import Contacts
import EventKit
import Foundation
import FoundationModels
import UIKit

enum PhonePrompt {
    static let instructions = "Cumpra o pedido chamando as ferramentas necessárias, uma vez cada. Se o pedido citar uma pessoa pelo nome, busque o número com buscarContato antes. Copie os dados do pedido para os argumentos. Não afirme que a ação foi feita sem chamar a ferramenta."
    static let maxToolRounds = 4

    static func plan(_ prompt: String) -> String {
        "\(prompt)\n\nEscreva um plano curto, no máximo 5 linhas, para responder. Não chame ferramentas ainda."
    }

    static func action(_ prompt: String, plan: String) -> String {
        "\(prompt)\n\nPlano:\n\(plan)\n\nExecute o pedido chamando as ferramentas."
    }
}

func makeTools(log: ToolLog, world: ToolWorld) -> [any Tool] {
    [
        CallTool(log: log, world: world),
        FaceTimeTool(log: log, world: world),
        MailTool(log: log, world: world),
        MessageTool(log: log, world: world),
        CalendarTool(log: log, world: world),
        ReminderTool(log: log, world: world),
        MapsTool(log: log, world: world),
        SafariTool(log: log, world: world),
        ContactTool(log: log, world: world),
    ]
}

enum AppleToolBridge {
    static func install() {
        RealToolBridge.perform = { id, arguments in
            try await AppleActions.perform(id, arguments)
        }
    }
}

// Agenda sintética do benchmark. A execução real lê a agenda do iPhone em DeviceContacts.
enum Contacts {
    static let numbers = ["Ana": "+15550100", "Bruno": "+15550101", "Carla": "+15550102"]

    static func lookup(_ name: String) throws -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let hit = numbers.first(where: { $0.key.lowercased() == key }) else {
            throw BenchError.failed("Contato não encontrado: \(name).")
        }
        return "\(hit.key): \(hit.value)"
    }
}

enum DeviceContacts {
    static func lookup(_ name: String) async throws -> String {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            guard try await store.requestAccess(for: .contacts) else {
                throw BenchError.failed("Sem acesso aos Contatos.")
            }
        } else if status == .denied || status == .restricted {
            throw BenchError.failed("Sem acesso aos Contatos. Autorize em Ajustes.")
        }
        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
        ] as [CNKeyDescriptor]
        var candidates: [ContactMatch.Candidate] = []
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            guard let candidate = Self.candidate(contact) else { return }
            candidates.append(candidate)
        }
        let hits = ContactMatch.select(name, from: candidates)
        guard !hits.isEmpty else {
            let limited = CNContactStore.authorizationStatus(for: .contacts) == .limited
            let hint = limited ? " O app só vê os contatos que você selecionou em Ajustes." : ""
            throw BenchError.failed("Contato não encontrado: \(name).\(hint)")
        }
        return hits.map { "\($0.name): \($0.phone)" }.joined(separator: "\n")
    }

    private static func candidate(_ contact: CNContact) -> ContactMatch.Candidate? {
        let number = contact.phoneNumbers.first { $0.label == CNLabelPhoneNumberMobile }?.value.stringValue
            ?? contact.phoneNumbers.first?.value.stringValue
        guard let number, let phone = ContactMatch.dialable(number) else { return nil }
        let parts = [contact.givenName, contact.familyName].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let display = parts.joined(separator: " ")
        let title = display.isEmpty
            ? (contact.nickname.isEmpty ? contact.organizationName : contact.nickname)
            : display
        guard !title.isEmpty else { return nil }
        return ContactMatch.Candidate(
            name: title, phone: phone,
            aliases: [contact.givenName, contact.familyName, contact.nickname, contact.organizationName, display])
    }
}

struct ContactTool: Tool {
    let log: ToolLog
    let world: ToolWorld
    let name = "buscarContato"
    let description = "Busca o número de telefone de um contato pelo nome."

    @Generable
    struct Arguments {
        @Guide(description: "Nome do contato")
        var nome: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolRuntime.execute(id: name, arguments: ["nome": .string(arguments.nome)], world: world, log: log)
    }
}

// tel: — Phone.app. https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/PhoneLinks/PhoneLinks.html
struct CallTool: Tool {
    let log: ToolLog
    let world: ToolWorld
    let name = "ligar"
    let description = "Liga para um número pelo app Telefone."

    @Generable
    struct Arguments {
        @Guide(description: "Número internacional começando com +")
        var numero: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolRuntime.execute(id: name, arguments: ["numero": .string(arguments.numero)], world: world, log: log)
    }
}

// facetime-audio: — FaceTime. Mesmo documento de URL schemes da Apple.
struct FaceTimeTool: Tool {
    let log: ToolLog
    let world: ToolWorld
    let name = "ligarFaceTime"
    let description = "Inicia uma chamada de FaceTime áudio."

    @Generable
    struct Arguments {
        @Guide(description: "Número internacional começando com +")
        var numero: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolRuntime.execute(id: name, arguments: ["numero": .string(arguments.numero)], world: world, log: log)
    }
}

// mailto: — Mail.
struct MailTool: Tool {
    let log: ToolLog
    let world: ToolWorld
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
        try await ToolRuntime.execute(id: name, arguments: [
            "destinatario": .string(arguments.destinatario),
            "assunto": .string(arguments.assunto),
            "corpo": .string(arguments.corpo),
        ], world: world, log: log)
    }
}

// sms: — Messages.
struct MessageTool: Tool {
    let log: ToolLog
    let world: ToolWorld
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
        try await ToolRuntime.execute(id: name, arguments: [
            "numero": .string(arguments.numero), "corpo": .string(arguments.corpo),
        ], world: world, log: log)
    }
}

// EventKit EKEvent — Calendário.
struct CalendarTool: Tool {
    let log: ToolLog
    let world: ToolWorld
    let name = "criarEvento"
    let description = "Grava um evento no Calendário do iPhone."

    @Generable
    struct Arguments {
        @Guide(description: "Título do evento")
        var titulo: String
        @Guide(description: "Minutos a partir de agora", .range(1...1440))
        var minutos: Int
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolRuntime.execute(id: name, arguments: [
            "titulo": .string(arguments.titulo), "minutos": .int(arguments.minutos),
        ], world: world, log: log)
    }
}

// EventKit EKReminder — Lembretes.
struct ReminderTool: Tool {
    let log: ToolLog
    let world: ToolWorld
    let name = "criarLembrete"
    let description = "Grava um lembrete no app Lembretes."

    @Generable
    struct Arguments {
        @Guide(description: "Título do lembrete")
        var titulo: String
        @Guide(description: "Minutos a partir de agora", .range(1...1440))
        var minutos: Int
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolRuntime.execute(id: name, arguments: [
            "titulo": .string(arguments.titulo), "minutos": .int(arguments.minutos),
        ], world: world, log: log)
    }
}

// https://maps.apple.com — Mapas.
struct MapsTool: Tool {
    let log: ToolLog
    let world: ToolWorld
    let name = "abrirRota"
    let description = "Abre uma rota de carro no Apple Mapas."

    @Generable
    struct Arguments {
        @Guide(description: "Destino, lugar ou endereço")
        var destino: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolRuntime.execute(id: name, arguments: ["destino": .string(arguments.destino)], world: world, log: log)
    }
}

// https aberto pelo sistema — Safari.
struct SafariTool: Tool {
    let log: ToolLog
    let world: ToolWorld
    let name = "abrirSafari"
    let description = "Abre uma página https no Safari."

    @Generable
    struct Arguments {
        @Guide(description: "URL https")
        var url: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await ToolRuntime.execute(id: name, arguments: ["url": .string(arguments.url)], world: world, log: log)
    }
}

@MainActor
enum AppleActions {
    static func perform(_ id: String, _ arguments: [String: ToolValue]) async throws -> ToolResult {
        switch id {
        case "ligar":
            let numero = try ToolChecks.phone(arguments)
            return ToolResult(output: try await call(numero), values: ["numero": .string(numero)])
        case "ligarFaceTime":
            let numero = try ToolChecks.phone(arguments)
            return ToolResult(output: try await faceTime(numero), values: ["numero": .string(numero)])
        case "enviarEmail":
            let to = try ToolChecks.email(arguments)
            let subject = try ToolChecks.requiredText(arguments, "assunto")
            let body = try ToolChecks.requiredText(arguments, "corpo")
            let output = try await mail(to, assunto: subject, corpo: body)
            return ToolResult(output: output, values: [
                "destinatario": .string(to), "assunto": .string(subject), "corpo": .string(body),
            ])
        case "enviarWhatsApp":
            let numero = try ToolChecks.phone(arguments)
            let body = (try? ToolChecks.requiredText(arguments, "corpo")) ?? ""
            let output = try await whatsApp(numero, corpo: body)
            return ToolResult(output: output, values: ["numero": .string(numero), "corpo": .string(body)])
        case "enviarMensagem":
            let numero = try ToolChecks.phone(arguments)
            let body = try ToolChecks.requiredText(arguments, "corpo")
            let output = try await message(numero, corpo: body)
            return ToolResult(output: output, values: ["numero": .string(numero), "corpo": .string(body)])
        case "criarEvento":
            let title = try ToolChecks.requiredText(arguments, "titulo")
            let minutes = try ToolChecks.minutes(arguments)
            let output = try await event(title, minutos: minutes)
            return ToolResult(output: output, values: ["titulo": .string(title), "minutos": .int(minutes)])
        case "criarLembrete":
            let title = try ToolChecks.requiredText(arguments, "titulo")
            let minutes = try ToolChecks.minutes(arguments)
            let output = try await reminder(title, minutos: minutes)
            return ToolResult(output: output, values: ["titulo": .string(title), "minutos": .int(minutes)])
        case "abrirRota":
            let place = try ToolChecks.requiredText(arguments, "destino")
            return ToolResult(output: try await maps(place), values: ["destino": .string(place)])
        case "abrirSafari":
            let url = try ToolChecks.https(arguments)
            return ToolResult(output: try await safari(url), values: ["url": .string(url)])
        case "buscarContato":
            let name = try ToolChecks.requiredText(arguments, "nome")
            let output = try await DeviceContacts.lookup(name)
            let lines = output.split(separator: "\n").map(String.init)
            var values: [String: ToolValue] = ["nome": .string(name)]
            if lines.count == 1, let phone = lines[0].split(separator: " ").last.map(String.init) {
                values["phone"] = .string(phone)
            }
            return ToolResult(output: output, values: values)
        default:
            throw BenchError.failed("Ferramenta desconhecida: \(id).")
        }
    }

    static func call(_ numero: String) async throws -> String {
        try await open(phoneURL("tel", numero))
    }

    static func faceTime(_ numero: String) async throws -> String {
        try await open(phoneURL("facetime-audio", numero))
    }

    static func whatsApp(_ numero: String, corpo: String) async throws -> String {
        let digits = numero.filter(\.isNumber)
        let text = encodedQuery(String(corpo.prefix(300)))
        let native = URL(string: "whatsapp://send?phone=\(digits)" + (text.isEmpty ? "" : "&text=\(text)"))
        let web = URL(string: "https://wa.me/\(digits)" + (text.isEmpty ? "" : "?text=\(text)"))
        if let native, await UIApplication.shared.canOpenURL(native) {
            return try await open(native)
        }
        guard let web else { throw BenchError.failed("Não foi possível montar o link do WhatsApp.") }
        return try await open(web)
    }

    static func message(_ numero: String, corpo: String) async throws -> String {
        let phone = try phoneURL("sms", numero)
        let body = encodedQuery(String(corpo.prefix(300)))
        guard let url = URL(string: "\(phone.absoluteString)&body=\(body)") else {
            throw BenchError.failed("Não foi possível montar o link de mensagem.")
        }
        return try await open(url)
    }

    static func mail(_ destinatario: String, assunto: String, corpo: String) async throws -> String {
        let to = destinatario.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = to.split(separator: "@")
        guard parts.count == 2, !to.contains(where: { $0.isWhitespace }) else {
            throw BenchError.failed("Destinatário de e-mail inválido.")
        }
        let subject = encodedQuery(String(assunto.prefix(120)))
        let body = encodedQuery(String(corpo.prefix(2000)))
        guard let url = URL(string: "mailto:\(to)?subject=\(subject)&body=\(body)") else {
            throw BenchError.failed("Não foi possível montar o e-mail.")
        }
        return try await open(url)
    }

    static func maps(_ destino: String) async throws -> String {
        let query = destino.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw BenchError.failed("Destino vazio.") }
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "daddr", value: String(query.prefix(200))),
            URLQueryItem(name: "dirflg", value: "d"),
        ]
        guard let url = components.url else { throw BenchError.failed("Não foi possível montar a rota.") }
        return try await open(url)
    }

    static func safari(_ raw: String) async throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw BenchError.failed("A URL precisa ser https.")
        }
        return try await open(url)
    }

    static func event(_ titulo: String, minutos: Int) async throws -> String {
        let title = try itemTitle(titulo)
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw BenchError.failed("Sem acesso ao Calendário.")
        }
        guard let calendar = store.defaultCalendarForNewEvents
            ?? store.calendars(for: .event).first(where: \.allowsContentModifications) else {
            throw BenchError.failed("Nenhum calendário gravável.")
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = Date().addingTimeInterval(TimeInterval(minutos * 60))
        event.endDate = event.startDate.addingTimeInterval(3600)
        try store.save(event, span: .thisEvent)
        return "evento \(event.eventIdentifier ?? title)"
    }

    static func reminder(_ titulo: String, minutos: Int) async throws -> String {
        let title = try itemTitle(titulo)
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw BenchError.failed("Sem acesso aos Lembretes.")
        }
        guard let calendar = store.defaultCalendarForNewReminders()
            ?? store.calendars(for: .reminder).first(where: \.allowsContentModifications) else {
            throw BenchError.failed("Nenhuma lista de lembretes gravável.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        let due = Date().addingTimeInterval(TimeInterval(minutos * 60))
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: due)
        try store.save(reminder, commit: true)
        return "lembrete \(reminder.calendarItemIdentifier)"
    }

    private static func open(_ url: URL) async throws -> String {
        guard await UIApplication.shared.open(url) else {
            throw BenchError.failed("O iOS não abriu \(url.scheme ?? "o link").")
        }
        return url.absoluteString
    }

    private static func phoneURL(_ scheme: String, _ raw: String) throws -> URL {
        let trimmed = raw.filter { $0 == "+" || $0.isNumber }
        guard trimmed.first == "+" else {
            throw BenchError.failed("O número precisa começar com + e o DDI.")
        }
        let digits = trimmed.dropFirst()
        guard (8...15).contains(digits.count) else {
            throw BenchError.failed("O número precisa ter o DDI e entre 8 e 15 dígitos.")
        }
        guard let url = URL(string: "\(scheme):\(trimmed)") else {
            throw BenchError.failed("Não foi possível montar o link \(scheme).")
        }
        return url
    }

    private static func encodedQuery(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    private static func itemTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BenchError.failed("Título vazio.") }
        return String(title.prefix(120))
    }

    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
}
