import Foundation
import Observation

/// Um fato durável sobre o usuário ("casa = Rua X, 100"). Fica no aparelho, em Chat/memory.json.
struct UserFact: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var key: String
    var value: String
    var date = Date()

    var line: String { "\(key) = \(value)" }
}

/// Memória entre conversas, sem custo de modelo: os fatos saem de padrões no texto do usuário
/// ("minha casa fica na…", "lembre que…") e entram num bloco curto junto do pedido.
/// O bloco vai no turno do usuário, nunca no system, para o prefixo (system + tools) seguir cacheado.
@MainActor
@Observable
final class UserMemory {
    static let maxFacts = 40
    static let maxBlockCharacters = 400
    static let noteKey = "nota"

    private(set) var facts: [UserFact] = []
    private let url: URL?

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([UserFact].self, from: data) {
            facts = saved
        }
    }

    /// Chaves de lugar: a rota resolve "casa" direto no endereço, sem perguntar nem gastar rodada.
    static let placeKeys: Set<String> = ["casa", "trabalho", "escritorio", "academia", "faculdade", "escola"]

    func set(_ rawKey: String, _ rawValue: String) {
        let key = Self.normalizeKey(rawKey)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        guard !key.isEmpty, !value.isEmpty, value.count <= 160 else { return }
        if key != Self.noteKey { facts.removeAll { $0.key == key } }
        if facts.contains(where: { $0.key == key && $0.value.lowercased() == value.lowercased() }) { return }
        facts.append(UserFact(key: key, value: value))
        if facts.count > Self.maxFacts { facts.removeFirst(facts.count - Self.maxFacts) }
        save()
    }

    func remove(_ id: UUID) {
        facts.removeAll { $0.id == id }
        save()
    }

    func clear() {
        facts = []
        save()
    }

    /// Extrai e grava fatos do texto do usuário. Devolve o que foi gravado.
    @discardableResult
    func absorb(_ prompt: String) -> [UserFact] {
        let before = facts
        for (key, value) in Self.extract(prompt) { set(key, value) }
        return facts.filter { fact in !before.contains(fact) }
    }

    /// "lembre que X" sem mais nada: responde direto, sem rodar o modelo.
    static func isPureNote(_ prompt: String) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.range(of: #"^(?:(?:por favor|ei|oi),?\s*)?(?:lembre-se|lembre|lembra|anota|anote|guarde|guarda)\s+que\s+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Bloco para o prompt. nil quando não há fatos.
    var promptBlock: String? {
        guard !facts.isEmpty else { return nil }
        var parts: [String] = []
        var used = 0
        for fact in facts.reversed() {
            let piece = fact.line
            guard used + piece.count + 2 <= Self.maxBlockCharacters else { break }
            parts.insert(piece, at: 0)
            used += piece.count + 2
        }
        return "[Sobre o usuário: \(parts.joined(separator: "; ")).]"
    }

    /// Endereço gravado para um destino como "casa", "minha casa", "pro trabalho". nil se não há fato.
    func place(for destination: String) -> String? {
        let words = ContactMatch.normalize(destination).split(separator: " ").map(String.init)
            .filter { !Self.fillers.contains($0) }
        guard words.count == 1, let key = words.first, Self.placeKeys.contains(key) else { return nil }
        return facts.last { $0.key == key }?.value
    }

    private static let fillers: Set<String> = ["a", "o", "em", "na", "no", "pra", "pro", "para", "ate", "de", "da", "do", "minha", "meu", "la", "ir", "voltar"]

    // MARK: Extração (pura, testável)

    private static let placePattern = try! NSRegularExpression(
        pattern: #"\b(?:minha|meu)\s+(casa|trabalho|escrit[oó]rio|academia|faculdade|escola)\s+(?:é|e|fica|está|esta)\s+(?:em|na|no|perto d[oa]|em frente (?:a|à|ao))?\s*([^.;!?\n]{3,160})"#,
        options: [.caseInsensitive])
    private static let namePattern = try! NSRegularExpression(
        pattern: #"\b(?:me chamo|meu nome é|meu nome e)\s+([\p{L}][\p{L}' ]{1,60}?)(?=[.,;!?\n]|\s+e\s|$)"#,
        options: [.caseInsensitive])
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"\b(?:minha|meu)\s+(carro|placa|cpf|anivers[aá]rio|time|cidade|endere[cç]o|e-?mail|telefone|celular|empresa|chefe|m[eé]dico|dentista|banco|operadora)\s+(?:é|e|se chama|chama)\s+([^.;!?\n]{2,120})"#,
        options: [.caseInsensitive])
    /// "lembre que X": memória. "me lembra de X" é lembrete (ferramenta), não entra aqui.
    private static let notePattern = try! NSRegularExpression(
        pattern: #"\b(?:lembre-se|lembre|lembra|anota|anote|guarde|guarda)\s+que\s+([^\n]{3,160})"#,
        options: [.caseInsensitive])

    static func extract(_ prompt: String, notes: Bool = true) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        let range = NSRange(prompt.startIndex..., in: prompt)
        func scan(_ regex: NSRegularExpression, fixedKey: String? = nil) {
            for match in regex.matches(in: prompt, range: range) {
                // "minha casa fica onde mesmo?" é pergunta, não fato.
                if let whole = Range(match.range, in: prompt), whole.upperBound < prompt.endIndex,
                   prompt[whole.upperBound] == "?" { continue }
                let key: String
                let valueIndex: Int
                if let fixedKey {
                    key = fixedKey; valueIndex = 1
                } else {
                    guard let keyRange = Range(match.range(at: 1), in: prompt) else { continue }
                    key = normalizeKey(String(prompt[keyRange])); valueIndex = 2
                }
                guard let valueRange = Range(match.range(at: valueIndex), in: prompt) else { continue }
                let value = String(prompt[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                guard !value.isEmpty, !value.contains("?") else { continue }
                // "lembre que meu time é o Sport" já virou time = o Sport; não duplica como nota.
                if fixedKey == noteKey, !extract(value, notes: false).isEmpty { continue }
                out.append((key, value))
            }
        }
        scan(placePattern)
        scan(namePattern, fixedKey: "nome")
        scan(attributePattern)
        if notes { scan(notePattern, fixedKey: noteKey) }
        return out
    }

    static func normalizeKey(_ raw: String) -> String {
        let key = ContactMatch.normalize(raw)
        if key == "e mail" || key == "email" { return "e-mail" }
        return key
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(facts) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
