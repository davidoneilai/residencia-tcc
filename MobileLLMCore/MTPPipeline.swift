#if MLX_LM_MAIN
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Contadores do `MTPPipelineIterator`, lidos depois da geração (`ServeStats.draft`).
final class MTPReport: @unchecked Sendable {
    var rounds = 0
    var proposed = 0
    var accepted = 0
    /// Rodadas já na fila descartadas porque a anterior rejeitou o rascunho.
    var wasted = 0
    /// Rejeições sem o checkpoint do estado recorrente: o trecho volta inteiro e passa de novo pelo modelo.
    var replays = 0
    /// Rodadas em que a seguinte não entrou na fila: confiança do rascunho abaixo de `gate`.
    var synced = 0
    /// Rascunhos propostos e aceitos por decil da confiança da MTP (calibração do `gate`).
    var proposedByConfidence = [Int](repeating: 0, count: 10)
    var acceptedByConfidence = [Int](repeating: 0, count: 10)
    var prefillMs = 0.0
    var waitMs = 0.0
    var context = 0
    var subset = 0
    var forced = false
    var thinkTokens: Int?

    var json: [String: Any] {
        ["mtp_rounds": rounds, "mtp_proposed": proposed, "mtp_accepted": accepted, "mtp_wasted_rounds": wasted,
         "mtp_replays": replays, "mtp_synced": synced, "mtp_proposed_by_conf": proposedByConfidence,
         "mtp_accepted_by_conf": acceptedByConfidence, "mtp_prefill_ms": prefillMs, "mtp_wait_ms": waitMs, "mtp_context": context,
         "mtp_subset": subset]
    }
}

/// Vocabulário reduzido do rascunho: linhas do embedding atado já recortadas (tokens do prompt e os já gerados).
/// Cresce com os tokens novos; o argmax do rascunho só olha estas linhas.
struct VocabularySubset {
    private(set) var ids: MLXArray
    private var weight: MLXArray
    private var scales: MLXArray
    private var biases: MLXArray
    private var known: Set<Int32>
    private var fresh = [Int32]()

    init(_ tokens: [Int32], vocab: TiedVocabulary) {
        known = Set(tokens)
        let list = Array(known)
        ids = MLXArray(list)
        weight = vocab.weight[ids]
        scales = vocab.scales[ids]
        biases = vocab.biases[ids]
    }

    var count: Int { known.count }

    mutating func add(_ token: Int) {
        if known.insert(Int32(token)).inserted { fresh.append(Int32(token)) }
    }

    /// Junta as linhas dos tokens novos (fora do caminho crítico: só quando algum token inédito saiu).
    mutating func sync(_ vocab: TiedVocabulary) {
        guard !fresh.isEmpty else { return }
        let new = MLXArray(fresh)
        fresh = []
        ids = concatenated([ids, new])
        weight = concatenated([weight, vocab.weight[new]])
        scales = concatenated([scales, vocab.scales[new]])
        biases = concatenated([biases, vocab.biases[new]])
    }

    /// Argmax de `hidden` [1, L, H] sobre o subconjunto: ids [L] e a probabilidade (softmax no subconjunto).
    func draft(_ hidden: MLXArray, groupSize: Int, bits: Int) -> (MLXArray, MLXArray) {
        let logits = quantizedMatmul(hidden[0], weight, scales: scales, biases: biases, transpose: true,
                                     groupSize: groupSize, bits: bits)
        return (take(ids, MLX.argMax(logits, axis: -1), axis: 0), TiedVocabulary.confidence(logits))
    }
}

extension TiedVocabulary {
    /// Rascunho de `hidden` [1, L, H] (vocabulário inteiro ou `subset`): ids int32 [L] e a confiança da MTP [L].
    func draft(_ hidden: MLXArray, subset: VocabularySubset?) -> (MLXArray, MLXArray) {
        if let subset { return subset.draft(hidden, groupSize: groupSize, bits: bits) }
        let logits = logits(hidden)[0]
        return (MLX.argMax(logits, axis: -1).asType(.int32), Self.confidence(logits))
    }

    /// Probabilidade do argmax: exp(max − logsumexp), em float32.
    static func confidence(_ logits: MLXArray) -> MLXArray {
        let x = logits.asType(.float32)
        return exp(x.max(axis: -1) - logSumExp(x, axis: -1))
    }
}

/// Decodificação especulativa com a cabeça MTP própria (`MTPHead`), sem sincronizar a cada rodada.
///
/// Uma rodada passa `[y, d]` pelo alvo (y = token já decidido, d = rascunho da MTP) e, no mesmo grafo, roda a MTP
/// sobre as duas posições. Aceite (`argmax(y) == d`) ou não, o próximo par sai na GPU com `which`:
/// - aceite: próximo token = argmax depois de d; rascunho = MTP na 2ª posição;
/// - rejeição: próximo token = argmax depois de y; rascunho = MTP na 1ª posição, que recebeu esse token no lugar de d.
///
/// Assim a rodada seguinte entra na fila antes de a CPU ler a anterior, como o decode comum faz com `asyncEval`. A
/// CPU só precisa saber o resultado para emitir os tokens e, na rejeição (≈ 13%), desfazer: a rodada seguinte, que
/// foi montada sobre o d errado, é descartada; a atenção apara 1 + 2 posições; o `MambaCache` volta ao estado depois
/// de y, salvo pelo próprio modelo dentro da passada (`mtpCacheCheckpointIndexKey`), sem reprocessar nada; a MTP
/// apara a posição errada. Greedy, verificado pelo alvo: só sai token que o alvo escolheria nessa passada (a passada
/// em lote de 2 muda a numérica, então a trajetória pode diferir da do decode token a token).
///
/// Contexto da MTP: só os últimos `mtpContext` tokens da entrada (o prefixo vem do cache do alvo, sem estados
/// ocultos). Budget forcing opcional, como no `ThinkBudgetIterator`, mas a especulação continua depois do fechamento.
struct MTPPipelineIterator: TokenIteratorProtocol {
    let model: any LanguageModel
    var cache: [any KVCache]
    var state: LMOutput.State?
    let maxTokens: Int?
    var tokenCount = 0
    var promptPrefillTime: TimeInterval = 0

    let head: MTPHead
    let vocab: TiedVocabulary
    var subset: VocabularySubset?
    let mtpCache = KVCacheSimple()
    let force: (budget: Int, close: Int, closing: [Int])?
    let report: MTPReport
    /// Escalonador pelo custo do aparelho: a rodada seguinte só entra na fila antes da leitura da atual se a
    /// confiança da MTP no rascunho atual for ≥ `gate`. Na fila, uma rejeição desperdiça a rodada seguinte (custo r);
    /// sem fila, a GPU espera a CPU montar o grafo (custo b). Vale enfileirar se P(aceite) > 1 − b/r.
    let gate: Float
    private var pending = [Int]()
    private var current: Round?
    private var ahead: Round?
    private var closed = false

    private struct Round {
        /// Tokens já decididos passados ao alvo (1; o fechamento forçado no budget).
        let tokens: MLXArray
        let count: Int
        /// Quantos de `tokens` já saíram (rejeição sem checkpoint passa de novo os tokens emitidos).
        let skip: Int
        let draft: MLXArray?
        /// Confiança da MTP em `draft` (calculada na rodada anterior, que já foi lida).
        let confidence: MLXArray?
        let mtpFed: Int
        let redo: Bool
        let accepted: MLXArray?
        let nextToken: MLXArray
        let nextDraft: MLXArray
        let nextConfidence: MLXArray
        /// Estado oculto da última posição válida da MTP, para refazer a 1ª posição dela no fechamento forçado.
        let outHidden: MLXArray
        let prevHidden: MLXArray
        /// Slots e offset de cada `MambaCache` antes da rodada, e o checkpoint depois de `tokens` (com rascunho).
        let before: [(Int, MLXArray?, MLXArray?, Int)]
        let mid: [(Int, MLXArray, MLXArray)]
        /// Se a passada avança o `offset` do `MambaCache` (para restaurá-lo junto com os slots).
        let stepsMamba: Bool
        var fed: Int { count + (draft == nil ? 0 : 1) }
    }

    init(
        input: LMInput, model: any LanguageModel, cache: [any KVCache], maxTokens: Int, head: MTPHead,
        vocab: TiedVocabulary, seed: [Int32]?, mtpContext: Int, gate: Float,
        force: (budget: Int, close: Int, closing: [Int])?, report: MTPReport
    ) throws {
        self.gate = gate
        self.model = model
        self.cache = cache
        self.maxTokens = maxTokens
        self.head = head
        self.vocab = vocab
        self.force = force
        self.report = report
        let started = Date.timeIntervalSinceReferenceDate
        let tokens = input.text.tokens.reshaped(-1).asType(.int32).asArray(Int32.self)
        subset = seed.map { VocabularySubset($0 + tokens, vocab: vocab) }
        // Prefill do alvo: o começo sem estados ocultos (como o `TokenIterator`), os últimos `k` com eles.
        let k = Swift.min(Swift.max(mtpContext, 1), tokens.count)
        let lead = Array(tokens.dropLast(k))
        var at = 0
        while at < lead.count {
            let end = Swift.min(at + 512, lead.count)
            _ = model(LMInput.Text(tokens: MLXArray(Array(lead[at ..< end]))[.newAxis]), cache: cache, state: nil)
            eval(cache.flatMap { $0.state })
            at = end
        }
        var emit = LMOutput.State()
        emit[mtpEmitFlagKey] = true
        let tail = Array(tokens.suffix(k))
        var hiddens = [MLXArray]()
        var last = MLXArray(0)
        at = 0
        while at < tail.count {
            // Com o estado ligado o alvo projeta todas as posições no vocabulário: blocos de 256 limitam a memória.
            let end = Swift.min(at + 256, tail.count)
            let out = model(LMInput.Text(tokens: MLXArray(Array(tail[at ..< end]))[.newAxis]), cache: cache, state: emit)
            guard let hidden = out.state?[mtpLastHiddenStatesKey] else { throw MTPDrafters.MTPError.notADrafter }
            last = MLX.argMax(out.logits[0, -1], axis: -1).asType(.int32).reshaped(1)
            eval(hidden, last, cache.flatMap { $0.state })
            hiddens.append(hidden)
            at = end
        }
        // Prefill da MTP: a posição i recebe emb(x[i+1]) e h[i]; o último x é o 1º token gerado.
        let hidden = concatenated(hiddens, axis: 1)
        let ids = concatenated([MLXArray(Array(tail.dropFirst())), last])
        var out = MLXArray(0)
        at = 0
        while at < k {
            let end = Swift.min(at + 256, k)
            out = head(embeds: vocab.embed(ids[at ..< end])[.newAxis], hidden: hidden[0..., at ..< end, 0...],
                       cache: mtpCache)
            eval(out)
            at = end
        }
        subset?.sync(vocab)
        let (draft, confidence) = vocab.draft(out[0..., (-1)..., 0...], subset: subset)
        report.context = k
        current = build(
            tokens: last, count: 1, draft: draft, confidence: confidence, prevHidden: hidden[0..., (k - 1)..., 0...],
            redo: false)
        promptPrefillTime = Date.timeIntervalSinceReferenceDate - started
        report.prefillMs = promptPrefillTime * 1000
    }

    /// Enfileira uma rodada (alvo + MTP) sem sincronizar. `redo`: a 1ª posição da MTP é refeita com `tokens[0]`.
    private mutating func build(
        tokens: MLXArray, count c: Int, skip: Int = 0, draft: MLXArray?, confidence: MLXArray?, prevHidden: MLXArray,
        redo: Bool
    ) -> Round {
        subset?.sync(vocab)
        let before = cache.enumerated().compactMap { i, entry -> (Int, MLXArray?, MLXArray?, Int)? in
            (entry as? MambaCache).map { (i, $0[0], $0[1], $0.offset) }
        }
        if redo { _ = mtpCache.trim(1) }
        var flags = LMOutput.State()
        flags[mtpEmitFlagKey] = true
        if draft != nil { flags[mtpCacheCheckpointIndexKey] = c }
        let input = draft.map { concatenated([tokens, $0]) } ?? tokens
        let out = model(LMInput.Text(tokens: input[.newAxis]), cache: cache, state: flags)
        let hidden = out.state?[mtpLastHiddenStatesKey] ?? MLXArray.zeros([1, input.dim(0), head.fc.weight.dim(0)])
        let picks = MLX.argMax(out.logits[0], axis: -1).asType(.int32)
        let stepsMamba = before.first.map { (cache[$0.0] as! MambaCache).offset != $0.3 } ?? false
        // O checkpoint fica num campo privado do `MambaCache` e a próxima passada o sobrescreve: lido já.
        let mid = draft == nil ? [] : cache.enumerated().compactMap { i, entry -> (Int, MLXArray, MLXArray)? in
            (entry as? MambaCache).flatMap(Self.checkpoint).map { (i, $0.0, $0.1) }
        }
        var ids = [MLXArray]()
        var hiddens = [MLXArray]()
        if redo {
            ids.append(tokens[0 ..< 1])
            hiddens.append(prevHidden)
        }
        if c > 1 { ids.append(tokens[1 ..< c]) }
        let accepted = draft.map { picks[(c - 1) ..< c] .== $0 }
        if let draft, let accepted {
            ids.append(which(accepted, draft, picks[(c - 1) ..< c]))
            ids.append(picks[c ..< (c + 1)])
        } else {
            ids.append(picks[(c - 1) ..< c])
        }
        hiddens.append(hidden)
        let mtp = head(embeds: vocab.embed(concatenated(ids))[.newAxis], hidden: concatenated(hiddens, axis: 1),
                       cache: mtpCache)
        let length = mtp.dim(1)
        let nextToken: MLXArray
        let nextDraft: MLXArray
        let nextConfidence: MLXArray
        let outHidden: MLXArray
        if let accepted {
            let (both, sure) = vocab.draft(mtp[0..., (length - 2)..., 0...], subset: subset)
            nextToken = which(accepted, picks[c ..< (c + 1)], picks[(c - 1) ..< c])
            nextDraft = which(accepted, both[1 ..< 2], both[0 ..< 1])
            nextConfidence = which(accepted, sure[1 ..< 2], sure[0 ..< 1])
            outHidden = which(accepted, hidden[0..., c ..< (c + 1), 0...], hidden[0..., (c - 1) ..< c, 0...])
            asyncEval(nextToken, nextDraft, nextConfidence, outHidden, accepted)
        } else {
            nextToken = picks[(c - 1) ..< c]
            (nextDraft, nextConfidence) = vocab.draft(mtp[0..., (length - 1)..., 0...], subset: subset)
            outHidden = hidden[0..., (c - 1) ..< c, 0...]
            asyncEval(nextToken, nextDraft, nextConfidence, outHidden)
        }
        report.rounds += 1
        return Round(
            tokens: tokens, count: c, skip: skip, draft: draft, confidence: confidence, mtpFed: length, redo: redo,
            accepted: accepted, nextToken: nextToken, nextDraft: nextDraft, nextConfidence: nextConfidence,
            outHidden: outHidden, prevHidden: prevHidden,
            before: before, mid: mid, stepsMamba: stepsMamba)
    }

    /// `MambaCache.speculativeCheckpoint` (privado no `mlx-swift-lm`) por reflexão: slots depois dos tokens decididos.
    private static func checkpoint(_ cache: MambaCache) -> (MLXArray, MLXArray)? {
        guard let saved = Mirror(reflecting: cache).children.first(where: { $0.label == "speculativeCheckpoint" })?.value,
              let wrapped = Mirror(reflecting: saved).children.first?.value,
              let slots = Mirror(reflecting: wrapped).children.first(where: { $0.label == "state" })?.value
                as? [MLXArray?],
              slots.count == 2, let conv = slots[0], let recurrent = slots[1]
        else { return nil }
        return (conv, recurrent)
    }

    private mutating func buildSuccessor(_ round: Round) -> Round {
        build(
            tokens: round.nextToken, count: 1, draft: round.nextDraft, confidence: round.nextConfidence,
            prevHidden: round.outHidden, redo: false)
    }

    mutating func next() -> Int? {
        if let maxTokens, tokenCount >= maxTokens { return nil }
        if !pending.isEmpty { return emit(pending.removeFirst()) }
        guard current != nil else { return nil }
        if let force, !closed, tokenCount >= force.budget { forceClose(force.closing) }
        if ahead == nil, let current {
            if gate <= 0 || (current.confidence?.item(Float.self) ?? 1) >= gate {
                ahead = buildSuccessor(current)
            } else {
                report.synced += 1
            }
        }
        resolve()
        return pending.isEmpty ? nil : emit(pending.removeFirst())
    }

    /// Lê a rodada atual (a seguinte já está na GPU), emite os tokens e, na rejeição, desfaz a seguinte.
    private mutating func resolve() {
        guard let round = current else { return }
        let started = Date.timeIntervalSinceReferenceDate
        let ok = round.accepted.map { $0.item(Bool.self) } ?? true
        var out = round.tokens.asArray(Int32.self).dropFirst(round.skip).map(Int.init)
        if let draft = round.draft {
            let bin = Swift.min(9, Swift.max(0, Int((round.confidence?.item(Float.self) ?? 1) * 10)))
            report.proposed += 1
            report.proposedByConfidence[bin] += 1
            if ok {
                report.accepted += 1
                report.acceptedByConfidence[bin] += 1
                out.append(draft.item(Int.self))
            }
        }
        report.waitMs += (Date.timeIntervalSinceReferenceDate - started) * 1000
        pending = out
        if ok {
            current = ahead ?? buildSuccessor(round)
            ahead = nil
            return
        }
        let wasted = ahead
        ahead = nil
        if wasted != nil { report.wasted += 1 }
        let exact = round.mid.count == round.before.count
        if exact {
            // Atenção: d e a rodada descartada; recorrente: estado depois dos tokens decididos; MTP: idem.
            for entry in cache where !(entry is MambaCache) { _ = entry.trim(1 + (wasted?.fed ?? 0)) }
            for (i, conv, recurrent) in round.mid {
                let mamba = cache[i] as! MambaCache
                mamba[0] = conv
                mamba[1] = recurrent
            }
            for (i, _, _, offset) in round.before { (cache[i] as! MambaCache).offset = offset + (round.stepsMamba ? round.count : 0) }
            _ = mtpCache.trim(1 + (wasted?.mtpFed ?? 0))
            current = buildSuccessor(round)
        } else {
            // Sem checkpoint: tudo volta ao começo da rodada e os tokens decididos passam de novo, com o novo.
            report.replays += 1
            rewind(round, wasted)
            current = build(
                tokens: concatenated([round.tokens, round.nextToken]), count: round.count + 1, skip: round.count,
                draft: round.nextDraft, confidence: round.nextConfidence, prevHidden: round.prevHidden, redo: false)
        }
    }

    /// Volta alvo e MTP ao estado de antes de `round` (a MTP, até depois da posição refeita, se houve).
    private mutating func rewind(_ round: Round, _ wasted: Round?) {
        for entry in cache where !(entry is MambaCache) { _ = entry.trim(round.fed + (wasted?.fed ?? 0)) }
        for (i, conv, recurrent, offset) in round.before {
            let mamba = cache[i] as! MambaCache
            mamba[0] = conv
            mamba[1] = recurrent
            mamba.offset = offset
        }
        _ = mtpCache.trim(round.mtpFed - (round.redo ? 1 : 0) + (wasted?.mtpFed ?? 0))
    }

    /// Budget forcing: o token decidido e ainda não emitido é descartado e o fechamento entra no lugar.
    private mutating func forceClose(_ closing: [Int]) {
        guard let round = current else { return }
        closed = true
        report.forced = true
        report.thinkTokens = tokenCount
        rewind(round, ahead)
        if ahead != nil { report.wasted += 1 }
        ahead = nil
        current = build(
            tokens: MLXArray(closing.map(Int32.init)), count: closing.count, draft: nil, confidence: nil,
            prevHidden: round.prevHidden, redo: true)
    }

    private mutating func emit(_ token: Int) -> Int {
        tokenCount += 1
        subset?.add(token)
        if let force, !closed, token == force.close {
            closed = true
            report.thinkTokens = tokenCount
        }
        return token
    }
}
#endif
