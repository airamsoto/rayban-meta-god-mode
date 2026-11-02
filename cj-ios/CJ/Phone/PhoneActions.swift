import Foundation
import UIKit
import UserNotifications

/// The things CJ does on the iPhone itself: timers, phone calls. (Port of the timer and call parts of Core.kt.)
@MainActor
final class PhoneActions: ObservableObject {
    struct RunningTimer: Identifiable {
        let id = UUID()
        let label: String
        let ends: Date
    }

    @Published private(set) var timers: [RunningTimer] = []

    /// Says something when a timer goes off while the app is running (wired to the Speaker).
    var announce: ((String) -> Void)?

    /// "Remind me in 10 minutes to check the oven". A notification fires even if the app is closed; while the app
    /// runs, CJ also says it.
    func startTimer(seconds: Int, label: String?) {
        let label = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let timer = RunningTimer(label: label, ends: Date().addingTimeInterval(TimeInterval(seconds)))
        timers.append(timer)
        let text = label.isEmpty ? "Se acabó el tiempo." : "Se acabó el tiempo: \(label)."
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = "CJ"
            content.body = text
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(1, seconds)), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: trigger))
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard let self else { return }
            self.timers.removeAll { $0.id == timer.id }
            self.announce?(text)
        }
    }

    /// "Call this number": the brain already asked and heard yes. iOS shows its own call confirmation too.
    func call(_ number: String) {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else { return }
        UIApplication.shared.open(url)
    }
}

/// Shows notifications (timers) even while CJ is on screen.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
