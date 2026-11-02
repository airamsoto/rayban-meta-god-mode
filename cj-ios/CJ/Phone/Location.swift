import CoreLocation
import Foundation

/// Where the user is, sent with each conversation so "how long to get home?", "weather here" and nearby places work.
/// Only "while using the app", one fix per conversation; nothing is stored on the phone.
@MainActor
final class Location: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var allowed = false

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        refresh()
    }

    func refresh() {
        let status = manager.authorizationStatus
        allowed = status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func request() { manager.requestWhenInUseAuthorization() }

    /// The current position as the brain expects it ({lat, lon, acc}), or nil (not allowed, or no fix in 4 s).
    func current() async -> [String: Double]? {
        guard allowed else { return nil }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -120 { return Self.json(recent) }
        let fix: CLLocation? = await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 { manager.requestLocation() }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.deliver(nil)
            }
        }
        return fix.map(Self.json)
    }

    private func deliver(_ location: CLLocation?) {
        let all = waiting
        waiting.removeAll()
        all.forEach { $0.resume(returning: location) }
    }

    private static func json(_ l: CLLocation) -> [String: Double] {
        ["lat": l.coordinate.latitude, "lon": l.coordinate.longitude, "acc": l.horizontalAccuracy]
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.deliver(locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.deliver(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
}
