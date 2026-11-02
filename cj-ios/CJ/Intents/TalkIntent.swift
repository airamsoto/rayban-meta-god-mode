import AppIntents
import Foundation

/// "Hablar con CJ" from Siri, the Shortcuts app, the Action Button or a Back Tap: opens CJ and starts a real-time
/// conversation. iOS doesn't let an app listen for its own wake word in the background the way Android does, so this
/// is the hands-free way in.
struct TalkToCJIntent: AppIntent {
    static var title: LocalizedStringResource = "Hablar con CJ"
    static var description = IntentDescription("Abre CJ y empieza una conversación por las gafas.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.talkRequested = true
        return .result()
    }
}

struct CJShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToCJIntent(),
                    phrases: ["Hablar con \(.applicationName)", "Habla con \(.applicationName)",
                              "Talk to \(.applicationName)"],
                    shortTitle: "Hablar con CJ",
                    systemImageName: "eyeglasses")
    }
}

/// Hands a request from an App Intent to the UI.
@MainActor
final class IntentRouter: ObservableObject {
    static let shared = IntentRouter()
    @Published var talkRequested = false
}
