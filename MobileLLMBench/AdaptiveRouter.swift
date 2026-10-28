import Foundation

/// Roteador leve, independente do backend. Escolhe a política *antes* da inferência.
/// Features espelham `analysis/adaptive_routing/features.py` (sem rótulos nem avaliador).
enum AdaptiveRouterKind: String, Codable, CaseIterable, Identifiable {
    case heuristic
    case logistic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heuristic: "Heurística"
        case .logistic: "Logística"
        }
    }
}

struct AdaptiveRouteDecision: Equatable {
    var strategy: Strategy
    var decisionMs: Double
    var reason: String
}

enum AdaptiveRouter {
    /// Candidatas compartilhadas entre backends. Thinking budgets ficam de fora (só Qwen).
    static let sharedCandidates: [Strategy] = [.direct, .planAct]

    static func choose(
        prompt: String,
        kind: AdaptiveRouterKind? = nil,
        agent: Agent = .qwen,
        candidates: [Strategy] = sharedCandidates,
        defaultStrategy: Strategy = .direct
    ) -> AdaptiveRouteDecision {
        let kind = kind ?? LaunchAutomation.routerKind
        let started = ProcessInfo.processInfo.systemUptime
        let features = AdaptiveFeatures.extract(prompt)
        let picked: (Strategy, String)
        switch kind {
        case .heuristic:
            picked = heuristic(features, agent: agent, candidates: candidates, defaultStrategy: defaultStrategy)
        case .logistic:
            // Pesos treinados no Qwen; nos demais cai para direct.
            if agent != .qwen {
                picked = (.direct, "logistic_non_qwen_direct")
            } else {
                picked = logistic(features, candidates: candidates, defaultStrategy: defaultStrategy)
            }
        }
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return AdaptiveRouteDecision(strategy: picked.0, decisionMs: ms, reason: picked.1)
    }

    static func resolve(_ strategy: Strategy, prompt: String, agent: Agent) -> AdaptiveRouteDecision? {
        guard strategy == .adaptive else { return nil }
        return choose(prompt: prompt, kind: .heuristic, agent: agent)
    }

    static func selfCheck() {
        // kind explícito: auto-run `router=logistic` não pode quebrar o harness no init.
        let sequential = choose(prompt: "Busque o contato Ana e depois ligue para ela.", kind: .heuristic, agent: .qwen)
        precondition(sequential.strategy == .planAct, sequential.reason)
        let appleSeq = choose(prompt: "Busque o contato Ana e depois ligue para ela.", kind: .heuristic, agent: .apple)
        precondition(appleSeq.strategy == .direct, appleSeq.reason)
        let short = choose(prompt: "Ligue para +15550100.", kind: .heuristic)
        precondition(short.strategy == .direct, short.reason)
        let features = AdaptiveFeatures.extract("Email ana@example.com about Notes.")
        precondition(features.hasEmail)
        precondition(features.charLen > 0)
        let logX = choose(prompt: "x", kind: .logistic)
        precondition(logX.strategy == .direct || logX.strategy == .planAct)
        let logShort = choose(prompt: "Ligue para +15550100.", kind: .logistic)
        precondition(logShort.strategy == .direct, logShort.reason)
    }

    private static func heuristic(
        _ f: AdaptiveFeatures, agent: Agent, candidates: [Strategy], defaultStrategy: Strategy
    ) -> (Strategy, String) {
        let plan = candidates.contains(.planAct) ? Strategy.planAct : (candidates.last ?? defaultStrategy)
        let direct = candidates.contains(.direct) ? Strategy.direct : (candidates.first ?? defaultStrategy)
        if agent != .qwen {
            return (direct, "profile_\(agent.rawValue)_prefer_direct")
        }
        if f.seqCueCount >= 1 || f.contactNameHits >= 1 {
            return (plan, "sequential_or_contact")
        }
        if f.ambigCueCount >= 1 {
            return (direct, "ambiguous_prefer_direct")
        }
        if f.toolCueCount >= 2 && f.wordCount >= 20 {
            return (plan, "long_multi_tool")
        }
        if f.charLen <= 80 && f.toolCueCount <= 1 {
            return (direct, "short_single")
        }
        let fallback = candidates.contains(defaultStrategy) ? defaultStrategy : direct
        return (fallback, "default")
    }

    /// Pesos v2 (custo de sucesso, sessão variance-3rep). Não usar o replay in-sample como generalização.
    private static func logistic(
        _ f: AdaptiveFeatures, candidates: [Strategy], defaultStrategy: Strategy
    ) -> (Strategy, String) {
        let plan = candidates.contains(.planAct) ? Strategy.planAct : defaultStrategy
        let direct = candidates.contains(.direct) ? Strategy.direct : defaultStrategy
        let x = f.standardized(mean: LogisticWeights.mean, std: LogisticWeights.std)
        var z = LogisticWeights.bias
        for (w, xi) in zip(LogisticWeights.weights, x) { z += w * xi }
        let prob = 1.0 / (1.0 + exp(-min(max(z, -30), 30)))
        let choice = prob >= LogisticWeights.threshold ? plan : direct
        return (choice, String(format: "p=%.3f", prob))
    }
}

struct AdaptiveFeatures: Equatable {
    var charLen: Double
    var wordCount: Double
    var digitCount: Double
    var hasPhone: Bool
    var hasEmail: Bool
    var hasURL: Bool
    var isEnglish: Bool
    var contactNameHits: Double
    var toolCueCount: Double
    var seqCueCount: Double
    var multiCueCount: Double
    var ambigCueCount: Double
    var conjunctionCount: Double
    var avgWordLen: Double
    var questionMarks: Double
    var negationCount: Double

    var values: [Double] {
        [
            charLen, wordCount, digitCount,
            hasPhone ? 1 : 0, hasEmail ? 1 : 0, hasURL ? 1 : 0, isEnglish ? 1 : 0,
            contactNameHits, toolCueCount, seqCueCount, multiCueCount, ambigCueCount,
            conjunctionCount, avgWordLen, questionMarks, negationCount
        ]
    }

    func standardized(mean: [Double], std: [Double]) -> [Double] {
        zip(zip(values, mean), std).map { pair, s in
            let (v, m) = pair
            return (v - m) / (s > 1e-9 ? s : 1)
        }
    }

    static func extract(_ prompt: String) -> AdaptiveFeatures {
        let lower = prompt.lowercased()
        let words = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let toolHits = Double(Self.toolCues.values.filter { cues in cues.contains { lower.contains($0) } }.count)
        let pt = ["para", "uma", "com", "daqui", "lembrete", "envie", "crie", "abra"]
            .filter { words.contains($0) }.count
        let en = ["the", "to", "and", "please", "create", "send", "call", "remind"]
            .filter { words.contains($0) }.count
        return AdaptiveFeatures(
            charLen: Double(prompt.count),
            wordCount: Double(words.count),
            digitCount: Double(prompt.filter(\.isNumber).count),
            hasPhone: prompt.range(of: #"\+\d{8,}"#, options: .regularExpression) != nil,
            hasEmail: prompt.range(of: #"[\w.+-]+@[\w.-]+\.\w+"#, options: .regularExpression) != nil,
            hasURL: lower.contains("http://") || lower.contains("https://") || lower.contains("www."),
            isEnglish: en > pt,
            contactNameHits: Double(["ana", "bruno", "carla", "diego", "elena", "felipe", "gina", "hugo"]
                .filter { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }.count),
            toolCueCount: toolHits,
            seqCueCount: Double(Self.seqCues.filter { lower.contains($0) }.count),
            multiCueCount: Double(Self.multiCues.filter { lower.contains($0) }.count),
            ambigCueCount: Double(Self.ambigCues.filter { lower.contains($0) }.count),
            conjunctionCount: Double(
                lower.components(separatedBy: " e ").count - 1
                    + lower.components(separatedBy: " and ").count - 1
                    + prompt.filter { $0 == "," }.count),
            avgWordLen: words.isEmpty ? 0 : Double(words.map(\.count).reduce(0, +)) / Double(words.count),
            questionMarks: Double(prompt.filter { $0 == "?" }.count),
            negationCount: Double(["não ", "nao ", " do not", " don't", "dont ", "never "]
                .filter { lower.contains($0) }.count)
        )
    }

    private static let toolCues: [String: [String]] = [
        "ligar": ["ligue", "ligar", "disque", "chamada", "call ", " phone"],
        "ligarFaceTime": ["facetime", "face time"],
        "enviarEmail": ["e-mail", "email", "mail to", "envie um e-mail", "mande um e-mail"],
        "enviarMensagem": ["mensagem", "mensagens", "sms", "text ", "mande no"],
        "criarEvento": ["evento", "calendário", "calendario", "calendar", "marque "],
        "criarLembrete": ["lembrete", "remind", "lembra"],
        "abrirRota": ["rota", "mapas", "maps", "directions", "navega"],
        "abrirSafari": ["safari", "abra http", "open http", "página", "pagina", "website"],
        "buscarContato": ["contato", "contact", "busque", "procure", "look up", "find "]
    ]
    private static let seqCues = [
        "depois", "em seguida", "então", "entao", "then ", "after ", "and then",
        "use o número", "use the number", "com o número", "with the number",
        "busque o contato", "look up", "find the contact"
    ]
    private static let multiCues = [" e ", " and ", " também", " also ", ",", ";"]
    private static let ambigCues = [
        "ou ", " or ", "talvez", "maybe", "não sei", "not sure", "ambígu", "ambigu",
        "prefiro", "se puder", "if you can", "não faça nada", "do nothing", "aguarde"
    ]
}

/// Pesos do experimento Qwen; atualizados por `analysis/adaptive_routing/export_swift_weights.py`.
enum LogisticWeights {
    static let threshold: Double = 0.5
    static let bias: Double = -1.0453998
    static let mean: [Double] = [57.88, 10.32, 3.64, 0.4, 0, 0, 0.4, 0.24, 1.72, 0.24, 0.48, 0.2, 0.44, 4.4598955, 0.04, 0.08]
    static let std: [Double] = [35.048903, 6.2207395, 4.3532057, 0.48989795, 1, 1, 0.48989795, 0.42708313, 0.66452991, 0.42708313, 0.64, 0.4, 0.57131427, 0.54493085, 0.19595918, 0.2712932]
    static let weights: [Double] = [0.31278191, 0.59263905, 0.96981875, 1.2636542, 0, 0, 0.25540619, 0.16146753, 0.22558272, -0.89939532, -0.92020972, 0.59659931, -0.55752357, -1.7132769, -0.13468755, -0.69682813]
}
