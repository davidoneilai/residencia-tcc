import XCTest
@testable import MobileLLMBench

/// Conjunto de chat agêntico (simulado), separado do benchmark de 360 tarefas.
enum ChatBenchCategory: String, Codable {
    case noTool, singleQuery, singleReminder, sequential, ambiguous, confirmCancel, recovery
}

struct ChatBenchTask: Codable {
    var id: String
    var prompt: String
    var category: ChatBenchCategory
    /// Nomes esperados na ordem (subsequência das chamadas reais).
    var expectTools: [String]
    /// Se true, nenhuma ferramenta.
    var expectNoTools = false
    /// Horário final do lembrete (sufixo HH:mm), se houver escrita.
    var expectDueSuffix: String?
    /// Deve pedir confirmação (proposta).
    var expectConfirmation = false
    /// Cancelar a confirmação.
    var denyWrite = false
    /// Falhas simuladas antes do sucesso (0 = limpo).
    var failingWrites = 0
}

enum ChatBenchCatalog {
    /// 40 solicitações inéditas em relação aos exemplos de desenvolvimento.
    static let tasks: [ChatBenchTask] = noTool + queries + reminders + sequential + ambiguous + control

    private static let noTool: [ChatBenchTask] = [
        .init(id: "nt01", prompt: "O que significa TCC em uma graduação?", category: .noTool, expectTools: [], expectNoTools: true),
        .init(id: "nt02", prompt: "Me explique em uma frase o que é um LLM local.", category: .noTool, expectTools: [], expectNoTools: true),
        .init(id: "nt03", prompt: "Qual a diferença entre Calendário e Lembretes no iPhone?", category: .noTool, expectTools: [], expectNoTools: true),
        .init(id: "nt04", prompt: "Estou estudando Swift. Sugira um tópico curto para hoje.", category: .noTool, expectTools: [], expectNoTools: true),
        .init(id: "nt05", prompt: "Bom dia! Como você pode me ajudar neste app?", category: .noTool, expectTools: [], expectNoTools: true),
        .init(id: "nt06", prompt: "Traduza para inglês: preciso revisar o relatório.", category: .noTool, expectTools: [], expectNoTools: true),
    ]

    private static let queries: [ChatBenchTask] = [
        .init(id: "q01", prompt: "O que tem na minha agenda amanhã?", category: .singleQuery, expectTools: ["consultarCompromissos"]),
        .init(id: "q02", prompt: "Lista meus compromissos de hoje.", category: .singleQuery, expectTools: ["consultarCompromissos"]),
        .init(id: "q03", prompt: "Tenho alguma reunião depois de amanhã?", category: .singleQuery, expectTools: ["consultarCompromissos"]),
        .init(id: "q04", prompt: "Quais eventos nos próximos dias?", category: .singleQuery, expectTools: ["consultarCompromissos"]),
        .init(id: "q05", prompt: "Mostra minha agenda desta semana.", category: .singleQuery, expectTools: ["consultarCompromissos"]),
        .init(id: "q06", prompt: "Tem compromisso na manhã de amanhã?", category: .singleQuery, expectTools: ["consultarCompromissos"]),
        .init(id: "q07", prompt: "Consulta o calendário para 2026-10-20.", category: .singleQuery, expectTools: ["consultarCompromissos"]),
        .init(id: "q08", prompt: "Há algo marcado para terça-feira que vem? Use a data se souber.", category: .singleQuery, expectTools: ["consultarCompromissos"]),
    ]

    private static let reminders: [ChatBenchTask] = [
        .init(id: "r01", prompt: "Crie um lembrete amanhã às 8h para pagar a conta de luz.", category: .singleReminder,
              expectTools: ["criarLembrete"], expectDueSuffix: "08:00", expectConfirmation: true),
        .init(id: "r02", prompt: "Me lembra de comprar café amanhã às 07:30.", category: .singleReminder,
              expectTools: ["criarLembrete"], expectDueSuffix: "07:30", expectConfirmation: true),
        .init(id: "r03", prompt: "Agende um lembrete para 2026-10-20 às 18:00: enviar slides.", category: .singleReminder,
              expectTools: ["criarLembrete"], expectDueSuffix: "18:00", expectConfirmation: true),
        .init(id: "r04", prompt: "Lembrete para amanhã 21h: carregar o celular.", category: .singleReminder,
              expectTools: ["criarLembrete"], expectDueSuffix: "21:00", expectConfirmation: true),
        .init(id: "r05", prompt: "Cria lembrete amanhã às 15:00 — ligar para a clínica.", category: .singleReminder,
              expectTools: ["criarLembrete"], expectDueSuffix: "15:00", expectConfirmation: true),
        .init(id: "r06", prompt: "Quero um lembrete às 10:00 de amanhã sobre a entrega do protótipo.", category: .singleReminder,
              expectTools: ["criarLembrete"], expectDueSuffix: "10:00", expectConfirmation: true),
        .init(id: "r07", prompt: "Marca lembrete para amanhã 12:00: almoço sem celular.", category: .singleReminder,
              expectTools: ["criarLembrete"], expectDueSuffix: "12:00", expectConfirmation: true),
        .init(id: "r08", prompt: "Crie lembrete amanhã 16:45 para revisar o código do chat.", category: .singleReminder,
              expectTools: ["criarLembrete"], expectDueSuffix: "16:45", expectConfirmation: true),
    ]

    private static let sequential: [ChatBenchTask] = [
        .init(id: "s01", prompt: "Veja o próximo compromisso e crie um lembrete 15 minutos antes.", category: .sequential,
              expectTools: ["consultarCompromissos", "criarLembrete"], expectDueSuffix: "09:45", expectConfirmation: true),
        .init(id: "s02", prompt: "Consulte amanhã e me avise com um lembrete 30 minutos antes do primeiro evento.", category: .sequential,
              expectTools: ["consultarCompromissos", "criarLembrete"], expectDueSuffix: "09:30", expectConfirmation: true),
        .init(id: "s03", prompt: "Olha a agenda de amanhã e cria lembrete 10 min antes da reunião com orientador.", category: .sequential,
              expectTools: ["consultarCompromissos", "criarLembrete"], expectDueSuffix: "09:50", expectConfirmation: true),
        .init(id: "s04", prompt: "Depois de ver meus compromissos de amanhã, lembre-me 45 minutos antes do almoço com Ana.", category: .sequential,
              expectTools: ["consultarCompromissos", "criarLembrete"], expectDueSuffix: "11:45", expectConfirmation: true),
        .init(id: "s05", prompt: "Qual o próximo evento? Em seguida, lembrete 20 minutos antes.", category: .sequential,
              expectTools: ["consultarCompromissos", "criarLembrete"], expectDueSuffix: "09:40", expectConfirmation: true),
        .init(id: "s06", prompt: "Consulta a agenda e cria lembrete 60 minutos antes do primeiro compromisso de amanhã.", category: .sequential,
              expectTools: ["consultarCompromissos", "criarLembrete"], expectDueSuffix: "09:00", expectConfirmation: true),
        .init(id: "s07", prompt: "Primeiro liste amanhã; depois lembrete 5 minutos antes da reunião.", category: .sequential,
              expectTools: ["consultarCompromissos", "criarLembrete"], expectDueSuffix: "09:55", expectConfirmation: true),
        .init(id: "s08", prompt: "Verifique o compromisso das 10h amanhã e lembre-me meia hora antes.", category: .sequential,
              expectTools: ["consultarCompromissos", "criarLembrete"], expectDueSuffix: "09:30", expectConfirmation: true),
    ]

    private static let ambiguous: [ChatBenchTask] = [
        .init(id: "a01", prompt: "Me cria um lembrete.", category: .ambiguous, expectTools: [], expectNoTools: true),
        .init(id: "a02", prompt: "Lembra eu de alguma coisa amanhã.", category: .ambiguous, expectTools: [], expectNoTools: true),
        .init(id: "a03", prompt: "Agenda isso pra mim.", category: .ambiguous, expectTools: [], expectNoTools: true),
        .init(id: "a04", prompt: "Faz um lembrete qualquer.", category: .ambiguous, expectTools: [], expectNoTools: true),
        .init(id: "a05", prompt: "Preciso que você me lembre de algo importante.", category: .ambiguous, expectTools: [], expectNoTools: true),
        .init(id: "a06", prompt: "Pode marcar um aviso?", category: .ambiguous, expectTools: [], expectNoTools: true),
    ]

    private static let control: [ChatBenchTask] = [
        .init(id: "c01", prompt: "Crie um lembrete amanhã às 11h para beber água.", category: .confirmCancel,
              expectTools: ["criarLembrete"], expectConfirmation: true, denyWrite: true),
        .init(id: "c02", prompt: "Lembrete amanhã 13:00: alongar.", category: .confirmCancel,
              expectTools: ["criarLembrete"], expectConfirmation: true, denyWrite: true),
        .init(id: "c03", prompt: "Crie lembrete amanhã 17:00 para salvar o relatório.", category: .recovery,
              expectTools: ["criarLembrete"], expectDueSuffix: "17:00", expectConfirmation: true, failingWrites: 1),
        .init(id: "c04", prompt: "Lembrete amanhã 19:30: desligar o Wi-Fi.", category: .recovery,
              expectTools: ["criarLembrete"], expectDueSuffix: "19:30", expectConfirmation: true, failingWrites: 1),
    ]
}

struct ChatBenchGrade: Codable {
    var toolOrderOK: Bool
    var noExtraWrite: Bool
    var dueOK: Bool
    var confirmationOK: Bool
    var outcomeOK: Bool
    var success: Bool
}

enum ChatBenchScorer {
    static func grade(task: ChatBenchTask, calls: [ToolLog.Mark], steps: [ToolStep],
                      proposals: Int, reminders: [ReminderEntry], denied: Bool) -> ChatBenchGrade {
        // Preferir `steps`: cancelamentos não passam pelo ToolLog de execução.
        let names = steps.map(\.tool)
        let toolOrderOK: Bool
        if task.expectNoTools {
            toolOrderOK = !steps.contains { $0.tool == "criarLembrete" && $0.status == .ok }
        } else {
            toolOrderOK = isSubsequence(task.expectTools, of: names)
        }
        let writes = steps.filter { $0.tool == "criarLembrete" && $0.status == .ok }.count
        let noExtraWrite = writes <= 1
        let dueOK: Bool
        if task.denyWrite {
            dueOK = reminders.isEmpty
        } else if let suffix = task.expectDueSuffix {
            dueOK = reminders.contains { $0.due.map(ChatDates.text)?.hasSuffix(suffix) == true }
        } else {
            dueOK = true
        }
        let confirmationOK = !task.expectConfirmation || proposals >= 1
        let outcomeOK: Bool
        if task.denyWrite {
            outcomeOK = steps.contains { $0.status == .cancelled } && reminders.isEmpty
        } else if task.expectNoTools {
            outcomeOK = writes == 0
        } else if task.failingWrites > 0 {
            // Recuperação: escrita verificada importa mais que o horário exato (modelo pode errar a hora).
            outcomeOK = writes == 1
        } else if task.expectDueSuffix != nil {
            outcomeOK = writes == 1 && dueOK
        } else {
            outcomeOK = toolOrderOK
        }
        let success = toolOrderOK && noExtraWrite && dueOK && confirmationOK && outcomeOK
        return ChatBenchGrade(toolOrderOK: toolOrderOK, noExtraWrite: noExtraWrite, dueOK: dueOK,
                              confirmationOK: confirmationOK, outcomeOK: outcomeOK, success: success)
    }

    private static func isSubsequence(_ needle: [String], of hay: [String]) -> Bool {
        guard !needle.isEmpty else { return true }
        var i = 0
        for name in hay where i < needle.count && name == needle[i] { i += 1 }
        return i == needle.count
    }
}

/// Piloto: Apple FM × políticas fixed_direct, fixed_plan_act e heurística chat. Store simulado.
@MainActor
final class ChatAdaptivePilotTests: XCTestCase {
    func testPilotMatrix() async throws {
        if let reason = AppleFoundationBackend.unavailableReason { throw XCTSkip(reason) }
        XCTAssertEqual(ChatBenchCatalog.tasks.count, 40)

        let policies: [(String, any InferencePolicy)] = [
            ("fixed_direct", FixedPolicy(strategy: .direct)),
            ("fixed_plan_act", FixedPolicy(strategy: .planAct)),
            ("heuristic_chat", ChatHeuristicPolicy()),
        ]

        var rows: [[String: Any]] = []
        var matrix: [String: [String: (Bool, Double)]] = [:]
        for task in ChatBenchCatalog.tasks {
            matrix[task.id] = [:]
            for (name, policy) in policies {
                let store = SimulatedCalendarStore.demo(clock: testClock)
                if task.failingWrites > 0 { await store.configure(failingWrites: task.failingWrites) }
                let registry = EventRegistry()
                let world = ChatWorldBox(mode: .simulated)
                let gate = ToolGate(
                    tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
                    registry: registry, worldBox: world)
                let coordinator = AgentCoordinator(gate: gate, mlx: MLXPhoneBackend(), clock: testClock)
                coordinator.executionMode = .simulated
                coordinator.policy = policy
                var proposals = 0
                gate.confirm = { _ in
                    proposals += 1
                    return !task.denyWrite
                }
                let outcome = await coordinator.run(
                    agent: .apple, conversation: UUID(), history: [], prompt: task.prompt) { _ in }
                let calls = await gate.log.snapshot()
                let saved = await store.reminders
                let grade = ChatBenchScorer.grade(
                    task: task, calls: calls, steps: gate.steps,
                    proposals: proposals, reminders: saved, denied: task.denyWrite)
                let latency = outcome.metrics.totalExcludingConfirmationMs
                matrix[task.id]![name] = (grade.success, latency)
                let line: [String: Any] = [
                    "task": task.id, "category": task.category.rawValue, "policy": name,
                    "success": grade.success, "latencyMs": Int(latency),
                    "ttftMs": outcome.metrics.ttftMs.map(Int.init) ?? -1,
                    "toolSelectionMs": outcome.metrics.toolSelectionMs.map(Int.init) ?? -1,
                    "toolExecutionMs": outcome.metrics.toolExecutionMs ?? -1,
                    "routerMs": outcome.metrics.routerDecisionMs,
                    "policyReason": outcome.metrics.policyReason,
                    "actions": outcome.metrics.actions,
                    "toolOrderOK": grade.toolOrderOK, "dueOK": grade.dueOK, "noExtraWrite": grade.noExtraWrite,
                ]
                rows.append(line)
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print("CHAT_BENCH " + text)
                }
            }
        }

        // Resumo: melhor fixa, oracle, heurística
        let policyNames = policies.map(\.0)
        var fixedBest = ""
        var fixedBestScore = (-1.0, Double.infinity)
        for name in policyNames where name.hasPrefix("fixed_") {
            let vals = matrix.values.compactMap { $0[name] }
            let rate = Double(vals.filter(\.0).count) / Double(vals.count)
            let lat = vals.map(\.1).reduce(0, +)
            if rate > fixedBestScore.0 || (rate == fixedBestScore.0 && lat < fixedBestScore.1) {
                fixedBestScore = (rate, lat)
                fixedBest = name
            }
        }
        var oracleSuccess = 0
        var oracleLatency = 0.0
        var heuristicSuccess = 0
        var heuristicLatency = 0.0
        var potentialGain = 0.0
        for (_, pols) in matrix {
            let heuristic = pols["heuristic_chat"]!
            heuristicSuccess += heuristic.0 ? 1 : 0
            heuristicLatency += heuristic.1
            let ok = pols.filter { $0.value.0 }
            if let best = ok.min(by: { $0.value.1 < $1.value.1 }) {
                oracleSuccess += 1
                oracleLatency += best.value.1
                if let fixed = pols[fixedBest] {
                    potentialGain += max(0, fixed.1 - best.value.1)
                }
            } else if let fixed = pols[fixedBest] {
                oracleLatency += fixed.1
            }
        }
        let n = Double(ChatBenchCatalog.tasks.count)
        let summary: [String: Any] = [
            "n": ChatBenchCatalog.tasks.count,
            "fixedBest": fixedBest,
            "fixedSuccessRate": fixedBestScore.0,
            "fixedTotalLatencyMs": Int(fixedBestScore.1),
            "heuristicSuccessRate": Double(heuristicSuccess) / n,
            "heuristicTotalLatencyMs": Int(heuristicLatency),
            "oracleSuccessRate": Double(oracleSuccess) / n,
            "oracleTotalLatencyMs": Int(oracleLatency),
            "oracleLatencyGainVsFixedMs": Int(potentialGain),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            print("CHAT_BENCH_SUMMARY " + text)
        }
        // Critério mínimo: o piloto rodou e a melhor fixa tem sucesso > 0.
        XCTAssertGreaterThan(fixedBestScore.0, 0, "Piloto sem nenhum sucesso — ver logs CHAT_BENCH")
    }
}
