import XCTest
@testable import MobileLLMBench

final class ActionAwareTests: XCTestCase {
    private func view(
        prompt: String = "Busque o contato Ana e depois ligue para ela.",
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

    func testStartsWithNoThink() {
        let step = BudgetController.action(view(prompt: "Ligue para +15550100."))
        XCTAssertEqual(step.mode, .fast)
        XCTAssertEqual(step.trigger, "default")
        XCTAssertFalse(step.thinking)
    }

    func testKeepsNoThinkAfterSuccessfulLookup() {
        let step = BudgetController.action(view(
            roundsDone: 1, lastStop: "stop", lastHadCalls: true,
            toolOutputs: [("buscarContato", "Ana: +15550100")]))
        XCTAssertEqual(step.mode, .fast)
        XCTAssertEqual(step.trigger, "continue")
    }

    func testRecoversWhenFollowUpCallIsMissing() {
        let step = BudgetController.action(view(
            roundsDone: 2, lastStop: "stop", lastHadCalls: false, lastText: "Ligue para +15550100",
            toolOutputs: [("buscarContato", "Ana: +15550100")]))
        XCTAssertEqual(step.mode, .recover)
        XCTAssertEqual(step.trigger, "unresolved_dependency")
    }

    func testStopsWhenToolsAlreadyRanAndGenerationIsEmpty() {
        let step = BudgetController.action(view(
            roundsDone: 2, lastStop: "stop", lastHadCalls: false, lastText: "feito",
            toolOutputs: [("buscarContato", "Ana: +15550100"), ("ligar", "tel:+15550100")]))
        XCTAssertEqual(step.mode, .stop)
        XCTAssertEqual(step.trigger, "done")
    }

    func testRecoversOnObservableToolError() {
        let step = BudgetController.action(view(
            roundsDone: 1, lastStop: "stop", lastHadCalls: true,
            toolOutputs: [("ligarFaceTime", "O número precisa começar com +.")]))
        XCTAssertEqual(step.mode, .recover)
        XCTAssertEqual(step.trigger, "tool_error")
    }

    func testRecoversWhenFirstRoundHasNoToolCall() {
        let step = BudgetController.action(view(
            roundsDone: 1, lastStop: "stop", lastHadCalls: false, lastText: "Vou ligar agora."))
        XCTAssertEqual(step.mode, .recover)
        XCTAssertEqual(step.trigger, "missing_call")
    }

    func testStopsAfterRecoveryCapWithoutGold() {
        let step = BudgetController.action(
            view(
                roundsDone: 3, lastStop: "stop", lastHadCalls: false, lastText: "Ligue para o número",
                toolOutputs: [("buscarContato", "Ana: +15550100")]),
            recoveries: BudgetCaps.maxRecoveries)
        XCTAssertEqual(step.mode, .stop)
        XCTAssertEqual(step.trigger, "recover_cap")
    }

    func testDecisionIgnoresPromptWordingWhenToolStateMatches() {
        let state: [(String, String)] = [("buscarContato", "Ana: +15550100")]
        let a = BudgetController.action(view(
            prompt: "pedido A", roundsDone: 2, lastStop: "stop", lastHadCalls: false, toolOutputs: state))
        let b = BudgetController.action(view(
            prompt: "pedido B sem Ana", roundsDone: 2, lastStop: "stop", lastHadCalls: false, toolOutputs: state))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.trigger, "unresolved_dependency")
    }

    func testRuntimeFixAbsorbsThrowsOnlyForFixedPolicies() {
        XCTAssertFalse(ToolErrorPolicy.absorbs(.noThink))
        XCTAssertTrue(ToolErrorPolicy.absorbs(.noThinkRuntime))
        XCTAssertTrue(ToolErrorPolicy.absorbs(.actionAware))
        XCTAssertTrue(ToolErrorPolicy.absorbs(.adaptiveStep))
    }

    func testAdaptiveStepStopsOnEmptyAfterTools() {
        let step = BudgetController.step(view(
            roundsDone: 2, lastStop: "stop", lastHadCalls: false, lastText: "Ligue para +15550100",
            toolOutputs: [("buscarContato", "Ana: +15550100")]))
        XCTAssertEqual(step.mode, .stop)
        XCTAssertEqual(step.trigger, "done")
    }

    func testPresetIsThreePoliciesOnNovelSlice() {
        let preset = ExperimentPresets.actionAwarePilot()
        XCTAssertEqual(preset.config.strategies, ["nothink", "nothink_runtime", "action_aware"])
        XCTAssertEqual(preset.config.taskIDs, AppleDataset.stepPilotIDs)
        XCTAssertEqual(preset.config.repetitions, 1)
        XCTAssertEqual(preset.config.dataset, "apple_step")
        XCTAssertTrue(Set(preset.config.taskIDs ?? []).isDisjoint(with: Set(AppleTaskIDs.heldout90)))
        XCTAssertTrue(Set(preset.config.taskIDs ?? []).isDisjoint(with: Set(AppleTaskIDs.residency)))
        let plan = MatrixPlanner.estimate(agents: preset.agents, config: preset.config)
        XCTAssertEqual(plan.measured, 36)
    }
}
