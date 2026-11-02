import Foundation
import MWDATCamera
import MWDATCore
import UIKit

/// A photo from the glasses: the image to show and the JPEG (base64) to send to the brain.
struct Snapshot {
    let image: UIImage
    let jpegBase64: String
}

/// Ray-Ban Meta glasses through Meta's Wearables Device Access Toolkit (port of the Android Glasses.kt).
/// The user links CJ to the glasses once in the Meta AI app (registration; it calls back to cjglasses://), grants
/// camera access there, and CJ then opens a device session on demand to grab one photo from a short camera stream.
/// The glasses' microphone and speakers are ordinary Bluetooth audio (Speaker, Recorder, LiveAudio), not this SDK.
@MainActor
final class Glasses: ObservableObject {
    @Published private(set) var registration: RegistrationState = .unavailable
    @Published private(set) var devices = 0
    @Published private(set) var cameraGranted: Bool?
    @Published private(set) var configureError: String?
    @Published private(set) var connected = false  // the linked glasses are on and connected right now
    @Published private(set) var battery: Int?

    /// Connection and battery of the linked glasses, for the status chip.
    func refreshState() {
        guard configured else { return }
        let device = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
            .first { $0.linkState == .connected } ?? Wearables.shared.devices.first.flatMap { Wearables.shared.deviceForIdentifier($0) }
        connected = device?.linkState == .connected
        battery = device?.batteryLevel
    }

    private var observing = false
    /// The SDK crashes the app if touched before configure(): every entry point checks this first.
    private(set) var configured = false

    /// Once, at app launch. In Developer Mode MetaAppID is "0", so the SDK skips app attestation.
    func configure() {
        guard !configured else { return }
        do {
            try Wearables.configure()
        } catch {
            configureError = "No se pudo iniciar el SDK de Meta: \(error.localizedDescription)"
            return
        }
        configured = true
        guard !observing else { return }
        observing = true
        Task { for await state in Wearables.shared.registrationStateStream() { registration = state } }
        Task { for await ids in Wearables.shared.devicesStream() { devices = ids.count; refreshState() } }
        Task { await refreshCameraPermission() }
    }

    /// The Meta AI app's answer (registration, permissions) arrives as a cjglasses:// URL.
    func handle(_ url: URL) async -> Bool {
        guard configured else { return false }
        let handled = (try? await Wearables.shared.handleUrl(url)) ?? false
        if handled { await refreshCameraPermission() }
        return handled
    }

    /// Opens the Meta AI app to link CJ to the glasses.
    func register() async throws {
        guard configured else { throw GlassesError.notLinked }
        try await Wearables.shared.startRegistration()
    }

    func unregister() async throws {
        guard configured else { return }
        try await Wearables.shared.startUnregistration()
    }

    func refreshCameraPermission() async {
        guard configured, registration == .registered else { cameraGranted = nil; return }
        cameraGranted = (try? await Wearables.shared.checkPermissionStatus(.camera)) == .granted
    }

    /// Opens the Meta AI app to allow CJ to use the glasses' camera.
    func requestCamera() async throws {
        guard configured else { throw GlassesError.notLinked }
        cameraGranted = try await Wearables.shared.requestPermission(.camera) == .granted
    }

    // MARK: - photo

    /// One photo from the glasses. Bluetooth hiccups are common (the glasses are still waking up, the link drops for
    /// a second), so it tries again a couple of times before giving up.
    func takePhoto() async throws -> Snapshot {
        guard configured, registration == .registered else { throw GlassesError.notLinked }
        var last: Error = GlassesError.unavailable
        for attempt in 1...3 {
            do {
                return try await takePhotoOnce()
            } catch let error as GlassesError where error.isFinal {
                throw error
            } catch let error as DeviceSessionError where Self.hopeless(error) {
                throw GlassesError.session(error)
            } catch {
                last = error
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
        throw last
    }

    /// What the SDK knows about each pair of glasses, for the setup screen (helps when a photo fails).
    func describeDevices() -> String {
        guard configured else { return "El SDK de Meta no está iniciado." }
        let all = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
        guard !all.isEmpty else { return "Ninguna. ¿Están vinculadas y encendidas?" }
        return all.map { d in
            let link = d.linkState == .connected ? "conectadas" : d.linkState == .connecting ? "conectando" : "desconectadas"
            let hinge = d.hingeState == .open ? "abiertas" : d.hingeState == .closed ? "plegadas" : "patillas ?"
            let worn = d.donState == .donned ? "puestas" : d.donState == .doffed ? "quitadas" : "uso ?"
            let battery = d.batteryLevel.map { "\($0) %" } ?? "batería ?"
            return "\(d.nameOrId()): \(link), \(hinge), \(worn), \(battery), \(d.compatibility().displayString)"
        }.joined(separator: "\n")
    }

    /// The glasses to use: connected and unfolded. Picked by hand, as on Android, because the SDK's automatic choice
    /// waits for the "worn" signal from the glasses' sensor and fails with "no eligible device" when it hasn't
    /// arrived. Waits a few seconds for the link, and says why when it can't.
    private func connectedGlasses() async throws -> DeviceIdentifier {
        let deadline = Date().addingTimeInterval(8)
        while true {
            let ids = Wearables.shared.devices
            let devices = ids.compactMap { Wearables.shared.deviceForIdentifier($0) }
            if let ready = devices.first(where: { $0.linkState == .connected && $0.hingeState != .closed }) {
                return ready.identifier
            }
            if Date() >= deadline {
                if devices.isEmpty { throw GlassesError.notLinked }
                if devices.contains(where: { $0.hingeState == .closed }) { throw GlassesError.stream(.hingesClosed) }
                throw GlassesError.unavailable
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func takePhotoOnce() async throws -> Snapshot {
        let device = try await connectedGlasses()
        let session = try Wearables.shared.createSession(deviceSelector: SpecificDeviceSelector(device: device))
        defer { session.stop() }
        try session.start()
        let started = await firstMatch(session.stateStream(), timeout: 20) { $0 == .started }
        guard started else { throw GlassesError.unavailable }

        // Low resolution and frame rate: better quality per frame over Bluetooth, and we only want one still.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)
        guard let camera = try session.addCamera(config: config) else { throw GlassesError.unavailable }
        defer { camera.stop() }
        let stream = camera.stream

        let streaming = OneShot<Bool>()
        let photo = OneShot<Data>()
        var tokens: [any AnyListenerToken] = []
        tokens.append(stream.statePublisher.listen { state in
            if state == .streaming { streaming.set(true) }
        })
        tokens.append(stream.photoDataPublisher.listen { data in photo.set(data.data) })
        tokens.append(stream.errorPublisher.listen { error in
            streaming.fail(GlassesError.stream(error))
            photo.fail(GlassesError.stream(error))
        })
        defer { tokens.removeAll() }

        stream.start()
        _ = try await streaming.value(timeout: 10, otherwise: GlassesError.cameraSlow)
        guard stream.capturePhoto(format: .jpeg) else { throw GlassesError.captureNotStarted }
        let jpeg = try await photo.value(timeout: 15, otherwise: GlassesError.captureNotStarted)
        return try Self.encode(jpeg)
    }

    /// Scaled to at most 1280 px (like the Android app) and re-encoded as JPEG for the brain.
    private static func encode(_ data: Data) throws -> Snapshot {
        guard let original = UIImage(data: data) else { throw GlassesError.unreadablePhoto }
        let longest = max(original.size.width, original.size.height)
        let scale = min(1, 1280 / max(longest, 1))
        let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw GlassesError.unreadablePhoto }
        return Snapshot(image: image, jpegBase64: jpeg.base64EncodedString())
    }

    private static func hopeless(_ error: DeviceSessionError) -> Bool {
        switch error {
        case .datAppOnTheGlassesUpdateRequired, .insufficientSDKVersion, .batteryCritical, .thermalCritical,
             .thermalEmergency, .peakPowerShutdown: return true
        default: return false
        }
    }

    /// Waits for the first element of [stream] that matches, or gives up after [timeout] seconds.
    private func firstMatch<T: Sendable>(_ stream: AsyncStream<T>, timeout: TimeInterval,
                                         _ match: @escaping @Sendable (T) -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await value in stream where match(value) { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

enum GlassesError: LocalizedError {
    case notLinked, unavailable, cameraSlow, captureNotStarted, unreadablePhoto
    case session(DeviceSessionError)
    case stream(StreamError)

    /// Retrying won't help.
    var isFinal: Bool {
        switch self {
        case .notLinked: return true
        case .stream(.permissionDenied), .stream(.hingesClosed), .stream(.batteryLow), .stream(.thermalHot): return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notLinked: return "Las gafas no están vinculadas con CJ. Pulsa «Vincular gafas»."
        case .unavailable: return "No encuentro las gafas. Enciéndelas, despliega las patillas y comprueba que están conectadas en la app Meta AI."
        case .cameraSlow: return "La cámara de las gafas tardó demasiado en arrancar."
        case .captureNotStarted: return "Las gafas no hicieron la foto. Inténtalo otra vez."
        case .unreadablePhoto: return "No pude leer la foto de las gafas."
        case .session(.datAppOnTheGlassesUpdateRequired):
            return "Las gafas necesitan una actualización para CJ. Ábrela desde la app Meta AI (Conexiones de apps)."
        case .session(.insufficientSDKVersion): return "Actualiza la app Meta AI y el software de las gafas."
        case .session(.batteryCritical): return "A las gafas les queda muy poca batería."
        case .session(.thermalCritical), .session(.thermalEmergency): return "Las gafas están demasiado calientes. Deja que se enfríen."
        case .session(let error): return "Error de las gafas: \(error.localizedDescription)"
        case .stream(.permissionDenied): return "CJ no tiene permiso para la cámara de las gafas. Pulsa «Permitir cámara»."
        case .stream(.hingesClosed): return "Las gafas están plegadas. Despliega las patillas."
        case .stream(let error): return "Error de la cámara de las gafas: \(error.localizedDescription)"
        }
    }
}

/// A value that arrives once from a callback (an SDK listener), awaited with a timeout.
final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ value: T) { complete(.success(value)) }
    func fail(_ error: Error) { complete(.failure(error)) }

    func value(timeout: TimeInterval, otherwise timeoutError: Error) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.complete(.failure(timeoutError))
            }
        }
    }

    private func complete(_ outcome: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }
}
