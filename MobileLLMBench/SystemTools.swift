import EventKit
import Foundation
import FoundationModels
import UIKit

actor ToolLog {
    struct Mark: Sendable {
        var name: String
        var detail: String
        var ms: Double
    }

    private var marks: [Mark] = []

    func add(name: String, detail: String, ms: Double) {
        marks.append(Mark(name: name, detail: detail, ms: ms))
    }

    func snapshot() -> [Mark] { marks }
}

func makeTools(log: ToolLog) -> [any Tool] {
    [
        CallTool(log: log),
        FaceTimeTool(log: log),
        MailTool(log: log),
        MessageTool(log: log),
        CalendarTool(log: log),
        ReminderTool(log: log),
        MapsTool(log: log),
        SafariTool(log: log),
    ]
}

private func traced(_ log: ToolLog, _ name: String, _ body: () async throws -> String) async throws -> String {
    let started = ProcessInfo.processInfo.systemUptime
    do {
        let output = try await body()
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        await log.add(name: name, detail: output, ms: ms)
        return output
    } catch {
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        await log.add(name: name, detail: error.localizedDescription, ms: ms)
        throw error
    }
}

// tel: — Phone.app. https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/PhoneLinks/PhoneLinks.html
struct CallTool: Tool {
    let log: ToolLog
    let name = "ligar"
    let description = "Liga para um número pelo app Telefone."

    @Generable
    struct Arguments {
        @Guide(description: "Número internacional começando com +")
        var numero: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await traced(log, name) { try await AppleActions.call(arguments.numero) }
    }
}

// facetime-audio: — FaceTime. Mesmo documento de URL schemes da Apple.
struct FaceTimeTool: Tool {
    let log: ToolLog
    let name = "ligarFaceTime"
    let description = "Inicia uma chamada de FaceTime áudio."

    @Generable
    struct Arguments {
        @Guide(description: "Número internacional começando com +")
        var numero: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await traced(log, name) { try await AppleActions.faceTime(arguments.numero) }
    }
}

// mailto: — Mail.
struct MailTool: Tool {
    let log: ToolLog
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
        try await traced(log, name) {
            try await AppleActions.mail(arguments.destinatario, assunto: arguments.assunto, corpo: arguments.corpo)
        }
    }
}

// sms: — Messages.
struct MessageTool: Tool {
    let log: ToolLog
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
        try await traced(log, name) {
            try await AppleActions.message(arguments.numero, corpo: arguments.corpo)
        }
    }
}

// EventKit EKEvent — Calendário.
struct CalendarTool: Tool {
    let log: ToolLog
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
        try await traced(log, name) {
            try await AppleActions.event(arguments.titulo, minutos: arguments.minutos)
        }
    }
}

// EventKit EKReminder — Lembretes.
struct ReminderTool: Tool {
    let log: ToolLog
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
        try await traced(log, name) {
            try await AppleActions.reminder(arguments.titulo, minutos: arguments.minutos)
        }
    }
}

// https://maps.apple.com — Mapas.
struct MapsTool: Tool {
    let log: ToolLog
    let name = "abrirRota"
    let description = "Abre uma rota de carro no Apple Mapas."

    @Generable
    struct Arguments {
        @Guide(description: "Destino, lugar ou endereço")
        var destino: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await traced(log, name) { try await AppleActions.maps(arguments.destino) }
    }
}

// https aberto pelo sistema — Safari.
struct SafariTool: Tool {
    let log: ToolLog
    let name = "abrirSafari"
    let description = "Abre uma página https no Safari."

    @Generable
    struct Arguments {
        @Guide(description: "URL https")
        var url: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await traced(log, name) { try await AppleActions.safari(arguments.url) }
    }
}

@MainActor
enum AppleActions {
    static func call(_ numero: String) async throws -> String {
        try await open(phoneURL("tel", numero))
    }

    static func faceTime(_ numero: String) async throws -> String {
        try await open(phoneURL("facetime-audio", numero))
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
        let body = encodedQuery(String(corpo.prefix(500)))
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
        guard (8...15).contains(digits.count), digits.contains("555") else {
            throw BenchError.failed("Neste teste o número precisa ser da faixa 555.")
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
