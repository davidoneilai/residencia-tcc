#if MLX_LM_MAIN
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Cabeça MTP do Qwen3.5-2B escrita aqui, sem as camadas internas do `mlx-swift-lm`, para controlar o rascunho:
/// vocabulário reduzido, cache próprio persistível e passadas que entram no pipeline do decode.
///
/// Igual ao `Qwen35MTPPredictor` do `mlx-swift-lm` e ao checkpoint oficial (`mtp.*`): concat(norm_e(emb(x[t+1])),
/// norm_h(h[t])) → `fc` → 1 camada de atenção completa do Qwen3.5 (porta de saída sigmoide, q/k norm, RoPE parcial de
/// 64 dimensões, base 10⁷) com MLP SwiGLU → norma. `h[t]` é o estado oculto do alvo depois da norma final. As normas do
/// checkpoint HF vêm como desvio (w − 1): todos os 7 tensores 1-D recebem +1 ao carregar.
final class MTPAttention: Module {
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let rope: RoPE

    init(hidden: Int, heads: Int, kvHeads: Int, headDim: Int, ropeDims: Int, ropeBase: Float, eps: Float) {
        self.heads = heads
        self.kvHeads = kvHeads
        self.headDim = headDim
        _qProj.wrappedValue = Linear(hidden, heads * headDim * 2, bias: false)
        _kProj.wrappedValue = Linear(hidden, kvHeads * headDim, bias: false)
        _vProj.wrappedValue = Linear(hidden, kvHeads * headDim, bias: false)
        _oProj.wrappedValue = Linear(heads * headDim, hidden, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: eps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: eps)
        rope = RoPE(dimensions: ropeDims, traditional: false, base: ropeBase)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cache: KVCache) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))
        let split = qProj(x).reshaped(B, L, heads, -1).split(parts: 2, axis: -1)
        let gate = split[1].reshaped(B, L, -1)
        var q = qNorm(split[0]).transposed(0, 2, 1, 3)
        var k = kNorm(kProj(x).reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)
        q = rope(q, offset: cache.offset)
        k = rope(k, offset: cache.offset)
        let out = attentionWithCacheUpdate(
            queries: q, keys: k, values: v, cache: cache, scale: 1 / Float(headDim).squareRoot(),
            mask: createAttentionMask(h: x, cache: [cache]))
        return oProj(out.transposed(0, 2, 1, 3).reshaped(B, L, -1) * sigmoid(gate))
    }
}

final class MTPMLP: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    init(hidden: Int, intermediate: Int) {
        _gate.wrappedValue = Linear(hidden, intermediate, bias: false)
        _up.wrappedValue = Linear(hidden, intermediate, bias: false)
        _down.wrappedValue = Linear(intermediate, hidden, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { down(silu(gate(x)) * up(x)) }
}

final class MTPLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: MTPAttention
    @ModuleInfo(key: "mlp") var mlp: MTPMLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postNorm: RMSNorm

    init(_ c: MTPHead.Config) {
        _attention.wrappedValue = MTPAttention(
            hidden: c.hidden, heads: c.heads, kvHeads: c.kvHeads, headDim: c.headDim, ropeDims: c.ropeDims,
            ropeBase: c.ropeBase, eps: c.eps)
        _mlp.wrappedValue = MTPMLP(hidden: c.hidden, intermediate: c.intermediate)
        _inputNorm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.eps)
        _postNorm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.eps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cache: KVCache) -> MLXArray {
        let h = x + attention(inputNorm(x), cache: cache)
        return h + mlp(postNorm(h))
    }
}

final class MTPHead: Module {
    struct Config {
        var hidden = 2048, intermediate = 6144, heads = 8, kvHeads = 2, headDim = 256, ropeDims = 64
        var ropeBase: Float = 10_000_000
        var eps: Float = 1e-6
    }

    @ModuleInfo(key: "fc") var fc: Linear
    @ModuleInfo(key: "layers") var layers: [MTPLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm
    @ModuleInfo(key: "pre_fc_norm_embedding") var normEmbedding: RMSNorm
    @ModuleInfo(key: "pre_fc_norm_hidden") var normHidden: RMSNorm

    init(_ c: Config = Config()) {
        _fc.wrappedValue = Linear(c.hidden * 2, c.hidden, bias: false)
        _layers.wrappedValue = [MTPLayer(c)]
        _norm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.eps)
        _normEmbedding.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.eps)
        _normHidden.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.eps)
        super.init()
    }

    /// `embeds` = emb(x[t+1]) e `hidden` = h[t] (depois da norma final do alvo), [1, L, H]; devolve o estado da MTP.
    func callAsFunction(embeds: MLXArray, hidden: MLXArray, cache: KVCache) -> MLXArray {
        var x = fc(concatenated([normEmbedding(embeds), normHidden(hidden)], axis: -1))
        for layer in layers { x = layer(x, cache: cache) }
        return norm(x)
    }

    /// Lê `mtp.*` de um `.safetensors` (bf16, normas como desvio) e confere que todo parâmetro foi preenchido.
    static func load(_ url: URL) throws -> MTPHead {
        let head = MTPHead()
        var weights = [String: MLXArray]()
        for (key, value) in try MLX.loadArrays(url: url) where key.hasPrefix("mtp.") {
            let name = String(key.dropFirst("mtp.".count))
            weights[name] = value.ndim == 1 ? value + MLXArray(1, dtype: value.dtype) : value
        }
        try head.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(head)
        return head
    }
}

/// Embedding atado do alvo (4 bits): ler linhas e projetar o estado no vocabulário inteiro ou num subconjunto.
struct TiedVocabulary {
    let weight: MLXArray
    let scales: MLXArray
    let biases: MLXArray
    let groupSize: Int
    let bits: Int

    init(model: any LanguageModel) throws {
        let flat = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        guard let key = flat.keys.first(where: { $0.hasSuffix("embed_tokens.weight") }) else {
            throw MTPDrafters.MTPError.notADrafter
        }
        let base = String(key.dropLast("weight".count))
        guard let scales = flat[base + "scales"], let biases = flat[base + "biases"] else {
            throw MTPDrafters.MTPError.notADrafter
        }
        weight = flat[key]!
        self.scales = scales
        self.biases = biases
        // mlx-community: grupos de 64; `weight` empacota 32/bits valores por uint32, `scales` tem 1 por grupo.
        groupSize = 64
        bits = weight.dim(-1) * 32 / (scales.dim(-1) * 64)
    }

    func embed(_ ids: MLXArray) -> MLXArray {
        dequantized(weight[ids], scales: scales[ids], biases: biases[ids], groupSize: groupSize, bits: bits)
    }

    /// Logits sobre todo o vocabulário ou só sobre `subset` (ids), para o argmax do rascunho.
    func logits(_ hidden: MLXArray, subset: MLXArray? = nil) -> MLXArray {
        guard let subset else {
            return quantizedMatmul(hidden, weight, scales: scales, biases: biases, transpose: true,
                                   groupSize: groupSize, bits: bits)
        }
        return quantizedMatmul(hidden, weight[subset], scales: scales[subset], biases: biases[subset],
                               transpose: true, groupSize: groupSize, bits: bits)
    }
}

#endif
