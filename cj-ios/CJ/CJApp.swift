import SwiftUI
import UserNotifications

/// CJ for iPhone: a hands-free assistant for Ray-Ban Meta glasses, talking to the CJ brain on your Mac.
@main
struct CJApp: App {
    @StateObject private var model = AppModel(glasses: Glasses())

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared  // timer banners while CJ is open
    }

    var body: some Scene {
        WindowGroup {
            HomeView(model: model, live: model.live, glasses: model.glasses, timers: model.timers)
                // The Meta AI app answers registration and permission requests with a cjglasses:// link.
                .onOpenURL { url in
                    // cjglasses://cocina and cjglasses://ajustes open those screens (handy as Shortcuts).
                    switch url.host?.lowercased() {
                    case "cocina", "kitchen": model.showKitchen = true
                    case "ajustes", "settings": model.showSettings = true
                    default: Task { _ = await model.glasses.handle(url) }
                    }
                }
        }
    }
}
