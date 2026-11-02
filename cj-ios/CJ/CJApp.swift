import SwiftUI

/// CJ for iPhone: a hands-free assistant for Ray-Ban Meta glasses, talking to the CJ brain on your Mac.
@main
struct CJApp: App {
    @StateObject private var glasses = Glasses()

    var body: some Scene {
        WindowGroup {
            ContentView(glasses: glasses)
                .task { glasses.configure() }
                // The Meta AI app answers registration and permission requests with a cjglasses:// link.
                .onOpenURL { url in
                    Task { _ = await glasses.handle(url) }
                }
        }
    }
}
