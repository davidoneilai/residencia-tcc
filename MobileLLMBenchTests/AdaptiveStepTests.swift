import XCTest
@testable import MobileLLMBench

final class AdaptiveStepTests: XCTestCase {
    private func view(
        prompt: String,
        roundsDone: Int = 0,
        remainingTokens: Int = 2048,
        remainingRounds: Int = 4,
        lastStop: String? = nil,
        lastHadCalls: Bool = false,
        lastText: String = "",
        toolOutputs: [(name: String, output: String)] = []
    ) -> BudgetTrajectory {
        BudgetTrajectory(
            prompt: prompt, roundsDone: roundsDone, remainingTokens: remainingTokens,
            remainingRounds: remainingRounds, lastStop: lastStop, lastHadCalls: lastHadCalls,
            lastText: lastText, planned: false, toolOutputs: toolOutputs)
    }

    func testShortSingleStartsFast() {
        let step = BudgetController.step(view(prompt: "Ligue para +15550100."))
        XCTAssertEqual(step.mode, .fast)
        XCTAssertEqual(step.trigger, "short_single")
        XCTAssertFalse(step.thinking)
        XCTAssertNil(step.thinkBudget)
    }

    func testSequentialFirstStepUsesShortThink() {
        let step = BudgetController.step(
            view(prompt: "Busque o contato Ana e depois ligue para ela."))
        XCTAssertEqual(step.mode, .slow)
        XCTAssertEqual(step.trigger, "sequential_or_contact")
        XCTAssertEqual(step.thinkBudget, 64)
        XCTAssertTrue(step.thinking)
    }

    func testMultiToolFirstStepUsesShortThink() {
        let step = BudgetController.step(
            view(prompt: "Crie um evento Standup daqui a 25 minutos e um lembrete Pack charger daqui a 12."))
        XCTAssertEqual(step.mode, .slow)
        XCTAssertEqual(step.trigger, "multi_tool")
    }

    func testLengthWithoutToolRecoversWithoutThinking() {
        let step = BudgetController.step(view(
            prompt: "Busque o contato Ana e depois ligue para ela.",
            roundsDone: 1, remainingTokens: 1536, remainingRounds: 3,
            lastStop: "length", lastText: "<think>plano longo"))
        XCTAssertEqual(step.mode, .recover)
        XCTAssertEqual(step.trigger, "no_progress")
        XCTAssertFalse(step.thinking)
    }

    func testContactFoundContinuesFast() {
        let step = BudgetController.step(view(
            prompt: "Busque o contato Ana e depois ligue para ela.",
            roundsDone: 1, remainingTokens: 1400, remainingRounds: 3,
            lastStop: "stop", lastHadCalls: true, lastText: "",
            toolOutputs: [("buscarContato", "Ana: +15550100")]))
        XCTAssertEqual(step.mode, .fast)
        XCTAssertEqual(step.trigger, "unresolved_dependency")
        XCTAssertFalse(step.thinking)
    }

    func testToolErrorUsesShortThink() {
        let step = BudgetController.step(view(
            prompt: "Busque o contato Ana e depois ligue para ela.",
            roundsDone: 1, remainingTokens: 1400, remainingRounds: 3,
            lastStop: "stop", lastHadCalls: true, lastText: "",
            toolOutputs: [("buscarContato", "Contato não encontrado: Ana.")]))
        XCTAssertEqual(step.mode, .slow)
        XCTAssertEqual(step.trigger, "tool_error")
    }

    func testEmptyBudgetStops() {
        let step = BudgetController.step(view(
            prompt: "Ligue para +15550100.", remainingTokens: 4, remainingRounds: 2))
        XCTAssertEqual(step.mode, .stop)
        XCTAssertEqual(step.trigger, "budget")
    }

    func testStepPilotIDsAreNovel() {
        let ids = Set(AppleDataset.stepPilot.map(\.id))
        XCTAssertEqual(ids.count, 12)
        XCTAssertTrue(ids.isDisjoint(with: Set(AppleTaskIDs.residency)))
        XCTAssertTrue(ids.isDisjoint(with: Set(AppleTaskIDs.heldout90)))
        XCTAssertTrue(ids.isDisjoint(with: Set(AppleDataset.tasks.map(\.id))))
        let queries = AppleDataset.stepPilot.map(\.query)
        XCTAssertEqual(Set(queries).count, 12)
        XCTAssertTrue(Set(queries).isDisjoint(with: Set(AppleDataset.tasks.map(\.query))))
    }
}
