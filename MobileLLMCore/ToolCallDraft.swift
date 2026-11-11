import Foundation
import MLX
import MLXLMCommon

/// Trechos da chamada XML do Qwen3.5 (`<tool_call>\n<function=NOME>\n<parameter=P>\nVALOR\n</parameter>\n…`) que
/// a gramática e o catálogo de ferramentas determinam, dado o que o modelo já gerou. Só propõe rascunhos: quem
/// decide é o modelo (`GrammarDraftIterator` verifica cada token pelo argmax). Valores nunca são propostos.
struct ToolCallGrammar: Sendable {
    /// Nome da função → parâmetros (todos) e obrigatórios, na ordem do schema.
    let functions: [String: (all: [String], required: [String])]
    let callOpen: Int
    let callClose: Int
    let thinkClose: Int?
    static let maxDraft = 8

    init?(tools: [ToolSpec], tokenizer: any Tokenizer, thinkClose: String?) {
        var functions = [String: (all: [String], required: [String])]()
        for tool in tools {
            guard let fn = tool["function"] as? [String: any Sendable], let name = fn["name"] as? String else { continue }
            let parameters = fn["parameters"] as? [String: any Sendable]
            let properties = (parameters?["properties"] as? [String: any Sendable]).map { Array($0.keys).sorted() } ?? []
            let required = parameters?["required"] as? [String] ?? []
            functions[name] = (properties, required)
        }
        guard !functions.isEmpty, let open = tokenizer.convertTokenToId("<tool_call>"),
              let close = tokenizer.convertTokenToId("</tool_call>") else { return nil }
        self.functions = functions
        callOpen = open
        callClose = close
        self.thinkClose = thinkClose.flatMap { tokenizer.convertTokenToId($0) }
    }

    /// Texto que a gramática determina depois de `call` (texto desde `<tool_call>` inclusive); "" = nada determinado.
    func continuation(_ call: String) -> String {
        guard call.hasPrefix("<tool_call>") else { return "" }
        var rest = Substring(call.dropFirst("<tool_call>".count))
        if rest.isEmpty { return "\n<function=" }
        guard rest.hasPrefix("\n<function=") else { return "" }
        rest = rest.dropFirst("\n<function=".count)
        // Nome da função.
        guard let nameEnd = rest.firstIndex(of: ">") else { return complete(String(rest), among: Array(functions.keys)) }
        let name = String(rest[..<nameEnd])
        guard let spec = functions[name] else { return "" }
        rest = rest[rest.index(after: nameEnd)...]
        if rest.isEmpty { return "\n" }
        guard rest.hasPrefix("\n") else { return "" }
        rest = rest.dropFirst()
        var used = [String]()
        while true {
            // Fronteira: próximo parâmetro ou fim da função.
            if rest.isEmpty {
                let remaining = spec.all.filter { !used.contains($0) }
                if spec.required.contains(where: { !used.contains($0) }) { return "<parameter=" }
                return remaining.isEmpty ? "</function>\n</tool_call>" : ""
            }
            // `</` é um token só: um `<` sozinho na fronteira só pode abrir `<parameter=`.
            if rest == "<" { return "parameter=" }
            if "</function>\n</tool_call>".hasPrefix(rest) {
                return String("</function>\n</tool_call>".dropFirst(rest.count))
            }
            guard rest.hasPrefix("<parameter=") else {
                return "<parameter=".hasPrefix(rest) ? String("<parameter=".dropFirst(rest.count)) : ""
            }
            rest = rest.dropFirst("<parameter=".count)
            guard let keyEnd = rest.firstIndex(of: ">") else {
                return complete(String(rest), among: spec.all.filter { !used.contains($0) })
            }
            used.append(String(rest[..<keyEnd]))
            rest = rest[rest.index(after: keyEnd)...]
            if rest.isEmpty { return "\n" }
            // Valor: livre até `\n</parameter>\n`.
            guard let valueEnd = rest.range(of: "\n</parameter>\n") else {
                if let tail = rest.range(of: "\n</", options: .backwards), tail.upperBound == rest.endIndex {
                    return "parameter>\n"
                }
                if let tail = rest.range(of: "\n</parameter", options: .backwards), "\n</parameter>\n".hasPrefix(rest[tail.lowerBound...]) {
                    return String("\n</parameter>\n".dropFirst(rest.distance(from: tail.lowerBound, to: rest.endIndex)))
                }
                return ""
            }
            rest = rest[valueEnd.upperBound...]
        }
    }

    /// Resto de um nome quando o prefixo já escolhe um só candidato, mais `>\n`.
    private func complete(_ prefix: String, among names: [String]) -> String {
        let candidates = names.filter { $0.hasPrefix(prefix) }
        guard candidates.count == 1, let name = candidates.first else { return "" }
        // Se outro nome tem este como prefixo (`get_user` / `get_user_id`) o fim não é determinado: `count == 1` cobre.
        return String(name.dropFirst(prefix.count)) + ">\n"
    }

    /// Rascunho em tokens para continuar `generated`, ou [] se nada é determinado ou se a tokenização do contexto
    /// não reproduz os tokens já gerados (aí o rascunho nem seria aceito na mesma forma).
    func draft(_ generated: [Int], tokenizer: any Tokenizer) -> [Int] {
        guard let start = generated.lastIndex(of: callOpen), !generated[start...].contains(callClose) else { return [] }
        if let thinkClose, !generated.contains(thinkClose) { return [] }
        let emitted = Array(generated[start...])
        let text = tokenizer.decode(tokenIds: emitted, skipSpecialTokens: false)
        let more = continuation(text)
        guard !more.isEmpty else { return [] }
        let full = tokenizer.encode(text: text + more, addSpecialTokens: false)
        guard full.count > emitted.count, Array(full.prefix(emitted.count)) == emitted else { return [] }
        var draft = Array(full.dropFirst(emitted.count).prefix(Self.maxDraft))
        // `=` antes de um nome livre se funde com ele (`=get`, `=user`): o modelo escolhe esse token.
        if more.hasSuffix("="), let last = draft.last, tokenizer.decode(tokenIds: [last], skipSpecialTokens: false) == "=" {
            draft.removeLast()
        }
        return draft
    }
}

/// Telemetria do decode com rascunho (lida pelo servidor depois da geração).
final class DraftReport: @unchecked Sendable {
    var passes = 0
    var verifyPasses = 0
    var proposed = 0
    var accepted = 0
    var fullAccepts = 0
    var refeeds = 0
    var refeedTokens = 0
    var draftMs = 0.0
    var waitMs = 0.0
    var forced = false
    var thinkTokens: Int?

    var json: [String: Any] {
        ["draft_passes": passes, "draft_verify_passes": verifyPasses, "draft_proposed": proposed,
         "draft_accepted": accepted, "draft_full_accepts": fullAccepts, "draft_refeeds": refeeds,
         "draft_refeed_tokens": refeedTokens, "draft_grammar_ms": draftMs, "draft_wait_ms": waitMs]
    }
}

/// Decode guloso igual ao `TokenIterator` (mesma chamada do modelo, mesmo pipeline com `asyncEval`), mais:
/// - rascunho da gramática (`ToolCallGrammar`) para depois do token que acabou de sair: o passo normal já está na fila
///   (ele calcula o próximo token), e a passada de verificação com o rascunho entra logo atrás, como hipótese para esse
///   próximo token. O 1º token do rascunho vale se for o argmax do passo normal; o i-ésimo, se for o argmax da
///   verificação na posição anterior. Sem perda: o modelo nunca emite um token que não escolheria. O passo normal não
///   espera a CPU decidir o rascunho, então fora das chamadas o custo é o do `TokenIterator`;
/// - rejeição em modelo híbrido: a atenção apara (`trim`), o `MambaCache` não volta atrás, então os dois slots são
///   guardados por referência depois do passo normal (o modelo troca os arrays, não escreve neles) e restaurados; o
///   trecho aceito passa de novo pelo modelo (uma passada de `aceitos` tokens; nenhuma se nada foi aceito);
/// - budget forcing opcional (mesma regra do `ThinkBudgetIterator`): fechamento injetado numa passada.
struct GrammarDraftIterator: TokenIteratorProtocol {
    let model: any LanguageModel
    var cache: [any KVCache]
    var state: LMOutput.State?
    var y: MLXArray
    let maxTokens: Int?
    var tokenCount = 0
    var promptPrefillTime: TimeInterval = 0

    let grammar: ToolCallGrammar?
    let tokenizer: any Tokenizer
    let force: (budget: Int, close: Int, closing: [Int])?
    let report: DraftReport
    private var generated = [Int]()
    private var pending = [Int]()
    private var verify: (draft: [Int], first: MLXArray, picks: MLXArray, mamba: [(Int, MLXArray?, MLXArray?)])?
    private var closed = false

    init(
        input: LMInput, model: any LanguageModel, cache: [any KVCache], maxTokens: Int, grammar: ToolCallGrammar?,
        tokenizer: any Tokenizer, force: (budget: Int, close: Int, closing: [Int])?, report: DraftReport
    ) throws {
        self.model = model
        self.cache = cache
        self.maxTokens = maxTokens
        self.grammar = grammar
        self.tokenizer = tokenizer
        self.force = force
        self.report = report
        y = MLXArray(0)
        let started = Date.timeIntervalSinceReferenceDate
        switch try model.legacyPrepare(input, cache: cache, windowSize: 512) {
        case .tokens(let rest):
            y = argmax(forward(rest.tokens)[0, -1])
        case .logits(let result):
            y = argmax(result.logits[0, -1])
        }
        asyncEval(y)
        promptPrefillTime = Date.timeIntervalSinceReferenceDate - started
    }

    /// `model(...)` com os tokens dados; logits [1, T, V].
    private mutating func forward(_ tokens: MLXArray) -> MLXArray {
        let input = LMInput.Text(tokens: tokens)
        let result = withPreparedCache(cache, lengths: input.sequenceLengths) {
            model(input[text: .newAxis], cache: cache.isEmpty ? nil : cache, state: state)
        }
        state = result.state
        report.passes += 1
        return result.logits
    }

    private func argmax(_ logits: MLXArray) -> MLXArray { MLX.argMax(logits, axis: -1) }

    mutating func next() -> Int? {
        if let maxTokens, tokenCount >= maxTokens { return nil }
        if !pending.isEmpty { return emit(pending.removeFirst()) }
        if verify != nil {
            resolve()
            if !pending.isEmpty { return emit(pending.removeFirst()) }
        }
        // Budget forcing: o token pendente é descartado e o fechamento entra no lugar, numa passada.
        if let force, !closed, tokenCount >= force.budget {
            closed = true
            report.forced = true
            report.thinkTokens = tokenCount
            y = argmax(forward(MLXArray(force.closing.map(Int32.init)))[0, -1])
            asyncEval(y)
            pending = Array(force.closing.dropFirst())
            return emit(force.closing[0])
        }
        // Passo normal, como o `TokenIterator`: o grafo usa o token ainda não lido.
        let previous = y
        y = argmax(forward(previous[.newAxis])[0, -1])
        asyncEval(y)
        let current = previous.item(Int.self)
        if let force, !closed, current == force.close { closed = true; report.thinkTokens = tokenCount }
        guard let grammar else { return emit(current) }
        let started = Date.timeIntervalSinceReferenceDate
        var draft = grammar.draft(generated + [current], tokenizer: tokenizer)
        if let maxTokens { draft = Array(draft.prefix(Swift.max(0, maxTokens - tokenCount - 2))) }
        report.draftMs += (Date.timeIntervalSinceReferenceDate - started) * 1000
        guard !draft.isEmpty else { return emit(current) }
        // Verificação logo atrás do passo normal. Slots do MambaCache = estado depois de `current` (ainda preguiçoso).
        let mamba = cache.enumerated().compactMap { i, c -> (Int, MLXArray?, MLXArray?)? in
            (c as? MambaCache).map { (i, $0[0], $0[1]) }
        }
        let picks = argmax(forward(MLXArray(draft.map(Int32.init)))[0])
        asyncEval(picks)
        verify = (draft, y, picks, mamba)
        report.verifyPasses += 1
        report.proposed += draft.count
        return emit(current)
    }

    /// Aceita o prefixo do rascunho que o modelo confirma; desfaz o resto.
    private mutating func resolve() {
        guard let v = verify else { return }
        verify = nil
        let started = Date.timeIntervalSinceReferenceDate
        let first = v.first.item(Int.self)
        let picks = v.picks.asArray(Int.self)
        report.waitMs += (Date.timeIntervalSinceReferenceDate - started) * 1000
        let k = v.draft.count
        var accepted = 0
        if first == v.draft[0] {
            accepted = 1
            while accepted < k, picks[accepted - 1] == v.draft[accepted] { accepted += 1 }
        }
        report.accepted += accepted
        if accepted == k {
            report.fullAccepts += 1
            y = MLXArray(Int32(picks[k - 1]))
        } else {
            for c in cache where !(c is MambaCache) { _ = c.trim(k - accepted) }
            for (i, conv, ssm) in v.mamba {
                let m = cache[i] as! MambaCache
                m[0] = conv
                m[1] = ssm
            }
            if accepted == 0 {
                y = MLXArray(Int32(first))
            } else {
                y = argmax(forward(MLXArray(v.draft.prefix(accepted).map(Int32.init)))[0, -1])
                asyncEval(y)
                report.refeeds += 1
                report.refeedTokens += accepted
            }
        }
        pending = Array(v.draft.prefix(accepted))
    }

    private mutating func emit(_ token: Int) -> Int {
        generated.append(token)
        tokenCount += 1
        return token
    }

    static func selfCheck() {
        // Só a gramática (sem modelo): continuações a partir de texto parcial.
        let g = ToolCallGrammar(functions: [
            "book_flight": (["access_token", "card_id", "travel_cost"], ["access_token", "card_id"]),
            "get_user": (["user"], ["user"]), "get_user_id": (["user"], ["user"]), "list_all_airports": ([], []),
        ])
        precondition(g.continuation("<tool_call>") == "\n<function=")
        precondition(g.continuation("<tool_call>\n<function=bo") == "ok_flight>\n")
        precondition(g.continuation("<tool_call>\n<function=get_user") == "")  // get_user / get_user_id
        precondition(g.continuation("<tool_call>\n<function=get_user_") == "id>\n")
        precondition(g.continuation("<tool_call>\n<function=book_flight>\n") == "<parameter=")
        precondition(g.continuation("<tool_call>\n<function=book_flight>\n<parameter=car") == "d_id>\n")
        precondition(g.continuation("<tool_call>\n<function=book_flight>\n<parameter=card_id>\nc_1\n</") == "parameter>\n")
        let two = "<tool_call>\n<function=book_flight>\n<parameter=card_id>\nc_1\n</parameter>\n"
        precondition(g.continuation(two) == "<parameter=")  // access_token obrigatório falta
        let all = two + "<parameter=access_token>\nabc\n</parameter>\n"
        precondition(g.continuation(all) == "")  // travel_cost opcional: o modelo decide
        precondition(g.continuation(all + "</") == "function>\n</tool_call>")
        precondition(g.continuation(two + "<") == "parameter=")
        precondition(g.continuation("<tool_call>\n<function=list_all_airports>\n") == "</function>\n</tool_call>")
        precondition(g.continuation("<tool_call>\n<function=nope>\n") == "")
        precondition(g.continuation(all + "<parameter=travel_cost>\n12") == "")  // valor: livre
    }
}

extension ToolCallGrammar {
    /// Só para o self-check.
    init(functions: [String: (all: [String], required: [String])]) {
        self.functions = functions
        callOpen = -1
        callClose = -2
        thinkClose = nil
    }
}
