import SwiftUI

struct ContentView: View {
    @State private var runner = BenchmarkRunner()
    @State private var strategy = Strategy.direct

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mobile LLM Bench").font(.title)
                Picker("Estratégia", selection: $strategy) {
                    ForEach(Strategy.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                ForEach(PhoneTask.allCases) { task in
                    Button(task.title) { Task { await runner.run(task, strategy: strategy) } }
                        .disabled(runner.running)
                }
                if let url = runner.exportURL {
                    ShareLink("Export JSON (\(runner.results.count) resultados)", item: url)
                }
                Text(runner.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
}
