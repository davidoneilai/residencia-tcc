import Contacts
import Foundation
import UIKit

// Harness real do iPhone para o chat: navegação (Waze/Mapas), e-mail pelo Gmail, apps por link
// universal, ponte com o app Atalhos e índice de contatos em memória.
//
// Regras de custo: nada aqui chama o modelo; tudo é determinístico e roda em milissegundos.
// Apps: scheme nativo primeiro e link universal (https) depois; `open` falha sozinho se o app não
// existe, sem LSApplicationQueriesSchemes. Waze, Gmail e Google Maps ainda testam com canOpenURL.

// MARK: - Preferências

enum HarnessSettings {
    enum NavigationApp: String, CaseIterable, Identifiable, Sendable {
        case waze, apple, google
        var id: String { rawValue }
        var title: String {
            switch self {
            case .waze: "Waze"
            case .apple: "Apple Mapas"
            case .google: "Google Maps"
            }
        }
    }

    nonisolated(unsafe) static var defaults = UserDefaults.standard
    static let navigationKey = "harness.navigationApp"
    static let shortcutsKey = "harness.shortcuts"
    static let gmailDirectKey = "harness.gmailDirect"

    static var navigationApp: NavigationApp {
        get { NavigationApp(rawValue: defaults.string(forKey: navigationKey) ?? "") ?? .waze }
        set { defaults.set(newValue.rawValue, forKey: navigationKey) }
    }

    /// Nomes exatos dos atalhos do usuário que o modelo pode rodar. Vazio = ferramenta ausente do prompt.
    static var shortcuts: [String] {
        get { (defaults.stringArray(forKey: shortcutsKey) ?? []).map(Self.trim).filter { !$0.isEmpty } }
        set { defaults.set(newValue.map(Self.trim).filter { !$0.isEmpty }, forKey: shortcutsKey) }
    }

    /// Envia pelo Gmail (API) quando a conta Google está conectada; senão abre o Gmail/Mail preenchido.
    static var gmailDirect: Bool {
        get { defaults.object(forKey: gmailDirectKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: gmailDirectKey) }
    }

    private static func trim(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Contatos em memória

struct ContactHit: Equatable, Sendable {
    var name: String
    var phone: String
    var email: String?
    var aliases: [String]

    var line: String {
        var text = "\(name): \(phone)"
        if let email { text += " · e-mail \(email)" }
        return text
    }
}

/// Agenda inteira lida uma vez e mantida em memória; invalida quando o iOS avisa que os Contatos mudaram.
/// Antes cada busca enumerava a agenda de novo (centenas de ms numa agenda grande).
actor ContactsIndex {
    static let shared = ContactsIndex()

    private var hits: [ContactHit]?
    private var observing = false
    private let store = CNContactStore()

    func invalidate() { hits = nil }

    /// Só carrega se o usuário já autorizou; nunca mostra o pedido de permissão ao abrir o app.
    func prewarm() async {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return }
        _ = try? await all()
    }

    func lookup(_ name: String) async throws -> [ContactHit] {
        let all = try await all()
        let hits = Self.select(name, from: all)
        if hits.isEmpty {
            let limited = CNContactStore.authorizationStatus(for: .contacts) == .limited
            let hint = limited ? " O app só vê os contatos que você selecionou em Ajustes." : ""
            throw BenchError.failed("Contato não encontrado: \(name).\(hint)")
        }
        return hits
    }

    /// Foto pequena do contato para o cartão de confirmação. Só lê se a agenda já estiver autorizada.
    func thumbnail(phone: String) -> Data? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return nil }
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
        let keys = [CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        return (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?
            .lazy.compactMap(\.thumbnailImageData).first
    }

    static func select(_ query: String, from hits: [ContactHit]) -> [ContactHit] {
        let candidates = hits.map { ContactMatch.Candidate(name: $0.name, phone: $0.phone, aliases: $0.aliases) }
        let chosen = ContactMatch.select(query, from: candidates)
        return hits.filter { hit in chosen.contains { $0.name == hit.name && $0.phone == hit.phone } }
    }

    private func all() async throws -> [ContactHit] {
        if let hits { return hits }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            guard try await store.requestAccess(for: .contacts) else {
                throw ChatToolError.permissionDenied("Sem acesso aos Contatos.")
            }
        } else if status == .denied || status == .restricted {
            throw ChatToolError.permissionDenied("Sem acesso aos Contatos. Autorize em Ajustes.")
        }
        startObserving()
        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        var loaded: [ContactHit] = []
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            if let hit = Self.hit(contact) { loaded.append(hit) }
        }
        hits = loaded
        return loaded
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.invalidate() }
        }
    }

    private static func hit(_ contact: CNContact) -> ContactHit? {
        let number = contact.phoneNumbers.first { $0.label == CNLabelPhoneNumberMobile }?.value.stringValue
            ?? contact.phoneNumbers.first?.value.stringValue
        guard let number, let phone = ContactMatch.dialable(number) else { return nil }
        let parts = [contact.givenName, contact.familyName].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let display = parts.joined(separator: " ")
        let title = display.isEmpty
            ? (contact.nickname.isEmpty ? contact.organizationName : contact.nickname)
            : display
        guard !title.isEmpty else { return nil }
        let email = contact.emailAddresses.first.map { String($0.value) }
        return ContactHit(
            name: title, phone: phone, email: email,
            aliases: [contact.givenName, contact.familyName, contact.nickname, contact.organizationName, display])
    }
}

// MARK: - Links e apps

enum DeviceLinks {
    /// App que o modelo pode abrir pelo nome. A Siri abre qualquer app por API privada do SpringBoard;
    /// app de terceiro só tem URL scheme (`native`) e link universal (`web`, abre o app se instalado).
    struct AppLink: Sendable {
        var title: String
        var aliases: [String] = []
        var native: String?
        var web: String?
        /// Perfil/busca/destino já limpo → link universal. nil = o app não aceita alvo.
        var target: (@Sendable (String) -> String)?
    }

    static let apps: [String: AppLink] = [
        // Terceiros (schemes públicos).
        "whatsapp": AppLink(title: "WhatsApp", aliases: ["whats", "zap", "zapzap"], native: "whatsapp://", web: "https://wa.me/"),
        "telegram": AppLink(title: "Telegram", native: "tg://", web: "https://t.me/", target: { "https://t.me/\($0)" }),
        "instagram": AppLink(title: "Instagram", aliases: ["insta"], native: "instagram://", web: "https://www.instagram.com/",
                             target: { "https://www.instagram.com/\($0)" }),
        "facebook": AppLink(title: "Facebook", aliases: ["face"], native: "fb://", web: "https://www.facebook.com/"),
        "messenger": AppLink(title: "Messenger", native: "fb-messenger://", web: "https://www.messenger.com/"),
        "threads": AppLink(title: "Threads", native: "barcelona://", web: "https://www.threads.net/"),
        "x": AppLink(title: "X", aliases: ["twitter"], native: "twitter://", web: "https://x.com/", target: { "https://x.com/\($0)" }),
        "tiktok": AppLink(title: "TikTok", native: "snssdk1233://", web: "https://www.tiktok.com/", target: { "https://www.tiktok.com/@\($0)" }),
        "linkedin": AppLink(title: "LinkedIn", native: "linkedin://", web: "https://www.linkedin.com/", target: { "https://www.linkedin.com/in/\($0)" }),
        "youtube": AppLink(title: "YouTube", native: "youtube://", web: "https://www.youtube.com/",
                           target: { "https://www.youtube.com/results?search_query=\(percent($0))" }),
        "spotify": AppLink(title: "Spotify", native: "spotify://", web: "https://open.spotify.com/",
                           target: { "https://open.spotify.com/search/\(percent($0))" }),
        "netflix": AppLink(title: "Netflix", native: "nflx://", web: "https://www.netflix.com/",
                           target: { "https://www.netflix.com/search?q=\(percent($0))" }),
        "uber": AppLink(title: "Uber", native: "uber://", web: "https://m.uber.com/",
                        target: { "https://m.uber.com/ul/?action=setPickup&pickup=my_location&dropoff%5Bformatted_address%5D=\(percent($0))" }),
        "99": AppLink(title: "99", aliases: ["99 taxi", "99pop"], native: "taxis99://"),
        "ifood": AppLink(title: "iFood", native: "ifood://", web: "https://www.ifood.com.br/"),
        "nubank": AppLink(title: "Nubank", aliases: ["nu"], native: "nubank://"),
        "picpay": AppLink(title: "PicPay", native: "picpay://"),
        "mercado livre": AppLink(title: "Mercado Livre", aliases: ["mercadolivre", "meli"], native: "meli://", web: "https://www.mercadolivre.com.br/"),
        "amazon": AppLink(title: "Amazon", native: "com.amazon.mobile.shopping://", web: "https://www.amazon.com.br/"),
        "discord": AppLink(title: "Discord", native: "discord://", web: "https://discord.com/app"),
        "slack": AppLink(title: "Slack", native: "slack://", web: "https://app.slack.com/"),
        "teams": AppLink(title: "Teams", aliases: ["microsoft teams"], native: "msteams://", web: "https://teams.microsoft.com/"),
        "zoom": AppLink(title: "Zoom", native: "zoomus://", web: "https://zoom.us/"),
        "outlook": AppLink(title: "Outlook", native: "ms-outlook://", web: "https://outlook.live.com/"),
        "gmail": AppLink(title: "Gmail", native: "googlegmail://", web: "https://mail.google.com/"),
        "chrome": AppLink(title: "Chrome", aliases: ["google chrome"], native: "googlechrome://"),
        "google maps": AppLink(title: "Google Maps", aliases: ["maps google"], native: "comgooglemaps://", web: "https://maps.google.com/"),
        "waze": AppLink(title: "Waze", native: "waze://", web: "https://waze.com/ul"),
        "pinterest": AppLink(title: "Pinterest", native: "pinterest://", web: "https://www.pinterest.com/"),
        "reddit": AppLink(title: "Reddit", native: "reddit://", web: "https://www.reddit.com/"),
        "twitch": AppLink(title: "Twitch", native: "twitch://", web: "https://www.twitch.tv/"),
        "duolingo": AppLink(title: "Duolingo", native: "duolingo://"),
        // Apps da Apple (schemes do sistema; Ajustes e alguns outros não são documentados).
        "mensagens": AppLink(title: "Mensagens", aliases: ["imessage", "sms", "messages"], native: "sms:"),
        "telefone": AppLink(title: "Telefone", aliases: ["phone"], native: "mobilephone://"),
        "mail": AppLink(title: "Mail", aliases: ["email", "e mail"], native: "message://"),
        "musica": AppLink(title: "Música", aliases: ["apple music", "music"], native: "music://"),
        "podcasts": AppLink(title: "Podcasts", native: "podcasts://"),
        "fotos": AppLink(title: "Fotos", aliases: ["galeria", "photos"], native: "photos-redirect://"),
        "calendario": AppLink(title: "Calendário", aliases: ["agenda", "calendar"], native: "calshow://"),
        "lembretes": AppLink(title: "Lembretes", aliases: ["reminders"], native: "x-apple-reminderkit://"),
        "notas": AppLink(title: "Notas", aliases: ["notes"], native: "mobilenotes://"),
        "mapas": AppLink(title: "Mapas", aliases: ["apple maps", "maps"], native: "maps://", web: "https://maps.apple.com/"),
        "app store": AppLink(title: "App Store", aliases: ["appstore", "loja"], native: "itms-apps://"),
        "atalhos": AppLink(title: "Atalhos", aliases: ["shortcuts"], native: "shortcuts://"),
        "arquivos": AppLink(title: "Arquivos", aliases: ["files"], native: "shareddocuments://"),
        "carteira": AppLink(title: "Carteira", aliases: ["wallet"], native: "shoebox://"),
        "saude": AppLink(title: "Saúde", aliases: ["health"], native: "x-apple-health://"),
        "livros": AppLink(title: "Livros", aliases: ["books"], native: "ibooks://"),
        "tempo": AppLink(title: "Tempo", aliases: ["clima", "weather"], native: "weather://"),
        "ajustes": AppLink(title: "Ajustes", aliases: ["configuracoes", "settings"], native: "App-prefs:"),
    ]
    static let appNames = apps.keys.sorted()

    /// Nome canônico do catálogo (aceita apelido, acento, espaço e "app do"). nil = fora do catálogo.
    static func appName(_ raw: String) -> String? {
        var key = ContactMatch.normalize(raw)
        for prefix in ["o app do ", "o app da ", "app do ", "app da ", "o ", "a "] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
        }
        if apps[key] != nil { return key }
        let compact = key.replacingOccurrences(of: " ", with: "")
        return apps.first { name, link in
            name.replacingOccurrences(of: " ", with: "") == compact
                || link.aliases.contains { ContactMatch.normalize($0) == key || $0.replacingOccurrences(of: " ", with: "") == compact }
        }?.key
    }

    static func appTitle(_ raw: String) -> String {
        appName(raw).flatMap { apps[$0]?.title } ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
    }

    /// Links em ordem de tentativa. Com alvo: link universal da rota. Sem alvo: scheme nativo, depois o site.
    /// Fora do catálogo tenta `<nome>://` (muitos apps registram o próprio nome), como a Siri abre pelo nome.
    static func appURLs(_ app: String, target: String?) -> [URL] {
        let clean = target?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@")) ?? ""
        guard let name = appName(app), let link = apps[name] else {
            let guess = ContactMatch.normalize(app).replacingOccurrences(of: " ", with: "")
            guard !guess.isEmpty, guess.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return [] }
            return [URL(string: "\(guess)://")].compactMap { $0 }
        }
        var urls: [String] = []
        if !clean.isEmpty, let target = link.target {
            // Perfil: uma palavra sem espaço vai direto na rota; o resto é busca percent-encoded.
            let routed = ["spotify", "youtube", "uber", "netflix"].contains(name)
            urls.append(target(routed || !clean.contains(" ") ? clean : percent(clean)))
        }
        urls += [link.native, link.web].compactMap { $0 }
        return urls.compactMap { URL(string: $0) }
    }

    /// Primeiro link (o que abre se o app estiver instalado).
    static func appURL(_ app: String, target: String?) -> URL? { appURLs(app, target: target).first }

    /// `native` = o app está instalado (canOpenURL); senão link universal/web equivalente.
    static func navigationURL(_ destination: String, app: HarnessSettings.NavigationApp, native: Bool) -> URL? {
        let q = percent(String(destination.prefix(200)))
        switch app {
        case .waze:
            return URL(string: native ? "waze://?q=\(q)&navigate=yes" : "https://waze.com/ul?q=\(q)&navigate=yes")
        case .google:
            return URL(string: native
                ? "comgooglemaps://?daddr=\(q)&directionsmode=driving"
                : "https://www.google.com/maps/dir/?api=1&destination=\(q)&travelmode=driving")
        case .apple:
            return URL(string: "https://maps.apple.com/?daddr=\(q)&dirflg=d")
        }
    }

    static func nativeProbe(_ app: HarnessSettings.NavigationApp) -> URL? {
        switch app {
        case .waze: URL(string: "waze://")
        case .google: URL(string: "comgooglemaps://")
        case .apple: nil
        }
    }

    /// x-callback: ao terminar (ou cancelar) o atalho, o iOS volta para este app.
    static func shortcutURL(_ name: String, input: String?) -> URL? {
        var text = "shortcuts://x-callback-url/run-shortcut?name=\(percent(name))"
        text += "&x-success=mobilellmchat://atalho-ok&x-cancel=mobilellmchat://atalho-cancelado&x-error=mobilellmchat://atalho-erro"
        if let input, !input.isEmpty { text += "&input=text&text=\(percent(String(input.prefix(2000))))" }
        return URL(string: text)
    }

    static func gmailComposeURL(to: String, subject: String, body: String) -> URL? {
        URL(string: "googlegmail://co?to=\(percent(to))&subject=\(percent(String(subject.prefix(200))))&body=\(percent(String(body.prefix(4000))))")
    }

    static func mailtoURL(to: String, subject: String, body: String) -> URL? {
        URL(string: "mailto:\(to)?subject=\(percent(String(subject.prefix(200))))&body=\(percent(String(body.prefix(4000))))")
    }

    static func percent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#/:@"))

    // Aberturas (precisam do main actor por causa do UIApplication).

    @MainActor
    static func navigate(_ destination: String, app: HarnessSettings.NavigationApp) async throws -> String {
        let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw BenchError.failed("Destino vazio.") }
        let native = nativeProbe(app).map { UIApplication.shared.canOpenURL($0) } ?? false
        guard let url = navigationURL(query, app: app, native: native) else {
            throw BenchError.failed("Não foi possível montar a rota.")
        }
        try await open(url)
        return "Rota até “\(query)” aberta no \(app.title)."
    }

    @MainActor
    static func openApp(_ app: String, target: String?) async throws -> String {
        let urls = appURLs(app, target: target)
        let title = appTitle(app)
        // `open` devolve false se nenhum app trata o scheme: não precisa de canOpenURL nem de
        // LSApplicationQueriesSchemes (limite de 50) para cair no próximo link.
        for url in urls where await UIApplication.shared.open(url) {
            let what = (target?.isEmpty == false) ? " em “\(target!)”" : ""
            return "\(title) aberto\(what)."
        }
        if appName(app) == nil {
            throw BenchError.failed("Não consegui abrir “\(app)”: não está no catálogo e não respondeu ao link \(urls.first?.absoluteString ?? "pelo nome"). Se for um atalho, use rodarAtalho.")
        }
        throw BenchError.failed("\(title) não parece instalado neste iPhone.")
    }

    @MainActor
    static func runShortcut(_ name: String, input: String?) async throws -> String {
        guard let url = shortcutURL(name, input: input) else { throw BenchError.failed("Nome de atalho inválido.") }
        try await open(url)
        return "Atalho “\(name)” iniciado no app Atalhos."
    }

    /// Gmail instalado → compose preenchido; senão Mail (mailto). Nos dois o usuário toca em Enviar.
    @MainActor
    static func composeMail(to: String, subject: String, body: String) async throws -> String {
        if let gmail = gmailComposeURL(to: to, subject: subject, body: body), UIApplication.shared.canOpenURL(gmail) {
            try await open(gmail)
            return "Gmail aberto com o e-mail para \(to) preenchido; toque em Enviar."
        }
        guard let url = mailtoURL(to: to, subject: subject, body: body) else {
            throw BenchError.failed("Não foi possível montar o e-mail.")
        }
        try await open(url)
        return "Mail aberto com o e-mail para \(to) preenchido; toque em Enviar."
    }

    @MainActor
    private static func open(_ url: URL) async throws {
        guard await UIApplication.shared.open(url) else {
            throw BenchError.failed("O iOS não abriu \(url.scheme ?? "o link").")
        }
    }
}

// MARK: - Gmail

struct GoogleMailDraft: Sendable, Equatable {
    var to: String
    var subject: String
    var body: String
}

enum GmailMessage {
    /// RFC 2822 mínimo, UTF-8, pronto para `users.messages.send` (campo `raw`, base64url sem padding).
    static func raw(_ draft: GoogleMailDraft, from: String?) -> String {
        var lines: [String] = []
        if let from, !from.isEmpty { lines.append("From: \(from)") }
        lines.append("To: \(draft.to)")
        lines.append("Subject: =?UTF-8?B?\(Data(draft.subject.utf8).base64EncodedString())?=")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        lines.append("Content-Transfer-Encoding: 8bit")
        lines.append("")
        lines.append(draft.body)
        return base64URL(Data(lines.joined(separator: "\r\n").utf8))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
