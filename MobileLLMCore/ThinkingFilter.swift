import Foundation

/// Remove blocos `<think>…</think>` (e um `<think>` aberto) do texto visível ao usuário.
/// Compartilhado entre o backend MLX e o coordenador do chat.
enum ThinkingFilter {
    static func hide(_ text: String) -> String {
        var out = text.replacing(/<think>[\s\S]*?<\/think>/, with: "")
        if let open = out.range(of: "<think>") { out = String(out[..<open.lowerBound]) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
