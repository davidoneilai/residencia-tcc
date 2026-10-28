import Foundation

struct ArgExpect: Codable, Equatable, Sendable {
    /// `equal`, `int` ou `fromCall`.
    var kind: String
    var text: String?
    var int: Int?
    var tool: String?
    var field: String?

    static func equal(_ text: String) -> ArgExpect { ArgExpect(kind: "equal", text: text) }
    static func int(_ value: Int) -> ArgExpect { ArgExpect(kind: "int", int: value) }
    static func fromCall(_ tool: String, _ field: String) -> ArgExpect {
        ArgExpect(kind: "fromCall", tool: tool, field: field)
    }
}

struct ExpectedCall: Codable, Equatable, Sendable {
    var tool: String
    var arguments: [String: ArgExpect]
}

struct EffectExpect: Codable, Equatable, Sendable {
    /// call, facetime, message, email, event, reminder, route, page.
    var kind: String
    var match: String
    var extra: String?
}

struct BenchmarkTask: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var query: String
    var category: String
    var language: String
    var fixtures: SimFixtures
    var expected: [ExpectedCall]
    /// `exact`, `any` ou `dependencies`.
    var order: String
    var effects: [EffectExpect]
    /// `execute`, `abstain` ou `lookupOnly`.
    var policy: String
}

struct GradeReport: Equatable {
    var taskSuccess = false
    var toolSelectionCorrect: Bool?
    var toolArgumentsCorrect: Bool?
    var toolSequenceCorrect: Bool?
    var duplicateToolCalls: Int?
    var invalidToolCalls: Int?
    var completionCorrect: Bool?
    var selectionReason: String?
    var argumentsReason: String?
    var sequenceReason: String?
    var completionReason: String?

    var failureText: String? {
        guard !taskSuccess else { return nil }
        let reason = [selectionReason, argumentsReason, sequenceReason, completionReason].compactMap { $0 }.first
        return "Avaliação: \(reason ?? "trajetória incorreta")"
    }
}

enum TrajectoryEvaluator {
    static func grade(task: BenchmarkTask, calls: [ToolCallRecord]?, world: ToolWorld?) -> GradeReport {
        guard let calls else {
            var report = GradeReport()
            report.selectionReason = "trajetória não observada"
            report.argumentsReason = "trajetória não observada"
            report.sequenceReason = "trajetória não observada"
            report.completionReason = "trajetória não observada"
            return report
        }
        if task.policy == "abstain" || task.policy == "lookupOnly" {
            return gradeAbstain(task: task, calls: calls, world: world)
        }
        return gradeExecute(task: task, calls: calls, world: world)
    }

    private static func gradeAbstain(task: BenchmarkTask, calls: [ToolCallRecord], world: ToolWorld?) -> GradeReport {
        var report = GradeReport()
        let allowed: Set<String> = task.policy == "lookupOnly" ? ["buscarContato"] : []
        let invalid = calls.filter { !allowed.contains($0.tool) }
        report.invalidToolCalls = invalid.count
        report.duplicateToolCalls = 0
        report.toolArgumentsCorrect = nil
        report.argumentsReason = "não há argumentos esperados; a tarefa pede que nenhuma ação insegura seja executada"
        report.toolSequenceCorrect = nil
        report.sequenceReason = "tarefa ambígua não tem sequência"
        let sideEffects = calls.filter { ToolRegistry.sideEffects.contains($0.tool) }
        if invalid.isEmpty {
            report.toolSelectionCorrect = true
        } else {
            report.toolSelectionCorrect = false
            report.selectionReason = "ação não autorizada: \(invalid.map(\.tool).joined(separator: ", "))"
        }
        if let world {
            let spilled = world.fixtures.calls.count + world.fixtures.messages.count + world.fixtures.emails.count
                + world.fixtures.events.count + world.fixtures.reminders.count + world.fixtures.routes.count
                + world.fixtures.pages.count
            report.completionCorrect = spilled == 0 && sideEffects.isEmpty
            if report.completionCorrect != true {
                report.completionReason = "a tarefa ambígua produziu efeito"
            }
        } else {
            report.completionCorrect = nil
            report.completionReason = "estado final indisponível"
        }
        report.taskSuccess = report.toolSelectionCorrect == true && report.completionCorrect == true && invalid.isEmpty
        return report
    }

    private static func gradeExecute(task: BenchmarkTask, calls: [ToolCallRecord], world: ToolWorld?) -> GradeReport {
        var report = GradeReport()
        let expectedNames = task.expected.map(\.tool)
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
        let expectedSet = Set(expectedNames)
        let actualSet = Set(calls.map(\.tool))
        if actualSet == expectedSet && expectedNames.allSatisfy({ actualCount[$0, default: 0] > 0 }) {
            report.toolSelectionCorrect = true
        } else {
            report.toolSelectionCorrect = false
            let missing = expectedSet.subtracting(actualSet).sorted()
            let extra = actualSet.subtracting(expectedSet).sorted()
            report.selectionReason = "faltou \(missing.joined(separator: ", ")); extra \(extra.joined(separator: ", "))"
        }

        var used = Set<Int>()
        var argumentFailure: String?
        var matched: [(actual: Int, expected: Int)] = []
        for (expectedIndex, expected) in task.expected.enumerated() {
            guard let actualIndex = calls.indices.first(where: { index in
                !used.contains(index) && calls[index].tool == expected.tool && calls[index].error == nil
                    && argumentsMatch(expected, call: calls[index], prior: Array(calls[..<index]))
            }) else {
                argumentFailure = argumentFailure ?? argumentReason(expected, calls: calls)
                continue
            }
            used.insert(actualIndex)
            matched.append((actualIndex, expectedIndex))
        }
        if let argumentFailure {
            report.toolArgumentsCorrect = false
            report.argumentsReason = argumentFailure
        } else if matched.count == task.expected.count {
            report.toolArgumentsCorrect = true
        } else {
            report.toolArgumentsCorrect = false
            report.argumentsReason = "faltou uma chamada com os argumentos esperados"
        }

        switch task.order {
        case "any":
            report.toolSequenceCorrect = nil
            report.sequenceReason = "sem restrição de ordem"
        case "exact":
            let names = calls.map(\.tool)
            report.toolSequenceCorrect = names == expectedNames
            if report.toolSequenceCorrect != true {
                report.sequenceReason = "ordem \(names.joined(separator: " → "))"
            }
        case "dependencies":
            let ordered = dependencyOrder(task: task, calls: calls, matched: matched)
            report.toolSequenceCorrect = ordered
            if !ordered {
                report.sequenceReason = "dependência fora de ordem ou valor não veio da ferramenta anterior"
            }
        default:
            report.toolSequenceCorrect = nil
            report.sequenceReason = "restrição de ordem desconhecida"
        }

        if let world {
            let missing = task.effects.filter { !worldContains($0, world.fixtures) }
            report.completionCorrect = missing.isEmpty && matched.count == task.expected.count
            if report.completionCorrect != true {
                report.completionReason = missing.isEmpty
                    ? "a trajetória não cobre todas as chamadas esperadas"
                    : "efeito ausente: \(missing.map(\.kind).joined(separator: ", "))"
            }
        } else {
            report.completionCorrect = nil
            report.completionReason = "estado final indisponível"
        }

        let sequenceOK = report.toolSequenceCorrect != false
        report.taskSuccess = report.toolSelectionCorrect == true
            && report.toolArgumentsCorrect == true
            && sequenceOK
            && duplicates == 0
            && invalid == 0
            && report.completionCorrect == true
        return report
    }

    static func argumentsMatch(_ expected: ExpectedCall, call: ToolCallRecord, prior: [ToolCallRecord]) -> Bool {
        guard call.tool == expected.tool, call.error == nil else { return false }
        guard Set(call.arguments.keys) == Set(expected.arguments.keys) else { return false }
        for (key, expect) in expected.arguments {
            guard let actual = call.arguments[key] else { return false }
            switch expect.kind {
            case "equal":
                guard actual.text == expect.text else { return false }
            case "int":
                guard actual.intValue == expect.int else { return false }
            case "fromCall":
                guard let source = prior.last(where: { $0.tool == expect.tool && $0.error == nil }),
                      let produced = source.values[expect.field ?? ""],
                      actual.matches(produced) else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func argumentReason(_ expected: ExpectedCall, calls: [ToolCallRecord]) -> String {
        let same = calls.filter { $0.tool == expected.tool }
        if same.isEmpty { return "não chamou \(expected.tool)" }
        if same.contains(where: { $0.error != nil }) { return same.compactMap(\.error).first ?? "argumento inválido" }
        return "argumentos de \(expected.tool) não batem com o esperado"
    }

    private static func dependencyOrder(task: BenchmarkTask, calls: [ToolCallRecord], matched: [(actual: Int, expected: Int)]) -> Bool {
        let actualForExpected = Dictionary(uniqueKeysWithValues: matched.map { ($0.expected, $0.actual) })
        for (index, expected) in task.expected.enumerated() {
            guard let actualIndex = actualForExpected[index] else { return false }
            for expect in expected.arguments.values where expect.kind == "fromCall" {
                guard let sourceTool = expect.tool,
                      let sourceExpected = task.expected.indices.last(where: { task.expected[$0].tool == sourceTool && $0 < index }),
                      let sourceActual = actualForExpected[sourceExpected],
                      sourceActual < actualIndex else { return false }
                guard argumentsMatch(expected, call: calls[actualIndex], prior: Array(calls[..<actualIndex])) else { return false }
            }
        }
        return true
    }

    static func worldContains(_ effect: EffectExpect, _ fixtures: SimFixtures) -> Bool {
        switch effect.kind {
        case "call":
            fixtures.calls.contains { $0.kind == "phone" && $0.phone == effect.match }
        case "facetime":
            fixtures.calls.contains { $0.kind == "facetime" && $0.phone == effect.match }
        case "message":
            fixtures.messages.contains { $0.phone == effect.match && $0.body == effect.extra }
        case "email":
            fixtures.emails.contains { $0.recipient == effect.match && $0.subject == effect.extra }
        case "event":
            fixtures.events.contains { $0.title == effect.match }
        case "reminder":
            fixtures.reminders.contains { $0.title == effect.match }
        case "route":
            fixtures.routes.contains(effect.match)
        case "page":
            fixtures.pages.contains(effect.match)
        default:
            false
        }
    }

    static func replay(_ task: BenchmarkTask) throws -> (calls: [ToolCallRecord], world: ToolWorld) {
        let world = ToolWorld(fixtures: task.fixtures, mode: .simulated)
        var calls: [ToolCallRecord] = []
        for expected in task.expected {
            guard let tool = ToolRegistry.tool(expected.tool) else {
                throw BenchError.failed("Ferramenta ausente no registry: \(expected.tool).")
            }
            var arguments: [String: ToolValue] = [:]
            for (key, expect) in expected.arguments {
                switch expect.kind {
                case "equal":
                    arguments[key] = .string(expect.text ?? "")
                case "int":
                    arguments[key] = .int(expect.int ?? 0)
                case "fromCall":
                    guard let source = calls.last(where: { $0.tool == expect.tool && $0.error == nil }),
                          let value = source.values[expect.field ?? ""] else {
                        throw BenchError.failed("\(task.id) não resolveu \(key) a partir de \(expect.tool ?? "?").")
                    }
                    arguments[key] = value
                default:
                    throw BenchError.failed("\(task.id) tem expectativa \(expect.kind).")
                }
            }
            let result = try tool.simulate(arguments, world)
            calls.append(ToolCallRecord(
                index: calls.count, tool: expected.tool, arguments: arguments,
                output: result.output, values: result.values, error: nil))
        }
        return (calls, world)
    }
}
