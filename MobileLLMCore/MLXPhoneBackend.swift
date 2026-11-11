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

/// KV de system + tools e de onde veio (`disk` ou `built`), com o tempo gasto.
private struct PrefixBuild: @unchecked Sendable {
    let value: [any KVCache]
    let label: String
    let ms: Double
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
    private var draft: UncheckedBox<any LanguageModel>?
    /// Cabeça MTP do modelo carregado (`MTPDrafters`), carregada na 1ª requisição com `mtp_block`.
    private var mtpDrafter: UncheckedBox<Any>?
    #if MLX_LM_MAIN
    /// Cabeça MTP própria e o embedding atado do alvo (`MTPPipelineIterator`), carregados no 1º uso.
    private var mtpPipeline: UncheckedBox<(MTPHead, TiedVocabulary)>?
    #endif
    private var prefixKey: String?
    private var prefixTokens = [Int32]()
    private var prefixCache = [any KVCache]()
    private var servePrefixTokens = [Int32]()
    private var servePrefixCache = [any KVCache]()
    private var serveConvTokens = [Int32]()
    private var serveConvCache = [any KVCache]()
    private var serveTurnTokens = [Int32]()
    private var serveTurnCache = [any KVCache]()
    /// Tokens do prompt que vieram do KV guardado no último `serveTurn`.
    private(set) var serveReusedTokens = 0
    /// Decomposição do último `chatTurn` (ms e tokens), para o log do servidor.
    private(set) var serveStats = ServeStats()
    private var serveBudgetPrefix = false
    private var world = ToolWorld(fixtures: .standard, mode: .simulated)
    private var catalog: [any AgentTool] = ToolRegistry.tools
    private var schemas: [ToolSpec] = MLXPhoneBackend.appleSchemas
    private var absorbToolErrors = false

    init() {
        ToolArguments.selfCheck()
        ConfidenceSampler.selfCheck()
        Memory.cacheLimit = 256 * 1024 * 1024
    }

    /// Modelo carregado na GPU agora (nil = nenhum ou Apple).
    var loadedAgent: Agent? { loaded }

    func prepare(
        _ agent: Agent, status: (String) -> Void, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Double? {
        guard agent != .apple else { return nil }
        if loaded == agent, container != nil { return nil }
        unload()
        await Self.waitForeground()
        status("Baixando e carregando \(agent.title). A primeira vez precisa de internet.")
        let started = ProcessInfo.processInfo.systemUptime
        // O registro padrão tenta MLXVLM antes: o Qwen3.5 vira VLM (o Gemma 4 E2B falha lá e cai no LLM), e o `prepare` VLM ignora
        // `prefillStepSize` e faz prefill do prompt inteiro (~1 MB/token → jetsam com ~5k tokens).
        let downloader = #hubDownloader()
        let config: ModelConfiguration
        // SFT: base 4 bits com o template do treino; o LoRA (PEFT) entra depois, em runtime, sem fundir.
        if let sft = agent.sft { config = try await sft.configuration(downloader) } else { config = configuration(for: agent) }
        container = try await LLMModelFactory.shared.loadContainer(
            from: downloader, using: #huggingFaceTokenizerLoader(), configuration: config,
            progressHandler: { report in progress?(report.fractionCompleted) })
        if let sft = agent.sft, let base = container {
            status("Aplicando LoRA \(sft.adapterID).")
            do { _ = try await sft.apply(to: base, downloader) } catch { container = nil; throw error }
        }
        loaded = agent
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        status("\(agent.title) carregado.")
        return ms
    }

    /// Custo de uma passada com T tokens sobre uma cópia do KV de system + tools (microbenchmark do rascunho):
    /// mediana de `reps` passadas, cada uma sincronizada. Nada fica no cache do servidor.
    func benchForward(sizes: [Int], reps: Int) async throws -> [[String: Any]] {
        guard let container, !servePrefixCache.isEmpty else { throw BenchError.failed("sem prefixo em memória") }
        let base = UncheckedBox(value: servePrefixCache)
        let context = servePrefixTokens.count
        let rows: UncheckedBox<[[String: Any]]> = try await container.perform { (ctx: ModelContext) in
            var rows = [[String: Any]]()
            for size in sizes {
                var times = [Double]()
                for _ in 0 ..< reps + 1 {
                    let cache = base.value.map { $0.copy() }
                    eval(cache.flatMap { $0.state })
                    let tokens = MLXArray((0 ..< size).map { _ in Int32.random(in: 1000 ..< 50000) })[.newAxis, 0...]
                    let started = ProcessInfo.processInfo.systemUptime
                    let logits = ctx.model(LMInput.Text(tokens: tokens), cache: cache, state: nil).logits
                    eval(MLX.argMax(logits, axis: -1), cache.flatMap { $0.state })
                    times.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
                }
                let sorted = times.dropFirst().sorted()
                rows.append(["tokens": size, "context": context, "median_ms": sorted[sorted.count / 2],
                             "min_ms": sorted.first ?? 0, "max_ms": sorted.last ?? 0])
            }
            return UncheckedBox(value: rows)
        }
        return rows.value
    }

    #if MLX_LM_MAIN
    /// Diagnóstico da cabeça MTP própria (`MTPHead`) no aparelho, sem especular: o alvo gera em greedy e, a cada passo,
    /// a MTP prevê o token depois do próximo. Mede a aceitação de 1 rascunho com o vocabulário inteiro e com o
    /// reduzido (tokens do prompt e já gerados) e o custo, sincronizado, do passo do alvo e de cada rascunho.
    func benchMTP(_ lines: [ChatLine], tools: [ToolSpec], limit: Int, thinking: Bool) async throws -> [String: Any] {
        guard let container, let loaded else { throw BenchError.failed("Modelo MLX não carregado.") }
        let url = MTPDrafters.directory(for: loaded).appendingPathComponent("model.safetensors")
        let input = try await container.prepare(input: UserInput(
            chat: Self.chat(lines), tools: tools, additionalContext: thinkingContext(thinking)))
        let raw = UncheckedBox(value: input)
        let result: UncheckedBox<[String: Any]> = try await container.perform { (ctx: ModelContext) in
            func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
            let head = try MTPHead.load(url)
            let vocab = try TiedVocabulary(model: ctx.model)
            let cache = try ctx.model.makeCache(parameters: nil)
            let mtpCache = KVCacheSimple()
            var emit = LMOutput.State()
            emit[mtpEmitFlagKey] = true
            let prompt = raw.value.text.tokens.reshaped(-1).asArray(Int32.self)
            let stop = Set(["<|im_end|>", "<|endoftext|>"].compactMap { ctx.tokenizer.convertTokenToId($0) })
            let chunk = 256

            // Prefill do alvo em blocos (com o estado ligado, ele projeta todas as posições no vocabulário),
            // guardando o estado oculto de cada posição.
            var t0 = now()
            var hiddens = [MLXArray]()
            var last = MLXArray(0)
            var at = 0
            while at < prompt.count {
                let end = Swift.min(at + chunk, prompt.count)
                let out = ctx.model(LMInput.Text(tokens: MLXArray(Array(prompt[at ..< end]))[.newAxis]),
                                    cache: cache, state: emit)
                guard let hidden = out.state?[mtpLastHiddenStatesKey] else { throw MTPDrafters.MTPError.notADrafter }
                last = MLX.argMax(out.logits[0, -1], axis: -1)
                eval(hidden, last, cache.flatMap { $0.state })
                hiddens.append(hidden)
                Memory.clearCache()
                at = end
            }
            let prefillMs = now() - t0
            var y = last.item(Int32.self)
            // Prefill da MTP: a posição i usa emb(x[i+1]) e h[i]; x[N] = y.
            t0 = now()
            let shifted = Array(prompt.dropFirst()) + [y]
            let hidden = concatenated(hiddens, axis: 1)
            var mtpOut = MLXArray(0)
            at = 0
            while at < shifted.count {
                let end = Swift.min(at + chunk, shifted.count)
                mtpOut = head(embeds: vocab.embed(MLXArray(Array(shifted[at ..< end])))[.newAxis],
                              hidden: hidden[0..., at ..< end, 0...], cache: mtpCache)
                eval(mtpOut)
                at = end
            }
            let mtpPrefillMs = now() - t0
            var seen = Set(prompt)
            func drafts(_ state: MLXArray) -> (full: Int32, subset: Int32, fullMs: Double, subsetMs: Double, size: Int) {
                let s = state[0..., (-1)..., 0...]
                var t = now()
                let full = MLX.argMax(vocab.logits(s)[0, 0], axis: -1)
                eval(full)
                let fullMs = now() - t
                let ids = Array(seen)
                t = now()
                let pick = MLX.argMax(vocab.logits(s, subset: MLXArray(ids))[0, 0], axis: -1)
                eval(pick)
                let subsetMs = now() - t
                return (full.item(Int32.self), ids[pick.item(Int.self)], fullMs, subsetMs, ids.count)
            }
            var draft = drafts(mtpOut)
            var steps = 0, okFull = 0, okSubset = 0, inSubset = 0
            var targetMs = 0.0, headMs = 0.0, fullMs = 0.0, subsetMs = 0.0
            for _ in 0 ..< limit {
                t0 = now()
                let out = ctx.model(LMInput.Text(tokens: MLXArray([y])[.newAxis]), cache: cache, state: emit)
                guard let h = out.state?[mtpLastHiddenStatesKey] else { break }
                let next = MLX.argMax(out.logits[0, -1], axis: -1)
                eval(next, h)
                targetMs += now() - t0
                let token = next.item(Int32.self)
                steps += 1
                okFull += draft.full == token ? 1 : 0
                okSubset += draft.subset == token ? 1 : 0
                inSubset += seen.contains(token) ? 1 : 0
                seen.insert(token)
                if stop.contains(Int(token)) { break }
                t0 = now()
                mtpOut = head(embeds: vocab.embed(MLXArray([token]))[.newAxis], hidden: h, cache: mtpCache)
                eval(mtpOut)
                headMs += now() - t0
                draft = drafts(mtpOut)
                fullMs += draft.fullMs
                subsetMs += draft.subsetMs
                y = token
            }
            let n = Double(Swift.max(steps, 1))
            return UncheckedBox(value: [
                "prompt_tokens": prompt.count, "steps": steps, "prefill_ms": prefillMs, "mtp_prefill_ms": mtpPrefillMs,
                "accept_full": Double(okFull) / n, "accept_subset": Double(okSubset) / n,
                "next_token_in_subset": Double(inSubset) / n, "subset_size": draft.size,
                "target_step_ms": targetMs / n, "mtp_layer_ms": headMs / n,
                "draft_full_vocab_ms": fullMs / n, "draft_subset_ms": subsetMs / n,
            ])
        }
        return result.value
    }
    #endif

    /// Esquece os KV do servidor em memória (turno, conversa e, sem `keepSystem`, system + tools); `disk` apaga
    /// também o `PrefixStore`. O modelo continua carregado: separa o custo de prefill do de carregar pesos.
    func resetServeCaches(disk: Bool, keepSystem: Bool = false) -> Int {
        if !keepSystem {
            servePrefixTokens = []
            servePrefixCache = []
        }
        serveConvTokens = []
        serveConvCache = []
        serveTurnTokens = []
        serveTurnCache = []
        Memory.clearCache()
        guard let loaded else { return 0 }
        let store = PrefixStore(model: loaded.model)
        if disk { store.clear() }
        return store.files
    }

    func unload() {
        container = nil
        loaded = nil
        draft = nil
        mtpDrafter = nil
        #if MLX_LM_MAIN
        mtpPipeline = nil
        #endif
        prefixKey = nil
        prefixTokens = []
        prefixCache = []
        servePrefixTokens = []
        servePrefixCache = []
        serveConvTokens = []
        serveConvCache = []
        serveTurnTokens = []
        serveTurnCache = []
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
        if strategy == .speculative { try await loadDraft() }
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
        } else if strategy == .adaptiveNonLive {
            let decision = NonLiveRouter.choose(task)
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
        case .budget64, .budget128, .budget256, .budget512:
            // Duas passadas com prefill completo: o raciocínio fica idêntico ao da Reasoning até o teto
            // (reusar o KV do prompt muda a numérica e o greedy diverge; o MambaCache do Qwen3.5 não apara).
            answer = try await astThink(
                agent, chat: Self.astChat(messages), tools: tools, budget: chosen.thinkingBudget ?? 64,
                started: started, result: &result)
        case .speculative:
            answer = try await astGenerate(messages, tools: tools, thinking: direct, limit: Self.astLimit,
                                           seed: seed, started: started, role: .action, result: &result,
                                           speculative: true)
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

    /// Rascunho do speculative do MiniCPM5: o MiniCPM5-1B tem tokenizer idêntico ao do 2B.
    private func loadDraft() async throws {
        guard draft == nil else { return }
        let small = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(
                id: "openbmb/MiniCPM5-1B-MLX", revision: "9879b18bf2928355fcdf4287635388a3665a40cb"))
        draft = await small.perform { UncheckedBox(value: $0.model) }
    }

    private func astGenerate(
        _ messages: [[String: String]], tools: [ToolSpec], thinking: Bool?, limit: Int,
        seed: UInt64?, started: TimeInterval, role: TurnRole, result: inout BenchmarkResult,
        speculative: Bool = false
    ) async throws -> (text: String, calls: [ToolCall]) {
        guard let container else { throw BenchError.failed("Modelo MLX não carregado.") }
        guard !speculative || draft != nil else { throw BenchError.failed("Sem rascunho carregado.") }
        await Self.waitForeground()
        let input = try await container.prepare(input: UserInput(
            chat: Self.astChat(messages), tools: tools,
            additionalContext: thinking.map { ["enable_thinking": $0] }))
        let fullCount = input.text.tokens.size
        let parameters = GenerateParameters(maxTokens: limit, temperature: 0, seed: seed).legacyPrefill()
        let raw = UncheckedBox(value: input)
        let draftModel = speculative ? draft : nil
        let stream = try await container.perform { (context: ModelContext) in
            if let draftModel {
                return try MLXLMCommon.generate(
                    input: raw.value, parameters: parameters, context: context,
                    draftModel: draftModel.value, numDraftTokens: 2)
            }
            return try MLXLMCommon.generate(input: raw.value, parameters: parameters, context: context, tools: tools)
        }
        var rawText = RawText()
        var text: String {
            get { rawText.value }
            set { rawText.value = newValue }
        }
        var calls = [ToolCall]()
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if role == .action, result.firstTextMs == nil, !chunk.isEmpty {
                    result.firstTextMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                rawText.chunk(chunk)
                // Modelos sem parser MLX (MiniCPM5, LFM2.5): a chamada fecha no texto, depois do thinking.
                if role == .action, result.astFirstCallMs == nil, thinking == false || text.contains("</think>"),
                   Self.callClosers.contains(where: (text.components(separatedBy: "</think>").last ?? "").contains) {
                    result.astFirstCallMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
            case .info(let info):
                result.inputTokens = (result.inputTokens ?? 0) + fullCount
                result.outputTokens = (result.outputTokens ?? 0) + info.generationTokenCount
                absorb(info, result: &result, role: role, primary: true)
                if speculative {
                    let telemetry = info.speculativeDecodingTelemetry
                    result.controllerTrace = [
                        "draft:\(telemetry?.acceptedDraftTokenCount ?? 0)/\(telemetry?.draftTokenCount ?? 0)"]
                }
                if role == .action {
                    result.stopReason = switch info.stopReason {
                    case .stop: "stop"
                    case .length: "length"
                    case .cancelled: "cancelled"
                    #if MLX_LM_MAIN
                    case .steered: "steered"
                    #endif
                    }
                }
            #if MLX_LM_MAIN
            case .reasoning(let piece):
                rawText.reasoning(piece)
            case .rejectedToolCall(let rejected):
                // O 3.31.4 deixava a chamada malformada no texto; `recoverToolCalls` ainda a lê dali.
                rawText.chunk(rejected.rawTextPreview)
            case .steering:
                break
            #endif
            case .toolCall(let call):
                rawText.close()
                if role == .action, result.astFirstCallMs == nil {
                    result.astFirstCallMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                calls.append(call)
            }
        }
        return (text, calls)
    }

    private static let callClosers = ["</function>", "</tool_call>", "<|tool_call_end|>"]

    /// s1 com o marcador nativo do modelo: pensa até `budget` tokens, fecha e força a resposta.
    private func astThink(
        _ agent: Agent, chat: sending [Chat.Message], tools: [ToolSpec], budget: Int, limit: Int = astLimit,
        started: TimeInterval, result: inout BenchmarkResult
    ) async throws -> (text: String, calls: [ToolCall]) {
        guard let container, let close = agent.thinkClose else { throw BenchError.failed("Sem marcador de thinking.") }
        await Self.waitForeground()
        let input = try await container.prepare(input: UserInput(
            chat: chat, tools: tools,
            additionalContext: agent.thinkingSwitch ? ["enable_thinking": true] : nil))
        let head = input.text.tokens.asType(.int32).asArray(Int32.self).map(Int.init)
        let thought = try await pass(head, limit: budget, stop: [close], started: started, result: &result)
        let closing = close == "</think>" ? "\n</think>\n\n" : close
        result.thinkingTokens = thought.tokens
        result.response += thought.text + closing
        let answer = try await pass(
            head + (await container.encode(thought.text + closing)), limit: limit - thought.tokens,
            started: started, result: &result)
        result.inputTokens = head.count
        result.outputTokens = thought.tokens + answer.tokens
        result.stopReason = answer.stop ?? (answer.tokens >= limit - thought.tokens ? "length" : "stop")
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
            additionalContext: thinkingContext(thinking)))
        let fullCount = input.text.tokens.size
        // Prefixo estático (system + schema das tools) pré-calculado 1× por modelo/catálogo;
        // em KVCacheSimple trimável (Qwen3), clona o cache base e só faz prefill do sufixo do usuário/rodadas.
        let cached = try await prepareCachedInput(input, tools: tools, thinking: thinking)
        // temperature 0 é argmax; o seed do MLX não altera esses tokens.
        let parameters = GenerateParameters(maxTokens: limit, temperature: 0, seed: seed).legacyPrefill()
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
        var rawText = RawText()
        var text: String {
            get { rawText.value }
            set { rawText.value = newValue }
        }
        var calls = [ToolCall]()
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if captureTiming, result.firstTextMs == nil, !chunk.isEmpty {
                    result.firstTextMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                rawText.chunk(chunk)
            case .info(let info):
                result.inputTokens = (result.inputTokens ?? 0) + fullCount
                result.outputTokens = (result.outputTokens ?? 0) + info.generationTokenCount
                absorb(info, result: &result, role: role, primary: captureTiming)
                if role == .action {
                    switch info.stopReason {
                    case .stop: result.stopReason = "stop"
                    case .length: result.stopReason = "length"
                    case .cancelled: result.stopReason = "cancelled"
                    #if MLX_LM_MAIN
                    case .steered: result.stopReason = "steered"
                    #endif
                    }
                }
            #if MLX_LM_MAIN
            case .reasoning(let piece):
                rawText.reasoning(piece)
            case .rejectedToolCall(let rejected):
                // O 3.31.4 deixava a chamada malformada no texto; `recoverToolCalls` ainda a lê dali.
                rawText.chunk(rejected.rawTextPreview)
            case .steering:
                break
            #endif
            case .toolCall(let call):
                rawText.close()
                calls.append(call)
            }
        }
        let known = (tools ?? []).compactMap(Self.toolName)
        let resolved = calls.isEmpty ? Self.recoverToolCalls(from: text, known: known) : calls
        // Ferramentas abrem outros apps; só executa depois que a GPU terminou, senão o iOS mata o app em background.
        return (text, try await execute(resolved, log: log))
    }

    private func thinkingContext(_ thinking: Bool) -> [String: any Sendable]? {
        if loaded?.thinkingSwitch == true { return ["enable_thinking": thinking] }
        return thinking ? nil : ["enable_thinking": false]
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
                let cache = try context.model.makeCache(parameters: nil)
                let prefixInput = LMInput(tokens: MLXArray(shared))
                _ = try context.model.legacyPrepare(prefixInput, cache: cache, windowSize: 512)
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
        let closer = loaded?.thinkClose == "<channel|>" ? "<channel|>" : Self.closeThink
        let stopMark = loaded?.thinkClose ?? "</think>"
        let input = try await container.prepare(input: UserInput(
            chat: Self.chat(prompt, rounds: rounds, system: true), tools: schemas,
            additionalContext: thinkingContext(true)))
        let head = input.text.tokens.asType(.int32).asArray(Int32.self).map(Int.init)
        var thought = ""
        var used = 0
        while used < budget {
            let step = try await pass(
                head + (await container.encode(thought)), limit: budget - used,
                stop: earlyExit ? [stopMark, "Wait"] : [stopMark], started: started, result: &result)
            thought += step.text
            used += step.tokens
            guard step.stop == "Wait" else { break }
            let sampler = ConfidenceSampler()
            let trial = try await pass(
                head + (await container.encode(thought + closer)), limit: max(512 - used, 1),
                started: started, result: &result, sampler: sampler)
            result.exitChecks = (result.exitChecks ?? 0) + 1
            if !trial.calls.isEmpty, sampler.confidence >= Self.exitConfidence {
                result.exitedEarly = true
                result.thinkingTokens = (result.thinkingTokens ?? 0) + used
                result.response += thought + closer
                return (trial.text, try await execute(trial.calls, log: log))
            }
            thought += "Wait"
        }
        result.thinkingTokens = (result.thinkingTokens ?? 0) + used
        result.response += thought + closer
        let answer = try await pass(
            head + (await container.encode(thought + closer)), limit: max(512 - used, 1),
            started: started, result: &result)
        let resolved = answer.calls.isEmpty
            ? Self.recoverToolCalls(from: answer.text, known: schemas.compactMap(Self.toolName)) : answer.calls
        return (answer.text, try await execute(resolved, log: log))
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
        let cached = serveBudgetPrefix ? serveSlice(fullInput) : try await prepareCachedInput(fullInput, tools: tools, thinking: true)
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
        var rawText = RawText()
        var text: String {
            get { rawText.value }
            set { rawText.value = newValue }
        }
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
                    rawText.chunk(chunk)
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
            #if MLX_LM_MAIN
            case .reasoning(let piece):
                rawText.reasoning(piece)
            case .rejectedToolCall(let rejected):
                // O 3.31.4 deixava a chamada malformada no texto; `recoverToolCalls` ainda a lê dali.
                rawText.chunk(rejected.rawTextPreview)
            case .steering:
                break
            #endif
            case .toolCall(let call):
                rawText.close()
                if !stopped {
                    if result.astFirstCallMs == nil {
                        result.astFirstCallMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    }
                    calls.append(call)
                }
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

    typealias Turn = (text: String, calls: [ToolCall], promptTokens: Int, outputTokens: Int)

    /// Um turno do servidor com as fixas do BFCL AST: mesmos prompts, tetos e decode greedy.
    /// `turns` guarda também o KV até a última mensagem do usuário (ver `serveConversation`).
    /// `guards` só vale em Direct/NoThink (ver `ServeGuards`).
    func serveTurn(
        _ lines: [ChatLine], tools: [ToolSpec], limit: Int, strategy: Strategy, prefix: Bool,
        turns: Bool = false, guards: ServeGuards = ServeGuards()
    ) async throws -> Turn {
        serveReusedTokens = 0
        serveStats = ServeStats()
        switch strategy {
        case .budget64:
            guard let agent = loaded else { throw BenchError.failed("Modelo MLX não carregado.") }
            schemas = tools
            var result = BenchmarkResult(
                device: "", osVersion: "", backend: "mlx", model: agent.rawValue, experiment: "serve",
                strategy: strategy.rawValue, promptCharacters: 0, thermalBefore: "")
            if prefix, let container {
                let full = try await container.prepare(input: UserInput(
                    chat: Self.chat(lines), tools: tools, additionalContext: thinkingContext(true)))
                _ = try await servePrefix(full, lines: lines, tools: tools, thinking: true)
            }
            serveBudgetPrefix = prefix
            defer { serveBudgetPrefix = false }
            let answer = try await astThink(
                agent, chat: Self.chat(lines), tools: tools, budget: 64, limit: limit,
                started: ProcessInfo.processInfo.systemUptime, result: &result)
            let calls = answer.calls.isEmpty
                ? Self.recoverToolCalls(from: answer.text, known: tools.compactMap(Self.toolName)) : answer.calls
            return (result.response + answer.text, calls, result.inputTokens ?? 0, result.outputTokens ?? 0)
        case .planAct:
            // Multi-turno: o pedido do plano e o da ação entram como mensagem nova no fim, com o texto do BFCL.
            let goal = lines.first { $0.role == .user }?.content ?? ""
            let plan = try await chatTurn(
                lines + [.init(role: .user, content: Self.astPlan(goal))], tools: tools,
                limit: BudgetCaps.plan, thinking: false, prefix: prefix) { _ in }
            let answer = try await chatTurn(
                lines + [.init(role: .user, content: Self.astAction(goal, plan: plan.text))], tools: tools,
                limit: limit, thinking: true, prefix: prefix) { _ in }
            return ("[plan] \(plan.text)\n[act] \(answer.text)", answer.calls,
                    plan.promptTokens + answer.promptTokens, plan.outputTokens + answer.outputTokens)
        default:
            return try await chatTurn(
                lines, tools: tools, limit: limit, thinking: strategy == .direct, prefix: prefix, turns: turns,
                guards: guards) { _ in }
        }
    }

    /// Resposta sem o raciocínio. O template abre o thinking no prompt; o texto gerado só traz o fechamento.
    static func visible(_ text: String, agent: Agent?) -> String {
        guard let close = agent?.thinkClose, let end = text.range(of: close, options: .backwards) else {
            return ThinkingFilter.hide(text)
        }
        return ThinkingFilter.hide(String(text[end.upperBound...]))
    }

    /// Um turno do chat sobre o modelo já carregado por `prepare`. Não executa ferramentas: devolve as chamadas.
    func chatTurn(
        _ lines: [ChatLine], tools: [ToolSpec], limit: Int, thinking: Bool = false, prefix: Bool = false,
        turns: Bool = false, guards: ServeGuards = ServeGuards(), onText: (String) -> Void
    ) async throws -> Turn {
        guard let container else { throw BenchError.failed("Modelo MLX não carregado.") }
        await Self.waitForeground()
        let clock = ProcessInfo.processInfo
        let started = clock.systemUptime
        let input = try await container.prepare(input: UserInput(
            chat: Self.chat(lines), tools: tools, additionalContext: thinkingContext(thinking)))
        let promptTokens = input.text.tokens.size
        serveStats.templateMs = (clock.systemUptime - started) * 1000
        let cacheStarted = clock.systemUptime
        let cached = prefix
            ? try await servePrefix(input, lines: lines, tools: tools, thinking: thinking, turns: turns,
                                    persist: guards.persistPrefix)
            : (input: input, cache: nil)
        serveStats.cacheMs = (clock.systemUptime - cacheStarted) * 1000
        serveStats.evalTokens = cached.input.text.tokens.size
        // Budget forcing só no Qwen3.5/MiniCPM/LFM (`</think>` é um token só) e com o thinking ligado.
        var force: (budget: Int, close: Int, closing: [Int])?
        if thinking, let budget = guards.thinkBudget, budget < limit, let close = loaded?.thinkClose, close == "</think>" {
            let ids = await container.encode(close)
            if ids.count == 1 { force = (budget, ids[0], await container.encode(Self.closeThink)) }
        }
        let forcing = force
        let report = ThinkReport()
        let raw = UncheckedBox(value: cached.input)
        let cache = UncheckedBox(value: cached.cache)
        let parameters = GenerateParameters(maxTokens: limit, temperature: 0).legacyPrefill()
        // Rascunho da gramática só no formato XML do Qwen3.5; com thinking, só depois de `</think>`.
        let drafting = guards.grammarDraft ? DraftReport() : nil
        let xml = loaded == .qwen35
        if guards.mtpBlock != nil, mtpDrafter == nil, let loaded {
            mtpDrafter = try await MTPDrafters.load(for: loaded).map { UncheckedBox(value: $0) }
        }
        let mtp = guards.mtpBlock.flatMap { block in mtpDrafter.map { (block, $0) } }
        if guards.mtpBlock != nil, mtp == nil { throw BenchError.failed("mtp_block sem cabeça MTP para \(loaded?.rawValue ?? "?")") }
        #if MLX_LM_MAIN
        if guards.mtpPipe != nil, mtpPipeline == nil, let loaded {
            let url = MTPDrafters.directory(for: loaded).appendingPathComponent("model.safetensors")
            mtpPipeline = try await container.perform { (context: ModelContext) in
                UncheckedBox(value: (try MTPHead.load(url), try TiedVocabulary(model: context.model)))
            }
        }
        let pipeline = guards.mtpPipe.flatMap { _ in mtpPipeline }
        let pipeReport = pipeline == nil ? nil : MTPReport()
        let seed = guards.mtpPipe == "subset"
            ? input.text.tokens.reshaped(-1).asType(.int32).asArray(Int32.self) + (0 ..< Int32(guards.mtpTop ?? 0))
            : nil
        #endif
        let (stream, task) = try await container.perform { (context: ModelContext) in
            // Igual a `MLXLMCommon.generate(input:cache:parameters:context:tools:)`; o cache fica à mão para o budget.
            let kv = try cache.value ?? context.model.makeCache(parameters: parameters)
            #if MLX_LM_MAIN
            if let pipeline, let pipeReport {
                let iterator = try MTPPipelineIterator(
                    input: raw.value, model: context.model, cache: kv, maxTokens: limit, head: pipeline.value.0,
                    vocab: pipeline.value.1, seed: seed, mtpContext: guards.mtpContext ?? 256,
                    gate: Float(guards.mtpGate ?? 0), force: forcing,
                    report: pipeReport)
                return generateTask(
                    promptTokenCount: raw.value.text.tokens.size, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: iterator, tools: tools)
            }
            #endif
            if let (block, drafter) = mtp {
                let speculative = try MTPDrafters.iterator(
                    input: raw.value, model: context.model, drafter: drafter.value, cache: kv,
                    parameters: parameters, blockSize: block)
                guard let force = forcing else {
                    return generateTask(
                        promptTokenCount: raw.value.text.tokens.size, modelConfiguration: context.configuration,
                        tokenizer: context.tokenizer, iterator: speculative, tools: tools)
                }
                let forced = ThinkBudgetIterator(
                    inner: speculative, model: context.model, cache: kv, closeID: force.close, closing: force.closing,
                    budget: force.budget, maxTokens: limit, report: report)
                return generateTask(
                    promptTokenCount: raw.value.text.tokens.size, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: forced, tools: tools)
            }
            if let drafting {
                let grammar = xml
                    ? ToolCallGrammar(tools: tools, tokenizer: context.tokenizer, thinkClose: thinking ? "</think>" : nil)
                    : nil
                let drafted = try GrammarDraftIterator(
                    input: raw.value, model: context.model, cache: kv, maxTokens: limit, grammar: grammar,
                    tokenizer: context.tokenizer, force: forcing, report: drafting)
                return generateTask(
                    promptTokenCount: raw.value.text.tokens.size, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: drafted, tools: tools)
            }
            let iterator = try TokenIterator(input: raw.value, model: context.model, cache: kv, parameters: parameters)
            guard let force = forcing else {
                return generateTask(
                    promptTokenCount: raw.value.text.tokens.size, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: iterator, tools: tools)
            }
            let forced = ThinkBudgetIterator(
                inner: iterator, model: context.model, cache: kv, closeID: force.close, closing: force.closing,
                budget: force.budget, maxTokens: limit, report: report)
            return generateTask(
                promptTokenCount: raw.value.text.tokens.size, modelConfiguration: context.configuration,
                tokenizer: context.tokenizer, iterator: forced, tools: tools)
        }
        var rawText = RawText()
        var text: String {
            get { rawText.value }
            set { rawText.value = newValue }
        }
        var calls = [ToolCall]()
        var outputTokens = 0
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                rawText.chunk(chunk)
                onText(text)
            case .info(let info):
                outputTokens = info.generationTokenCount
                serveStats.evalMs = info.promptTime * 1000
                serveStats.decodeMs = info.generateTime * 1000
                #if MLX_LM_MAIN
                if let proposed = info.proposedDraftTokens {
                    serveStats.mtpProposed = proposed
                    serveStats.mtpAccepted = info.acceptedDraftTokens
                    serveStats.mtpPassthrough = info.passthroughReason
                }
                #endif
            #if MLX_LM_MAIN
            case .reasoning(let piece):
                rawText.reasoning(piece)
            case .rejectedToolCall(let rejected):
                // O 3.31.4 deixava a chamada malformada no texto; `recoverToolCalls` ainda a lê dali.
                rawText.chunk(rejected.rawTextPreview)
            case .steering:
                break
            #endif
            case .toolCall(let call):
                rawText.close()
                // Mesma chamada (nome e argumentos) de novo na mesma resposta: corta o decode e não a repete.
                if guards.repeatGuard, calls.contains(where: {
                    $0.function.name == call.function.name && $0.function.arguments == call.function.arguments
                }) {
                    if !serveStats.repeatCut { serveStats.repeatCut = true; task.cancel() }
                } else if !serveStats.repeatCut {
                    calls.append(call)
                }
            }
        }
        await task.value
        serveStats.forcedClose = drafting?.forced ?? report.forced
        serveStats.thinkTokens = drafting?.thinkTokens ?? report.thinkTokens
        if let drafting { serveStats.draft = drafting.json }
        #if MLX_LM_MAIN
        if let pipeReport {
            serveStats.forcedClose = pipeReport.forced
            serveStats.thinkTokens = pipeReport.thinkTokens
            serveStats.draft = pipeReport.json
            serveStats.mtpProposed = pipeReport.proposed
            serveStats.mtpAccepted = pipeReport.accepted
        }
        #endif
        try Task.checkCancellation()
        // Chamadas que o parser do stream perdeu ficam no texto: o Qwen3.5 SFT emite a 2ª chamada sem `<tool_call>`.
        // Nos 1062 passos do Qwen3.5 base (DEV 2026-11-07) isso nunca aconteceu, então a base não muda.
        let leftover = Self.recoverToolCalls(from: Self.visible(text, agent: loaded), known: tools.compactMap(Self.toolName))
        let resolved = calls + leftover.filter { extra in
            !calls.contains { $0.function.name == extra.function.name && $0.function.arguments == extra.function.arguments }
        }
        return (text, resolved, promptTokens, outputTokens)
    }

    /// System + tools, comum a todos os turnos, pré-preenchido uma vez; cada turno parte de uma cópia.
    /// Cópia em vez de trim: Qwen3.5 e LFM2.5 usam `MambaCache`, que não volta atrás.
    private func servePrefix(
        _ full: LMInput, lines: [ChatLine], tools: [ToolSpec], thinking: Bool, turns: Bool = false,
        persist: Bool = false
    ) async throws -> (input: LMInput, cache: [any KVCache]?) {
        guard let container else { return (full, nil) }
        let head = Array(lines.prefix { $0.role == .system })
        var probes = [[Int32]]()
        for text in ["A", "B"] {
            let probe = try await container.prepare(input: UserInput(
                chat: Self.chat(head + [.init(role: .user, content: text)]), tools: tools,
                additionalContext: thinkingContext(thinking)))
            probes.append(probe.text.tokens.asType(.int32).asArray(Int32.self))
        }
        let shared = zip(probes[0], probes[1]).prefix { $0.0 == $0.1 }.map(\.0)
        let tokens = full.text.tokens.asType(.int32).asArray(Int32.self)
        guard shared.count > 32, tokens.count > shared.count, Array(tokens.prefix(shared.count)) == shared else {
            return (full, nil)
        }
        serveStats.prefixSource = "memory"
        if servePrefixTokens != shared {
            let clock = ProcessInfo.processInfo
            // `model` inclui o adaptador nas variantes SFT: o KV com LoRA não serve para a base.
            let store = loaded.map { PrefixStore(model: $0.model) }
            let built: PrefixBuild = try await container.perform { (context: ModelContext) in
                let layout = PrefixStore.layout(try context.model.makeCache(parameters: nil))
                let loadStarted = clock.systemUptime
                if persist, let restored = store?.load(shared, expected: layout) {
                    return PrefixBuild(value: restored, label: "disk", ms: (clock.systemUptime - loadStarted) * 1000)
                }
                let buildStarted = clock.systemUptime
                let cache = try context.model.makeCache(parameters: nil)
                try Self.fill(context.model, cache, shared)
                return PrefixBuild(value: cache, label: "built", ms: (clock.systemUptime - buildStarted) * 1000)
            }
            serveStats.prefixSource = built.label
            if built.label == "disk" {
                serveStats.prefixLoadMs = built.ms
            } else {
                serveStats.prefixBuildMs = built.ms
                serveStats.prefixBuildTokens = shared.count
                if persist, let store {
                    let saveStarted = clock.systemUptime
                    let snapshot = UncheckedBox(value: built.value)
                    let failure = try await container.perform { (_: ModelContext) in
                        UncheckedBox(value: store.save(shared, cache: snapshot.value))
                    }
                    serveStats.prefixSaveMs = (clock.systemUptime - saveStarted) * 1000
                    serveStats.prefixSaveError = failure.value
                }
            }
            servePrefixCache = built.value
            servePrefixTokens = shared
            serveConvTokens = []
            serveConvCache = []
            serveTurnTokens = []
            serveTurnCache = []
        }
        return try await serveConversation(full, lines: lines, tools: tools, thinking: thinking, turns: turns)
    }

    /// Multi-turno só acrescenta mensagens: o prompt do passo seguinte repete este até o `assistant` da geração.
    /// Guarda o KV até esse ponto estável; no passo seguinte só o trecho novo passa por prefill.
    /// O ponto vem de duas respostas fictícias diferentes e fica antes do prompt de geração, então o mesmo KV
    /// serve Direct e NoThink. Se o template reescrever o histórico, `serveBase` cai no prefixo do system.
    ///
    /// `turns`: o template do Qwen3.5 põe `<think>\n\n</think>` nos assistant depois da última pergunta e tira
    /// quando chega outra; o snapshot da conversa deixa de ser prefixo a cada turno novo. No 1º passo do turno
    /// guarda também o KV até o fim da mensagem do usuário (a "âncora"), que continua prefixo no turno seguinte.
    private func serveConversation(
        _ full: LMInput, lines: [ChatLine], tools: [ToolSpec], thinking: Bool, turns: Bool = false
    ) async throws -> (input: LMInput, cache: [any KVCache]?) {
        guard let container else { return (full, nil) }
        let tokens = full.text.tokens.asType(.int32).asArray(Int32.self)
        guard let base = serveBase(tokens) else { return (full, nil) }
        var probes = [[Int32]]()
        for text in ["A", "B"] {
            let probe = try await container.prepare(input: UserInput(
                chat: Self.chat(lines + [.init(role: .assistant, content: text)]), tools: tools,
                additionalContext: thinkingContext(thinking)))
            probes.append(probe.text.tokens.asType(.int32).asArray(Int32.self))
        }
        let stable = min(
            Self.commonPrefix(probes[0], probes[1]), Self.commonPrefix(probes[0], tokens), tokens.count - 1)
        // Outra mensagem do usuário no lugar da resposta: o comum vai até o `<|im_start|>` do papel seguinte.
        var anchor = 0
        if turns, lines.last?.role == .user {
            let probe = try await container.prepare(input: UserInput(
                chat: Self.chat(lines + [.init(role: .user, content: "A")]), tools: tools,
                additionalContext: thinkingContext(thinking)))
            anchor = min(Self.commonPrefix(probe.text.tokens.asType(.int32).asArray(Int32.self), tokens), stable)
        }
        serveReusedTokens = base.count
        serveStats.reusedFrom = base.source
        guard stable > base.count else {
            return (LMInput(tokens: MLXArray(Array(tokens.dropFirst(base.count)))), base.cache)
        }
        let fillStarted = ProcessInfo.processInfo.systemUptime
        let cut = anchor > base.count ? anchor : base.count
        let head = Array(tokens[base.count..<cut])
        let gap = Array(tokens[cut..<stable])
        let cache = UncheckedBox(value: base.cache)
        let snapshots: UncheckedBox<(turn: [any KVCache]?, conv: [any KVCache])> = try await container.perform {
            (context: ModelContext) in
            var turn: [any KVCache]?
            if !head.isEmpty {
                try Self.fill(context.model, cache.value, head)
                turn = cache.value.map { $0.copy() }
            }
            if !gap.isEmpty { try Self.fill(context.model, cache.value, gap) }
            return UncheckedBox(value: (turn, cache.value.map { $0.copy() }))
        }
        serveStats.fillMs = (ProcessInfo.processInfo.systemUptime - fillStarted) * 1000
        serveStats.fillTokens = stable - base.count
        if let turn = snapshots.value.turn {
            serveTurnTokens = Array(tokens.prefix(cut))
            serveTurnCache = turn
        }
        serveConvTokens = Array(tokens.prefix(stable))
        serveConvCache = snapshots.value.conv
        return (LMInput(tokens: MLXArray(Array(tokens.dropFirst(stable)))), base.cache)
    }

    /// Corta o maior prefixo já pré-preenchido (conversa, senão system); sem prefixo compatível, devolve o prompt inteiro.
    private func serveSlice(_ full: LMInput) -> (input: LMInput, cache: [any KVCache]?) {
        let tokens = full.text.tokens.asType(.int32).asArray(Int32.self)
        guard let base = serveBase(tokens) else { return (full, nil) }
        return (LMInput(tokens: MLXArray(Array(tokens.dropFirst(base.count)))), base.cache)
    }

    /// Cópia do KV do maior prefixo guardado de `tokens`; deixa pelo menos um token para a geração.
    private func serveBase(_ tokens: [Int32]) -> (count: Int, cache: [any KVCache], source: String)? {
        let stored = [("conv", serveConvTokens, serveConvCache), ("turn", serveTurnTokens, serveTurnCache),
                      ("system", servePrefixTokens, servePrefixCache)]
        for (source, prefix, cache) in stored
        where !prefix.isEmpty && tokens.count > prefix.count && tokens.starts(with: prefix) {
            return (prefix.count, cache.map { $0.copy() }, source)
        }
        return nil
    }

    private nonisolated static func commonPrefix(_ a: [Int32], _ b: [Int32]) -> Int {
        zip(a, b).prefix { $0.0 == $0.1 }.count
    }

    /// Pré-preenche `tokens` em `cache` em blocos de 512, como o `TokenIterator`.
    private nonisolated static func fill(_ model: any LanguageModel, _ cache: [any KVCache], _ tokens: [Int32]) throws {
        if case .tokens(let rest) = try model.legacyPrepare(LMInput(tokens: MLXArray(tokens)), cache: cache, windowSize: 512) {
            eval(model(LMInput.Text(tokens: rest.tokens[.newAxis, 0...]), cache: cache, state: nil).logits)
        }
        eval(cache.flatMap { $0.state })
    }

    /// Recupera chamadas quando o modelo não usou o formato estruturado (`<tool_call>…`).
    static func recoverToolCalls(from text: String, known: [String]) -> [ToolCall] {
        let known = Set(known)
        guard !known.isEmpty else { return [] }
        var cleaned = text.replacing(/<think>[\s\S]*?<\/think>/, with: "")
        if let open = cleaned.range(of: "<think>") { cleaned = String(cleaned[..<open.lowerBound]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let xml = parseMiniCPMFunctions(cleaned, known: known)
        if !xml.isEmpty { return xml }
        // Qwen3.5 XML sem `<tool_call>` de abertura: `<function=nome><parameter=x>v</parameter></function>`.
        if cleaned.contains("<function=") {
            let parser = ToolCallFormat.xmlFunction.createParser()
            let blocks = cleaned.components(separatedBy: "<function=").dropFirst().compactMap { block -> String? in
                guard let end = block.range(of: "</function>") else { return nil }
                return "<tool_call>\n<function=\(block[..<end.upperBound])\n</tool_call>"
            }
            let qwen = blocks.flatMap { parser.parseEOS($0, tools: nil) }.filter { known.contains($0.function.name) }
            if !qwen.isEmpty { return qwen }
        }
        let pythonic = parseLFMCalls(cleaned, known: known)
        if !pythonic.isEmpty { return pythonic }

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

    /// MiniCPM5: `<function name="ligar"><param name="numero">+15550100</param></function>`
    static func parseMiniCPMFunctions(_ text: String, known: Set<String>) -> [ToolCall] {
        var calls = [ToolCall]()
        for block in text.components(separatedBy: "<function name=\"").dropFirst() {
            guard let nameEnd = block.firstIndex(of: "\"") else { continue }
            let name = String(block[..<nameEnd])
            guard known.contains(name) else { continue }
            let body = block[nameEnd...].split(separator: "</function>", maxSplits: 1).first.map(String.init) ?? ""
            var arguments: [String: JSONValue] = [:]
            var rest = body[...]
            while let start = rest.range(of: "<param name=\""),
                  let nameClose = rest[start.upperBound...].firstIndex(of: "\"") {
                let key = String(rest[start.upperBound..<nameClose])
                guard let open = rest[nameClose...].range(of: ">"),
                      let close = rest[open.upperBound...].range(of: "</param>") else { break }
                var value = String(rest[open.upperBound..<close.lowerBound])
                if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>") {
                    value = String(value.dropFirst(9).dropLast(3))
                }
                arguments[key] = JSONValue.from(value)
                rest = rest[close.upperBound...]
            }
            calls.append(ToolCall(function: .init(name: name, arguments: arguments), id: UUID().uuidString))
        }
        return calls
    }

    /// LFM2.5: `[ligar(numero="+15550100"), criarEvento(titulo="x", minutos=60)]`
    static func parseLFMCalls(_ text: String, known: Set<String>) -> [ToolCall] {
        var body = text
        if let start = body.range(of: "<|tool_call_start|>") { body = String(body[start.upperBound...]) }
        if let end = body.range(of: "<|tool_call_end|>") { body = String(body[..<end.lowerBound]) }
        guard let open = body.firstIndex(of: "["), let close = body.lastIndex(of: "]") else { return [] }
        body = String(body[body.index(after: open)..<close])
        var calls = [ToolCall]()
        for piece in splitTopLevel(body, by: ",") {
            let item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let paren = item.firstIndex(of: "("), item.hasSuffix(")") else { continue }
            let name = String(item[..<paren]).trimmingCharacters(in: .whitespaces)
            guard known.contains(name) else { continue }
            let argsText = String(item[item.index(after: paren)..<item.index(before: item.endIndex)])
            var arguments: [String: JSONValue] = [:]
            for arg in splitTopLevel(argsText, by: ",") {
                let pair = arg.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let key = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
                var raw = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if raw.count >= 2, (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
                    raw = String(raw.dropFirst().dropLast())
                }
                arguments[key] = JSONValue.from(Int(raw) ?? raw)
            }
            calls.append(ToolCall(function: .init(name: name, arguments: arguments), id: UUID().uuidString))
        }
        return calls
    }

    private static func splitTopLevel(_ text: String, by separator: Character) -> [String] {
        var parts = [String]()
        var current = ""
        var depth = 0
        var quote: Character?
        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; current.append(ch); continue }
            if ch == "(" || ch == "[" { depth += 1; current.append(ch); continue }
            if ch == ")" || ch == "]" { depth = max(0, depth - 1); current.append(ch); continue }
            if ch == separator, depth == 0 {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
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
        case .qwen35SFT, .minicpm5SFT, .xlam2SFT:
            preconditionFailure("SFT carrega por SFTAdapter.configuration (o template vem do adaptador).")
        case .minicpm5, .lfm25, .gemma4, .qwen35, .lfm3:
            // MiniCPM5 declara `llama` e o infer cairia em llama3; o formato nativo
            // `<function name=…><param …>` não tem parser no pacote e é lido do texto no Mac.
            // `.json` só procura `<tool_call>`, então não consome esse texto.
            // LFM2.5 idem: o parser pythonic do pacote pega só a 1ª chamada da lista e não aceita
            // nome com ponto; `[f(a=1), g(b=2)]` é decodificado no Mac com `ast`.
            let format: ToolCallFormat = switch agent {
            case .gemma4: .gemma4
            // LFM3 usa o mesmo XML do Qwen3.5 (`<tool_call>\n<function=…><parameter=…>`).
            case .qwen35, .lfm3: .xmlFunction
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
