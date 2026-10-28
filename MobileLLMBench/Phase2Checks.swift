import Foundation

enum Phase2Checks {
    private static func expectThrow(_ body: () throws -> Void) {
        do {
            try body()
            preconditionFailure("esperava um erro")
        } catch {}
    }

    static func selfCheck() {
        registry()
        contactMatch()
        simulation()
        trajectories()
        AppleDataset.validate()
        AppleDataset.validateStepPilot()
        legacyAgreement()
        session()
        latency()
        bfcl()
        let counts = AppleDataset.counts()
        precondition(counts.values.reduce(0, +) == 150)
    }

    private static func registry() {
        precondition(ToolRegistry.tools.count == 10)
        precondition(ToolRegistry.tool("buscarContato") != nil)
        precondition(ToolRegistry.tool("naoExiste") == nil)
        let ligar = ToolRegistry.tool("ligar")!
        expectThrow { try ligar.validate(arguments: [:]) }
        expectThrow { try ligar.validate(arguments: ["numero": .string("119999")]) }
        try! ligar.validate(arguments: ["numero": .string("+15550100")])
        precondition(ToolRegistry.tools.allSatisfy { !$0.parameters.isEmpty })
        precondition(ToolRegistry.sideEffects.contains("ligar"))
        precondition(!ToolRegistry.sideEffects.contains("buscarContato"))
    }

    private static func contactMatch() {
        let book = [
            ContactMatch.Candidate(name: "Ju", phone: "+5511988880001", aliases: ["Ju 💕", "Ju"]),
            ContactMatch.Candidate(name: "Julia Souza", phone: "+5511988880002", aliases: ["Julia Souza", "Julia"]),
            ContactMatch.Candidate(name: "Jv", phone: "+5511988880003", aliases: ["Jv"]),
        ]
        precondition(ContactMatch.select("Ju", from: book).map(\.name) == ["Ju"])
        precondition(ContactMatch.select("jv", from: book).map(\.name) == ["Jv"])
        precondition(ContactMatch.select("julia", from: book).map(\.name) == ["Julia Souza"])
        precondition(ContactMatch.select("não existe", from: book).isEmpty)
        precondition(ContactMatch.dialable("(11) 98888-7777") == "+5511988887777")
        precondition(ContactMatch.dialable("+1 (555) 010-0100") == "+15550100100")
    }

    private static func simulation() {
        var trapped = false
        RealToolBridge.perform = { _, _ in
            trapped = true
            throw BenchError.failed("execução real não pode rodar no teste")
        }
        defer { RealToolBridge.perform = nil }
        let first = ToolWorld(fixtures: .standard, mode: .simulated)
        let second = ToolWorld(fixtures: .standard, mode: .simulated)
        let lookup = try! ToolRegistry.tool("buscarContato")!.simulate(["nome": .string("Ana")], first)
        precondition(lookup.values["phone"]?.text == "+15550100")
        _ = try! ToolRegistry.tool("ligar")!.simulate(["numero": lookup.values["phone"]!], first)
        _ = try! ToolRegistry.tool("criarEvento")!.simulate(
            ["titulo": .string("Isolado"), "minutos": .int(15)], first)
        precondition(first.fixtures.calls.count == 1 && first.fixtures.events.count == 1)
        precondition(second.fixtures.calls.isEmpty && second.fixtures.events.isEmpty)
        precondition(!trapped)
        let again = ToolWorld(fixtures: .standard, mode: .simulated)
        let replay = try! TrajectoryEvaluator.replay(AppleDataset.task("apple_seq_001")!)
        precondition(replay.calls.map(\.tool) == ["buscarContato", "ligar"])
        precondition(replay.calls[1].arguments["numero"]?.text == "+15550100")
        precondition(again.fixtures.calls.isEmpty)
    }

    private static func trajectories() {
        let callAna = AppleDataset.task("apple_seq_001")!
        let good = try! TrajectoryEvaluator.replay(callAna)
        precondition(TrajectoryEvaluator.grade(task: callAna, calls: good.calls, world: good.world).taskSuccess)

        var triple = good.calls
        triple.append(good.calls[1])
        triple.append(good.calls[1])
        triple[2].index = 2
        triple[3].index = 3
        let repeated = TrajectoryEvaluator.grade(task: callAna, calls: triple, world: good.world)
        precondition(repeated.taskSuccess == false)
        precondition(repeated.toolSelectionCorrect == true)
        precondition(repeated.toolArgumentsCorrect == true)
        precondition(repeated.duplicateToolCalls == 2)
        precondition(repeated.invalidToolCalls == 0)

        var wrong = good.calls
        wrong[1].arguments["numero"] = .string("+15550199")
        let badNumber = TrajectoryEvaluator.grade(task: callAna, calls: wrong, world: good.world)
        precondition(badNumber.toolArgumentsCorrect == false && badNumber.taskSuccess == false)

        let invented = [good.calls[1]]
        let skippedLookup = TrajectoryEvaluator.grade(task: callAna, calls: invented, world: good.world)
        precondition(skippedLookup.taskSuccess == false)

        let swapped = [good.calls[1], good.calls[0]]
        precondition(TrajectoryEvaluator.grade(task: callAna, calls: swapped, world: good.world).toolSequenceCorrect == false)

        let multi = AppleDataset.tasks.first { $0.category == "multi_tool" }!
        let forward = try! TrajectoryEvaluator.replay(multi)
        let reversedCalls = forward.calls.reversed().enumerated().map { index, call in
            var copy = call
            copy.index = index
            return copy
        }
        let reversedWorld = world(after: reversedCalls, fixtures: multi.fixtures)
        let reversed = TrajectoryEvaluator.grade(task: multi, calls: reversedCalls, world: reversedWorld)
        precondition(reversed.taskSuccess, reversed.failureText ?? "")
        precondition(reversed.toolSequenceCorrect == nil)
        precondition(reversed.sequenceReason == "sem restrição de ordem")

        let sequential = AppleDataset.tasks.first { $0.expected.contains { $0.tool == "criarEvento" } && $0.category == "sequential" }!
        let seq = try! TrajectoryEvaluator.replay(sequential)
        precondition(TrajectoryEvaluator.grade(task: sequential, calls: seq.calls, world: seq.world).taskSuccess)
        let event = seq.calls.first { $0.tool == "criarEvento" }!
        let rest = seq.calls.filter { $0.tool != "criarEvento" }
        let moved = ([event] + rest).enumerated().map { index, call -> ToolCallRecord in
            var copy = call
            copy.index = index
            return copy
        }
        // O evento independente pode ir para o fim se a busca continuar antes da mensagem.
        let contactFirst = rest + [event]
        let reordered = contactFirst.enumerated().map { index, call -> ToolCallRecord in
            var copy = call
            copy.index = index
            return copy
        }
        let reorderedWorld = world(after: reordered, fixtures: sequential.fixtures)
        let flex = TrajectoryEvaluator.grade(task: sequential, calls: reordered, world: reorderedWorld)
        precondition(flex.taskSuccess, flex.failureText ?? "")
        _ = moved

        let ambiguous = AppleDataset.task("apple_amb_001")!
        let quiet = TrajectoryEvaluator.grade(task: ambiguous, calls: [], world: ToolWorld(fixtures: .standard, mode: .simulated))
        precondition(quiet.taskSuccess)
        precondition(quiet.toolArgumentsCorrect == nil)
        let unsafe = ToolCallRecord(
            index: 0, tool: "ligar", arguments: ["numero": .string("+15550100")],
            output: "tel:+15550100", values: ["numero": .string("+15550100")], error: nil)
        let talked = TrajectoryEvaluator.grade(task: ambiguous, calls: [unsafe], world: good.world)
        precondition(talked.taskSuccess == false && (talked.invalidToolCalls ?? 0) > 0)

        let unknown = AppleDataset.task("apple_amb_003")!
        let onlyLookup = ToolCallRecord(
            index: 0, tool: "buscarContato", arguments: ["nome": .string("João")],
            output: nil, values: [:], error: "Contato não encontrado: João.")
        let asked = TrajectoryEvaluator.grade(
            task: unknown, calls: [onlyLookup], world: ToolWorld(fixtures: .standard, mode: .simulated))
        precondition(asked.taskSuccess, asked.failureText ?? "")
        precondition(TrajectoryEvaluator.grade(task: callAna, calls: nil, world: nil).toolSelectionCorrect == nil)
    }

    private static func world(after calls: [ToolCallRecord], fixtures: SimFixtures) -> ToolWorld {
        let world = ToolWorld(fixtures: fixtures, mode: .simulated)
        for call in calls where call.error == nil {
            _ = try! ToolRegistry.tool(call.tool)?.simulate(call.arguments, world)
        }
        return world
    }

    private static func legacyAgreement() {
        let world = ToolWorld(fixtures: .standard, mode: .simulated)
        let ana = try! ToolRegistry.tool("buscarContato")!.simulate(["nome": .string("Ana")], world)
        let call = try! ToolRegistry.tool("ligar")!.simulate(["numero": ana.values["phone"]!], world)
        let trace = ["buscarContato: \(ana.output)", "ligar: \(call.output)"]
        precondition(PhoneTask.ligarContato.grade(trace) == nil)
        precondition(PhoneTask.ligarContato.grade(trace + ["ligar: \(call.output)"]) != nil)
        precondition(Contacts.numbers["Ana"] == "+15550100")
    }

    private static func session() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlb-session-\(UUID().uuidString)")
        SessionDisk.rootOverride = root
        defer {
            SessionDisk.rootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let jobs = [
            ScheduledJob(agent: .qwen, strategy: .direct, taskID: "ligar", prompt: "Ligue.", runIndex: 1, phase: "measured", executionMode: "simulated"),
            ScheduledJob(agent: .qwen, strategy: .noThink, taskID: "safari", prompt: "Abra.", runIndex: 1, phase: "measured", executionMode: "simulated"),
        ]
        var session = ExperimentSession(
            protocolVersion: ExperimentProtocol.version, appVersion: "test", sessionID: UUID(), startedAt: Date(),
            config: ProtocolConfig(executionMode: "simulated", dataset: "legacy"),
            mlxSwiftLM: ExperimentProtocol.mlxSwiftLM, energyAvailable: false,
            energyReason: ExperimentProtocol.energyReason, jobs: jobs, completedJobIDs: [], results: [], finished: false)
        try! SessionDisk.save(session)
        var loaded = SessionDisk.load()!
        precondition(SessionResume.isResumable(loaded))
        precondition(SessionResume.remaining(loaded).map(\.id) == jobs.map(\.id))
        loaded.completedJobIDs.append(jobs[0].id)
        try! SessionDisk.save(loaded)
        let resumed = SessionDisk.load()!
        precondition(SessionResume.remaining(resumed).map(\.taskID) == ["safari"])
        precondition(resumed.finished == false)
        var done = resumed
        done.finished = true
        try! SessionDisk.save(done)
        precondition(SessionResume.isResumable(SessionDisk.load()!) == false)
        let old = #"{"repetitions":1,"shuffle":false,"warmup":true,"requireCoolThermal":false,"thermalTimeoutSeconds":180,"recoverySeconds":30,"orderSeed":"4"}"#
        let config = try! JSONDecoder().decode(ProtocolConfig.self, from: Data(old.utf8))
        precondition(config.resolvedExecutionMode == "simulated" && config.resolvedDataset == "legacy")
        let archived = try! SessionDisk.archive(done)
        precondition(FileManager.default.fileExists(atPath: archived.path))
    }

    private static func latency() {
        precondition(ExperimentProtocol.totalLatency(totalMs: 10_000, modelLoadMs: 1_500) == 8_500)
        var row = BenchmarkResult(
            device: "iPhone17,1", osVersion: "test", backend: "mlx", model: "m", experiment: "ligar",
            strategy: "direct", promptCharacters: 1, thermalBefore: "nominal")
        row.totalMs = 10_000
        row.modelLoadMs = 1_500
        row.thermalWaitMs = 30_000
        ExperimentProtocol.applyMetrics(&row)
        precondition(row.totalLatencyMs == 8_500)
        var skipped = row
        skipped.totalMs = nil
        skipped.modelLoadMs = nil
        ExperimentProtocol.applyMetrics(&skipped)
        precondition(skipped.totalLatencyMs == nil)
        precondition(ThermalGate.decide(state: "serious", elapsed: 180, timeout: 180, cancelled: false, required: true) == "timeout")
        precondition(ThermalGate.decide(state: "fair", elapsed: 0, timeout: 180, cancelled: true, required: true) == "cancelled")
    }

    private static func bfcl() {
        let tasks = try! BFCLSubset.load()
        precondition(tasks.count == 20)
        let counts = Dictionary(grouping: tasks, by: \.category).mapValues(\.count)
        precondition(counts["simple"] == 5 && counts["multiple"] == 5 && counts["parallel"] == 5 && counts["parallel_multiple"] == 5)
        let triangle = tasks[0]
        precondition(triangle.id == "simple_python_0")
        let right = ToolCallRecord(
            index: 0, tool: "calculate_triangle_area",
            arguments: ["base": .int(10), "height": .int(5)], output: "ok", values: [:], error: nil)
        let ok = BFCLChecker.grade(triangle, calls: [right])
        precondition(ok.taskSuccess, ok.failureText ?? "")
        var wrong = right
        wrong.arguments["base"] = .int(11)
        precondition(BFCLChecker.grade(triangle, calls: [wrong]).toolArgumentsCorrect == false)
        let parallel = tasks.first { $0.id == "parallel_0" }!
        let swift = ToolCallRecord(index: 0, tool: "spotify.play", arguments: ["artist": .string("Taylor Swift"), "duration": .int(20)], output: "ok", values: [:], error: nil)
        let maroon = ToolCallRecord(index: 1, tool: "spotify.play", arguments: ["artist": .string("Maroon 5"), "duration": .int(15)], output: "ok", values: [:], error: nil)
        let flipped = BFCLChecker.grade(parallel, calls: [maroon, swift])
        precondition(flipped.taskSuccess, flipped.failureText ?? "")
        precondition(flipped.toolSequenceCorrect == nil)
        precondition(BFCLChecker.grade(parallel, calls: [swift]).taskSuccess == false)
        let primes = tasks.first { $0.id == "parallel_multiple_0" }!
        let sum = ToolCallRecord(
            index: 0, tool: "math_toolkit.sum_of_multiples",
            arguments: ["lower_limit": .int(1), "upper_limit": .int(1000), "multiples": .list([.int(3), .int(5)])],
            output: "ok", values: [:], error: nil)
        let product = ToolCallRecord(
            index: 1, tool: "math_toolkit.product_of_primes",
            arguments: ["count": .int(5)], output: "ok", values: [:], error: nil)
        precondition(BFCLChecker.grade(primes, calls: [product, sum]).taskSuccess)
    }
}

private func precondition(throws body: () throws -> Void) {
    do {
        try body()
        preconditionFailure("deveria ter falhado")
    } catch {}
}
