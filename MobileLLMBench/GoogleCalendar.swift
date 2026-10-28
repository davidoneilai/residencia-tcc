import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

enum GoogleAuth {
    static let clientIDKey = "google.iosClientID"

    static var clientID: String {
        let pasted = normalized(UserDefaults.standard.string(forKey: clientIDKey) ?? "")
        if isClientID(pasted) { return pasted }
        let plist = normalized(Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "")
        return isClientID(plist) ? plist : ""
    }

    static func isClientID(_ raw: String) -> Bool {
        let text = normalized(raw)
        return text.contains(".apps.googleusercontent.com") && !text.contains("$(")
    }

    static func reversedScheme(_ id: String = clientID) -> String {
        guard isClientID(id), let head = id.split(separator: ".").first else { return "" }
        return "com.googleusercontent.apps.\(head)"
    }

    static func saveClientID(_ raw: String) {
        let text = normalized(raw)
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: clientIDKey)
        } else {
            UserDefaults.standard.set(text, forKey: clientIDKey)
        }
    }

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Client ID é da app (Google Cloud), não o e-mail/senha do usuário.
    static func missingClientIDMessage() -> String {
        let typed = normalized(UserDefaults.standard.string(forKey: clientIDKey) ?? "")
        if !typed.isEmpty, !isClientID(typed) {
            return "“\(typed)” não é um Client ID iOS. O valor termina com .apps.googleusercontent.com. Google Cloud → Credenciais → OAuth iOS, bundle davidoneil.MobileLLMBench. Cole em Desenvolvimento (medidor)."
        }
        return "Falta o Client ID iOS da app (não é login da sua conta). Google Cloud → Credenciais → OAuth iOS, bundle davidoneil.MobileLLMBench. Cole em Desenvolvimento (medidor)."
    }
}

struct GoogleEventDraft: Sendable {
    var title: String
    var start: Date
    var end: Date
    var timeZone: TimeZone
    var meet: Bool
    var attendees: [String] = []
    var isPrivate: Bool = false
}

struct GoogleEventResult: Sendable, Equatable {
    var title: String
    var htmlLink: String?
    var meetURL: String?
    var attendees: [String] = []
    var isPrivate: Bool = false
}

protocol GoogleCalendarProviding: Sendable {
    func isConfigured() async -> Bool
    func isSignedIn() async -> Bool
    func accountEmail() async -> String?
    func restoreSession() async
    func signIn() async throws
    func signOut() async
    func createEvent(_ draft: GoogleEventDraft) async throws -> GoogleEventResult
}

actor SimulatedGoogleCalendarProvider: GoogleCalendarProviding {
    var signedIn: Bool
    var configured: Bool
    private(set) var events: [GoogleEventResult] = []

    init(signedIn: Bool = true, configured: Bool = true) {
        self.signedIn = signedIn
        self.configured = configured
    }

    func setSignedIn(_ value: Bool) { signedIn = value }
    func isConfigured() async -> Bool { configured }
    func isSignedIn() async -> Bool { signedIn }
    func accountEmail() async -> String? { signedIn ? "simulado@local" : nil }
    func restoreSession() async {}

    func signIn() async throws {
        signedIn = true
    }

    func signOut() async {
        signedIn = false
    }

    func createdCount() -> Int { events.count }
    func lastAttendees() -> [String] { events.last?.attendees ?? [] }
    func lastPrivate() -> Bool { events.last?.isPrivate ?? false }
    func lastMeet() -> Bool { events.last?.meetURL != nil }

    func createEvent(_ draft: GoogleEventDraft) async throws -> GoogleEventResult {
        guard signedIn else {
            throw ChatToolError.permissionDenied("Entre com o Google para usar a Agenda.")
        }
        let meetURL = draft.meet ? "https://meet.google.com/sim-\(events.count + 1)" : nil
        let result = GoogleEventResult(
            title: draft.title, htmlLink: "https://calendar.google.com/sim", meetURL: meetURL,
            attendees: draft.attendees, isPrivate: draft.isPrivate)
        events.append(result)
        return result
    }
}

final class LiveGoogleCalendarProvider: GoogleCalendarProviding, @unchecked Sendable {
    static let shared = LiveGoogleCalendarProvider()
    static let calendarScope = "https://www.googleapis.com/auth/calendar.events"

    static var clientID: String { GoogleAuth.clientID }

    func isConfigured() async -> Bool { !Self.clientID.isEmpty }

    func isSignedIn() async -> Bool {
        #if canImport(GoogleSignIn)
        await MainActor.run { GIDSignIn.sharedInstance.currentUser != nil }
        #else
        false
        #endif
    }

    func accountEmail() async -> String? {
        #if canImport(GoogleSignIn)
        await MainActor.run { GIDSignIn.sharedInstance.currentUser?.profile?.email }
        #else
        nil
        #endif
    }

    func restoreSession() async {
        #if canImport(GoogleSignIn)
        guard GoogleAuth.isClientID(Self.clientID) else { return }
        _ = try? await restoreOnMain()
        #endif
    }

    func signIn() async throws {
        #if canImport(GoogleSignIn)
        try await signInOnMain()
        #else
        throw BenchError.failed("Google Sign-In não está ligado neste build.")
        #endif
    }

    func signOut() async {
        #if canImport(GoogleSignIn)
        await MainActor.run { GIDSignIn.sharedInstance.signOut() }
        #endif
    }

    func createEvent(_ draft: GoogleEventDraft) async throws -> GoogleEventResult {
        #if canImport(GoogleSignIn)
        let accessToken = try await MainActor.run {
            guard let user = GIDSignIn.sharedInstance.currentUser else {
                throw ChatToolError.permissionDenied("Entre com o Google para usar a Agenda.")
            }
            return user.accessToken.tokenString
        }
        return try await Self.postEvent(draft, accessToken: accessToken)
        #else
        throw BenchError.failed("Google Sign-In não está ligado neste build.")
        #endif
    }

    #if canImport(GoogleSignIn)
    @MainActor
    private func restoreOnMain() async throws {
        let clientID = Self.clientID
        guard GoogleAuth.isClientID(clientID) else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
    }

    @MainActor
    private func signInOnMain() async throws {
        let clientID = Self.clientID
        guard GoogleAuth.isClientID(clientID) else {
            throw BenchError.failed(GoogleAuth.missingClientIDMessage())
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let presenter = try Self.presenter()
        if let user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn(),
           (user.grantedScopes ?? []).contains(Self.calendarScope) {
            return
        }
        if let user = GIDSignIn.sharedInstance.currentUser {
            if (user.grantedScopes ?? []).contains(Self.calendarScope) { return }
            _ = try await user.addScopes([Self.calendarScope], presenting: presenter)
            return
        }
        _ = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenter, hint: nil, additionalScopes: [Self.calendarScope])
    }
    #endif

    #if canImport(UIKit)
    @MainActor
    private static func presenter() throws -> UIViewController {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        guard var top = window?.rootViewController else {
            throw BenchError.failed("Não há tela para o login do Google.")
        }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
    #endif

    private static func postEvent(_ draft: GoogleEventDraft, accessToken: String) async throws -> GoogleEventResult {
        var query: [String] = []
        if draft.meet { query.append("conferenceDataVersion=1") }
        if !draft.attendees.isEmpty { query.append("sendUpdates=all") }
        var url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        if !query.isEmpty {
            url = URL(string: url.absoluteString + "?" + query.joined(separator: "&"))!
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "summary": draft.title,
            "start": ["dateTime": rfc3339(draft.start, timeZone: draft.timeZone), "timeZone": draft.timeZone.identifier],
            "end": ["dateTime": rfc3339(draft.end, timeZone: draft.timeZone), "timeZone": draft.timeZone.identifier],
        ]
        if draft.meet {
            body["conferenceData"] = [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"],
                ]
            ]
        }
        if draft.isPrivate { body["visibility"] = "private" }
        if !draft.attendees.isEmpty {
            body["attendees"] = draft.attendees.map { ["email": $0] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = googleError(data) ?? "HTTP \(status)"
            throw ChatToolError.notWritten("Google Agenda recusou: \(message)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let invited = (json?["attendees"] as? [[String: Any]] ?? []).compactMap { $0["email"] as? String }
        return GoogleEventResult(
            title: (json?["summary"] as? String) ?? draft.title,
            htmlLink: json?["htmlLink"] as? String,
            meetURL: (json?["hangoutLink"] as? String) ?? meetEntry(json),
            attendees: invited.isEmpty ? draft.attendees : invited,
            isPrivate: (json?["visibility"] as? String) == "private" || draft.isPrivate)
    }

    private static func meetEntry(_ json: [String: Any]?) -> String? {
        let points = (json?["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]]
        return points?.first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String
    }

    private static func googleError(_ data: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String
    }

    private static func rfc3339(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset >= 0 ? "+" : "-"
        let abs = abs(offset)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            sign, abs / 3600, (abs % 3600) / 60)
    }
}
