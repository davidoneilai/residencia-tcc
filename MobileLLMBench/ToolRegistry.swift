import Foundation

enum ExecutionMode: String, Codable, Sendable {
    case real
    case simulated
}

enum ToolValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case list([ToolValue])

    var text: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .list(let values): values.map(\.text).joined(separator: ",")
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): value.rounded() == value ? Int(value) : nil
        case .string(let value): Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([ToolValue].self) {
            self = .list(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        self = .string(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        }
    }

    func matches(_ other: ToolValue) -> Bool {
        if let left = intValue, let right = other.intValue { return left == right }
        return text == other.text
    }
}

struct ToolParameter: Codable, Equatable, Sendable {
    var name: String
    var type: String
    var detail: String
    var required: Bool = true
}

struct ToolResult: Codable, Equatable, Sendable {
    var output: String
    var values: [String: ToolValue]
}

struct ToolCallRecord: Codable, Equatable, Sendable {
    var index: Int
    var tool: String
    var arguments: [String: ToolValue]
    var output: String?
    var values: [String: ToolValue]
    var error: String?
}

struct SimContact: Codable, Equatable, Sendable {
    var name: String
    var phone: String
}

struct SimItem: Codable, Equatable, Sendable {
    var title: String
    var minutes: Int
}

struct SimMessage: Codable, Equatable, Sendable {
    var phone: String
    var body: String
}

struct SimEmail: Codable, Equatable, Sendable {
    var recipient: String
    var subject: String
    var body: String
}

struct SimCall: Codable, Equatable, Sendable {
    var phone: String
    var kind: String
}

struct SimFixtures: Codable, Equatable, Sendable {
    var contacts: [SimContact] = []
    var events: [SimItem] = []
    var reminders: [SimItem] = []
    var messages: [SimMessage] = []
    var emails: [SimEmail] = []
    var calls: [SimCall] = []
    var routes: [String] = []
    var pages: [String] = []

    static let standard = SimFixtures(contacts: AppleBook.people.map { SimContact(name: $0.0, phone: $0.1) })
}

enum AppleBook {
    static let people: [(String, String)] = [
        ("Ana", "+15550100"), ("Bruno", "+15550101"), ("Carla", "+15550102"),
        ("Diego", "+15550103"), ("Elena", "+15550104"), ("Fabio", "+15550105"),
        ("Marina", "+15550106"), ("Pedro", "+15550107"), ("Sofia", "+15550108"),
        ("Lucas", "+15550109"),
    ]
}

final class ToolWorld: @unchecked Sendable {
    var fixtures: SimFixtures
    let mode: ExecutionMode

    init(fixtures: SimFixtures, mode: ExecutionMode) {
        self.fixtures = fixtures
        self.mode = mode
    }
}

struct ToolExecutionContext {
    var world: ToolWorld
}

protocol AgentTool {
    var id: String { get }
    var toolDescription: String { get }
    var parameters: [ToolParameter] { get }
    var sideEffect: Bool { get }

    func validate(arguments: [String: ToolValue]) throws
    func execute(arguments: [String: ToolValue], context: ToolExecutionContext) async throws -> ToolResult
}

enum RealToolBridge {
    nonisolated(unsafe) static var perform: ((String, [String: ToolValue]) async throws -> ToolResult)?
}

actor ToolLog {
    struct Mark: Sendable {
        var name: String
        var detail: String
        var ms: Double
        var started: TimeInterval
        var arguments: [String: ToolValue]
        var values: [String: ToolValue]
        var error: String?
        var index: Int

        func record() -> ToolCallRecord {
            ToolCallRecord(
                index: index, tool: name, arguments: arguments, output: error == nil ? detail : nil,
                values: values, error: error)
        }
    }

    private var marks: [Mark] = []

    func add(
        name: String, detail: String, ms: Double, started: TimeInterval,
        arguments: [String: ToolValue] = [:], values: [String: ToolValue] = [:], error: String? = nil
    ) {
        marks.append(Mark(
            name: name, detail: detail, ms: ms, started: started,
            arguments: arguments, values: values, error: error, index: marks.count))
    }

    func snapshot() -> [Mark] { marks }
}

enum ToolRuntime {
    static func execute(
        id: String,
        arguments: [String: ToolValue],
        world: ToolWorld,
        log: ToolLog,
        catalog: [any AgentTool]? = nil
    ) async throws -> String {
        let tools = catalog ?? ToolRegistry.tools
        let started = ProcessInfo.processInfo.systemUptime
        guard let tool = tools.first(where: { $0.id == id }) else {
            let message = "Ferramenta desconhecida: \(id)."
            await log.add(
                name: id, detail: message, ms: 0, started: started, arguments: arguments, error: message)
            throw BenchError.failed(message)
        }
        do {
            try tool.validate(arguments: arguments)
            let result = try await tool.execute(arguments: arguments, context: ToolExecutionContext(world: world))
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
            await log.add(
                name: id, detail: result.output, ms: ms, started: started,
                arguments: arguments, values: result.values)
            return result.output
        } catch {
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
            await log.add(
                name: id, detail: error.localizedDescription, ms: ms, started: started,
                arguments: arguments, error: error.localizedDescription)
            throw error
        }
    }
}

struct AppleTool: AgentTool, Sendable {
    var id: String
    var toolDescription: String
    var parameters: [ToolParameter]
    var sideEffect: Bool
    var check: @Sendable ([String: ToolValue]) throws -> Void
    var simulate: @Sendable ([String: ToolValue], ToolWorld) throws -> ToolResult

    func validate(arguments: [String: ToolValue]) throws {
        for parameter in parameters where parameter.required && arguments[parameter.name] == nil {
            throw BenchError.failed("Falta o argumento \(parameter.name).")
        }
        try check(arguments)
    }

    func execute(arguments: [String: ToolValue], context: ToolExecutionContext) async throws -> ToolResult {
        if context.world.mode == .simulated {
            return try simulate(arguments, context.world)
        }
        guard let perform = RealToolBridge.perform else {
            throw BenchError.failed("Execução real indisponível neste processo.")
        }
        return try await perform(id, arguments)
    }
}

enum ContactMatch {
    struct Candidate: Equatable {
        var name: String
        var phone: String
        var aliases: [String]
    }

    /// 2 = nome ou apelido inteiro; 1 = prefixo / apelido curto. Emoji e acento não entram na comparação.
    static func rank(_ query: String, names: [String]) -> Int {
        let needle = normalize(query)
        guard !needle.isEmpty else { return 0 }
        let qTokens = needle.split(separator: " ").map(String.init)
        var best = 0
        for name in names {
            let normalized = normalize(name)
            guard !normalized.isEmpty else { continue }
            let nTokens = normalized.split(separator: " ").map(String.init)
            if normalized == needle || nTokens.contains(needle) { return 2 }
            if qTokens.count > 1, qTokens.allSatisfy(nTokens.contains) { best = max(best, 2) }
            if let q = qTokens.first, q.count >= 2, nTokens.contains(where: { $0.hasPrefix(q) }) {
                best = max(best, 1)
            }
            // Contato "Ju" vs pedido "Julia Conceicao" (o modelo costuma expandir o apelido).
            if nTokens.count == 1, let nick = nTokens.first, (2...4).contains(nick.count),
               qTokens.contains(where: { $0.hasPrefix(nick) }) {
                best = max(best, 1)
            }
        }
        return best
    }

    static func select(_ query: String, from candidates: [Candidate]) -> [Candidate] {
        let hits = pick(query, from: candidates)
        if !hits.isEmpty { return hits }
        let tokens = normalize(query).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard tokens.count > 1 else { return [] }
        return pick(tokens[0], from: candidates)
    }

    private static func pick(_ query: String, from candidates: [Candidate]) -> [Candidate] {
        let ranked = candidates.map { ($0, rank(query, names: [$0.name] + $0.aliases)) }
        let best = ranked.map(\.1).max() ?? 0
        guard best > 0 else { return [] }
        return ranked.filter { $0.1 == best }.map(\.0)
    }

    /// Número discável. Sem DDI, um telefone brasileiro de 10 ou 11 dígitos ganha +55.
    static func dialable(_ raw: String) -> String? {
        let hadPlus = raw.contains("+")
        var digits = raw.filter(\.isNumber)
        if digits.hasPrefix("00") { digits.removeFirst(2) }
        guard !digits.isEmpty else { return nil }
        if hadPlus || digits.hasPrefix("55") && (12...13).contains(digits.count) {
            return (8...15).contains(digits.count) ? "+\(digits)" : nil
        }
        if (10...11).contains(digits.count) { return "+55\(digits)" }
        return (8...15).contains(digits.count) ? "+\(digits)" : nil
    }

    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum ToolChecks {
    static func requiredText(_ arguments: [String: ToolValue], _ key: String) throws -> String {
        guard let value = arguments[key] else { throw BenchError.failed("Falta o argumento \(key).") }
        if case .list = value { throw BenchError.failed("\(key) não é texto.") }
        let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BenchError.failed("\(key) vazio.") }
        return text
    }

    static func phone(_ arguments: [String: ToolValue], _ key: String = "numero") throws -> String {
        let raw = try requiredText(arguments, key)
        let trimmed = raw.filter { $0 == "+" || $0.isNumber }
        guard trimmed.first == "+" else { throw BenchError.failed("O número precisa começar com + e o DDI.") }
        guard (8...15).contains(trimmed.dropFirst().count) else {
            throw BenchError.failed("O número precisa ter o DDI e entre 8 e 15 dígitos.")
        }
        return trimmed
    }

    static func minutes(_ arguments: [String: ToolValue]) throws -> Int {
        guard let value = arguments["minutos"] else { throw BenchError.failed("Falta o argumento minutos.") }
        guard let number = value.intValue else { throw BenchError.failed("minutos não é um número.") }
        guard (1...1440).contains(number) else { throw BenchError.failed("minutos fora de 1...1440.") }
        return number
    }

    static func email(_ arguments: [String: ToolValue]) throws -> String {
        let to = try requiredText(arguments, "destinatario")
        let parts = to.split(separator: "@")
        guard parts.count == 2, !to.contains(where: \.isWhitespace) else {
            throw BenchError.failed("Destinatário de e-mail inválido.")
        }
        return to
    }

    static func https(_ arguments: [String: ToolValue]) throws -> String {
        let text = try requiredText(arguments, "url")
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw BenchError.failed("A URL precisa ser https.")
        }
        return text
    }
}

enum ToolRegistry {
    static let tools: [AppleTool] = [
        AppleTool(
            id: "ligar",
            toolDescription: "Liga para um número pelo app Telefone.",
            parameters: [ToolParameter(name: "numero", type: "string", detail: "Número internacional começando com +")],
            sideEffect: true,
            check: { _ = try ToolChecks.phone($0) },
            simulate: { arguments, world in
                let phone = try ToolChecks.phone(arguments)
                world.fixtures.calls.append(SimCall(phone: phone, kind: "phone"))
                return ToolResult(output: "tel:\(phone)", values: ["numero": .string(phone)])
            }),
        AppleTool(
            id: "ligarFaceTime",
            toolDescription: "Inicia uma chamada de FaceTime áudio.",
            parameters: [ToolParameter(name: "numero", type: "string", detail: "Número internacional começando com +")],
            sideEffect: true,
            check: { _ = try ToolChecks.phone($0) },
            simulate: { arguments, world in
                let phone = try ToolChecks.phone(arguments)
                world.fixtures.calls.append(SimCall(phone: phone, kind: "facetime"))
                return ToolResult(output: "facetime-audio:\(phone)", values: ["numero": .string(phone)])
            }),
        AppleTool(
            id: "enviarEmail",
            toolDescription: "Abre o Mail com destinatário, assunto e corpo preenchidos.",
            parameters: [
                ToolParameter(name: "destinatario", type: "string", detail: "E-mail do destinatário"),
                ToolParameter(name: "assunto", type: "string", detail: "Assunto"),
                ToolParameter(name: "corpo", type: "string", detail: "Corpo do e-mail"),
            ],
            sideEffect: true,
            check: { arguments in
                _ = try ToolChecks.email(arguments)
                _ = try ToolChecks.requiredText(arguments, "assunto")
                _ = try ToolChecks.requiredText(arguments, "corpo")
            },
            simulate: { arguments, world in
                let to = try ToolChecks.email(arguments)
                let subject = try ToolChecks.requiredText(arguments, "assunto")
                let body = try ToolChecks.requiredText(arguments, "corpo")
                world.fixtures.emails.append(SimEmail(recipient: to, subject: subject, body: body))
                return ToolResult(output: "mailto:\(to)", values: [
                    "destinatario": .string(to), "assunto": .string(subject), "corpo": .string(body),
                ])
            }),
        AppleTool(
            id: "enviarWhatsApp",
            toolDescription: "Abre a conversa no WhatsApp com o número (e texto opcional). Não envia sozinho: o usuário confirma no Zap. Se o pedido citar uma pessoa, busque o número com buscarContato antes.",
            parameters: [
                ToolParameter(name: "numero", type: "string", detail: "Número internacional começando com +"),
                ToolParameter(name: "corpo", type: "string", detail: "Texto opcional; omita para só abrir a conversa.", required: false),
            ],
            sideEffect: true,
            check: { arguments in
                _ = try ToolChecks.phone(arguments)
            },
            simulate: { arguments, world in
                let phone = try ToolChecks.phone(arguments)
                let body = (try? ToolChecks.requiredText(arguments, "corpo")) ?? ""
                world.fixtures.messages.append(SimMessage(phone: phone, body: body.isEmpty ? "(whatsapp)" : body))
                return ToolResult(
                    output: "whatsapp:\(phone)\(body.isEmpty ? "" : " texto:\(body)")",
                    values: ["numero": .string(phone), "corpo": .string(body)])
            }),
        AppleTool(
            id: "enviarMensagem",
            toolDescription: "Abre o Mensagens com o número e o texto preenchidos.",
            parameters: [
                ToolParameter(name: "numero", type: "string", detail: "Número internacional começando com +"),
                ToolParameter(name: "corpo", type: "string", detail: "Texto da mensagem"),
            ],
            sideEffect: true,
            check: { arguments in
                _ = try ToolChecks.phone(arguments)
                _ = try ToolChecks.requiredText(arguments, "corpo")
            },
            simulate: { arguments, world in
                let phone = try ToolChecks.phone(arguments)
                let body = try ToolChecks.requiredText(arguments, "corpo")
                world.fixtures.messages.append(SimMessage(phone: phone, body: body))
                return ToolResult(output: "sms:\(phone)", values: ["numero": .string(phone), "corpo": .string(body)])
            }),
        AppleTool(
            id: "criarEvento",
            toolDescription: "Grava um evento no Calendário do iPhone.",
            parameters: [
                ToolParameter(name: "titulo", type: "string", detail: "Título do evento"),
                ToolParameter(name: "minutos", type: "integer", detail: "Minutos a partir de agora"),
            ],
            sideEffect: true,
            check: { arguments in
                _ = try ToolChecks.requiredText(arguments, "titulo")
                _ = try ToolChecks.minutes(arguments)
            },
            simulate: { arguments, world in
                let title = try ToolChecks.requiredText(arguments, "titulo")
                let minutes = try ToolChecks.minutes(arguments)
                world.fixtures.events.append(SimItem(title: title, minutes: minutes))
                return ToolResult(output: "evento \(title)", values: ["titulo": .string(title), "minutos": .int(minutes)])
            }),
        AppleTool(
            id: "criarLembrete",
            toolDescription: "Grava um lembrete no app Lembretes.",
            parameters: [
                ToolParameter(name: "titulo", type: "string", detail: "Título do lembrete"),
                ToolParameter(name: "minutos", type: "integer", detail: "Minutos a partir de agora"),
            ],
            sideEffect: true,
            check: { arguments in
                _ = try ToolChecks.requiredText(arguments, "titulo")
                _ = try ToolChecks.minutes(arguments)
            },
            simulate: { arguments, world in
                let title = try ToolChecks.requiredText(arguments, "titulo")
                let minutes = try ToolChecks.minutes(arguments)
                world.fixtures.reminders.append(SimItem(title: title, minutes: minutes))
                return ToolResult(output: "lembrete \(title)", values: ["titulo": .string(title), "minutos": .int(minutes)])
            }),
        AppleTool(
            id: "abrirRota",
            toolDescription: "Abre uma rota de carro no Apple Mapas.",
            parameters: [ToolParameter(name: "destino", type: "string", detail: "Destino, lugar ou endereço")],
            sideEffect: true,
            check: { _ = try ToolChecks.requiredText($0, "destino") },
            simulate: { arguments, world in
                let place = try ToolChecks.requiredText(arguments, "destino")
                world.fixtures.routes.append(place)
                return ToolResult(output: "maps:\(place)", values: ["destino": .string(place)])
            }),
        AppleTool(
            id: "abrirSafari",
            toolDescription: "Abre uma página https no Safari.",
            parameters: [ToolParameter(name: "url", type: "string", detail: "URL https")],
            sideEffect: true,
            check: { _ = try ToolChecks.https($0) },
            simulate: { arguments, world in
                let url = try ToolChecks.https(arguments)
                world.fixtures.pages.append(url)
                return ToolResult(output: url, values: ["url": .string(url)])
            }),
        AppleTool(
            id: "buscarContato",
            toolDescription: "Busca o número de telefone de um contato pelo nome.",
            parameters: [ToolParameter(name: "nome", type: "string", detail: "Nome do contato")],
            sideEffect: false,
            check: { _ = try ToolChecks.requiredText($0, "nome") },
            simulate: { arguments, world in
                let name = try ToolChecks.requiredText(arguments, "nome")
                guard let hit = world.fixtures.contacts.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                    throw BenchError.failed("Contato não encontrado: \(name).")
                }
                return ToolResult(output: "\(hit.name): \(hit.phone)", values: [
                    "nome": .string(hit.name), "phone": .string(hit.phone),
                ])
            }),
    ]

    static func tool(_ id: String) -> AppleTool? { tools.first { $0.id == id } }

    static var sideEffects: Set<String> { Set(tools.filter(\.sideEffect).map(\.id)) }
}
