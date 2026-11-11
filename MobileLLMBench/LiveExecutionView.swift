import SwiftUI

struct LiveExecutionView: View {
    var runner: BenchmarkRunner
    var server: InferenceServer?
    @State private var inspection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Live Execution").font(.title2)
                Toggle("Inspection mode", isOn: $inspection)
                if let server { serving(server) }
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
                } else if server?.progress == nil {
                    Text("Nenhuma matriz nesta sessão. A tela lê o runner; não dispara o modelo.")
                        .font(.footnote)
                }
            }
            .padding()
        }
    }

    private func serving(_ server: InferenceServer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Servidor (bench do Mac)").font(.headline)
            // Relê a térmica e a idade do último aviso do Mac a cada 5 s.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    if let progress = server.progress { benchStatus(progress, server: server, now: context.date) }
                    labeled("Térmica agora", DeviceMetrics.thermal)
                }
            }
            labeled("Estado", server.status)
            if let since = server.generatingSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    labeled("Gerando há", "\(Int(context.date.timeIntervalSince(since))) s")
                }
            }
            labeled("Respostas", "\(server.served)")
            if let last = server.lastTurn { labeled("Último passo", last) }
        }
    }

    /// Cartão do bench do Mac: estado em cor, execuções feitas/total, rodada/tarefa/condição e previsão.
    private func benchStatus(_ progress: ServeProgress, server: InferenceServer, now: Date) -> some View {
        let finished = progress.state == "terminou" || progress.done >= progress.total
        let age = progress.received.map { Int(now.timeIntervalSince($0)) } ?? 0
        // Uma execução longa (197) chega a ~8 min; sem aviso por 15 min e sem gerar, o Mac provavelmente parou.
        let stale = !finished && age > 900 && server.generatingSince == nil
        let (title, color): (String, Color) =
            if stale { ("Sem notícias do Mac há \(age / 60) min", .red) }
            else if progress.state == "falhou" { ("Falhou", .red) }
            else if finished { ("Terminou", .gray) }
            else if progress.state == "esfriando" { ("Esfriando o iPhone", .orange) }
            else { ("Rodando", .green) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold()).foregroundStyle(color)
            if progress.state == "esfriando" && !stale {
                Text("Térmica \(DeviceMetrics.thermal): o Mac espera baixar antes da próxima execução"
                     + (progress.cooledSeconds.map { " (já \($0) s)" } ?? "") + ".")
                    .font(.footnote)
            }
            ProgressView(value: Double(min(progress.done, progress.total)), total: Double(max(progress.total, 1)))
                .tint(color)
            Text("\(progress.done) de \(progress.total) execuções · faltam \(max(progress.total - progress.done, 0))")
                .font(.headline)
            if let round = progress.round { labeled("Rodada", round) }
            if let task = progress.task { labeled("Tarefa", task) }
            if let condition = progress.condition { labeled("Condição", condition) }
            if let eta = progress.etaSeconds, !finished {
                labeled("Previsão", "\(eta / 3600) h \(eta % 3600 / 60) min · ~\(now.addingTimeInterval(Double(eta)).formatted(date: .omitted, time: .shortened))")
            }
            if let failures = progress.failures, failures > 0 { labeled("Execuções que falharam", "\(failures)") }
            labeled("Último aviso do Mac", age < 60 ? "há \(age) s" : "há \(age / 60) min")
            Text(progress.label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
