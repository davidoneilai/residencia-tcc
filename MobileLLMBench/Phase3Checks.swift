import Foundation

enum Phase3Checks {
    static func selfCheck() {
        presets()
        protocols()
        subset()
        legacyConfig()
        stats()
        findings()
    }

    private static func presets() {
        let cross = ExperimentPresets.crossModel()
        let crossPlan = MatrixPlanner.estimate(agents: cross.agents, config: cross.config)
        precondition(cross.agents == [.qwen, .gemma, .apple])
        precondition(crossPlan.measured == 360 && crossPlan.notApplicable.isEmpty)
        precondition(Set(crossPlan.strategies) == ["direct", "plan_act"])
        precondition(cross.config.taskSetId == TaskSets.residency)
        precondition(cross.config.evaluationVersion == "apple-trajectory-1")
        precondition(counts(crossPlan.taskIDs) == ["single_tool": 15, "multi_tool": 15, "sequential": 20, "ambiguous": 10])
        precondition(cross.config.shuffle && cross.config.orderSeed == ExperimentPresets.residencySeed)

        let specific = ExperimentPresets.modelSpecific()
        let specificPlan = MatrixPlanner.estimate(agents: specific.agents, config: specific.config)
        precondition(specificPlan.measured == 240)
        precondition(Set(specificPlan.strategies) == ["nothink", "budget_64", "budget_128", "early_exit"])
        precondition(specific.config.taskSetId == cross.config.taskSetId)
        let gemmaOnly = MatrixPlanner.estimate(agents: [.gemma], config: specific.config)
        precondition(gemmaOnly.measured == 0)
        precondition(gemmaOnly.notApplicable == ["gemma nothink", "gemma budget_64", "gemma budget_128", "gemma early_exit"])

        let full = ExperimentPresets.fullApple()
        let fullPlan = MatrixPlanner.estimate(agents: full.agents, config: full.config)
        precondition(fullPlan.measured == 300 && Set(fullPlan.taskIDs).count == 150)
        precondition(full.config.taskSetId == TaskSets.full)

        let held = ExperimentPresets.heldout90()
        let heldPlan = MatrixPlanner.estimate(agents: held.agents, config: held.config)
        precondition(heldPlan.measured == 180 && Set(heldPlan.taskIDs).count == 90)
        precondition(held.config.taskSetId == TaskSets.heldout90)
        precondition(Set(heldPlan.taskIDs).isDisjoint(with: Set(AppleTaskIDs.residency)))

        let control = ExperimentPresets.heldoutControl()
        let controlPlan = MatrixPlanner.estimate(agents: control.agents, config: control.config)
        precondition(controlPlan.measured == 8)
        precondition(Set(controlPlan.taskIDs).isSubset(of: Set(heldPlan.taskIDs)))

        let check = ExperimentPresets.heldoutRouterCheck()
        let checkPlan = MatrixPlanner.estimate(agents: check.agents, config: check.config)
        precondition(checkPlan.measured == 8)
        precondition(Set(checkPlan.strategies) == ["adaptive"])

        let inf = ExperimentPresets.adaptiveInferencePilot()
        let infPlan = MatrixPlanner.estimate(agents: inf.agents, config: inf.config)
        precondition(infPlan.measured == 80 && Set(infPlan.taskIDs).count == 20)
        precondition(Set(infPlan.strategies) == Set(ExperimentPresets.inferencePolicies.map(\.rawValue)))
        let smoke = ExperimentPresets.adaptiveInferenceSmoke()
        precondition(MatrixPlanner.estimate(agents: smoke.agents, config: smoke.config).measured == 8)

        let step = ExperimentPresets.adaptiveStepPilot()
        let stepPlan = MatrixPlanner.estimate(agents: step.agents, config: step.config)
        precondition(stepPlan.measured == 48 && Set(stepPlan.taskIDs).count == 12)
        precondition(Set(stepPlan.strategies) == Set(ExperimentPresets.stepPolicies.map(\.rawValue)))
        precondition(Set(stepPlan.taskIDs).isDisjoint(with: Set(AppleTaskIDs.heldout90)))
        precondition(Set(stepPlan.taskIDs).isDisjoint(with: Set(AppleTaskIDs.residency)))
        precondition(step.config.repetitions == 1)
        precondition(step.config.dataset == "apple_step")
        for id in stepPlan.taskIDs {
            precondition(AppleDataset.task(id) != nil, id)
        }

        let aware = ExperimentPresets.actionAwarePilot()
        let awarePlan = MatrixPlanner.estimate(agents: aware.agents, config: aware.config)
        precondition(awarePlan.measured == 36 && Set(awarePlan.taskIDs).count == 12)
        precondition(Set(awarePlan.strategies) == Set(ExperimentPresets.actionAwarePolicies.map(\.rawValue)))
        precondition(Set(awarePlan.taskIDs) == Set(stepPlan.taskIDs))
        precondition(aware.config.repetitions == 1)
        precondition(aware.config.dataset == "apple_step")

        for id in crossPlan.taskIDs {
            precondition(AppleDataset.task(id) != nil, id)
        }
    }

    private static func protocols() {
        let cross = ExperimentPresets.crossModel()
        let tasks = cross.config.taskIDs!.map { ScheduleTask(id: $0, prompt: "p") }
        let jobs = ExperimentSchedule.make(agents: [.qwen, .gemma], tasks: tasks, config: cross.config)
        let measured = jobs.filter(\.countsTowardAnalysis)
        let qwen = measured.filter { $0.agent == .qwen }
        let gemma = measured.filter { $0.agent == .gemma }
        precondition(qwen.count == 120 && gemma.count == 120)
        precondition(Set(qwen.map(\.taskID)) == Set(gemma.map(\.taskID)))
        precondition(Set(qwen.map(\.taskID)).count == 60)
        precondition(Set(qwen.map(\.strategy)) == [.direct, .planAct])
        precondition(Set(gemma.map(\.strategy)) == [.direct, .planAct])
        precondition(measured.allSatisfy { $0.strategy.supports($0.agent) })

        var blocked = cross.config
        blocked.strategies = ["direct", "nothink", "budget_64"]
        let partial = ExperimentSchedule.make(agents: [.gemma], tasks: tasks, config: blocked)
        precondition(partial.allSatisfy { $0.strategy == .direct })
        precondition(partial.count == 60)
        precondition(Strategy.noThink.status(for: .gemma) == "not_applicable")
        precondition(Strategy.noThink.status(for: .apple) == "not_applicable")
        precondition(Strategy.budget64.status(for: .qwen) == "applicable")
        precondition(StudyProtocol.matrix().count == Agent.allCases.count * Strategy.allCases.count)
        AdaptiveRouter.selfCheck()
        BudgetController.selfCheck()
        let adaptivePlan = MatrixPlanner.estimate(
            agents: [.qwen], config: ExperimentPresets.adaptivePilot().config)
        precondition(adaptivePlan.measured == 60)
        precondition(Set(adaptivePlan.strategies) == ["adaptive"])
        let variance = ExperimentPresets.variance3Rep()
        let variancePlan = MatrixPlanner.estimate(agents: variance.agents, config: variance.config)
        precondition(variancePlan.measured == 540)
        precondition(Set(variancePlan.strategies) == ["direct", "plan_act", "adaptive"])
        precondition(variance.config.repetitions == 3 && !variance.config.requireCoolThermal)
        precondition(StudyProtocol.matrix().contains("gemma nothink not_applicable"))
        precondition(StudyProtocol.matrix().contains("qwen budget_128 applicable"))
        precondition(StudyProtocol.matrix().contains("apple plan_act applicable"))

        let task = AppleDataset.task("apple_single_001")!
        let replay = try! TrajectoryEvaluator.replay(task)
        let report = TrajectoryEvaluator.grade(task: task, calls: replay.calls, world: replay.world)
        precondition(report.taskSuccess, report.failureText ?? "")
        precondition(EvaluationIdentity.version(dataset: "apple") == cross.config.evaluationVersion)
        precondition(AppleDataset.task("apple_single_001")?.fixtures == task.fixtures)

        var appleRow = sample("apple_single_001", "direct", "single_tool", success: true, latency: 100, tokens: 10, kind: nil, gate: nil, run: 1)
        var legacyRow = sample("ligar", "direct", "single_tool", success: true, latency: 100, tokens: 10, kind: nil, gate: nil, run: 1)
        appleRow.dataset = "apple"
        appleRow.datasetId = "apple"
        appleRow.protocolId = StudyProtocol.crossModel
        legacyRow.dataset = "legacy"
        legacyRow.datasetId = "legacy"
        legacyRow.protocolId = StudyProtocol.legacy
        let mixed = ResultStats.analyze([appleRow, legacyRow])
        precondition(mixed.successRate == nil && mixed.strategies.isEmpty && mixed.comparable == false)
        precondition(ResultStats.crossWarnings([appleRow, legacyRow]).contains("Legado, Apple e BFCL não entram na mesma taxa de sucesso."))
        precondition(ResultStats.slices([appleRow, legacyRow]).count == 2)

        var qwenRow = appleRow
        var gemmaRow = appleRow
        qwenRow.modelId = "qwen"
        qwenRow.experiment = "apple_single_001"
        qwenRow.taskId = "apple_single_001"
        gemmaRow.modelId = "gemma"
        gemmaRow.model = "gemma"
        gemmaRow.totalLatencyMs = 50
        gemmaRow.totalMs = 50
        let split = ResultStats.analyze([qwenRow, gemmaRow])
        precondition(split.comparable)
        precondition(Set(split.strategies.map(\.strategy)) == ["gemma direct", "qwen direct"])
    }

    private static func subset() {
        var config = ProtocolConfig(repetitions: 2, shuffle: false, warmup: false, dataset: "apple")
        config.taskIDs = ["apple_single_001", "nao-existe", "apple_amb_001"]
        config.strategies = ["direct", "nothink"]
        let plan = MatrixPlanner.estimate(agents: [.qwen], config: config)
        precondition(plan.taskIDs == ["apple_single_001", "apple_amb_001"])
        precondition(plan.measured == 8)
        config.taskLimit = 1
        let limited = MatrixPlanner.estimate(agents: [.qwen], config: config)
        precondition(limited.taskIDs == ["apple_single_001"] && limited.measured == 4)
    }

    private static func legacyConfig() {
        let old = #"{"repetitions":1,"shuffle":false,"warmup":true,"requireCoolThermal":false,"thermalTimeoutSeconds":180,"recoverySeconds":30,"orderSeed":"4"}"#
        let config = try! JSONDecoder().decode(ProtocolConfig.self, from: Data(old.utf8))
        precondition(config.strategies == nil && config.taskIDs == nil && config.taskLimit == nil)
        precondition(config.protocolId == nil && config.datasetId == nil && config.taskSetId == nil)
        precondition(config.evaluationVersion == nil && config.methodNote == nil)
        precondition(config.resolvedDataset == "legacy" && config.resolvedExecutionMode == "simulated")
        let legacy = #"{"backend":"mlx","device":"iPhone17,1","experiment":"ligar","model":"mlx-community/Qwen3-1.7B-4bit","osVersion":"Version 26","promptCharacters":21,"strategy":"direct","success":true,"thermalBefore":"nominal","totalMs":13921.5}"#
        let row = try! JSONDecoder().decode(BenchmarkResult.self, from: Data(legacy.utf8))
        precondition(row.protocolId == nil && row.modelId == nil && row.strategyId == nil && row.evaluationVersion == nil)
        precondition(row.success && row.totalMs == 13921.5)
    }

    private static func stats() {
        let ran = sample("ligar", "direct", "single_tool", success: true, latency: 100, tokens: 10, kind: nil, gate: nil, run: 1)
        var slow = sample("safari", "direct", "single_tool", success: false, latency: 300, tokens: 30, kind: "grade", gate: nil, run: 1)
        slow.selectionReason = "faltou abrirSafari; extra "
        var hot = sample("ligar", "nothink", "single_tool", success: false, latency: nil, tokens: nil, kind: "thermal", gate: "timeout", run: 1)
        hot.totalMs = nil
        var cold = sample("ligar", "direct", "single_tool", success: true, latency: nil, tokens: 4, kind: nil, gate: nil, run: 1)
        cold.totalMs = 10_000
        cold.modelLoadMs = 1_500
        cold.totalLatencyMs = nil
        cold.startKind = "cold"
        let other = sample("mapas", "nothink", "single_tool", success: true, latency: 50, tokens: 5, kind: nil, gate: nil, run: 1)
        let report = ResultStats.analyze([ran, slow, hot, cold, other])
        precondition(report.executed == 4, "\(report.executed)")
        precondition(report.failures.notRun == 1 && report.failures.agent == 1)
        precondition(report.successRate == 0.75)
        precondition(ResultStats.inferenceLatency(cold) == 8_500)
        precondition(report.missingLatency == 0)
        precondition(report.exploratory)
        precondition(report.comparable == false && report.paretoFront.isEmpty)

        let matched = ResultStats.analyze([
            sample("ligar", "direct", "single_tool", success: true, latency: 200, tokens: 10, kind: nil, gate: nil, run: 1),
            sample("ligar", "nothink", "single_tool", success: true, latency: 100, tokens: 8, kind: nil, gate: nil, run: 1),
            sample("safari", "direct", "single_tool", success: false, latency: 200, tokens: 10, kind: "grade", gate: nil, run: 1),
            sample("safari", "nothink", "single_tool", success: true, latency: 100, tokens: 8, kind: nil, gate: nil, run: 1),
        ])
        precondition(matched.comparable)
        precondition(matched.paretoFront == ["nothink"])
        var once = sample("ligar", "direct", "single_tool", success: true, latency: nil, tokens: nil, kind: nil, gate: nil, run: 2)
        once.repetitions = 2
        precondition(ResultStats.analyze([once]).exploratory == false)
        var coldStart = sample("ligar", "direct", "single_tool", success: true, latency: 5_000, tokens: 10, kind: nil, gate: nil, run: 1)
        var warmStart = sample("safari", "direct", "single_tool", success: false, latency: 8_000, tokens: 10, kind: "grade", gate: nil, run: 1)
        coldStart.startKind = "cold"
        warmStart.startKind = "warm"
        precondition(ResultStats.latencyBars([coldStart, warmStart]).map(\.label) == ["direct cold", "direct warm"])
        precondition(ResultStats.startPoints([coldStart, warmStart]).count == 2)
        precondition(ResultStats.median([10, 30]) == 20)
        precondition(ResultStats.percentile([10, 20, 30, 40], 0.9) == 40)
    }

    private static func findings() {
        var row = sample("ligar", "direct", "sequential", success: false, latency: 1, tokens: 1, kind: "grade", gate: nil, run: 1)
        row.toolSelectionCorrect = false
        row.selectionReason = "faltou buscarContato; extra ligarFaceTime"
        row.toolArgumentsCorrect = false
        row.duplicateToolCalls = 2
        row.toolSequenceCorrect = false
        row.sequenceReason = "dependência fora de ordem"
        row.completionCorrect = false
        row.invalidToolCalls = 1
        let labels = ResultStats.findings(row)
        precondition(labels.contains("Missing tool") && labels.contains("Wrong tool"))
        precondition(labels.contains("Invalid arguments") && labels.contains("Duplicate tool"))
        precondition(labels.contains("Broken dependency") && labels.contains("Incomplete trajectory"))
        precondition(labels.contains("Unexpected action"))
    }

    private static func counts(_ ids: [String]) -> [String: Int] {
        Dictionary(grouping: ids, by: { id -> String in
            AppleDataset.task(id)?.category ?? "?"
        }).mapValues(\.count)
    }

    private static func sample(
        _ id: String, _ strategy: String, _ kind: String, success: Bool, latency: Double?, tokens: Int?,
        kind failure: String?, gate: String?, run: Int
    ) -> BenchmarkResult {
        var row = BenchmarkResult(
            device: "iPhone17,1", osVersion: "test", backend: "mlx", model: "qwen",
            experiment: id, strategy: strategy, promptCharacters: 1, thermalBefore: "nominal")
        row.taskKind = kind
        row.taskId = id
        row.success = success
        row.taskSuccess = success
        row.totalLatencyMs = latency
        row.totalMs = latency
        row.outputTokens = tokens
        row.generatedTokens = tokens
        row.failureKind = failure
        row.thermalGate = gate
        row.countsTowardAnalysis = true
        row.phase = "measured"
        row.runIndex = run
        row.repetitions = 1
        row.inferenceMs = latency
        return row
    }
}
