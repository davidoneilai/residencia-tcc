import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import UIKit

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// Greedy que guarda o log-prob de cada token escolhido; confiança = média geométrica das probabilidades.
final class ConfidenceSampler: LogitSampler, @unchecked Sendable {
    private var logprobs = [Float]()

    func sample(logits: MLXArray) -> MLXArray {
        let lp = logits.max(axis: -1) - logSumExp(logits, axis: -1)
        logprobs.append(lp.asType(.float32).item(Float.self))
        return argMax(logits, axis: -1)
    }

    var confidence: Double {
        logprobs.isEmpty ? 0 : exp(Double(logprobs.reduce(0, +)) / Double(logprobs.count))
    }

    static func selfCheck() {
        let sampler = ConfidenceSampler()
        let token = sampler.sample(logits: MLXArray([0, log(3)] as [Float]).reshaped(1, 2))
        assert(token.asType(.int32).item(Int32.self) == 1 && abs(sampler.confidence - 0.75) < 1e-4)
    }
}

enum ToolArguments {
    static func string(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = arguments[key] else { throw BenchError.failed("Falta o argumento \(key).") }
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        default: throw BenchError.failed("\(key) não é texto.")
        }
    }

    static func integer(_ arguments: [String: JSONValue], _ key: String) throws -> Int {
        guard let value = arguments[key] else { throw BenchError.failed("Falta o argumento \(key).") }
        switch value {
        case .int(let number): return number
        case .double(let number): return Int(number)
        case .string(let text):
            guard let number = Int(text) else { throw BenchError.failed("\(key) não é um número.") }
            return number
        default: throw BenchError.failed("\(key) não é um número.")
        }
    }

    static func selfCheck() {
        let arguments: [String: JSONValue] = ["numero": .string("+15550100"), "minutos": .int(60)]
        precondition((try? string(arguments, "numero")) == "+15550100")
        precondition((try? integer(arguments, "minutos")) == 60)
    }
}

@MainActor
final class MLXPhoneBackend {
    private var loaded: Agent?
    private var container: ModelContainer?
    private var prefixKey: String?
    private var prefixTokens = [Int32]()
    private var prefixCache = [any KVCache]()
    private var world = ToolWorld(fixtures: .standard, mode: .simulated)
    private var catalog: [any AgentTool] = ToolRegistry.tools
    private var schemas: [ToolSpec] = MLXPhoneBackend.appleSchemas
    private var absorbToolErrors = false

    init() {
        ToolArguments.selfCheck()
        ConfidenceSampler.selfCheck()
        Memory.cacheLimit = 256 * 1024 * 1024
    }

    func prepare(_ agent: Agent, status: (String) -> Void) async throws -> Double? {
        guard agent != .apple else { return nil }
        if loaded == agent, container != nil { return nil }
        unload()
        await Self.waitForeground()
        status("Baixando e carregando \(agent.title). A primeira vez precisa de internet.")
        let started = ProcessInfo.processInfo.systemUptime
        container = try await #huggingFaceLoadModelContainer(configuration: configuration(for: agent))
        loaded = agent
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        status("\(agent.title) carregado.")
        return ms
    }

    func unload() {
        container = nil
        loaded = nil
        prefixKey = nil
        prefixTokens = []
        prefixCache = []
        Memory.clearCache()
    }

    func run(
        agent: Agent,
        prompt: String,
        strategy: Strategy,
        seed: UInt64? = nil,
        mode: ExecutionMode = .real,
        fixtures: SimFixtures = .standard,
        catalog: [any AgentTool]? = nil,
        result: inout BenchmarkResult,
        status: (String) -> Void
    ) async throws {
        world = ToolWorld(fixtures: fixtures, mode: mode)
        self.catalog = catalog ?? ToolRegistry.tools
        schemas = Self.specs(for: self.catalog)
        if let loadMs = try await prepare(agent, status: status) { result.modelLoadMs = loadMs }
        let started = ProcessInfo.processInfo.systemUptime
        let log = ToolLog()
        result.toolCallingMode = "prompt_requested"
        do {
            try await runControlled(
                prompt: prompt, strategy: strategy, seed: seed, started: started, result: &result, log: log)
        } catch {
            result.error = error.localizedDescription
        }
        let marks = await log.snapshot()
        result.toolCallCount = marks.count
        result.toolExecutionMs = marks.isEmpty ? nil : marks.reduce(0) { $0 + $1.ms }
        result.toolTrace = marks.map { "\($0.name): \($0.detail)" }
        result.toolCalls = marks.map { $0.record() }
        if let first = marks.first {
            result.inferenceMs = (first.started - started) * 1000
        }
        if let error = result.error { throw BenchError.failed(error) }
    }

    static let astLimit = 1024

    /// BFCL AST: uma resposta do modelo, sem system prompt do harness nem execução de ferramenta.
    /// Direct = thinking ligado quando o template permite; NoThink = `enable_thinking: false`.
    func runAST(
        agent: Agent, task: ASTTask, strategy: Strategy, seed: UInt64?,
        result: inout BenchmarkResult, status: (String) -> Void
    ) async throws {
        if let loadMs = try await prepare(agent, status: status) { result.modelLoadMs = loadMs }
        let tools = task.tools
        schemas = tools
        result.toolCallingMode = "native_template"
        GPU.resetPeakMemory()
        let started = ProcessInfo.processInfo.systemUptime
        var chosen = strategy
        if strategy == .astRouter {
            let decision = ASTRouter.choose(task, agent: agent)
            chosen = decision.strategy
            result.routerReason = decision.reason
            result.routerDecisionMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        } else if strategy == .adaptiveStep {
            let decision = BudgetController.step(BudgetTrajectory(
                prompt: task.prompt, roundsDone: 0, remainingTokens: Self.astLimit, remainingRounds: 1,
                lastStop: nil, lastHadCalls: false, lastText: "", planned: false, toolOutputs: []))
            chosen = decision.mode == .slow ? .budget64 : .noThink
            result.controllerTrace = ["\(decision.mode):\(decision.trigger)"]
        }
        result.strategyId = strategy.rawValue
        if chosen != strategy { result.strategy = chosen.rawValue }
        let direct: Bool? = agent.thinkingSwitch ? true : nil
        var messages = task.messages
        let answer: (text: String, calls: [ToolCall])
        switch chosen {
        case .noThink:
            answer = try await astGenerate(messages, tools: tools, thinking: false, limit: Self.astLimit,
                                           seed: seed, started: started, role: .action, result: &result)
        case .budget64:
            answer = try await astThink(agent, messages, tools: tools, budget: 64, started: started, result: &result)
        case .planAct:
            let planStart = ProcessInfo.processInfo.systemUptime
            let plan = try await astGenerate(
                Self.withUser(messages, Self.astPlan(task.prompt)), tools: tools,
                thinking: agent.thinkingSwitch ? false : nil, limit: BudgetCaps.plan,
                seed: seed, started: started, role: .plan, result: &result)
            result.planLatencyMs = (ProcessInfo.processInfo.systemUptime - planStart) * 1000
            result.plan = plan.text
            result.planCount = 1
            messages = Self.withUser(messages, Self.astAction(task.prompt, plan: plan.text))
            answer = try await astGenerate(messages, tools: tools, thinking: direct, limit: Self.astLimit,
                                           seed: seed, started: started, role: .action, result: &result)
        default:
            answer = try await astGenerate(messages, tools: tools, thinking: direct, limit: Self.astLimit,
                                           seed: seed, started: started, role: .action, result: &result)
        }
        result.response += answer.text
        result.toolCallCount = answer.calls.count
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        result.astCalls = String(decoding: try encoder.encode(answer.calls), as: UTF8.self)
        result.inferenceMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        result.peakMemoryMB = Double(Memory.peakMemory) / 1_048_576
    }

    static func astPlan(_ prompt: String) -> String {
        "\(prompt)\n\nWrite a short plan, at most 5 lines, for answering. Do not call any function yet."
    }

    static func astAction(_ prompt: String, plan: String) -> String {
        "\(prompt)\n\nPlan:\n\(plan)\n\nNow answer the request, calling functions only if needed."
    }

    private static func withUser(_ messages: [[String: String]], _ content: String) -> [[String: String]] {
        var copy = messages
        if let last = copy.lastIndex(where: { $0["role"] == "user" }) { copy[last]["content"] = content }
        return copy
    }

    private nonisolated static func astChat(_ messages: [[String: String]]) -> [Chat.Message] {
        messages.map { row in
            let text = row["content"] ?? ""
            return switch row["role"] {
            case "system": .system(text)
            case "assistant": .assistant(text)
            default: .user(text)
            }
        }
    }

    private func astGenerate(
        _ messages: [[String: String]], tools: [ToolSpec], thinking: Bool?, limit: Int,
        seed: UInt64?, started: TimeInterval, role: TurnRole, result: inout BenchmarkResult
    ) async throws -> (text: String, calls: [ToolCall]) {
        guard let container else { throw BenchError.failed("Modelo MLX não carregado.") }
        await Self.waitForeground()
        let input = try await container.prepare(input: UserInput(
            chat: Self.astChat(messages), tools: tools,
            additionalContext: thinking.map { ["enable_thinking": $0] }))
        let fullCount = input.text.tokens.size
        let parameters = GenerateParameters(maxTokens: limit, temperature: 0, seed: seed)
        let raw = UncheckedBox(value: input)
        let stream = try await container.perform { (context: ModelContext) in
            try MLXLMCommon.generate(input: raw.value, parameters: parameters, context: context, tools: tools)
        }
        var text = ""
        var calls = [ToolCall]()
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if role == .action, result.firstTextMs == nil, !chunk.isEmpty {
                    result.firstTextMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                text += chunk
            case .info(let info):
                result.inputTokens = (result.inputTokens ?? 0) + fullCount
                result.outputTokens = (result.outputTokens ?? 0) + info.generationTokenCount
                absorb(info, result: &result, role: role, primary: true)
                if role == .action {
                    result.stopReason = switch info.stopReason {
                    case .stop: "stop"
                    case .length: "length"
                    case .cancelled: "cancelled"
                    }
                }
            case .toolCall(let call):
                calls.append(call)
            }
        }
        return (text, calls)
    }

    /// s1 com o marcador nativo do modelo: pensa até `budget` tokens, fecha e força a resposta.
    private func astThink(
        _ agent: Agent, _ messages: [[String: String]], tools: [ToolSpec], budget: Int,
        started: TimeInterval, result: inout BenchmarkResult
    ) async throws -> (text: String, calls: [ToolCall]) {
        guard let container, let close = agent.thinkClose else { throw BenchError.failed("Sem marcador de thinking.") }
        await Self.waitForeground()
        let input = try await container.prepare(input: UserInput(
            chat: Self.astChat(messages), tools: tools,
            additionalContext: agent.thinkingSwitch ? ["enable_thinking": true] : nil))
        let head = input.text.tokens.asType(.int32).asArray(Int32.self).map(Int.init)
        let thought = try await pass(head, limit: budget, stop: [close], started: started, result: &result)
        let closing = close == "</think>" ? "\n</think>\n\n" : close
        result.thinkingTokens = thought.tokens
        result.response += thought.text + closing
        let answer = try await pass(
            head + (await container.encode(thought.text + closing)), limit: Self.astLimit - thought.tokens,
            started: started, result: &result)
        result.inputTokens = head.count
        result.outputTokens = thought.tokens + answer.tokens
        result.stopReason = answer.stop ?? (answer.tokens >= Self.astLimit - thought.tokens ? "length" : "stop")
        return (answer.text, answer.calls)
    }

    typealias Round = (text: String, calls: [(call: ToolCall, output: String)])

    /// P0–P3: mesmo teto de tokens gerados e de rodadas. MLX só limita `maxTokens` por chamada.
    private func runControlled(
        prompt: String, strategy: Strategy, seed: UInt64?, started: TimeInterval,
        result: inout BenchmarkResult, log: ToolLog
    ) async throws {
        let kind = BudgetKind.from(strategy)
        absorbToolErrors = ToolErrorPolicy.absorbs(strategy)
        var remaining = BudgetCaps.totalGenerated
        var events: [String] = []
        var planned = false
        var planCount = 0
        var recoverCount = 0
        var overhead = 0.0
        result.tokenBudgetCap = remaining
        defer {
            result.controllerTrace = events
            result.planCount = kind == .actionAware ? recoverCount : planCount
            result.routerDecisionMs = (result.routerDecisionMs ?? 0) + overhead
            if result.routerReason == nil { result.routerReason = events.joined(separator: " | ") }
        }

        if kind == .planAct {
            let limit = BudgetController.planLimit(kind: kind, remaining: remaining)
            let before = result.outputTokens ?? 0
            let planStarted = ProcessInfo.processInfo.systemUptime
            let planTurn = try await generate(
                PhonePrompt.plan(prompt), rounds: [], tools: nil, limit: limit, started: started, result: &result,
                captureTiming: false, role: .plan, seed: seed, log: log)
            remaining = max(0, remaining - ((result.outputTokens ?? 0) - before))
            result.plan = planTurn.text
            result.planLatencyMs = (ProcessInfo.processInfo.systemUptime - planStarted) * 1000
            planned = true
            planCount += 1
            events.append("r0:plan:upfront:limit=\(limit):left=\(remaining)")
        }

        var action = result.plan.map { PhonePrompt.action(prompt, plan: $0) } ?? prompt
        var rounds = [Round]()
        var lastStop = result.stopReason
        var lastText = ""
        var lastHadCalls = false

        for round in 0..<BudgetCaps.maxToolRounds {
            let t0 = ProcessInfo.processInfo.systemUptime
            let view = BudgetTrajectory(
                prompt: prompt, roundsDone: round, remainingTokens: remaining,
                remainingRounds: BudgetCaps.maxToolRounds - round,
                lastStop: lastStop, lastHadCalls: lastHadCalls, lastText: lastText,
                planned: planned,
                toolOutputs: rounds.flatMap { $0.calls.map { ($0.call.function.name, $0.output) } })
            if kind == .adaptiveStep {
                let step = BudgetController.step(view)
                overhead += (ProcessInfo.processInfo.systemUptime - t0) * 1000
                if step.mode == .stop {
                    events.append("r\(round):stop:\(step.trigger):left=\(remaining)")
                    break
                }
                let before = result.outputTokens ?? 0
                let turn: Round
                if step.mode == .slow {
                    let budget = min(step.thinkBudget ?? BudgetCaps.shortPlan, max(0, remaining))
                    if budget <= 0 { break }
                    turn = try await think(
                        action, rounds: rounds, budget: budget, earlyExit: false,
                        started: started, result: &result, log: log)
                } else {
                    let cap = step.mode == .recover ? BudgetCaps.recovery : BudgetCaps.perRound
                    let limit = min(cap, remaining)
                    if limit <= 0 { break }
                    turn = try await generate(
                        action, rounds: rounds, tools: schemas, limit: limit, started: started, result: &result,
                        captureTiming: round == 0 && rounds.isEmpty, thinking: false,
                        role: .action, seed: seed, log: log)
                }
                remaining = max(0, remaining - ((result.outputTokens ?? 0) - before))
                lastText = turn.text
                lastHadCalls = !turn.calls.isEmpty
                lastStop = result.stopReason
                result.response += turn.text
                let used = (result.outputTokens ?? 0) - before
                events.append(
                    "r\(round):step:\(step.mode.rawValue):\(step.trigger):got=\(used):calls=\(turn.calls.count):stop=\(lastStop ?? "-"):left=\(remaining)")
                rounds.append(turn)
                if turn.calls.isEmpty, step.mode == .recover { break }
                continue
            }
            if kind == .actionAware {
                let step = BudgetController.action(view, recoveries: recoverCount)
                overhead += (ProcessInfo.processInfo.systemUptime - t0) * 1000
                if step.mode == .stop {
                    events.append("r\(round):stop:\(step.trigger):left=\(remaining)")
                    break
                }
                let before = result.outputTokens ?? 0
                let turn: Round
                if step.mode == .recover {
                    recoverCount += 1
                    let budget = min(BudgetCaps.shortPlan, max(0, remaining))
                    if budget <= 0 { break }
                    turn = try await think(
                        action, rounds: rounds, budget: budget, earlyExit: false,
                        started: started, result: &result, log: log)
                } else {
                    let limit = min(BudgetCaps.perRound, remaining)
                    if limit <= 0 { break }
                    turn = try await generate(
                        action, rounds: rounds, tools: schemas, limit: limit, started: started, result: &result,
                        captureTiming: round == 0 && rounds.isEmpty, thinking: false,
                        role: .action, seed: seed, log: log)
                }
                remaining = max(0, remaining - ((result.outputTokens ?? 0) - before))
                lastText = turn.text
                lastHadCalls = !turn.calls.isEmpty
                lastStop = result.stopReason
                result.response += turn.text
                let used = (result.outputTokens ?? 0) - before
                events.append(
                    "r\(round):\(step.mode.rawValue):\(step.trigger):got=\(used):calls=\(turn.calls.count):stop=\(lastStop ?? "-"):left=\(remaining)")
                rounds.append(turn)
                continue
            }
            let decision = BudgetController.observe(view, kind: kind)
            overhead += (ProcessInfo.processInfo.systemUptime - t0) * 1000

            if decision.action == "stop" {
                events.append("r\(round):stop:\(decision.trigger ?? "budget"):left=\(remaining)")
                break
            }
            if decision.action == "plan", remaining >= 16 {
                let limit = BudgetController.planLimit(kind: kind, remaining: remaining)
                let before = result.outputTokens ?? 0
                let planStarted = ProcessInfo.processInfo.systemUptime
                let planTurn = try await generate(
                    PhonePrompt.plan(prompt), rounds: rounds, tools: nil, limit: limit, started: started,
                    result: &result, captureTiming: false, role: .plan, seed: seed, log: log)
                remaining = max(0, remaining - ((result.outputTokens ?? 0) - before))
                result.plan = planTurn.text
                result.planLatencyMs = (result.planLatencyMs ?? 0)
                    + (ProcessInfo.processInfo.systemUptime - planStarted) * 1000
                action = PhonePrompt.action(prompt, plan: planTurn.text)
                planned = true
                planCount += 1
                events.append("r\(round):plan:\(decision.trigger ?? "?"):limit=\(limit):left=\(remaining)")
            }

            let limit = BudgetController.nextLimit(remaining: remaining)
            if limit <= 0 { break }
            let before = result.outputTokens ?? 0
            var turn: Round
            if let budget = strategy.thinkingBudget {
                turn = try await think(
                    action, rounds: rounds, budget: min(budget, limit), earlyExit: strategy == .earlyExit,
                    started: started, result: &result, log: log)
            } else {
                    turn = try await generate(
                        action, rounds: rounds, tools: schemas, limit: limit, started: started, result: &result,
                        captureTiming: round == 0 && rounds.isEmpty,
                        thinking: strategy != .noThink && strategy != .noThinkRuntime,
                        role: .action, seed: seed, log: log)
            }
            remaining = max(0, remaining - ((result.outputTokens ?? 0) - before))
            lastText = turn.text
            lastHadCalls = !turn.calls.isEmpty
            lastStop = result.stopReason
            result.response += turn.text
            events.append(
                "r\(round):gen:limit=\(limit):got=\((result.outputTokens ?? 0) - before):calls=\(turn.calls.count):stop=\(lastStop ?? "-"):left=\(remaining)")

            if turn.calls.isEmpty {
                let t1 = ProcessInfo.processInfo.systemUptime
                let after = BudgetTrajectory(
                    prompt: prompt, roundsDone: round + 1, remainingTokens: remaining,
                    remainingRounds: BudgetCaps.maxToolRounds - round - 1,
                    lastStop: lastStop, lastHadCalls: false, lastText: lastText,
                    planned: planned,
                    toolOutputs: rounds.flatMap { $0.calls.map { ($0.call.function.name, $0.output) } })
                let next = BudgetController.observe(after, kind: kind)
                overhead += (ProcessInfo.processInfo.systemUptime - t1) * 1000
                if next.action == "recover" || (next.action == "plan" && kind == .reactiveBudget) {
                    if next.action == "plan", remaining >= 16 {
                        let pl = BudgetController.planLimit(kind: kind, remaining: remaining)
                        let b2 = result.outputTokens ?? 0
                        let planTurn = try await generate(
                            PhonePrompt.plan(prompt), rounds: rounds, tools: nil, limit: pl, started: started,
                            result: &result, captureTiming: false, role: .plan, seed: seed, log: log)
                        remaining = max(0, remaining - ((result.outputTokens ?? 0) - b2))
                        result.plan = planTurn.text
                        action = PhonePrompt.action(prompt, plan: planTurn.text)
                        planned = true
                        planCount += 1
                        events.append("r\(round):plan:\(next.trigger ?? "?"):after_empty:left=\(remaining)")
                    }
                    let recLimit = min(BudgetCaps.recovery, remaining)
                    if recLimit >= 16 {
                        let b3 = result.outputTokens ?? 0
                        let rec = try await generate(
                            action, rounds: rounds, tools: schemas, limit: recLimit, started: started,
                            result: &result, captureTiming: false, thinking: false, role: .action, seed: seed, log: log)
                        remaining = max(0, remaining - ((result.outputTokens ?? 0) - b3))
                        lastText = rec.text
                        lastHadCalls = !rec.calls.isEmpty
                        lastStop = result.stopReason
                        result.response += rec.text
                        events.append(
                            "r\(round):recover:\(next.trigger ?? "no_progress"):got=\((result.outputTokens ?? 0) - b3):calls=\(rec.calls.count):left=\(remaining)")
                        if rec.calls.isEmpty { break }
                        rounds.append(rec)
                        continue
                    }
                }
                break
            }
            rounds.append(turn)
        }
    }

    private enum TurnRole { case plan, action }

    /// Soma decode e separa o primeiro prefill dos reprocessamentos. O plano não entra nesses campos.
    private func absorb(_ info: GenerateCompletionInfo, result: inout BenchmarkResult, role: TurnRole, primary: Bool) {
        guard role == .action else { return }
        let promptMs = info.promptTime.isFinite && info.promptTime > 0 ? info.promptTime * 1000 : nil
        let decodeMs = info.generateTime.isFinite && info.generateTime > 0 ? info.generateTime * 1000 : nil
        if let promptMs {
            if result.ttftMs == nil {
                result.ttftMs = promptMs
                if info.promptTokensPerSecond.isFinite {
                    result.prefillTokensPerSecond = info.promptTokensPerSecond
                }
            } else {
                result.repeatedPrefillMs = (result.repeatedPrefillMs ?? 0) + promptMs
            }
        }
        if let decodeMs {
            result.decodeLatencyMs = (result.decodeLatencyMs ?? 0) + decodeMs
            if primary, result.decodeTokensPerSecond == nil, info.tokensPerSecond.isFinite {
                result.decodeTokensPerSecond = info.tokensPerSecond
            }
        }
    }

    private func generate(
        _ prompt: String,
        rounds: [Round],
        tools: [ToolSpec]?,
        limit: Int,
        started: TimeInterval,
        result: inout BenchmarkResult,
        captureTiming: Bool,
        thinking: Bool = true,
        role: TurnRole,
        seed: UInt64?,
        log: ToolLog
    ) async throws -> Round {
        guard let container else { throw BenchError.failed("Modelo MLX não carregado.") }
        await Self.waitForeground()
        let input = try await container.prepare(input: UserInput(
            chat: Self.chat(prompt, rounds: rounds, system: tools != nil), tools: tools,
            additionalContext: thinking ? nil : ["enable_thinking": false]))
        let fullCount = input.text.tokens.size
        // Prefixo estático (system + schema das tools) pré-calculado 1× por modelo/catálogo;
        // em KVCacheSimple trimável (Qwen3), clona o cache base e só faz prefill do sufixo do usuário/rodadas.
        let cached = try await prepareCachedInput(input, tools: tools, thinking: thinking)
        // temperature 0 é argmax; o seed do MLX não altera esses tokens.
        let parameters = GenerateParameters(maxTokens: limit, temperature: 0, seed: seed)
        let stream: AsyncStream<Generation>
        if let cache = cached.cache {
            let sliced = UncheckedBox(value: cached.input)
            let boxedCache = UncheckedBox(value: cache)
            stream = try await container.perform { (context: ModelContext) in
                try MLXLMCommon.generate(
                    input: sliced.value, cache: boxedCache.value,
                    parameters: parameters, context: context, tools: tools)
            }
        } else {
            let raw = UncheckedBox(value: input)
            stream = try await container.perform { (context: ModelContext) in
                try MLXLMCommon.generate(
                    input: raw.value, parameters: parameters, context: context, tools: tools)
            }
        }
        var text = ""
        var calls = [ToolCall]()
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if captureTiming, result.firstTextMs == nil, !chunk.isEmpty {
                    result.firstTextMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                text += chunk
            case .info(let info):
                result.inputTokens = (result.inputTokens ?? 0) + fullCount
                result.outputTokens = (result.outputTokens ?? 0) + info.generationTokenCount
                absorb(info, result: &result, role: role, primary: captureTiming)
                if role == .action {
                    switch info.stopReason {
                    case .stop: result.stopReason = "stop"
                    case .length: result.stopReason = "length"
                    case .cancelled: result.stopReason = "cancelled"
                    }
                }
            case .toolCall(let call):
                calls.append(call)
            }
        }
        // Ferramentas abrem outros apps; só executa depois que a GPU terminou, senão o iOS mata o app em background.
        return (text, try await execute(calls, log: log))
    }

    private func prepareCachedInput(
        _ full: LMInput,
        tools: [ToolSpec]?,
        thinking: Bool
    ) async throws -> (input: LMInput, cache: [any KVCache]?) {
        guard let container, let tools, loaded == .qwen else { return (full, nil) }
        // enable_thinking muda os tokens do prefixo; um cache por modo. Alternar thinking
        // entre rodadas reconstrói o prefixo uma vez, depois reusa o KV do sufixo.
        let key = "qwen|\(thinking)|\(catalog.map(\.id).joined(separator: ","))"
        if prefixKey != key || prefixCache.isEmpty {
            let probeA = try await container.prepare(input: UserInput(
                chat: [.system(PhonePrompt.instructions), .user("A")],
                tools: tools, additionalContext: thinking ? nil : ["enable_thinking": false]))
            let probeB = try await container.prepare(input: UserInput(
                chat: [.system(PhonePrompt.instructions), .user("B")],
                tools: tools, additionalContext: thinking ? nil : ["enable_thinking": false]))
            let a = probeA.text.tokens.asType(.int32).asArray(Int32.self)
            let b = probeB.text.tokens.asType(.int32).asArray(Int32.self)
            var common = 0
            while common < min(a.count, b.count) && a[common] == b[common] { common += 1 }
            guard common > 32 else { return (full, nil) }
            let shared = Array(a.prefix(common))
            let built: UncheckedBox<[any KVCache]> = try await container.perform { (context: ModelContext) in
                let cache = context.model.newCache(parameters: nil)
                let prefixInput = LMInput(tokens: MLXArray(shared))
                _ = try context.model.prepare(prefixInput, cache: cache, windowSize: 512)
                if shared.count % 512 != 0 {
                    let rem = shared.count % 512
                    let tail = MLXArray(shared.suffix(rem))[.newAxis, 0...]
                    let out = context.model(LMInput.Text(tokens: tail), cache: cache, state: nil)
                    eval(out.logits)
                }
                let states = cache.flatMap { $0.state }
                if !states.isEmpty { eval(states) }
                return UncheckedBox(value: cache)
            }
            prefixCache = built.value
            prefixTokens = shared
            prefixKey = key
        }
        let tokens = full.text.tokens.asType(.int32).asArray(Int32.self)
        let pCount = prefixTokens.count
        guard pCount > 0, tokens.count > pCount + 1,
              Array(tokens.prefix(pCount)) == prefixTokens,
              prefixCache.first?.offset == pCount else {
            return (full, nil)
        }
        let cloned = prefixCache.map { $0.copy() }
        let suffix = Array(tokens.dropFirst(pCount))
        return (LMInput(tokens: MLXArray(suffix)), cloned)
    }

    /// O iOS proíbe trabalho de GPU com o app fora de primeiro plano; espera o usuário voltar ao app.
    static func waitForeground() async {
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // Chat.Message não é Sendable: a conversa é montada a cada rodada a partir de valores Sendable.
    private nonisolated static func chat(_ prompt: String, rounds: [Round], system: Bool) -> [Chat.Message] {
        var messages = [Chat.Message]()
        if system { messages.append(.system(PhonePrompt.instructions)) }
        messages.append(.user(prompt))
        for round in rounds {
            messages.append(.assistant(round.text, toolCalls: round.calls.map { $0.call }))
            for item in round.calls { messages.append(.tool(item.output, id: item.call.id)) }
        }
        return messages
    }

    static let closeThink = "\n</think>\n\n"
    static let exitConfidence = 0.95

    /// Budget forcing (s1): pensa até `budget` tokens, fecha o `</think>` e força a resposta.
    /// Early exit (DEER): a cada "Wait" testa uma resposta e sai se a confiança média dos tokens passar do limiar.
    private func think(
        _ prompt: String,
        rounds: [Round],
        budget: Int,
        earlyExit: Bool,
        started: TimeInterval,
        result: inout BenchmarkResult,
        log: ToolLog
    ) async throws -> Round {
        guard let container else { throw BenchError.failed("Modelo MLX não carregado.") }
        await Self.waitForeground()
        let input = try await container.prepare(input: UserInput(
            chat: Self.chat(prompt, rounds: rounds, system: true), tools: schemas))
        let head = input.text.tokens.asType(.int32).asArray(Int32.self).map(Int.init)
        var thought = ""
        var used = 0
        while used < budget {
            let step = try await pass(
                head + (await container.encode(thought)), limit: budget - used,
                stop: earlyExit ? ["</think>", "Wait"] : ["</think>"], started: started, result: &result)
            thought += step.text
            used += step.tokens
            guard step.stop == "Wait" else { break }
            let sampler = ConfidenceSampler()
            let trial = try await pass(
                head + (await container.encode(thought + Self.closeThink)), limit: max(512 - used, 1),
                started: started, result: &result, sampler: sampler)
            result.exitChecks = (result.exitChecks ?? 0) + 1
            if !trial.calls.isEmpty, sampler.confidence >= Self.exitConfidence {
                result.exitedEarly = true
                result.thinkingTokens = (result.thinkingTokens ?? 0) + used
                result.response += thought + Self.closeThink
                return (trial.text, try await execute(trial.calls, log: log))
            }
            thought += "Wait"
        }
        result.thinkingTokens = (result.thinkingTokens ?? 0) + used
        result.response += thought + Self.closeThink
        let answer = try await pass(
            head + (await container.encode(thought + Self.closeThink)), limit: max(512 - used, 1),
            started: started, result: &result)
        return (answer.text, try await execute(answer.calls, log: log))
    }

    /// Gera a partir de tokens crus, sem executar ferramentas; para no primeiro marcador de `stop`.
    private func pass(
        _ tokens: [Int],
        limit: Int,
        stop: [String] = [],
        started: TimeInterval,
        result: inout BenchmarkResult,
        sampler: ConfidenceSampler? = nil
    ) async throws -> (text: String, calls: [ToolCall], stop: String?, tokens: Int) {
        guard let container else { throw BenchError.failed("Modelo MLX não carregado.") }
        await Self.waitForeground()
        let tools = schemas
        let fullInput = LMInput(tokens: MLXArray(tokens.map(Int32.init)))
        let cached = try await prepareCachedInput(fullInput, tools: tools, thinking: true)
        let sliced = UncheckedBox(value: cached.input)
        let boxedCache = UncheckedBox(value: cached.cache)
        let (stream, task) = try await container.perform { (context: ModelContext) in
            let input = sliced.value
            let cache = boxedCache.value
            let iterator = if let sampler {
                try TokenIterator(
                    input: input, model: context.model, cache: cache, processor: nil, sampler: sampler, maxTokens: limit)
            } else {
                try TokenIterator(
                    input: input, model: context.model, cache: cache, processor: nil, sampler: ArgMaxSampler(), maxTokens: limit)
            }
            return generateTask(
                promptTokenCount: tokens.count, modelConfiguration: context.configuration,
                tokenizer: context.tokenizer, iterator: iterator, tools: tools)
        }
        var text = ""
        var calls = [ToolCall]()
        var hit: String?
        var generated: Int?
        var stopped = false
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if !stopped {
                    if result.firstTextMs == nil, !chunk.isEmpty {
                        result.firstTextMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    }
                    text += chunk
                    if let marker = stop.first(where: { text.contains($0) }), let range = text.range(of: marker) {
                        text = String(text[..<range.lowerBound])
                        hit = marker
                        stopped = true
                        // Cancela o decode e continua lendo o stream até o info, para não perder o tempo já gasto.
                        task.cancel()
                    }
                }
            case .info(let info):
                generated = info.generationTokenCount
                let primary = result.ttftMs == nil
                absorb(info, result: &result, role: .action, primary: primary)
            case .toolCall(let call):
                if !stopped { calls.append(call) }
            }
        }
        // O info do MLX pode incluir alguns tokens gerados depois do marcador, até o cancelamento pegar.
        // A contagem de tokens do texto cortado continua a de antes.
        await task.value
        let count = if hit != nil {
            await container.encode(text).count
        } else if let generated {
            generated
        } else {
            await container.encode(text).count
        }
        result.inputTokens = (result.inputTokens ?? 0) + tokens.count
        result.outputTokens = (result.outputTokens ?? 0) + count
        return (text, calls, hit, count)
    }

    private func execute(_ calls: [ToolCall], log: ToolLog) async throws -> [(call: ToolCall, output: String)] {
        var done = [(call: ToolCall, output: String)]()
        for call in calls {
            let arguments = Self.toolValues(call.function.arguments)
            do {
                let output = try await ToolRuntime.execute(
                    id: call.function.name, arguments: arguments, world: world, log: log, catalog: catalog)
                done.append((call, output))
            } catch {
                if absorbToolErrors {
                    done.append((call, error.localizedDescription))
                } else {
                    throw error
                }
            }
        }
        return done
    }

    struct ChatLine: Sendable {
        enum Role: Sendable { case system, user, assistant, tool }
        var role: Role
        var content: String
        var calls: [ToolCall] = []
        var callID: String?
    }

    /// Um turno do chat sobre o modelo já carregado por `prepare`. Não executa ferramentas: devolve as chamadas.
    func chatTurn(
        _ lines: [ChatLine], tools: [ToolSpec], limit: Int, onText: (String) -> Void
    ) async throws -> (text: String, calls: [ToolCall], promptTokens: Int, outputTokens: Int) {
        guard let container else { throw BenchError.failed("Modelo MLX não carregado.") }
        await Self.waitForeground()
        let input = try await container.prepare(input: UserInput(
            chat: Self.chat(lines), tools: tools, additionalContext: ["enable_thinking": false]))
        let promptTokens = input.text.tokens.size
        let raw = UncheckedBox(value: input)
        let parameters = GenerateParameters(maxTokens: limit, temperature: 0)
        let stream = try await container.perform { (context: ModelContext) in
            try MLXLMCommon.generate(input: raw.value, parameters: parameters, context: context, tools: tools)
        }
        var text = ""
        var calls = [ToolCall]()
        var outputTokens = 0
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                text += chunk
                onText(text)
            case .info(let info): outputTokens = info.generationTokenCount
            case .toolCall(let call): calls.append(call)
            }
        }
        try Task.checkCancellation()
        // Qwen às vezes escreve o nome da tool (ou JSON) como texto sem emitir `.toolCall`.
        let resolved = calls.isEmpty ? Self.recoverToolCalls(from: text, known: tools.compactMap(Self.toolName)) : calls
        return (text, resolved, promptTokens, outputTokens)
    }

    /// Recupera chamadas quando o modelo não usou o formato estruturado (`<tool_call>…`).
    static func recoverToolCalls(from text: String, known: [String]) -> [ToolCall] {
        let known = Set(known)
        guard !known.isEmpty else { return [] }
        var cleaned = text.replacing(/<think>[\s\S]*?<\/think>/, with: "")
        if let open = cleaned.range(of: "<think>") { cleaned = String(cleaned[..<open.lowerBound]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let parser = ToolCallFormat.json.createParser()
        let tagged = parser.parseEOS(cleaned, tools: nil).filter { known.contains($0.function.name) }
        if !tagged.isEmpty { return tagged }

        if let data = cleaned.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let call = toolCall(fromJSON: object, known: known) { return [call] }
            if let list = object as? [Any] {
                let calls = list.compactMap { toolCall(fromJSON: $0, known: known) }
                if !calls.isEmpty { return calls }
            }
        }

        // Nome nu: "consultarCompromissos" (o bug visto no chat com Qwen).
        let line = cleaned.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? cleaned
        if known.contains(line) {
            return [ToolCall(function: .init(name: line, arguments: [:]), id: UUID().uuidString)]
        }
        return []
    }

    private static func toolName(_ spec: ToolSpec) -> String? {
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String
    }

    private static func toolCall(fromJSON raw: Any, known: Set<String>) -> ToolCall? {
        guard var object = raw as? [String: Any] else { return nil }
        if let nested = object["function"] as? [String: Any] { object = nested }
        guard let name = object["name"] as? String, known.contains(name) else { return nil }
        let argsRaw = object["arguments"] ?? object["parameters"] ?? [:]
        var arguments: [String: JSONValue] = [:]
        if let dict = argsRaw as? [String: Any] {
            for (key, value) in dict { arguments[key] = JSONValue.from(value) }
        }
        return ToolCall(function: .init(name: name, arguments: arguments), id: UUID().uuidString)
    }

    /// Texto que é só nome/JSON de ferramenta — não deve ir para a bolha do chat.
    static func looksLikeToolPayload(_ text: String, known: [String]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if known.contains(trimmed) { return true }
        if trimmed.contains("<tool_call>") { return true }
        if trimmed.hasPrefix("{"), trimmed.contains("\"name\"") { return true }
        return !recoverToolCalls(from: trimmed, known: known).isEmpty
    }

    private nonisolated static func chat(_ lines: [ChatLine]) -> [Chat.Message] {
        lines.map { line in
            switch line.role {
            case .system: .system(line.content)
            case .user: .user(line.content)
            case .assistant: .assistant(line.content, toolCalls: line.calls.isEmpty ? nil : line.calls)
            case .tool: .tool(line.content, id: line.callID)
            }
        }
    }

    static func toolValues(_ arguments: [String: JSONValue]) -> [String: ToolValue] {
        var values: [String: ToolValue] = [:]
        for (key, value) in arguments {
            if let converted = convert(value) { values[key] = converted }
        }
        return values
    }

    private static func convert(_ value: JSONValue) -> ToolValue? {
        switch value {
        case .string(let text): .string(text)
        case .int(let number): .int(number)
        case .double(let number): .double(number)
        case .bool(let flag): .bool(flag)
        case .array(let values): .list(values.compactMap(convert))
        case .null, .object: nil
        }
    }

    static func specs(for tools: [any AgentTool]) -> [ToolSpec] {
        tools.map { schema($0.id, $0.toolDescription, $0.parameters) }
    }

    private static let appleSchemas: [ToolSpec] = specs(for: ToolRegistry.tools)

    private func configuration(for agent: Agent) -> ModelConfiguration {
        switch agent {
        case .qwen:
            var config = LLMRegistry.qwen3_1_7b_4bit
            config.toolCallFormat = .json
            return config
        case .gemma:
            var config = LLMRegistry.gemma4_e2b_it_4bit
            config.toolCallFormat = .gemma4
            return config
        case .apple:
            preconditionFailure("Apple não carrega pelo MLX.")
        case .minicpm5, .lfm25, .gemma4, .qwen35:
            // MiniCPM5 declara `llama` e o infer cairia em llama3; o formato nativo
            // `<function name=…><param …>` não tem parser no pacote e é lido do texto no Mac.
            // `.json` só procura `<tool_call>`, então não consome esse texto.
            // LFM2.5 idem: o parser pythonic do pacote pega só a 1ª chamada da lista e não aceita
            // nome com ponto; `[f(a=1), g(b=2)]` é decodificado no Mac com `ast`.
            let format: ToolCallFormat = switch agent {
            case .gemma4: .gemma4
            case .qwen35: .xmlFunction
            default: .json
            }
            return ModelConfiguration(
                id: agent.hubID, revision: agent.revision,
                extraEOSTokens: agent == .gemma4 ? ["<turn|>"] : ["<|im_end|>"],
                toolCallFormat: format)
        }
    }

    private static func schema(_ name: String, _ description: String, _ fields: [ToolParameter]) -> ToolSpec {
        var properties = [String: any Sendable]()
        for field in fields {
            properties[field.name] = ["type": field.type, "description": field.detail]
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": fields.filter(\.required).map(\.name),
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }
}
