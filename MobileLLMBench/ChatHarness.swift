import Foundation
import FoundationModels

/// Mundo compartilhado das tools do harness no chat (ligar, SMS, Maps…).
/// O modo acompanha o picker Real/Simulado do ChatStore.
final class ChatWorldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _world: ToolWorld
    private var _google: any GoogleCalendarProviding

    init(mode: ExecutionMode = .real, google: (any GoogleCalendarProviding)? = nil) {
        _world = ToolWorld(fixtures: .standard, mode: mode)
        _google = google ?? (mode == .simulated ? SimulatedGoogleCalendarProvider() : LiveGoogleCalendarProvider.shared)
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

    static func tools(world: ChatWorldBox) -> [ChatTool] {
        ToolRegistry.tools.filter { ids.contains($0.id) }.map { wrap($0, world: world) }
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
            return "Abrir e-mail para \(arguments["destinatario"]?.text ?? "?") — \(arguments["assunto"]?.text ?? "")"
        case "abrirRota":
            return "Abrir rota no Mapas até “\(arguments["destino"]?.text ?? "?")”"
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
    let description = "Busca o número de telefone de um contato pelo nome."

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
    let description = "Abre o Mail com destinatário, assunto e corpo preenchidos."

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
    let description = "Abre uma rota de carro no Apple Mapas."

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
