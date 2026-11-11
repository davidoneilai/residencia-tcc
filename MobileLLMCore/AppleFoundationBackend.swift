import Foundation
import FoundationModels

@MainActor
enum AppleFoundationBackend {
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "Este dispositivo não suporta Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Ative Apple Intelligence nos Ajustes."
        case .unavailable(.modelNotReady): "O modelo Apple ainda não está pronto; aguarde o download do sistema."
        case .unavailable(let reason): "Modelo Apple indisponível: \(reason)."
        @unknown default: "Disponibilidade do modelo Apple desconhecida."
        }
    }

    static func run(
        prompt: String,
        strategy: Strategy,
        mode: ExecutionMode = .real,
        fixtures: SimFixtures = .standard,
        result: inout BenchmarkResult
    ) async throws {
        if let reason = unavailableReason { throw BenchError.failed(reason) }
        let started = ProcessInfo.processInfo.systemUptime
        let log = ToolLog()
        let tools = makeTools(log: log, world: ToolWorld(fixtures: fixtures, mode: mode))
        result.toolCallingMode = "prompt_requested"

        do {
            if strategy == .planAct {
                let planSession = LanguageModelSession(model: .default)
                let planStarted = ProcessInfo.processInfo.systemUptime
                result.plan = try await generate(
                    planSession,
                    prompt: PhonePrompt.plan(prompt),
                    limit: 128,
                    started: started,
                    result: &result,
                    captureTiming: false
                )
                result.planLatencyMs = (ProcessInfo.processInfo.systemUptime - planStarted) * 1000
            }
            let session = LanguageModelSession(model: .default, tools: tools) { PhonePrompt.instructions }
            let action = result.plan.map { PhonePrompt.action(prompt, plan: $0) } ?? prompt
            result.response = try await generate(
                session, prompt: action, limit: 512, started: started, result: &result, captureTiming: true
            )
            if #available(iOS 27.0, *) {
                result.inputTokens = session.usage.input.totalTokenCount
                result.outputTokens = session.usage.output.totalTokenCount
            }
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

    private static func generate(
        _ session: LanguageModelSession,
        prompt: String,
        limit: Int,
        started: TimeInterval,
        result: inout BenchmarkResult,
        captureTiming: Bool
    ) async throws -> String {
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: limit)
        var text = ""
        for try await snapshot in session.streamResponse(to: Prompt { prompt }, options: options) {
            if captureTiming, result.firstTextMs == nil, !snapshot.content.isEmpty {
                result.firstTextMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            }
            text = snapshot.content
        }
        return text
    }
}
