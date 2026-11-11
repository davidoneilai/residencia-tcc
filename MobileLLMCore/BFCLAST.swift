import Foundation

/// BFCL v4 AST de turno único (amostra congelada por `analysis/slm_bfcl/freeze_sample.py`).
/// A função vai crua ao template, como o handler OSS-FC oficial; a avaliação é o
/// `ast_checker` oficial no Mac. O app só gera e registra.
struct ASTTask: @unchecked Sendable {
    var id: String
    var category: String
    var messages: [[String: String]]
    var functions: [[String: Any]]

    var prompt: String { messages.last { $0["role"] == "user" }?["content"] ?? "" }

    var tools: [[String: any Sendable]] {
        functions.map { ["type": "function", "function": Self.sendable($0)] }
    }

    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let dict as [String: Any]: dict.mapValues(sendable) as [String: any Sendable]
        case let list as [Any]: list.map(sendable) as [any Sendable]
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { number.boolValue }
            else if number.doubleValue.rounded() == number.doubleValue { number.intValue }
            else { number.doubleValue }
        case let text as String: text
        default: String(describing: value)
        }
    }
}

enum ASTDataset {
    static let id = "bfcl_ast"

    /// Estudo SLM × AST (`BFCLv4AST`) + split Non-Live piloto/teste (`freeze_split.py`) + TESTE-2 (`freeze_test2.py`).
    /// IDs disjuntos por construção.
    static let tasks: [ASTTask] = ["BFCLv4AST", "BFCLv4NonLive", "BFCLv4NonLiveTest2"].flatMap(load)

    private static func load(_ resource: String) -> [ASTTask] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["tasks"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let category = row["category"] as? String,
                  let messages = row["messages"] as? [[String: String]],
                  let functions = row["function"] as? [[String: Any]] else { return nil }
            return ASTTask(id: id, category: category, messages: messages, functions: functions)
        }
    }

    static func task(_ id: String) -> ASTTask? { tasks.first { $0.id == id } }
}

/// Fixada antes da execução, sem olhar resultados do BFCL: pedido com várias funções
/// candidatas ou pistas de pedido múltiplo vai para a Direct (thinking completo);
/// o resto vai para a política rápida do modelo (NoThink, ou Budget64 sem switch).
enum ASTRouter {
    static let multiCues = [" and ", "respectively", " also ", ";", " as well as ", " both "]

    static func choose(_ task: ASTTask, agent: Agent) -> (strategy: Strategy, reason: String) {
        let lower = " " + task.prompt.lowercased() + " "
        let fast: Strategy = agent.thinkingSwitch ? .noThink : .budget64
        if task.functions.count >= 2 { return (.direct, "functions>=2") }
        if multiCues.contains(where: lower.contains) { return (.direct, "multi_cue") }
        return (fast, "single_request")
    }

    static func selfCheck() {
        let one = ASTTask(id: "t", category: "simple_python", messages: [["role": "user", "content": "Find x."]], functions: [[:]])
        precondition(choose(one, agent: .qwen35).strategy == .noThink)
        precondition(choose(one, agent: .lfm25).strategy == .budget64)
        var two = one
        two.messages = [["role": "user", "content": "Find x and y."]]
        precondition(choose(two, agent: .qwen35).strategy == .direct)
        two.functions = [[:], [:]]
        precondition(choose(two, agent: .gemma4).reason == "functions>=2")
    }
}

/// BFCL Non-Live, congelada no DEV antes do TESTE (`reports/bfcl-nonlive/FROZEN_POLICY.json`):
/// pedido com 64 code points ou mais → Direct (thinking completo, a "Reasoning"); senão NoThink (a "Direct").
/// Contagem em `unicodeScalars`, igual ao `len` do Python que escolheu o limiar.
enum NonLiveRouter {
    static let threshold = 64

    static func choose(_ task: ASTTask) -> (strategy: Strategy, reason: String) {
        let chars = task.prompt.unicodeScalars.count
        return chars >= threshold
            ? (.direct, "prompt_chars=\(chars)>=\(threshold)") : (.noThink, "prompt_chars=\(chars)<\(threshold)")
    }

    static func selfCheck() {
        let short = ASTTask(id: "t", category: "irrelevance", messages: [["role": "user", "content": "What is π?"]], functions: [])
        precondition(choose(short).strategy == .noThink)
        var long = short
        long.messages = [["role": "user", "content": String(repeating: "é", count: 64)]]
        precondition(choose(long).strategy == .direct)
    }
}
