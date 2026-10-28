import SwiftUI

struct LiveExecutionView: View {
    var runner: BenchmarkRunner
    @State private var inspection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Live Execution").font(.title2)
                Toggle("Inspection mode", isOn: $inspection)
                if let live = runner.live {
                    if live.mode == "simulated" {
                        Text("Dados simulados. Esta execução não mexe na agenda, no calendário nem nas mensagens do iPhone.")
                            .font(.footnote)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.yellow.opacity(0.25))
                    }
                    ProgressView(value: Double(min(live.completed, live.total)), total: Double(max(live.total, 1)))
                    labeled("Progresso", "\(min(live.completed + (runner.running ? 1 : 0), live.total)) / \(live.total)")
                    labeled("Modelo", live.agent)
                    labeled("Estratégia", live.strategy)
                    labeled("Dataset", live.dataset)
                    labeled("Categoria", live.category)
                    labeled("Tarefa", live.taskID)
                    labeled("Fase", live.phase)
                    labeled("Térmica no início", live.thermal)
                    Text(live.query).textSelection(.enabled)
                    if let row = matchingResult(live) {
                        labeled("Avaliador", row.success ? "sucesso" : (row.failureKind ?? "falha"))
                        labeled("Latência", milliseconds(row.totalLatencyMs))
                        labeled("Tokens", row.generatedTokens.map(String.init) ?? row.outputTokens.map(String.init) ?? "null")
                        labeled("Térmica ao fim", row.thermalAfter)
                        if inspection {
                            findings(row)
                            calls(row)
                        } else {
                            Text("Tools: \(row.toolCallCount.map(String.init) ?? "0"). Abra Inspection mode para o trace.")
                                .font(.footnote)
                        }
                    } else if runner.running {
                        Text("Tarefa em execução. O trace aparece quando ela termina, sem uma segunda inferência.")
                            .font(.footnote)
                    }
                } else {
                    Text("Nenhuma matriz nesta sessão. A tela lê o runner; não dispara o modelo.")
                        .font(.footnote)
                }
            }
            .padding()
        }
    }

    private func matchingResult(_ live: LiveProgress) -> BenchmarkResult? {
        runner.results.last { $0.experiment == live.taskID && $0.phase == live.phase }
    }

    private func findings(_ row: BenchmarkResult) -> some View {
        let labels = ResultStats.findings(row)
        return VStack(alignment: .leading, spacing: 4) {
            if labels.isEmpty {
                Text(row.success ? "Nenhuma condição do evaluator falhou." : (row.error ?? "Sem justificativa."))
            } else {
                ForEach(labels, id: \.self) { Text($0).bold() }
            }
            if let reason = row.selectionReason { Text(reason).font(.caption) }
            if let reason = row.argumentsReason { Text(reason).font(.caption) }
            if let reason = row.sequenceReason { Text(reason).font(.caption) }
            if let reason = row.completionReason { Text(reason).font(.caption) }
        }
    }

    private func calls(_ row: BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(row.toolCalls ?? [], id: \.index) { call in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(call.index). \(call.tool)").bold()
                    Text(call.arguments.map { "\($0.key)=\($0.value.text)" }.sorted().joined(separator: ", "))
                    Text(call.error ?? call.output ?? "null")
                }
                .font(.caption)
            }
            if row.toolCalls == nil, let trace = row.toolTrace {
                Text(trace.joined(separator: "\n")).font(.caption)
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "null"
    }
}
