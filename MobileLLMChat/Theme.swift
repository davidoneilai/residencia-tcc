import SwiftUI

/// Identidade visual do chat: fundo escuro com aurora lenta, acento violeta→ciano, vidro nos cartões.
enum Theme {
    static let violet = Color(red: 0.49, green: 0.36, blue: 1.00)
    static let cyan = Color(red: 0.18, green: 0.89, blue: 1.00)
    static let magenta = Color(red: 1.00, green: 0.36, blue: 0.72)
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.07)

    static let accent = LinearGradient(colors: [violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warm = LinearGradient(colors: [magenta, violet], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .rounded) }
}

/// Malha de gradiente que respira devagar. Pausa enquanto o modelo gera para não disputar a GPU.
struct AuroraBackground: View {
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / 9
            let drift = Float(sin(t)) * 0.12
            let swell = Float(cos(t * 0.7)) * 0.10
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + drift, 0.45 + swell], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Theme.ink, Theme.violet.opacity(0.55), Theme.ink,
                    Theme.cyan.opacity(0.25), Theme.ink, Theme.magenta.opacity(0.30),
                    Theme.ink, Theme.ink, Theme.violet.opacity(0.35),
                ])
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Cartão de vidro com borda sutil.
    func glassCard(radius: CGFloat = 22) -> some View {
        padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}
