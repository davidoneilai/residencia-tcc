import Foundation
import FoundationModels
import MLXLMCommon

struct ToolProposal: Identifiable, Equatable, Sendable {
    let id = UUID()
    var tool: String
    /// Argumentos resolvidos, exatamente o que será executado.
    var summary: String
    /// Ligação/mensagem: o cartão mostra contato, canal e texto editáveis (estilo Siri).
    var message: MessageDraft?
}

/// Rascunho de mensagem ou ligação que o usuário pode ajustar no cartão antes de aprovar.
struct MessageDraft: Equatable, Sendable {
    enum Channel: String, CaseIterable, Sendable {
        case whatsapp = "enviarWhatsApp", sms = "enviarMensagem", call = "ligar", facetime = "ligarFaceTime"

        var title: String {
            switch self {
            case .whatsapp: "WhatsApp"
            case .sms: "Mensagens"
            case .call: "Telefone"
            case .facetime: "FaceTime"
            }
        }
        var sendsText: Bool { self == .whatsapp || self == .sms }
        /// Canais trocáveis entre si no cartão (texto com texto, voz com voz).
        var siblings: [Channel] { sendsText ? [.whatsapp, .sms] : [.call, .facetime] }
    }

    var name: String?
    var phone: String
    var body: String
    var channel: Channel
}

enum ChatPending: Equatable {
    case confirm(ToolProposal)
    case pickProvider(String)
    case googleSignIn(String)
}

enum ToolStepStatus: String, Codable, Sendable {
    case awaitingConfirmation = "awaiting_confirmation"
    case running, ok, invalid, cancelled, failed, duplicate, limit
    case unknownTool = "unknown_tool"
    case permissionDenied = "permission_denied"
    case reused
    case stalled
    case writeLimit = "write_limit"
}

struct ToolStep: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var tool: String
    var summary: String
    var status: ToolStepStatus
    var output = ""
    var ms: Double?
}

enum ChatAgentError: LocalizedError {
    case runaway(Int)

    var errorDescription: String? {
        switch self {
        case .runaway(let limit): "O modelo insistiu em ferramentas depois do limite de \(limit) chamadas; a tarefa foi interrompida."
        }
    }
}

/// Única porta entre o LLM e as ferramentas: existência, validação, limite, confirmação, deduplicação e execução.
/// Não conhece tarefas nem gabaritos do benchmark.
@MainActor
final class ToolGate {
    var tools: [ChatTool]
    let registry: EventRegistry
    let maxCalls: Int
    /// MVP: no máximo uma escrita confirmada e verificada por turno.
    let maxWritesPerTurn: Int
    var confirm: (ToolProposal) async -> Bool = { _ in false }
    /// Edição feita no cartão (contato, canal, texto); o store grava antes de aprovar e o gate aplica.
    var edit: MessageDraft?
    /// Pedido original do usuário neste turno. O roteador de agenda lê isto, não o modelo.
    var prompt = ""
    var providerRouter = ProviderRouter()
    var pickProvider: (String) async -> ProviderPick? = { _ in nil }
    /// `true` = entrou; `false` = usuário cancelou. Erro de configuração/login deve ser `throw`.
    var requestGoogleSignIn: (String) async throws -> Bool = { _ in false }
    var onStep: (ToolStep) -> Void = { _ in }
    /// Memória do usuário: resolve "casa"/"trabalho" no endereço gravado sem nova rodada do modelo.
    var memory: UserMemory?
    private(set) var steps: [ToolStep] = []
    private(set) var log = ToolLog()
    private(set) var firstCallAt: TimeInterval?
    private(set) var confirmationWaitMs = 0.0
    /// True quando consultas idênticas se repetiram sem progresso — o coordenador deve encerrar.
    private(set) var stalled = false
    /// Última escrita .ok (texto verificado), se houver.
    private(set) var lastVerifiedWrite: String?
    private var executed: [String: String] = [:]
    private var declined: Set<String> = []
    private var failures: [String: Int] = [:]
    private var queryCache: [String: String] = [:]
    private var queryHits: [String: Int] = [:]
    private var writesOk = 0
    private var calls = 0
    /// Telefones que vieram da agenda (buscarContato) nesta sessão, dígitos → nome. Não zera por tarefa:
    /// "a Ana Souza" no turno seguinte usa o número achado antes.
    private(set) var knownPhones: [String: String] = [:]
    let worldBox: ChatWorldBox

    init(
        tools: [ChatTool], registry: EventRegistry = EventRegistry(), worldBox: ChatWorldBox = ChatWorldBox(),
        maxCalls: Int = 8, maxWritesPerTurn: Int = 3
    ) {
        self.tools = tools
        self.registry = registry
        self.worldBox = worldBox
        self.maxCalls = maxCalls
        self.maxWritesPerTurn = maxWritesPerTurn
        self.providerRouter = ProviderRouter(savedPreference: ProviderPreference.load())
    }

    /// Zera o estado por tarefa. Cada mensagem do usuário é uma tarefa.
    func begin() {
        steps = []
        log = ToolLog()
        firstCallAt = nil
        confirmationWaitMs = 0
        executed = [:]
        declined = []
        failures = [:]
        queryCache = [:]
        queryHits = [:]
        writesOk = 0
        calls = 0
        stalled = false
        lastVerifiedWrite = nil
        registry.reset()
    }

    var toolExecutionMs: Double {
        get async { await log.snapshot().reduce(0) { $0 + $1.ms } }
    }

    var verifiedWriteSucceeded: Bool { lastVerifiedWrite != nil }

    /// Alguma ferramenta com efeito foi tentada (ok, cancelada, falhou, aguardando…), não só leituras.
    var attemptedWrite: Bool {
        let writes = Set(tools.filter(\.sideEffect).map(\.id))
        return steps.contains { writes.contains($0.tool) }
    }

    /// Sempre devolve texto para o modelo; só lança quando o modelo entra em laço depois do limite.
    func call(_ name: String, _ arguments: [String: ToolValue]) async throws -> String {
        var name = name
        calls += 1
        if firstCallAt == nil { firstCallAt = ProcessInfo.processInfo.systemUptime }
        if calls > maxCalls + 2 { throw ChatAgentError.runaway(maxCalls) }
        let shown = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.text)" }.joined(separator: ", ")
        guard calls <= maxCalls else {
            return finish(ToolStep(tool: name, summary: shown, status: .limit),
                          "LIMITE: \(maxCalls) chamadas por tarefa. Não chame mais ferramentas; responda com o que já tem.")
        }
        guard var tool = tools.first(where: { $0.id == name }) else {
            let names = tools.map(\.id).joined(separator: ", ")
            return finish(ToolStep(tool: name, summary: shown, status: .unknownTool),
                          "ERRO: a ferramenta \(name) não existe. Disponíveis: \(names).")
        }
        var arguments = arguments
        let promptEmails = ChatToolCatalog.emailsInText(prompt)
        if name == ChatToolCatalog.eventName, !promptEmails.isEmpty {
            arguments["participantes"] = .string(promptEmails.joined(separator: ", "))
        }
        if name == "enviarEmail", let first = promptEmails.first {
            arguments["destinatario"] = .string(first)
        }
        if name == "abrirRota", let typed = arguments["destino"]?.text, let place = memory?.place(for: typed) {
            arguments["destino"] = .string(place)
        }
        if Self.phoneTools.contains(name), let typed = arguments["numero"]?.text, !phoneIsGrounded(typed) {
            // O modelo costuma inventar (+55 11 99999-9999) em vez de usar o que a agenda devolveu.
            // Se o pedido cita uma pessoa já achada nesta sessão, troque o número e siga: o cartão de
            // confirmação mostra nome e número, então o usuário ainda vê para quem vai.
            if let grounded = groundedPhoneMentionedInPrompt() {
                arguments["numero"] = .string(grounded)
            } else {
                return finish(ToolStep(tool: name, summary: shown, status: .invalid),
                              "ERRO: o número \(typed) não veio da agenda nem do pedido do usuário. Não invente número: chame buscarContato com o nome da pessoa ou pergunte o número.\(knownPhonesHint())")
            }
        }
        if name == ChatToolCatalog.eventName {
            do {
                try tool.validate(arguments: arguments)
            } catch {
                return finish(ToolStep(tool: name, summary: shown, status: .invalid),
                              "ERRO DE ARGUMENTO: \(error.localizedDescription) Corrija ou pergunte ao usuário.")
            }
            switch await bindCalendarProvider(into: &arguments, tool: tool) {
            case .ready:
                break
            case .cancelled:
                let summary = (try? tool.preview(arguments)) ?? shown
                return finish(ToolStep(tool: name, summary: summary, status: .cancelled),
                              "CANCELADO: o usuário não escolheu a agenda ou não entrou no Google. Nada foi executado.")
            case .failed(let message):
                let summary = (try? tool.preview(arguments)) ?? shown
                return finish(ToolStep(tool: name, summary: summary, status: .failed),
                              "FALHA: \(message) Nada foi executado.")
            }
        }
        let fingerprint = "\(name)|\(shown)"
        if !tool.sideEffect, let cached = queryCache[fingerprint] {
            let hits = queryHits[fingerprint, default: 0] + 1
            queryHits[fingerprint] = hits
            if hits >= 2 {
                stalled = true
                return finish(ToolStep(tool: name, summary: shown, status: .stalled),
                              "SEM PROGRESSO: a mesma consulta já foi feita. Dados já obtidos:\n\(cached)\nNão chame ferramentas; responda só com o que já tem. Não invente local, horário ou detalhes ausentes.")
            }
            return finish(ToolStep(tool: name, summary: shown, status: .reused),
                          "REUTILIZADO (mesma consulta; sem nova leitura):\n\(cached)")
        }
        var summary: String
        do {
            try tool.validate(arguments: arguments)
            summary = withContactName(try tool.preview(arguments), number: arguments["numero"]?.text)
        } catch {
            return finish(ToolStep(tool: name, summary: shown, status: .invalid),
                          "ERRO DE ARGUMENTO: \(error.localizedDescription) Corrija ou pergunte ao usuário.")
        }
        var step = ToolStep(tool: name, summary: summary, status: .running)
        if tool.sideEffect {
            if writesOk >= maxWritesPerTurn {
                return finish(with(step, .writeLimit),
                              "LIMITE DE ESCRITA: já houve \(maxWritesPerTurn) ação(ões) com efeito nesta tarefa. Responda ao usuário; não chame outra ferramenta que grave ou abra apps.")
            }
            if let previous = executed[summary] {
                return finish(with(step, .duplicate), "JÁ EXECUTADO nesta tarefa: \(previous) Não repita.")
            }
            if declined.contains(summary) {
                return finish(with(step, .cancelled), "CANCELADO pelo usuário antes. Não tente de novo.")
            }
            if failures[summary, default: 0] >= 2 {
                return finish(with(step, .failed), "FALHOU duas vezes. Não tente de novo; explique ao usuário.")
            }
            step.status = .awaitingConfirmation
            publish(step)
            let waited = ProcessInfo.processInfo.systemUptime
            edit = nil
            let proposal = ToolProposal(tool: name, summary: summary, message: draft(name, arguments))
            let approved = await confirm(proposal) && !Task.isCancelled
            confirmationWaitMs += (ProcessInfo.processInfo.systemUptime - waited) * 1000
            guard approved else {
                declined.insert(summary)
                return finish(with(step, .cancelled),
                              "CANCELADO: o usuário recusou “\(summary)”. Nada foi executado. Não tente de novo; avise o usuário.")
            }
            if let changed = edit, changed != proposal.message, let next = tools.first(where: { $0.id == changed.channel.rawValue }) {
                // O usuário escolheu o contato no seletor da agenda: número de origem confiável.
                if let key = Self.phoneKey(changed.phone) { knownPhones[key] = changed.name ?? knownPhones[key] }
                arguments["numero"] = .string(changed.phone)
                arguments["corpo"] = changed.channel.sendsText ? .string(changed.body) : nil
                name = next.id
                tool = next
                summary = withContactName((try? tool.preview(arguments)) ?? summary, number: changed.phone)
                step.tool = name
                step.summary = summary
            }
            edit = nil
            step.status = .running
        }
        publish(step)
        for attempt in 1...2 {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let output = try await ToolRuntime.execute(
                    id: name, arguments: arguments, world: worldBox.world, log: log,
                    catalog: tools.map { $0 as any AgentTool })
                step.ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
                if tool.sideEffect {
                    executed[summary] = output
                    writesOk += 1
                    lastVerifiedWrite = output
                } else {
                    queryCache[fingerprint] = output
                    queryHits[fingerprint] = 0
                    if name == "buscarContato" { rememberPhones(output) }
                }
                return finish(with(step, .ok), attempt == 1 ? output : "\(output) (na segunda tentativa)")
            } catch ChatToolError.permissionDenied(let message) {
                return finish(with(step, .permissionDenied),
                              "SEM PERMISSÃO: \(message) Não tente de novo; peça ao usuário para autorizar em Ajustes.")
            } catch ChatToolError.notWritten(let message) where attempt == 1 && failures[summary, default: 0] == 0 {
                failures[summary, default: 0] += 1
                _ = finish(with(step, .failed), "FALHA: \(message) Nada foi gravado; tentando de novo.")
                step = ToolStep(tool: name, summary: summary, status: .running)
                publish(step)
            } catch {
                failures[summary, default: 0] += 1
                return finish(with(step, .failed),
                              "FALHA: \(error.localizedDescription) Não tente de novo; explique ao usuário.")
            }
        }
        return finish(with(step, .failed), "FALHA. Não tente de novo; explique ao usuário.")
    }

    // MARK: Telefones

    static let phoneTools: Set<String> = ["ligar", "ligarFaceTime", "enviarWhatsApp", "enviarMensagem"]

    /// Chave de comparação: só dígitos do número discável (11 9999-0001 e +55 11 99990001 batem).
    static func phoneKey(_ raw: String) -> String? {
        let digits = (ContactMatch.dialable(raw) ?? raw).filter(\.isNumber)
        return digits.count >= 8 ? digits : nil
    }

    /// Números escritos pelo usuário no pedido (com ou sem DDI, com espaço, hífen ou parênteses).
    static func phonesInText(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\+?\d[\d\s().-]{6,}\d"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { phoneKey(String(text[$0])) }
        }
    }

    /// Só aceita número achado na agenda ou digitado pelo usuário; o modelo não pode inventar (+55 11 99999-9999).
    func phoneIsGrounded(_ raw: String) -> Bool {
        guard let key = Self.phoneKey(raw) else { return false }
        return knownPhones[key] != nil || Self.phonesInText(prompt).contains(key)
    }

    /// Único número da agenda cujo nome aparece no pedido ("manda um oi para Ju" → o número de "Ju 💞").
    /// nil se nenhum ou mais de um batem: aí o erro volta para o modelo corrigir.
    func groundedPhoneMentionedInPrompt() -> String? {
        let words = Set(ContactMatch.normalize(prompt).split(separator: " ").map(String.init))
        guard !words.isEmpty else { return nil }
        let hits = knownPhones.filter { _, person in
            ContactMatch.normalize(person)
                .split(separator: " ")
                .contains { $0.count >= 2 && words.contains(String($0)) }
        }
        guard hits.count == 1, let key = hits.keys.first else { return nil }
        return "+\(key)"
    }

    /// Lembra ao modelo os números que a agenda já devolveu nesta sessão, para ele não inventar de novo.
    func knownPhonesHint() -> String {
        guard !knownPhones.isEmpty else { return "" }
        let list = knownPhones.map { "\($0.value): +\($0.key)" }.sorted().joined(separator: "; ")
        return " Números que a agenda já devolveu: \(list)."
    }

    /// Linhas "Nome: +5511… · e-mail …" do buscarContato.
    private func rememberPhones(_ output: String) {
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let person = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...].split(separator: "·").first.map(String.init) ?? ""
            if !person.isEmpty, let key = Self.phoneKey(rest) { knownPhones[key] = person }
        }
    }

    private func draft(_ name: String, _ arguments: [String: ToolValue]) -> MessageDraft? {
        guard let channel = MessageDraft.Channel(rawValue: name), let phone = arguments["numero"]?.text else { return nil }
        let person = Self.phoneKey(phone).flatMap { knownPhones[$0] }
        return MessageDraft(name: person, phone: phone, body: arguments["corpo"]?.text ?? "", channel: channel)
    }

    /// O cartão de confirmação mostra para quem vai: "Abrir WhatsApp com Ana Souza (+55…)".
    private func withContactName(_ summary: String, number: String?) -> String {
        guard let number, let key = Self.phoneKey(number), let person = knownPhones[key] else { return summary }
        return summary.replacingOccurrences(of: number, with: "\(person) (\(number))")
    }

    private enum CalendarBind {
        case ready
        case cancelled
        case failed(String)
    }

    /// Meet, convidado ou privado força Google. Pedido explícito não pergunta. Login retoma a mesma chamada.
    private func bindCalendarProvider(into arguments: inout [String: ToolValue], tool: ChatTool) async -> CalendarBind {
        let title = ChatToolCatalog.optionalText(arguments, "titulo") ?? ""
        let guests = (try? ChatToolCatalog.emails(from: arguments)) ?? []
        let isPrivate = ChatToolCatalog.flag(arguments, "privado")
        let meet = ChatToolCatalog.flag(arguments, "meet")
            || ProviderRouter.wantsMeet(prompt)
            || ProviderRouter.wantsMeet(title)
        let decision = providerRouter.decide(
            prompt: prompt, toolAgenda: ChatToolCatalog.agenda(from: arguments),
            meet: meet || isPrivate || !guests.isEmpty)
        var provider: CalendarProvider
        switch decision {
        case .resolved(let chosen):
            provider = chosen
        case .ask:
            let summary = (try? tool.preview(arguments)) ?? "Criar evento"
            let waited = ProcessInfo.processInfo.systemUptime
            let pick = await pickProvider(summary)
            confirmationWaitMs += (ProcessInfo.processInfo.systemUptime - waited) * 1000
            guard let pick, !Task.isCancelled else { return .cancelled }
            if pick.remember {
                providerRouter.savedPreference = pick.provider
                ProviderPreference.save(pick.provider)
            }
            provider = pick.provider
        }
        arguments["agenda"] = .string(provider.rawValue)
        if meet { arguments["meet"] = .bool(true) }
        if provider == .google {
            if await !worldBox.google.isConfigured() {
                return .failed(GoogleAuth.missingClientIDMessage() + " Nada foi gravado.")
            }
            if await !worldBox.google.isSignedIn() {
                let summary = (try? tool.preview(arguments)) ?? "Criar evento no Google Agenda"
                let waited = ProcessInfo.processInfo.systemUptime
                do {
                    let ok = try await requestGoogleSignIn(summary)
                    confirmationWaitMs += (ProcessInfo.processInfo.systemUptime - waited) * 1000
                    guard ok, !Task.isCancelled, await worldBox.google.isSignedIn() else { return .cancelled }
                } catch {
                    confirmationWaitMs += (ProcessInfo.processInfo.systemUptime - waited) * 1000
                    return .failed(error.localizedDescription)
                }
            }
        }
        return .ready
    }

    private func with(_ step: ToolStep, _ status: ToolStepStatus) -> ToolStep {
        var copy = step
        copy.status = status
        return copy
    }

    private func finish(_ step: ToolStep, _ text: String) -> String {
        var done = step
        done.output = text
        publish(done)
        return text
    }

    private func publish(_ step: ToolStep) {
        if let index = steps.firstIndex(where: { $0.id == step.id }) { steps[index] = step } else { steps.append(step) }
        onStep(step)
    }
}

/// Ponto de entrada do futuro roteador do TCC. Hoje só a política fixa.
protocol InferencePolicy {
    func decide(prompt: String, agent: Agent) -> AdaptiveRouteDecision
}

/// Baseline: `direct` foi a melhor política fixa nos três modelos (reports/adaptive-routing/REPORT.md).
struct FixedPolicy: InferencePolicy {
    var strategy = Strategy.direct

    func decide(prompt: String, agent: Agent) -> AdaptiveRouteDecision {
        AdaptiveRouteDecision(strategy: strategy, decisionMs: 0, reason: "fixed_\(strategy.rawValue)")
    }
}

struct BudgetedDirectPolicy: InferencePolicy {
    func decide(prompt: String, agent: Agent) -> AdaptiveRouteDecision {
        AdaptiveRouteDecision(strategy: .budgetedDirect, decisionMs: 0, reason: "fixed_budgeted_direct")
    }
}

struct ReactiveBudgetPolicy: InferencePolicy {
    func decide(prompt: String, agent: Agent) -> AdaptiveRouteDecision {
        AdaptiveRouteDecision(strategy: .reactiveBudget, decisionMs: 0, reason: "fixed_reactive_budget")
    }
}

/// Heurística só com features do prompt (sem rótulos). Independente do perfil Qwen do AdaptiveRouter.
struct ChatHeuristicPolicy: InferencePolicy {
    func decide(prompt: String, agent: Agent) -> AdaptiveRouteDecision {
        let started = ProcessInfo.processInfo.systemUptime
        let lower = prompt.lowercased()
        let seq = ["depois", "em seguida", "e então", "antes de", "minutos antes", "próximo compromisso", "proximo compromisso"]
            .filter { lower.contains($0) }.count
        let ambig = ["alguma coisa", "não sei", "nao sei", "me lembra de algo", "um lembrete", "qualquer"]
            .filter { lower.contains($0) }.count
        let strategy: Strategy
        let reason: String
        if ambig >= 1 && seq == 0 {
            strategy = .direct; reason = "chat_ambiguous_direct"
        } else if seq >= 1 {
            strategy = .planAct; reason = "chat_sequential_plan"
        } else if prompt.count > 120 {
            strategy = .planAct; reason = "chat_long_plan"
        } else {
            strategy = .direct; reason = "chat_short_direct"
        }
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return AdaptiveRouteDecision(strategy: strategy, decisionMs: ms, reason: reason)
    }
}

/// Telemetria por tarefa. Sem texto da conversa nem argumentos: só nomes de ferramentas, status e tempos.
struct ChatMetricsRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var device: String
    var osVersion: String
    var agent: String
    var model: String
    var backend: String
    var executionMode: String
    var policy: String
    var policyReason: String
    var routerDecisionMs: Double
    var modelLoadMs: Double?
    var ttftMs: Double?
    var generationMs: Double?
    var toolSelectionMs: Double?
    var toolExecutionMs: Double?
    var confirmationWaitMs: Double?
    var totalMs = 0.0
    var totalExcludingConfirmationMs = 0.0
    var inputTokens: Int?
    var outputTokens: Int?
    /// session.usage (iOS 27), tokenCount_transcript (iOS 26.4+, estimativa) ou mlx.
    var tokenSource: String?
    var memoryBeforeMB: Double?
    var memoryAfterMB: Double?
    var thermalBefore: String
    var thermalAfter = "unknown"
    var actions: [String] = []
    var llmRounds = 0
    var contextResets = 0
    var outcome = "ok"
    var errorKind: String?
}

struct HistoryLine: Sendable {
    var fromUser: Bool
    var text: String
}

struct ChatTurnOutcome {
    var text: String?
    var error: Error?
    var metrics: ChatMetricsRecord
}

@MainActor
final class AgentCoordinator {
    let gate: ToolGate
    let mlx: MLXPhoneBackend
    var policy: any InferencePolicy = FixedPolicy()
    var clock: ChatClock
    var executionMode = ExecutionMode.real
    /// Bloco "[Sobre o usuário: …]" ou nil. Entra no turno do usuário (MLX) ou nas instruções (Apple).
    var memoryBlock: () -> String? = { nil }
    /// Raciocínio escolhido pelo usuário; resolvido por pedido em `run`.
    var thinkingMode = ThinkingMode.off
    /// true enquanto o modelo está dentro do bloco de raciocínio (nada visível ainda).
    var onThinking: (Bool) -> Void = { _ in }
    private var appleSession: LanguageModelSession?
    private var sessionKey: String?
    static let maxRounds = 4

    init(gate: ToolGate, mlx: MLXPhoneBackend, clock: ChatClock = ChatClock()) {
        self.gate = gate
        self.mlx = mlx
        self.clock = clock
    }

    func reset() {
        appleSession = nil
        sessionKey = nil
    }

    func run(
        agent: Agent, conversation: UUID, history: [HistoryLine], prompt: String,
        onText: @escaping (String) -> Void
    ) async -> ChatTurnOutcome {
        let decision = policy.decide(prompt: prompt, agent: agent)
        let think = thinkingMode.resolve(prompt: prompt, agent: agent)
        var metrics = ChatMetricsRecord(
            device: DeviceMetrics.device, osVersion: DeviceMetrics.osVersion,
            agent: agent.rawValue, model: agent.model, backend: agent.backend,
            executionMode: executionMode.rawValue,
            policy: decision.strategy.rawValue, policyReason: "\(decision.reason)+\(think.reason)", routerDecisionMs: decision.decisionMs,
            memoryBeforeMB: DeviceMetrics.memoryMB, thermalBefore: DeviceMetrics.thermal)
        gate.begin()
        gate.prompt = prompt
        let started = ProcessInfo.processInfo.systemUptime
        var firstText: TimeInterval?
        var waitAtFirstText = 0.0
        let visible: (String) -> Void = { [gate] text in
            if firstText == nil, !text.isEmpty {
                firstText = ProcessInfo.processInfo.systemUptime
                waitAtFirstText = gate.confirmationWaitMs
            }
            onText(text)
        }
        var outcome = ChatTurnOutcome(text: nil, error: nil, metrics: metrics)
        do {
            let actionPrompt: String
            if decision.strategy == .planAct {
                let plan = try await draftPlan(agent: agent, prompt: prompt, metrics: &metrics)
                actionPrompt = "Plano interno (siga-o):\n\(plan)\n\nPedido do usuário:\n\(prompt)"
            } else {
                actionPrompt = prompt
            }
            func attempt(_ prompt: String) async throws -> String {
                switch agent {
                case .apple:
                    return try await runApple(
                        conversation: conversation, history: history, prompt: prompt, metrics: &metrics, onText: visible)
                case .qwen, .gemma, .minicpm5, .lfm25, .gemma4, .qwen35, .lfm3, .qwen35SFT, .minicpm5SFT, .xlam2SFT:
                    return try await runMLX(
                        agent: agent, history: history, prompt: prompt, strategy: decision.strategy,
                        thinking: think.thinking, metrics: &metrics, onText: visible)
                }
            }
            var text = try await attempt(actionPrompt)
            // Cascata pós-geração: pedido claramente acionável, mas o modelo só leu (ou nem chamou nada) e não
            // perguntou nada. Uma segunda chance apontando a ferramenta; custa uma rodada só quando falhou.
            if let intent = ActionIntent.detect(prompt), !gate.attemptedWrite, !Self.asksSomething(text) {
                metrics.policyReason += "+nudge_\(intent.tool)"
                text = try await attempt(actionPrompt + "\n\n" + intent.nudge)
            }
            // O modelo às vezes diz "enviei" sem ter chamado ferramenta: uma chance de agir, depois texto honesto.
            if Self.claimsAction(text), !gate.verifiedWriteSucceeded {
                text = try await attempt(actionPrompt + "\n\n" + Self.falseClaimNudge)
                if Self.claimsAction(text), !gate.verifiedWriteSucceeded {
                    text = Self.honestNoAction
                    visible(text)
                }
            }
            outcome.text = text
        } catch {
            outcome.error = error
            metrics.outcome = error is CancellationError || Task.isCancelled ? "cancelled" : "error"
            metrics.errorKind = String(describing: type(of: error))
        }
        let end = ProcessInfo.processInfo.systemUptime
        metrics.totalMs = (end - started) * 1000
        metrics.confirmationWaitMs = gate.confirmationWaitMs
        metrics.totalExcludingConfirmationMs = metrics.totalMs - gate.confirmationWaitMs
        let toolMs = await gate.toolExecutionMs
        metrics.toolExecutionMs = gate.steps.isEmpty ? nil : toolMs
        metrics.toolSelectionMs = gate.firstCallAt.map { ($0 - started) * 1000 }
        metrics.ttftMs = firstText.map { ($0 - started) * 1000 - waitAtFirstText }
        metrics.generationMs = metrics.totalExcludingConfirmationMs - toolMs - (metrics.modelLoadMs ?? 0)
        metrics.actions = gate.steps.map { "\($0.tool):\($0.status.rawValue)" }
        metrics.memoryAfterMB = DeviceMetrics.memoryMB
        metrics.thermalAfter = DeviceMetrics.thermal
        outcome.metrics = metrics
        return outcome
    }

    /// Curtas de propósito: no modelo Apple, instruções longas e a data no prompt levaram a consultar a agenda
    /// em vez de criar o lembrete (reports/chat-agent-mvp/REPORT.md, variantes A–E).
    static let rules = """
    Você é um assistente no iPhone. Responda em português, de forma curta.
    Agenda: consultarCompromissos (#N). Lembrete: criarLembrete. Evento/reunião/Meet: criarEvento com titulo+data+hora (não é lembrete). Não pergunte Google vs iPhone.
    Se o usuário passou e-mail de convidado, preencha participantes com o endereço exatamente como escrito. Se pediu privado, privado=true.
    Pessoa: buscarContato com o texto do usuário (Ju, não complete sobrenome). Se não achar, pergunte como está na agenda e busque de novo.
    Zap/WhatsApp: enviarWhatsApp (abre a conversa; o usuário envia). Rota/navegação/Waze: abrirRota. Web https: abrirSafari. E-mail: enviarEmail (busque o e-mail com buscarContato se citou pessoa).
    Abrir qualquer app (WhatsApp sem mensagem, Instagram, Spotify, Fotos, Ajustes...): abrirApp. Atalho do usuário: rodarAtalho.
    Se faltou dado (o que lembrar, número, destino), pergunte. Não invente telefone, local ou horários.
    Fatos em [Sobre o usuário] são verdade: use-os sem perguntar (ex.: "casa" é o endereço gravado).
    Pergunta geral (explicar, código, traduzir): responda direto, sem ferramenta.
    Só diga que enviou, criou, abriu ou ligou se a ferramenta respondeu nesta mensagem.
    Pedido novo: execute de novo mesmo se um parecido foi recusado. Não responda só "Cancelar."
    Se vier ERRO, FALHA, CANCELADO, SEM PERMISSÃO, SEM PROGRESSO ou LIMITE, explique e pare de chamar ferramentas.
    """

    /// Apple FM regride com instrução longa (reports/chat-agent-mvp, variantes A–E): versão curta, lembrete primeiro.
    static let appleRules = """
    Você é um assistente no iPhone. Responda em português, curto.
    Lembrete ("me lembra", "lembrete"): criarLembrete com titulo+data+hora. Não consulte a agenda para isso.
    Evento/reunião/Meet: criarEvento com titulo+data+hora. Agenda: consultarCompromissos (#N).
    Pessoa: buscarContato com o texto do usuário. Zap: enviarWhatsApp. Rota: abrirRota. E-mail: enviarEmail. Apps: abrirApp. Web: abrirSafari.
    Se faltou dado, pergunte. Não invente telefone, local ou horário. Fatos em [Sobre o usuário] são verdade.
    Só diga que fez algo se a ferramenta respondeu nesta mensagem. Se vier ERRO, FALHA, CANCELADO ou LIMITE, explique e pare.
    """

    static func instructions(_ clock: ChatClock, history: [HistoryLine], characters: Int, rules: String = rules) -> String {
        let digest = digest(history, characters: characters)
        let base = "\(rules)\n\(context(clock))"
        return digest.isEmpty ? base : "\(base)\n\nConversa até aqui:\n\(digest)"
    }

    static func context(_ clock: ChatClock) -> String {
        let now = clock.now()
        let cal = clock.calendar
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        return "[Agora: \(ChatDates.weekday(now, calendar: cal)), \(ChatDates.text(now, calendar: cal)), fuso \(cal.timeZone.identifier). Amanhã: \(ChatDates.weekday(tomorrow, calendar: cal)), \(ChatDates.text(tomorrow, calendar: cal, time: false)).]"
    }

    /// Mensagens mais recentes que cabem em `characters`, cada uma cortada em 400 caracteres.
    static func recent(_ history: [HistoryLine], characters: Int) -> [HistoryLine] {
        var kept: [HistoryLine] = []
        var used = 0
        var sawAssistant = false
        for line in history.reversed() {
            if !line.fromUser && isBareCancel(line.text) { continue }
            // A última resposta vai quase inteira: "manda isso por e-mail" precisa do código, não de 400 caracteres.
            let cap = !line.fromUser && !sawAssistant ? min(2000, characters) : 400
            if !line.fromUser { sawAssistant = true }
            let text = String(line.text.prefix(cap))
            guard used + text.count <= characters else { break }
            kept.insert(HistoryLine(fromUser: line.fromUser, text: text), at: 0)
            used += text.count
        }
        return kept
    }

    static func digest(_ history: [HistoryLine], characters: Int) -> String {
        recent(history, characters: characters)
            .map { "\($0.fromUser ? "Usuário" : "Assistente"): \($0.text)" }
            .joined(separator: "\n")
    }

    static let falseClaimNudge = "(Sistema: nenhuma ferramenta foi executada nesta mensagem. Se o pedido exige ação, chame a ferramenta agora. Se não, responda sem dizer que fez.)"
    static let honestNoAction = "Não executei nenhuma ação: nenhuma ferramenta foi chamada. Peça de novo dizendo o que fazer (por exemplo, \"abre o e-mail para fulano@exemplo.com com o código\")."

    private static let claimVerbs: Set<String> = [
        "enviei", "mandei", "criei", "marquei", "agendei", "liguei", "abri", "adicionei", "salvei", "registrei",
    ]
    private static let claimParticiples = [
        "enviad", "mandad", "criad", "marcad", "agendad", "abert", "adicionad", "salv", "registrad",
    ]

    /// Afirma ação concluída ("enviei", "foi enviada"), ignorando blocos de código e negação ("não enviei").
    static func claimsAction(_ text: String) -> Bool {
        let prose = text.replacing(/```[\s\S]*?```/, with: " ").replacing(/\s+/, with: " ")
        let words = ContactMatch.normalize(prose).split(whereSeparator: { !$0.isLetter }).map(String.init)
        for (i, word) in words.enumerated() {
            let negated = i > 0 && words[i - 1] == "nao"
            if claimVerbs.contains(word), !negated { return true }
            if (word == "foi" || word == "foram"), !negated, i + 1 < words.count,
               claimParticiples.contains(where: { words[i + 1].hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    /// A resposta pede algo ao usuário (esclarecimento legítimo; não forçar ação).
    static func asksSomething(_ text: String) -> Bool {
        text.contains("?")
    }

    static func isBareCancel(_ text: String) -> Bool {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .lowercased()
        return folded == "cancelar" || folded == "cancel"
    }


    /// Plano curto sem ferramentas (política plan_act). Overhead entra em generationMs via llmRounds.
    private func draftPlan(agent: Agent, prompt: String, metrics: inout ChatMetricsRecord) async throws -> String {
        let planPrompt = "Em no máximo 3 frases, planeje quais ferramentas usar (agenda, evento, Meet, lembrete, contato, ligar, SMS, Maps, Safari, e-mail) e em que ordem. Sem executar. Pedido: \(prompt)"
        metrics.llmRounds += 1
        switch agent {
        case .apple:
            if let reason = AppleFoundationBackend.unavailableReason { throw BenchError.failed(reason) }
            let session = LanguageModelSession(model: .default)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 128)
            var text = ""
            for try await snapshot in session.streamResponse(to: Prompt { planPrompt }, options: options) {
                text = snapshot.content
            }
            return text
        case .qwen, .gemma, .minicpm5, .lfm25, .gemma4, .qwen35, .lfm3, .qwen35SFT, .minicpm5SFT, .xlam2SFT:
            if let ms = try await mlx.prepare(agent, status: { _ in }) { metrics.modelLoadMs = (metrics.modelLoadMs ?? 0) + ms }
            let lines = [MLXPhoneBackend.ChatLine(role: .user, content: planPrompt)]
            let turn = try await mlx.chatTurn(lines, tools: [], limit: 128) { _ in }
            metrics.inputTokens = (metrics.inputTokens ?? 0) + turn.promptTokens
            metrics.outputTokens = (metrics.outputTokens ?? 0) + turn.outputTokens
            metrics.tokenSource = "mlx"
            return Self.hideThinking(turn.text)
        }
    }

    // MARK: Apple Foundation Models — a sessão faz o ciclo de tools e chama o gate pelos `Tool`.

    private func runApple(
        conversation: UUID, history: [HistoryLine], prompt: String,
        metrics: inout ChatMetricsRecord, onText: @escaping (String) -> Void
    ) async throws -> String {
        if let reason = AppleFoundationBackend.unavailableReason { throw BenchError.failed(reason) }
        // Sessão nova por turno: reusar o transcript envenenava o modelo com CANCELADO ("Cancelar.").
        appleSession = makeSession(history: history, characters: 2400)
        sessionKey = conversation.uuidString
        do {
            return try await stream(appleSession!, prompt, metrics: &metrics, onText: onText)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            metrics.contextResets += 1
            appleSession = makeSession(history: history, characters: 800)
            return try await stream(appleSession!, prompt, metrics: &metrics, onText: onText)
        }
    }

    private func makeSession(history: [HistoryLine], characters: Int) -> LanguageModelSession {
        var tools: [any FoundationModels.Tool] = [
            AppleReminderTool(gate: gate), AppleQueryTool(gate: gate), AppleEventTool(gate: gate),
            ChatContactTool(gate: gate), ChatCallTool(gate: gate), ChatFaceTimeTool(gate: gate),
            ChatMessageTool(gate: gate), ChatWhatsAppTool(gate: gate), ChatMailTool(gate: gate),
            ChatMapsTool(gate: gate), ChatSafariTool(gate: gate), ChatOpenAppTool(gate: gate),
        ]
        if gate.tools.contains(where: { $0.id == ChatHarness.shortcutName }) {
            tools.append(ChatShortcutTool(gate: gate, shortcuts: HarnessSettings.shortcuts))
        }
        var instructions = Self.instructions(clock, history: history, characters: characters, rules: Self.appleRules)
        if let block = memoryBlock() { instructions += "\n\(block)" }
        return LanguageModelSession(model: .default, tools: tools) { instructions }
    }

    private func stream(
        _ session: LanguageModelSession, _ prompt: String,
        metrics: inout ChatMetricsRecord, onText: (String) -> Void
    ) async throws -> String {
        var before = (0, 0)
        if #available(iOS 27.0, *) {
            before = (session.usage.input.totalTokenCount, session.usage.output.totalTokenCount)
        }
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 512)
        var text = ""
        metrics.llmRounds += 1
        for try await snapshot in session.streamResponse(to: Prompt { prompt }, options: options) {
            text = snapshot.content
            onText(text)
        }
        if #available(iOS 27.0, *) {
            metrics.inputTokens = (metrics.inputTokens ?? 0) + session.usage.input.totalTokenCount - before.0
            metrics.outputTokens = (metrics.outputTokens ?? 0) + session.usage.output.totalTokenCount - before.1
            metrics.tokenSource = "session.usage"
        } else if #available(iOS 26.4, *) {
            // Sem `usage` no iOS 26: contexto ocupado pelo transcript inteiro e tokens da resposta final.
            let model = SystemLanguageModel.default
            if let context = try? await model.tokenCount(for: session.transcript),
               let output = try? await model.tokenCount(for: text) {
                metrics.inputTokens = context - output
                metrics.outputTokens = output
                metrics.tokenSource = "tokenCount_transcript"
            }
        }
        return text
    }

    // MARK: MLX (Qwen, Gemma) — o coordenador conduz as rodadas com chamadas estruturadas do template.

    private func runMLX(
        agent: Agent, history: [HistoryLine], prompt: String, strategy: Strategy = .direct, thinking: Bool = false,
        metrics: inout ChatMetricsRecord, onText: @escaping (String) -> Void
    ) async throws -> String {
        if let ms = try await mlx.prepare(agent, status: { _ in }) { metrics.modelLoadMs = ms }
        defer { onThinking(false) }
        // System só com as regras: o prefixo (system + schema das tools) fica idêntico entre turnos e o
        // backend reaproveita o KV cache (`prefix: true`). A hora atual muda a cada minuto, então vai no
        // turno do usuário, não no system.
        var lines = [MLXPhoneBackend.ChatLine(role: .system, content: Self.rules)]
        for line in Self.recent(history, characters: 2400) {
            lines.append(.init(role: line.fromUser ? .user : .assistant, content: line.text))
        }
        let header = [Self.context(clock), memoryBlock()].compactMap { $0 }.joined(separator: "\n")
        lines.append(.init(role: .user, content: "\(header)\n\(prompt)"))
        let specs = MLXPhoneBackend.specs(for: gate.tools.map { $0 as any AgentTool })
        var remaining = BudgetCaps.totalGenerated
        var planned = strategy == .planAct
        let kind = BudgetKind.from(strategy)
        for round in 0..<Self.maxRounds {
            try Task.checkCancellation()
            let limit = BudgetController.nextLimit(remaining: remaining)
            if limit <= 0 { break }
            metrics.llmRounds += 1
            let turn = try await mlx.chatTurn(lines, tools: specs, limit: limit, thinking: thinking, prefix: true) { partial in
                // Evita mostrar raciocínio ou nome/JSON cru de ferramenta na bolha enquanto a chamada ainda não rodou.
                let visible = MLXPhoneBackend.visible(partial, agent: agent)
                self.onThinking(thinking && visible.isEmpty && !partial.isEmpty)
                if MLXPhoneBackend.looksLikeToolPayload(visible, known: gate.tools.map(\.id)) {
                    onText("")
                } else {
                    onText(visible)
                }
            }
            onThinking(false)
            metrics.inputTokens = (metrics.inputTokens ?? 0) + turn.promptTokens
            metrics.outputTokens = (metrics.outputTokens ?? 0) + turn.outputTokens
            remaining = max(0, remaining - turn.outputTokens)
            metrics.tokenSource = "mlx"
            if turn.calls.isEmpty {
                let view = BudgetTrajectory(
                    prompt: prompt, roundsDone: round + 1, remainingTokens: remaining,
                    remainingRounds: Self.maxRounds - round - 1, lastStop: nil,
                    lastHadCalls: false, lastText: turn.text, planned: planned, toolOutputs: [])
                let next = BudgetController.observe(view, kind: kind)
                if (next.action == "recover" || next.action == "plan"), remaining >= 16 {
                    if next.action == "plan", !planned {
                        lines.append(.init(role: .user, content: PhonePrompt.plan(prompt)))
                        planned = true
                    }
                    continue
                }
                let text = MLXPhoneBackend.visible(turn.text, agent: agent)
                if !text.isEmpty { return text }
                let fallback = groundedFallback()
                onText(fallback)
                return fallback
            }
            onText("") // limpa payload de tool que possa ter vazado no stream
            lines.append(.init(role: .assistant, content: turn.text, calls: turn.calls))
            for call in turn.calls {
                let output = try await gate.call(call.function.name, MLXPhoneBackend.toolValues(call.function.arguments))
                lines.append(.init(role: .tool, content: output, callID: call.id))
            }
            // Após escrita verificada, ou se não há progresso: uma rodada final sem ferramentas.
            if gate.verifiedWriteSucceeded || gate.stalled {
                return try await finalAnswer(lines: &lines, metrics: &metrics, onText: onText,
                                            fallback: gate.lastVerifiedWrite ?? groundedFallback())
            }
        }
        return try await finalAnswer(lines: &lines, metrics: &metrics, onText: onText, fallback: groundedFallback())
    }

    /// Rodada sem tools. Se o modelo ainda emitir chamadas, ignora e usa o fallback fundamentado.
    private func finalAnswer(
        lines: inout [MLXPhoneBackend.ChatLine], metrics: inout ChatMetricsRecord,
        onText: @escaping (String) -> Void, fallback: String
    ) async throws -> String {
        lines.append(.init(role: .user, content: "Responda agora ao usuário em português, curto, só com base nos resultados das ferramentas acima. Não chame ferramentas."))
        metrics.llmRounds += 1
        let turn = try await mlx.chatTurn(lines, tools: [], limit: 256) { onText(Self.hideThinking($0)) }
        metrics.inputTokens = (metrics.inputTokens ?? 0) + turn.promptTokens
        metrics.outputTokens = (metrics.outputTokens ?? 0) + turn.outputTokens
        let text = Self.hideThinking(turn.text)
        if turn.calls.isEmpty, !text.isEmpty { return text }
        onText(fallback)
        return fallback
    }

    private func groundedFallback() -> String {
        let bits = gate.steps.reversed().compactMap { step -> String? in
            switch step.status {
            case .ok, .reused: return step.output.isEmpty ? nil : step.output
            case .stalled: return step.output
            default: return nil
            }
        }
        if let first = bits.first { return first }
        return "Não consegui concluir com as ferramentas disponíveis."
    }

    static func hideThinking(_ text: String) -> String { ThinkingFilter.hide(text) }
}

private func compact(_ values: [String: String?]) -> [String: ToolValue] {
    values.compactMapValues { $0.map(ToolValue.string) }
}

struct AppleQueryTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = ChatToolCatalog.queryName
    let description = ChatToolCatalog.queryDescription

    @Generable
    struct Arguments {
        @Guide(description: ChatToolCatalog.queryDateDetail)
        var data: String?
        @Guide(description: ChatToolCatalog.queryDaysDetail)
        var dias: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        var values = compact(["data": arguments.data])
        if let days = arguments.dias { values["dias"] = .int(days) }
        return try await gate.call(name, values)
    }
}

struct AppleReminderTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = ChatToolCatalog.reminderName
    let description = ChatToolCatalog.reminderDescription

    @Generable
    struct Arguments {
        @Guide(description: "O que lembrar, curto")
        var titulo: String
        @Guide(description: "Dia, AAAA-MM-DD. Omita se o usuário não deu data.")
        var data: String?
        @Guide(description: ChatToolCatalog.timeDetail)
        var hora: String?
        @Guide(description: ChatToolCatalog.eventDetail)
        var evento: Int?
        @Guide(description: ChatToolCatalog.minutesBeforeDetail)
        var minutosAntes: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        var values = compact(["titulo": arguments.titulo, "data": arguments.data, "hora": arguments.hora])
        if let event = arguments.evento { values["evento"] = .int(event) }
        if let before = arguments.minutosAntes { values["minutosAntes"] = .int(before) }
        return try await gate.call(name, values)
    }
}

struct AppleEventTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = ChatToolCatalog.eventName
    let description = ChatToolCatalog.eventDescription

    @Generable
    struct Arguments {
        @Guide(description: "Título curto do evento")
        var titulo: String
        @Guide(description: "Dia, AAAA-MM-DD")
        var data: String
        @Guide(description: ChatToolCatalog.eventTimeDetail)
        var hora: String
        @Guide(description: ChatToolCatalog.durationDetail)
        var duracaoMinutos: Int?
        @Guide(description: "true só se o usuário pediu Meet ou videoconferência.")
        var meet: Bool?
        @Guide(description: "E-mails dos convidados, separados por vírgula. Só se o usuário passou e-mail.")
        var participantes: String?
        @Guide(description: "true se o usuário pediu evento privado.")
        var privado: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        var values = compact(["titulo": arguments.titulo, "data": arguments.data, "hora": arguments.hora])
        if let minutes = arguments.duracaoMinutos { values["duracaoMinutos"] = .int(minutes) }
        if arguments.meet == true { values["meet"] = .bool(true) }
        if let guests = arguments.participantes, guests.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            values["participantes"] = .string(guests)
        }
        if arguments.privado == true { values["privado"] = .bool(true) }
        return try await gate.call(name, values)
    }
}

/// Intenção de ação detectada no pedido, sem modelo. Só serve para a segunda chance; nunca executa nada.
struct ActionIntent: Equatable {
    var tool: String
    var nudge: String

    /// Padrões sobre o texto normalizado (sem acento, sem pontuação, minúsculo).
    private static let table: [(pattern: String, tool: String)] = [
        (#"\b(me lembr[ae]|lembrete|lembrar de|lembre me)\b"#, "criarLembrete"),
        (#"\b(reuniao|evento|meet|agenda|agende|agendar|marca uma|marca um|marcar)\b"#, "criarEvento"),
        // "abre o WhatsApp" sozinho é abrir o app; com pessoa/texto cai na linha do enviarWhatsApp.
        (#"^(me )?(abr[ae]|abrir) (o |a )?(app (do |da )?)?(zap|whats|whatsapp)$"#, "abrirApp"),
        (#"\b(zap|whats|whatsapp)\b"#, "enviarWhatsApp"),
        (#"\b(sms|mensagem de texto)\b"#, "enviarMensagem"),
        (#"\b(liga|ligue|ligar) (pra|para|pro)\b"#, "ligar"),
        (#"\b(rota|navega|waze|como chego|como eu chego|me leva)\b"#, "abrirRota"),
        (#"\be ?mail\b"#, "enviarEmail"),
        (#"\b(abr[ae]|abrir) (o |a )?(app (do |da )?)?(instagram|insta|spotify|youtube|uber|tiktok|telegram|linkedin|netflix|x|facebook|ifood|nubank|fotos|musica|ajustes|notas|mapas)\b"#, "abrirApp"),
    ]

    static func detect(_ prompt: String) -> ActionIntent? {
        let text = ContactMatch.normalize(prompt)
        // Pergunta ("quais compromissos tenho amanhã?") não é pedido de ação, salvo "pode/consegue…?".
        if prompt.contains("?"), !text.hasPrefix("pode"), !text.hasPrefix("consegue"), !text.hasPrefix("da pra") { return nil }
        for (pattern, tool) in table where text.range(of: pattern, options: [.regularExpression]) != nil {
            return ActionIntent(
                tool: tool,
                nudge: "(Sistema: o pedido exige a ferramenta \(tool) e ela não foi chamada. Chame \(tool) agora com os dados do pedido; se faltar algum dado, pergunte só isso.)")
        }
        return nil
    }
}
