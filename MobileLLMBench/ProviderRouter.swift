import Foundation

enum CalendarProvider: String, Codable, Sendable, CaseIterable {
    case apple
    case google

    var label: String {
        switch self {
        case .apple: "Calendário do iPhone"
        case .google: "Google Agenda"
        }
    }
}

enum ProviderDecision: Equatable, Sendable {
    case resolved(CalendarProvider)
    case ask
}

struct ProviderPick: Equatable, Sendable {
    var provider: CalendarProvider
    var remember: Bool
}

/// Escolhe Google vs EventKit no runtime. O modelo não pergunta.
struct ProviderRouter: Sendable {
    var savedPreference: CalendarProvider?

    func decide(prompt: String, toolAgenda: CalendarProvider? = nil, meet: Bool = false) -> ProviderDecision {
        if meet || Self.wantsMeet(prompt) { return .resolved(.google) }
        let hints = Self.hints(in: prompt)
        if hints.count == 1 { return .resolved(hints[0]) }
        if hints.count > 1 { return .ask }
        if let toolAgenda { return .resolved(toolAgenda) }
        if let savedPreference { return .resolved(savedPreference) }
        return .ask
    }

    static func wantsMeet(_ prompt: String) -> Bool {
        let text = ContactMatch.normalize(prompt)
        if text.contains("google meet") || text.contains("videochamada") || text.contains("videoconferencia") {
            return true
        }
        return text.split(separator: " ").map(String.init).contains("meet")
    }

    static func hints(in prompt: String) -> [CalendarProvider] {
        let text = ContactMatch.normalize(prompt)
        var found: [CalendarProvider] = []
        if Self.mentionsGoogle(text) { found.append(.google) }
        if Self.mentionsApple(text) { found.append(.apple) }
        return found
    }

    private static func mentionsGoogle(_ text: String) -> Bool {
        if text.contains("google agenda") || text.contains("agenda google") || text.contains("google calendar") {
            return true
        }
        if text.contains("gcal") { return true }
        let words = text.split(separator: " ").map(String.init)
        return words.contains("google")
    }

    private static func mentionsApple(_ text: String) -> Bool {
        if text.contains("calendario do iphone") || text.contains("agenda do iphone")
            || text.contains("calendario da apple") || text.contains("apple calendar") {
            return true
        }
        let words = Set(text.split(separator: " ").map(String.init))
        return words.contains("iphone") || words.contains("eventkit")
    }
}

enum ProviderPreference {
    static let key = "chat.calendarProvider"

    static func load() -> CalendarProvider? {
        UserDefaults.standard.string(forKey: key).flatMap(CalendarProvider.init(rawValue:))
    }

    static func save(_ provider: CalendarProvider?) {
        if let provider {
            UserDefaults.standard.set(provider.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
