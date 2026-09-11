import Foundation
import FoundationModels

// Tool permits concurrent calls; the actor protects only the small execution trace.
actor AddNumbersTool: Tool {
    nonisolated let name = "addNumbers"
    nonisolated let description = "Soma dois números inteiros e retorna o resultado exato."
    private(set) var calls: [(a: Int, b: Int, sum: Int, ms: Double)] = []

    @Generable
    struct Arguments {
        @Guide(description: "Primeiro inteiro", .range(-1_000_000...1_000_000))
        var a: Int
        @Guide(description: "Segundo inteiro", .range(-1_000_000...1_000_000))
        var b: Int
    }

    func call(arguments: Arguments) async throws -> String {
        guard calls.count < 4 else { throw BenchError.failed("Limite de chamadas da tool excedido.") }
        let started = ProcessInfo.processInfo.systemUptime
        let (sum, overflow) = arguments.a.addingReportingOverflow(arguments.b)
        guard !overflow else { throw BenchError.failed("Overflow na soma.") }
        let output = String(sum)
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        calls.append((arguments.a, arguments.b, sum, ms))
        return output
    }
}

@available(iOS 27.0, *)
extension SessionPropertyValues {
    @SessionPropertyEntry var additionCallCount: Int = 0
}

@available(iOS 27.0, *)
struct AdditionProfile: LanguageModelSession.DynamicProfile {
    let tool: AddNumbersTool
    @SessionProperty(\.additionCallCount) var callCount

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions("Some os números com addNumbers. Depois responda somente com o número retornado.")
            tool
        }
        .model(SystemLanguageModel.default)
        // Required without a transition can call tools indefinitely (Apple docs).
        .toolCallingMode(callCount == 0 ? .required : .disallowed)
        .onToolCall { callCount += 1 }
    }
}
