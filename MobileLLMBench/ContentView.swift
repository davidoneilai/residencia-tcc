import SwiftUI

struct ContentView: View {
    @State private var runner = BenchmarkRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mobile LLM Bench").font(.title)
            Group {
                Button("Run Apple Baseline") { Task { await runner.run([.appleBaseline]) } }
                Button("Run Apple Tool Test") { Task { await runner.run([.appleTool]) } }
                Button("Run MLX Baseline") { Task { await runner.run([.mlxBaseline]) } }
                Button("Run All") { Task { await runner.run(Experiment.allCases) } }
            }
            .disabled(runner.running)
            if let url = runner.exportURL {
                ShareLink("Export JSON (\(runner.results.count) resultados)", item: url)
            }
            ScrollView {
                Text(runner.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}
