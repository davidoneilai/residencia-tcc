import Foundation
import FoundationModels

/// Mundo compartilhado das tools do harness no chat (ligar, SMS, Maps…).
/// O modo acompanha o picker Real/Simulado do ChatStore.
/// Em modo real instala `AppleToolBridge`: sem ele, as tools que vêm direto do `ToolRegistry`
/// (ligar, ligarFaceTime, enviarMensagem, enviarWhatsApp, abrirSafari) falham com
/// "Execução real indisponível neste processo" — o bench instalava a ponte no BenchmarkRunner,
/// que não existe no target do chat.
final class ChatWorldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _world: ToolWorld
    private var _google: any GoogleCalendarProviding

    init(mode: ExecutionMode = .real, google: (any GoogleCalendarProviding)? = nil) {
        _world = ToolWorld(fixtures: .standard, mode: mode)
        _google = google ?? (mode == .simulated ? SimulatedGoogleCalendarProvider() : LiveGoogleCalendarProvider.shared)
        if mode == .real { AppleToolBridge.install() }
    }

    var world: ToolWorld {
        lock.lock(); defer { lock.unlock() }
        return _world
    }

    var google: any GoogleCalendarProviding {
        lock.lock(); defer { lock.unlock() }
        return _google
    }

    func setMode(_ mode: ExecutionMode) {
        lock.lock(); defer { lock.unlock() }
        _world = ToolWorld(fixtures: .standard, mode: mode)
        if mode == .real { AppleToolBridge.install() }
        if mode == .simulated {
            if !(_google is SimulatedGoogleCalendarProvider) {
                _google = SimulatedGoogleCalendarProvider()
            }
        } else {
            _google = LiveGoogleCalendarProvider.shared
        }
    }
}

/// Expõe um subconjunto do `ToolRegistry` no chat, sem duplicar a lógica de execução.
enum ChatHarness {
    /// Não inclui `criarEvento`/`criarLembrete` do bench (o chat tem EventKit próprio).
    static let ids: Set<String> = [
        "buscarContato", "ligar", "ligarFaceTime", "enviarMensagem", "enviarWhatsApp", "enviarEmail", "abrirRota", "abrirSafari",
    ]

    static func wrap(_ apple: AppleTool, world: ChatWorldBox) -> ChatTool {
        ChatTool(
            id: apple.id,
            toolDescription: apple.toolDescription,
            parameters: apple.parameters,
            sideEffect: apple.sideEffect,
            preview: { arguments in
                try apple.validate(arguments: arguments)
                return summary(id: apple.id, arguments: arguments)
            },
            run: { arguments in
                do {
                    return try await apple.execute(
                        arguments: arguments, context: ToolExecutionContext(world: world.world))
                } catch {
                    guard apple.id == "buscarContato" else { throw error }
                    let nome = arguments["nome"]?.text ?? ""
                    return ToolResult(
                        output: "Nenhum contato para “\(nome)”. Não invente sobrenome. Pergunte como o nome aparece na agenda e busque de novo com esse texto.",
                        values: ["count": .int(0)])
                }
            })
    }

    static let shortcutName = "rodarAtalho"
    static let openAppName = "abrirApp"
    /// Exemplos, não a lista inteira: o catálogo tem ~50 apps e a descrição vai em todo prompt.
    static let openAppDescription = "Abre um app do iPhone pelo nome (whatsapp, instagram, spotify, youtube, uber, ifood, nubank, fotos, música, ajustes…). alvo = perfil, busca ou destino (opcional)."

    /// Catálogo do chat: as tools do registro com execução real do iPhone, mais atalhos e apps.
    /// Em modo simulado nada abre app nem usa rede (fixtures do registro / respostas sintéticas).
    static func tools(world: ChatWorldBox) -> [ChatTool] {
        var list = ToolRegistry.tools.filter { ids.contains($0.id) }.map { wrap($0, world: world) }
        let simulated: @Sendable () -> Bool = { world.world.mode == .simulated }

        replace(&list, "buscarContato") { tool in
            tool.toolDescription = "Busca telefone e e-mail de um contato pelo nome."
            let fallback = tool.run
            tool.run = { arguments in
                guard !simulated() else { return try await fallback(arguments) }
                let name = try ToolChecks.requiredText(arguments, "nome")
                do {
                    let hits = try await ContactsIndex.shared.lookup(name)
                    var values: [String: ToolValue] = ["nome": .string(name), "count": .int(hits.count)]
                    if hits.count == 1 {
                        values["phone"] = .string(hits[0].phone)
                        if let email = hits[0].email { values["email"] = .string(email) }
                    }
                    var output = hits.map(\.line).joined(separator: "\n")
                    if hits.count > 1 { output += "\n\(hits.count) contatos com esse nome: pergunte qual antes de ligar ou enviar." }
                    return ToolResult(output: output, values: values)
                } catch let error as ChatToolError {
                    throw error
                } catch {
                    return ToolResult(
                        output: "Nenhum contato para “\(name)”. Não invente sobrenome. Pergunte como o nome aparece na agenda e busque de novo com esse texto.",
                        values: ["count": .int(0)])
                }
            }
        }
        replace(&list, "abrirRota") { tool in
            tool.toolDescription = "Abre a navegação de carro até um destino ou endereço no app de mapas do usuário."
            let fallback = tool.run
            tool.run = { arguments in
                guard !simulated() else { return try await fallback(arguments) }
                let place = try ToolChecks.requiredText(arguments, "destino")
                let app = HarnessSettings.navigationApp
                let output = try await DeviceLinks.navigate(place, app: app)
                return ToolResult(output: output, values: ["destino": .string(place), "app": .string(app.rawValue)])
            }
        }
        replace(&list, "enviarEmail") { tool in
            tool.toolDescription = "Envia um e-mail (pelo Gmail da conta conectada) ou abre o app de e-mail preenchido."
            let fallback = tool.run
            tool.run = { arguments in
                guard !simulated() else { return try await fallback(arguments) }
                let to = try ToolChecks.email(arguments)
                let subject = try ToolChecks.requiredText(arguments, "assunto")
                let body = try ToolChecks.requiredText(arguments, "corpo")
                let values: [String: ToolValue] = [
                    "destinatario": .string(to), "assunto": .string(subject), "corpo": .string(body),
                ]
                if HarnessSettings.gmailDirect, await world.google.isSignedIn() {
                    let id = try await world.google.sendMail(GoogleMailDraft(to: to, subject: subject, body: body))
                    return ToolResult(output: "E-mail enviado pelo Gmail para \(to): “\(subject)”.", values: values.merging(["id": .string(id)]) { a, _ in a })
                }
                let output = try await DeviceLinks.composeMail(to: to, subject: subject, body: body)
                return ToolResult(output: output, values: values)
            }
        }

        list.append(ChatTool(
            id: openAppName,
            toolDescription: ChatHarness.openAppDescription,
            parameters: [
                ToolParameter(name: "app", type: "string", detail: "Nome do app, em minúsculas."),
                ToolParameter(name: "alvo", type: "string", detail: "Perfil, termo de busca ou destino. Omita para só abrir.", required: false),
            ],
            sideEffect: true,
            preview: { arguments in
                let app = try ToolChecks.requiredText(arguments, "app")
                // Fora do catálogo também vale (tenta `<nome>://`); só recusa nome que não vira link.
                guard !DeviceLinks.appURLs(app, target: nil).isEmpty else {
                    throw BenchError.failed("Nome de app inválido: \(app).")
                }
                return summary(id: openAppName, arguments: arguments)
            },
            run: { arguments in
                let app = try ToolChecks.requiredText(arguments, "app")
                let target = (try? ToolChecks.requiredText(arguments, "alvo"))
                var values: [String: ToolValue] = ["app": .string(DeviceLinks.appName(app) ?? app)]
                if let target { values["alvo"] = .string(target) }
                if simulated() {
                    return ToolResult(output: "\(app) aberto (simulado).", values: values)
                }
                return ToolResult(output: try await DeviceLinks.openApp(app, target: target), values: values)
            }))

        let shortcuts = HarnessSettings.shortcuts
        if !shortcuts.isEmpty {
            list.append(ChatTool(
                id: shortcutName,
                toolDescription: "Roda um atalho do app Atalhos do usuário. Atalhos: \(shortcuts.joined(separator: "; ")). Use o nome exato.",
                parameters: [
                    ToolParameter(name: "nome", type: "string", detail: "Nome exato do atalho."),
                    ToolParameter(name: "entrada", type: "string", detail: "Texto de entrada para o atalho, se ele pedir.", required: false),
                ],
                sideEffect: true,
                preview: { arguments in
                    let name = try ToolChecks.requiredText(arguments, "nome")
                    guard shortcuts.contains(where: { ContactMatch.normalize($0) == ContactMatch.normalize(name) }) else {
                        throw BenchError.failed("Atalho desconhecido: \(name). Disponíveis: \(shortcuts.joined(separator: "; ")).")
                    }
                    return summary(id: shortcutName, arguments: arguments)
                },
                run: { arguments in
                    let typed = try ToolChecks.requiredText(arguments, "nome")
                    let name = shortcuts.first { ContactMatch.normalize($0) == ContactMatch.normalize(typed) } ?? typed
                    let input = try? ToolChecks.requiredText(arguments, "entrada")
                    var values: [String: ToolValue] = ["nome": .string(name)]
                    if let input { values["entrada"] = .string(input) }
                    if simulated() { return ToolResult(output: "Atalho “\(name)” rodado (simulado).", values: values) }
                    return ToolResult(output: try await DeviceLinks.runShortcut(name, input: input), values: values)
                }))
        }
        return list
    }

    private static func replace(_ list: inout [ChatTool], _ id: String, _ change: (inout ChatTool) -> Void) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
    }

    static func summary(id: String, arguments: [String: ToolValue]) -> String {
        switch id {
        case "buscarContato":
            return "Buscar contato “\(arguments["nome"]?.text ?? "?")”"
        case "ligar":
            return "Ligar para \(arguments["numero"]?.text ?? "?")"
        case "ligarFaceTime":
            return "FaceTime áudio com \(arguments["numero"]?.text ?? "?")"
        case "enviarMensagem":
            let body = String((arguments["corpo"]?.text ?? "").prefix(80))
            return "Enviar SMS para \(arguments["numero"]?.text ?? "?"): “\(body)”"
        case "enviarWhatsApp":
            let phone = arguments["numero"]?.text ?? "?"
            let body = arguments["corpo"]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return body.isEmpty ? "Abrir WhatsApp com \(phone)" : "Abrir WhatsApp com \(phone): “\(body.prefix(80))”"
        case "enviarEmail":
            return "Enviar e-mail para \(arguments["destinatario"]?.text ?? "?") — \(arguments["assunto"]?.text ?? "")"
        case "abrirRota":
            return "Abrir rota no \(HarnessSettings.navigationApp.title) até “\(arguments["destino"]?.text ?? "?")”"
        case openAppName:
            let app = DeviceLinks.appTitle(arguments["app"]?.text ?? "?")
            if let target = arguments["alvo"]?.text, !target.isEmpty { return "Abrir \(app) em “\(target)”" }
            return "Abrir \(app)"
        case shortcutName:
            let name = arguments["nome"]?.text ?? "?"
            if let input = arguments["entrada"]?.text, !input.isEmpty { return "Rodar atalho “\(name)” com “\(input.prefix(80))”" }
            return "Rodar atalho “\(name)”"
        case "abrirSafari":
            return "Abrir no Safari: \(arguments["url"]?.text ?? "?")"
        default:
            let args = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.text)" }.joined(separator: ", ")
            return "\(id)(\(args))"
        }
    }
}

// MARK: - Apple Foundation Models → ToolGate (confirmação e anti-duplicata)

struct ChatContactTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = "buscarContato"
    let description = "Busca telefone e e-mail de um contato pelo nome."

    @Generable
    struct Arguments {
        @Guide(description: "Nome do contato")
        var nome: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await gate.call(name, ["nome": .string(arguments.nome)])
    }
}

struct ChatCallTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = "ligar"
    let description = "Liga para um número pelo app Telefone."

    @Generable
    struct Arguments {
        @Guide(description: "Número internacional começando com +")
        var numero: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await gate.call(name, ["numero": .string(arguments.numero)])
    }
}

struct ChatFaceTimeTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = "ligarFaceTime"
    let description = "Inicia uma chamada de FaceTime áudio."

    @Generable
    struct Arguments {
        @Guide(description: "Número internacional começando com +")
        var numero: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await gate.call(name, ["numero": .string(arguments.numero)])
    }
}

struct ChatWhatsAppTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = "enviarWhatsApp"
    let description = "Abre a conversa no WhatsApp com o número (texto opcional). Não envia sozinho. Se o pedido citar uma pessoa, use buscarContato antes."

    @Generable
    struct Arguments {
        @Guide(description: "Número internacional começando com +")
        var numero: String
        @Guide(description: "Texto opcional; omita para só abrir a conversa.")
        var corpo: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var values = ["numero": ToolValue.string(arguments.numero)]
        if let corpo = arguments.corpo, !corpo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values["corpo"] = .string(corpo)
        }
        return try await gate.call(name, values)
    }
}

struct ChatMessageTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = "enviarMensagem"
    let description = "Abre o Mensagens com o número e o texto preenchidos."

    @Generable
    struct Arguments {
        @Guide(description: "Número internacional começando com +")
        var numero: String
        @Guide(description: "Texto da mensagem")
        var corpo: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await gate.call(name, ["numero": .string(arguments.numero), "corpo": .string(arguments.corpo)])
    }
}

struct ChatMailTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = "enviarEmail"
    let description = "Envia um e-mail (pelo Gmail da conta conectada) ou abre o app de e-mail preenchido."

    @Generable
    struct Arguments {
        @Guide(description: "E-mail do destinatário")
        var destinatario: String
        @Guide(description: "Assunto")
        var assunto: String
        @Guide(description: "Corpo do e-mail")
        var corpo: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await gate.call(name, [
            "destinatario": .string(arguments.destinatario),
            "assunto": .string(arguments.assunto),
            "corpo": .string(arguments.corpo),
        ])
    }
}

struct ChatMapsTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = "abrirRota"
    let description = "Abre a navegação de carro até um destino ou endereço no app de mapas do usuário."

    @Generable
    struct Arguments {
        @Guide(description: "Destino, lugar ou endereço")
        var destino: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await gate.call(name, ["destino": .string(arguments.destino)])
    }
}

struct ChatSafariTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = "abrirSafari"
    let description = "Abre uma página https no Safari."

    @Generable
    struct Arguments {
        @Guide(description: "URL https")
        var url: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await gate.call(name, ["url": .string(arguments.url)])
    }
}

struct ChatOpenAppTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = ChatHarness.openAppName
    let description = ChatHarness.openAppDescription

    @Generable
    struct Arguments {
        @Guide(description: "Nome do app, em minúsculas.")
        var app: String
        @Guide(description: "Perfil, termo de busca ou destino. Omita para só abrir.")
        var alvo: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var values = ["app": ToolValue.string(arguments.app)]
        if let alvo = arguments.alvo, !alvo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values["alvo"] = .string(alvo)
        }
        return try await gate.call(name, values)
    }
}

struct ChatShortcutTool: FoundationModels.Tool {
    let gate: ToolGate
    let name = ChatHarness.shortcutName
    let description: String

    init(gate: ToolGate, shortcuts: [String]) {
        self.gate = gate
        description = "Roda um atalho do app Atalhos do usuário. Atalhos: \(shortcuts.joined(separator: "; ")). Use o nome exato."
    }

    @Generable
    struct Arguments {
        @Guide(description: "Nome exato do atalho.")
        var nome: String
        @Guide(description: "Texto de entrada para o atalho, se ele pedir.")
        var entrada: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var values = ["nome": ToolValue.string(arguments.nome)]
        if let entrada = arguments.entrada, !entrada.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values["entrada"] = .string(entrada)
        }
        return try await gate.call(name, values)
    }
}
