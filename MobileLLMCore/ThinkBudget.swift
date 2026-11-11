import Foundation
import MLX
import MLXLMCommon

/// Guardas de decode do servidor (DAC): só agem quando a resposta para de progredir.
struct ServeGuards: Sendable {
    /// Raciocínio que passa disto sem `</think>` é fechado à força e a resposta continua do mesmo KV.
    var thinkBudget: Int?
    /// Corta o decode quando a mesma chamada (nome e argumentos) sai de novo na mesma resposta.
    var repeatGuard = false
    /// Runtime: KV de system + tools persistido em disco entre tarefas e sessões (`PrefixStore`). Só muda o tempo.
    var persistPrefix = false
    /// Runtime: rascunho da gramática nas chamadas do Qwen3.5, verificado pelo modelo (`GrammarDraftIterator`).
    var grammarDraft = false
    /// Runtime: decodificação especulativa com a cabeça MTP do Qwen3.5 (`MTPDrafters`, só no build `MLX_LM_MAIN`).
    /// Tokens por passada de verificação: 2 = 1 rascunho. Greedy: a saída tem de ser idêntica à sem MTP.
    var mtpBlock: Int?
    /// Runtime: especulação com a cabeça MTP própria, em pipeline (`MTPPipelineIterator`): `full` ou `subset`
    /// (rascunho no vocabulário reduzido). `mtpContext`: últimos tokens da entrada que entram no cache da MTP.
    var mtpPipe: String?
    var mtpContext: Int?
    /// Ids `0..<mtpTop` (no BPE, os merges mais frequentes) somados ao vocabulário reduzido.
    var mtpTop: Int?
    /// Confiança mínima da MTP para enfileirar a rodada seguinte sem ler a atual (0 = sempre).
    var mtpGate: Double?
}

/// Decomposição de um `chatTurn`: onde foi o tempo e de onde veio o KV.
struct ServeStats {
    /// Jinja + tokenização do prompt inteiro.
    var templateMs = 0.0
    /// Sondas do template, prefill do trecho novo e cópias do KV (inclui `fillMs` e `prefixBuildMs`).
    var cacheMs = 0.0
    /// KV de system + tools refeito (catálogo novo).
    var prefixBuildMs = 0.0
    var prefixBuildTokens = 0
    /// Prefill entre o KV reaproveitado e o ponto estável guardado para o passo seguinte.
    var fillMs = 0.0
    var fillTokens = 0
    /// Prefill do resto do prompt dentro do `generate`, até o 1º token.
    var evalTokens = 0
    var evalMs = 0.0
    var decodeMs = 0.0
    /// Snapshot reaproveitado: conv, turn, system ou nenhum.
    var reusedFrom = "none"
    var forcedClose = false
    var thinkTokens: Int?
    var repeatCut = false
    /// De onde veio o KV de system + tools: memory (já carregado), disk (`PrefixStore`), built (prefill) ou none.
    var prefixSource = "none"
    var prefixLoadMs = 0.0
    var prefixSaveMs = 0.0
    /// Por que o prefixo não foi gravado (layout do cache, erro do serializador); nil quando gravou ou não tentou.
    var prefixSaveError: String?
    /// Rascunhos da MTP propostos e aceitos no passo (telemetria do iterador especulativo).
    var mtpProposed: Int?
    var mtpAccepted: Int?
    /// Por que o iterador MTP caiu para geração comum (nil = especulou até o fim).
    var mtpPassthrough: String?
    var draft: [String: Any] = [:]

    var json: [String: Any] {
        var row: [String: Any] = [
            "template_ms": templateMs, "cache_ms": cacheMs, "prefix_build_ms": prefixBuildMs,
            "prefix_build_tokens": prefixBuildTokens, "fill_ms": fillMs, "fill_tokens": fillTokens,
            "eval_tokens": evalTokens, "eval_ms": evalMs, "decode_ms": decodeMs, "reused_from": reusedFrom,
            "forced_close": forcedClose, "repeat_cut": repeatCut,
            "prefix_source": prefixSource, "prefix_load_ms": prefixLoadMs, "prefix_save_ms": prefixSaveMs,
            // Todo o prefill do passo: prefixo novo, trecho até o ponto estável e o resto do prompt.
            "prefill_ms": prefixBuildMs + fillMs + evalMs,
            "prefill_tokens": prefixBuildTokens + fillTokens + evalTokens,
        ]
        if let thinkTokens { row["think_tokens"] = thinkTokens }
        if let prefixSaveError { row["prefix_save_error"] = prefixSaveError }
        if let mtpProposed { row["mtp_proposed"] = mtpProposed }
        if let mtpAccepted { row["mtp_accepted"] = mtpAccepted }
        if let mtpPassthrough { row["mtp_passthrough"] = mtpPassthrough }
        row.merge(draft) { a, _ in a }
        return row
    }
}

final class ThinkReport: @unchecked Sendable {
    var forced = false
    var thinkTokens: Int?
}

/// Budget forcing (s1) só no estouro: até `budget` tokens sem `</think>`, devolve o fechamento como se o modelo
/// o tivesse gerado e continua do mesmo cache. Quem fecha antes do orçamento segue token a token igual ao `TokenIterator`.
/// O `TokenIterator` já passou pelo modelo todo token que devolveu, então o fechamento entra como prompt de um iterador
/// novo sobre o mesmo KV: nada é reprocessado e posições e estado recorrente continuam os do decode.
struct ThinkBudgetIterator: TokenIteratorProtocol {
    /// O iterador comum ou o especulativo (MTP). No fechamento forçado o resto segue num `TokenIterator` comum.
    var inner: any TokenIteratorProtocol
    let model: any LanguageModel
    let cache: [any KVCache]
    let closeID: Int
    let closing: [Int]
    let budget: Int
    let maxTokens: Int?
    let report: ThinkReport
    private(set) var tokenCount = 0
    let promptPrefillTime: TimeInterval
    private var pending = [Int]()
    private var closed = false
    /// Aceitação da MTP até o fechamento forçado (o iterador especulativo é trocado nele).
    private(set) var speculativeStats: (proposed: Int, accepted: Int, reason: String?) = (0, 0, nil)

    init(
        inner: any TokenIteratorProtocol, model: any LanguageModel, cache: [any KVCache], closeID: Int, closing: [Int],
        budget: Int, maxTokens: Int, report: ThinkReport
    ) {
        self.inner = inner
        self.model = model
        self.cache = cache
        self.closeID = closeID
        self.closing = closing
        self.budget = budget
        self.maxTokens = maxTokens
        self.report = report
        promptPrefillTime = inner.promptPrefillTime
    }

    mutating func next() -> Int? {
        if let maxTokens, tokenCount >= maxTokens { return nil }
        if pending.isEmpty, !closed, tokenCount >= budget {
            closed = true
            report.forced = true
            report.thinkTokens = tokenCount
            let input = LMInput(tokens: MLXArray(closing.map(Int32.init)))
            #if MLX_LM_MAIN
            if let stats = inner as? MTPStatsCollecting {
                speculativeStats = (stats.proposedDraftTokens, stats.acceptedDraftTokens, stats.passthroughReason)
            }
            #endif
            guard let resumed = try? TokenIterator(
                input: input, model: model, cache: cache, parameters: GenerateParameters(temperature: 0).legacyPrefill())
            else { return nil }
            inner = resumed
            pending = closing
        }
        let token: Int
        if !pending.isEmpty {
            token = pending.removeFirst()
        } else {
            guard let next = inner.next() else { return nil }
            token = next
            if !closed, token == closeID {
                closed = true
                report.thinkTokens = tokenCount
            }
        }
        tokenCount += 1
        return token
    }

    mutating func discardGeneratedToken() { inner.discardGeneratedToken() }
}

#if MLX_LM_MAIN
/// O `generateTask` só publica a aceitação da MTP se o iterador entregue for `MTPStatsCollecting`; o envoltório repassa.
/// Depois do fechamento forçado o resto roda num `TokenIterator` comum, e os números são os do trecho especulativo.
extension ThinkBudgetIterator: MTPStatsCollecting {
    var proposedDraftTokens: Int { (inner as? MTPStatsCollecting)?.proposedDraftTokens ?? speculativeStats.proposed }
    var acceptedDraftTokens: Int { (inner as? MTPStatsCollecting)?.acceptedDraftTokens ?? speculativeStats.accepted }
    var passthroughReason: String? { (inner as? MTPStatsCollecting)?.passthroughReason ?? speculativeStats.reason }
}
#endif
