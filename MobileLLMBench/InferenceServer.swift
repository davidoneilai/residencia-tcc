import Foundation
import MLX
import MLXLMCommon
import Network
import Observation
import os
import UIKit

/// Endpoint OpenAI-compatível (`POST /v1/chat/completions`) sobre o MLX do iPhone.
/// O harness do benchmark público roda no Mac e executa as tools dele; aqui só gera a resposta.
/// Ativa com `{"run":"serve","port":8080}`. Mac: `iproxy 8080 8080 -u <UDID>` ou o IP do Wi-Fi.
@MainActor @Observable
final class InferenceServer {
    static let maxTokens = 1024

    private let mlx: MLXPhoneBackend
    private var listener: NWListener?
    private var queue: Task<Void, Never>?
    private(set) var status = "parado"
    private(set) var served = 0
    /// Enviado pelo runner do Mac (`POST /v1/progress`); a tela Ao vivo mostra.
    private(set) var progress: ServeProgress?
    private(set) var lastTurn: String?
    private(set) var generatingSince: Date?

    init(mlx: MLXPhoneBackend) {
        ServeRequest.selfCheck()
        GrammarDraftIterator.selfCheck()
        self.mlx = mlx
    }

    func start(port: UInt16) {
        let listener: NWListener
        do { listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) } catch {
            status = "falhou: \(error)"
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        UIApplication.shared.isIdleTimerDisabled = true
        status = "ouvindo :\(port)"
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        Self.receive(connection, buffer: Data()) { [weak self] request in
            Task { @MainActor in self?.enqueue(request, on: connection) }
        }
    }

    /// Uma geração por vez na GPU; requisições concorrentes esperam na fila.
    private func enqueue(_ request: HTTPRequest?, on connection: NWConnection) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            let (code, body) = await self.handle(request)
            Self.send(connection, code: code, body: body)
        }
    }

    private func handle(_ request: HTTPRequest?) async -> (Int, Data) {
        guard let request else { return Self.error(400, "requisição HTTP inválida") }
        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            // O runner do Mac espera a térmica baixar antes de cada execução (ver analysis/bfcl_mt/run_dac.sh).
            return (200, Data("{\"status\":\"ok\",\"thermal\":\"\(DeviceMetrics.thermal)\"}".utf8))
        case ("GET", "/v1/models"):
            let data = Agent.studyModels.map { ["id": $0.rawValue, "object": "model", "owned_by": "iphone"] }
            return (200, try! JSONSerialization.data(withJSONObject: ["object": "list", "data": data]))
        case ("POST", "/v1/progress"):
            guard var value = try? JSONDecoder().decode(ServeProgress.self, from: request.body) else {
                return Self.error(400, "progresso inválido")
            }
            value.received = Date()
            progress = value
            return (200, Data("{\"status\":\"ok\"}".utf8))
        case ("POST", "/v1/debug/reset"):
            // Medição cold/warm: esquece os KV em memória; `{"disk": true}` apaga também o prefixo persistido,
            // `{"keep_system": true}` mantém só o system + tools (A/B do decode sobre o mesmo prefill).
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let files = mlx.resetServeCaches(
                disk: body["disk"] as? Bool ?? false, keepSystem: body["keep_system"] as? Bool ?? false)
            return (200, try! JSONSerialization.data(withJSONObject: ["status": "ok", "prefix_files": files]))
        case ("POST", "/v1/debug/forward"):
            // Custo de uma passada com T tokens (rascunho): `{"sizes": [1, 2, 4, 8], "reps": 5}`.
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            do {
                let rows = try await mlx.benchForward(sizes: body["sizes"] as? [Int] ?? [1, 2, 4, 8], reps: body["reps"] as? Int ?? 5)
                return (200, try! JSONSerialization.data(withJSONObject: ["rows": rows, "thermal": DeviceMetrics.thermal]))
            } catch {
                return Self.error(400, error.localizedDescription)
            }
        case ("POST", "/v1/debug/mtp"):
            // Diagnóstico da cabeça MTP (`MLXPhoneBackend.benchMTP`): corpo igual ao do chat, só no build `MLX_LM_MAIN`.
            #if MLX_LM_MAIN
            do {
                let parsed = try ServeRequest(request.body)
                _ = try await mlx.prepare(parsed.agent) { _ in }
                let row = try await mlx.benchMTP(parsed.lines, tools: parsed.tools, limit: parsed.maxTokens ?? 256,
                                                 thinking: parsed.strategy == .direct)
                return (200, try! JSONSerialization.data(withJSONObject: ["result": row, "thermal": DeviceMetrics.thermal]))
            } catch let error as ServeError {
                return Self.error(400, error.message)
            } catch {
                return Self.error(500, error.localizedDescription)
            }
            #else
            return Self.error(404, "/v1/debug/mtp só no build MLX_LM_MAIN")
            #endif
        case ("POST", "/v1/chat/completions"):
            do { return (200, try await complete(request.body)) } catch let error as ServeError {
                return Self.error(400, error.message)
            } catch {
                return Self.error(500, error.localizedDescription)
            }
        default:
            return Self.error(404, "rota desconhecida: \(request.method) \(request.path)")
        }
    }

    private func complete(_ body: Data) async throws -> Data {
        let parsed = try ServeRequest(body)
        status = "gerando \(parsed.agent.rawValue) \(parsed.strategy.rawValue)"
        generatingSince = Date()
        defer {
            served += 1
            status = "ouvindo"
            generatingSince = nil
        }
        let loadMs = try await mlx.prepare(parsed.agent) { _ in }
        GPU.resetPeakMemory()
        let thermalBefore = DeviceMetrics.thermal
        let started = ProcessInfo.processInfo.systemUptime
        let limit = min(parsed.maxTokens ?? Self.maxTokens, Self.maxTokens)
        Self.log(["time": ISO8601DateFormatter().string(from: Date()),
                  "request": try JSONSerialization.jsonObject(with: body)], to: "serve-requests.jsonl")
        let turn = try await mlx.serveTurn(
            parsed.lines, tools: parsed.tools, limit: limit, strategy: parsed.strategy, prefix: parsed.prefix,
            turns: parsed.turns, guards: parsed.guards)
        Memory.clearCache()
        let latencyMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let peakMB = Double(Memory.peakMemory) / 1_048_576

        let finish = !turn.calls.isEmpty ? "tool_calls" : turn.outputTokens >= limit ? "length" : "stop"
        var message: [String: Any] = [
            "role": "assistant",
            "content": turn.calls.isEmpty ? MLXPhoneBackend.visible(turn.text, agent: parsed.agent) : "",
        ]
        if !turn.calls.isEmpty {
            message["tool_calls"] = try turn.calls.map { call in
                [
                    "id": call.id ?? UUID().uuidString,
                    "type": "function",
                    "function": [
                        "name": call.function.name,
                        "arguments": String(decoding: try JSONEncoder().encode(call.function.arguments), as: UTF8.self),
                    ],
                ] as [String: Any]
            }
        }
        var device: [String: Any] = [
            "model": parsed.agent.hubID,
            "adapter": parsed.agent.sft.map { "\($0.adapterID)@\($0.adapterRevision)" } ?? "",
            "strategy": parsed.strategy.rawValue,
            "prefix_cache": parsed.prefix,
            "cache_mode": parsed.turns ? "kv" : parsed.prefix ? "prefix" : "off",
            "think_budget": parsed.guards.thinkBudget ?? 0,
            "repeat_guard": parsed.guards.repeatGuard,
            "persist_prefix": parsed.guards.persistPrefix,
            "grammar_draft": parsed.guards.grammarDraft,
            "mtp_block": parsed.guards.mtpBlock ?? 0,
            "mtp_pipe": parsed.guards.mtpPipe ?? "",
            "mtp_context": parsed.guards.mtpContext ?? 0,
            "mtp_top": parsed.guards.mtpTop ?? 0,
            "mtp_gate": parsed.guards.mtpGate ?? 0,
            "thermal_before": thermalBefore,
            "thermal_after": DeviceMetrics.thermal,
            "reused_prompt_tokens": mlx.serveReusedTokens,
            "latency_ms": latencyMs,
            "model_load_ms": loadMs ?? 0,
            "peak_memory_mb": peakMB,
            "available_memory_mb": Double(os_proc_available_memory()) / 1_048_576,
            "max_tokens": limit,
            // Texto gerado inteiro (raciocínio + resposta): análise offline do decode. Só registro, não muda a geração.
            "raw_text": turn.text,
        ]
        device.merge(mlx.serveStats.json) { a, _ in a }
        // Só no caminho chatTurn (Direct/NoThink); budget_64 e plan_act não preenchem a decomposição.
        let stats = mlx.serveStats
        device["ttft_ms"] = stats.templateMs + stats.cacheMs + stats.evalMs
        let response: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": parsed.model,
            "choices": [["index": 0, "message": message, "finish_reason": finish]],
            "usage": [
                "prompt_tokens": turn.promptTokens,
                "completion_tokens": turn.outputTokens,
                "total_tokens": turn.promptTokens + turn.outputTokens,
            ],
            "device": device,
        ]
        lastTurn = "\(parsed.agent.rawValue) \(parsed.strategy.rawValue) · \(Int(latencyMs / 1000)) s · "
            + "prompt \(turn.promptTokens) (\(mlx.serveReusedTokens) reusados) · saída \(turn.outputTokens) · \(finish)"
        Self.log(device.merging([
            "time": ISO8601DateFormatter().string(from: Date()),
            "prompt_tokens": turn.promptTokens, "completion_tokens": turn.outputTokens,
            "finish_reason": finish, "tool_calls": turn.calls.map(\.function.name),
        ]) { a, _ in a }, to: "serve-log.jsonl")
        return try JSONSerialization.data(withJSONObject: response)
    }

    /// Uma linha por requisição em `Documents/`: métricas em `serve-log.jsonl`, corpo cru em
    /// `serve-requests.jsonl` (replay de prefix cache e speculative sobre os mesmos turnos).
    private static func log(_ row: [String: Any], to file: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(file)
        guard var line = try? JSONSerialization.data(withJSONObject: row) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private static func error(_ code: Int, _ message: String) -> (Int, Data) {
        (code, try! JSONSerialization.data(withJSONObject: ["error": ["message": message, "code": code]]))
    }

    // MARK: HTTP/1.1 mínimo: uma requisição por conexão, corpo por Content-Length.

    struct HTTPRequest {
        var method: String
        var path: String
        var body: Data
    }

    nonisolated static func parse(_ data: Data) -> (request: HTTPRequest?, complete: Bool) {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return (nil, false) }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return (nil, true) }
        let length = head.dropFirst().compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[split.upperBound...]
        guard body.count >= length else { return (nil, false) }
        let path = String(parts[1].split(separator: "?").first ?? "")
        return (HTTPRequest(method: String(parts[0]), path: path, body: Data(body.prefix(length))), true)
    }

    private nonisolated static func receive(
        _ connection: NWConnection, buffer: Data, done: @escaping @Sendable (HTTPRequest?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { chunk, _, isComplete, error in
            var data = buffer
            if let chunk { data.append(chunk) }
            let parsed = parse(data)
            if parsed.complete || isComplete || error != nil {
                done(parsed.request)
            } else {
                receive(connection, buffer: data, done: done)
            }
        }
    }

    private nonisolated static func send(_ connection: NWConnection, code: Int, body: Data) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][code] ?? "Internal Server Error"
        var data = Data("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Progresso do bench do Mac (`analysis/runtime/run_eval.py`). Só `done`/`total`/`label` são obrigatórios.
struct ServeProgress: Decodable, Equatable {
    var done: Int
    var total: Int
    var label: String
    /// `rodando`, `esfriando`, `terminou` ou `falhou`.
    var state: String?
    var round: String?
    var task: String?
    var condition: String?
    /// Segundos já esperados pela térmica nesta execução.
    var cooledSeconds: Int?
    /// Estimativa do Mac para o fim, em segundos.
    var etaSeconds: Int?
    var failures: Int?
    /// Preenchido ao receber, não vem do Mac.
    var received: Date?

    enum CodingKeys: String, CodingKey {
        case done, total, label, state, round, task, condition, failures
        case cooledSeconds = "cooled_s", etaSeconds = "eta_s"
    }
}

struct ServeError: Error {
    var message: String
}

/// Tradução do corpo OpenAI Chat Completions para o `chatTurn` do MLX.
struct ServeRequest {
    static let strategies: [Strategy] = [.direct, .noThink, .budget64, .planAct]

    var model: String
    var agent: Agent
    var strategy: Strategy
    var prefix: Bool
    /// `:kv` = prefix cache + âncora por turno (ver `MLXPhoneBackend.serveConversation`).
    var turns: Bool
    var guards = ServeGuards()
    var lines: [MLXPhoneBackend.ChatLine]
    var tools: [ToolSpec]
    var maxTokens: Int?

    /// `model` = `<slm>:<estratégia>[:prefix|:kv]`. Sem padrão: a estratégia de cada turno tem de ser explícita.
    /// Prefix cache (system + tools pré-preenchidos) só muda o tempo, em qualquer estratégia.
    /// Extensões do corpo (DAC): `think_budget` (int) e `repeat_guard` (bool), ver `ServeGuards`.
    /// Runtime: `persist_prefix` (bool, `PrefixStore`), `grammar_draft` (bool, `GrammarDraftIterator`) e
    /// `mtp_block` (int ≥ 2, especulação MTP; só no build `MLX_LM_MAIN`).
    init(_ body: Data) throws {
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: body) else {
            throw ServeError(message: "corpo JSON precisa ser um objeto")
        }
        let usage = "model precisa ser <slm>:<\(Self.strategies.map(\.rawValue).joined(separator: "|"))>[:prefix|:kv], "
            + "slm em: \(Agent.studyModels.map(\.rawValue).joined(separator: ", "))"
        guard case .string(let model) = root["model"] else { throw ServeError(message: usage) }
        let parts = model.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count), let agent = Agent(rawValue: parts[0]), Agent.studyModels.contains(agent),
              let strategy = Strategy(rawValue: parts[1]), Self.strategies.contains(strategy),
              parts.count == 2 || ["prefix", "kv"].contains(parts[2]) else {
            throw ServeError(message: usage)
        }
        guard strategy.supports(agent) else {
            throw ServeError(message: "\(strategy.rawValue) não se aplica a \(agent.rawValue)")
        }
        guard case .array(let messages) = root["messages"], !messages.isEmpty else {
            throw ServeError(message: "messages vazio")
        }
        self.model = model
        self.agent = agent
        self.strategy = strategy
        prefix = parts.count == 3
        turns = parts.count == 3 && parts[2] == "kv"
        if case .int(let budget) = root["think_budget"], budget > 0 { guards.thinkBudget = budget }
        if case .bool(let flag) = root["repeat_guard"] { guards.repeatGuard = flag }
        if case .bool(let flag) = root["persist_prefix"] { guards.persistPrefix = flag }
        if case .bool(let flag) = root["grammar_draft"] { guards.grammarDraft = flag }
        if case .int(let block) = root["mtp_block"], block >= 2 { guards.mtpBlock = block }
        if case .string(let pipe) = root["mtp_pipe"] {
            guard ["full", "subset"].contains(pipe) else { throw ServeError(message: "mtp_pipe: full ou subset") }
            guards.mtpPipe = pipe
        }
        if case .int(let context) = root["mtp_context"], context > 0 { guards.mtpContext = context }
        if case .int(let top) = root["mtp_top"], top > 0 { guards.mtpTop = top }
        if case .double(let gate) = root["mtp_gate"] { guards.mtpGate = gate }
        lines = Self.compact(try messages.map(Self.line))
        if case .array(let tools) = root["tools"] {
            self.tools = tools.compactMap { Self.sendable($0) as? ToolSpec }
        } else {
            tools = []
        }
        for key in ["max_tokens", "max_completion_tokens"] {
            if case .int(let value) = root[key] { maxTokens = value }
        }
    }

    private static func line(_ value: JSONValue) throws -> MLXPhoneBackend.ChatLine {
        guard case .object(let message) = value, case .string(let role) = message["role"] else {
            throw ServeError(message: "mensagem sem role")
        }
        let content = text(message["content"])
        switch role {
        case "system", "developer":
            return .init(role: .system, content: content)
        case "user":
            return .init(role: .user, content: content)
        case "assistant":
            var calls = [ToolCall]()
            if case .array(let raw) = message["tool_calls"] {
                calls = raw.compactMap(toolCall)
            }
            return .init(role: .assistant, content: content, calls: calls)
        case "tool":
            guard case .string(let id) = message["tool_call_id"] else {
                throw ServeError(message: "mensagem tool sem tool_call_id")
            }
            return .init(role: .tool, content: content, callID: id)
        default:
            throw ServeError(message: "role desconhecido: \(role)")
        }
    }

    /// XML de observe() estoura o SLM: guarda 2 resultados recentes, o resto vira 400 caracteres.
    static func compact(_ lines: [MLXPhoneBackend.ChatLine]) -> [MLXPhoneBackend.ChatLine] {
        let recent = Set(lines.indices.filter { lines[$0].role == .tool }.suffix(2))
        return lines.enumerated().map { index, line in
            guard line.role == .tool else { return line }
            let cap = recent.contains(index) ? 2000 : 400
            guard line.content.count > cap else { return line }
            var copy = line
            copy.content = String(line.content.prefix(cap)) + " …[truncated]"
            return copy
        }
    }

    /// Conteúdo string ou lista de partes; partes de imagem são descartadas (modelos só de texto).
    private static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text): return text
        case .array(let parts):
            return parts.compactMap { part -> String? in
                guard case .object(let object) = part, case .string(let text) = object["text"] else { return nil }
                return text
            }.joined(separator: "\n")
        default: return ""
        }
    }

    private static func toolCall(_ value: JSONValue) -> ToolCall? {
        guard case .object(let call) = value, case .object(let function) = call["function"],
              case .string(let name) = function["name"] else { return nil }
        var arguments = [String: JSONValue]()
        switch function["arguments"] {
        case .string(let raw):
            if let data = raw.data(using: .utf8),
               case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data) {
                arguments = object
            }
        case .object(let object): arguments = object
        default: break
        }
        let id: String = if case .string(let id) = call["id"] { id } else { UUID().uuidString }
        return ToolCall(function: .init(name: name, arguments: arguments), id: id)
    }

    /// `JSONValue` → valores que o template Jinja aceita; `null` some.
    static func sendable(_ value: JSONValue) -> (any Sendable)? {
        switch value {
        case .null: nil
        case .bool(let flag): flag
        case .int(let number): number
        case .double(let number): number
        case .string(let text): text
        case .array(let values): values.compactMap(sendable)
        case .object(let object): object.compactMapValues(sendable) as [String: any Sendable]
        }
    }

    @MainActor static func selfCheck() {
        let body = Data("""
        {"model":"qwen35:direct","max_tokens":64,"messages":[
          {"role":"user","content":[{"type":"text","text":"oi"}]},
          {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function",
            "function":{"name":"mcp__clock__create_alarm","arguments":"{\\"hour\\":6,\\"label\\":\\"Gym\\"}"}}]},
          {"role":"tool","tool_call_id":"c1","content":"ok"}],
         "tools":[{"type":"function","function":{"name":"mcp__clock__create_alarm",
           "parameters":{"type":"object","properties":{"hour":{"type":"integer","minimum":1}},"required":["hour"]}}}]}
        """.utf8)
        let request = try! ServeRequest(body)
        precondition(request.agent == .qwen35 && request.strategy == .direct && request.maxTokens == 64)
        func rejects(_ model: String) -> Bool {
            (try? ServeRequest(Data(#"{"model":"\#(model)","messages":[{"role":"user","content":"x"}]}"#.utf8))) == nil
        }
        precondition(rejects("qwen35") && rejects("lfm25:nothink") && rejects("qwen35:ast_router")
            && rejects("qwen35:direct:x"))
        precondition(!rejects("lfm25:direct") && !rejects("lfm25:budget_64") && !rejects("gemma4:plan_act")
            && !rejects("minicpm5:nothink:prefix") && !rejects("qwen35:budget_64:prefix")
            && !rejects("gemma4:plan_act:prefix") && !rejects("qwen35:direct:kv"))
        let guarded = try! ServeRequest(Data(
            #"{"model":"qwen35:direct:kv","think_budget":512,"repeat_guard":true,"messages":[{"role":"user","content":"x"}]}"#.utf8))
        precondition(guarded.turns && guarded.prefix && guarded.guards.thinkBudget == 512 && guarded.guards.repeatGuard)
        precondition(!request.turns && !request.prefix && request.guards.thinkBudget == nil)
        precondition(MLXPhoneBackend.visible("plan\n</think>\n\nok", agent: .qwen35) == "ok")
        precondition(MLXPhoneBackend.visible("<think>x</think>ok", agent: .qwen35) == "ok")
        precondition(MLXPhoneBackend.visible("thought<channel|>ok", agent: .gemma4) == "ok")
        precondition(request.lines.map(\.content) == ["oi", "", "ok"] && request.lines[2].callID == "c1")
        precondition(request.lines[1].calls.first?.function.arguments == ["hour": .int(6), "label": .string("Gym")])
        let function = request.tools.first?["function"] as? [String: any Sendable]
        let hour = ((function?["parameters"] as? [String: any Sendable])?["properties"] as? [String: any Sendable])?["hour"]
        precondition((hour as? [String: any Sendable])?["minimum"] as? Int == 1)

        let minicpm = MLXPhoneBackend.recoverToolCalls(
            from: "<function name=\"mcp__clock__create_alarm\"><param name=\"time\">06:45</param></function>",
            known: ["mcp__clock__create_alarm"])
        precondition(minicpm.first?.function.arguments == ["time": .string("06:45")])
        let long = String(repeating: "x", count: 3000)
        let compacted = compact([
            .init(role: .tool, content: long, callID: "a"),
            .init(role: .tool, content: long, callID: "b"),
            .init(role: .tool, content: long, callID: "c"),
        ])
        precondition(compacted[0].content.count == 400 + 13 && compacted[2].content.count == 2000 + 13)

        let raw = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8)
        precondition(!InferenceServer.parse(raw).complete)
        let full = InferenceServer.parse(raw + Data("cd".utf8))
        precondition(full.complete && full.request?.body == Data("abcd".utf8) && full.request?.path == "/v1/chat/completions")
    }
}
