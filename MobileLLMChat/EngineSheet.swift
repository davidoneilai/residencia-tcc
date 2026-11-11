import SwiftUI

/// "Motor": modelo, raciocínio e estratégia. É a parte do produto que vem do bench.
struct EngineSheet: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        section("Modelo", "Roda no aparelho. Nada sai do iPhone, exceto o que você manda pelas ferramentas.") {
                            VStack(spacing: 10) {
                                ForEach(Agent.chatModels) { ModelCard(store: store, agent: $0) }
                            }
                        }
                        section("Raciocínio", store.agent.thinkingSwitch
                                ? "O modelo pode pensar antes de responder. No estudo, pensar só compensou no Qwen 3.5."
                                : "\(store.agent.chatName) não expõe raciocínio; esta escolha não muda nada nele.") {
                            ModePicker(options: ThinkingMode.allCases, selection: Bindable(store).thinking,
                                       title: \.title, blurb: \.blurb, enabled: store.agent.thinkingSwitch && !store.generating)
                        }
                        section("Estratégia", "Como o modelo conduz as rodadas de ferramenta. Direto foi a melhor política fixa nos três modelos do bench.") {
                            ModePicker(options: StrategyMode.allCases, selection: Bindable(store).strategy,
                                       title: \.title, blurb: \.blurb, enabled: !store.generating)
                        }
                        if let error = store.modelError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Motor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("OK") { dismiss() }.fontWeight(.semibold) }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, _ hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.title(22))
            content()
            Text(hint).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct ModelCard: View {
    let store: ChatStore
    let agent: Agent

    private var selected: Bool { store.agent == agent }
    private var downloaded: Bool { store.isDownloaded(agent) }
    private var progress: Double? { store.downloads[agent] }

    var body: some View {
        Button { tap() } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.08)))
                    Image(systemName: agent == .apple ? "apple.logo" : "cpu")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(agent.chatName).font(.system(.body, design: .rounded, weight: .semibold))
                        if agent.recommended {
                            Text("Recomendado").font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.warm, in: Capsule()).foregroundStyle(.white)
                        }
                        if store.loadedAgent == agent {
                            Text("na GPU").font(.caption2.weight(.bold)).foregroundStyle(Theme.cyan)
                        }
                    }
                    Text(agent.chatBlurb).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Text(status).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                trailing
            }
            .glassCard(radius: 18)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(store.generating)
        .contextMenu {
            if downloaded, agent != .apple {
                Button("Apagar do aparelho (\(ModelLibrary.sizeText(agent)))", systemImage: "trash", role: .destructive) { store.deleteModel(agent) }
            }
        }
        .accessibilityIdentifier("engine.model.\(agent.rawValue)")
    }

    private var status: String {
        if let progress { return "Baixando \(Int(progress * 100))%" }
        if agent == .apple { return "Pronto · no sistema" }
        return downloaded ? "No aparelho · \(ModelLibrary.sizeText(agent))" : "Toque para baixar · \(ModelLibrary.sizeText(agent))"
    }

    @ViewBuilder private var trailing: some View {
        if let progress {
            ProgressView(value: progress).progressViewStyle(.circular).tint(Theme.cyan)
        } else if selected {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.cyan).font(.title3)
        } else if !downloaded {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).font(.title3)
        }
    }

    private func tap() {
        if agent == .apple || downloaded { store.agent = agent } else { store.download(agent) }
    }
}

private struct ModePicker<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: KeyPath<Option, String>
    let blurb: KeyPath<Option, String>
    var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    Button { selection = option } label: {
                        Text(option[keyPath: title])
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(option == selection ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.08)), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(selection[keyPath: blurb]).font(.footnote).foregroundStyle(.secondary)
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}
