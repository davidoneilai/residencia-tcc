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

    static func run(_ experiment: Experiment, result: inout BenchmarkResult) async throws {
        if let reason = unavailableReason { throw BenchError.failed(reason) }
        let started = ProcessInfo.processInfo.systemUptime
        let tool = AddNumbersTool()
        let session: LanguageModelSession
        if experiment == .appleTool {
            if #available(iOS 27.0, *) {
                session = LanguageModelSession(profile: AdditionProfile(tool: tool))
                result.toolCallingMode = "required_then_disallowed"
            } else {
                session = LanguageModelSession(model: .default, tools: [tool]) {
                    "Chame addNumbers com os dois números pedidos. Depois responda somente com o número retornado."
                }
                result.toolCallingMode = "prompt_requested"
            }
        } else {
            session = LanguageModelSession(model: .default)
        }
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 128)
        // Keep partial response and tool evidence even if streaming throws.
        do {
            for try await snapshot in session.streamResponse(to: Prompt { experiment.prompt }, options: options) {
                if result.firstTextMs == nil, !snapshot.content.isEmpty {
                    result.firstTextMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                result.response = snapshot.content // Apple snapshots are cumulative.
            }
        } catch {
            result.error = error.localizedDescription
        }
        if #available(iOS 27.0, *) {
            result.inputTokens = session.usage.input.totalTokenCount
            result.outputTokens = session.usage.output.totalTokenCount
        }
        if experiment == .appleTool {
            let calls = await tool.calls
            result.toolCallCount = calls.count
            result.toolExecutionMs = calls.isEmpty ? nil : calls.reduce(0) { $0 + $1.ms }
            result.toolTrace = calls.map { "\($0.a) + \($0.b) = \($0.sum)" }
            let correctCall = calls.contains {
                (($0.a == 137 && $0.b == 284) || ($0.a == 284 && $0.b == 137)) && $0.sum == 421
            }
            if result.error == nil,
                !correctCall || result.response.trimmingCharacters(in: .whitespacesAndNewlines) != "421" {
                result.error = "Tool test falhou: é necessária uma chamada real com 137 e 284 e resposta final 421."
            }
        }
        if let error = result.error { throw BenchError.failed(error) }
        guard !result.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BenchError.failed("O modelo Apple retornou uma resposta vazia.")
        }
    }
}
