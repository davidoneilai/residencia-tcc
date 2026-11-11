import Foundation

// Motor de inferência escolhido pelo usuário: modelo, raciocínio e estratégia.
// Tudo persistido em UserDefaults; nada aqui roda o modelo.

/// Raciocínio (`enable_thinking`). `auto` usa a regra congelada do BFCL Non-Live:
/// pedido com `NonLiveRouter.threshold` code points ou mais pensa; curto não pensa.
enum ThinkingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off, auto, on
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Desligado"
        case .auto: "Auto"
        case .on: "Ligado"
        }
    }

    var blurb: String {
        switch self {
        case .off: "Responde direto. Mais rápido."
        case .auto: "Pensa só em pedidos longos ou compostos."
        case .on: "Pensa antes de agir. Mais lento, mais cuidadoso."
        }
    }

    func resolve(prompt: String, agent: Agent) -> (thinking: Bool, reason: String) {
        guard agent.thinkingSwitch else { return (false, "no_thinking_switch") }
        switch self {
        case .off: return (false, "think_off")
        case .on: return (true, "think_on")
        case .auto:
            let long = prompt.unicodeScalars.count >= NonLiveRouter.threshold
            return (long, long ? "think_auto_long" : "think_auto_short")
        }
    }
}

/// Estratégia de aceleração (como o modelo conduz as rodadas de ferramenta).
enum StrategyMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case direct, planAct, auto
    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Direto"
        case .planAct: "Plano e ação"
        case .auto: "Adaptativo"
        }
    }

    var blurb: String {
        switch self {
        case .direct: "Uma passada: age e responde. Melhor política fixa no estudo."
        case .planAct: "Planeja em 3 frases antes de agir. Útil em pedidos encadeados."
        case .auto: "Escolhe por pedido: encadeado ou longo planeja, o resto vai direto."
        }
    }

    var policy: any InferencePolicy {
        switch self {
        case .direct: FixedPolicy(strategy: .direct)
        case .planAct: FixedPolicy(strategy: .planAct)
        case .auto: ChatHeuristicPolicy()
        }
    }
}

enum EnginePreferences {
    nonisolated(unsafe) static var defaults = UserDefaults.standard
    static let agentKey = "engine.agent"
    static let thinkingKey = "engine.thinking"
    static let strategyKey = "engine.strategy"

    static var agent: Agent {
        get { Agent(rawValue: defaults.string(forKey: agentKey) ?? "").flatMap { Agent.chatModels.contains($0) ? $0 : nil } ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: agentKey) }
    }
    static var thinking: ThinkingMode {
        get { ThinkingMode(rawValue: defaults.string(forKey: thinkingKey) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: thinkingKey) }
    }
    static var strategy: StrategyMode {
        get { StrategyMode(rawValue: defaults.string(forKey: strategyKey) ?? "") ?? .direct }
        set { defaults.set(newValue.rawValue, forKey: strategyKey) }
    }
}

extension Agent {
    /// Ordem da vitrine: o da Apple (sem download) e os quatro do estudo SLM × BFCL.
    static let chatModels: [Agent] = [.apple, .qwen35, .gemma4, .lfm25, .minicpm5]

    var chatName: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .qwen35: "Qwen 3.5"
        case .gemma4: "Gemma 4"
        case .lfm25: "LFM 2.5"
        case .lfm3: "LFM 3"
        case .minicpm5: "MiniCPM 5"
        case .qwen: "Qwen 3"
        case .gemma: "Gemma 4 (legado)"
        case .qwen35SFT: "Qwen 3.5 SFT"
        case .minicpm5SFT: "MiniCPM 5 SFT"
        case .xlam2SFT: "xLAM 2 SFT"
        }
    }

    var chatBlurb: String {
        switch self {
        case .apple: "Modelo do sistema. Sem download, privado, imediato."
        case .qwen35: "2B parâmetros. Melhor acerto em ferramentas no nosso estudo; o único em que pensar ajuda."
        case .gemma4: "E2B do Google. Rápido, bom em conversa."
        case .lfm25: "2,6B da Liquid. Sempre pensa; respostas mais lentas."
        case .lfm3: "1,7B da Liquid (2026). Precisa do build com mlx-swift-lm novo."
        case .minicpm5: "2B da OpenBMB. Leve e rápido."
        case .qwen: "1,7B. Primeira geração usada no bench."
        case .gemma: "Mesmo peso do Gemma 4."
        case .qwen35SFT, .minicpm5SFT, .xlam2SFT: "LoRA de SFT agêntico sobre a base 4 bits (pesquisa)."
        }
    }

    /// Tamanho aproximado do download em MB (pesos 4 bits). Quando já está no aparelho, mostramos o real.
    var approximateDownloadMB: Int {
        switch self {
        case .apple: 0
        case .qwen35: 1_300
        case .gemma4: 2_900
        case .lfm25: 1_500
        case .lfm3: 1_000
        case .minicpm5: 1_400
        case .qwen: 1_000
        case .gemma: 2_900
        case .qwen35SFT: 1_350
        case .minicpm5SFT: 1_500
        case .xlam2SFT: 1_900
        }
    }

    var recommended: Bool { self == .qwen35 }
}

/// Estado dos pesos no disco (cache do Hugging Face em Caches/huggingface/hub).
enum ModelLibrary {
    static var hubDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface").appendingPathComponent("hub")
    }

    static func repoDirectory(_ agent: Agent) -> URL {
        hubDirectory.appendingPathComponent("models--" + agent.hubID.replacingOccurrences(of: "/", with: "--"))
    }

    /// Baixado = há pelo menos um `.safetensors` em algum snapshot.
    static func isDownloaded(_ agent: Agent) -> Bool {
        guard agent != .apple else { return true }
        let snapshots = repoDirectory(agent).appendingPathComponent("snapshots")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return false }
        for name in names {
            let folder = snapshots.appendingPathComponent(name)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
               files.contains(where: { $0.hasSuffix(".safetensors") }) {
                return true
            }
        }
        return false
    }

    /// Bytes reais no disco (blobs), ou nil se não baixado.
    static func sizeOnDisk(_ agent: Agent) -> Int64? {
        guard agent != .apple, isDownloaded(agent) else { return nil }
        let blobs = repoDirectory(agent).appendingPathComponent("blobs")
        guard let enumerator = FileManager.default.enumerator(at: blobs, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func delete(_ agent: Agent) throws {
        guard agent != .apple else { return }
        try FileManager.default.removeItem(at: repoDirectory(agent))
    }

    static func sizeText(_ agent: Agent) -> String {
        if agent == .apple { return "no sistema" }
        if let bytes = sizeOnDisk(agent) {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return "~\(String(format: "%.1f", Double(agent.approximateDownloadMB) / 1000)) GB"
    }
}
