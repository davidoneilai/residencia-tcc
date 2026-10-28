import Foundation

/// Arranque sem UI via `Documents/auto-run.json` ou args `--run=...`.
///
/// Exemplos de JSON:
/// - `{"run":"adaptive-pilot","taskLimit":8,"router":"heuristic"}`
/// - `{"run":"variance-3rep","router":"heuristic"}`
/// - `{"run":"resume"}`
/// - `{"run":"adaptive-step-pilot"}`
/// - `{"run":"action-aware-pilot"}`
enum LaunchAutomation {
    private nonisolated(unsafe) static var cachedFile: [String: Any]?
    private nonisolated(unsafe) static var fileLoaded = false

    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func loadFileIfNeeded() -> [String: Any]? {
        if fileLoaded { return cachedFile }
        fileLoaded = true
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("auto-run.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cachedFile = nil
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        cachedFile = obj
        return obj
    }

    static var runName: String? {
        if let arg = arguments.first(where: { $0.hasPrefix("--run=") }) {
            return String(arg.dropFirst("--run=".count))
        }
        return loadFileIfNeeded()?["run"] as? String
    }

    static var resumeSession: Bool { runName == "resume" }

    static var taskLimit: Int? {
        for arg in arguments {
            if arg.hasPrefix("--task-limit="), let value = Int(arg.dropFirst("--task-limit=".count)), value > 0 {
                return value
            }
        }
        if let value = loadFileIfNeeded()?["taskLimit"] as? Int, value > 0 { return value }
        if let value = loadFileIfNeeded()?["taskLimit"] as? NSNumber { return value.intValue }
        return nil
    }

    static var emptyContacts: Bool {
        if arguments.contains("--empty-contacts") { return true }
        return loadFileIfNeeded()?["emptyContacts"] as? Bool == true
    }

    static var routerKind: AdaptiveRouterKind {
        if arguments.contains("--router=logistic") { return .logistic }
        if let value = loadFileIfNeeded()?["router"] as? String, value == "logistic" { return .logistic }
        return .heuristic
    }

    /// Preset correspondente ao `run`, ou nil.
    static func preset() -> ExperimentPreset? {
        switch runName {
        case "adaptive-pilot":
            return ExperimentPresets.adaptivePilot()
        case "variance-3rep":
            return ExperimentPresets.variance3Rep()
        case "heldout-90":
            return ExperimentPresets.heldout90()
        case "heldout-control":
            return ExperimentPresets.heldoutControl()
        case "heldout-router-check":
            return ExperimentPresets.heldoutRouterCheck()
        case "adaptive-inference-pilot":
            return ExperimentPresets.adaptiveInferencePilot()
        case "adaptive-inference-smoke":
            return ExperimentPresets.adaptiveInferenceSmoke()
        case "reactive-probe":
            return ExperimentPresets.reactiveProbe()
        case "adaptive-step-pilot":
            return ExperimentPresets.adaptiveStepPilot()
        case "action-aware-pilot":
            return ExperimentPresets.actionAwarePilot()
        case "bfcl-ast":
            // {"run":"bfcl-ast","agents":["qwen35"],"strategies":["direct"],"taskIDs":[...],"repetitions":1,"seed":"20261027"}
            let file = loadFileIfNeeded() ?? [:]
            return ExperimentPresets.slmAST(
                agents: (file["agents"] as? [String] ?? []).compactMap(Agent.init(rawValue:)),
                strategies: (file["strategies"] as? [String])?.compactMap(Strategy.init(rawValue:)),
                ids: file["taskIDs"] as? [String],
                repetitions: (file["repetitions"] as? Int) ?? 1,
                seed: (file["seed"] as? String) ?? "20261027")
        default:
            return nil
        }
    }

    static func writeDiagnostics() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("launch-diagnostics.txt")
        let text = """
        args=\(arguments.joined(separator: " "))
        run=\(runName ?? "nil")
        taskLimit=\(taskLimit.map(String.init) ?? "nil")
        router=\(routerKind.rawValue)
        fileConfig=\(String(describing: loadFileIfNeeded()))
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
