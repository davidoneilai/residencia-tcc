import XCTest
@testable import MobileLLMBench

final class ProviderRouterTests: XCTestCase {
    func testExplicitGoogle() {
        XCTAssertEqual(ProviderRouter().decide(prompt: "Marca reunião no Google amanhã às 10"), .resolved(.google))
        XCTAssertEqual(ProviderRouter().decide(prompt: "Cria um evento na Google Agenda"), .resolved(.google))
    }

    func testExplicitiPhone() {
        XCTAssertEqual(ProviderRouter().decide(prompt: "Marca no calendário do iPhone amanhã 10h"), .resolved(.apple))
        XCTAssertEqual(ProviderRouter().decide(prompt: "Evento no iPhone às 9"), .resolved(.apple))
    }

    func testMeetForcesGoogle() {
        XCTAssertEqual(ProviderRouter().decide(prompt: "Cria um Meet com a Ju amanhã 10h"), .resolved(.google))
        XCTAssertEqual(ProviderRouter().decide(prompt: "Reunião no calendário do iPhone com Google Meet"), .resolved(.google))
        XCTAssertTrue(ProviderRouter.wantsMeet("abre um meet pra gente"))
        XCTAssertTrue(ProviderRouter.wantsMeet("Meet"))
        XCTAssertFalse(ProviderRouter.wantsMeet("marca reunião amanhã"))
    }

    func testMeetBeatsSavediPhonePreference() {
        let router = ProviderRouter(savedPreference: .apple)
        XCTAssertEqual(router.decide(prompt: "Cria um Meet amanhã às 10"), .resolved(.google))
    }

    func testAmbiguousAsks() {
        XCTAssertEqual(ProviderRouter().decide(prompt: "Marca reunião amanhã às 10"), .ask)
    }

    func testSavedPreferenceUsedWhenAmbiguous() {
        var router = ProviderRouter(savedPreference: .google)
        XCTAssertEqual(router.decide(prompt: "Marca reunião amanhã às 10"), .resolved(.google))
        router.savedPreference = .apple
        XCTAssertEqual(router.decide(prompt: "Marca reunião amanhã às 10"), .resolved(.apple))
    }

    func testExplicitBeatsSavedPreference() {
        let router = ProviderRouter(savedPreference: .google)
        XCTAssertEqual(router.decide(prompt: "No iPhone amanhã 10h"), .resolved(.apple))
    }

    func testConflictingHintsAsk() {
        XCTAssertEqual(ProviderRouter(savedPreference: .google).decide(prompt: "No Google e no iPhone"), .ask)
    }

    func testToolAgendaUsedWhenPromptSilent() {
        XCTAssertEqual(ProviderRouter().decide(prompt: "Marca reunião", toolAgenda: .google), .resolved(.google))
    }
}
