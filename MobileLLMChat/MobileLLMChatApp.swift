import SwiftUI
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct MobileLLMChatApp: App {
    var body: some Scene {
        WindowGroup {
            ChatRootView()
                .onOpenURL { url in
                    // mobilellmchat://atalho-* é só o retorno (x-callback) do app Atalhos.
                    guard url.scheme != "mobilellmchat" else { return }
                    #if canImport(GoogleSignIn)
                    GIDSignIn.sharedInstance.handle(url)
                    #endif
                }
        }
    }
}
