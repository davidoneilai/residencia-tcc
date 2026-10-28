import Foundation

/// Subconjunto do BFCL v4 (gorilla): 5 primeiros IDs de `simple_python`, `multiple`,
/// `parallel` e `parallel_multiple`. O checker local aplica a allow-list do
/// `possible_answer`, trata `""` como argumento opcional e não exige ordem em
/// `parallel` / `parallel_multiple`. Não é o `ast_checker` Python: não cobre
/// multi-turn, relevance, Java/JS nem toda a coerção de tipos oficial.
struct BFCLTask: Equatable {
    var id: String
    var category: String
    var question: String
    var functions: [BFCLFunction]
    var groundTruth: [BFCLCall]
}

struct BFCLFunction: Equatable {
    var name: String
    var summary: String
    var parameters: [ToolParameter]
}

struct BFCLCall: Equatable {
    var name: String
    var arguments: [String: [BFCLAccept]]
}

enum BFCLAccept: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case list([BFCLAccept])
    /// `""` na allow-list do BFCL: o argumento pode faltar.
    case optional
}

enum BFCLSubset {
    nonisolated(unsafe) static var fileOverride: URL?

    static func load() throws -> [BFCLTask] {
        let data: Data
        if let fileOverride {
            data = try Data(contentsOf: fileOverride)
        } else if let bundled = Bundle.main.url(forResource: "BFCLSubset", withExtension: "json") {
            data = try Data(contentsOf: bundled)
        } else {
            throw BenchError.failed("BFCLSubset.json não está no bundle.")
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = root?["tasks"] as? [[String: Any]] ?? []
        return try rows.map(parse)
    }

    static func task(_ id: String, in tasks: [BFCLTask]) -> BFCLTask? {
        tasks.first { $0.id == id }
    }

    private static func parse(_ row: [String: Any]) throws -> BFCLTask {
        guard let id = row["id"] as? String,
              let category = row["category"] as? String,
              let question = row["question"] as? String,
              let functions = row["function"] as? [[String: Any]],
              let ground = row["ground_truth"] as? [[String: Any]] else {
            throw BenchError.failed("Tarefa BFCL incompleta.")
        }
        return BFCLTask(
            id: id, category: category, question: question,
            functions: functions.map(parseFunction),
            groundTruth: ground.map(parseCall))
    }

    private static func parseFunction(_ raw: [String: Any]) -> BFCLFunction {
        let name = raw["name"] as? String ?? ""
        let summary = raw["description"] as? String ?? ""
        let parameters = raw["parameters"] as? [String: Any] ?? [:]
        let properties = parameters["properties"] as? [String: Any] ?? [:]
        let required = Set(parameters["required"] as? [String] ?? [])
        let fields = properties.keys.sorted().map { key in
            let schema = properties[key] as? [String: Any] ?? [:]
            let type = schema["type"] as? String ?? "string"
            let detail = schema["description"] as? String ?? ""
            return ToolParameter(name: key, type: type, detail: detail, required: required.contains(key))
        }
        return BFCLFunction(name: name, summary: summary, parameters: fields)
    }

    private static func parseCall(_ raw: [String: Any]) -> BFCLCall {
        let name = raw.keys.first ?? ""
        let arguments = raw[name] as? [String: Any] ?? [:]
        var parsed: [String: [BFCLAccept]] = [:]
        for (key, value) in arguments {
            let list = value as? [Any] ?? []
            parsed[key] = list.map(parseAccept)
        }
        return BFCLCall(name: name, arguments: parsed)
    }

    private static func parseAccept(_ value: Any) -> BFCLAccept {
        if let text = value as? String {
            return text.isEmpty ? .optional : .string(text)
        }
        if let list = value as? [Any] { return .list(list.map(parseAccept)) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            if double.rounded() != double { return .double(double) }
            return .int(number.intValue)
        }
        return .string(String(describing: value))
    }
}

enum BFCLChecker {
    static func grade(_ task: BFCLTask, calls: [ToolCallRecord]?) -> GradeReport {
        guard let calls else {
            var report = GradeReport()
            report.selectionReason = "trajetória não observada"
            report.argumentsReason = "trajetória não observada"
            report.sequenceReason = parallel(task) ? "BFCL parallel não exige ordem" : "trajetória não observada"
            return report
        }
        var report = GradeReport()
        let ordered = !parallel(task)
        var used = Set<Int>()
        var argumentFailure: String?
        for spec in task.groundTruth {
            guard let index = calls.indices.first(where: { !used.contains($0) && matches(calls[$0], spec) }) else {
                argumentFailure = argumentFailure ?? "chamada \(spec.name) não bate com a allow-list do BFCL"
                continue
            }
            used.insert(index)
        }
        let expectedNames = task.groundTruth.map(\.name)
        var expectedCount: [String: Int] = [:]
        for name in expectedNames { expectedCount[name, default: 0] += 1 }
        var actualCount: [String: Int] = [:]
        for call in calls { actualCount[call.tool, default: 0] += 1 }
        var duplicates = 0
        var invalid = 0
        for (name, count) in actualCount {
            let expected = expectedCount[name] ?? 0
            if expected == 0 { invalid += count }
            else { duplicates += max(0, count - expected) }
        }
        report.duplicateToolCalls = duplicates
        report.invalidToolCalls = invalid
        report.toolSelectionCorrect = Set(calls.map(\.tool)) == Set(expectedNames)
            && expectedNames.allSatisfy { actualCount[$0, default: 0] > 0 }
        if report.toolSelectionCorrect != true {
            report.selectionReason = "ferramentas BFCL \(calls.map(\.tool)) em vez de \(expectedNames)"
        }
        report.toolArgumentsCorrect = argumentFailure == nil && used.count == task.groundTruth.count
        report.argumentsReason = report.toolArgumentsCorrect == true ? nil : argumentFailure
        if ordered {
            report.toolSequenceCorrect = calls.map(\.tool) == expectedNames
            if report.toolSequenceCorrect != true { report.sequenceReason = "ordem diferente da allow-list" }
        } else {
            report.toolSequenceCorrect = nil
            report.sequenceReason = "BFCL parallel não exige ordem"
        }
        report.completionCorrect = report.toolArgumentsCorrect == true && duplicates == 0 && invalid == 0
        if report.completionCorrect != true { report.completionReason = "a chamada BFCL não cobre o ground truth" }
        report.taskSuccess = report.toolSelectionCorrect == true
            && report.toolArgumentsCorrect == true
            && report.toolSequenceCorrect != false
            && duplicates == 0
            && invalid == 0
        return report
    }

    static func foreignTools(_ task: BFCLTask) -> [ForeignTool] {
        task.functions.map { function in
            ForeignTool(id: function.name, toolDescription: function.summary, parameters: function.parameters)
        }
    }

    private static func parallel(_ task: BFCLTask) -> Bool {
        task.category == "parallel" || task.category == "parallel_multiple"
    }

    private static func matches(_ call: ToolCallRecord, _ spec: BFCLCall) -> Bool {
        guard call.tool == spec.name, call.error == nil else { return false }
        for key in call.arguments.keys where spec.arguments[key] == nil { return false }
        for (key, accepted) in spec.arguments {
            let optional = accepted.contains { if case .optional = $0 { return true }; return false }
            guard let actual = call.arguments[key] else {
                if optional { continue }
                return false
            }
            let options = accepted.filter { if case .optional = $0 { return false }; return true }
            guard options.contains(where: { accepts($0, actual) }) else { return false }
        }
        return true
    }

    private static func accepts(_ option: BFCLAccept, _ actual: ToolValue) -> Bool {
        switch option {
        case .optional: return false
        case .string(let value): return actual.text == value
        case .int(let value): return actual.intValue == value
        case .double(let value): return actual.intValue == Int(value) || actual.text == String(value)
        case .bool(let value):
            if case .bool(let flag) = actual { return flag == value }
            return actual.text == (value ? "true" : "false")
        case .list(let values):
            guard case .list(let actualValues) = actual, actualValues.count == values.count else { return false }
            return zip(values, actualValues).allSatisfy { accepts($0.0, $0.1) }
        }
    }
}

struct ForeignTool: AgentTool, Sendable {
    var id: String
    var toolDescription: String
    var parameters: [ToolParameter]
    var sideEffect: Bool { false }

    func validate(arguments: [String: ToolValue]) throws {}

    func execute(arguments: [String: ToolValue], context: ToolExecutionContext) async throws -> ToolResult {
        ToolResult(output: "ok", values: arguments)
    }
}
