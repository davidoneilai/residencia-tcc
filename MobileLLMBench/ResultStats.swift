import Foundation

struct StrategyStats: Equatable, Identifiable {
    var strategy: String
    var n: Int
    var successes: Int
    var successRate: Double?
    var medianLatency: Double?
    var p90Latency: Double?
    var meanTokens: Double?
    var medianTimeToTool: Double?
    var coldMedian: Double?
    var warmMedian: Double?
    var missingLatency: Int
    var population: String
    var taskIDs: [String]
    var id: String { strategy }
}

struct CategoryStats: Equatable, Identifiable {
    var category: String
    var strategy: String
    var n: Int
    var successRate: Double?
    var id: String { "\(category)|\(strategy)" }
}

struct ParetoPoint: Equatable, Identifiable {
    var strategy: String
    var latency: Double
    var success: Double
    var id: String { strategy }
}

struct LatencyBar: Equatable, Identifiable {
    var label: String
    var milliseconds: Double
    var id: String { label }
}

struct FailureBucket: Equatable {
    var agent: Int
    var runtime: Int
    var notRun: Int
    var kinds: [String: Int]
}

struct SessionStats: Equatable {
    var completed: Int
    var executed: Int
    var successRate: Double?
    var medianLatency: Double?
    var p90Latency: Double?
    var meanTokens: Double?
    var missingLatency: Int
    var failures: FailureBucket
    var thermal: [String: Int]
    var strategies: [StrategyStats]
    var categories: [CategoryStats]
    var pareto: [ParetoPoint]
    var paretoFront: [String]
    var comparable: Bool
    var comparabilityNote: String
    var exploratory: Bool
    var coldMedian: Double?
    var warmMedian: Double?
    var warnings: [String]
}

struct ResultSlice: Identifiable {
    var id: String
    var title: String
    var rows: [BenchmarkResult]
}

enum ResultStats {
    static func analyze(_ rows: [BenchmarkResult]) -> SessionStats {
        let kept = rows.filter { $0.countsTowardAnalysis != false && ($0.phase == nil || $0.phase == "measured") }
        let notes = warnings(kept)
        if Set(kept.map(datasetKey)).count > 1 {
            return empty(kept, note: "Datasets diferentes. Sem taxa única.", warnings: notes)
        }
        let executed = kept.filter(ran)
        let successes = executed.filter(succeeded)
        let latencies = executed.compactMap(inferenceLatency)
        let tokens = executed.compactMap(tokenCount)
        let label = seriesLabel(executed)
        let byStrategy = Dictionary(grouping: executed, by: label)
        let strategies = byStrategy.keys.sorted().map { strategyStats($0, rows: byStrategy[$0] ?? []) }
        let categories = categoryStats(executed, label: label)
        let comparable = populationsMatch(strategies)
        let points = strategies.compactMap { row -> ParetoPoint? in
            guard let latency = row.medianLatency, let rate = row.successRate else { return nil }
            return ParetoPoint(strategy: row.strategy, latency: latency, success: rate)
        }
        let front = comparable ? undominated(points).map(\.strategy) : []
        let note = comparable
            ? "As estratégias usam o mesmo conjunto de tarefas."
            : "As estratégias não usam o mesmo conjunto de tarefas. A fronteira de Pareto não foi traçada."
        let cold = median(executed.filter { $0.startKind == "cold" }.compactMap(inferenceLatency))
        let warm = median(executed.filter { $0.startKind == "warm" }.compactMap(inferenceLatency))
        let unspecified = executed.filter { inferenceLatency($0) != nil && $0.startKind != "cold" && $0.startKind != "warm" }.count
        let classes = [cold == nil ? 0 : 1, warm == nil ? 0 : 1, unspecified == 0 ? 0 : 1].reduce(0, +)
        let pooled = classes > 1 ? nil : median(latencies)
        let pooledP90 = classes > 1 ? nil : percentile(latencies, 0.9)
        return SessionStats(
            completed: kept.count,
            executed: executed.count,
            successRate: rate(successes.count, executed.count),
            medianLatency: pooled,
            p90Latency: pooledP90,
            meanTokens: mean(tokens),
            missingLatency: executed.count - latencies.count,
            failures: buckets(kept),
            thermal: thermalCounts(kept),
            strategies: strategies,
            categories: categories,
            pareto: points,
            paretoFront: front,
            comparable: comparable,
            comparabilityNote: note,
            exploratory: exploratory(rows),
            coldMedian: cold,
            warmMedian: warm,
            warnings: notes)
    }

    static func slices(_ rows: [BenchmarkResult]) -> [ResultSlice] {
        let grouped = Dictionary(grouping: rows) { row in
            [row.protocolId ?? "sem protocolo", datasetKey(row), row.taskSetId ?? "sem conjunto", row.evaluationVersion ?? "sem versão"].joined(separator: "|")
        }
        return grouped.keys.sorted().map { key in
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let title = "\(parts.first ?? "") · \(parts.dropFirst().first ?? "") · \(parts.dropFirst(2).first ?? "")"
            return ResultSlice(id: key, title: title, rows: grouped[key] ?? [])
        }
    }

    static func crossWarnings(_ rows: [BenchmarkResult]) -> [String] {
        var notes: [String] = []
        if Set(rows.map(datasetKey)).count > 1 {
            notes.append("Legado, Apple e BFCL não entram na mesma taxa de sucesso.")
        }
        if Set(rows.map { $0.protocolId ?? "sem protocolo" }).count > 1 {
            notes.append("Protocolos diferentes. Cada bloco é uma comparação separada.")
        }
        if Set(rows.compactMap(\.taskSetId)).count > 1 {
            notes.append("Conjuntos de tarefas diferentes.")
        }
        if Set(rows.compactMap(\.evaluationVersion)).count > 1 {
            notes.append("Versões de avaliação diferentes.")
        }
        return notes
    }

    static func warnings(_ rows: [BenchmarkResult]) -> [String] {
        var notes: [String] = []
        if rows.contains(where: { datasetKey($0) == "bfcl" }) {
            notes.append("BFCL é um subset com checker adaptado, não a avaliação oficial.")
        }
        if Set(rows.compactMap(\.orderSeed)).count > 1 {
            notes.append("Seeds de ordem diferentes.")
        }
        if Set(rows.compactMap(\.repetitions)).count > 1 {
            notes.append("Número de repetições diferente.")
        }
        return notes
    }

    private static func datasetKey(_ row: BenchmarkResult) -> String {
        row.datasetId ?? row.dataset ?? "legacy"
    }

    private static func seriesLabel(_ rows: [BenchmarkResult]) -> (BenchmarkResult) -> String {
        let models = Set(rows.map { $0.modelId ?? $0.model })
        let split = models.count > 1
        return { row in
            let strategy = row.strategyId ?? row.strategy
            return split ? "\(row.modelId ?? row.model) \(strategy)" : strategy
        }
    }

    private static func empty(_ rows: [BenchmarkResult], note: String, warnings: [String]) -> SessionStats {
        SessionStats(
            completed: rows.count, executed: 0, successRate: nil, medianLatency: nil, p90Latency: nil,
            meanTokens: nil, missingLatency: 0, failures: buckets(rows), thermal: thermalCounts(rows),
            strategies: [], categories: [], pareto: [], paretoFront: [], comparable: false,
            comparabilityNote: note, exploratory: exploratory(rows), coldMedian: nil, warmMedian: nil,
            warnings: warnings)
    }

    static func inferenceLatency(_ row: BenchmarkResult) -> Double? {
        if let latency = row.totalLatencyMs { return latency }
        if let total = row.totalMs, let load = row.modelLoadMs, total >= load { return total - load }
        if row.modelLoadMs == nil { return row.totalMs }
        return nil
    }

    static func ran(_ row: BenchmarkResult) -> Bool {
        if row.failureKind == "thermal" || row.failureKind == "cancelled" { return false }
        if row.thermalGate == "timeout" || row.thermalGate == "cancelled" { return false }
        if row.failureKind == "grade" || row.failureKind == "no_tool" || row.failureKind == "inference" || row.failureKind == "execution" {
            return true
        }
        if succeeded(row) { return true }
        return row.totalMs != nil || row.totalLatencyMs != nil || row.toolTrace != nil
    }

    static func succeeded(_ row: BenchmarkResult) -> Bool {
        row.taskSuccess ?? row.success
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[mid - 1] + sorted[mid]) / 2 }
        return sorted[mid]
    }

    static func csv(_ stats: SessionStats, model: String) -> String {
        var lines = ["model,strategy,category,n,success_rate,median_latency_ms,p90_latency_ms,mean_tokens,median_time_to_tool_ms,missing_latency,population"]
        for row in stats.strategies {
            lines.append(cell(model, row.strategy, "all", row))
        }
        for row in stats.categories {
            let rate = row.successRate.map { String($0) } ?? ""
            lines.append([model, row.strategy, row.category, String(row.n), rate, "", "", "", "", "", ""].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func markdown(_ stats: SessionStats, model: String) -> String {
        var lines = [
            "# Resumo experimental",
            "",
            stats.exploratory ? "Análise exploratória: há no máximo uma repetição por condição." : "Há mais de uma repetição.",
            "",
            "Avaliações na análise: \(stats.completed). Executadas: \(stats.executed). Puladas ou interrompidas: \(stats.failures.notRun).",
            "Sucesso: \(percent(stats.successRate)). Latência mediana: \(number(stats.medianLatency)) ms. p90: \(number(stats.p90Latency)) ms.",
            "Tokens médios: \(number(stats.meanTokens)). Latências ausentes: \(stats.missingLatency).",
            "Cold-start mediano: \(number(stats.coldMedian)) ms. Warm-start mediano: \(number(stats.warmMedian)) ms.",
            "",
            "Falhas do agente: \(stats.failures.agent). Falhas de runtime: \(stats.failures.runtime). Não executadas: \(stats.failures.notRun).",
            stats.comparabilityNote,
            "",
        ]
        lines.append(contentsOf: stats.warnings)
        lines.append(contentsOf: [
            "",
            "| Estratégia | n | Sucesso | Mediana | p90 | Tokens | Time-to-tool | População |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
        ])
        for row in stats.strategies {
            lines.append("| \(row.strategy) | \(row.n) | \(percent(row.successRate)) | \(number(row.medianLatency)) | \(number(row.p90Latency)) | \(number(row.meanTokens)) | \(number(row.medianTimeToTool)) | \(row.population) |")
        }
        if !stats.paretoFront.isEmpty {
            lines.append("")
            lines.append("Fronteira: \(stats.paretoFront.joined(separator: ", ")).")
        }
        lines.append("")
        lines.append("Modelo: \(model). A latência é `totalLatencyMs`, ou `totalMs` menos a carga quando o campo novo não existe. Tentativas puladas não entram na taxa de sucesso.")
        return lines.joined(separator: "\n")
    }

    /// Uma barra por estratégia e tipo de partida. Cold e warm não viram uma mediana só.
    static func latencyBars(_ rows: [BenchmarkResult]) -> [LatencyBar] {
        groups(rows).compactMap { pair in
            guard let value = median(pair.value.compactMap(inferenceLatency)) else { return nil }
            return LatencyBar(label: pair.key, milliseconds: value)
        }
    }

    /// Ponto por estratégia e tipo de partida, para o gráfico não ficar vazio quando a mediana única é retida.
    static func startPoints(_ rows: [BenchmarkResult]) -> [ParetoPoint] {
        groups(rows).compactMap { pair in
            guard let latency = median(pair.value.compactMap(inferenceLatency)), !pair.value.isEmpty else { return nil }
            return ParetoPoint(
                strategy: pair.key, latency: latency,
                success: Double(pair.value.filter(succeeded).count) / Double(pair.value.count))
        }
    }

    private static func groups(_ rows: [BenchmarkResult]) -> [(key: String, value: [BenchmarkResult])] {
        let executed = rows.filter { ran($0) && $0.countsTowardAnalysis != false && ($0.phase == nil || $0.phase == "measured") }
        let label = seriesLabel(executed)
        let grouped = Dictionary(grouping: executed) { row in
            "\(label(row)) \(row.startKind ?? "start")"
        }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    static func findings(_ row: BenchmarkResult) -> [String] {
        var labels: [String] = []
        let selection = row.selectionReason ?? ""
        if row.failureKind == "no_tool" || selection.contains("faltou") { labels.append("Missing tool") }
        if row.toolSelectionCorrect == false && (selection.contains("extra") || !selection.contains("faltou")) {
            labels.append("Wrong tool")
        }
        if row.toolArgumentsCorrect == false { labels.append("Invalid arguments") }
        if (row.duplicateToolCalls ?? 0) > 0 { labels.append("Duplicate tool") }
        if (row.sequenceReason ?? "").contains("dependência") || row.toolSequenceCorrect == false {
            labels.append("Broken dependency")
        }
        if row.completionCorrect == false || (row.completionReason ?? "").contains("efeito") || (row.completionReason ?? "").contains("não cobre") {
            labels.append("Incomplete trajectory")
        }
        if (row.invalidToolCalls ?? 0) > 0 { labels.append("Unexpected action") }
        return labels
    }

    private static func strategyStats(_ strategy: String, rows: [BenchmarkResult]) -> StrategyStats {
        let latencies = rows.compactMap(inferenceLatency)
        let tokens = rows.compactMap(tokenCount)
        let tools = rows.compactMap { $0.inferenceMs ?? $0.timeToFirstToolCallMs }
        let coldValues = rows.filter { $0.startKind == "cold" }.compactMap(inferenceLatency)
        let warmValues = rows.filter { $0.startKind == "warm" }.compactMap(inferenceLatency)
        let cold = median(coldValues)
        let warm = median(warmValues)
        let unspecified = rows.filter { inferenceLatency($0) != nil && $0.startKind != "cold" && $0.startKind != "warm" }.count
        let classes = [coldValues.isEmpty ? 0 : 1, warmValues.isEmpty ? 0 : 1, unspecified == 0 ? 0 : 1].reduce(0, +)
        let chosen: [Double]
        let population: String
        if classes > 1 {
            chosen = []
            population = "misto"
        } else if !warmValues.isEmpty {
            chosen = warmValues
            population = "warm"
        } else if !coldValues.isEmpty {
            chosen = coldValues
            population = "cold"
        } else {
            chosen = latencies
            population = latencies.isEmpty ? "sem latência" : "start não informado"
        }
        let headline = median(chosen)
        let ids = Array(Set(rows.map { $0.taskId ?? $0.experiment })).sorted()
        return StrategyStats(
            strategy: strategy, n: rows.count, successes: rows.filter(succeeded).count,
            successRate: rate(rows.filter(succeeded).count, rows.count),
            medianLatency: headline, p90Latency: percentile(chosen, 0.9),
            meanTokens: mean(tokens), medianTimeToTool: median(tools),
            coldMedian: cold, warmMedian: warm, missingLatency: rows.count - latencies.count,
            population: population, taskIDs: ids)
    }

    private static func categoryStats(_ rows: [BenchmarkResult], label: (BenchmarkResult) -> String) -> [CategoryStats] {
        let groups = Dictionary(grouping: rows) { "\($0.taskKind ?? "sem categoria")|\(label($0))" }
        return groups.keys.sorted().map { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let sample = groups[key] ?? []
            return CategoryStats(
                category: parts.first ?? "", strategy: parts.last ?? "",
                n: sample.count, successRate: rate(sample.filter(succeeded).count, sample.count))
        }
    }

    private static func populationsMatch(_ rows: [StrategyStats]) -> Bool {
        let sets = rows.map { Set($0.taskIDs) }.filter { !$0.isEmpty }
        guard let first = sets.first else { return false }
        return sets.allSatisfy { $0 == first }
    }

    private static func undominated(_ points: [ParetoPoint]) -> [ParetoPoint] {
        points.filter { point in
            !points.contains { other in
                other.strategy != point.strategy
                    && other.latency <= point.latency
                    && other.success >= point.success
                    && (other.latency < point.latency || other.success > point.success)
            }
        }
    }

    private static func buckets(_ rows: [BenchmarkResult]) -> FailureBucket {
        var agent = 0
        var runtime = 0
        var notRun = 0
        var kinds: [String: Int] = [:]
        for row in rows {
            let kind = row.failureKind ?? (succeeded(row) ? "ok" : "desconhecido")
            kinds[kind, default: 0] += 1
            if !ran(row) { notRun += 1 }
            else if kind == "grade" || kind == "no_tool" { agent += 1 }
            else if !succeeded(row) { runtime += 1 }
        }
        return FailureBucket(agent: agent, runtime: runtime, notRun: notRun, kinds: kinds)
    }

    private static func thermalCounts(_ rows: [BenchmarkResult]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows {
            let state = row.thermalStateAfter ?? row.thermalAfter
            counts[state, default: 0] += 1
        }
        return counts
    }

    private static func exploratory(_ rows: [BenchmarkResult]) -> Bool {
        let reps = rows.compactMap(\.repetitions)
        if reps.contains(where: { $0 > 1 }) { return false }
        let indexes = rows.compactMap(\.runIndex)
        return !indexes.contains(where: { $0 > 1 })
    }

    private static func tokenCount(_ row: BenchmarkResult) -> Double? {
        if let generated = row.generatedTokens { return Double(generated) }
        if let output = row.outputTokens { return Double(output) }
        return nil
    }

    private static func rate(_ hits: Int, _ total: Int) -> Double? {
        guard total > 0 else { return nil }
        return Double(hits) / Double(total)
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func cell(_ model: String, _ strategy: String, _ category: String, _ row: StrategyStats) -> String {
        let rate = row.successRate.map { String($0) } ?? ""
        let latency = row.medianLatency.map { String($0) } ?? ""
        let p90 = row.p90Latency.map { String($0) } ?? ""
        let tokens = row.meanTokens.map { String($0) } ?? ""
        let tool = row.medianTimeToTool.map { String($0) } ?? ""
        return [model, strategy, category, String(row.n), rate, latency, p90, tokens, tool, String(row.missingLatency), row.population].joined(separator: ",")
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "null" }
        return String(format: "%.1f%%", value * 100)
    }

    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "null"
    }
}
