import XCTest
@testable import MobileLLMBench

final class ContactMatchTests: XCTestCase {
    private let book = [
        ContactMatch.Candidate(name: "Ju", phone: "+5511988880001", aliases: ["Ju 💕", "Ju"]),
        ContactMatch.Candidate(name: "Julia Souza", phone: "+5511988880002", aliases: ["Julia Souza", "Julia"]),
        ContactMatch.Candidate(name: "Jv", phone: "+5511988880003", aliases: ["Jv"]),
        ContactMatch.Candidate(
            name: "Julia Conceição", phone: "+5511999990000",
            aliases: ["Julia Conceição", "Julia", "Ju"]),
    ]

    func testExactNicknameBeatsPrefix() {
        let short = [
            ContactMatch.Candidate(name: "Ju", phone: "+1", aliases: ["Ju 💕", "Ju"]),
            ContactMatch.Candidate(name: "Julia Souza", phone: "+2", aliases: ["Julia Souza", "Julia"]),
        ]
        XCTAssertEqual(ContactMatch.select("Ju", from: short).map(\.name), ["Ju"])
        XCTAssertEqual(ContactMatch.select("julia", from: short).map(\.name), ["Julia Souza"])
    }

    func testDiacriticsAndInventedSurnameStillHit() {
        XCTAssertEqual(
            ContactMatch.select("Julia Conceicao", from: book).map(\.name),
            ["Julia Conceição"])
    }

    func testNicknameQueryFindsOfficialNameWhenNoExactJu() {
        let onlyOfficial = book.filter { $0.name == "Julia Conceição" }
        XCTAssertEqual(ContactMatch.select("Ju", from: onlyOfficial).map(\.name), ["Julia Conceição"])
    }

    func testExpandedNameFindsShortContact() {
        let onlyNick = [ContactMatch.Candidate(name: "Ju", phone: "+1", aliases: ["Ju 💕"])]
        XCTAssertEqual(ContactMatch.select("Julia Conceicao", from: onlyNick).map(\.name), ["Ju"])
    }

    func testUnknownStaysEmpty() {
        XCTAssertTrue(ContactMatch.select("não existe", from: book).isEmpty)
    }
}
