import XCTest
@testable import MobileLLMChat

@MainActor
final class UserMemoryTests: XCTestCase {
    func testExtractsPlacesNameAttributesAndNotes() {
        let facts = UserMemory.extract("Oi! Me chamo David. Minha casa fica na Rua das Flores, 100, Recife. Meu trabalho é no CESAR, Cais do Apolo. Lembre que a senha do wifi é abc123.")
        XCTAssertEqual(facts.map(\.key), ["casa", "trabalho", "nome", "nota"])
        XCTAssertEqual(facts[0].value, "Rua das Flores, 100, Recife")
        XCTAssertEqual(facts[1].value, "CESAR, Cais do Apolo")
        XCTAssertEqual(facts[2].value, "David")
        XCTAssertEqual(facts[3].value, "a senha do wifi é abc123")
    }

    func testReminderRequestsAreNotMemory() {
        XCTAssertTrue(UserMemory.extract("me lembra de comprar pão às 9h").isEmpty)
        XCTAssertTrue(UserMemory.extract("cria um lembrete para ligar pra Ana amanhã").isEmpty)
        XCTAssertTrue(UserMemory.extract("minha casa fica onde mesmo?").isEmpty, "pergunta não vira fato")
        XCTAssertFalse(UserMemory.isPureNote("me lembra de comprar pão"))
        XCTAssertTrue(UserMemory.isPureNote("Lembre que meu carro é um Onix prata"))
    }

    func testAbsorbReplacesKeyButAccumulatesNotes() {
        let memory = UserMemory(url: nil)
        memory.absorb("minha casa fica na Rua A, 1")
        memory.absorb("minha casa é na Rua B, 2")
        memory.absorb("lembre que gosto de café sem açúcar")
        memory.absorb("lembre que meu time é o Sport")
        XCTAssertEqual(memory.facts.filter { $0.key == "casa" }.map(\.value), ["Rua B, 2"])
        XCTAssertEqual(memory.facts.filter { $0.key == "nota" }.count, 1, "nota com atributo vira o atributo, não duplica")
        XCTAssertEqual(memory.promptBlock, "[Sobre o usuário: casa = Rua B, 2; nota = gosto de café sem açúcar; time = o Sport.]")
        memory.clear()
        XCTAssertNil(memory.promptBlock)
    }

    func testPromptBlockIsCappedAndKeepsNewest() {
        let memory = UserMemory(url: nil)
        for index in 0..<30 { memory.set("nota", String(repeating: "x", count: 50) + "\(index)") }
        let block = memory.promptBlock!
        XCTAssertLessThanOrEqual(block.count, UserMemory.maxBlockCharacters + 30)
        XCTAssertTrue(block.contains("x29"))
        XCTAssertFalse(block.contains("x0;"))
    }

    func testPlaceResolution() {
        let memory = UserMemory(url: nil)
        memory.set("casa", "Rua das Flores, 100")
        memory.set("trabalho", "Cais do Apolo, 222")
        XCTAssertEqual(memory.place(for: "casa"), "Rua das Flores, 100")
        XCTAssertEqual(memory.place(for: "minha casa"), "Rua das Flores, 100")
        XCTAssertEqual(memory.place(for: "pro trabalho"), "Cais do Apolo, 222")
        XCTAssertNil(memory.place(for: "casa da Ana"))
        XCTAssertNil(memory.place(for: "academia"))
        XCTAssertNil(memory.place(for: "Shopping Recife"))
    }

    func testGateResolvesHomeAddressBeforeRoute() async throws {
        let registry = EventRegistry()
        let world = ChatWorldBox(mode: .simulated)
        let gate = ToolGate(
            tools: ChatToolCatalog.make(store: SimulatedCalendarStore(events: []), clock: testClock, registry: registry, world: world),
            registry: registry, worldBox: world)
        let memory = UserMemory(url: nil)
        memory.set("casa", "Rua das Flores, 100")
        gate.memory = memory
        var proposals: [ToolProposal] = []
        gate.confirm = { proposal in proposals.append(proposal); return true }
        gate.begin()
        let output = try await gate.call("abrirRota", ["destino": .string("casa")])
        XCTAssertEqual(output, "maps:Rua das Flores, 100")
        XCTAssertEqual(proposals.first?.summary, "Abrir rota no Waze até “Rua das Flores, 100”")
    }
}
