import Foundation
import Observation

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, error }
    var id = UUID()
    var role: Role
    var text: String
    var steps: [ToolStep] = []
    var date = Date()
}

struct Conversation: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = "Nova conversa"
    var created = Date()
    var messages: [ChatMessage] = []
}

@MainActor
@Observable
final class ChatStore {
    private(set) var conversations: [Conversation] = []
    private(set) var currentID = UUID()
    var agent = Agent.apple {
        didSet { coordinator.reset() }
    }
    var mode = ExecutionMode.real {
        didSet { applyMode() }
    }
    private(set) var generating = false
    private(set) var streamingText = ""
    private(set) var liveSteps: [ToolStep] = []
    private(set) var pending: ChatPending?
    private(set) var metrics: [ChatMetricsRecord] = []
    private(set) var storageError: String?
    let coordinator: AgentCoordinator
    private let realStore: any CalendarStore
    private let simulatedStore: any CalendarStore
    private var confirmation: CheckedContinuation<Bool, Never>?
    private var providerPick: CheckedContinuation<ProviderPick?, Never>?
    private var googleLogin: CheckedContinuation<Bool, Error>?
    private var task: Task<Void, Never>?
    private let conversationsURL: URL
    let metricsURL: URL

    init(mlx: MLXPhoneBackend, realStore: any CalendarStore = EventKitCalendarStore(), root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Conversas (dados pessoais) e métricas (sem conteúdo) ficam em pastas separadas.
        conversationsURL = base.appendingPathComponent("Chat/conversations.json")
        metricsURL = base.appendingPathComponent("ChatMetrics/metrics.json")
        let clock = ChatClock()
        self.realStore = realStore
        simulatedStore = SimulatedCalendarStore.demo(clock: clock)
        let registry = EventRegistry()
        let worldBox = ChatWorldBox(mode: .real)
        let gate = ToolGate(
            tools: ChatToolCatalog.make(store: realStore, clock: clock, registry: registry, world: worldBox),
            registry: registry, worldBox: worldBox)
        coordinator = AgentCoordinator(gate: gate, mlx: mlx, clock: clock)
        conversations = load([Conversation].self, from: conversationsURL) ?? []
        metrics = load([ChatMetricsRecord].self, from: metricsURL) ?? []
        if let latest = conversations.first { currentID = latest.id } else { newConversation() }
        coordinator.gate.confirm = { [weak self] proposal in await self?.ask(proposal) ?? false }
        coordinator.gate.pickProvider = { [weak self] summary in await self?.askProvider(summary) }
        coordinator.gate.requestGoogleSignIn = { [weak self] summary in try await self?.askGoogleLogin(summary) ?? false }
        coordinator.gate.onStep = { [weak self] step in self?.track(step) }
        Task { await restoreGoogleSession() }
    }

    func restoreGoogleSession() async {
        await coordinator.gate.worldBox.google.restoreSession()
        googleEmail = await coordinator.gate.worldBox.google.accountEmail()
    }

    var current: Conversation { conversations.first { $0.id == currentID } ?? Conversation(id: currentID) }

    func newConversation() {
        guard !generating else { return }
        if let open = conversations.first, open.messages.isEmpty {
            currentID = open.id
            return
        }
        let fresh = Conversation()
        conversations.insert(fresh, at: 0)
        currentID = fresh.id
        coordinator.reset()
        save()
    }

    func select(_ id: UUID) {
        guard !generating, id != currentID else { return }
        currentID = id
        coordinator.reset()
    }

    func delete(_ id: UUID) {
        guard !generating else { return }
        conversations.removeAll { $0.id == id }
        if id == currentID {
            coordinator.reset()
            if let first = conversations.first { currentID = first.id } else { newConversation() }
        }
        save()
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating else { return }
        let history = current.messages
            .filter { $0.role != .error }
            .map { HistoryLine(fromUser: $0.role == .user, text: $0.text) }
        let conversation = currentID
        append(ChatMessage(role: .user, text: text), to: conversation)
        generating = true
        streamingText = ""
        liveSteps = []
        let agent = agent
        task = Task {
            let outcome = await coordinator.run(
                agent: agent, conversation: conversation, history: history, prompt: text
            ) { partial in self.streamingText = partial }
            let steps = coordinator.gate.steps
            if let reply = outcome.text {
                append(ChatMessage(role: .assistant, text: reply.isEmpty ? "(resposta vazia)" : reply, steps: steps), to: conversation)
            } else {
                let message = outcome.metrics.outcome == "cancelled"
                    ? "Geração cancelada."
                    : "Erro: \(outcome.error?.localizedDescription ?? "desconhecido")"
                append(ChatMessage(role: .error, text: message, steps: steps), to: conversation)
            }
            metrics.append(outcome.metrics)
            write(metrics, to: metricsURL)
            generating = false
            streamingText = ""
            liveSteps = []
        }
    }

    func stop() {
        task?.cancel()
        resolve(false)
        pickProvider(nil)
        finishGoogleLogin(false)
    }

    func resolve(_ approved: Bool) {
        confirmation?.resume(returning: approved)
        confirmation = nil
        if case .confirm = pending { pending = nil }
    }

    func pickProvider(_ pick: ProviderPick?) {
        providerPick?.resume(returning: pick)
        providerPick = nil
        if case .pickProvider = pending { pending = nil }
    }

    func startGoogleLogin() {
        Task { await runGoogleLogin() }
    }

    func cancelGoogleLogin() {
        finishGoogleLogin(false)
    }

    var googleEmail: String?
    var googleClientID = GoogleAuth.clientID {
        didSet { GoogleAuth.saveClientID(googleClientID) }
    }

    private func runGoogleLogin() async {
        do {
            try await coordinator.gate.worldBox.google.signIn()
            googleEmail = await coordinator.gate.worldBox.google.accountEmail()
            finishGoogleLogin(true)
        } catch {
            storageError = error.localizedDescription
            failGoogleLogin(error)
        }
    }

    func signOutGoogle() {
        Task {
            await coordinator.gate.worldBox.google.signOut()
            googleEmail = nil
        }
    }

    private func finishGoogleLogin(_ ok: Bool) {
        googleLogin?.resume(returning: ok)
        googleLogin = nil
        if case .googleSignIn = pending { pending = nil }
    }

    private func failGoogleLogin(_ error: Error) {
        googleLogin?.resume(throwing: error)
        googleLogin = nil
        if case .googleSignIn = pending { pending = nil }
    }

    func clearMetrics() {
        metrics = []
        write(metrics, to: metricsURL)
    }

    private func ask(_ proposal: ToolProposal) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            confirmation = continuation
            pending = .confirm(proposal)
        }
    }

    private func askProvider(_ summary: String) async -> ProviderPick? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            providerPick = continuation
            pending = .pickProvider(summary)
        }
    }

    private func askGoogleLogin(_ summary: String) async throws -> Bool {
        guard !Task.isCancelled else { return false }
        let google = coordinator.gate.worldBox.google
        if await google.isSignedIn() {
            googleEmail = await google.accountEmail()
            return true
        }
        guard await google.isConfigured() else {
            throw BenchError.failed(GoogleAuth.missingClientIDMessage())
        }
        return try await withCheckedThrowingContinuation { continuation in
            googleLogin = continuation
            pending = .googleSignIn(summary)
        }
    }

    private func track(_ step: ToolStep) {
        if let index = liveSteps.firstIndex(where: { $0.id == step.id }) { liveSteps[index] = step } else { liveSteps.append(step) }
    }

    private func applyMode() {
        let clock = coordinator.clock
        coordinator.gate.worldBox.setMode(mode)
        coordinator.gate.tools = ChatToolCatalog.make(
            store: mode == .real ? realStore : simulatedStore, clock: clock,
            registry: coordinator.gate.registry, world: coordinator.gate.worldBox)
        coordinator.executionMode = mode
        if mode == .real { Task { await restoreGoogleSession() } }
        else { googleEmail = nil }
    }

    private func append(_ message: ChatMessage, to id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(message)
        if message.role == .user, conversations[index].title == "Nova conversa" {
            conversations[index].title = String(message.text.prefix(40))
        }
        save()
    }

    private func save() { write(conversations, to: conversationsURL) }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            // Move o arquivo ilegível para o lado antes que o próximo save o sobrescreva.
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            storageError = "Não li \(url.lastPathComponent): \(error.localizedDescription). Cópia em \(aside.lastPathComponent)."
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            storageError = "Não gravei \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
