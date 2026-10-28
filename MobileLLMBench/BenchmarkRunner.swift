import Foundation
import Observation
import OSLog
import UIKit

@MainActor
@Observable
final class BenchmarkRunner {
    private(set) var running = false
    private(set) var results: [BenchmarkResult] = []
    private(set) var log = "Pronto. Escolha o modo, o modelo e toque em uma ação."
    private(set) var exportURL: URL?
    private(set) var exportURLs: [URL] = []
    private(set) var live: LiveProgress?
    private(set) var pendingCompleted: Int?
    private(set) var pendingRemaining: Int?
    /// Compartilhado com o chat: um modelo MLX por vez na memória.
    let mlx = MLXPhoneBackend()
    // Intervalo "task" por execução; o Power Profiler do Instruments soma a energia em cada um.
    private let signposter = OSSignposter(subsystem: "MobileLLMBench", category: .pointsOfInterest)
    private var activeSession: ExperimentSession?
    private var currentJobID: String?
    private var cancelRequested = false

    init() {
        PhoneTask.selfCheck()
        ExperimentProtocol.selfCheck()
        Phase2Checks.selfCheck()
        Phase3Checks.selfCheck()
        AdaptiveRouter.selfCheck()
        BudgetController.selfCheck()
        ASTRouter.selfCheck()
        AppleToolBridge.install()
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIApplication.shared.isIdleTimerDisabled = true
        if let reason = AppleFoundationBackend.unavailableReason { log += "\nApple: \(reason)" }
        refreshPending()
    }

    func cancel() {
        guard running else { return }
        cancelRequested = true
        log += "\nCancelamento pedido. A execução atual termina; a sessão já gravada pode continuar depois.\n"
    }

    func runMatrix(agents: [Agent], config: ProtocolConfig) async {
        guard !running else { return }
        running = true
        cancelRequested = false
        exportURL = nil
        defer {
            mlx.unload()
            running = false
            currentJobID = nil
        }
        if let existing = SessionDisk.load(), !existing.finished {
            do {
                let url = try SessionDisk.archive(existing)
                log = "Sessão anterior arquivada em \(url.lastPathComponent).\n"
            } catch {
                log = "Não arquivei a sessão anterior: \(error.localizedDescription). A nova matriz não começou.\n"
                return
            }
        } else {
            log = ""
        }
        var resolved = config
        if resolved.orderSeed.isEmpty { resolved.orderSeed = "1" }
        let catalog = Self.catalog(resolved, agents: agents)
        if catalog.dataset != "legacy" { resolved.executionMode = "simulated" }
        resolved.datasetId = resolved.datasetId ?? catalog.dataset
        resolved.evaluationVersion = resolved.evaluationVersion ?? EvaluationIdentity.version(dataset: catalog.dataset)
        resolved.taskSetId = resolved.taskSetId ?? TaskSets.identify(dataset: catalog.dataset, ids: catalog.tasks.map(\.id))
        resolved.protocolId = resolved.protocolId ?? StudyProtocol.identify(dataset: catalog.dataset, strategies: resolved.strategies ?? [])
        resolved.methodNote = resolved.methodNote ?? ExperimentProtocol.methodNote
        if catalog.tasks.isEmpty || catalog.agents.isEmpty {
            log += "Dataset \(catalog.dataset) sem tarefas ou modelos executáveis. Apple Foundation Models não recebe o BFCL: as ferramentas são dinâmicas.\n"
            return
        }
        let jobs = ExperimentSchedule.make(agents: catalog.agents, tasks: catalog.tasks, config: resolved)
        let session = ExperimentSession(
            protocolVersion: ExperimentProtocol.version,
            appVersion: ExperimentProtocol.appVersion,
            sessionID: UUID(),
            startedAt: Date(),
            config: resolved,
            mlxSwiftLM: ExperimentProtocol.mlxSwiftLM,
            energyAvailable: false,
            energyReason: ExperimentProtocol.energyReason,
            jobs: jobs,
            completedJobIDs: [],
            results: [],
            finished: false)
        activeSession = session
        results = []
        persist(session)
        let measured = jobs.filter(\.countsTowardAnalysis).count
        log += """
        Protocolo \(ExperimentProtocol.version). Estudo \(resolved.protocolId ?? "sem id"). App \(ExperimentProtocol.appVersion). MLX \(ExperimentProtocol.mlxSwiftLM).
        Dataset \(resolved.datasetId ?? resolved.resolvedDataset). Conjunto \(resolved.taskSetId ?? "sem id"). Avaliação \(resolved.evaluationVersion ?? "sem versão").
        Modo \(resolved.resolvedExecutionMode). Seed da ordem \(resolved.orderSeed). \(jobs.count) execuções, \(measured) medidas, \(resolved.repetitions) repetições.
        Ordem \(resolved.shuffle ? "aleatória" : "fixa"). Aquecimento \(resolved.warmup ? "sim, fora da análise" : "não").
        Térmica: \(resolved.requireCoolThermal ? "só nominal ou fair" : "segue em serious; pausa só em critical"), timeout \(Int(resolved.thermalTimeoutSeconds)) s, pausa \(Int(resolved.recoverySeconds)) s.
        Amostragem gulosa. O seed não altera tokens: temperature 0 e ArgMaxSampler.
        \(ExperimentProtocol.energyReason)

        """
        await executeSession()
    }

    func resume() async {
        guard !running, let saved = SessionDisk.load(), !saved.finished else { return }
        running = true
        cancelRequested = false
        exportURL = nil
        defer {
            mlx.unload()
            running = false
            currentJobID = nil
        }
        activeSession = saved
        results = saved.results
        log = "Retomando sessão \(saved.sessionID.uuidString). \(saved.results.count) resultados já gravados. Seed \(saved.config.orderSeed).\n"
        await executeSession()
    }

    private func executeSession() async {
        guard let session = activeSession else { return }
        let pending = SessionResume.remaining(session)
        let doneBefore = session.jobs.count - pending.count
        for (index, job) in pending.enumerated() {
            if cancelRequested {
                log += "\nInterrompido. \(results.count) resultados gravados. Pode continuar a sessão.\n"
                refreshPending()
                return
            }
            log += "\n[\(index + 1)/\(pending.count)] \(job.phase) · rep \(job.runIndex) · \(job.agent.title) · \(job.strategy.title) · \(job.taskID)\n"
            live = LiveProgress(
                completed: doneBefore + index, total: session.jobs.count,
                agent: job.agent.title, strategy: job.strategy.title,
                dataset: session.config.resolvedDataset,
                category: Self.category(job.taskID, dataset: session.config.resolvedDataset),
                taskID: job.taskID, query: job.prompt, phase: job.phase,
                mode: job.resolvedExecutionMode, thermal: DeviceMetrics.thermal)
            let wait = await waitBeforeJob(session.config)
            if wait.gate == "cancelled" || cancelRequested {
                log += "\nInterrompido durante a espera térmica. \(results.count) resultados gravados.\n"
                refreshPending()
                return
            }
            if wait.gate == "timeout" {
                appendThermalSkip(job, wait: wait)
                continue
            }
            currentJobID = job.id
            await execute(
                agent: job.agent, strategy: job.strategy, experiment: job.taskID, prompt: job.prompt,
                phase: job.phase, runIndex: job.runIndex, repetitions: session.config.repetitions,
                orderSeed: session.config.orderSeed, thermalGate: wait.gate, thermalWaitMs: wait.milliseconds,
                countsTowardAnalysis: job.countsTowardAnalysis, inferenceSeed: session.config.orderSeed,
                executionMode: job.resolvedExecutionMode, dataset: session.config.resolvedDataset)
            currentJobID = nil
        }
        guard var done = activeSession else { return }
        done.finished = true
        done.results = results
        activeSession = done
        persist(done)
        refreshPending()
        if var finishedLive = live {
            finishedLive.completed = session.jobs.count
            live = finishedLive
        }
        let kept = results.filter { $0.countsTowardAnalysis == true }.count
        log += "\nSessão concluída. \(kept) medições entram na análise.\n"
    }

    private struct ThermalWait {
        var gate: String
        var milliseconds: Double?
    }

    private func waitBeforeJob(_ config: ProtocolConfig) async -> ThermalWait {
        if cancelRequested { return ThermalWait(gate: "cancelled", milliseconds: nil) }
        // O iPhone em teste contínuo na tomada permanece em serious/hot; não bloqueia a execução.
        let state = DeviceMetrics.thermal
        let gate = (state == "nominal" || state == "fair" || state == "unknown") ? "ready" : "proceed_hot"
        return ThermalWait(gate: gate, milliseconds: nil)
    }

    private func appendThermalSkip(_ job: ScheduledJob, wait: ThermalWait) {
        var result = baseResult(agent: job.agent, experiment: job.taskID, strategy: job.strategy, prompt: job.prompt)
        result.thermalAfter = DeviceMetrics.thermal
        result.memoryAfterMB = DeviceMetrics.memoryMB
        result.batteryAfter = DeviceMetrics.battery
        result.error = "Timeout aguardando estado térmico nominal ou fair."
        stamp(
            &result, agent: job.agent, phase: job.phase, runIndex: job.runIndex,
            repetitions: activeSession?.config.repetitions, orderSeed: activeSession?.config.orderSeed,
            thermalGate: "timeout", thermalWaitMs: wait.milliseconds,
            countsTowardAnalysis: job.countsTowardAnalysis, inferenceSeed: activeSession?.config.orderSeed,
            executionMode: job.resolvedExecutionMode, dataset: activeSession?.config.resolvedDataset ?? "legacy")
        finish(&result, task: PhoneTask(rawValue: job.taskID), gate: "timeout", dataset: activeSession?.config.resolvedDataset ?? "legacy")
        currentJobID = job.id
        results.append(result)
        commitSession()
        currentJobID = nil
        log += summary(result) + "\n"
        writeExport()
    }

    private func execute(
        agent: Agent,
        strategy: Strategy,
        experiment: String,
        prompt: String,
        phase: String = "single",
        runIndex: Int = 1,
        repetitions: Int? = nil,
        orderSeed: String? = nil,
        thermalGate: String? = nil,
        thermalWaitMs: Double? = nil,
        countsTowardAnalysis: Bool = true,
        inferenceSeed: String? = nil,
        executionMode: String = "real",
        dataset: String = "legacy"
    ) async {
        let task = PhoneTask(rawValue: experiment)
        let signpost = signposter.beginInterval(
            "task", id: signposter.makeSignpostID(), "\(agent.rawValue) \(strategy.rawValue) \(experiment)")
        defer { signposter.endInterval("task", signpost) }
        var result = baseResult(agent: agent, experiment: experiment, strategy: strategy, prompt: prompt)
        stamp(
            &result, agent: agent, phase: phase, runIndex: runIndex, repetitions: repetitions,
            orderSeed: orderSeed, thermalGate: thermalGate, thermalWaitMs: thermalWaitMs,
            countsTowardAnalysis: countsTowardAnalysis, inferenceSeed: inferenceSeed,
            executionMode: executionMode, dataset: dataset)
        let started = ProcessInfo.processInfo.systemUptime
        let mode = ExecutionMode(rawValue: executionMode) ?? .simulated
        let prepared = Self.preparation(experiment, dataset: dataset, mode: mode)
        // Roteamento adaptativo: decide a política concreta antes de qualquer backend.
        var effectiveStrategy = strategy
        if strategy == .adaptive {
            let decision = AdaptiveRouter.choose(prompt: prompt, agent: agent)
            effectiveStrategy = decision.strategy
            result.strategy = effectiveStrategy.rawValue
            result.strategyId = Strategy.adaptive.rawValue
            result.routerDecisionMs = decision.decisionMs
            result.routerReason = decision.reason
            log += "router → \(effectiveStrategy.rawValue) · \(decision.reason) · \(String(format: "%.3f", decision.decisionMs)) ms\n"
        }
        do {
            guard effectiveStrategy.supports(agent) else {
                throw BenchError.failed("\(effectiveStrategy.title) só existe para o Qwen3 (controle de <think>).")
            }
            switch agent {
            case .apple:
                mlx.unload()
                try await AppleFoundationBackend.run(
                    prompt: prompt, strategy: effectiveStrategy, mode: prepared.mode, fixtures: prepared.fixtures, result: &result)
            case .qwen, .gemma:
                try await mlx.run(
                    agent: agent, prompt: prompt, strategy: effectiveStrategy,
                    seed: inferenceSeed.flatMap(UInt64.init),
                    mode: prepared.mode, fixtures: prepared.fixtures, catalog: prepared.catalog,
                    result: &result
                ) { message in
                    log += message + "\n"
                }
            case .minicpm5, .lfm25, .gemma4, .qwen35:
                guard dataset == ASTDataset.id, let ast = ASTDataset.task(experiment) else {
                    throw BenchError.failed("\(agent.title) só roda no BFCL AST (\(ASTDataset.id)).")
                }
                try await mlx.runAST(
                    agent: agent, task: ast, strategy: effectiveStrategy,
                    seed: inferenceSeed.flatMap(UInt64.init), result: &result
                ) { message in
                    log += message + "\n"
                }
            }
        } catch {
            if result.error == nil { result.error = error.localizedDescription }
        }
        let inferenceError = result.error
        gradeTask(&result, dataset: dataset, experiment: experiment)
        if let inferenceError {
            result.error = inferenceError
            result.success = false
        }
        result.totalMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        result.memoryAfterMB = DeviceMetrics.memoryMB
        result.thermalAfter = DeviceMetrics.thermal
        result.batteryAfter = DeviceMetrics.battery
        if agent != .apple, result.toolTrace != nil || result.modelLoadMs != nil {
            result.startKind = result.modelLoadMs == nil ? "warm" : "cold"
        }
        finish(&result, task: task, gate: thermalGate, dataset: dataset)
        results.append(result)
        commitSession()
        log += summary(result) + "\n"
        writeExport()
    }

    private func baseResult(agent: Agent, experiment: String, strategy: Strategy, prompt: String) -> BenchmarkResult {
        BenchmarkResult(
            device: DeviceMetrics.device,
            osVersion: DeviceMetrics.osVersion,
            backend: agent.backend,
            model: agent.model,
            experiment: experiment,
            taskKind: PhoneTask(rawValue: experiment)?.kind,
            strategy: strategy.rawValue,
            promptCharacters: prompt.count,
            memoryBeforeMB: DeviceMetrics.memoryMB,
            thermalBefore: DeviceMetrics.thermal,
            batteryBefore: DeviceMetrics.battery)
    }

    private func stamp(
        _ result: inout BenchmarkResult,
        agent: Agent,
        phase: String,
        runIndex: Int,
        repetitions: Int?,
        orderSeed: String?,
        thermalGate: String?,
        thermalWaitMs: Double?,
        countsTowardAnalysis: Bool,
        inferenceSeed: String?,
        executionMode: String,
        dataset: String
    ) {
        result.executionMode = executionMode
        result.dataset = dataset
        result.protocolVersion = ExperimentProtocol.version
        result.appVersion = ExperimentProtocol.appVersion
        result.mlxSwiftLM = agent == .apple ? nil : ExperimentProtocol.mlxSwiftLM
        result.phase = phase
        result.runIndex = runIndex
        result.repetitions = repetitions
        result.orderSeed = orderSeed
        result.sampling = "greedy"
        result.temperature = agent == .apple ? nil : 0
        result.inferenceSeed = inferenceSeed
        result.seedAffectsSampling = false
        result.thermalGate = thermalGate
        result.thermalWaitMs = thermalWaitMs
        result.countsTowardAnalysis = countsTowardAnalysis
        let study = activeSession?.config
        result.protocolId = study?.protocolId
        result.datasetId = study?.datasetId ?? dataset
        result.taskSetId = study?.taskSetId
        result.modelId = agent.rawValue
        result.strategyId = result.strategy
        result.evaluationVersion = study?.evaluationVersion ?? EvaluationIdentity.version(dataset: dataset)
    }

    private func finish(_ result: inout BenchmarkResult, task: PhoneTask?, gate: String?, dataset: String) {
        if dataset == "legacy" {
            let grade = TraceGrade.score(task: task, trace: result.toolTrace)
            result.toolSelectionCorrect = grade.toolSelectionCorrect
            result.toolArgumentsCorrect = grade.toolArgumentsCorrect
            result.toolSequenceCorrect = grade.toolSequenceCorrect
            result.duplicateToolCalls = grade.duplicateToolCalls
            result.invalidToolCalls = grade.invalidToolCalls
        }
        ExperimentProtocol.applyMetrics(&result)
        result.failureKind = FailureKind.classify(
            success: result.success, error: result.error, trace: result.toolTrace, gate: gate)
    }

    private func commitSession() {
        guard let id = currentJobID, var session = activeSession else { return }
        if !session.completedJobIDs.contains(id) { session.completedJobIDs.append(id) }
        session.results = results
        activeSession = session
        persist(session)
    }

    private func persist(_ session: ExperimentSession) {
        do {
            try SessionDisk.save(session)
        } catch {
            log += "Erro ao gravar sessão: \(error.localizedDescription). Resultados seguem em memória.\n"
        }
    }

    private func refreshPending() {
        guard let session = SessionDisk.load(), !session.finished else {
            pendingCompleted = nil
            pendingRemaining = nil
            return
        }
        pendingCompleted = session.results.count
        pendingRemaining = session.jobs.filter { !session.completedJobIDs.contains($0.id) }.count
    }

    private func writeExport() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let folder = FileManager.default.temporaryDirectory
            let url = folder.appendingPathComponent("benchmark-results.json")
            try encoder.encode(results).write(to: url, options: .atomic)
            let stats = ResultStats.analyze(results)
            let model = results.last?.model ?? ""
            let csv = folder.appendingPathComponent("summary.csv")
            let report = folder.appendingPathComponent("report.md")
            try ResultStats.csv(stats, model: model).write(to: csv, atomically: true, encoding: .utf8)
            try ResultStats.markdown(stats, model: model).write(to: report, atomically: true, encoding: .utf8)
            exportURL = url
            exportURLs = [url, csv, report]
        } catch {
            log += "Erro ao preparar JSON: \(error.localizedDescription). Resultados preservados em memória.\n"
        }
    }

    private struct RunCatalog {
        var dataset: String
        var agents: [Agent]
        var tasks: [ScheduleTask]
    }

    private struct Prepared {
        var mode: ExecutionMode
        var fixtures: SimFixtures
        var catalog: [any AgentTool]?
    }

    private static func catalog(_ config: ProtocolConfig, agents: [Agent]) -> RunCatalog {
        let dataset = config.resolvedDataset
        let pool = MatrixCatalog.tasks(dataset: dataset)
        let chosen = MatrixSelection.choose(config, pool: pool)
        let usable = dataset == "bfcl" || dataset == ASTDataset.id ? agents.filter { $0 != .apple } : agents
        return RunCatalog(
            dataset: dataset, agents: usable,
            tasks: chosen.map { ScheduleTask(id: $0.id, prompt: $0.prompt) })
    }

    private static func category(_ id: String, dataset: String) -> String {
        MatrixCatalog.tasks(dataset: dataset).first { $0.id == id }?.category ?? "sem categoria"
    }

    private static func preparation(_ experiment: String, dataset: String, mode: ExecutionMode) -> Prepared {
        switch dataset {
        case "apple", "apple_step":
            var fixtures = AppleDataset.task(experiment)?.fixtures ?? .standard
            if LaunchAutomation.emptyContacts { fixtures.contacts = [] }
            return Prepared(mode: .simulated, fixtures: fixtures, catalog: nil)
        case "bfcl":
            let task = ((try? BFCLSubset.load()) ?? []).first { $0.id == experiment }
            let tools: [any AgentTool] = task.map { BFCLChecker.foreignTools($0).map { $0 as any AgentTool } } ?? []
            return Prepared(mode: .simulated, fixtures: .standard, catalog: tools)
        default:
            return Prepared(mode: mode, fixtures: .standard, catalog: nil)
        }
    }

    private static func world(after calls: [ToolCallRecord], fixtures: SimFixtures) -> ToolWorld {
        let world = ToolWorld(fixtures: fixtures, mode: .simulated)
        for call in calls where call.error == nil {
            _ = try? ToolRegistry.tool(call.tool)?.simulate(call.arguments, world)
        }
        return world
    }

    private func gradeTask(_ result: inout BenchmarkResult, dataset: String, experiment: String) {
        switch dataset {
        case "apple", "apple_step":
            guard let task = AppleDataset.task(experiment) else {
                result.success = false
                result.error = "Avaliação: tarefa \(experiment) ausente."
                return
            }
            result.taskKind = task.category
            let world = result.toolCalls.map { Self.world(after: $0, fixtures: task.fixtures) }
            apply(TrajectoryEvaluator.grade(task: task, calls: result.toolCalls, world: world), to: &result, emptyIsNoTool: task.policy == "execute")
        case "bfcl":
            guard let task = ((try? BFCLSubset.load()) ?? []).first(where: { $0.id == experiment }) else {
                result.success = false
                result.error = "Avaliação: tarefa \(experiment) ausente do BFCL."
                return
            }
            result.taskKind = task.category
            apply(BFCLChecker.grade(task, calls: result.toolCalls), to: &result, emptyIsNoTool: true)
        case ASTDataset.id:
            // Só sinal ao vivo (houve/não houve chamada). A nota é do ast_checker oficial no Mac.
            let category = ASTDataset.task(experiment)?.category ?? "sem categoria"
            result.taskKind = category
            result.success = (category == "irrelevance") == ((result.toolCallCount ?? 0) == 0)
        default:
            if let phone = PhoneTask(rawValue: experiment) {
                result.taskKind = phone.kind
                if let reason = phone.grade(result.toolTrace ?? []) {
                    result.success = false
                    result.error = reason
                } else {
                    result.success = true
                }
            } else if result.error == nil {
                result.success = true
            }
        }
    }

    private func apply(_ report: GradeReport, to result: inout BenchmarkResult, emptyIsNoTool: Bool) {
        result.toolSelectionCorrect = report.toolSelectionCorrect
        result.toolArgumentsCorrect = report.toolArgumentsCorrect
        result.toolSequenceCorrect = report.toolSequenceCorrect
        result.duplicateToolCalls = report.duplicateToolCalls
        result.invalidToolCalls = report.invalidToolCalls
        result.completionCorrect = report.completionCorrect
        result.selectionReason = report.selectionReason
        result.argumentsReason = report.argumentsReason
        result.sequenceReason = report.sequenceReason
        result.completionReason = report.completionReason
        result.success = report.taskSuccess
        guard !report.taskSuccess else { return }
        if emptyIsNoTool, (result.toolCalls ?? []).isEmpty {
            result.error = "Nenhuma ferramenta foi chamada."
        } else {
            result.error = report.failureText
        }
    }

    private func summary(_ result: BenchmarkResult) -> String {
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "null"
        }
        return """
        Modelo: \(result.model)
        Dataset: \(result.dataset ?? "null") · modo \(result.executionMode ?? "null")
        Estratégia: \(result.strategy) · \(result.phase ?? "single") · rep \(result.runIndex.map(String.init) ?? "null") · \(result.startKind ?? "null")
        Plano: \(result.plan ?? "null")
        Thinking: \(result.thinkingTokens.map { String($0) } ?? "null") tokens; checks de saída: \(result.exitChecks.map { String($0) } ?? "null"); saiu cedo: \(result.exitedEarly.map { String($0) } ?? "null")
        Device: \(result.device) — \(result.osVersion)
        Inferência até a tool: \(number(result.inferenceMs)) ms
        Latência sem carga: \(number(result.totalLatencyMs)) ms
        Total com carga: \(number(result.totalMs)) ms
        Load: \(number(result.modelLoadMs)) ms
        Prefill / prefill repetido / decode: \(number(result.prefillLatencyMs)) / \(number(result.repeatedPrefillMs)) / \(number(result.decodeLatencyMs)) ms
        Plano: \(number(result.planLatencyMs)) ms
        Primeiro texto: \(number(result.firstTextMs)) ms
        Tokens in/out: \(result.inputTokens.map { String($0) } ?? "null") / \(result.outputTokens.map { String($0) } ?? "null")
        Memory: \(number(result.memoryBeforeMB)) -> \(number(result.memoryAfterMB)) MB
        Thermal: \(result.thermalBefore) -> \(result.thermalAfter) espera \(number(result.thermalWaitMs)) ms (\(result.thermalGate ?? "null"))
        Battery (0–1): \(number(result.batteryBefore.map { Double($0) })) -> \(number(result.batteryAfter.map { Double($0) }))
        Tool calls: \(result.toolCallCount.map { String($0) } ?? "null"); execução: \(number(result.toolExecutionMs)) ms
        Tool trace: \(result.toolTrace?.joined(separator: "; ") ?? "null")
        Duplicadas / inválidas: \(result.duplicateToolCalls.map(String.init) ?? "null") / \(result.invalidToolCalls.map(String.init) ?? "null")
        Success: \(result.success) · falha: \(result.failureKind ?? "null") · análise: \(result.countsTowardAnalysis.map { String($0) } ?? "null")
        Error: \(result.error ?? "null")
        Response: \(result.response)
        """
    }
}
