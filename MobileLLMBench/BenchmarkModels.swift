import Foundation

enum Agent: String, Codable, CaseIterable, Identifiable {
    case apple, qwen, gemma
    /// Estudo SLM × BFCL v4 AST. Fora de `allCases`: Chat e protocolos antigos não os veem.
    case minicpm5, lfm25, gemma4, qwen35

    static let allCases: [Agent] = [.apple, .qwen, .gemma]
    static let slms: [Agent] = [.minicpm5, .lfm25, .gemma4, .qwen35]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .qwen: "Qwen"
        case .gemma: "Gemma"
        case .minicpm5: "MiniCPM5-2B"
        case .lfm25: "LFM2.5-2.6B"
        case .gemma4: "Gemma 4 E2B"
        case .qwen35: "Qwen3.5-2B"
        }
    }

    var backend: String { self == .apple ? "apple_foundation_models" : "mlx" }

    var model: String {
        switch self {
        case .apple: "SystemLanguageModel.default"
        case .qwen: "mlx-community/Qwen3-1.7B-4bit"
        case .gemma: "mlx-community/gemma-4-e2b-it-4bit"
        default: "\(hubID)@\(revision)"
        }
    }

    var hubID: String {
        switch self {
        case .minicpm5: "openbmb/MiniCPM5-2B-MLX"
        case .lfm25: "LiquidAI/LFM2.5-2.6B-MLX-4bit"
        case .gemma4: "mlx-community/gemma-4-e2b-it-4bit"
        case .qwen35: "mlx-community/Qwen3.5-2B-4bit"
        default: model
        }
    }

    /// Commit do Hub verificado em 2026-10-27; nunca `main`.
    var revision: String {
        switch self {
        case .minicpm5: "8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3"
        case .lfm25: "04efa23776ce61ec34ec95ec34c859854c89542b"
        case .gemma4: "238767527555cb75a05732a84dff5d6ba0dd6809"
        case .qwen35: "674aaa7240b91e8012fcad5d791b7dfe5ba90207"
        default: "main"
        }
    }

    /// Template aceita `enable_thinking` (on/off). LFM2.5 abre `<think>` sempre.
    var thinkingSwitch: Bool { self == .minicpm5 || self == .gemma4 || self == .qwen35 }

    /// Marcador que fecha o raciocínio nativo; necessário para budget forcing (s1).
    var thinkClose: String? {
        switch self {
        case .minicpm5, .lfm25, .qwen35: "</think>"
        case .gemma4: "<channel|>"
        default: nil
        }
    }
}

enum Strategy: String, Codable, CaseIterable, Identifiable {
    case direct
    case planAct = "plan_act"
    case noThink = "nothink"
    case budget64 = "budget_64"
    case budget128 = "budget_128"
    case earlyExit = "early_exit"
    /// Escolhe `direct` ou `plan_act` via `AdaptiveRouter` antes da inferência.
    case adaptive
    /// Direct com teto global e recuperação se a primeira geração estoura sem ferramenta.
    case budgetedDirect = "budgeted_direct"
    /// Direct, e só planeja no meio da trajetória se houver bloqueio observado.
    case reactiveBudget = "reactive_budget"
    /// Por rodada: thinking on/off e orçamento, sem treino. Não é o roteador v3.
    case adaptiveStep = "adaptive_step"
    /// NoThink com throw de ferramenta absorvido; o loop continua.
    case noThinkRuntime = "nothink_runtime"
    /// NoThink até falha observável; aí uma recuperação com s1. Sem gold.
    case actionAware = "action_aware"
    /// BFCL AST: regra a priori (`ASTRouter`) entre a política rápida e a Direct do modelo.
    case astRouter = "ast_router"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Direto"
        case .planAct: "Plano e ação"
        case .noThink: "Sem thinking"
        case .budget64: "Budget 64"
        case .budget128: "Budget 128"
        case .earlyExit: "Early exit"
        case .adaptive: "Adaptativo"
        case .budgetedDirect: "Direct orçado"
        case .reactiveBudget: "Orçamento reativo"
        case .adaptiveStep: "Passo adaptativo"
        case .noThinkRuntime: "Sem thinking (runtime)"
        case .actionAware: "ActionAware"
        case .astRouter: "Roteador AST"
        }
    }

    /// Teto de tokens de raciocínio; early exit usa o teto do turno inteiro.
    var thinkingBudget: Int? {
        switch self {
        case .budget64: 64
        case .budget128: 128
        case .earlyExit: 512
        default: nil
        }
    }

    var shared: Bool { self == .direct || self == .planAct || self == .adaptive }

    /// Controle de thinking só existe no Qwen3: Apple não expõe raciocínio e o Gemma não gera <think>.
    func supports(_ agent: Agent) -> Bool {
        if Agent.slms.contains(agent) {
            switch self {
            case .direct, .planAct, .astRouter: return true
            case .noThink, .adaptiveStep: return agent.thinkingSwitch
            case .budget64: return agent.thinkClose != nil
            default: return false
            }
        }
        if self == .astRouter { return false }
        if self == .budgetedDirect || self == .reactiveBudget || self == .adaptiveStep
            || self == .noThinkRuntime || self == .actionAware {
            return agent == .qwen
        }
        return shared || agent == .qwen
    }

    func status(for agent: Agent) -> String {
        supports(agent) ? "applicable" : "not_applicable"
    }
}

enum PhoneTask: String, CaseIterable, Identifiable {
    case ligar, faceTime, email, mensagem, calendario, lembrete, mapas, safari
    case eventoELembrete, lembreteEMensagem
    case ligarContato, mensagemContato, lembreteEFaceTimeContato

    var id: String { rawValue }

    var kind: String {
        switch self {
        case .eventoELembrete, .lembreteEMensagem: "multi_tool"
        case .ligarContato, .mensagemContato, .lembreteEFaceTimeContato: "sequential"
        default: "single_tool"
        }
    }

    var expected: [String] {
        switch self {
        case .ligar: ["ligar"]
        case .faceTime: ["ligarFaceTime"]
        case .email: ["enviarEmail"]
        case .mensagem: ["enviarMensagem"]
        case .calendario: ["criarEvento"]
        case .lembrete: ["criarLembrete"]
        case .mapas: ["abrirRota"]
        case .safari: ["abrirSafari"]
        case .eventoELembrete: ["criarEvento", "criarLembrete"]
        case .lembreteEMensagem: ["criarLembrete", "enviarMensagem"]
        case .ligarContato: ["buscarContato", "ligar"]
        case .mensagemContato: ["buscarContato", "enviarMensagem"]
        case .lembreteEFaceTimeContato: ["buscarContato", "criarLembrete", "ligarFaceTime"]
        }
    }

    /// O número só aparece na resposta de buscarContato; a ação certa prova que o passo anterior foi usado.
    var contactNumber: String? {
        switch self {
        case .ligarContato: Contacts.numbers["Ana"]
        case .mensagemContato: Contacts.numbers["Bruno"]
        case .lembreteEFaceTimeContato: Contacts.numbers["Carla"]
        default: nil
        }
    }

    /// Nil quando a trajetória bate; senão o motivo da falha.
    func grade(_ trace: [String]) -> String? {
        let names = trace.map { String($0.prefix { $0 != ":" }) }
        guard names.sorted() == expected.sorted() else {
            return "Esperava \(expected.joined(separator: ", ")); chamou \(names.joined(separator: ", "))."
        }
        if let number = contactNumber,
           !trace.contains(where: { !$0.hasPrefix("buscarContato") && $0.contains(number) }) {
            return "A ação não usou o número do contato (\(number))."
        }
        return nil
    }

    static func selfCheck() {
        precondition(PhoneTask.ligar.grade(["ligar: tel:+15550100"]) == nil)
        precondition(PhoneTask.ligar.grade(["ligar: tel:+15550100", "ligar: tel:+15550100"]) != nil)
        precondition(PhoneTask.eventoELembrete.grade(["criarLembrete: x", "criarEvento: y"]) == nil)
        precondition(PhoneTask.ligarContato.grade(["buscarContato: Ana: +15550100", "ligar: tel:+15550100"]) == nil)
        precondition(PhoneTask.ligarContato.grade(["buscarContato: Ana: +15550100", "ligar: tel:+15550199"]) != nil)
    }

    var title: String {
        switch self {
        case .ligar: "Ligar"
        case .faceTime: "FaceTime"
        case .email: "E-mail"
        case .mensagem: "Mensagem"
        case .calendario: "Calendário"
        case .lembrete: "Lembrete"
        case .mapas: "Mapas"
        case .safari: "Safari"
        case .eventoELembrete: "Evento + lembrete"
        case .lembreteEMensagem: "Lembrete + mensagem"
        case .ligarContato: "Contato → ligar"
        case .mensagemContato: "Contato → mensagem"
        case .lembreteEFaceTimeContato: "Contato → lembrete → FaceTime"
        }
    }

    var prompt: String {
        switch self {
        case .ligar: "Ligue para +15550100."
        case .faceTime: "Faça uma chamada de FaceTime áudio para +15550102."
        case .email: "Envie um e-mail para test@example.com com assunto Teste iPhone e corpo Olá, isto é um teste."
        case .mensagem: "Envie uma mensagem para +15550101 dizendo Olá, isto é um teste."
        case .calendario: "Crie um evento no calendário chamado Teste MobileLLMBench daqui a 60 minutos."
        case .lembrete: "Crie um lembrete chamado Teste MobileLLMBench para daqui a 60 minutos."
        case .mapas: "Abra uma rota de carro no Mapas até Apple Park, Cupertino."
        case .safari: "Abra a página https://www.apple.com no Safari."
        case .eventoELembrete:
            "Crie um evento chamado Reunião TCC daqui a 60 minutos e um lembrete chamado Levar slides para daqui a 30 minutos."
        case .lembreteEMensagem:
            "Crie um lembrete chamado Comprar pão para daqui a 30 minutos e envie uma mensagem para +15550101 dizendo Vou comprar o pão."
        case .ligarContato: "Ligue para a Ana."
        case .mensagemContato: "Envie uma mensagem para o Bruno dizendo Chego em 10 minutos."
        case .lembreteEFaceTimeContato:
            "Crie um lembrete chamado Retornar Carla para daqui a 30 minutos e depois faça uma chamada de FaceTime áudio para a Carla."
        }
    }
}

/// Nomes estáveis das ferramentas do harness. A Fase 2 unifica isso com os schemas.
enum PhoneTool {
    static let names: Set<String> = [
        "ligar", "ligarFaceTime", "enviarEmail", "enviarMensagem",
        "criarEvento", "criarLembrete", "abrirRota", "abrirSafari", "buscarContato",
    ]
}

struct BenchmarkResult: Codable {
    var id = UUID()
    var timestamp = Date()
    var device: String
    var osVersion: String
    var backend: String
    var model: String
    var experiment: String
    var taskKind: String?
    var strategy: String
    var plan: String?
    var promptCharacters: Int
    var inputTokens: Int?
    var outputTokens: Int?
    var modelLoadMs: Double?
    var ttftMs: Double?
    var firstTextMs: Double?
    var inferenceMs: Double?
    /// Wall clock do `execute`, incluindo carga do modelo quando houve. Null se a tentativa não começou.
    var totalMs: Double?
    var prefillTokensPerSecond: Double?
    var decodeTokensPerSecond: Double?
    var memoryBeforeMB: Double?
    var memoryAfterMB: Double?
    var thermalBefore: String
    var thermalAfter = "unknown"
    var batteryBefore: Float?
    var batteryAfter: Float?
    var toolCallCount: Int?
    var toolExecutionMs: Double?
    var toolTrace: [String]?
    var toolCallingMode: String?
    var stopReason: String?
    var thinkingTokens: Int?
    var exitChecks: Int?
    var exitedEarly: Bool?
    var response = ""
    var success = false
    var error: String?

    // Protocolo 2. Campos antigos acima continuam com o mesmo significado.
    var protocolVersion: String?
    var appVersion: String?
    var mlxSwiftLM: String?
    var taskId: String?
    var runIndex: Int?
    var repetitions: Int?
    var phase: String?
    var startKind: String?
    var orderSeed: String?
    var sampling: String?
    var temperature: Double?
    var inferenceSeed: String?
    /// MLX ignora seed com temperature 0; o caminho de budget usa ArgMaxSampler. False registra isso.
    var seedAffectsSampling: Bool?
    var thermalGate: String?
    var thermalWaitMs: Double?
    var countsTowardAnalysis: Bool?
    var totalLatencyMs: Double?
    var timeToFirstTokenMs: Double?
    var timeToFirstToolCallMs: Double?
    var prefillLatencyMs: Double?
    var decodeLatencyMs: Double?
    var repeatedPrefillMs: Double?
    var planLatencyMs: Double?
    var generatedTokens: Int?
    var tokensPerSecond: Double?
    var memoryUsageMB: Double?
    var thermalStateBefore: String?
    var thermalStateAfter: String?
    var batteryLevelBefore: Float?
    var batteryLevelAfter: Float?
    var taskSuccess: Bool?
    var toolSelectionCorrect: Bool?
    var toolArgumentsCorrect: Bool?
    var toolSequenceCorrect: Bool?
    var duplicateToolCalls: Int?
    var invalidToolCalls: Int?
    /// inference, execution, grade, no_tool, thermal ou cancelled. Null quando houve acerto.
    var failureKind: String?
    var executionMode: String?
    var dataset: String?
    var toolCalls: [ToolCallRecord]?
    var completionCorrect: Bool?
    var selectionReason: String?
    var argumentsReason: String?
    var sequenceReason: String?
    var completionReason: String?
    /// Identidade do protocolo. Ausente no JSON antigo.
    var protocolId: String?
    var datasetId: String?
    var taskSetId: String?
    var modelId: String?
    var strategyId: String?
    var evaluationVersion: String?
    /// Overhead do `AdaptiveRouter` (ms). Null quando a estratégia não é adaptativa.
    var routerDecisionMs: Double?
    var routerReason: String?
    /// Eventos do `BudgetController` (piloto de inferência adaptativa).
    var controllerTrace: [String]?
    var tokenBudgetCap: Int?
    var planCount: Int?
    /// BFCL AST: `[ToolCall]` nativos do parser MLX, em JSON sem perda de tipo.
    var astCalls: String?
    var peakMemoryMB: Double?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, device, osVersion, backend, model, experiment, taskKind, strategy, plan, promptCharacters
        case inputTokens, outputTokens, modelLoadMs, ttftMs, firstTextMs, inferenceMs, totalMs
        case prefillTokensPerSecond, decodeTokensPerSecond, memoryBeforeMB, memoryAfterMB
        case thermalBefore, thermalAfter, batteryBefore, batteryAfter
        case toolCallCount, toolExecutionMs, toolTrace, toolCallingMode, stopReason
        case thinkingTokens, exitChecks, exitedEarly
        case response, success, error
        case protocolVersion, appVersion, mlxSwiftLM, taskId, runIndex, repetitions, phase, startKind, orderSeed
        case sampling, temperature, inferenceSeed, seedAffectsSampling, thermalGate, thermalWaitMs, countsTowardAnalysis
        case totalLatencyMs, timeToFirstTokenMs, timeToFirstToolCallMs, prefillLatencyMs, decodeLatencyMs
        case repeatedPrefillMs, planLatencyMs, generatedTokens, tokensPerSecond, memoryUsageMB
        case thermalStateBefore, thermalStateAfter, batteryLevelBefore, batteryLevelAfter
        case taskSuccess, toolSelectionCorrect, toolArgumentsCorrect, toolSequenceCorrect
        case duplicateToolCalls, invalidToolCalls, failureKind
        case executionMode, dataset, toolCalls, completionCorrect
        case selectionReason, argumentsReason, sequenceReason, completionReason
        case protocolId, datasetId, taskSetId, modelId, strategyId, evaluationVersion
        case routerDecisionMs, routerReason, controllerTrace, tokenBudgetCap, planCount
        case astCalls, peakMemoryMB
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(device, forKey: .device)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(backend, forKey: .backend)
        try c.encode(model, forKey: .model)
        try c.encode(experiment, forKey: .experiment)
        try c.encode(taskKind, forKey: .taskKind)
        try c.encode(strategy, forKey: .strategy)
        try c.encode(plan, forKey: .plan)
        try c.encode(promptCharacters, forKey: .promptCharacters)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(modelLoadMs, forKey: .modelLoadMs)
        try c.encode(ttftMs, forKey: .ttftMs)
        try c.encode(firstTextMs, forKey: .firstTextMs)
        try c.encode(inferenceMs, forKey: .inferenceMs)
        try c.encode(totalMs, forKey: .totalMs)
        try c.encode(prefillTokensPerSecond, forKey: .prefillTokensPerSecond)
        try c.encode(decodeTokensPerSecond, forKey: .decodeTokensPerSecond)
        try c.encode(memoryBeforeMB, forKey: .memoryBeforeMB)
        try c.encode(memoryAfterMB, forKey: .memoryAfterMB)
        try c.encode(thermalBefore, forKey: .thermalBefore)
        try c.encode(thermalAfter, forKey: .thermalAfter)
        try c.encode(batteryBefore, forKey: .batteryBefore)
        try c.encode(batteryAfter, forKey: .batteryAfter)
        try c.encode(toolCallCount, forKey: .toolCallCount)
        try c.encode(toolExecutionMs, forKey: .toolExecutionMs)
        try c.encode(toolTrace, forKey: .toolTrace)
        try c.encode(toolCallingMode, forKey: .toolCallingMode)
        try c.encode(stopReason, forKey: .stopReason)
        try c.encode(thinkingTokens, forKey: .thinkingTokens)
        try c.encode(exitChecks, forKey: .exitChecks)
        try c.encode(exitedEarly, forKey: .exitedEarly)
        try c.encode(response, forKey: .response)
        try c.encode(success, forKey: .success)
        try c.encode(error, forKey: .error)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(mlxSwiftLM, forKey: .mlxSwiftLM)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(runIndex, forKey: .runIndex)
        try c.encode(repetitions, forKey: .repetitions)
        try c.encode(phase, forKey: .phase)
        try c.encode(startKind, forKey: .startKind)
        try c.encode(orderSeed, forKey: .orderSeed)
        try c.encode(sampling, forKey: .sampling)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(inferenceSeed, forKey: .inferenceSeed)
        try c.encode(seedAffectsSampling, forKey: .seedAffectsSampling)
        try c.encode(thermalGate, forKey: .thermalGate)
        try c.encode(thermalWaitMs, forKey: .thermalWaitMs)
        try c.encode(countsTowardAnalysis, forKey: .countsTowardAnalysis)
        try c.encode(totalLatencyMs, forKey: .totalLatencyMs)
        try c.encode(timeToFirstTokenMs, forKey: .timeToFirstTokenMs)
        try c.encode(timeToFirstToolCallMs, forKey: .timeToFirstToolCallMs)
        try c.encode(prefillLatencyMs, forKey: .prefillLatencyMs)
        try c.encode(decodeLatencyMs, forKey: .decodeLatencyMs)
        try c.encode(repeatedPrefillMs, forKey: .repeatedPrefillMs)
        try c.encode(planLatencyMs, forKey: .planLatencyMs)
        try c.encode(generatedTokens, forKey: .generatedTokens)
        try c.encode(tokensPerSecond, forKey: .tokensPerSecond)
        try c.encode(memoryUsageMB, forKey: .memoryUsageMB)
        try c.encode(thermalStateBefore, forKey: .thermalStateBefore)
        try c.encode(thermalStateAfter, forKey: .thermalStateAfter)
        try c.encode(batteryLevelBefore, forKey: .batteryLevelBefore)
        try c.encode(batteryLevelAfter, forKey: .batteryLevelAfter)
        try c.encode(taskSuccess, forKey: .taskSuccess)
        try c.encode(toolSelectionCorrect, forKey: .toolSelectionCorrect)
        try c.encode(toolArgumentsCorrect, forKey: .toolArgumentsCorrect)
        try c.encode(toolSequenceCorrect, forKey: .toolSequenceCorrect)
        try c.encode(duplicateToolCalls, forKey: .duplicateToolCalls)
        try c.encode(invalidToolCalls, forKey: .invalidToolCalls)
        try c.encode(failureKind, forKey: .failureKind)
        try c.encode(executionMode, forKey: .executionMode)
        try c.encode(dataset, forKey: .dataset)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encode(completionCorrect, forKey: .completionCorrect)
        try c.encode(selectionReason, forKey: .selectionReason)
        try c.encode(argumentsReason, forKey: .argumentsReason)
        try c.encode(sequenceReason, forKey: .sequenceReason)
        try c.encode(completionReason, forKey: .completionReason)
        try c.encode(protocolId, forKey: .protocolId)
        try c.encode(datasetId, forKey: .datasetId)
        try c.encode(taskSetId, forKey: .taskSetId)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(strategyId, forKey: .strategyId)
        try c.encode(evaluationVersion, forKey: .evaluationVersion)
        try c.encode(routerDecisionMs, forKey: .routerDecisionMs)
        try c.encode(routerReason, forKey: .routerReason)
        try c.encode(controllerTrace, forKey: .controllerTrace)
        try c.encode(tokenBudgetCap, forKey: .tokenBudgetCap)
        try c.encode(planCount, forKey: .planCount)
        try c.encode(astCalls, forKey: .astCalls)
        try c.encode(peakMemoryMB, forKey: .peakMemoryMB)
    }
}

extension BenchmarkResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            device: try c.decode(String.self, forKey: .device),
            osVersion: try c.decode(String.self, forKey: .osVersion),
            backend: try c.decode(String.self, forKey: .backend),
            model: try c.decode(String.self, forKey: .model),
            experiment: try c.decode(String.self, forKey: .experiment),
            strategy: try c.decode(String.self, forKey: .strategy),
            promptCharacters: try c.decode(Int.self, forKey: .promptCharacters),
            thermalBefore: try c.decode(String.self, forKey: .thermalBefore)
        )
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? timestamp
        taskKind = try c.decodeIfPresent(String.self, forKey: .taskKind)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        modelLoadMs = try c.decodeIfPresent(Double.self, forKey: .modelLoadMs)
        ttftMs = try c.decodeIfPresent(Double.self, forKey: .ttftMs)
        firstTextMs = try c.decodeIfPresent(Double.self, forKey: .firstTextMs)
        inferenceMs = try c.decodeIfPresent(Double.self, forKey: .inferenceMs)
        totalMs = try c.decodeIfPresent(Double.self, forKey: .totalMs)
        prefillTokensPerSecond = try c.decodeIfPresent(Double.self, forKey: .prefillTokensPerSecond)
        decodeTokensPerSecond = try c.decodeIfPresent(Double.self, forKey: .decodeTokensPerSecond)
        memoryBeforeMB = try c.decodeIfPresent(Double.self, forKey: .memoryBeforeMB)
        memoryAfterMB = try c.decodeIfPresent(Double.self, forKey: .memoryAfterMB)
        thermalAfter = try c.decodeIfPresent(String.self, forKey: .thermalAfter) ?? thermalAfter
        batteryBefore = try c.decodeIfPresent(Float.self, forKey: .batteryBefore)
        batteryAfter = try c.decodeIfPresent(Float.self, forKey: .batteryAfter)
        toolCallCount = try c.decodeIfPresent(Int.self, forKey: .toolCallCount)
        toolExecutionMs = try c.decodeIfPresent(Double.self, forKey: .toolExecutionMs)
        toolTrace = try c.decodeIfPresent([String].self, forKey: .toolTrace)
        toolCallingMode = try c.decodeIfPresent(String.self, forKey: .toolCallingMode)
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        thinkingTokens = try c.decodeIfPresent(Int.self, forKey: .thinkingTokens)
        exitChecks = try c.decodeIfPresent(Int.self, forKey: .exitChecks)
        exitedEarly = try c.decodeIfPresent(Bool.self, forKey: .exitedEarly)
        response = try c.decodeIfPresent(String.self, forKey: .response) ?? response
        success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? success
        error = try c.decodeIfPresent(String.self, forKey: .error)
        protocolVersion = try c.decodeIfPresent(String.self, forKey: .protocolVersion)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        mlxSwiftLM = try c.decodeIfPresent(String.self, forKey: .mlxSwiftLM)
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        runIndex = try c.decodeIfPresent(Int.self, forKey: .runIndex)
        repetitions = try c.decodeIfPresent(Int.self, forKey: .repetitions)
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        startKind = try c.decodeIfPresent(String.self, forKey: .startKind)
        orderSeed = try c.decodeIfPresent(String.self, forKey: .orderSeed)
        sampling = try c.decodeIfPresent(String.self, forKey: .sampling)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        inferenceSeed = try c.decodeIfPresent(String.self, forKey: .inferenceSeed)
        seedAffectsSampling = try c.decodeIfPresent(Bool.self, forKey: .seedAffectsSampling)
        thermalGate = try c.decodeIfPresent(String.self, forKey: .thermalGate)
        thermalWaitMs = try c.decodeIfPresent(Double.self, forKey: .thermalWaitMs)
        countsTowardAnalysis = try c.decodeIfPresent(Bool.self, forKey: .countsTowardAnalysis)
        totalLatencyMs = try c.decodeIfPresent(Double.self, forKey: .totalLatencyMs)
        timeToFirstTokenMs = try c.decodeIfPresent(Double.self, forKey: .timeToFirstTokenMs)
        timeToFirstToolCallMs = try c.decodeIfPresent(Double.self, forKey: .timeToFirstToolCallMs)
        prefillLatencyMs = try c.decodeIfPresent(Double.self, forKey: .prefillLatencyMs)
        decodeLatencyMs = try c.decodeIfPresent(Double.self, forKey: .decodeLatencyMs)
        repeatedPrefillMs = try c.decodeIfPresent(Double.self, forKey: .repeatedPrefillMs)
        planLatencyMs = try c.decodeIfPresent(Double.self, forKey: .planLatencyMs)
        generatedTokens = try c.decodeIfPresent(Int.self, forKey: .generatedTokens)
        tokensPerSecond = try c.decodeIfPresent(Double.self, forKey: .tokensPerSecond)
        memoryUsageMB = try c.decodeIfPresent(Double.self, forKey: .memoryUsageMB)
        thermalStateBefore = try c.decodeIfPresent(String.self, forKey: .thermalStateBefore)
        thermalStateAfter = try c.decodeIfPresent(String.self, forKey: .thermalStateAfter)
        batteryLevelBefore = try c.decodeIfPresent(Float.self, forKey: .batteryLevelBefore)
        batteryLevelAfter = try c.decodeIfPresent(Float.self, forKey: .batteryLevelAfter)
        taskSuccess = try c.decodeIfPresent(Bool.self, forKey: .taskSuccess)
        toolSelectionCorrect = try c.decodeIfPresent(Bool.self, forKey: .toolSelectionCorrect)
        toolArgumentsCorrect = try c.decodeIfPresent(Bool.self, forKey: .toolArgumentsCorrect)
        toolSequenceCorrect = try c.decodeIfPresent(Bool.self, forKey: .toolSequenceCorrect)
        duplicateToolCalls = try c.decodeIfPresent(Int.self, forKey: .duplicateToolCalls)
        invalidToolCalls = try c.decodeIfPresent(Int.self, forKey: .invalidToolCalls)
        failureKind = try c.decodeIfPresent(String.self, forKey: .failureKind)
        executionMode = try c.decodeIfPresent(String.self, forKey: .executionMode)
        dataset = try c.decodeIfPresent(String.self, forKey: .dataset)
        toolCalls = try c.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls)
        completionCorrect = try c.decodeIfPresent(Bool.self, forKey: .completionCorrect)
        selectionReason = try c.decodeIfPresent(String.self, forKey: .selectionReason)
        argumentsReason = try c.decodeIfPresent(String.self, forKey: .argumentsReason)
        sequenceReason = try c.decodeIfPresent(String.self, forKey: .sequenceReason)
        completionReason = try c.decodeIfPresent(String.self, forKey: .completionReason)
        protocolId = try c.decodeIfPresent(String.self, forKey: .protocolId)
        datasetId = try c.decodeIfPresent(String.self, forKey: .datasetId)
        taskSetId = try c.decodeIfPresent(String.self, forKey: .taskSetId)
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        strategyId = try c.decodeIfPresent(String.self, forKey: .strategyId)
        evaluationVersion = try c.decodeIfPresent(String.self, forKey: .evaluationVersion)
        routerDecisionMs = try c.decodeIfPresent(Double.self, forKey: .routerDecisionMs)
        routerReason = try c.decodeIfPresent(String.self, forKey: .routerReason)
        controllerTrace = try c.decodeIfPresent([String].self, forKey: .controllerTrace)
        tokenBudgetCap = try c.decodeIfPresent(Int.self, forKey: .tokenBudgetCap)
        planCount = try c.decodeIfPresent(Int.self, forKey: .planCount)
        astCalls = try c.decodeIfPresent(String.self, forKey: .astCalls)
        peakMemoryMB = try c.decodeIfPresent(Double.self, forKey: .peakMemoryMB)
    }
}

enum BenchError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}
