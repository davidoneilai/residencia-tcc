import MLX
import MLXLMCommon

// Diferenças entre o `mlx-swift-lm` 3.31.4 (build dos estudos até o TEST de 2026-11-10) e o `main` usado no build
// do LFM3 (`~/VSCODE/MobileLLMBench-lfm3`, `-D MLX_LM_MAIN`). Tudo aqui reproduz no `main` o comportamento do 3.31.4,
// para que o mesmo código meça a mesma coisa nos dois builds.

/// Texto bruto do modelo como o 3.31.4 entregava: raciocínio, `</think>` e resposta num só fluxo.
/// No `main`, o raciocínio chega à parte (`.reasoning`) e o delimitador some do `.chunk`; o resto do backend
/// (`ThinkingFilter`, contagem de raciocínio, `recoverToolCalls`, `raw_text`) depende do texto inteiro.
struct RawText {
    var value = ""
    private var thinking = false

    mutating func reasoning(_ piece: String) {
        thinking = true
        value += piece
    }

    mutating func chunk(_ piece: String) {
        close()
        value += piece
    }

    /// Uma chamada ou o fim do stream também fecham o raciocínio.
    mutating func close() {
        if thinking {
            value += "</think>"
            thinking = false
        }
    }
}

extension GenerateParameters {
    /// Prefill em blocos de exatamente o passo (512), como no 3.31.4; no `main` o padrão virou `balanced`, que muda a
    /// numérica e, com ela, trajetórias greedy frágeis.
    func legacyPrefill() -> GenerateParameters {
        #if MLX_LM_MAIN
        var parameters = self
        parameters.prefill.chunking = .remainder
        return parameters
        #else
        return self
        #endif
    }
}

extension LanguageModel {
    /// `newCache` passou a lançar erro no `main`.
    func makeCache(parameters: GenerateParameters?) throws -> [KVCache] {
        #if MLX_LM_MAIN
        try newCache(parameters: parameters)
        #else
        newCache(parameters: parameters)
        #endif
    }

    /// `prepare` com os blocos do 3.31.4 (ver `GenerateParameters.legacyPrefill`).
    func legacyPrepare(_ input: LMInput, cache: [KVCache], windowSize: Int) throws -> PrepareResult {
        #if MLX_LM_MAIN
        try prepare(input, cache: cache, state: nil, prefill: .init(stepSize: windowSize, chunking: .remainder))
        #else
        try prepare(input, cache: cache, windowSize: windowSize)
        #endif
    }
}
