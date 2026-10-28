import Foundation

struct MatrixTask: Equatable, Identifiable {
    var id: String
    var prompt: String
    var category: String
}

enum MatrixCatalog {
    static func tasks(dataset: String) -> [MatrixTask] {
        switch dataset {
        case "apple":
            return AppleDataset.tasks.map { MatrixTask(id: $0.id, prompt: $0.query, category: $0.category) }
        case "apple_step":
            return AppleDataset.stepPilot.map { MatrixTask(id: $0.id, prompt: $0.query, category: $0.category) }
        case "bfcl":
            let rows = (try? BFCLSubset.load()) ?? []
            return rows.map { MatrixTask(id: $0.id, prompt: $0.question, category: $0.category) }
        case ASTDataset.id:
            return ASTDataset.tasks.map { MatrixTask(id: $0.id, prompt: $0.prompt, category: $0.category) }
        default:
            return PhoneTask.allCases.map { MatrixTask(id: $0.rawValue, prompt: $0.prompt, category: $0.kind) }
        }
    }

    static func categories(dataset: String) -> [String] {
        var seen: [String] = []
        for task in tasks(dataset: dataset) where !seen.contains(task.category) {
            seen.append(task.category)
        }
        return seen
    }
}

enum MatrixSelection {
    /// Uma lista só. Categorias, IDs e limite cortam o pool antes de qualquer estratégia.
    static func choose(_ config: ProtocolConfig, pool: [MatrixTask]) -> [MatrixTask] {
        var rows = pool
        if let categories = config.categories {
            let allowed = Set(categories)
            rows = rows.filter { allowed.contains($0.category) }
        }
        if let ids = config.taskIDs {
            let allowed = Set(ids)
            rows = rows.filter { allowed.contains($0.id) }
        }
        if let limit = config.taskLimit, limit >= 0 {
            rows = Array(rows.prefix(limit))
        }
        return rows
    }
}

struct MatrixEstimate: Equatable {
    var taskIDs: [String]
    var strategies: [String]
    var measured: Int
    var warmup: Int
    var total: Int
    /// `modelo estratégia` que o modelo não executa. Não vira job nem falha.
    var notApplicable: [String]
}

enum MatrixPlanner {
    static func estimate(agents: [Agent], config: ProtocolConfig) -> MatrixEstimate {
        let chosen = MatrixSelection.choose(config, pool: MatrixCatalog.tasks(dataset: config.resolvedDataset))
        let usable = ["bfcl", ASTDataset.id].contains(config.resolvedDataset) ? agents.filter { $0 != .apple } : agents
        var names: [String] = []
        var measured = 0
        let reps = max(config.repetitions, 1)
        for agent in usable {
            let strategies = Strategy.allCases.filter { $0.supports(agent) && config.allows($0) }
            for strategy in strategies where !names.contains(strategy.rawValue) {
                names.append(strategy.rawValue)
            }
            measured += strategies.count * chosen.count * reps
        }
        let warmup = config.warmup ? usable.count : 0
        return MatrixEstimate(
            taskIDs: chosen.map(\.id), strategies: names,
            measured: measured, warmup: warmup, total: measured + warmup,
            notApplicable: skipped(agents, strategies: config.strategies))
    }

    private static func skipped(_ agents: [Agent], strategies: [String]?) -> [String] {
        guard let strategies else { return [] }
        var rows: [String] = []
        for agent in agents {
            for name in strategies {
                guard let strategy = Strategy(rawValue: name), !strategy.supports(agent) else { continue }
                rows.append("\(agent.rawValue) \(strategy.rawValue)")
            }
        }
        return rows
    }
}

enum AppleTaskIDs {
    static let residency = make(single: 15, multi: 15, sequential: 20, ambiguous: 10)
    static let full = make(single: 40, multi: 40, sequential: 50, ambiguous: 20)
    static let heldout90 = full.filter { !residency.contains($0) }

    static func make(single: Int, multi: Int, sequential: Int, ambiguous: Int) -> [String] {
        slice("apple_single_", single) + slice("apple_multi_", multi) + slice("apple_seq_", sequential) + slice("apple_amb_", ambiguous)
    }

    private static func slice(_ prefix: String, _ count: Int) -> [String] {
        (1...count).map { String(format: "\(prefix)%03d", $0) }
    }
}

enum TaskSets {
    static let residency = "apple_residency_60"
    static let full = "apple_full_150"
    static let heldout90 = "apple_heldout_90"
    static let legacy = "legacy_13"
    static let bfcl = "bfcl_subset_20"

    static func identify(dataset: String, ids: [String]) -> String {
        let found = Set(ids)
        switch dataset {
        case "apple":
            if found == Set(AppleTaskIDs.residency) { return residency }
            if found == Set(AppleTaskIDs.full) { return full }
            if found == Set(AppleTaskIDs.heldout90) { return heldout90 }
            return "apple_custom_\(ids.count)"
        case "apple_step":
            return "apple_step_pilot_\(ids.count)"
        case "bfcl":
            return ids.count == 20 ? bfcl : "bfcl_custom_\(ids.count)"
        case ASTDataset.id:
            return "bfcl_v4_ast_frozen_\(ids.count)"
        default:
            return ids.count == PhoneTask.allCases.count ? legacy : "legacy_custom_\(ids.count)"
        }
    }
}

struct ExperimentPreset: Equatable {
    var agents: [Agent]
    var config: ProtocolConfig
}

enum ExperimentPresets {
    static let residencySeed = "736194"

    static func crossModel() -> ExperimentPreset {
        fill(
            agents: [.qwen, .gemma, .apple], ids: AppleTaskIDs.residency,
            strategies: [.direct, .planAct], shuffle: true, seed: residencySeed,
            protocolId: StudyProtocol.crossModel, taskSetId: TaskSets.residency)
    }

    static func modelSpecific() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: AppleTaskIDs.residency,
            strategies: [.noThink, .budget64, .budget128, .earlyExit], shuffle: true, seed: residencySeed,
            protocolId: StudyProtocol.modelSpecific, taskSetId: TaskSets.residency)
    }

    static func fullApple() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: AppleTaskIDs.full, strategies: [.direct, .planAct],
            shuffle: false, seed: "450", protocolId: StudyProtocol.crossModel, taskSetId: TaskSets.full)
    }

    /// Piloto on-device do roteador: mesmas 60 tarefas, só política `adaptive`.
    static func adaptivePilot() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: AppleTaskIDs.residency,
            strategies: [.adaptive], shuffle: true, seed: residencySeed,
            protocolId: StudyProtocol.crossModel, taskSetId: TaskSets.residency)
    }

    static let heldoutControlIDs = [
        "apple_single_016", "apple_multi_016", "apple_seq_021", "apple_amb_011",
    ]
    static let heldoutRouterCheckIDs = heldoutControlIDs + [
        "apple_single_020", "apple_multi_020", "apple_seq_025", "apple_amb_015",
    ]

    /// 90 tarefas inéditas (famílias fora do residency-60) × {direct, plan_act} × 1.
    static func heldout90() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: AppleTaskIDs.heldout90,
            strategies: [.direct, .planAct], shuffle: true, seed: residencySeed,
            protocolId: StudyProtocol.crossModel, taskSetId: TaskSets.heldout90,
            repetitions: 1, requireCoolThermal: false)
    }

    /// Amostra de controle em outra sessão (estabilidade entre launches).
    static func heldoutControl() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: heldoutControlIDs,
            strategies: [.direct, .planAct], shuffle: false, seed: residencySeed,
            protocolId: StudyProtocol.crossModel, taskSetId: "apple_heldout_control_4",
            repetitions: 1, requireCoolThermal: false)
    }

    /// Validação on-device do roteador congelado (logistic via auto-run).
    static func heldoutRouterCheck() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: heldoutRouterCheckIDs,
            strategies: [.adaptive], shuffle: false, seed: residencySeed,
            protocolId: StudyProtocol.crossModel, taskSetId: "apple_heldout_router_check_8",
            repetitions: 1, requireCoolThermal: false)
    }

    /// 20 tarefas já medidas (heldout-90). Critérios em reports/adaptive-inference/pilot/selection.json.
    static let inferencePilotIDs = [
        "apple_seq_021", "apple_seq_024", "apple_seq_025", "apple_seq_026",
        "apple_seq_027", "apple_seq_035", "apple_seq_042", "apple_seq_048",
        "apple_multi_016", "apple_multi_021", "apple_multi_028", "apple_multi_033",
        "apple_multi_038", "apple_multi_040",
        "apple_single_016", "apple_single_017", "apple_single_021", "apple_single_029",
        "apple_amb_011", "apple_amb_014",
    ]
    static let inferenceSmokeIDs = ["apple_seq_027", "apple_single_021"]
    static let inferencePolicies: [Strategy] = [.direct, .planAct, .budgetedDirect, .reactiveBudget]

    static func adaptiveInferencePilot() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: inferencePilotIDs, strategies: inferencePolicies,
            shuffle: true, seed: residencySeed, protocolId: StudyProtocol.modelSpecific,
            taskSetId: "apple_inference_pilot_20", repetitions: 1, requireCoolThermal: false)
    }

    static func adaptiveInferenceSmoke() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: inferenceSmokeIDs, strategies: inferencePolicies,
            shuffle: false, seed: residencySeed, protocolId: StudyProtocol.modelSpecific,
            taskSetId: "apple_inference_smoke_2", repetitions: 1, requireCoolThermal: false)
    }

    static func reactiveProbe() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: ["apple_seq_021"], strategies: [.reactiveBudget],
            shuffle: false, seed: residencySeed, protocolId: StudyProtocol.modelSpecific,
            taskSetId: "apple_reactive_probe_1", repetitions: 1, requireCoolThermal: false)
    }

    /// 12 famílias inéditas × {direct, nothink, budget_64, adaptive_step} × 1.
    static let stepPolicies: [Strategy] = [.direct, .noThink, .budget64, .adaptiveStep]
    /// Mesmo recorte do step-pilot × {nothink, nothink_runtime, action_aware} × 1.
    static let actionAwarePolicies: [Strategy] = [.noThink, .noThinkRuntime, .actionAware]

    static func adaptiveStepPilot() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: AppleDataset.stepPilotIDs, strategies: stepPolicies,
            shuffle: true, seed: residencySeed, protocolId: StudyProtocol.modelSpecific,
            taskSetId: "apple_step_pilot_12", repetitions: 1, requireCoolThermal: false,
            dataset: "apple_step",
            categories: ["single_tool", "multi_tool", "sequential"])
    }

    static func actionAwarePilot() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: AppleDataset.stepPilotIDs, strategies: actionAwarePolicies,
            shuffle: true, seed: residencySeed, protocolId: StudyProtocol.modelSpecific,
            taskSetId: "apple_step_pilot_12", repetitions: 1, requireCoolThermal: false,
            dataset: "apple_step",
            categories: ["single_tool", "multi_tool", "sequential"])
    }

    /// Variância: Qwen × {direct, plan_act, adaptive} × 60 × 3 reps.
    static func variance3Rep() -> ExperimentPreset {
        fill(
            agents: [.qwen], ids: AppleTaskIDs.residency,
            strategies: [.direct, .planAct, .adaptive], shuffle: true, seed: residencySeed,
            protocolId: StudyProtocol.crossModel, taskSetId: TaskSets.residency,
            repetitions: 3, requireCoolThermal: false)
    }

    /// Um modelo por sessão (sem trocar pesos entre jobs); ordem embaralhada com seed fixa.
    static func slmAST(agents: [Agent], strategies: [Strategy]?, ids: [String]?, repetitions: Int, seed: String) -> ExperimentPreset {
        let usable = agents.filter(Agent.slms.contains)
        let policies = strategies ?? Strategy.allCases.filter { s in usable.contains { s.supports($0) } }
        var preset = fill(
            agents: usable, ids: ids ?? ASTDataset.tasks.map(\.id), strategies: policies,
            shuffle: true, seed: seed, protocolId: StudyProtocol.slmAST,
            taskSetId: "bfcl_v4_ast_frozen_\(ids?.count ?? ASTDataset.tasks.count)",
            repetitions: repetitions, dataset: ASTDataset.id,
            categories: ["simple_python", "multiple", "parallel", "parallel_multiple", "irrelevance"])
        preset.config.warmup = true
        // iPhone conectado ao Mac esquenta sempre: térmica só é registrada, nunca espera.
        preset.config.thermalTimeoutSeconds = 0
        preset.config.recoverySeconds = 0
        return preset
    }

    private static func fill(
        agents: [Agent], ids: [String], strategies: [Strategy], shuffle: Bool, seed: String,
        protocolId: String, taskSetId: String,
        repetitions: Int = 1, requireCoolThermal: Bool = false,
        dataset: String = "apple",
        categories: [String] = ["single_tool", "multi_tool", "sequential", "ambiguous"]
    ) -> ExperimentPreset {
        var config = ProtocolConfig(
            repetitions: repetitions, shuffle: shuffle, warmup: false,
            requireCoolThermal: requireCoolThermal, orderSeed: seed,
            executionMode: "simulated", dataset: dataset)
        config.strategies = strategies.map(\.rawValue)
        config.categories = categories
        config.taskIDs = ids
        config.protocolId = protocolId
        config.datasetId = dataset
        config.taskSetId = taskSetId
        config.evaluationVersion = EvaluationIdentity.version(dataset: dataset)
        config.methodNote = ExperimentProtocol.methodNote
        return ExperimentPreset(agents: agents, config: config)
    }
}

struct LiveProgress: Equatable {
    var completed: Int
    var total: Int
    var agent: String
    var strategy: String
    var dataset: String
    var category: String
    var taskID: String
    var query: String
    var phase: String
    var mode: String
    var thermal: String
}
