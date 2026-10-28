import EventKit
import Foundation

// Ferramentas do chat. Catálogo próprio: o benchmark segue com ToolRegistry intacto (criarLembrete em minutos).

struct CalendarEntry: Codable, Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String? = nil
}

struct ReminderEntry: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var due: DateComponents?
}

enum ChatToolError: LocalizedError {
    case permissionDenied(String)
    /// A gravação falhou antes de acontecer: repetir não duplica.
    case notWritten(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let message), .notWritten(let message): message
        }
    }
}

protocol CalendarStore: Sendable {
    func events(from: Date, to: Date) async throws -> [CalendarEntry]
    /// Devolve o lembrete relido do armazenamento, não o rascunho.
    func addReminder(title: String, due: DateComponents?) async throws -> ReminderEntry
    func addEvent(title: String, start: Date, end: Date) async throws -> CalendarEntry
}

struct ChatClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var calendar = Calendar.current
}

/// EventKit real. `eventCalendarIDs`/`reminderListID` restringem a uma agenda de teste; nil usa as do usuário.
final class EventKitCalendarStore: CalendarStore, @unchecked Sendable {
    let store = EKEventStore()
    let eventCalendarIDs: [String]?
    let reminderListID: String?

    init(eventCalendarIDs: [String]? = nil, reminderListID: String? = nil) {
        self.eventCalendarIDs = eventCalendarIDs
        self.reminderListID = reminderListID
    }

    func events(from: Date, to: Date) async throws -> [CalendarEntry] {
        try await authorize(.event)
        let calendars = eventCalendarIDs?.compactMap { store.calendar(withIdentifier: $0) }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
            let place = $0.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CalendarEntry(
                title: $0.title ?? "(sem título)", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                location: (place?.isEmpty == false) ? place : nil)
        }
    }

    func addReminder(title: String, due: DateComponents?) async throws -> ReminderEntry {
        try await authorize(.reminder)
        guard let list = reminderListID.flatMap({ store.calendar(withIdentifier: $0) })
            ?? store.defaultCalendarForNewReminders()
            ?? store.calendars(for: .reminder).first(where: \.allowsContentModifications) else {
            throw BenchError.failed("Nenhuma lista de lembretes gravável.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        reminder.dueDateComponents = due
        if let due, due.hour != nil, let date = Calendar.current.date(from: due) {
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ChatToolError.notWritten("Lembretes recusou a gravação: \(error.localizedDescription)")
        }
        guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder,
              saved.title == title else {
            throw BenchError.failed("O lembrete foi enviado, mas não apareceu na releitura; confira no app Lembretes.")
        }
        return ReminderEntry(id: saved.calendarItemIdentifier, title: saved.title, due: saved.dueDateComponents)
    }

    func addEvent(title: String, start: Date, end: Date) async throws -> CalendarEntry {
        try await authorize(.event)
        guard let calendar = eventCalendarIDs?.compactMap({ store.calendar(withIdentifier: $0) }).first
            ?? store.defaultCalendarForNewEvents
            ?? store.calendars(for: .event).first(where: \.allowsContentModifications) else {
            throw BenchError.failed("Nenhuma agenda gravável.")
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ChatToolError.notWritten("Calendário recusou a gravação: \(error.localizedDescription)")
        }
        return CalendarEntry(title: event.title ?? title, start: event.startDate, end: event.endDate, allDay: event.isAllDay)
    }

    private func authorize(_ type: EKEntityType) async throws {
        let label = type == .event ? "Calendário" : "Lembretes"
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return
        case .notDetermined:
            let granted = type == .event
                ? try await store.requestFullAccessToEvents()
                : try await store.requestFullAccessToReminders()
            if !granted { throw ChatToolError.permissionDenied("Acesso a \(label) negado.") }
        default:
            throw ChatToolError.permissionDenied("Sem acesso total a \(label). Autorize em Ajustes > Privacidade.")
        }
    }
}

/// Armazenamento em memória para testes e para o modo simulado do chat.
actor SimulatedCalendarStore: CalendarStore {
    var storedEvents: [CalendarEntry]
    var reminders: [ReminderEntry] = []
    var denyEvents = false
    var denyReminders = false
    /// Quantas gravações seguidas falham antes de a próxima funcionar.
    var failingWrites = 0
    var writeAttempts = 0

    init(events: [CalendarEntry] = []) { storedEvents = events }

    func configure(denyEvents: Bool = false, denyReminders: Bool = false, failingWrites: Int = 0) {
        self.denyEvents = denyEvents
        self.denyReminders = denyReminders
        self.failingWrites = failingWrites
    }

    func events(from: Date, to: Date) async throws -> [CalendarEntry] {
        if denyEvents { throw ChatToolError.permissionDenied("Acesso a Calendário negado.") }
        return storedEvents.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
    }

    func addReminder(title: String, due: DateComponents?) async throws -> ReminderEntry {
        if denyReminders { throw ChatToolError.permissionDenied("Acesso a Lembretes negado.") }
        writeAttempts += 1
        if failingWrites > 0 {
            failingWrites -= 1
            throw ChatToolError.notWritten("Lembretes indisponível no momento (falha simulada).")
        }
        let entry = ReminderEntry(id: UUID().uuidString, title: title, due: due)
        reminders.append(entry)
        return entry
    }

    func addEvent(title: String, start: Date, end: Date) async throws -> CalendarEntry {
        if denyEvents { throw ChatToolError.permissionDenied("Acesso a Calendário negado.") }
        writeAttempts += 1
        if failingWrites > 0 {
            failingWrites -= 1
            throw ChatToolError.notWritten("Calendário indisponível no momento (falha simulada).")
        }
        let entry = CalendarEntry(title: title, start: start, end: end, allDay: false)
        storedEvents.append(entry)
        return entry
    }

    static func demo(clock: ChatClock) -> SimulatedCalendarStore {
        let cal = clock.calendar
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: clock.now())!)
        func at(_ hour: Int, _ minute: Int = 0) -> Date { cal.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)! }
        return SimulatedCalendarStore(events: [
            CalendarEntry(title: "Reunião com orientador", start: at(10), end: at(11), allDay: false),
            CalendarEntry(title: "Almoço com Ana", start: at(12, 30), end: at(13, 30), allDay: false),
        ])
    }
}

enum ChatDates {
    static func day(_ raw: String, clock: ChatClock) throws -> DateComponents {
        let cal = clock.calendar
        let text = ContactMatch.normalize(raw)
        let offsets = ["hoje": 0, "amanha": 1, "depois de amanha": 2]
        if let offset = offsets[text] {
            let date = cal.date(byAdding: .day, value: offset, to: clock.now())!
            return cal.dateComponents([.year, .month, .day], from: date)
        }
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            throw BenchError.failed("Data inválida: \(raw). Use AAAA-MM-DD.")
        }
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        // Rejeita datas normalizadas pelo Calendar, como 2026-02-30.
        guard comps.year == parts[0], comps.month == parts[1], comps.day == parts[2] else {
            throw BenchError.failed("Data inexistente: \(raw).")
        }
        return comps
    }

    static func time(_ raw: String) throws -> (hour: Int, minute: Int) {
        let text = raw.lowercased().filter { !$0.isWhitespace }
        guard let match = text.wholeMatch(of: /(\d{1,2})(?:[:h](\d{2}))?h?(?:min)?/),
              let hour = Int(match.1), (0...23).contains(hour) else {
            throw BenchError.failed("Hora inválida: \(raw). Use HH:mm.")
        }
        let minute = match.2.flatMap { Int($0) } ?? 0
        guard (0...59).contains(minute) else { throw BenchError.failed("Hora inválida: \(raw). Use HH:mm.") }
        return (hour, minute)
    }

    static func text(_ comps: DateComponents) -> String {
        var out = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        if let hour = comps.hour { out += String(format: " %02d:%02d", hour, comps.minute ?? 0) }
        return out
    }

    static func text(_ date: Date, calendar: Calendar, time: Bool = true) -> String {
        let comps = calendar.dateComponents(time ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
        return text(comps)
    }

    static func weekday(_ date: Date, calendar: Calendar) -> String {
        let names = ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"]
        return names[calendar.component(.weekday, from: date) - 1]
    }
}

struct ChatTool: AgentTool, Sendable {
    var id: String
    var toolDescription: String
    var parameters: [ToolParameter]
    var sideEffect: Bool
    /// Texto exato que o usuário confirma: horário já calculado (absoluto ou relativo).
    var preview: @Sendable ([String: ToolValue]) throws -> String
    var run: @Sendable ([String: ToolValue]) async throws -> ToolResult

    func validate(arguments: [String: ToolValue]) throws {
        for parameter in parameters where parameter.required && arguments[parameter.name] == nil {
            throw BenchError.failed("Falta o argumento \(parameter.name).")
        }
        _ = try preview(arguments)
    }

    func execute(arguments: [String: ToolValue], context: ToolExecutionContext) async throws -> ToolResult {
        try await run(arguments)
    }
}

enum ChatToolCatalog {
    static let queryName = "consultarCompromissos"
    static let queryDescription = "Lista os compromissos do Calendário. Sem datas, devolve os próximos 7 dias. Cada item traz um id estável (#N) para criarLembrete relativo."
    static let eventName = "criarEvento"
    static let eventDescription = """
Cria um evento na agenda (não é lembrete). titulo + data + hora. Duração padrão 60 min.
Meet/videoconferência: use esta ferramenta; o app escolhe Google Agenda vs Calendário do iPhone. Não pergunte ao usuário qual agenda.
Convidado: participantes com o e-mail que o usuário passou. Privado: privado=true. Não invente e-mail.
"""
    static let eventTimeDetail = "Hora de relógio HH:mm do início."
    static let durationDetail = "Duração em minutos (15–480). Omita para 60."
    static let queryDateDetail = "Dia, AAAA-MM-DD. Omita para os próximos 7 dias a partir de agora."
    static let queryDaysDetail = "Quantos dias a partir de data, contando com ela. Omita para um dia só."
    static let reminderName = "criarLembrete"
    static let reminderDescription = """
Cria um lembrete. Dois modos exclusivos — nunca misture:
(1) Absoluto: titulo + data + hora, quando o usuário deu um horário de relógio ("às 9h", "09:00").
(2) Relativo: titulo + evento (#N) + minutosAntes, só quando pediu "X minutos antes" de um compromisso já listado.
"às 9h" NÃO é minutosAntes=9.
"""
    static let eventDetail = "Id #N da consulta. Só com minutosAntes, e só se o usuário pediu minutos antes de um compromisso. Não use se ele deu horário de relógio."
    static let minutesBeforeDetail = "Deslocamento em minutos antes do #evento (ex.: 30). Nunca interprete 'às 9h' como 9 aqui."
    static let timeDetail = "Hora de relógio HH:mm (ex.: 09:00 para 'às 9h'). Modo absoluto; não combine com evento/minutosAntes."

    static func flag(_ arguments: [String: ToolValue], _ key: String) -> Bool {
        guard let value = arguments[key] else { return false }
        switch value {
        case .bool(let flag): return flag
        default:
            let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return text == "true" || text == "1" || text == "sim" || text == "yes"
        }
    }

    static func agenda(from arguments: [String: ToolValue]) -> CalendarProvider? {
        guard let raw = optionalText(arguments, "agenda") else { return nil }
        let text = ContactMatch.normalize(raw)
        if ["google", "gcal", "meet"].contains(text) { return .google }
        if ["iphone", "apple", "eventkit", "ios"].contains(text) { return .apple }
        return CalendarProvider(rawValue: text)
    }

    static func eventWindow(_ arguments: [String: ToolValue], clock: ChatClock) throws -> (start: Date, end: Date, title: String) {
        let title = String(try ToolChecks.requiredText(arguments, "titulo").prefix(120))
        guard let dayRaw = optionalText(arguments, "data") else { throw BenchError.failed("Falta a data do evento.") }
        guard let timeRaw = optionalText(arguments, "hora") else { throw BenchError.failed("Falta a hora do evento.") }
        var comps = try ChatDates.day(dayRaw, clock: clock)
        let time = try ChatDates.time(timeRaw)
        comps.hour = time.hour
        comps.minute = time.minute
        guard let start = clock.calendar.date(from: comps) else { throw BenchError.failed("Data inválida.") }
        if start < clock.now() {
            throw BenchError.failed("O horário \(ChatDates.text(comps)) já passou. Confirme a data com o usuário.")
        }
        var minutes = 60
        if let raw = arguments["duracaoMinutos"], raw.text.lowercased() != "null" {
            guard let value = raw.intValue, (15...480).contains(value) else {
                throw BenchError.failed("duracaoMinutos precisa ser um inteiro entre 15 e 480.")
            }
            minutes = value
        }
        let end = clock.calendar.date(byAdding: .minute, value: minutes, to: start)!
        return (start, end, title)
    }

    static func eventPreview(_ arguments: [String: ToolValue], clock: ChatClock) throws -> String {
        let (start, end, title) = try eventWindow(arguments, clock: clock)
        let when = "\(ChatDates.text(start, calendar: clock.calendar))–\(ChatDates.text(end, calendar: clock.calendar).suffix(5))"
        let meet = flag(arguments, "meet")
        let guests = try emails(from: arguments)
        let dest: String
        switch agenda(from: arguments) {
        case .google: dest = meet ? " no Google Agenda (Meet)" : " no Google Agenda"
        case .apple: dest = " no Calendário do iPhone"
        case nil: dest = meet ? " (Meet)" : ""
        }
        var extra = ""
        if flag(arguments, "privado") { extra += ", privado" }
        if !guests.isEmpty { extra += ", com \(guests.joined(separator: ", "))" }
        return "Criar evento “\(title)” \(when)\(dest)\(extra)"
    }

    static func emailsInText(_ text: String) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        for match in text.matches(of: /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/) {
            let raw = String(text[match.range])
            guard let email = try? email(raw), seen.insert(email).inserted else { continue }
            found.append(email)
        }
        return found
    }

    static func emails(from arguments: [String: ToolValue]) throws -> [String] {
        guard let raw = optionalText(arguments, "participantes") else { return [] }
        let parts = raw.split { ",; ".contains($0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return try parts.map(email)
    }

    static func email(_ raw: String) throws -> String {
        let to = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = to.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !to.contains(where: \.isWhitespace) else {
            throw BenchError.failed("E-mail de convidado inválido: \(raw).")
        }
        return to
    }

    static func optionalText(_ arguments: [String: ToolValue], _ key: String) -> String? {
        guard let value = arguments[key] else { return nil }
        let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.lowercased() == "null" ? nil : text
    }

    static func range(_ arguments: [String: ToolValue], clock: ChatClock) throws -> (Date, Date, String) {
        let cal = clock.calendar
        var days = 1
        if let raw = arguments["dias"], raw.text.lowercased() != "null" {
            guard let value = raw.intValue, (1...31).contains(value) else {
                throw BenchError.failed("dias precisa ser um inteiro entre 1 e 31.")
            }
            days = value
        }
        guard let first = try optionalText(arguments, "data").map({ try ChatDates.day($0, clock: clock) }) else {
            let now = clock.now()
            let span = arguments["dias"] == nil ? 7 : days
            return (now, cal.date(byAdding: .day, value: span, to: now)!, "próximos \(span) dias")
        }
        let start = cal.date(from: first)!
        let end = cal.date(byAdding: .day, value: days, to: start)!
        let lastDay = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: -1, to: end)!)
        let label = days == 1 ? ChatDates.text(first) : "\(ChatDates.text(first)) a \(ChatDates.text(lastDay))"
        return (start, end, label)
    }

    static func minutesBefore(_ arguments: [String: ToolValue]) throws -> Int? {
        guard let raw = optionalText(arguments, "minutosAntes"), raw != "0" else { return nil }
        guard let minutes = Int(raw), (1...1440).contains(minutes) else {
            throw BenchError.failed("minutosAntes precisa ser um inteiro entre 1 e 1440.")
        }
        return minutes
    }

    static func eventID(_ arguments: [String: ToolValue]) throws -> Int? {
        guard let raw = optionalText(arguments, "evento"), raw != "0" else { return nil }
        guard let id = Int(raw), id >= 1 else { throw BenchError.failed("evento precisa ser um inteiro ≥ 1 (#N da consulta).") }
        return id
    }

    /// Modelos preenchem evento/minutosAntes=0 junto com data/hora. Com horário de relógio, o absoluto ganha.
    static func normalizedReminder(_ arguments: [String: ToolValue]) -> [String: ToolValue] {
        var args = arguments
        if optionalText(args, "minutosAntes") == "0" { args.removeValue(forKey: "minutosAntes") }
        if optionalText(args, "evento") == "0" { args.removeValue(forKey: "evento") }
        if optionalText(args, "data") != nil || optionalText(args, "hora") != nil {
            args.removeValue(forKey: "evento")
            args.removeValue(forKey: "minutosAntes")
        }
        return args
    }

    /// Modo absoluto (data/hora) ou relativo (evento + minutosAntes).
    static func due(
        _ arguments: [String: ToolValue], clock: ChatClock, registry: EventRegistry, store: any CalendarStore
    ) async throws -> DateComponents? {
        let arguments = normalizedReminder(arguments)
        let relativeID = try eventID(arguments)
        let before = try minutesBefore(arguments)
        let day = try optionalText(arguments, "data").map { try ChatDates.day($0, clock: clock) }
        let time = try optionalText(arguments, "hora").map(ChatDates.time)
        if (relativeID == nil) != (before == nil) {
            throw BenchError.failed("Modo relativo exige evento e minutosAntes juntos.")
        }
        if let id = relativeID, let minutes = before {
            guard let event = registry.event(id) else {
                throw BenchError.failed("evento #\(id) desconhecido. Consulte a agenda primeiro e use o #N listado.")
            }
            guard try await registry.stillPresent(event, in: store, clock: clock) else {
                throw BenchError.failed("evento #\(id) não corresponde mais a um compromisso consultado.")
            }
            guard !event.allDay else { throw BenchError.failed("evento #\(id) é dia inteiro; use horário absoluto.") }
            let cal = clock.calendar
            guard let shifted = cal.date(byAdding: .minute, value: -minutes, to: event.start) else {
                throw BenchError.failed("Não foi possível calcular \(minutes) min antes do evento.")
            }
            if shifted < clock.now() {
                throw BenchError.failed("O horário \(ChatDates.text(shifted, calendar: cal)) já passou. Confirme com o usuário.")
            }
            return cal.dateComponents([.year, .month, .day, .hour, .minute], from: shifted)
        }
        guard day != nil || time != nil else { return nil }
        var comps = day ?? clock.calendar.dateComponents([.year, .month, .day], from: clock.now())
        if let time {
            comps.hour = time.hour
            comps.minute = time.minute
            if let date = clock.calendar.date(from: comps), date < clock.now() {
                throw BenchError.failed("O horário \(ChatDates.text(comps)) já passou. Confirme a data com o usuário.")
            }
        }
        return comps
    }

    static func make(
        store: any CalendarStore, clock: ChatClock = ChatClock(), registry: EventRegistry = EventRegistry(),
        world: ChatWorldBox = ChatWorldBox()
    ) -> [ChatTool] {
        let calendar: [ChatTool] = [
            ChatTool(
                id: queryName,
                toolDescription: queryDescription,
                parameters: [
                    ToolParameter(name: "data", type: "string", detail: queryDateDetail, required: false),
                    ToolParameter(name: "dias", type: "integer", detail: queryDaysDetail, required: false),
                ],
                sideEffect: false,
                preview: { "Consultar compromissos: \(try range($0, clock: clock).2)" },
                run: { arguments in
                    let (start, end, label) = try range(arguments, clock: clock)
                    let cal = clock.calendar
                    let found = try await store.events(from: start, to: end)
                    let zone = cal.timeZone.identifier
                    guard !found.isEmpty else {
                        return ToolResult(output: "Nenhum compromisso em \(label) (fuso \(zone)).", values: ["count": .int(0)])
                    }
                    let numbered = registry.register(found)
                    let lines = numbered.prefix(10).map { id, event in
                        let when = event.allDay
                            ? "\(ChatDates.text(event.start, calendar: cal, time: false)) dia inteiro"
                            : "\(ChatDates.text(event.start, calendar: cal)) até \(ChatDates.text(event.end, calendar: cal).suffix(5))"
                        let place = event.location.map { " @ \($0)" } ?? ""
                        return "#\(id). \(when) — \(event.title)\(place)"
                    }
                    let more = found.count > 10 ? "\n(+\(found.count - 10) não listados)" : ""
                    return ToolResult(
                        output: "Compromissos em \(label) (fuso \(zone)):\n" + lines.joined(separator: "\n") + more
                            + "\n(Use o #N em criarLembrete com evento e minutosAntes.)",
                        values: ["count": .int(found.count), "first": .string(found[0].title), "firstEvent": .int(numbered[0].0)])
                }),
            ChatTool(
                id: reminderName,
                toolDescription: reminderDescription,
                parameters: [
                    ToolParameter(name: "titulo", type: "string", detail: "O que lembrar, curto"),
                    ToolParameter(name: "data", type: "string", detail: "Dia AAAA-MM-DD (modo absoluto).", required: false),
                    ToolParameter(name: "hora", type: "string", detail: timeDetail, required: false),
                    ToolParameter(name: "evento", type: "integer", detail: eventDetail, required: false),
                    ToolParameter(name: "minutosAntes", type: "integer", detail: minutesBeforeDetail, required: false),
                ],
                sideEffect: true,
                preview: { arguments in
                    let arguments = normalizedReminder(arguments)
                    try validateReminderArgs(arguments, clock: clock, registry: registry)
                    let title = String(try ToolChecks.requiredText(arguments, "titulo").prefix(120))
                    let when: String
                    if let id = try eventID(arguments), let minutes = try minutesBefore(arguments),
                       let event = registry.event(id),
                       let shifted = clock.calendar.date(byAdding: .minute, value: -minutes, to: event.start) {
                        when = ChatDates.text(shifted, calendar: clock.calendar)
                    } else if let day = try optionalText(arguments, "data").map({ try ChatDates.day($0, clock: clock) })
                                ?? (optionalText(arguments, "hora") != nil
                                    ? clock.calendar.dateComponents([.year, .month, .day], from: clock.now()) : nil) {
                        var comps = day
                        if let timeText = optionalText(arguments, "hora") {
                            let t = try ChatDates.time(timeText)
                            comps.hour = t.hour
                            comps.minute = t.minute
                        }
                        when = ChatDates.text(comps)
                    } else {
                        when = "sem data"
                    }
                    return "Criar lembrete “\(title)” para \(when)"
                },
                run: { arguments in
                    let title = String(try ToolChecks.requiredText(arguments, "titulo").prefix(120))
                    let when = try await due(arguments, clock: clock, registry: registry, store: store)
                    let saved = try await store.addReminder(title: title, due: when)
                    let text = saved.due.map(ChatDates.text) ?? "sem data"
                    var values: [String: ToolValue] = ["titulo": .string(saved.title), "id": .string(saved.id)]
                    if let due = saved.due { values["due"] = .string(ChatDates.text(due)) }
                    return ToolResult(output: "Lembrete criado e conferido: “\(saved.title)” para \(text).", values: values)
                }),
            ChatTool(
                id: eventName,
                toolDescription: eventDescription,
                parameters: [
                    ToolParameter(name: "titulo", type: "string", detail: "Título curto do evento"),
                    ToolParameter(name: "data", type: "string", detail: "Dia AAAA-MM-DD."),
                    ToolParameter(name: "hora", type: "string", detail: eventTimeDetail),
                    ToolParameter(name: "duracaoMinutos", type: "integer", detail: durationDetail, required: false),
                    ToolParameter(name: "meet", type: "boolean", detail: "true para criar link do Google Meet.", required: false),
                    ToolParameter(name: "participantes", type: "string", detail: "E-mails dos convidados, separados por vírgula. Só se o usuário passou e-mail.", required: false),
                    ToolParameter(name: "privado", type: "boolean", detail: "true se o usuário pediu evento privado.", required: false),
                    ToolParameter(name: "agenda", type: "string", detail: "google ou iphone. O app preenche; omita se o pedido não disser.", required: false),
                ],
                sideEffect: true,
                preview: { try eventPreview($0, clock: clock) },
                run: { arguments in
                    let (start, end, title) = try eventWindow(arguments, clock: clock)
                    let meet = flag(arguments, "meet")
                    let guests = try emails(from: arguments)
                    let isPrivate = flag(arguments, "privado")
                    let provider = agenda(from: arguments) ?? .apple
                    if provider == .google {
                        let created = try await world.google.createEvent(
                            GoogleEventDraft(
                                title: title, start: start, end: end, timeZone: clock.calendar.timeZone,
                                meet: meet, attendees: guests, isPrivate: isPrivate))
                        var output = "Evento criado no Google Agenda: “\(created.title)”."
                        if isPrivate { output += " Privado." }
                        if !created.attendees.isEmpty {
                            output += " Convidados: \(created.attendees.joined(separator: ", "))."
                        }
                        if let meetURL = created.meetURL { output += " Meet: \(meetURL)" }
                        else if let html = created.htmlLink { output += " \(html)" }
                        var values: [String: ToolValue] = ["titulo": .string(created.title), "agenda": .string("google")]
                        if let meetURL = created.meetURL { values["meet"] = .string(meetURL) }
                        if !created.attendees.isEmpty { values["participantes"] = .string(created.attendees.joined(separator: ",")) }
                        if isPrivate { values["privado"] = .bool(true) }
                        return ToolResult(output: output, values: values)
                    }
                    if !guests.isEmpty || isPrivate {
                        throw BenchError.failed("Convidado e evento privado só funcionam no Google Agenda. Entre com o Google.")
                    }
                    let saved = try await store.addEvent(title: title, start: start, end: end)
                    return ToolResult(
                        output: "Evento criado no Calendário do iPhone: “\(saved.title)”.",
                        values: ["titulo": .string(saved.title), "agenda": .string("apple")])
                }),
        ]
        return calendar + ChatHarness.tools(world: world)
    }

    /// Validação síncrona dos modos (o preview relativo usa o registry).
    static func validateReminderArgs(_ arguments: [String: ToolValue], clock: ChatClock, registry: EventRegistry) throws {
        let arguments = normalizedReminder(arguments)
        let relativeID = try eventID(arguments)
        let before = try minutesBefore(arguments)
        if (relativeID == nil) != (before == nil) {
            throw BenchError.failed("Modo relativo exige evento e minutosAntes juntos.")
        }
        if let id = relativeID, let minutes = before {
            guard let event = registry.event(id) else {
                throw BenchError.failed("evento #\(id) desconhecido. Consulte a agenda primeiro e use o #N listado.")
            }
            guard !event.allDay else { throw BenchError.failed("evento #\(id) é dia inteiro; use horário absoluto.") }
            guard let shifted = clock.calendar.date(byAdding: .minute, value: -minutes, to: event.start) else {
                throw BenchError.failed("Não foi possível calcular \(minutes) min antes do evento.")
            }
            if shifted < clock.now() {
                throw BenchError.failed("O horário \(ChatDates.text(shifted, calendar: clock.calendar)) já passou. Confirme com o usuário.")
            }
            return
        }
        let day = try optionalText(arguments, "data").map { try ChatDates.day($0, clock: clock) }
        let clockTime = try optionalText(arguments, "hora").map(ChatDates.time)
        guard day != nil || clockTime != nil else { return }
        var comps = day ?? clock.calendar.dateComponents([.year, .month, .day], from: clock.now())
        if let clockTime {
            comps.hour = clockTime.hour
            comps.minute = clockTime.minute
            if let date = clock.calendar.date(from: comps), date < clock.now() {
                throw BenchError.failed("O horário \(ChatDates.text(comps)) já passou. Confirme a data com o usuário.")
            }
        }
    }
}

/// Ids #N estáveis durante uma tarefa. Novas consultas só acrescentam; nunca renumeram.
final class EventRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 1
    private var byID: [Int: CalendarEntry] = [:]

    func reset() {
        lock.lock(); defer { lock.unlock() }
        nextID = 1
        byID = [:]
    }

    func register(_ events: [CalendarEntry]) -> [(Int, CalendarEntry)] {
        lock.lock(); defer { lock.unlock() }
        return events.map { event in
            let id = nextID
            nextID += 1
            byID[id] = event
            return (id, event)
        }
    }

    func event(_ id: Int) -> CalendarEntry? {
        lock.lock(); defer { lock.unlock() }
        return byID[id]
    }

    /// Confere se ainda existe um compromisso com o mesmo título e início no store.
    func stillPresent(_ event: CalendarEntry, in store: any CalendarStore, clock: ChatClock) async throws -> Bool {
        let cal = clock.calendar
        let day = cal.startOfDay(for: event.start)
        let end = cal.date(byAdding: .day, value: 1, to: day)!
        let found = try await store.events(from: day, to: end)
        return found.contains { $0.title == event.title && $0.start == event.start && $0.allDay == event.allDay }
    }
}

/// Agenda e lista descartáveis para testes reais no iPhone. Nada fora delas é lido ou gravado.
enum ChatSandbox {
    static let name = "MobileLLMBench E2E"

    struct Handles: Sendable {
        var calendarID: String
        var listID: String
    }

    /// Cria agenda e lista de teste e semeia `events` (título, início, fim).
    static func prepare(_ store: EKEventStore, events: [(String, Date, Date)]) throws -> Handles {
        try cleanup(store)
        guard let eventSource = store.defaultCalendarForNewEvents?.source,
              let listSource = store.defaultCalendarForNewReminders()?.source else {
            throw BenchError.failed("Sem fonte gravável para a agenda de teste.")
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name
        calendar.source = eventSource
        try store.saveCalendar(calendar, commit: true)
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = name
        list.source = listSource
        try store.saveCalendar(list, commit: true)
        for (title, start, end) in events {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            event.startDate = start
            event.endDate = end
            try store.save(event, span: .thisEvent, commit: true)
        }
        return Handles(calendarID: calendar.calendarIdentifier, listID: list.calendarIdentifier)
    }

    static func reminders(_ store: EKEventStore, listID: String) async -> [ReminderEntry] {
        guard let list = store.calendar(withIdentifier: listID) else { return [] }
        let predicate = store.predicateForReminders(in: [list])
        let found: [ReminderEntry] = await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { items in
                done.resume(returning: (items ?? []).map {
                    ReminderEntry(id: $0.calendarItemIdentifier, title: $0.title, due: $0.dueDateComponents)
                })
            }
        }
        return found
    }

    static func cleanup(_ store: EKEventStore) throws {
        for calendar in store.calendars(for: .event) + store.calendars(for: .reminder) where calendar.title == name {
            try store.removeCalendar(calendar, commit: true)
        }
    }
}
