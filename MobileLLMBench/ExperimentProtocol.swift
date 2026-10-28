import Foundation

/// Protocolo 2. Fronteiras de tempo — não somar estas parcelas para reconstruir a latência:
/// - `modelLoadMs`: carga ou download do modelo. Fora de `totalLatencyMs`.
/// - `thermalWaitMs`: espera ociosa por térmica. Fora de `totalLatencyMs` e do intervalo `task` do signposter.
/// - `prefillLatencyMs`: `promptTime` do primeiro turno de ação reportado pelo MLX. Não inclui o plano.
/// - `repeatedPrefillMs`: `promptTime` dos turnos de ação seguintes (budget e early-exit reprocessam o prefixo).
/// - `decodeLatencyMs`: soma de `generateTime` dos turnos de ação. Não inclui prefill nem tools.
/// - `planLatencyMs`: relógio de parede só do turno de plano.
/// - `toolExecutionMs`: soma do corpo das tools.
/// - `timeToFirstTokenMs`: relógio de parede, modelo já residente, até o primeiro texto. Inclui o prefill.
/// - `timeToFirstToolCallMs`: o mesmo relógio até o início da primeira tool. Inclui prefill e decode até a chamada.
/// - `totalLatencyMs`: relógio de parede da tentativa depois da carga e da espera térmica, até o fim da correção.
/// - `totalMs`: o mesmo intervalo mais a carga do modelo. É o campo do protocolo 1.
/// Energia por tarefa não é medida: o iOS não entrega joules ao app.
enum ExperimentProtocol {
    static let version = "2.0"
    static let mlxSwiftLM = "3.31.4"
    static let energyReason = "iOS não expõe joules ao app. O intervalo OSSignposter \"task\" (subsystem MobileLLMBench) continua no Power Profiler. batteryLevel não é energia."
    /// Diferenças que o app não consegue igualar. Os limites abaixo já são os mesmos nos dois backends.
    static let methodNote = "Limites comuns: plano até 128 tokens, ação até 512 tokens, no máximo 4 rodadas de ferramenta, timeout térmico 180 s. Qwen3 controla o bloco <think>. Gemma não gera <think>. Apple Foundation Models não expõe raciocínio. Tokenizador, template e formato de ferramenta diferem entre MLX e Apple. Amostragem gulosa: o seed não muda os tokens."

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    static func totalLatency(totalMs: Double?, modelLoadMs: Double?) -> Double? {
        guard let totalMs else { return nil }
        guard let modelLoadMs else { return totalMs }
        let value = totalMs - modelLoadMs
        return value >= 0 ? value : nil
    }

    static func tokensPerSecond(generated: Int?, decodeMs: Double?) -> Double? {
        guard let generated, let decodeMs, decodeMs > 0 else { return nil }
        return Double(generated) / (decodeMs / 1000)
    }

    static func applyMetrics(_ result: inout BenchmarkResult) {
        result.taskId = result.experiment
        result.thermalStateBefore = result.thermalBefore
        result.thermalStateAfter = result.thermalAfter
        result.batteryLevelBefore = result.batteryBefore
        result.batteryLevelAfter = result.batteryAfter
        result.memoryUsageMB = result.memoryAfterMB
        result.timeToFirstTokenMs = result.firstTextMs
        result.timeToFirstToolCallMs = result.inferenceMs
        result.prefillLatencyMs = result.ttftMs
        result.generatedTokens = result.outputTokens
        result.totalLatencyMs = totalLatency(totalMs: result.totalMs, modelLoadMs: result.modelLoadMs)
        result.tokensPerSecond = tokensPerSecond(generated: result.generatedTokens, decodeMs: result.decodeLatencyMs)
        result.taskSuccess = result.success
    }

    static func selfCheck() {
        ThermalGate.selfCheck()
        ExperimentSchedule.selfCheck()
        TraceGrade.selfCheck()
        FailureKind.selfCheck()
        precondition(totalLatency(totalMs: nil, modelLoadMs: 10) == nil)
        precondition(totalLatency(totalMs: 10_000, modelLoadMs: nil) == 10_000)
        precondition(totalLatency(totalMs: 10_000, modelLoadMs: 1_500) == 8_500)
        precondition(totalLatency(totalMs: 100, modelLoadMs: 500) == nil)
        precondition(tokensPerSecond(generated: nil, decodeMs: 1_000) == nil)
        precondition(tokensPerSecond(generated: 54, decodeMs: nil) == nil)
        precondition(tokensPerSecond(generated: 54, decodeMs: 0) == nil)
        precondition(abs(tokensPerSecond(generated: 54, decodeMs: 4_000)! - 13.5) < 1e-9)

        var row = BenchmarkResult(
            device: "iPhone17,1", osVersion: "test", backend: "mlx",
            model: "mlx-community/Qwen3-1.7B-4bit", experiment: "ligar", strategy: "nothink",
            promptCharacters: 21, thermalBefore: "nominal")
        row.totalMs = 10_000
        row.modelLoadMs = 1_500
        row.ttftMs = 2_000
        row.firstTextMs = 2_100
        row.inferenceMs = 6_000
        row.outputTokens = 54
        row.decodeLatencyMs = 4_000
        row.repeatedPrefillMs = 3_000
        row.success = true
        applyMetrics(&row)
        precondition(row.totalLatencyMs == 8_500)
        precondition(row.prefillLatencyMs == 2_000)
        precondition(row.repeatedPrefillMs == 3_000)
        precondition(row.decodeLatencyMs == 4_000)
        precondition(row.timeToFirstToolCallMs == 6_000)
        precondition(row.generatedTokens == 54)
        precondition(row.taskId == "ligar")
        precondition(row.planLatencyMs == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(row)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try! decoder.decode(BenchmarkResult.self, from: data)
        precondition(decoded.totalLatencyMs == 8_500)
        precondition(decoded.planLatencyMs == nil)
        precondition(decoded.error == nil)
        let legacy = """
        {"backend":"mlx","device":"iPhone17,1","error":null,"experiment":"ligar","model":"mlx-community/Qwen3-1.7B-4bit","osVersion":"Version 26","promptCharacters":21,"strategy":"direct","success":true,"thermalBefore":"nominal","totalMs":13921.5,"outputTokens":346}
        """.data(using: .utf8)!
        let old = try! JSONDecoder().decode(BenchmarkResult.self, from: legacy)
        precondition(old.success && old.totalMs == 13921.5 && old.outputTokens == 346)
        precondition(old.protocolVersion == nil && old.totalLatencyMs == nil && old.taskSuccess == nil)
    }
}

struct ProtocolConfig: Codable, Equatable {
    var repetitions: Int = 3
    var shuffle: Bool = true
    var warmup: Bool = true
    var requireCoolThermal: Bool = false
    var thermalTimeoutSeconds: Double = 180
    var recoverySeconds: Double = 30
    var orderSeed: String = "1"
    /// `real` ou `simulated`. Ausente no JSON antigo: a retomada fica simulada, sem efeito externo.
    var executionMode: String? = nil
    /// `legacy`, `apple` ou `bfcl`.
    var dataset: String? = nil
    /// Raw values de `Strategy`. Nil mantém todas as estratégias que o modelo suporta.
    var strategies: [String]? = nil
    /// Categorias do dataset. Nil ou vazio não filtra.
    var categories: [String]? = nil
    /// Subconjunto fixo. A mesma lista entra em todas as estratégias.
    var taskIDs: [String]? = nil
    /// Corta a lista já filtrada. Nil não limita.
    var taskLimit: Int? = nil
    /// `cross_model`, `model_specific`, `legacy` ou `bfcl_subset`. Nil no JSON antigo.
    var protocolId: String? = nil
    var datasetId: String? = nil
    var taskSetId: String? = nil
    var evaluationVersion: String? = nil
    var methodNote: String? = nil

    var seedValue: UInt64 {
        if let number = UInt64(orderSeed), number > 0 { return number }
        var hash: UInt64 = 14695981039346656037
        for byte in orderSeed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash == 0 ? 1 : hash
    }
    var resolvedExecutionMode: String { executionMode ?? "simulated" }
    var resolvedDataset: String { dataset ?? "legacy" }

    func allows(_ strategy: Strategy) -> Bool {
        // Adaptativo e políticas de orçamento só entram quando pedidas explicitamente.
        if strategy == .adaptive || strategy == .budgetedDirect || strategy == .reactiveBudget
            || strategy == .adaptiveStep || strategy == .noThinkRuntime || strategy == .actionAware,
            strategies == nil {
            return false
        }
        guard let strategies else { return true }
        return strategies.contains(strategy.rawValue)
    }
}

extension ProtocolConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repetitions = try c.decodeIfPresent(Int.self, forKey: .repetitions) ?? 3
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? true
        warmup = try c.decodeIfPresent(Bool.self, forKey: .warmup) ?? true
        requireCoolThermal = try c.decodeIfPresent(Bool.self, forKey: .requireCoolThermal) ?? false
        thermalTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .thermalTimeoutSeconds) ?? 180
        recoverySeconds = try c.decodeIfPresent(Double.self, forKey: .recoverySeconds) ?? 30
        orderSeed = try c.decodeIfPresent(String.self, forKey: .orderSeed) ?? "1"
        executionMode = try c.decodeIfPresent(String.self, forKey: .executionMode)
        dataset = try c.decodeIfPresent(String.self, forKey: .dataset)
        strategies = try c.decodeIfPresent([String].self, forKey: .strategies)
        categories = try c.decodeIfPresent([String].self, forKey: .categories)
        taskIDs = try c.decodeIfPresent([String].self, forKey: .taskIDs)
        taskLimit = try c.decodeIfPresent(Int.self, forKey: .taskLimit)
        protocolId = try c.decodeIfPresent(String.self, forKey: .protocolId)
        datasetId = try c.decodeIfPresent(String.self, forKey: .datasetId)
        taskSetId = try c.decodeIfPresent(String.self, forKey: .taskSetId)
        evaluationVersion = try c.decodeIfPresent(String.self, forKey: .evaluationVersion)
        methodNote = try c.decodeIfPresent(String.self, forKey: .methodNote)
    }
}

enum EvaluationIdentity {
    static func version(dataset: String) -> String {
        switch dataset {
        case "apple", "apple_step": "apple-trajectory-1"
        case "bfcl": "bfcl-subset-adapted-1"
        case ASTDataset.id: "bfcl-v4-ast-official-checker-mac"
        default: "legacy-name-1"
        }
    }
}

enum StudyProtocol {
    static let crossModel = "cross_model"
    static let modelSpecific = "model_specific"
    static let legacy = "legacy"
    static let bfcl = "bfcl_subset"
    static let slmAST = "slm_bfcl_v4_ast"

    static func identify(dataset: String, strategies: [String]) -> String {
        if dataset == "legacy" { return legacy }
        if dataset == ASTDataset.id { return slmAST }
        if dataset == "bfcl" { return bfcl }
        if strategies.contains(where: { Strategy(rawValue: $0)?.shared == false }) { return modelSpecific }
        return crossModel
    }

    static func matrix() -> [String] {
        Agent.allCases.flatMap { agent in
            Strategy.allCases.map { "\(agent.rawValue) \($0.rawValue) \($0.status(for: agent))" }
        }
    }
}

struct ScheduledJob: Codable, Equatable, Identifiable {
    var agent: Agent
    var strategy: Strategy
    var taskID: String
    var prompt: String
    var runIndex: Int
    var phase: String
    /// `real` ou `simulated`. Nil em sessão antiga: o runner trata como simulado.
    var executionMode: String? = nil

    var id: String { "\(phase)|\(runIndex)|\(agent.rawValue)|\(strategy.rawValue)|\(taskID)" }
    var countsTowardAnalysis: Bool { phase == "measured" }
    var resolvedExecutionMode: String { executionMode ?? "simulated" }
}

extension ScheduledJob {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decode(Agent.self, forKey: .agent)
        strategy = try c.decode(Strategy.self, forKey: .strategy)
        taskID = try c.decode(String.self, forKey: .taskID)
        prompt = try c.decode(String.self, forKey: .prompt)
        runIndex = try c.decode(Int.self, forKey: .runIndex)
        phase = try c.decode(String.self, forKey: .phase)
        executionMode = try c.decodeIfPresent(String.self, forKey: .executionMode)
    }
}

struct ExperimentSession: Codable {
    var protocolVersion: String
    var appVersion: String
    var sessionID: UUID
    var startedAt: Date
    var config: ProtocolConfig
    var mlxSwiftLM: String
    var energyAvailable: Bool
    var energyReason: String
    var jobs: [ScheduledJob]
    var completedJobIDs: [String]
    var results: [BenchmarkResult]
    var finished: Bool
}

enum SessionDisk {
    /// Testes apontam para um diretório temporário. O app deixa nil.
    nonisolated(unsafe) static var rootOverride: URL?

    static func directory() throws -> URL {
        let base = if let rootOverride {
            rootOverride
        } else {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MobileLLMBench", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func currentURL() throws -> URL {
        try directory().appendingPathComponent("session.json")
    }

    static func load() -> ExperimentSession? {
        guard let url = try? currentURL(), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExperimentSession.self, from: data)
    }

    static func save(_ session: ExperimentSession) throws {
        let encoder = Self.encoder()
        try encoder.encode(session).write(to: try currentURL(), options: .atomic)
    }

    static func sessions() -> [ExperimentSession] {
        guard let base = try? directory(),
              let urls = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("session") && $0.pathExtension == "json" }
            .compactMap { url -> ExperimentSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try? decoder.decode(ExperimentSession.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func archive(_ session: ExperimentSession) throws -> URL {
        let url = try directory().appendingPathComponent("session-\(session.sessionID.uuidString).json")
        try encoder().encode(session).write(to: url, options: .atomic)
        return url
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum SessionResume {
    static func remaining(_ session: ExperimentSession) -> [ScheduledJob] {
        let done = Set(session.completedJobIDs)
        return session.jobs.filter { !done.contains($0.id) }
    }

    static func isResumable(_ session: ExperimentSession) -> Bool {
        !session.finished && !remaining(session).isEmpty
    }
}

struct ScheduleTask: Equatable {
    var id: String
    var prompt: String
}

enum ExperimentSchedule {
    static func make(agents: [Agent], tasks: [PhoneTask], config: ProtocolConfig) -> [ScheduledJob] {
        make(agents: agents, tasks: tasks.map { ScheduleTask(id: $0.rawValue, prompt: $0.prompt) }, config: config)
    }

    static func make(agents: [Agent], tasks: [ScheduleTask], config: ProtocolConfig) -> [ScheduledJob] {
        let reps = max(config.repetitions, 1)
        var measured = [ScheduledJob]()
        for runIndex in 1...reps {
            for agent in agents {
                for strategy in Strategy.allCases where strategy.supports(agent) && config.allows(strategy) {
                    for task in tasks {
                        measured.append(ScheduledJob(
                            agent: agent, strategy: strategy, taskID: task.id,
                            prompt: task.prompt, runIndex: runIndex, phase: "measured",
                            executionMode: config.resolvedExecutionMode))
                    }
                }
            }
        }
        if config.shuffle {
            var rng = SplitMix64(seed: config.seedValue)
            measured.shuffle(using: &rng)
        }
        guard config.warmup, let task = tasks.first else { return measured }
        let warmup = agents.map { agent in
            ScheduledJob(
                agent: agent, strategy: .direct, taskID: task.id,
                prompt: task.prompt, runIndex: 0, phase: "warmup",
                executionMode: "simulated")
        }
        return warmup + measured
    }

    static func selfCheck() {
        var fixed = ProtocolConfig(repetitions: 2, shuffle: false, warmup: false, orderSeed: "1")
        let tasks: [PhoneTask] = [.ligar, .faceTime]
        let jobs = make(agents: [.qwen], tasks: tasks, config: fixed)
        precondition(jobs.count == 24)
        precondition(jobs[0].id == "measured|1|qwen|direct|ligar")
        precondition(jobs[1].id == "measured|1|qwen|direct|faceTime")
        precondition(jobs[12].id == "measured|2|qwen|direct|ligar")
        let apple = make(agents: [.apple], tasks: tasks, config: ProtocolConfig(repetitions: 1, shuffle: false, warmup: false))
        precondition(apple.count == 4)
        precondition(apple.allSatisfy { $0.strategy == .direct || $0.strategy == .planAct })
        fixed.warmup = true
        let warmed = make(agents: [.qwen], tasks: tasks, config: fixed)
        precondition(warmed[0].phase == "warmup" && warmed[0].runIndex == 0 && warmed[0].countsTowardAnalysis == false)
        precondition(warmed[0].executionMode == "simulated")
        var hot = ProtocolConfig(repetitions: 1, shuffle: false, warmup: true, executionMode: "real")
        let mixed = make(agents: [.qwen], tasks: tasks, config: hot)
        precondition(mixed[0].resolvedExecutionMode == "simulated")
        precondition(mixed[1].resolvedExecutionMode == "real")
        var seeded = ProtocolConfig(repetitions: 1, shuffle: true, warmup: false, orderSeed: "1")
        let first = make(agents: [.qwen], tasks: tasks, config: seeded).map(\.id)
        precondition(make(agents: [.qwen], tasks: tasks, config: seeded).map(\.id) == first)
        seeded.orderSeed = "2"
        precondition(make(agents: [.qwen], tasks: tasks, config: seeded).map(\.id) != first)
        let picked = ProtocolConfig(repetitions: 1, shuffle: false, warmup: false, strategies: ["nothink", "direct"])
        let subset = make(agents: [.qwen], tasks: tasks, config: picked)
        precondition(subset.count == 4)
        precondition(Set(subset.map(\.taskID)) == ["ligar", "faceTime"])
        precondition(Set(subset.map(\.strategy)) == [.noThink, .direct])
    }
}

enum ThermalGate {
    /// `ready`, `wait`, `timeout`, `proceed_hot` ou `cancelled`.
    static func decide(state: String, elapsed: TimeInterval, timeout: TimeInterval, cancelled: Bool, required: Bool) -> String {
        if cancelled { return "cancelled" }
        if state == "nominal" || state == "fair" { return "ready" }
        // Carregar o iPhone chega em serious. Sem a exigência de térmica fria, a tarefa segue e o estado fica registrado.
        if !required && state != "critical" { return state == "serious" ? "proceed_hot" : "ready" }
        if elapsed >= timeout { return required ? "timeout" : "proceed_hot" }
        return "wait"
    }

    static func selfCheck() {
        precondition(decide(state: "nominal", elapsed: 0, timeout: 10, cancelled: false, required: true) == "ready")
        precondition(decide(state: "fair", elapsed: 9, timeout: 10, cancelled: false, required: true) == "ready")
        precondition(decide(state: "serious", elapsed: 0, timeout: 10, cancelled: false, required: true) == "wait")
        precondition(decide(state: "serious", elapsed: 10, timeout: 10, cancelled: false, required: true) == "timeout")
        precondition(decide(state: "serious", elapsed: 0, timeout: 10, cancelled: false, required: false) == "proceed_hot")
        precondition(decide(state: "critical", elapsed: 0, timeout: 10, cancelled: false, required: false) == "wait")
        precondition(decide(state: "critical", elapsed: 10, timeout: 10, cancelled: false, required: false) == "proceed_hot")
        precondition(decide(state: "serious", elapsed: 1, timeout: 10, cancelled: true, required: true) == "cancelled")
        precondition(decide(state: "unknown", elapsed: 0, timeout: 10, cancelled: false, required: false) == "ready")
        precondition(decide(state: "unknown", elapsed: 10, timeout: 10, cancelled: false, required: true) == "timeout")
    }
}

enum TraceGrade {
    struct Score: Equatable {
        var toolSelectionCorrect: Bool?
        var toolArgumentsCorrect: Bool?
        var toolSequenceCorrect: Bool?
        var duplicateToolCalls: Int?
        var invalidToolCalls: Int?
    }

    static func score(task: PhoneTask?, trace: [String]?) -> Score {
        guard let trace else {
            return Score(
                toolSelectionCorrect: nil, toolArgumentsCorrect: nil, toolSequenceCorrect: nil,
                duplicateToolCalls: nil, invalidToolCalls: nil)
        }
        let names = trace.map { String($0.prefix { $0 != ":" }) }
        var seen = Set<String>()
        var duplicates = 0
        for name in names where !seen.insert(name).inserted { duplicates += 1 }
        let invalid = names.filter { !PhoneTool.names.contains($0) }.count
        guard let task else {
            return Score(
                toolSelectionCorrect: nil, toolArgumentsCorrect: nil, toolSequenceCorrect: nil,
                duplicateToolCalls: duplicates, invalidToolCalls: invalid)
        }
        let selection = names.sorted() == task.expected.sorted()
        let sequence: Bool? = task.kind == "sequential" ? names == task.expected : nil
        let arguments: Bool?
        if let number = task.contactNumber {
            arguments = trace.contains { !$0.hasPrefix("buscarContato") && $0.contains(number) }
        } else {
            arguments = nil
        }
        return Score(
            toolSelectionCorrect: selection, toolArgumentsCorrect: arguments, toolSequenceCorrect: sequence,
            duplicateToolCalls: duplicates, invalidToolCalls: invalid)
    }

    static func selfCheck() {
        let duplicate = score(task: .ligar, trace: ["ligar: tel:+15550100", "ligar: tel:+15550100"])
        precondition(duplicate.duplicateToolCalls == 1 && duplicate.toolSelectionCorrect == false)
        precondition(duplicate.toolSequenceCorrect == nil && duplicate.invalidToolCalls == 0)
        let ordered = score(task: .ligarContato, trace: ["buscarContato: Ana: +15550100", "ligar: tel:+15550100"])
        precondition(ordered.toolSelectionCorrect == true && ordered.toolSequenceCorrect == true)
        precondition(ordered.toolArgumentsCorrect == true && ordered.duplicateToolCalls == 0)
        let swapped = score(task: .ligarContato, trace: ["ligar: tel:+15550100", "buscarContato: Ana: +15550100"])
        precondition(swapped.toolSelectionCorrect == true && swapped.toolSequenceCorrect == false)
        precondition(swapped.toolArgumentsCorrect == true)
        let wrongNumber = score(task: .ligarContato, trace: ["buscarContato: Ana: +15550100", "ligar: tel:+15550199"])
        precondition(wrongNumber.toolArgumentsCorrect == false)
        let unknown = score(task: .ligar, trace: ["foo: x"])
        precondition(unknown.invalidToolCalls == 1 && unknown.toolSelectionCorrect == false)
        let missing = score(task: .ligar, trace: nil)
        precondition(missing.duplicateToolCalls == nil && missing.toolSelectionCorrect == nil)
        let free = score(task: nil, trace: ["ligar: tel:+15550100"])
        precondition(free.toolSelectionCorrect == nil && free.duplicateToolCalls == 0)
    }
}

enum FailureKind {
    static func classify(success: Bool, error: String?, trace: [String]?, gate: String?) -> String? {
        if success { return nil }
        if gate == "timeout" { return "thermal" }
        if gate == "cancelled" { return "cancelled" }
        guard let error else { return "inference" }
        if error.hasPrefix("Esperava ") || error.hasPrefix("A ação não usou") || error.hasPrefix("Avaliação:") {
            return "grade"
        }
        if error == "Nenhuma ferramenta foi chamada." { return "no_tool" }
        if let trace, !trace.isEmpty { return "execution" }
        return "inference"
    }

    static func selfCheck() {
        precondition(classify(success: true, error: nil, trace: ["ligar: x"], gate: nil) == nil)
        precondition(classify(success: false, error: "Esperava ligar; chamou .", trace: [], gate: nil) == "grade")
        precondition(classify(success: false, error: "Nenhuma ferramenta foi chamada.", trace: [], gate: nil) == "no_tool")
        precondition(classify(success: false, error: "Sem acesso ao Calendário.", trace: ["criarEvento: Sem acesso ao Calendário."], gate: nil) == "execution")
        precondition(classify(success: false, error: "Modelo MLX não carregado.", trace: nil, gate: nil) == "inference")
        precondition(classify(success: false, error: "Timeout aguardando estado térmico nominal ou fair.", trace: nil, gate: "timeout") == "thermal")
    }
}
