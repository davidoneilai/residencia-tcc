import CryptoKit
import Foundation
import MLX
import MLXLMCommon

/// KV de system + tools persistido entre tarefas e sessões (`Application Support/MobileLLMBench/prefix-kv/`).
///
/// Chave = SHA-256 de (formato, modelo@revisão, assinatura do binário, janela de prefill, tokens do prefixo).
/// Os tokens já carregam tokenizer, template, system, tools e `enable_thinking`: mudou qualquer um, muda a chave.
/// Modelo/revisão e binário entram à parte porque o KV depende dos pesos e da numérica dos kernels: qualquer rebuild
/// do app invalida tudo (conservador). Na leitura, metadados e layout do cache são conferidos de novo; qualquer
/// divergência = miss e o prefixo é refeito. Cópia exata do KV calculado (mesmo dtype), não uma aproximação.
struct PrefixStore {
    static let format = "prefix-kv-1"
    /// ~75–110 MB por prefixo (system + tools do BFCL-MT). Com 4, os 12 catálogos do DEV se despejavam entre si
    /// e metade das execuções "quentes" de 2026-11-07 refez o prefixo. 48 cobre 12 catálogos × 4 modelos.
    static let maxFiles = 48

    let directory: URL
    let model: String
    let window: Int

    init(model: String, window: Int = 512) {
        self.model = model
        self.window = window
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MobileLLMBench/prefix-kv", isDirectory: true)
    }

    /// Muda a cada build: data de modificação + tamanho do executável e da dylib de debug.
    static let binary: String = {
        let urls = [Bundle.main.executableURL, Bundle.main.bundleURL.appendingPathComponent("MobileLLMBench.debug.dylib")]
        return urls.compactMap { url -> String? in
            guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.lastPathComponent):\(Int(date)):\(attributes[.size] ?? 0)"
        }.joined(separator: "|")
    }()

    func key(_ tokens: [Int32], layout: [String]) -> String {
        var hash = SHA256()
        hash.update(data: Data("\(Self.format)|\(model)|\(Self.binary)|\(window)|\(layout.joined(separator: ","))".utf8))
        tokens.withUnsafeBufferPointer { hash.update(data: Data(buffer: $0)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func layout(_ cache: [any KVCache]) -> [String] {
        cache.map { $0 is MambaCache ? "mamba" : $0 is KVCacheSimple ? "kv" : String(describing: type(of: $0)) }
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).safetensors") }

    /// Cache restaurado ou nil (miss, arquivo inválido ou layout diferente de `expected`).
    func load(_ tokens: [Int32], expected: [String]) -> [any KVCache]? {
        let key = key(tokens, layout: expected)
        let file = url(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let (cache, meta) = try loadPromptCache(url: file)
            guard meta["format"] == Self.format, meta["model"] == model, meta["binary"] == Self.binary,
                  meta["key"] == key, meta["tokens"] == String(tokens.count), Self.layout(cache) == expected,
                  cache.allSatisfy({ $0.offset == tokens.count || $0 is MambaCache }),
                  meta["slots"] == Self.slots(cache)
            else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            eval(cache.flatMap { $0.state })
            // LRU por data de acesso.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return cache
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    /// Quantos arrays de estado cada camada tem. `MambaCache` guarda até dois slots e o `state` pula os vazios:
    /// Qwen3.5 (atenção linear) usa os dois; as camadas de convolução do LFM2.5/LFM3 só o primeiro.
    static func slots(_ cache: [any KVCache]) -> String {
        cache.map { String($0.state.count) }.joined(separator: ",")
    }

    /// Grava o KV do prefixo; devolve nil se gravou ou o motivo da recusa. Um `MambaCache` sem o 1º slot não volta
    /// pelo `state` (o 2º cairia no lugar do 1º); o número de slots por camada vai no arquivo e é conferido no `load`.
    @discardableResult
    func save(_ tokens: [Int32], cache: [any KVCache]) -> String? {
        let layout = Self.layout(cache)
        guard cache.compactMap({ $0 as? MambaCache }).allSatisfy({ $0[0] != nil }) else {
            return "MambaCache sem o 1º slot"
        }
        let key = key(tokens, layout: layout)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let partial = directory.appendingPathComponent("\(key).partial.safetensors")
            try savePromptCache(url: partial, cache: cache, metadata: [
                "format": Self.format, "model": model, "binary": Self.binary, "key": key,
                "tokens": String(tokens.count), "window": String(window), "slots": Self.slots(cache),
            ])
            try? FileManager.default.removeItem(at: url(key))
            try FileManager.default.moveItem(at: partial, to: url(key))
            prune()
            return nil
        } catch {
            return "\(layout.joined(separator: ",")): \(error)"
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    var files: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".safetensors") }.count) ?? 0
    }

    private func prune() {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = names.filter { $0.pathExtension == "safetensors" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(Self.maxFiles) { try? FileManager.default.removeItem(at: old) }
    }
}
