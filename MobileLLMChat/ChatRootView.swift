import SwiftUI

/// Raiz do app de chat: um único backend MLX compartilhado com o ChatStore.
/// O bench (MobileLLMBench) tem a própria raiz em ContentView.
struct ChatRootView: View {
    @State private var store: ChatStore

    init() {
        _store = State(initialValue: ChatStore(mlx: MLXPhoneBackend()))
    }

    var body: some View {
        ChatView(store: store)
            .preferredColorScheme(.dark)
            .task { UIApplication.shared.isIdleTimerDisabled = true }
    }
}
