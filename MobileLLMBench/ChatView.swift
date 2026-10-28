import SwiftUI

struct ChatView: View {
    let store: ChatStore
    let runner: BenchmarkRunner
    @State private var draft = ""
    @State private var showConversations = false
    @State private var showMetrics = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(store.current.messages) { MessageRow(message: $0) }
                            if store.generating { live }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: store.streamingText) { proxy.scrollTo("bottom") }
                    .onChange(of: store.current.messages.count) { proxy.scrollTo("bottom") }
                    .onChange(of: store.pending) { proxy.scrollTo("bottom") }
                }
                if let pending = store.pending {
                    switch pending {
                    case .confirm(let proposal):
                        ConfirmationCard(proposal: proposal, resolve: store.resolve)
                    case .pickProvider(let summary):
                        ProviderCard(summary: summary, pick: store.pickProvider)
                    case .googleSignIn(let summary):
                        GoogleLoginCard(summary: summary, cancel: store.cancelGoogleLogin, login: store.startGoogleLogin)
                    }
                }
                inputBar
            }
            .navigationTitle(store.current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showConversations = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Conversas")
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Modelo", selection: Bindable(store).agent) {
                            ForEach(Agent.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(store.agent.title, systemImage: "cpu").font(.headline)
                    }
                    .disabled(store.generating)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showMetrics = true } label: { Image(systemName: "gauge.with.dots.needle.33percent") }
                        .accessibilityLabel("Métricas e desenvolvimento")
                    Button { store.newConversation() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Nova conversa")
                        .disabled(store.generating)
                }
            }
            .sheet(isPresented: $showConversations) { ConversationList(store: store) }
            .sheet(isPresented: $showMetrics) { MetricsPanel(store: store) }
        }
    }

    @ViewBuilder private var live: some View {
        ForEach(store.liveSteps) { StepRow(step: $0) }
        if store.streamingText.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Bubble(text: store.streamingText, role: .assistant)
        }
    }

    private var status: String {
        switch store.pending {
        case .pickProvider: return "Escolha a agenda…"
        case .googleSignIn: return "Entre com o Google…"
        case .confirm: return "Aguardando sua confirmação…"
        case nil: break
        }
        if store.liveSteps.last?.status == .running { return "Executando ferramenta…" }
        return "Gerando…"
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if runner.running {
                Text("Benchmark em execução; o chat espera terminar.").font(.caption).foregroundStyle(.secondary)
            }
            if store.mode == .simulated {
                Text("Modo simulado: Contatos Ana/Bruno/Carla; ligar/SMS/Maps não abrem apps.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if store.mode == .real {
                if let email = store.googleEmail {
                    HStack(spacing: 8) {
                        Text("Google: \(email)").font(.caption).foregroundStyle(.secondary)
                        Button("Sair") { store.signOutGoogle() }
                            .font(.caption)
                            .disabled(store.generating)
                            .accessibilityIdentifier("chat.google.signout")
                    }
                } else {
                    Button("Entrar no Google para Agenda e Meet") { store.startGoogleLogin() }
                        .font(.caption)
                        .disabled(store.generating)
                        .accessibilityIdentifier("chat.google.signin")
                    if !GoogleAuth.isClientID(store.googleClientID) {
                        Text("A folha de login só abre com o Client ID iOS da app em Desenvolvimento — não com e-mail, senha nem um texto qualquer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = store.storageError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom) {
                TextField("Mensagem", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("chat.input")
                if store.generating {
                    Button { store.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .accessibilityLabel("Parar")
                        .accessibilityIdentifier("chat.stop")
                } else {
                    Button {
                        store.send(draft)
                        draft = ""
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .accessibilityLabel("Enviar")
                        .accessibilityIdentifier("chat.send")
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runner.running)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.steps) { StepRow(step: $0) }
            Bubble(text: message.text, role: message.role)
        }
    }
}

private struct Bubble: View {
    let text: String
    let role: ChatMessage.Role

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 40) }
            Text(text)
                .textSelection(.enabled)
                .padding(10)
                .foregroundStyle(role == .user ? .white : .primary)
                .background(background, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("chat.message.\(role.rawValue)")
            if role != .user { Spacer(minLength: 40) }
        }
    }

    private var background: Color {
        switch role {
        case .user: .accentColor
        case .assistant: Color(.secondarySystemBackground)
        case .error: .red.opacity(0.15)
        }
    }
}

private struct StepRow: View {
    let step: ToolStep

    var body: some View {
        DisclosureGroup {
            Text(step.output.isEmpty ? "—" : step.output)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text("\(step.tool) · \(label)").font(.caption.bold())
                    Text(step.summary).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
        }
        .padding(8)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("chat.step.\(step.tool).\(step.status.rawValue)")
    }

    private var label: String {
        switch step.status {
        case .awaitingConfirmation: "aguardando confirmação"
        case .running: "executando"
        case .ok: "ok"
        case .invalid: "argumento inválido"
        case .cancelled: "cancelada"
        case .failed: "falhou"
        case .duplicate: "repetição bloqueada"
        case .limit: "limite de chamadas"
        case .unknownTool: "ferramenta inexistente"
        case .permissionDenied: "sem permissão"
        case .reused: "reutilizada"
        case .stalled: "sem progresso"
        case .writeLimit: "limite de escrita"
        }
    }

    private var icon: String {
        switch step.status {
        case .ok, .reused: "checkmark.circle.fill"
        case .running: "gearshape.2"
        case .awaitingConfirmation: "hand.raised"
        case .cancelled: "xmark.circle"
        case .permissionDenied: "lock"
        default: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch step.status {
        case .ok, .reused: .green
        case .running, .awaitingConfirmation: .blue
        case .cancelled: .secondary
        default: .orange
        }
    }
}

private struct ProviderCard: View {
    let summary: String
    let pick: (ProviderPick?) -> Void
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Qual agenda?", systemImage: "calendar").font(.headline)
            Text(summary).accessibilityIdentifier("chat.provider.summary")
            Toggle("Lembrar esta escolha", isOn: $remember)
            HStack {
                Button("Cancelar", role: .cancel) { pick(nil) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chat.provider.cancel")
                Spacer()
                Button("iPhone") { pick(ProviderPick(provider: .apple, remember: remember)) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chat.provider.apple")
                Button("Google") { pick(ProviderPick(provider: .google, remember: remember)) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat.provider.google")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

private struct GoogleLoginCard: View {
    let summary: String
    let cancel: () -> Void
    let login: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Entrar com o Google", systemImage: "person.crop.circle.badge.plus").font(.headline)
            Text(summary)
            Text("Entra com a sua conta Google. O app grava o evento na Agenda dessa conta.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancelar", role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chat.google.cancel")
                Spacer()
                Button("Entrar", action: login)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat.google.login")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

private struct ConfirmationCard: View {
    let proposal: ToolProposal
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Confirmar ação", systemImage: "hand.raised.fill").font(.headline)
            Text(proposal.summary).accessibilityIdentifier("chat.confirm.summary")
            Text("Ferramenta: \(proposal.tool)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancelar", role: .cancel) { resolve(false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chat.deny")
                Spacer()
                Button("Confirmar") { resolve(true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat.confirm")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

private struct ConversationList: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.conversations) { conversation in
                    Button {
                        store.select(conversation.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(conversation.title).lineLimit(1)
                            Text("\(conversation.messages.count) mensagens · \(conversation.created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in offsets.map { store.conversations[$0].id }.forEach(store.delete) }
            }
            .navigationTitle("Conversas")
            .toolbar {
                Button("Nova") {
                    store.newConversation()
                    dismiss()
                }
            }
        }
    }
}

private struct MetricsPanel: View {
    let store: ChatStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Execução das ferramentas") {
                    Picker("Modo", selection: Bindable(store).mode) {
                        Text("Real").tag(ExecutionMode.real)
                        Text("Simulado").tag(ExecutionMode.simulated)
                    }
                    .pickerStyle(.segmented)
                    .disabled(store.generating)
                    Text("Real: agenda/lembretes (EventKit), Google Agenda/Meet (conta Google), Contatos, Telefone, SMS, Mail, Mapas, Safari, WhatsApp. Simulado: fixtures, sem rede. Ações com efeito pedem confirmação.")
                        .font(.caption)
                }
                Section("Google") {
                    if let email = store.googleEmail {
                        Text(email)
                        Button("Sair da conta Google", role: .destructive) { store.signOutGoogle() }
                            .disabled(store.generating)
                    } else {
                        Button("Entrar com o Google") { store.startGoogleLogin() }
                            .disabled(store.generating || store.mode == .simulated)
                        Text("Cada pessoa entra com a conta Google dela. O Client ID abaixo é da app (uma vez), não o e-mail nem a senha.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("123-abc.apps.googleusercontent.com", text: Bindable(store).googleClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .disabled(store.generating)
                    if GoogleAuth.isClientID(store.googleClientID) {
                        Text("URL scheme invertido: \(GoogleAuth.reversedScheme(store.googleClientID))")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("No Google.xcconfig, GOOGLE_IOS_REVERSED_CLIENT_ID é este scheme (não o Client ID). Rebuild obrigatório.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if store.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Google Cloud → APIs e serviços → Credenciais → + Criar credenciais → ID do cliente OAuth → iOS. Bundle ID: davidoneil.MobileLLMBench. Ative também a Google Calendar API.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Isso não é um Client ID iOS (tem que terminar com .apps.googleusercontent.com). Apague e cole o ID que o Google Cloud mostra.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Tarefas (\(store.metrics.count))") {
                    if FileManager.default.fileExists(atPath: store.metricsURL.path) {
                        ShareLink("Exportar métricas (sem conteúdo das conversas)", item: store.metricsURL)
                    }
                    ForEach(store.metrics.reversed()) { MetricsRow(record: $0) }
                    if !store.metrics.isEmpty {
                        Button("Apagar métricas", role: .destructive) { store.clearMetrics() }
                    }
                }
            }
            .navigationTitle("Desenvolvimento")
        }
    }
}

private struct MetricsRow: View {
    let record: ChatMetricsRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(record.agent) · \(record.policy) · \(record.executionMode) · \(record.outcome)").font(.caption.bold())
            Text("total \(ms(record.totalExcludingConfirmationMs)) (sem confirmação) · TTFT \(ms(record.ttftMs)) · carga \(ms(record.modelLoadMs))")
            Text("seleção de tool \(ms(record.toolSelectionMs)) · execução \(ms(record.toolExecutionMs)) · geração \(ms(record.generationMs))")
            Text("tokens \(record.inputTokens.map(String.init) ?? "–")/\(record.outputTokens.map(String.init) ?? "–") · memória \(mb(record.memoryBeforeMB))→\(mb(record.memoryAfterMB)) · rodadas \(record.llmRounds)")
            if !record.actions.isEmpty { Text(record.actions.joined(separator: " → ")) }
        }
        .font(.caption2.monospaced())
    }

    private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "–" }
    private func mb(_ value: Double?) -> String { value.map { String(format: "%.0f MB", $0) } ?? "–" }
}
