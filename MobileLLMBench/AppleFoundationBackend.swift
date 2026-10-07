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

    static func run(_ task: PhoneTask, strategy: Strategy, result: inout BenchmarkResult) async throws {
        if let reason = unavailableReason { throw BenchError.failed(reason) }
        let started = ProcessInfo.processInfo.systemUptime
        let log = ToolLog()
        let tools = makeTools(log: log)
        result.toolCallingMode = "prompt_requested"
        let instructions = "Cumpra o pedido chamando exatamente uma ferramenta. Copie os dados do pedido para os argumentos. Não afirme que a ação foi feita sem chamar a ferramenta."

        do {
            if strategy == .planAct {
                let planSession = LanguageModelSession(model: .default)
                result.plan = try await generate(
                    planSession,
                    prompt: "\(task.prompt)\n\nEscreva um plano curto, no máximo 5 linhas, para responder. Não chame ferramentas ainda.",
                    limit: 128,
                    started: started,
                    result: &result,
                    captureTiming: false
                )
            }
            let session = LanguageModelSession(model: .default, tools: tools) { instructions }
            let prompt = result.plan.map { "\(task.prompt)\n\nPlano:\n\($0)\n\nExecute o pedido chamando uma ferramenta." } ?? task.prompt
            result.response = try await generate(
                session, prompt: prompt, limit: 256, started: started, result: &result, captureTiming: true
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
        if result.error == nil, marks.isEmpty {
            result.error = "Nenhuma ferramenta foi chamada."
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
