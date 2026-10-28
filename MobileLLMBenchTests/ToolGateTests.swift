import MLXLMCommon
import XCTest
@testable import MobileLLMBench

/// Relógio fixo: segunda, 2026-10-19 14:00 em São Paulo.
let testClock: ChatClock = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14))!
    return ChatClock(now: { now }, calendar: calendar)
}()

func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    testClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

@MainActor
final class ToolGateTests: XCTestCase {
    private var store: SimulatedCalendarStore!
    private var gate: ToolGate!
    private var proposals: [ToolProposal] = []
    private var approve = true
    private var picks: [String] = []
    private var pickResult: ProviderPick?
    private var logins = 0

    override func setUp() async throws {
        store = SimulatedCalendarStore(events: [
            CalendarEntry(title: "Reunião com orientador", start: at(day: 20, 10), end: at(day: 20, 11), allDay: false),
            CalendarEntry(title: "Dentista", start: at(day: 21, 8), end: at(day: 21, 9), allDay: false),
        ])
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated)
        gate = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world, maxCalls: 8, maxWritesPerTurn: 1)
        proposals = []
        approve = true
        picks = []
        pickResult = nil
        logins = 0
        ProviderPreference.save(nil)
        gate.providerRouter.savedPreference = nil
        gate.confirm = { [unowned self] proposal in
            proposals.append(proposal)
            return approve
        }
        gate.pickProvider = { [unowned self] summary in
            picks.append(summary)
            return pickResult
        }
        gate.requestGoogleSignIn = { [unowned self] _ in
            logins += 1
            return true
        }
    }

    override func tearDown() async throws {
        ProviderPreference.save(nil)
    }

    func testDates() throws {
        XCTAssertEqual(ChatDates.text(try ChatDates.day("amanhã", clock: testClock)), "2026-10-20")
        XCTAssertEqual(ChatDates.text(try ChatDates.day("2026-10-20", clock: testClock)), "2026-10-20")
        XCTAssertThrowsError(try ChatDates.day("2026-02-30", clock: testClock))
        XCTAssertThrowsError(try ChatDates.day("sexta que vem", clock: testClock))
        XCTAssertTrue(try ChatDates.time("9h") == (9, 0))
        XCTAssertTrue(try ChatDates.time("09:30") == (9, 30))
        XCTAssertTrue(try ChatDates.time("21h15") == (21, 15))
        XCTAssertThrowsError(try ChatDates.time("25:00"))
    }

    func testQueryUsesRequestedDayOnly() async throws {
        let output = try await gate.call("consultarCompromissos", ["data": .string("2026-10-20")])
        XCTAssertTrue(output.contains("#1. 2026-10-20 10:00 até 11:00 — Reunião com orientador"), output)
        XCTAssertFalse(output.contains("Dentista"), output)
        XCTAssertTrue(proposals.isEmpty, "Leitura não pede confirmação")
    }

    func testDaysCountIncludesStartDay() async throws {
        let two = try await gate.call("consultarCompromissos", ["data": .string("2026-10-20"), "dias": .int(2)])
        XCTAssertTrue(two.hasPrefix("Compromissos em 2026-10-20 a 2026-10-21"), two)
        XCTAssertTrue(two.contains("Dentista"), two)
        let bad = try await gate.call("consultarCompromissos", ["data": .string("2026-10-20"), "dias": .int(90)])
        XCTAssertTrue(bad.hasPrefix("ERRO DE ARGUMENTO"), bad)
    }

    func testAbsoluteReminderIgnoresGuesswork() async throws {
        _ = try await gate.call("criarLembrete", [
            "titulo": .string("Revisar"), "data": .string("2026-10-20"), "hora": .string("09:30"),
        ])
        XCTAssertEqual(proposals.map(\.summary), ["Criar lembrete “Revisar” para 2026-10-20 09:30"])
    }

    func testMixedRelativeJunkFallsBackToAbsoluteAndConfirms() async throws {
        // O modelo Apple às vezes manda data/hora e ainda preenche evento/minutosAntes=0.
        let output = try await gate.call("criarLembrete", [
            "titulo": .string("Reserva de reunião"),
            "data": .string("2026-10-22"),
            "hora": .string("09:00"),
            "evento": .int(15),
            "minutosAntes": .int(0),
        ])
        XCTAssertEqual(proposals.map(\.summary), ["Criar lembrete “Reserva de reunião” para 2026-10-22 09:00"])
        XCTAssertTrue(output.hasPrefix("Lembrete criado e conferido"), output)
        let saved = await store.reminders
        XCTAssertEqual(saved.first?.due.map(ChatDates.text), "2026-10-22 09:00")
    }

    func testRelativeReminderUsesStableEventID() async throws {
        let listed = try await gate.call("consultarCompromissos", ["data": .string("2026-10-20")])
        XCTAssertTrue(listed.contains("#1."), listed)
        _ = try await gate.call("criarLembrete", [
            "titulo": .string("Reunião"), "evento": .int(1), "minutosAntes": .int(30),
        ])
        XCTAssertEqual(proposals.map(\.summary), ["Criar lembrete “Reunião” para 2026-10-20 09:30"])
        let saved = await store.reminders
        XCTAssertEqual(saved.first?.due.map(ChatDates.text), "2026-10-20 09:30")
        // Segunda consulta não renumera #1.
        let again = try await gate.call("consultarCompromissos", ["data": .string("2026-10-21")])
        XCTAssertTrue(again.contains("#2."), again)
        XCTAssertTrue(again.contains("Dentista"), again)
        let stripped = try await gate.call("criarLembrete", [
            "titulo": .string("x"), "hora": .string("09:00"), "evento": .int(1), "minutosAntes": .int(30),
        ])
        // hora presente vira absoluto (hoje 09:00 já passou) ou, se passar, bate no limite de uma escrita.
        XCTAssertTrue(
            stripped.hasPrefix("LIMITE DE ESCRITA") || stripped.hasPrefix("Lembrete criado")
                || stripped.hasPrefix("ERRO DE ARGUMENTO"), stripped)
        let orphan = try await gate.call("criarLembrete", ["titulo": .string("x"), "minutosAntes": .int(30)])
        XCTAssertTrue(orphan.hasPrefix("ERRO DE ARGUMENTO"), orphan)
        let unknown = try await gate.call("criarLembrete", ["titulo": .string("x"), "evento": .int(99), "minutosAntes": .int(30)])
        XCTAssertTrue(unknown.hasPrefix("ERRO DE ARGUMENTO"), unknown)
    }

    func testTimezoneAffectsAbsolutePreview() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Manaus")! // UTC-4
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14))!
        let clock = ChatClock(now: { now }, calendar: calendar)
        let localStore = SimulatedCalendarStore(events: [
            CalendarEntry(title: "Call", start: calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))!,
                          end: calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 11))!, allDay: false),
        ])
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated)
        let localGate = ToolGate(
            tools: ChatToolCatalog.make(store: localStore, clock: clock, registry: registry, world: world),
            registry: registry, worldBox: world, maxWritesPerTurn: 1)
        var seen: [String] = []
        localGate.confirm = { seen.append($0.summary); return true }
        _ = try await localGate.call("criarLembrete", ["titulo": .string("X"), "data": .string("amanhã"), "hora": .string("9h")])
        XCTAssertEqual(seen, ["Criar lembrete “X” para 2026-10-20 09:00"])
        _ = try await localGate.call("consultarCompromissos", ["data": .string("amanhã")])
        // write limit: second write blocked
        let blocked = try await localGate.call("criarLembrete", ["titulo": .string("Y"), "evento": .int(1), "minutosAntes": .int(30)])
        XCTAssertTrue(blocked.hasPrefix("LIMITE DE ESCRITA"), blocked)
    }

    func testIdenticalQueryIsReusedThenStalls() async throws {
        let first = try await gate.call("consultarCompromissos", ["data": .string("2026-10-20")])
        let second = try await gate.call("consultarCompromissos", ["data": .string("2026-10-20")])
        let third = try await gate.call("consultarCompromissos", ["data": .string("2026-10-20")])
        XCTAssertTrue(first.contains("#1."), first)
        XCTAssertTrue(second.hasPrefix("REUTILIZADO"), second)
        XCTAssertTrue(third.hasPrefix("SEM PROGRESSO"), third)
        XCTAssertTrue(gate.stalled)
        XCTAssertEqual(gate.steps.map(\.status), [.ok, .reused, .stalled])
    }

    func testOneWritePerTurnThenBlocksFurtherWrites() async throws {
        _ = try await gate.call("criarLembrete", ["titulo": .string("A"), "data": .string("amanhã"), "hora": .string("9h")])
        let other = try await gate.call("criarLembrete", ["titulo": .string("B"), "data": .string("amanhã"), "hora": .string("10h")])
        XCTAssertTrue(other.hasPrefix("LIMITE DE ESCRITA"), other)
        XCTAssertTrue(gate.verifiedWriteSucceeded)
        let count = await store.reminders.count
        XCTAssertEqual(count, 1)
    }

    func testNoDatesMeansNextSevenDaysFromNow() async throws {
        let output = try await gate.call("consultarCompromissos", [:])
        XCTAssertTrue(output.hasPrefix("Compromissos em próximos 7 dias"), output)
        XCTAssertTrue(output.contains("#1. 2026-10-20 10:00"), output)
    }

    func testReminderNeedsConfirmationWithExactArguments() async throws {
        let output = try await gate.call("criarLembrete", [
            "titulo": .string("Revisar o TCC"), "data": .string("amanhã"), "hora": .string("9h"),
        ])
        XCTAssertEqual(proposals.map(\.summary), ["Criar lembrete “Revisar o TCC” para 2026-10-20 09:00"])
        XCTAssertTrue(output.hasPrefix("Lembrete criado e conferido"), output)
        let saved = await store.reminders
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.due.map(ChatDates.text), "2026-10-20 09:00")
    }

    func testCancelExecutesNothingAndIsNotAskedAgain() async throws {
        approve = false
        let args: [String: ToolValue] = ["titulo": .string("Revisar o TCC"), "data": .string("2026-10-20"), "hora": .string("09:00")]
        let first = try await gate.call("criarLembrete", args)
        let second = try await gate.call("criarLembrete", args)
        XCTAssertTrue(first.hasPrefix("CANCELADO"), first)
        XCTAssertTrue(second.hasPrefix("CANCELADO"), second)
        XCTAssertEqual(proposals.count, 1)
        let attempts = await store.writeAttempts
        XCTAssertEqual(attempts, 0)
    }

    func testSameSideEffectIsNotRepeatedEvenWithRelativeDate() async throws {
        _ = try await gate.call("criarLembrete", ["titulo": .string("Revisar o TCC"), "data": .string("2026-10-20"), "hora": .string("09:00")])
        let again = try await gate.call("criarLembrete", ["titulo": .string("Revisar o TCC"), "data": .string("amanhã"), "hora": .string("9h")])
        XCTAssertTrue(again.hasPrefix("LIMITE DE ESCRITA") || again.hasPrefix("JÁ EXECUTADO"), again)
        let count = await store.reminders.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(proposals.count, 1)
    }

    func testTransientFailureIsRetriedOnceWithoutDuplicates() async throws {
        await store.configure(failingWrites: 1)
        let args: [String: ToolValue] = ["titulo": .string("Revisar o TCC"), "data": .string("amanhã"), "hora": .string("9h")]
        let output = try await gate.call("criarLembrete", args)
        XCTAssertTrue(output.contains("na segunda tentativa"), output)
        XCTAssertEqual(gate.steps.map(\.status), [.failed, .ok])
        XCTAssertEqual(proposals.count, 1, "A nova tentativa não pede outra confirmação")
        let again = try await gate.call("criarLembrete", args)
        XCTAssertTrue(again.hasPrefix("LIMITE DE ESCRITA") || again.hasPrefix("JÁ EXECUTADO"), again)
        let (count, attempts) = (await store.reminders.count, await store.writeAttempts)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(attempts, 2)
    }

    func testPersistentFailureStopsAfterOneRetry() async throws {
        await store.configure(failingWrites: 5)
        let args: [String: ToolValue] = ["titulo": .string("Revisar o TCC"), "data": .string("amanhã"), "hora": .string("9h")]
        let failed = try await gate.call("criarLembrete", args)
        let blocked = try await gate.call("criarLembrete", args)
        XCTAssertTrue(failed.hasPrefix("FALHA"), failed)
        XCTAssertTrue(blocked.hasPrefix("FALHOU duas vezes"), blocked)
        let (count, attempts) = (await store.reminders.count, await store.writeAttempts)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(attempts, 2)
    }

    func testPermissionDeniedIsReported() async throws {
        await store.configure(denyEvents: true, denyReminders: true)
        let read = try await gate.call("consultarCompromissos", ["data": .string("amanhã")])
        let write = try await gate.call("criarLembrete", ["titulo": .string("x"), "data": .string("amanhã")])
        XCTAssertTrue(read.hasPrefix("SEM PERMISSÃO"), read)
        XCTAssertTrue(write.hasPrefix("SEM PERMISSÃO"), write)
        XCTAssertEqual(gate.steps.map(\.status), [.permissionDenied, .permissionDenied])
    }

    func testUnknownToolAndInvalidArguments() async throws {
        let unknown = try await gate.call("apagarTudo", [:])
        let missing = try await gate.call("criarLembrete", ["data": .string("amanhã")])
        let badDate = try await gate.call("criarLembrete", ["titulo": .string("x"), "data": .string("2026-13-40")])
        let past = try await gate.call("criarLembrete", ["titulo": .string("x"), "data": .string("hoje"), "hora": .string("08:00")])
        XCTAssertTrue(unknown.hasPrefix("ERRO: a ferramenta apagarTudo não existe"), unknown)
        XCTAssertTrue(missing.hasPrefix("ERRO DE ARGUMENTO"), missing)
        XCTAssertTrue(badDate.hasPrefix("ERRO DE ARGUMENTO"), badDate)
        XCTAssertTrue(past.contains("já passou"), past)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testCallLimitThenAbort() async throws {
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated)
        let tight = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world, maxCalls: 4)
        for day in [20, 21, 22, 23] {
            _ = try await tight.call("consultarCompromissos", ["data": .string("2026-10-\(day)")])
        }
        let limited = try await tight.call("consultarCompromissos", ["data": .string("2026-10-24")])
        XCTAssertTrue(limited.hasPrefix("LIMITE"), limited)
        _ = try await tight.call("consultarCompromissos", ["data": .string("2026-10-25")])
        do {
            _ = try await tight.call("consultarCompromissos", ["data": .string("2026-10-26")])
            XCTFail("Deveria interromper o laço")
        } catch {}
        tight.begin()
        let fresh = try await tight.call("consultarCompromissos", ["data": .string("2026-10-20")])
        XCTAssertFalse(fresh.hasPrefix("LIMITE"), "Limite é por tarefa")
        XCTAssertTrue(fresh.contains("#1."), "Registry reinicia no begin")
    }

    func testMetricsCarryNoConversationContent() throws {
        var record = ChatMetricsRecord(
            device: "x", osVersion: "y", agent: "apple", model: "m", backend: "b", executionMode: "simulated",
            policy: "direct", policyReason: "fixed_direct", routerDecisionMs: 0, thermalBefore: "nominal")
        record.actions = ["criarLembrete:ok"]
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains("TCC"))
        XCTAssertTrue(json.contains("criarLembrete:ok"))
    }

    func testThinkingIsHidden() {
        XCTAssertEqual(AgentCoordinator.hideThinking("<think>plano</think>\nOlá"), "Olá")
        XCTAssertEqual(AgentCoordinator.hideThinking("<think>ainda pensando"), "")
    }

    func testDigestSkipsBareCancel() {
        let history = [
            HistoryLine(fromUser: true, text: "Marca um meet com a julia amanha as 10"),
            HistoryLine(fromUser: false, text: "Cancelar."),
            HistoryLine(fromUser: true, text: "Marca um meet com a julia amanha as 10"),
        ]
        let digest = AgentCoordinator.digest(history, characters: 2400)
        XCTAssertFalse(digest.contains("Cancelar"), digest)
        XCTAssertTrue(digest.contains("Marca um meet"), digest)
    }

    func testFalseActionClaimIsDetected() {
        XCTAssertTrue(AgentCoordinator.claimsAction("Enviei o e-mail para julia.teste15@example.com."))
        XCTAssertTrue(AgentCoordinator.claimsAction("A confirmação do envio foi enviada para você."))
        XCTAssertTrue(AgentCoordinator.claimsAction("Pronto, criei o lembrete."))
        XCTAssertFalse(AgentCoordinator.claimsAction("Não enviei nada ainda. Quer que eu abra o e-mail?"))
        XCTAssertFalse(AgentCoordinator.claimsAction("Para abrir o arquivo, use open(). Envie-o depois."))
        XCTAssertFalse(AgentCoordinator.claimsAction("```python\n# enviei\nmail.send()\n```\nEsse código lê e-mails."))
    }

    func testLastAnswerKeepsCodeForFollowUp() {
        let code = String(repeating: "x", count: 1500)
        let history = [
            HistoryLine(fromUser: true, text: "Gere um código Python"),
            HistoryLine(fromUser: false, text: code),
        ]
        let kept = AgentCoordinator.recent(history, characters: 2400)
        XCTAssertEqual(kept.last?.text.count, 1500)
        XCTAssertEqual(kept.count, 2)
    }

    func testRulesRetryAfterCancel() {
        let rules = AgentCoordinator.rules.lowercased()
        XCTAssertTrue(rules.contains("pedido novo"), rules)
    }

    func testReminderDoesNotAskCalendarProvider() async throws {
        gate.prompt = "Me lembra de revisar amanhã às 9"
        _ = try await gate.call("criarLembrete", [
            "titulo": .string("Revisar"), "data": .string("2026-10-20"), "hora": .string("09:00"),
        ])
        XCTAssertTrue(picks.isEmpty)
        XCTAssertEqual(logins, 0)
    }

    func testExplicitGoogleEventSkipsProviderCard() async throws {
        gate.prompt = "Marca reunião no Google amanhã às 10"
        let out = try await gate.call("criarEvento", [
            "titulo": .string("Reunião"), "data": .string("2026-10-20"), "hora": .string("10:00"),
        ])
        XCTAssertTrue(picks.isEmpty, picks.joined())
        XCTAssertEqual(proposals.last?.summary, "Criar evento “Reunião” 2026-10-20 10:00–11:00 no Google Agenda")
        XCTAssertTrue(out.contains("Google Agenda"), out)
        XCTAssertFalse(out.contains("Meet:"), out)
    }

    func testMeetForcesGoogleAndReturnsLink() async throws {
        gate.prompt = "Cria um Meet com a Ju amanhã às 10"
        let out = try await gate.call("criarEvento", [
            "titulo": .string("Ju"), "data": .string("2026-10-20"), "hora": .string("10:00"),
        ])
        XCTAssertTrue(picks.isEmpty)
        XCTAssertTrue(proposals.last?.summary.contains("Meet") == true, proposals.last?.summary ?? "")
        XCTAssertTrue(out.contains("meet.google.com"), out)
    }

    func testMeetInTitleForcesGoogleEvenIfPromptEmpty() async throws {
        gate.prompt = ""
        gate.providerRouter.savedPreference = .apple
        let out = try await gate.call("criarEvento", [
            "titulo": .string("Meet"), "data": .string("2026-10-20"), "hora": .string("10:00"),
        ])
        XCTAssertTrue(picks.isEmpty, "Meet não pergunta iPhone vs Google")
        XCTAssertTrue(proposals.last?.summary.contains("Google Agenda") == true, proposals.last?.summary ?? "")
        XCTAssertTrue(out.contains("meet.google.com"), out)
    }

    func testUnconfiguredGoogleDoesNotWrite() async throws {
        let google = SimulatedGoogleCalendarProvider(signedIn: false, configured: false)
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated, google: google)
        let local = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world, maxWritesPerTurn: 1)
        local.prompt = "Cria um Meet amanhã às 10"
        local.confirm = { [unowned self] proposal in
            proposals.append(proposal)
            return true
        }
        local.requestGoogleSignIn = { _ in
            XCTFail("Sem login Google ligado, não abre a folha de Sign-In")
            return true
        }
        let out = try await local.call("criarEvento", [
            "titulo": .string("Meet"), "data": .string("2026-10-21"), "hora": .string("10:00"),
        ])
        XCTAssertTrue(out.hasPrefix("FALHA"), out)
        XCTAssertTrue(out.contains("Google"), out)
        XCTAssertFalse(out.contains("iPhone"), out)
        XCTAssertFalse(out.contains("calendar.google.com"), out)
        XCTAssertTrue(proposals.isEmpty, "Não confirma gravação se o login não existe")
        let events = try await store.events(from: at(day: 21, 0), to: at(day: 22, 0))
        XCTAssertFalse(events.contains { $0.title == "Meet" })
        let created = await google.createdCount()
        XCTAssertEqual(created, 0)
    }

    func testMeetWithoutSignInAsksLoginAndWritesNothingIfCancelled() async throws {
        let google = SimulatedGoogleCalendarProvider(signedIn: false, configured: true)
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated, google: google)
        let local = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world, maxWritesPerTurn: 1)
        local.prompt = "Cria um Meet amanhã às 10"
        local.confirm = { _ in
            XCTFail("Não confirma o evento antes do login")
            return true
        }
        local.requestGoogleSignIn = { [unowned self] summary in
            self.logins += 1
            XCTAssertTrue(summary.contains("Google"), summary)
            return false
        }
        let out = try await local.call("criarEvento", [
            "titulo": .string("Meet"), "data": .string("2026-10-21"), "hora": .string("10:00"),
        ])
        XCTAssertEqual(logins, 1)
        XCTAssertTrue(out.hasPrefix("CANCELADO"), out)
        let created = await google.createdCount()
        XCTAssertEqual(created, 0)
    }

    func testBeginClearsDeclinedSoRetryWorks() async throws {
        approve = false
        gate.prompt = "Cria um Meet amanhã às 10"
        let first = try await gate.call("criarEvento", [
            "titulo": .string("Meet"), "data": .string("2026-10-20"), "hora": .string("10:00"),
        ])
        XCTAssertTrue(first.hasPrefix("CANCELADO"), first)
        gate.begin()
        gate.prompt = "Cria um Meet amanhã às 10"
        approve = true
        let second = try await gate.call("criarEvento", [
            "titulo": .string("Meet"), "data": .string("2026-10-20"), "hora": .string("10:00"),
        ])
        XCTAssertFalse(second.hasPrefix("CANCELADO"), second)
        XCTAssertTrue(second.contains("meet.google.com") || second.contains("Google Agenda"), second)
    }

    func testGoogleAuthAcceptsPastedClientID() {
        let previous = UserDefaults.standard.string(forKey: GoogleAuth.clientIDKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: GoogleAuth.clientIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: GoogleAuth.clientIDKey)
            }
        }
        XCTAssertFalse(GoogleAuth.isClientID(""))
        XCTAssertFalse(GoogleAuth.isClientID("I'm"))
        XCTAssertFalse(GoogleAuth.isClientID("$(GOOGLE_IOS_CLIENT_ID)"))
        GoogleAuth.saveClientID("123-abc.apps.googleusercontent.com")
        XCTAssertEqual(GoogleAuth.clientID, "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(GoogleAuth.reversedScheme(), "com.googleusercontent.apps.123-abc")
    }

    func testAmbiguousEventAsksThenWritesOniPhone() async throws {
        gate.prompt = "Marca reunião amanhã às 10"
        pickResult = ProviderPick(provider: .apple, remember: false)
        let out = try await gate.call("criarEvento", [
            "titulo": .string("Reunião"), "data": .string("2026-10-20"), "hora": .string("10:00"),
        ])
        XCTAssertEqual(picks.count, 1)
        XCTAssertTrue(out.contains("iPhone"), out)
        let events = try await store.events(from: at(day: 20, 0), to: at(day: 21, 0))
        XCTAssertTrue(events.contains { $0.title == "Reunião" })
    }

    func testGoogleLoginResumesPendingEvent() async throws {
        let google = SimulatedGoogleCalendarProvider(signedIn: false)
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated, google: google)
        let local = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world, maxWritesPerTurn: 1)
        local.prompt = "Reunião no Google amanhã às 10"
        local.confirm = { [unowned self] proposal in
            proposals.append(proposal)
            return true
        }
        local.requestGoogleSignIn = { _ in
            self.logins += 1
            await google.setSignedIn(true)
            return true
        }
        let out = try await local.call("criarEvento", [
            "titulo": .string("Sync"), "data": .string("2026-10-20"), "hora": .string("10:00"),
        ])
        XCTAssertEqual(logins, 1)
        XCTAssertTrue(out.contains("Google Agenda"), out)
        let created = await google.createdCount()
        XCTAssertEqual(created, 1)
    }

    func testPrivateMeetInvitesGuestOnGoogle() async throws {
        let google = SimulatedGoogleCalendarProvider()
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated, google: google)
        let local = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world, maxWritesPerTurn: 1)
        local.prompt = "Marca um meet com a julia amanha as 10h, julia.teste15@example.com. Evento privado."
        local.confirm = { [unowned self] proposal in
            proposals.append(proposal)
            return true
        }
        let out = try await local.call("criarEvento", [
            "titulo": .string("Discutir sobre investimento"),
            "data": .string("2026-10-22"), "hora": .string("10:00"),
            "meet": .bool(true), "privado": .bool(true),
            "participantes": .string("julia.teste15@example.com"),
        ])
        XCTAssertTrue(proposals.last?.summary.contains("privado") == true, proposals.last?.summary ?? "")
        XCTAssertTrue(proposals.last?.summary.contains("julia.teste15@example.com") == true, proposals.last?.summary ?? "")
        XCTAssertTrue(out.contains("julia.teste15@example.com"), out)
        XCTAssertTrue(out.localizedCaseInsensitiveContains("privado"), out)
        let guests = await google.lastAttendees()
        XCTAssertEqual(guests, ["julia.teste15@example.com"])
        let isPrivate = await google.lastPrivate()
        XCTAssertTrue(isPrivate)
        let hasMeet = await google.lastMeet()
        XCTAssertTrue(hasMeet)
    }

    func testGuestEmailForcesGoogleEvenWithiPhonePreference() async throws {
        let google = SimulatedGoogleCalendarProvider()
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated, google: google)
        let local = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world, maxWritesPerTurn: 1)
        local.providerRouter.savedPreference = .apple
        local.prompt = "Reunião amanhã às 10 com foo@bar.com"
        local.confirm = { [unowned self] proposal in
            proposals.append(proposal)
            return true
        }
        let out = try await local.call("criarEvento", [
            "titulo": .string("Reunião"), "data": .string("2026-10-22"), "hora": .string("10:00"),
            "participantes": .string("foo@bar.com"),
        ])
        XCTAssertTrue(out.contains("Google Agenda"), out)
        XCTAssertFalse(out.contains("iPhone"), out)
        let guests = await google.lastAttendees()
        XCTAssertEqual(guests, ["foo@bar.com"])
        let hasMeet = await google.lastMeet()
        XCTAssertFalse(hasMeet)
    }

    func testPromptEmailOverridesModelTypo() async throws {
        let google = SimulatedGoogleCalendarProvider()
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated, google: google)
        let local = ToolGate(
            tools: ChatToolCatalog.make(store: store, clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world, maxWritesPerTurn: 1)
        local.prompt = "Marca um meet amanha as 10 com a jteste15@example.com e coloca o evento como privado."
        local.confirm = { [unowned self] proposal in
            proposals.append(proposal)
            return true
        }
        let out = try await local.call("criarEvento", [
            "titulo": .string("Investimento"),
            "data": .string("2026-10-22"), "hora": .string("10:00"),
            "meet": .bool(true), "privado": .bool(true),
            "participantes": .string("jateste15@example.com"),
        ])
        XCTAssertFalse(out.contains("jateste15@example.com"), out)
        XCTAssertTrue(out.contains("jteste15@example.com"), out)
        XCTAssertTrue(proposals.last?.summary.contains("jteste15@example.com") == true, proposals.last?.summary ?? "")
        let guests = await google.lastAttendees()
        XCTAssertEqual(guests, ["jteste15@example.com"])
    }

    func testEmailsInTextKeepsUserSpelling() {
        let found = ChatToolCatalog.emailsInText(
            "Meet com jteste15@example.com e também FOO.Bar+1@usp.br amanhã")
        XCTAssertEqual(found, ["jteste15@example.com", "foo.bar+1@usp.br"])
    }

    func testInvalidGuestEmailIsArgumentError() async throws {
        let out = try await gate.call("criarEvento", [
            "titulo": .string("X"), "data": .string("2026-10-22"), "hora": .string("10:00"),
            "participantes": .string("julia"),
        ])
        XCTAssertTrue(out.hasPrefix("ERRO DE ARGUMENTO"), out)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testUnknownContactIsQuestionNotFailure() async throws {
        let out = try await gate.call("buscarContato", ["nome": .string("Ju")])
        XCTAssertFalse(out.hasPrefix("FALHA"), out)
        XCTAssertTrue(out.contains("Pergunte") || out.contains("agenda"), out)
        XCTAssertEqual(gate.steps.last?.status, .ok)
    }

    func testWhatsAppOpensAfterContactLookup() async throws {
        let lookup = try await gate.call("buscarContato", ["nome": .string("Ana")])
        XCTAssertTrue(lookup.contains("+15550100"), lookup)
        let zap = try await gate.call("enviarWhatsApp", ["numero": .string("+15550100")])
        XCTAssertEqual(proposals.last?.summary, "Abrir WhatsApp com +15550100")
        XCTAssertTrue(zap.contains("whatsapp:+15550100") || zap.contains("+15550100"), zap)
    }

    func testHarnessContactThenCallGoesThroughGate() async throws {
        let lookup = try await gate.call("buscarContato", ["nome": .string("Ana")])
        XCTAssertTrue(lookup.contains("+15550100"), lookup)
        XCTAssertTrue(proposals.isEmpty, "Leitura de contato não pede confirmação")
        let call = try await gate.call("ligar", ["numero": .string("+15550100")])
        XCTAssertEqual(proposals.map(\.summary), ["Ligar para +15550100"])
        XCTAssertTrue(call.contains("tel:+15550100") || call.contains("+15550100"), call)
        let route = try await gate.call("abrirRota", ["destino": .string("USP")])
        XCTAssertTrue(route.hasPrefix("LIMITE DE ESCRITA") || proposals.count >= 2, route)
    }

    func testQwenBareToolNameIsRecoveredAsCall() {
        let known = ["consultarCompromissos", "criarLembrete"]
        let bare = MLXPhoneBackend.recoverToolCalls(from: "consultarCompromissos", known: known)
        XCTAssertEqual(bare.map(\.function.name), ["consultarCompromissos"])
        XCTAssertTrue(bare[0].function.arguments.isEmpty)
        let tagged = MLXPhoneBackend.recoverToolCalls(
            from: #"<tool_call>{"name":"criarLembrete","arguments":{"titulo":"X","data":"amanhã","hora":"09:00"}}</tool_call>"#,
            known: known)
        XCTAssertEqual(tagged.map(\.function.name), ["criarLembrete"])
        XCTAssertEqual(tagged.first?.function.arguments["titulo"]?.anyValue as? String, "X")
        XCTAssertTrue(MLXPhoneBackend.looksLikeToolPayload("consultarCompromissos", known: known))
        XCTAssertFalse(MLXPhoneBackend.looksLikeToolPayload("Você tem uma viagem em novembro.", known: known))
    }
}
