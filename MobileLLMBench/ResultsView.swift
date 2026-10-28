import Charts
import SwiftUI
import UIKit

struct ResultsView: View {
    var runner: BenchmarkRunner
    @State private var sessions: [ExperimentSession] = []

    var body: some View {
        NavigationStack {
            List {
                if !runner.results.isEmpty {
                    NavigationLink("Resultados desta execução (\(runner.results.count))") {
                        SessionDashboard(title: "Execução atual", rows: runner.results, model: runner.results.last?.model ?? "")
                    }
                }
                ForEach(sessions, id: \.sessionID) { session in
                    NavigationLink(sessionTitle(session)) {
                        SessionDashboard(
                            title: session.startedAt.formatted(date: .abbreviated, time: .shortened),
                            rows: session.results, model: session.results.last?.model ?? "")
                    }
                }
            }
            .navigationTitle("Results")
            .onAppear { sessions = SessionDisk.sessions() }
            .toolbar {
                Button("Atualizar") { sessions = SessionDisk.sessions() }
            }
        }
    }

    private func sessionTitle(_ session: ExperimentSession) -> String {
        let when = session.startedAt.formatted(date: .abbreviated, time: .shortened)
        let study = session.config.protocolId ?? "sem protocolo"
        return "\(when) · \(study) · \(session.config.resolvedDataset) · \(session.results.count)"
    }
}

struct SessionDashboard: View {
    var title: String
    var rows: [BenchmarkResult]
    var model: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2)
                Text(ExperimentProtocol.methodNote).font(.caption)
                ForEach(ResultStats.crossWarnings(rows), id: \.self) { item in
                    Text(item).font(.footnote)
                }
                ForEach(ResultStats.slices(rows)) { slice in
                    ProtocolPanel(title: slice.title, rows: slice.rows)
                    Divider()
                }
            }
            .padding()
        }
        .navigationTitle("Sessão")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProtocolPanel: View {
    var title: String
    var rows: [BenchmarkResult]
    @State private var figureURLs: [URL] = []

    private var stats: SessionStats { ResultStats.analyze(rows) }
    private var latencyBars: [LatencyBar] { ResultStats.latencyBars(rows) }
    private var chartPoints: [ParetoPoint] {
        stats.pareto.isEmpty ? ResultStats.startPoints(rows) : stats.pareto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3)
            if stats.exploratory {
                Text("Análise exploratória: uma repetição por condição.").font(.footnote)
            }
            ForEach(stats.warnings, id: \.self) { item in
                Text(item).font(.footnote)
            }
            summary
                strategyTable
                categoryChart
                latencyChart
                paretoChart
                Button("Gerar figuras PNG") { figureURLs = FigureExport.write(rows: rows, name: title) }
                if !figureURLs.isEmpty {
                    ShareLink(items: figureURLs) {
                        Label("Compartilhar figuras", systemImage: "square.and.arrow.up")
                    }
                }
                Text("Trajetórias").font(.headline)
                ForEach(rows, id: \.id) { row in
                    NavigationLink("\(row.strategy) · \(row.experiment) · \(row.success ? "ok" : "falha")") {
                        TrajectoryView(row: row)
                    }
                }
            }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary").font(.headline)
            Text("Concluídas na análise: \(stats.completed). Executadas: \(stats.executed).")
            Text("Sucesso: \(percent(stats.successRate)). Mediana: \(ms(stats.medianLatency)). p90: \(ms(stats.p90Latency)).")
            Text("Tokens médios: \(ms(stats.meanTokens)). Latências ausentes: \(stats.missingLatency).")
            Text("Cold: \(ms(stats.coldMedian)). Warm: \(ms(stats.warmMedian)).")
            Text("Agente: \(stats.failures.agent). Runtime: \(stats.failures.runtime). Não executadas: \(stats.failures.notRun).")
            Text("Térmica: \(stats.thermal.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
                .font(.footnote)
        }
    }

    private var strategyTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strategy Comparison").font(.headline)
            ForEach(stats.strategies) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.strategy).bold()
                    Text("n \(row.n) · sucesso \(percent(row.successRate)) · mediana \(ms(row.medianLatency)) · p90 \(ms(row.p90Latency))")
                        .font(.caption)
                    Text("tokens \(ms(row.meanTokens)) · time-to-tool \(ms(row.medianTimeToTool)) · \(row.population)")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var categoryChart: some View {
        Text("Category Performance").font(.headline)
        if stats.categories.isEmpty {
            Text("Sem categorias executadas.")
        } else {
            Chart(stats.categories) { item in
                BarMark(
                    x: .value("Categoria", item.category),
                    y: .value("Sucesso", item.successRate ?? 0))
                .foregroundStyle(by: .value("Estratégia", item.strategy))
                .position(by: .value("Estratégia", item.strategy))
            }
            .chartYScale(domain: 0...1)
            .frame(height: 220)
        }
    }

    @ViewBuilder
    private var latencyChart: some View {
        Text("Latência").font(.headline)
        if latencyBars.isEmpty {
            Text("Sem latência para desenhar.")
        } else {
            Text("Cold e warm ficam em barras separadas.").font(.footnote)
            Chart(latencyBars) { bar in
                BarMark(
                    x: .value("Série", bar.label),
                    y: .value("ms", bar.milliseconds))
            }
            .frame(height: 220)
        }
    }

    @ViewBuilder
    private var paretoChart: some View {
        Text("Efficiency vs Quality").font(.headline)
        Text(stats.pareto.isEmpty
            ? "Cold e warm são pontos separados. A fronteira não mistura os dois."
            : stats.comparabilityNote)
            .font(.footnote)
        if chartPoints.isEmpty {
            Text("Sem pontos com latência e sucesso.")
        } else {
            Chart {
                ForEach(chartPoints) { point in
                    PointMark(
                        x: .value("Latência mediana", point.latency),
                        y: .value("Sucesso", point.success))
                    .foregroundStyle(by: .value("Série", point.strategy))
                    .annotation(position: .top) { Text(point.strategy).font(.caption2) }
                }
                if !stats.pareto.isEmpty, stats.comparable {
                    ForEach(frontPoints) { point in
                        LineMark(
                            x: .value("Latência mediana", point.latency),
                            y: .value("Sucesso", point.success))
                    }
                }
            }
            .chartYScale(domain: 0...1)
            .frame(height: 220)
        }
    }

    private var frontPoints: [ParetoPoint] {
        stats.pareto.filter { stats.paretoFront.contains($0.strategy) }.sorted { $0.latency < $1.latency }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "null"
    }

    private func ms(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "null"
    }
}

struct TrajectoryView: View {
    var row: BenchmarkResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(row.experiment).font(.headline)
                Text(row.strategy)
                if row.executionMode == "simulated" {
                    Text("Trajetória simulada.").font(.footnote)
                }
                Text("Latência \(row.totalLatencyMs.map { String(format: "%.0f ms", $0) } ?? "null") · tokens \(row.generatedTokens.map(String.init) ?? "null")")
                    .font(.caption)
                Text("Evaluator").font(.headline)
                let labels = ResultStats.findings(row)
                if labels.isEmpty {
                    Text(row.success ? "Sucesso. Nenhuma condição falhou." : (row.error ?? "Falha sem rótulo."))
                } else {
                    ForEach(labels, id: \.self) { Text($0) }
                }
                reason("Seleção", row.selectionReason)
                reason("Argumentos", row.argumentsReason)
                reason("Ordem", row.sequenceReason)
                reason("Conclusão", row.completionReason)
                if let error = row.error { Text(error).font(.caption) }
                Text("Chamadas").font(.headline)
                ForEach(row.toolCalls ?? [], id: \.index) { call in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(call.index). \(call.tool)").bold()
                        Text(call.arguments.map { "\($0.key)=\($0.value.text)" }.sorted().joined(separator: ", "))
                        Text(call.error ?? call.output ?? "null")
                    }
                    .font(.caption)
                }
                if row.toolCalls == nil, let trace = row.toolTrace {
                    Text(trace.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reason(_ title: String, _ value: String?) -> some View {
        Text("\(title): \(value ?? "null")").font(.caption)
    }
}

enum FigureExport {
    @MainActor
    static func write(rows: [BenchmarkResult], name: String) -> [URL] {
        let stats = ResultStats.analyze(rows)
        let folder = FileManager.default.temporaryDirectory
        let prefix = name.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return [
            png(AccuracyCard(categories: stats.categories), folder.appendingPathComponent("\(prefix)-accuracy_by_category.png")),
            png(LatencyCard(bars: ResultStats.latencyBars(rows)), folder.appendingPathComponent("\(prefix)-latency_by_strategy.png")),
            png(ParetoCard(points: stats.pareto.isEmpty ? ResultStats.startPoints(rows) : stats.pareto, link: !stats.pareto.isEmpty && stats.comparable, front: stats.paretoFront), folder.appendingPathComponent("\(prefix)-pareto.png")),
        ].compactMap { $0 }
    }

    @MainActor
    private static func png<V: View>(_ view: V, _ url: URL) -> URL? {
        let renderer = ImageRenderer(content: view.frame(width: 390).padding().background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 3
        guard let data = renderer.uiImage?.pngData() else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private struct AccuracyCard: View {
    var categories: [CategoryStats]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Sucesso por categoria").font(.headline)
            Chart(categories) { item in
                BarMark(x: .value("Categoria", item.category), y: .value("Sucesso", item.successRate ?? 0))
                    .foregroundStyle(by: .value("Estratégia", item.strategy))
            }
            .chartYScale(domain: 0...1)
            .frame(height: 240)
        }
    }
}

private struct LatencyCard: View {
    var bars: [LatencyBar]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Latência").font(.headline)
            Chart(bars) { bar in
                BarMark(x: .value("Série", bar.label), y: .value("ms", bar.milliseconds))
            }
            .frame(height: 240)
        }
    }
}

private struct ParetoCard: View {
    var points: [ParetoPoint]
    var link: Bool
    var front: [String]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Eficiência × qualidade").font(.headline)
            Chart {
                ForEach(points) { point in
                    PointMark(x: .value("Latência", point.latency), y: .value("Sucesso", point.success))
                }
                if link {
                    let ordered = points.filter { front.contains($0.strategy) }.sorted { $0.latency < $1.latency }
                    ForEach(ordered) { point in
                        LineMark(x: .value("Latência", point.latency), y: .value("Sucesso", point.success))
                    }
                }
            }
            .chartYScale(domain: 0...1)
            .frame(height: 240)
        }
    }
}
