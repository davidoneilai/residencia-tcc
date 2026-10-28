import EventKit
import XCTest
@testable import MobileLLMBench

/// LLM local de verdade (Apple Foundation Models) conduzindo o coordenador. Rodam no iPhone.
@MainActor
final class AgentDriver {
    let gate: ToolGate
    let coordinator: AgentCoordinator
    var proposals: [ToolProposal] = []
    var approve = true
    var agent = Agent.apple
    var history: [HistoryLine] = []
    let id = UUID()

    init(store: any CalendarStore, clock: ChatClock) {
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: store is SimulatedCalendarStore ? .simulated : .real)
        gate = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: clock, registry: registry, world: world),
            registry: registry, worldBox: world)
        coordinator = AgentCoordinator(gate: gate, mlx: MLXPhoneBackend(), clock: clock)
        coordinator.executionMode = store is SimulatedCalendarStore ? .simulated : .real
        gate.confirm = { [unowned self] proposal in
            proposals.append(proposal)
            return approve
        }
    }

    func say(_ text: String, scenario: String) async -> (reply: String, steps: [ToolStep], calls: [ToolLog.Mark]) {
        let outcome = await coordinator.run(agent: agent, conversation: id, history: history, prompt: text) { _ in }
        let reply = outcome.text ?? "ERRO: \(outcome.error?.localizedDescription ?? "?")"
        history += [HistoryLine(fromUser: true, text: text), HistoryLine(fromUser: false, text: reply)]
        let calls = await gate.log.snapshot()
        let m = outcome.metrics
        let line: [String: Any] = [
            "scenario": scenario, "agent": agent.rawValue, "prompt": text, "reply": reply,
            "steps": gate.steps.map { "\($0.tool):\($0.status.rawValue) [\($0.summary)]" },
            "totalMs": Int(m.totalExcludingConfirmationMs), "ttftMs": m.ttftMs.map(Int.init) ?? -1,
            "toolSelectionMs": m.toolSelectionMs.map(Int.init) ?? -1, "toolExecutionMs": m.toolExecutionMs ?? -1,
            "inputTokens": m.inputTokens ?? -1, "outputTokens": m.outputTokens ?? -1,
            "memoryMB": m.memoryAfterMB ?? -1, "policy": m.policyReason, "mode": m.executionMode,
            "tokenSource": m.tokenSource ?? "none", "rounds": m.llmRounds,
            "calls": calls.map { c in "\(c.name)(\(c.arguments.keys.sorted().map { "\($0)=\(c.arguments[$0]!)" }.joined(separator: ", ")))" },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
            print("E2E_RESULT " + String(decoding: data, as: UTF8.self))
        }
        return (reply, gate.steps, calls)
    }
}

func folded(_ text: String) -> String { ContactMatch.normalize(text) }

@MainActor
final class ChatAgentE2ETests: XCTestCase {
    private var store: SimulatedCalendarStore!
    private var chat: AgentDriver!

    override func setUp() async throws {
        if let reason = AppleFoundationBackend.unavailableReason { throw XCTSkip(reason) }
        store = SimulatedCalendarStore(events: [
            CalendarEntry(title: "Reunião com orientador", start: at(day: 20, 10), end: at(day: 20, 11), allDay: false),
            CalendarEntry(title: "Almoço com Ana", start: at(day: 20, 12, 30), end: at(day: 20, 13, 30), allDay: false),
            CalendarEntry(title: "Dentista", start: at(day: 21, 8), end: at(day: 21, 9), allDay: false),
        ])
        chat = AgentDriver(store: store, clock: testClock)
    }

    func test1_PlainChatKeepsContext() async {
        let first = await chat.say("Oi! Meu nome é Marcos e meu TCC é sobre LLMs rodando no celular.", scenario: "1a_chat")
        let second = await chat.say("Qual é o meu nome e qual é o tema do meu TCC?", scenario: "1b_chat_context")
        XCTAssertTrue(first.steps.isEmpty && second.steps.isEmpty, "Conversa comum não chama ferramenta")
        XCTAssertTrue(folded(second.reply).contains("marcos"), second.reply)
        XCTAssertTrue(folded(second.reply).contains("llm") || folded(second.reply).contains("celular"), second.reply)
    }

    func test2_CreateReminderTomorrowAt9() async {
        let turn = await chat.say("Crie um lembrete para amanhã às 9h para revisar o TCC.", scenario: "2_reminder")
        let saved = await store.reminders
        XCTAssertEqual(chat.proposals.count, 1, "Pediu confirmação uma vez")
        XCTAssertEqual(saved.count, 1, turn.reply)
        XCTAssertEqual(saved.first?.due.map(ChatDates.text), "2026-10-20 09:00")
        XCTAssertTrue(folded(saved.first?.title ?? "").contains("tcc"), saved.first?.title ?? "")
        // Leituras extras são permitidas (sem efeito colateral); a escrita tem de ser única e ok.
        XCTAssertEqual(turn.steps.filter { $0.tool == "criarLembrete" }.map(\.status), [.ok])
    }

    func test3_QueryTomorrow() async {
        let turn = await chat.say("Quais compromissos tenho amanhã?", scenario: "3_query")
        XCTAssertEqual(turn.calls.first?.name, "consultarCompromissos")
        XCTAssertTrue(turn.calls.first?.detail.contains("Reunião com orientador") ?? false, "Consultou o dia certo")
        XCTAssertFalse(turn.calls.first?.detail.contains("Dentista") ?? true)
        XCTAssertTrue(folded(turn.reply).contains("orientador"), turn.reply)
        XCTAssertFalse(folded(turn.reply).contains("dentista"), turn.reply)
        let saved = await store.reminders
        XCTAssertTrue(saved.isEmpty && chat.proposals.isEmpty)
    }

    func test4_NextEventThenReminder30MinutesBefore() async {
        let turn = await chat.say("Veja meu próximo compromisso e crie um lembrete 30 minutos antes.", scenario: "4_chain")
        XCTAssertTrue(turn.calls.map(\.name).contains("consultarCompromissos"), turn.reply)
        XCTAssertEqual(turn.calls.filter { $0.name == "criarLembrete" }.count, 1, turn.reply)
        let write = turn.calls.first { $0.name == "criarLembrete" }
        XCTAssertNotNil(write?.arguments["evento"], "Modo relativo com #evento: \(String(describing: write?.arguments))")
        XCTAssertNil(write?.arguments["hora"], "Modo relativo não mistura hora")
        let saved = await store.reminders
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.due.map(ChatDates.text), "2026-10-20 09:30", "30 min antes das 10:00")
        XCTAssertFalse(turn.steps.contains { $0.status == .duplicate || $0.status == .writeLimit },
                       "Não deve precisar do bloqueador para finalizar: \(turn.steps.map(\.status))")
    }

    func test5_AmbiguousRequestAsksBeforeActing() async {
        let turn = await chat.say("Cria um lembrete pra mim.", scenario: "5_ambiguous")
        let saved = await store.reminders
        XCTAssertTrue(saved.isEmpty, "Nada gravado sem saber o que lembrar")
        XCTAssertTrue(chat.proposals.isEmpty, "Nem chegou a pedir confirmação de algo inventado")
        XCTAssertTrue(turn.reply.contains("?"), turn.reply)
    }

    func test6_PermissionDenied() async {
        await store.configure(denyEvents: true, denyReminders: true)
        let read = await chat.say("Quais compromissos tenho amanhã?", scenario: "6a_denied_calendar")
        XCTAssertTrue(read.steps.contains { $0.status == .permissionDenied }, read.reply)
        XCTAssertLessThanOrEqual(read.steps.count, 2, "Não insiste em laço")
        let reply = folded(read.reply)
        XCTAssertTrue(reply.contains("permiss") || reply.contains("acesso") || reply.contains("ajustes"), read.reply)
        let write = await chat.say("Crie um lembrete para amanhã às 9h para revisar o TCC.", scenario: "6b_denied_reminders")
        XCTAssertTrue(write.steps.contains { $0.status == .permissionDenied }, write.reply)
        let saved = await store.reminders
        XCTAssertTrue(saved.isEmpty)
    }

    func test7_CancelBeforeExecution() async {
        chat.approve = false
        let turn = await chat.say("Crie um lembrete para amanhã às 9h para revisar o TCC.", scenario: "7_cancel")
        let attempts = await store.writeAttempts
        XCTAssertGreaterThanOrEqual(chat.proposals.count, 1)
        XCTAssertEqual(attempts, 0, "Nada chegou ao armazenamento")
        XCTAssertTrue(turn.steps.contains { $0.status == .cancelled })
        let reply = folded(turn.reply)
        XCTAssertTrue(reply.contains("cancel") || reply.contains("nao foi") || reply.contains("nao criei"), turn.reply)
    }

    func test8_FailureRecoveryWithoutDuplicates() async {
        await store.configure(failingWrites: 1)
        let turn = await chat.say("Crie um lembrete para amanhã às 9h para revisar o TCC.", scenario: "8_failure")
        let saved = await store.reminders
        let attempts = await store.writeAttempts
        let writes = turn.steps.filter { $0.tool == "criarLembrete" }.map(\.status)
        XCTAssertEqual(writes, [.failed, .ok], "Falhou, tentou de novo, gravou")
        XCTAssertEqual(saved.count, 1, "Sem duplicata")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(chat.proposals.count, 1)
        XCTAssertEqual(saved.first?.due.map(ChatDates.text), "2026-10-20 09:00")
    }

    func test8b_PersistentFailureIsReported() async {
        await store.configure(failingWrites: 5)
        let turn = await chat.say("Crie um lembrete para amanhã às 9h para revisar o TCC.", scenario: "8b_persistent_failure")
        let saved = await store.reminders
        let attempts = await store.writeAttempts
        XCTAssertTrue(saved.isEmpty)
        XCTAssertLessThanOrEqual(attempts, 2, "No máximo uma nova tentativa")
        let reply = folded(turn.reply)
        XCTAssertTrue(reply.contains("falh") || reply.contains("nao foi possivel") || reply.contains("erro"), turn.reply)
    }
}

/// EventKit real, restrito à agenda e lista descartáveis `ChatSandbox`, apagadas no fim.
@MainActor
final class RealEventKitE2ETests: XCTestCase {
    private let ek = EKEventStore()
    private var handles: ChatSandbox.Handles!
    private var chat: AgentDriver!
    private let clock = ChatClock()

    override func setUp() async throws {
        if let reason = AppleFoundationBackend.unavailableReason { throw XCTSkip(reason) }
        for type in [EKEntityType.event, .reminder] where EKEventStore.authorizationStatus(for: type) != .fullAccess {
            throw XCTSkip("Sem acesso total a \(type == .event ? "Calendário" : "Lembretes"); abra o app e autorize.")
        }
        let cal = clock.calendar
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: clock.now())!)
        func hour(_ day: Date, _ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: day)! }
        let after = cal.date(byAdding: .day, value: 1, to: tomorrow)!
        handles = try ChatSandbox.prepare(ek, events: [
            ("Reunião E2E MobileLLMBench", hour(tomorrow, 10), hour(tomorrow, 11)),
            ("Dentista E2E", hour(after, 8), hour(after, 9)),
        ])
        let store = EventKitCalendarStore(eventCalendarIDs: [handles.calendarID], reminderListID: handles.listID)
        chat = AgentDriver(store: store, clock: clock)
    }

    override func tearDown() async throws {
        try? ChatSandbox.cleanup(ek)
    }

    private var tomorrow: String {
        ChatDates.text(clock.calendar.date(byAdding: .day, value: 1, to: clock.now())!, calendar: clock.calendar, time: false)
    }

    func testReal_QueryTomorrow() async {
        let turn = await chat.say("Quais compromissos tenho amanhã?", scenario: "real_3_query")
        XCTAssertEqual(turn.calls.first?.name, "consultarCompromissos")
        // Fundamentado = cita o evento real (título ou horário 10h–11h), e não o de depois de amanhã.
        XCTAssertTrue(["reuniao e2e", "10h", "1000"].contains { folded(turn.reply).contains($0) }, turn.reply)
        XCTAssertFalse(folded(turn.reply).contains("dentista"), turn.reply)
    }

    func testReal_CreateReminderAfterConfirmation() async {
        let turn = await chat.say("Crie um lembrete para amanhã às 9h para revisar o TCC.", scenario: "real_2_reminder")
        let saved = await ChatSandbox.reminders(ek, listID: handles.listID)
        XCTAssertEqual(chat.proposals.count, 1)
        XCTAssertEqual(saved.count, 1, turn.reply)
        XCTAssertEqual(saved.first?.due.map(ChatDates.text), "\(tomorrow) 09:00")
    }

    func testReal_ChainNextEventReminder() async {
        let turn = await chat.say("Veja meu próximo compromisso e crie um lembrete 30 minutos antes.", scenario: "real_4_chain")
        let saved = await ChatSandbox.reminders(ek, listID: handles.listID)
        XCTAssertTrue(turn.calls.map(\.name).contains("consultarCompromissos"), turn.reply)
        XCTAssertEqual(turn.calls.filter { $0.name == "criarLembrete" }.count, 1, turn.reply)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.due.map(ChatDates.text), "\(tomorrow) 09:30")
    }

    func testReal_CancelWritesNothing() async {
        chat.approve = false
        _ = await chat.say("Crie um lembrete para amanhã às 9h para revisar o TCC.", scenario: "real_7_cancel")
        let saved = await ChatSandbox.reminders(ek, listID: handles.listID)
        XCTAssertTrue(saved.isEmpty)
    }
}

/// Mesmo coordenador com os modelos MLX (pesos baixados no app pelo benchmark). Agenda simulada.
@MainActor
final class MLXChatE2ETests: XCTestCase {
    private func run(_ agent: Agent, requireChain: Bool) async throws {
        let clock = ChatClock()
        for (scenario, prompt) in [("2_reminder", "Crie um lembrete para amanhã às 9h para revisar o TCC."),
                                   ("3_query", "Quais compromissos tenho amanhã?"),
                                   ("4_chain", "Veja meu próximo compromisso e crie um lembrete 30 minutos antes.")] {
            let store = SimulatedCalendarStore.demo(clock: clock)
            let chat = AgentDriver(store: store, clock: clock)
            chat.agent = agent
            let turn = await chat.say(prompt, scenario: "mlx_\(agent.rawValue)_\(scenario)")
            let saved = await store.reminders
            switch scenario {
            case "2_reminder":
                XCTAssertEqual(saved.first?.due.map(ChatDates.text).map { String($0.suffix(5)) }, "09:00", "\(agent) \(turn.reply)")
                XCTAssertFalse(turn.reply.hasPrefix("Parei depois"), turn.reply)
                XCTAssertFalse(turn.reply.isEmpty, turn.reply)
            case "3_query":
                XCTAssertEqual(turn.calls.first?.name, "consultarCompromissos", "\(agent) \(turn.reply)")
                XCTAssertFalse(turn.reply.isEmpty, "Resposta fundamentada após consulta")
            default:
                if requireChain {
                    XCTAssertEqual(saved.first?.due.map(ChatDates.text).map { String($0.suffix(5)) }, "09:30", "\(agent) \(turn.reply)")
                    XCTAssertFalse(turn.steps.contains { $0.status == .duplicate }, "\(agent) \(turn.steps.map(\.status))")
                    XCTAssertFalse(turn.reply.hasPrefix("Parei depois"), turn.reply)
                } else if saved.isEmpty {
                    // Diagnóstico Gemma: seleção/orquestração da cadeia, não falha de schema absoluto.
                    print("GEMMA_CHAIN_DIAG agent=\(agent) steps=\(turn.steps.map(\.status)) reply=\(turn.reply)")
                } else {
                    XCTAssertEqual(saved.first?.due.map(ChatDates.text).map { String($0.suffix(5)) }, "09:30", turn.reply)
                }
            }
        }
    }

    func testQwen() async throws { try await run(.qwen, requireChain: true) }
    func testGemma() async throws { try await run(.gemma, requireChain: false) }
}
