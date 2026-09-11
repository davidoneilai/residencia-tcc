import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

@MainActor
final class MLXBackend {
    static let configuration = LLMRegistry.gemma3_1B_qat_4bit
    private var container: ModelContainer?

    func run(prompt: String, result: inout BenchmarkResult, status: (String) -> Void) async throws {
        if container == nil {
            status("Loading model... (o primeiro carregamento inclui download)")
            let started = ProcessInfo.processInfo.systemUptime
            container = try await #huggingFaceLoadModelContainer(configuration: Self.configuration)
            result.modelLoadMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        }
        guard let container else { throw BenchError.failed("Container MLX indisponível.") }
        status("Generating with MLX...")
        let started = ProcessInfo.processInfo.systemUptime
        // Official LLMEval prepare/generate path; no custom tokenizer or inference.
        let input = try await container.prepare(input: UserInput(chat: [.user(prompt)]))
        result.inputTokens = input.text.tokens.size
        let stream = try await container.generate(
            input: input, parameters: GenerateParameters(maxTokens: 128, temperature: 0)
        )
        var completed = false
        for await generation in stream {
            switch generation {
            case .chunk(let text):
                if result.firstTextMs == nil, !text.isEmpty {
                    result.firstTextMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                result.response += text // MLX chunks are deltas.
            case .info(let info):
                completed = true
                result.inputTokens = info.promptTokenCount
                result.outputTokens = info.generationTokenCount
                // Library timing: prefill + first token; excludes tokenization/loading.
                if info.generationTokenCount > 0, info.promptTime.isFinite, info.promptTime > 0 {
                    result.ttftMs = info.promptTime * 1000
                }
                if info.promptTime > 0, info.promptTokensPerSecond.isFinite {
                    result.prefillTokensPerSecond = info.promptTokensPerSecond
                }
                if info.generateTime > 0, info.tokensPerSecond.isFinite {
                    result.decodeTokensPerSecond = info.tokensPerSecond
                }
                switch info.stopReason {
                case .stop: result.stopReason = "stop"
                case .length: result.stopReason = "length"
                case .cancelled: result.stopReason = "cancelled"
                }
            case .toolCall:
                result.error = "Tool call inesperado no baseline MLX."
            }
        }
        if let error = result.error { throw BenchError.failed(error) }
        guard completed, result.stopReason != "cancelled", !Task.isCancelled else {
            throw BenchError.failed("A geração MLX terminou sem conclusão válida.")
        }
        guard !result.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BenchError.failed("O modelo MLX retornou uma resposta vazia.")
        }
    }
}
