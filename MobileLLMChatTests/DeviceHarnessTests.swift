import XCTest
@testable import MobileLLMChat

/// Lógica pura do harness real: links, codificação do Gmail, índice de contatos e catálogo.
final class DeviceHarnessTests: XCTestCase {
    override func setUp() {
        HarnessSettings.defaults = UserDefaults(suiteName: "DeviceHarnessTests-\(UUID().uuidString)")!
    }

    func testWazeNativeAndUniversalLinks() {
        let native = DeviceLinks.navigationURL("Av. Paulista, 1000", app: .waze, native: true)!
        XCTAssertEqual(native.scheme, "waze")
        XCTAssertTrue(native.absoluteString.contains("navigate=yes"))
        XCTAssertTrue(native.absoluteString.contains("Av.%20Paulista,%201000"))
        let web = DeviceLinks.navigationURL("Shopping Iguatemi", app: .waze, native: false)!
        XCTAssertEqual(web.host, "waze.com")
        XCTAssertTrue(web.absoluteString.hasSuffix("&navigate=yes"))
    }

    func testGoogleAndAppleNavigationLinks() {
        XCTAssertEqual(DeviceLinks.navigationURL("Centro", app: .google, native: true)?.scheme, "comgooglemaps")
        XCTAssertTrue(DeviceLinks.navigationURL("Centro", app: .google, native: false)!.absoluteString.contains("google.com/maps/dir/"))
        XCTAssertTrue(DeviceLinks.navigationURL("Centro", app: .apple, native: false)!.absoluteString.contains("maps.apple.com/?daddr=Centro&dirflg=d"))
    }

    func testAppLinksUseUniversalURLs() {
        XCTAssertEqual(DeviceLinks.appURL("instagram", target: "@nasa")?.absoluteString, "https://www.instagram.com/nasa")
        XCTAssertEqual(DeviceLinks.appURL("twitter", target: "elonmusk")?.absoluteString, "https://x.com/elonmusk")
        XCTAssertEqual(DeviceLinks.appURL("spotify", target: "Legião Urbana")?.absoluteString, "https://open.spotify.com/search/Legi%C3%A3o%20Urbana")
        XCTAssertTrue(DeviceLinks.appURL("uber", target: "Aeroporto de Congonhas")!.absoluteString.contains("dropoff%5Bformatted_address%5D=Aeroporto%20de%20Congonhas"))
    }

    func testAppsOpenNativeFirstThenWeb() {
        XCTAssertEqual(DeviceLinks.appURLs("Insta", target: nil).map(\.absoluteString), ["instagram://", "https://www.instagram.com/"])
        XCTAssertEqual(DeviceLinks.appURLs("WhatsApp", target: nil).map(\.absoluteString), ["whatsapp://", "https://wa.me/"])
        XCTAssertEqual(DeviceLinks.appName("zap"), "whatsapp")
        XCTAssertEqual(DeviceLinks.appName("o app do Nubank"), "nubank")
        XCTAssertEqual(DeviceLinks.appName("Música"), "musica")
        XCTAssertEqual(DeviceLinks.appName("googlemaps"), "google maps")
        XCTAssertEqual(DeviceLinks.appName("mercadolivre"), "mercado livre")
        XCTAssertEqual(DeviceLinks.appURL("ajustes", target: nil)?.absoluteString, "App-prefs:")
        XCTAssertEqual(DeviceLinks.appTitle("ifood"), "iFood")
    }

    func testUnknownAppGuessesSchemeByName() {
        XCTAssertNil(DeviceLinks.appName("calculadora"))
        XCTAssertEqual(DeviceLinks.appURLs("Shopee", target: nil).map(\.absoluteString), ["shopee://"])
        XCTAssertTrue(DeviceLinks.appURLs("??", target: nil).isEmpty)
    }

    func testShortcutURLHasCallbackAndInput() {
        let url = DeviceLinks.shortcutURL("Modo Foco", input: "30 min")!
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertTrue(url.absoluteString.contains("run-shortcut?name=Modo%20Foco"))
        XCTAssertTrue(url.absoluteString.contains("x-success=mobilellmchat://atalho-ok"))
        XCTAssertTrue(url.absoluteString.contains("input=text&text=30%20min"))
        XCTAssertFalse(DeviceLinks.shortcutURL("Bom dia", input: nil)!.absoluteString.contains("input=text"))
    }

    func testGmailRawIsBase64URLWithHeaders() throws {
        let draft = GoogleMailDraft(to: "ana@exemplo.com", subject: "Reunião amanhã", body: "Oi Ana,\nconfirmando às 9h.")
        let raw = GmailMessage.raw(draft, from: "eu@gmail.com")
        XCTAssertFalse(raw.contains("+")); XCTAssertFalse(raw.contains("/")); XCTAssertFalse(raw.contains("="))
        var padded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: padded)), as: UTF8.self)
        XCTAssertTrue(decoded.contains("From: eu@gmail.com\r\nTo: ana@exemplo.com\r\n"))
        XCTAssertTrue(decoded.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(decoded.hasSuffix("\r\n\r\nOi Ana,\nconfirmando às 9h."))
    }

    func testContactsIndexSelectKeepsEmail() {
        let hits = [
            ContactHit(name: "Ana Souza", phone: "+5511999990001", email: "ana@exemplo.com", aliases: ["Ana", "Souza", "", "", "Ana Souza"]),
            ContactHit(name: "Bruno Lima", phone: "+5511999990002", email: nil, aliases: ["Bruno", "Lima", "", "", "Bruno Lima"]),
        ]
        let found = ContactsIndex.select("ana", from: hits)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.line, "Ana Souza: +5511999990001 · e-mail ana@exemplo.com")
        XCTAssertEqual(ContactsIndex.select("bruno lima", from: hits).first?.line, "Bruno Lima: +5511999990002")
        XCTAssertTrue(ContactsIndex.select("carla", from: hits).isEmpty)
    }

    func testCatalogAddsAppToolAndShortcutOnlyWhenConfigured() {
        let world = ChatWorldBox(mode: .simulated)
        var ids = ChatHarness.tools(world: world).map(\.id)
        XCTAssertTrue(ids.contains(ChatHarness.openAppName))
        XCTAssertFalse(ids.contains(ChatHarness.shortcutName), "sem atalhos configurados a tool não entra no prompt")
        HarnessSettings.shortcuts = ["Modo Foco", " Bom dia "]
        XCTAssertEqual(HarnessSettings.shortcuts, ["Modo Foco", "Bom dia"])
        ids = ChatHarness.tools(world: world).map(\.id)
        XCTAssertTrue(ids.contains(ChatHarness.shortcutName))
        let shortcut = ChatHarness.tools(world: world).first { $0.id == ChatHarness.shortcutName }!
        XCTAssertTrue(shortcut.toolDescription.contains("Modo Foco; Bom dia"))
        XCTAssertNoThrow(try shortcut.validate(arguments: ["nome": .string("modo foco")]))
        XCTAssertThrowsError(try shortcut.validate(arguments: ["nome": .string("Dormir")]))
    }

    func testSummariesAndSettingsDefaults() {
        XCTAssertEqual(HarnessSettings.navigationApp, .waze)
        XCTAssertTrue(HarnessSettings.gmailDirect)
        XCTAssertEqual(ChatHarness.summary(id: "abrirRota", arguments: ["destino": .string("Casa")]), "Abrir rota no Waze até “Casa”")
        HarnessSettings.navigationApp = .apple
        XCTAssertEqual(ChatHarness.summary(id: "abrirRota", arguments: ["destino": .string("Casa")]), "Abrir rota no Apple Mapas até “Casa”")
        XCTAssertEqual(ChatHarness.summary(id: ChatHarness.openAppName, arguments: ["app": .string("instagram"), "alvo": .string("nasa")]), "Abrir Instagram em “nasa”")
        XCTAssertEqual(ChatHarness.summary(id: ChatHarness.shortcutName, arguments: ["nome": .string("Modo Foco")]), "Rodar atalho “Modo Foco”")
    }

    /// Sem a ponte, enviarWhatsApp/ligar/enviarMensagem morrem em
    /// "Execução real indisponível neste processo" (o chat não tem o BenchmarkRunner do bench).
    func testRealModeInstallsTheAppleToolBridge() {
        RealToolBridge.perform = nil
        _ = ChatWorldBox(mode: .simulated)
        XCTAssertNil(RealToolBridge.perform, "modo simulado não abre nada do iPhone")
        _ = ChatWorldBox(mode: .real)
        XCTAssertNotNil(RealToolBridge.perform)
        let box = ChatWorldBox(mode: .simulated)
        RealToolBridge.perform = nil
        box.setMode(.real)
        XCTAssertNotNil(RealToolBridge.perform, "trocar Simulado → Real no picker também instala a ponte")
    }

    @MainActor
    func testWhatsAppTriesNativeSchemeThenUniversalLink() {
        let urls = AppleActions.whatsAppURLs("+55 62 99650-5788", corpo: "oi, Ju").map(\.absoluteString)
        XCTAssertEqual(urls, [
            "whatsapp://send?phone=5562996505788&text=oi,%20Ju",
            "https://wa.me/5562996505788?text=oi,%20Ju",
            "https://api.whatsapp.com/send?phone=5562996505788&text=oi,%20Ju",
        ])
        XCTAssertEqual(
            AppleActions.whatsAppURLs("+15550100", corpo: "").map(\.absoluteString).first,
            "whatsapp://send?phone=15550100")
        XCTAssertTrue(AppleActions.whatsAppURLs("1234", corpo: "oi").isEmpty)
    }

    func testSimulatedModeNeverOpensApps() async throws {
        let world = ChatWorldBox(mode: .simulated)
        let tools = ChatHarness.tools(world: world)
        let open = tools.first { $0.id == ChatHarness.openAppName }!
        let result = try await open.execute(arguments: ["app": .string("spotify")], context: ToolExecutionContext(world: world.world))
        XCTAssertEqual(result.output, "spotify aberto (simulado).")
        let route = tools.first { $0.id == "abrirRota" }!
        let routed = try await route.execute(arguments: ["destino": .string("Centro")], context: ToolExecutionContext(world: world.world))
        XCTAssertEqual(routed.output, "maps:Centro")
    }
}

@MainActor
final class ActionIntentTests: XCTestCase {
    func testDetectsActionableRequests() {
        XCTAssertEqual(ActionIntent.detect("Me lembra amanhã às 9h de pagar o boleto")?.tool, "criarLembrete")
        XCTAssertEqual(ActionIntent.detect("Cria uma reunião com Meet sexta às 15h")?.tool, "criarEvento")
        XCTAssertEqual(ActionIntent.detect("manda um zap pra Ana dizendo que chego em 10 min")?.tool, "enviarWhatsApp")
        XCTAssertEqual(ActionIntent.detect("Rota pra casa")?.tool, "abrirRota")
        XCTAssertEqual(ActionIntent.detect("Manda um e-mail pro João confirmando a entrega")?.tool, "enviarEmail")
        XCTAssertEqual(ActionIntent.detect("abre o Instagram da nasa")?.tool, "abrirApp")
        XCTAssertEqual(ActionIntent.detect("abre o WhatsApp")?.tool, "abrirApp")
        XCTAssertEqual(ActionIntent.detect("abre o whatsapp da Ana")?.tool, "enviarWhatsApp")
        XCTAssertEqual(ActionIntent.detect("Pode me lembrar de ligar pro dentista?")?.tool, "criarLembrete")
    }

    func testQuestionsAndChatAreNotActions() {
        XCTAssertNil(ActionIntent.detect("Quais compromissos tenho amanhã?"))
        XCTAssertNil(ActionIntent.detect("Explica o que é um lembrete no iOS?"))
        XCTAssertNil(ActionIntent.detect("Traduz 'bom dia' para inglês"))
        XCTAssertNil(ActionIntent.detect("Oi, tudo bem?"))
    }

    func testNudgeNamesTheTool() {
        let intent = ActionIntent.detect("me lembra de pagar o boleto amanhã")!
        XCTAssertTrue(intent.nudge.contains("criarLembrete"))
        XCTAssertTrue(AgentCoordinator.asksSomething("Que horas você quer o lembrete?"))
        XCTAssertFalse(AgentCoordinator.asksSomething("Não há compromisso agendado para amanhã às 9h."))
    }
}
