import SwiftUI

struct ChatView: View {
    let store: ChatStore
    @State private var draft = ""
    @State private var showConversations = false
    @State private var showSettings = false
    @State private var showEngine = false
    @FocusState private var typing: Bool

    var body: some View {
        ZStack {
            AuroraBackground(paused: store.generating)
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if store.current.messages.isEmpty, !store.generating {
                                EmptyState(agent: store.agent) { draft = $0; typing = true }
                            }
                            ForEach(store.current.messages) { MessageRow(message: $0) }
                            if store.generating { live }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: store.streamingText) { proxy.scrollTo("bottom") }
                    .onChange(of: store.current.messages.count) { withAnimation { proxy.scrollTo("bottom") } }
                    .onChange(of: store.pending) { withAnimation { proxy.scrollTo("bottom") } }
                }
                if let pending = store.pending {
                    Group {
                        switch pending {
                        case .confirm(let proposal):
                            if let message = proposal.message {
                                MessageCard(proposal: proposal, draft: message) { store.resolve($0, edit: $1) }
                                    .id(proposal.id)
                            } else {
                                ConfirmationCard(proposal: proposal) { store.resolve($0) }
                            }
                        case .pickProvider(let summary):
                            ProviderCard(summary: summary, pick: store.pickProvider)
                        case .googleSignIn(let summary):
                            GoogleLoginCard(summary: summary, cancel: store.cancelGoogleLogin, login: store.startGoogleLogin)
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                inputBar
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.cyan)
        .animation(.snappy, value: store.pending)
        .sheet(isPresented: $showConversations) { ConversationList(store: store) }
        .sheet(isPresented: $showSettings) { MetricsPanel(store: store) }
        .sheet(isPresented: $showEngine) { EngineSheet(store: store).presentationDetents([.large]) }
    }

    // MARK: Cabeçalho

    private var header: some View {
        HStack(spacing: 12) {
            Button { showConversations = true } label: { Image(systemName: "line.3.horizontal") }
                .accessibilityLabel("Conversas")
            Spacer()
            Button { showEngine = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    Text(store.agent.chatName).font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Text(engineTag).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(store.generating)
            .accessibilityIdentifier("chat.engine")
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Ajustes")
            Button { store.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("Nova conversa")
                .disabled(store.generating)
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var engineTag: String {
        var bits: [String] = []
        if store.agent.thinkingSwitch, store.thinking != .off { bits.append(store.thinking == .on ? "pensa" : "auto") }
        if store.strategy != .direct { bits.append(store.strategy == .auto ? "adaptativo" : "planeja") }
        return bits.joined(separator: " · ")
    }

    // MARK: Geração ao vivo

    @ViewBuilder private var live: some View {
        ForEach(store.liveSteps) { StepRow(step: $0) }
        if store.streamingText.isEmpty {
            HStack(spacing: 10) {
                PulsingDot()
                Text(status).font(.system(.footnote, design: .rounded)).foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
        } else {
            Bubble(text: store.streamingText, role: .assistant)
        }
    }

    private var status: String {
        switch store.pending {
        case .pickProvider: return "Escolha a agenda…"
        case .googleSignIn: return "Entre com o Google…"
        case .confirm: return "Aguardando você…"
        case nil: break
        }
        if store.liveSteps.last?.status == .running { return "Executando…" }
        if store.thinkingLive { return "Pensando…" }
        if store.downloads.isEmpty == false { return "Baixando o modelo…" }
        return "Gerando…"
    }

    // MARK: Entrada

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.mode == .simulated {
                Text("Modo simulado: contatos Ana/Bruno/Carla; nada abre app.")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 6)
            }
            if let error = store.storageError ?? store.modelError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Pede qualquer coisa…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("chat.input")
                if store.generating {
                    Button { store.stop() } label: {
                        Image(systemName: "stop.fill").font(.callout.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(.white.opacity(0.18), in: Circle())
                    }
                    .accessibilityLabel("Parar")
                    .accessibilityIdentifier("chat.stop")
                } else {
                    Button {
                        store.send(draft)
                        draft = ""
                    } label: {
                        Image(systemName: "arrow.up").font(.callout.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Theme.accent, in: Circle())
                    }
                    .accessibilityLabel("Enviar")
                    .accessibilityIdentifier("chat.send")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

// MARK: - Peças

private struct EmptyState: View {
    let agent: Agent
    let pick: (String) -> Void
    /// (ícone, chip, rascunho). Pedido com pessoa termina em "pra " com o teclado aberto: quem completa
    /// o nome é o usuário, nunca um contato de exemplo que pode existir (ou não) na agenda.
    private let ideas = [
        ("car.fill", "Rota pra casa", "Rota pra casa"),
        ("message.fill", "Manda um zap pra alguém dizendo que chego em 10 min", "Manda um zap dizendo que chego em 10 min pra "),
        ("camera.fill", "Abre o Instagram da nasa", "Abre o Instagram da nasa"),
        ("bell.fill", "Me lembra amanhã às 9h de pagar o boleto", "Me lembra amanhã às 9h de pagar o boleto"),
        ("video.fill", "Cria uma reunião com Meet sexta às 15h", "Cria uma reunião com Meet sexta às 15h"),
        ("envelope.fill", "Manda um e-mail pra alguém confirmando a entrega", "Manda um e-mail confirmando a entrega pro "),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Oi.\nO que a gente\nfaz agora?")
                .font(Theme.title(40))
                .foregroundStyle(.white)
                .padding(.top, 28)
            Text("Rodando \(agent.chatName) aqui no seu iPhone. São exemplos: toque, complete e envie.")
                .font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
            FlowChips(items: ideas, pick: pick)
        }
        .padding(.bottom, 20)
    }
}

private struct FlowChips: View {
    let items: [(String, String, String)]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.1) { icon, text, draft in
                Button { pick(draft) } label: {
                    Label(text, systemImage: icon)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.white.opacity(0.07), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.accent).frame(width: 10, height: 10)
            .scaleEffect(on ? 1.25 : 0.8).opacity(on ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
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
            if role == .user { Spacer(minLength: 48) }
            Text(text)
                .textSelection(.enabled)
                .font(.system(.body, design: .rounded))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(background, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(role == .assistant ? 0.10 : 0), lineWidth: 1))
                .accessibilityIdentifier("chat.message.\(role.rawValue)")
            if role != .user { Spacer(minLength: 48) }
        }
    }

    private var shape: UnevenRoundedRectangle {
        role == .user
            ? UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
    }

    private var background: AnyShapeStyle {
        switch role {
        case .user: AnyShapeStyle(Theme.accent)
        case .assistant: AnyShapeStyle(.ultraThinMaterial)
        case .error: AnyShapeStyle(Color.red.opacity(0.22))
        }
    }
}

private struct StepRow: View {
    let step: ToolStep
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(color).font(.callout.weight(.semibold))
                        .symbolEffect(.pulse, isActive: step.status == .running || step.status == .awaitingConfirmation)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Self.name(step.tool)) · \(label)").font(.system(.caption, design: .rounded, weight: .bold))
                        Text(step.summary).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
                    }
                    Spacer()
                    if let ms = step.ms { Text("\(Int(ms)) ms").font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(step.output.isEmpty ? "—" : step.output)
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("chat.step.\(step.tool).\(step.status.rawValue)")
    }

    static func name(_ tool: String) -> String {
        switch tool {
        case "buscarContato": "Contato"
        case "ligar": "Ligar"
        case "ligarFaceTime": "FaceTime"
        case "enviarWhatsApp": "WhatsApp"
        case "enviarMensagem": "SMS"
        case "enviarEmail": "E-mail"
        case "abrirRota": "Rota"
        case "abrirSafari": "Safari"
        case "abrirApp": "App"
        case "rodarAtalho": "Atalho"
        case "criarEvento": "Evento"
        case "criarLembrete": "Lembrete"
        case "consultarCompromissos": "Agenda"
        default: tool
        }
    }

    private var label: String {
        switch step.status {
        case .awaitingConfirmation: "confirma?"
        case .running: "executando"
        case .ok: "feito"
        case .invalid: "argumento inválido"
        case .cancelled: "cancelado"
        case .failed: "falhou"
        case .duplicate: "repetição bloqueada"
        case .limit: "limite de chamadas"
        case .unknownTool: "ferramenta inexistente"
        case .permissionDenied: "sem permissão"
        case .reused: "reutilizado"
        case .stalled: "sem progresso"
        case .writeLimit: "limite de escrita"
        }
    }

    private var icon: String {
        switch step.status {
        case .ok, .reused: "checkmark.circle.fill"
        case .running: "bolt.fill"
        case .awaitingConfirmation: "hand.raised.fill"
        case .cancelled: "xmark.circle"
        case .permissionDenied: "lock.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch step.status {
        case .ok, .reused: .green
        case .running, .awaitingConfirmation: Theme.cyan
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
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("chat.provider.cancel")
                Spacer()
                Button("iPhone") { pick(ProviderPick(provider: .apple, remember: remember)) }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("chat.provider.apple")
                Button("Google") { pick(ProviderPick(provider: .google, remember: remember)) }
                    .buttonStyle(GradientButtonStyle())
                    .accessibilityIdentifier("chat.provider.google")
            }
        }
        .glassCard()
        .padding(.horizontal, 12).padding(.bottom, 6)
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
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("chat.google.cancel")
                Spacer()
                Button("Entrar", action: login)
                    .buttonStyle(GradientButtonStyle())
                    .accessibilityIdentifier("chat.google.login")
            }
        }
        .glassCard()
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

private struct ConfirmationCard: View {
    let proposal: ToolProposal
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Posso?", systemImage: "hand.raised.fill").font(Theme.title(20))
            Text(proposal.summary).font(.system(.body, design: .rounded, weight: .semibold)).accessibilityIdentifier("chat.confirm.summary")
            Text(StepRow.name(proposal.tool)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancelar", role: .cancel) { resolve(false) }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("chat.deny")
                Spacer()
                Button("Confirmar") { resolve(true) }
                    .buttonStyle(GradientButtonStyle())
                    .accessibilityIdentifier("chat.confirm")
            }
        }
        .glassCard()
        .padding(.horizontal, 12).padding(.bottom, 6)
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
    @State private var newShortcut = ""
    @State private var newFact = ""

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
                Section("iPhone como harness") {
                    Picker("Navegação", selection: Bindable(store).navigationApp) {
                        ForEach(HarnessSettings.NavigationApp.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(store.generating)
                    Toggle("Enviar e-mail direto pelo Gmail", isOn: Bindable(store).gmailDirect)
                        .disabled(store.generating)
                    Text("Com a conta Google conectada o e-mail sai sem abrir app. Desligado, abre o Gmail ou o Mail preenchido.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Apps por link: \(DeviceLinks.appNames.joined(separator: ", ")). WhatsApp e SMS abrem preenchidos; o iOS não deixa enviar sozinho.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Memória do assistente (\(store.memory.facts.count))") {
                    ForEach(store.memory.facts) { fact in
                        VStack(alignment: .leading) {
                            Text(fact.key).font(.caption).foregroundStyle(.secondary)
                            Text(fact.value)
                        }
                    }
                    .onDelete { offsets in offsets.map { store.memory.facts[$0].id }.forEach(store.memory.remove) }
                    HStack {
                        TextField("casa = Rua Exemplo, 100", text: $newFact)
                            .autocorrectionDisabled()
                        Button("Guardar") {
                            let parts = newFact.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                            if parts.count == 2 { store.memory.set(parts[0], parts[1]) }
                            newFact = ""
                        }
                        .disabled(!newFact.contains("="))
                    }
                    if !store.memory.facts.isEmpty {
                        Button("Esquecer tudo", role: .destructive) { store.memory.clear() }
                    }
                    Text("Aprendido das suas mensagens (\"minha casa fica na…\", \"lembre que…\"), sem rodar o modelo. Fica só no aparelho e vai junto do pedido: \"rota pra casa\" já sai com o endereço.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Atalhos que o assistente pode rodar") {
                    ForEach(store.shortcuts, id: \.self) { Text($0) }
                        .onDelete { store.removeShortcuts(at: $0) }
                    HStack {
                        TextField("Nome exato do atalho", text: $newShortcut)
                            .autocorrectionDisabled()
                        Button("Adicionar") {
                            store.addShortcut(newShortcut)
                            newShortcut = ""
                        }
                        .disabled(newShortcut.trimmingCharacters(in: .whitespaces).isEmpty || store.generating)
                    }
                    Text("O app Atalhos faz o que o iOS não expõe (alarme, nota, iMessage sem confirmar, ações do WhatsApp). O nome precisa ser igual ao do app Atalhos.")
                        .font(.caption).foregroundStyle(.secondary)
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
                        Text("Google Cloud → APIs e serviços → Credenciais → + Criar credenciais → ID do cliente OAuth → iOS. Bundle ID: davidoneil.MobileLLMChat. Ative também a Google Calendar API.")
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
            .navigationTitle("Ajustes")
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
