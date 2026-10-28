import SwiftUI

struct ContentView: View {
    @State private var runner: BenchmarkRunner
    @State private var chat: ChatStore
    @State private var autoStarted = false

    init() {
        let runner = BenchmarkRunner()
        _runner = State(initialValue: runner)
        _chat = State(initialValue: ChatStore(mlx: runner.mlx))
    }

    var body: some View {
        TabView {
            ChatView(store: chat, runner: runner)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            execution
                .tabItem { Label("Executar", systemImage: "play") }
            LiveExecutionView(runner: runner)
                .tabItem { Label("Ao vivo", systemImage: "waveform.path.ecg") }
            ResultsView(runner: runner)
                .tabItem { Label("Resultados", systemImage: "chart.bar") }
        }
        .task {
            LaunchAutomation.writeDiagnostics()
            guard !autoStarted else { return }
            if LaunchAutomation.resumeSession {
                autoStarted = true
                await runner.resume()
                return
            }
            guard var preset = LaunchAutomation.preset() else { return }
            autoStarted = true
            if let limit = LaunchAutomation.taskLimit {
                preset.config.taskLimit = limit
            }
            await runner.runMatrix(agents: preset.agents, config: preset.config)
        }
    }

    private var execution: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mobile LLM Bench").font(.title)
                MatrixSetupView(runner: runner)
                if runner.running {
                    Button("Cancelar") { runner.cancel() }
                }
                if !runner.exportURLs.isEmpty {
                    ShareLink(items: runner.exportURLs) {
                        Label("Compartilhar JSON, CSV e resumo", systemImage: "square.and.arrow.up")
                    }
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

struct MatrixSetupView: View {
    var runner: BenchmarkRunner
    @State private var agents: Set<Agent> = [.qwen]
    @State private var dataset = "apple"
    @State private var categories: Set<String> = []
    @State private var strategies: Set<String> = ["direct"]
    @State private var repetitions = 1
    @State private var seed = "12"
    @State private var shuffle = false
    @State private var executionMode = "simulated"
    @State private var requireCool = false
    @State private var warmup = false
    @State private var taskLimit = 0
    @State private var taskIDText = ""
    @State private var applyingPreset = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presets editáveis").font(.headline)
            HStack {
                Button("Cross-Model") { apply(ExperimentPresets.crossModel()) }
                Button("Aceleração") { apply(ExperimentPresets.modelSpecific()) }
                Button("Full Apple") { apply(ExperimentPresets.fullApple()) }
            }
            HStack {
                Button("Adaptativo") { apply(ExperimentPresets.adaptivePilot()) }
                Button("Variância 3×") { apply(ExperimentPresets.variance3Rep()) }
            }
            HStack {
                Button("Passo adaptativo") { apply(ExperimentPresets.adaptiveStepPilot()) }
                Button("ActionAware") { apply(ExperimentPresets.actionAwarePilot()) }
            }
            .buttonStyle(.bordered)
            Picker("Dataset", selection: datasetBinding) {
                Text("Legado").tag("legacy")
                Text("Apple").tag("apple")
                Text("Step").tag("apple_step")
                Text("BFCL").tag("bfcl")
            }
            .pickerStyle(.segmented)
            Text("Modelos").font(.subheadline)
            ForEach(Agent.allCases) { item in
                Toggle(item.title, isOn: agentBinding(item))
            }
            Text("Categorias").font(.subheadline)
            ForEach(MatrixCatalog.categories(dataset: dataset), id: \.self) { category in
                Toggle(category, isOn: binding(category, in: $categories))
            }
            Text("Estratégias").font(.subheadline)
            ForEach(Strategy.allCases) { item in
                if supported(item).isEmpty {
                    Text("\(item.rawValue): not_applicable")
                        .font(.subheadline)
                } else {
                    Toggle(item.title, isOn: strategyBinding(item.rawValue))
                    if !unsupported(item).isEmpty {
                        Text(unsupported(item).map { "\($0.rawValue) \(item.rawValue): not_applicable" }.joined(separator: ", "))
                            .font(.caption)
                    }
                }
            }
            Stepper("Repetições: \(repetitions)", value: $repetitions, in: 1...10)
            TextField("Seed", text: $seed)
                .textFieldStyle(.roundedBorder)
            Toggle("Ordem aleatória", isOn: $shuffle)
            if dataset == "legacy" {
                Picker("Execução", selection: $executionMode) {
                    Text("Simulada").tag("simulated")
                    Text("Real").tag("real")
                }
                .pickerStyle(.segmented)
            }
            Toggle("Começar só em térmica nominal ou fair", isOn: $requireCool)
            Toggle("Aquecimento fora da análise", isOn: $warmup)
            Stepper("Limite de tarefas: \(taskLimit == 0 ? "sem limite" : String(taskLimit))", value: $taskLimit, in: 0...500)
            Text("IDs, um por linha. Vazio usa as categorias.").font(.caption)
            TextField("apple_single_001", text: $taskIDText, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            if forcedSimulated {
                Text("Modo simulado. As ferramentas não alteram dados do iPhone.")
                    .font(.footnote)
            }
            Text(estimateText).font(.headline)
            if !plan.notApplicable.isEmpty {
                Text(plan.notApplicable.map { "\($0): not_applicable" }.joined(separator: "\n"))
                    .font(.caption)
            }
            Button("Iniciar \(plan.measured) avaliações") {
                Task { await runner.runMatrix(agents: selectedAgents, config: config) }
            }
            .disabled(runner.running || plan.measured == 0)
            if let done = runner.pendingCompleted, let left = runner.pendingRemaining, left > 0 {
                Button("Continuar sessão (\(done) gravados, \(left) restantes)") { Task { await runner.resume() } }
                    .disabled(runner.running)
            }
        }
            .onAppear {
            guard !loaded else { return }
            loaded = true
            if let preset = LaunchAutomation.preset() {
                apply(preset)
                if let limit = LaunchAutomation.taskLimit { taskLimit = limit }
            } else {
                apply(ExperimentPresets.crossModel())
            }
        }
    }

    private var datasetBinding: Binding<String> {
        Binding(get: { dataset }, set: { newValue in
            dataset = newValue
            guard !applyingPreset else { return }
            categories = Set(MatrixCatalog.categories(dataset: newValue))
            taskIDText = ""
        })
    }

    private var forcedSimulated: Bool { dataset != "legacy" || executionMode != "real" }

    private var selectedAgents: [Agent] { Agent.allCases.filter { agents.contains($0) } }

    private var chosenStrategies: [String] {
        Strategy.allCases.map(\.rawValue).filter { strategies.contains($0) && !supported(Strategy(rawValue: $0)!).isEmpty }
    }

    private var config: ProtocolConfig {
        var built = ProtocolConfig()
        built.repetitions = repetitions
        built.shuffle = shuffle
        built.warmup = warmup
        built.requireCoolThermal = requireCool
        built.orderSeed = seed.isEmpty ? "1" : seed
        built.dataset = dataset
        built.executionMode = dataset == "legacy" ? executionMode : "simulated"
        built.strategies = chosenStrategies
        built.categories = MatrixCatalog.categories(dataset: dataset).filter { categories.contains($0) }
        built.taskIDs = parsedIDs
        built.taskLimit = taskLimit == 0 ? nil : taskLimit
        built.protocolId = StudyProtocol.identify(dataset: dataset, strategies: chosenStrategies)
        built.datasetId = dataset
        built.taskSetId = TaskSets.identify(dataset: dataset, ids: MatrixPlanner.estimate(agents: selectedAgents, config: built).taskIDs)
        built.evaluationVersion = EvaluationIdentity.version(dataset: dataset)
        built.methodNote = ExperimentProtocol.methodNote
        return built
    }

    private var plan: MatrixEstimate { MatrixPlanner.estimate(agents: selectedAgents, config: config) }

    private var estimateText: String {
        var lines = ["\(config.protocolId ?? "sem protocolo"): \(plan.measured) avaliações. \(plan.taskIDs.count) tarefas, \(selectedAgents.count) modelos, \(plan.strategies.count) estratégias aplicáveis, \(repetitions) repetições. Aquecimento: \(plan.warmup)."]
        if dataset == "bfcl", agents.contains(.apple) {
            lines.append("apple: not_applicable. BFCL é um subset com checker adaptado e não roda no Apple Foundation Models.")
        }
        if dataset == "bfcl" {
            lines.append("BFCL é um subset com checker adaptado, não a avaliação oficial.")
        }
        return lines.joined(separator: " ")
    }

    private var parsedIDs: [String]? {
        let ids = taskIDText.split { $0 == "," || $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
        return ids.isEmpty ? nil : ids
    }

    private func apply(_ preset: ExperimentPreset) {
        applyingPreset = true
        agents = Set(preset.agents)
        dataset = preset.config.resolvedDataset
        categories = Set(preset.config.categories ?? [])
        strategies = Set(preset.config.strategies ?? [])
        repetitions = preset.config.repetitions
        seed = preset.config.orderSeed
        shuffle = preset.config.shuffle
        executionMode = preset.config.resolvedExecutionMode
        requireCool = preset.config.requireCoolThermal
        warmup = preset.config.warmup
        taskLimit = preset.config.taskLimit ?? 0
        taskIDText = (preset.config.taskIDs ?? []).joined(separator: "\n")
        applyingPreset = false
    }

    private func agentBinding(_ agent: Agent) -> Binding<Bool> {
        Binding(get: { agents.contains(agent) }, set: { on in
            if on { agents.insert(agent) } else { agents.remove(agent) }
        })
    }

    private func strategyBinding(_ value: String) -> Binding<Bool> {
        Binding(get: { strategies.contains(value) }, set: { on in
            if on { strategies.insert(value) } else { strategies.remove(value) }
        })
    }

    private func supported(_ strategy: Strategy) -> [Agent] {
        selectedAgents.filter { strategy.supports($0) }
    }

    private func unsupported(_ strategy: Strategy) -> [Agent] {
        selectedAgents.filter { !strategy.supports($0) }
    }

    private func binding(_ value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) }, set: { on in
            if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
        })
    }
}
