import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class BenchmarkRunner {
    private(set) var running = false
    private(set) var results: [BenchmarkResult] = []
    private(set) var log = "Pronto. Cada botão executa uma vez."
    private(set) var exportURL: URL?
    private let mlx = MLXBackend()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let reason = AppleFoundationBackend.unavailableReason { log += "\nApple: \(reason)" }
    }

    func run(_ experiments: [Experiment]) async {
        guard !running else { return }
        running = true
        exportURL = nil
        log = ""
        defer { running = false }
        for experiment in experiments {
            let isMLX = experiment == .mlxBaseline
            log += "\nExecutando \(experiment.rawValue)...\n"
            var result = BenchmarkResult(
                device: DeviceMetrics.device,
                osVersion: DeviceMetrics.osVersion,
                backend: isMLX ? "mlx" : "apple_foundation_models",
                model: isMLX ? MLXBackend.configuration.name : "SystemLanguageModel.default",
                experiment: experiment.rawValue,
                promptCharacters: experiment.prompt.count,
                memoryBeforeMB: DeviceMetrics.memoryMB,
                thermalBefore: DeviceMetrics.thermal,
                batteryBefore: DeviceMetrics.battery
            )
            let started = ProcessInfo.processInfo.systemUptime
            do {
                if isMLX {
                    try await mlx.run(prompt: experiment.prompt, result: &result) { self.log += "\($0)\n" }
                } else {
                    try await AppleFoundationBackend.run(experiment, result: &result)
                }
                result.success = true
            } catch {
                result.error = error.localizedDescription
            }
            result.totalMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            result.memoryAfterMB = DeviceMetrics.memoryMB
            result.thermalAfter = DeviceMetrics.thermal
            result.batteryAfter = DeviceMetrics.battery
            results.append(result)
            log += summary(result) + "\n"
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-results.json")
            try encoder.encode(results).write(to: url, options: .atomic)
            exportURL = url
        } catch {
            log += "Erro ao preparar JSON: \(error.localizedDescription). Resultados preservados em memória.\n"
        }
    }

    private func summary(_ r: BenchmarkResult) -> String {
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "null"
        }
        return """
        Backend: \(r.backend)
        Model: \(r.model)
        Device: \(r.device) — \(r.osVersion)
        Total (inclui load): \(number(r.totalMs)) ms
        Load: \(number(r.modelLoadMs)) ms
        TTFT (MLX interno): \(number(r.ttftMs)) ms
        Primeiro texto: \(number(r.firstTextMs)) ms
        Tokens in/out: \(r.inputTokens.map { String($0) } ?? "null") / \(r.outputTokens.map { String($0) } ?? "null")
        Prefill: \(number(r.prefillTokensPerSecond)) tok/s
        Decode: \(number(r.decodeTokensPerSecond)) tok/s
        Memory: \(number(r.memoryBeforeMB)) -> \(number(r.memoryAfterMB)) MB
        Thermal: \(r.thermalBefore) -> \(r.thermalAfter)
        Battery (0–1): \(number(r.batteryBefore.map { Double($0) })) -> \(number(r.batteryAfter.map { Double($0) }))
        Tool calls: \(r.toolCallCount.map { String($0) } ?? "null"); execução: \(number(r.toolExecutionMs)) ms
        Tool trace: \(r.toolTrace?.joined(separator: "; ") ?? "null")
        Tool mode: \(r.toolCallingMode ?? "null"); stop: \(r.stopReason ?? "null")
        Success: \(r.success)
        Error: \(r.error ?? "null")
        Response: \(r.response)
        """
    }
}
