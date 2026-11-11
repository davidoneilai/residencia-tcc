import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// LoRA de SFT agêntico (`davidoneil/agent-sft-*-lora`): PEFT, r=16, α=32, q/k/v/o/gate/up/down, 1 época.
/// Estudo à parte da aceleração em runtime: muda os pesos, não a inferência.
///
/// No iPhone o adaptador é aplicado em runtime sobre a base MLX 4 bits (`QLoRALinear`), sem fundir.
/// O treino foi em bf16 (PEFT LoRA, não QLoRA), então a base quantizada é uma aproximação.
/// Tokenizer: sempre o da base. Template de chat: o do treino (repo do adaptador) ou o da base, por adaptador.
struct SFTAdapter: Sendable, Equatable {
    struct Rename: Sendable, Equatable {
        let from: String
        let to: String
    }

    enum Template: Sendable, Equatable {
        /// `chat_template.jinja` do repo do adaptador (o usado no SFT).
        case training
        /// Template da base; o adaptador roda fora do formato de treino.
        case base
    }

    let adapterID: String
    /// Commit do Hub verificado em 2026-11-06; nunca `main`.
    let adapterRevision: String
    let baseID: String
    let baseRevision: String
    /// Caminho PEFT (sem `base_model.model.`) → caminho do módulo no mlx-swift-lm.
    let renames: [Rename]
    let template: Template
    /// `.json` só consome `<tool_call>{…}</tool_call>`; o XML do MiniCPM5 e a lista do xLAM ficam no texto
    /// e são lidos por `MLXPhoneBackend.recoverToolCalls`.
    let toolCallFormat: ToolCallFormat

    /// Treinado sobre `Qwen/Qwen3.5-2B` com template Hermes `<tool_call>{json}</tool_call>`, não o XML nativo.
    /// O mlx-swift-lm carrega o Qwen3.5 dentro de `language_model.model.layers`; o PEFT salva `model.language_model.layers`.
    /// Smoke no Mac (6 prompts, greedy): template do treino 4/6 (`"name": <function-get_weather>`, JSON inválido);
    /// template da base com `.xmlFunction` 6/6 (2026-11-07). bf16 com o template do treino também 6/6: o erro do
    /// template do treino vem da base 4 bits. Padrão: template da base.
    static let qwen35 = SFTAdapter(
        adapterID: "davidoneil/agent-sft-qwen35-2b-lora",
        adapterRevision: "d8ede2e382442c3435c7129bdae0a5bf395dd556",
        baseID: "mlx-community/Qwen3.5-2B-4bit",
        baseRevision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
        renames: [.init(from: "model.language_model.", to: "language_model.model.")],
        template: .base, toolCallFormat: .xmlFunction)

    /// Treinado sobre `openbmb/MiniCPM5-2B`; mesmo formato nativo `<function name=…><param …>` da base.
    static let minicpm5 = SFTAdapter(
        adapterID: "davidoneil/agent-sft-minicpm5-2b-lora",
        adapterRevision: "906129558faa95977bde1a528c1ba16d51d320ff",
        baseID: "openbmb/MiniCPM5-2B-MLX",
        baseRevision: "8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3",
        renames: [], template: .training, toolCallFormat: .json)

    /// Treinado sobre `Salesforce/xLAM-2-3b-fc-r`; chamadas como lista JSON nua `[{"name":…,"arguments":…}]`.
    /// Não há base MLX 4 bits no Hub (2026-11-06). `baseID` é provisório: o repo precisa ser convertido
    /// (`mlx_lm.convert -q --q-bits 4 --q-group-size 64`) e publicado antes de rodar no iPhone.
    static let xlam2 = SFTAdapter(
        adapterID: "davidoneil/agent-sft-xlam2-3b-lora",
        adapterRevision: "850f12fb833d2b519ffc1596d899b63cf5334651",
        baseID: "davidoneil/xLAM-2-3b-fc-r-MLX-4bit",
        baseRevision: "main",
        renames: [], template: .training, toolCallFormat: .json)

    static let all: [SFTAdapter] = [.qwen35, .minicpm5, .xlam2]

    /// Pesos do adaptador (44–120 MB) e o template do treino.
    func downloadAdapter(
        _ downloader: any Downloader, progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        try await downloader.download(
            id: adapterID, revision: adapterRevision,
            matching: ["adapter_config.json", "adapter_model.safetensors", "chat_template.jinja"],
            useLatest: false, progressHandler: progress)
    }

    /// Tokenizer da base com o `chat_template.jinja` do adaptador por cima (o `.jinja` vence o do tokenizer_config).
    /// Não usa o tokenizer_config do adaptador: o do Qwen3.5 declara `Qwen3_5Tokenizer`, que o swift-transformers recusa.
    func tokenizerDirectory(_ downloader: any Downloader) async throws -> URL {
        let base = try await downloader.download(
            id: baseID, revision: baseRevision, matching: ["*.json", "*.jinja"],
            useLatest: false, progressHandler: { _ in })
        let adapter = try await downloadAdapter(downloader)
        let manager = FileManager.default
        let directory = URL.cachesDirectory.appending(path: "sft-tokenizers/\(adapterRevision)-\(baseRevision)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // O cache do Hub guarda links simbólicos relativos para `blobs/`: copiar o link deixa um link quebrado
        // (que `fileExists` não vê, e a cópia seguinte falha). Copia o arquivo resolvido e sobrescreve.
        func place(_ source: URL, _ name: String) throws {
            let target = directory.appending(component: name)
            try? manager.removeItem(at: target)
            try manager.copyItem(at: source.resolvingSymlinksInPath(), to: target)
        }
        for name in ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "config.json"] {
            let source = base.appending(component: name)
            guard manager.fileExists(atPath: source.path) else { continue }
            try place(source, name)
        }
        try place(adapter.appending(component: "chat_template.jinja"), "chat_template.jinja")
        return directory
    }

    /// Configuração de carga da base (o LoRA entra depois, em `apply`).
    func configuration(_ downloader: any Downloader) async throws -> ModelConfiguration {
        let tokenizer: TokenizerSource? = template == .training ? .directory(try await tokenizerDirectory(downloader)) : nil
        return ModelConfiguration(
            id: baseID, revision: baseRevision, tokenizerSource: tokenizer,
            extraEOSTokens: ["<|im_end|>"], toolCallFormat: toolCallFormat)
    }

    /// Baixa e aplica o adaptador no modelo já carregado. Devolve o número de tensores LoRA carregados.
    @discardableResult
    func apply(to container: ModelContainer, _ downloader: any Downloader) async throws -> Int {
        let directory = try await downloadAdapter(downloader)
        let renames = renames
        return try await container.perform { context in
            try Self.load(directory: directory, renames: renames, into: context.model)
        }
    }

    /// PEFT → `LoRAContainer` via `LoRAContainer.fromPEFT` (transpõe A/B, escala α/r), renomeia caminhos e
    /// converte para o dtype da base. `load(into:)` verifica `.noUnusedKeys`: caminho errado falha aqui.
    static func load(directory: URL, renames: [Rename], into model: any LanguageModel) throws -> Int {
        let peft = try LoRAContainer.fromPEFT(directory: directory)
        let dtype = computeDType(model)
        var weights = [String: MLXArray]()
        for (key, value) in peft.parameters.flattened() {
            var path = key
            for rename in renames where path.hasPrefix(rename.from) {
                path = rename.to + String(path.dropFirst(rename.from.count))
            }
            weights[path] = value.asType(dtype)
        }
        let lora = LoRAContainer(configuration: peft.configuration, parameters: .unflattened(weights))
        try model.load(adapter: lora)
        return weights.count
    }

    /// dtype das escalas da base quantizada. O PEFT salva f32 e o `QLoRALinear` do pacote soma `scale * z`
    /// sem converter de volta (o mlx-lm Python converte): f32 + bf16 levaria o residual inteiro para f32.
    static func computeDType(_ model: any LanguageModel) -> DType {
        let parameters = model.parameters().flattened()
        if let scales = parameters.first(where: { $0.0.hasSuffix(".scales") }) { return scales.1.dtype }
        if let weight = parameters.first(where: { $0.0.hasSuffix(".weight") && $0.1.ndim == 2 }) { return weight.1.dtype }
        return .float16
    }
}
