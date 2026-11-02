import AVFoundation
import Combine

/// Push-to-talk recording from the glasses' microphone. The glasses' mic only reaches the iPhone over the Bluetooth
/// hands-free profile (HFP), so recording switches them to "call mode" for the duration and back afterwards.
/// Produces a 16 kHz mono 16-bit WAV, the format the brain's /api/ask expects (about 90 s fits its size limit).
final class Recorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var input = ""
    @Published private(set) var fromGlasses = false
    @Published private(set) var seconds = 0.0

    static let maxSeconds: TimeInterval = 60

    private var recorder: AVAudioRecorder?
    private var timer: AnyCancellable?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("cj-question.wav")

    enum RecorderError: LocalizedError {
        case denied, failed(String)
        var errorDescription: String? {
            switch self {
            case .denied: return "Sin permiso de micrófono. Actívalo en Ajustes → CJ → Micrófono."
            case .failed(let why): return "No pude grabar: \(why)"
            }
        }
    }

    func start() async throws {
        guard !recording else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.denied }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
            // Several Bluetooth inputs can be available: prefer the glasses' (HFP) mic over the iPhone's.
            if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(glasses)
            }
        } catch {
            throw RecorderError.failed(error.localizedDescription)
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            let recorder = try AVAudioRecorder(url: file, settings: settings)
            guard recorder.record(forDuration: Self.maxSeconds) else { throw RecorderError.failed("el micrófono está ocupado") }
            self.recorder = recorder
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.failed(error.localizedDescription)
        }
        await MainActor.run {
            recording = true
            seconds = 0
            refreshInput()
            timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                self.seconds = recorder.currentTime
                self.refreshInput()  // the HFP route can take a moment to come up
            }
        }
    }

    /// Stops and returns the WAV, or nil if it was too short to hold a question.
    func stop() -> Data? {
        guard let recorder else { return nil }
        let length = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        timer = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard length >= 0.5 else { return nil }
        return try? Data(contentsOf: file)
    }

    private func refreshInput() {
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first else {
            input = "Sin micrófono"
            fromGlasses = false
            return
        }
        fromGlasses = port.portType == .bluetoothHFP
        switch port.portType {
        case .bluetoothHFP: input = "\(port.portName) (micrófono de las gafas)"
        case .builtInMic: input = "Micrófono del iPhone"
        case .headsetMic: input = "Micrófono de los auriculares"
        default: input = port.portName
        }
    }
}
