import AVFoundation
import Combine

/// Reads CJ's answers aloud with the iPhone's own voices. When the glasses are connected over Bluetooth, iOS plays
/// it on them (A2DP); otherwise on the speaker. [route] says where sound goes right now, so routing can be checked.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var route = ""
    @Published private(set) var onGlasses = false
    @Published private(set) var speaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var routeObserver: AnyCancellable?

    override init() {
        super.init()
        synthesizer.delegate = self
        refreshRoute()
        routeObserver = NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRoute() }
    }

    /// Speaks [text] in the voice for [language] (an ISO 639-1 code from the brain, e.g. "es"), cutting off any
    /// answer still playing.
    func say(_ text: String, language: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        activateSession()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = Self.voice(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Audio session and route

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback lets iOS pick the high-quality Bluetooth route (A2DP) to the glasses, and keeps playing with
            // the ringer switch on silent. Other audio (music) is lowered while CJ talks.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            route = "No pude activar el audio: \(error.localizedDescription)"
        }
        refreshRoute()
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        onGlasses = outputs.contains { Self.bluetooth.contains($0.portType) }
        route = outputs.map(Self.describe).joined(separator: ", ")
        if route.isEmpty { route = "Sin salida de audio" }
    }

    private static let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]

    private static func describe(_ port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .bluetoothA2DP: return "\(port.portName) (Bluetooth, alta calidad)"
        case .bluetoothHFP: return "\(port.portName) (Bluetooth, modo llamada)"
        case .bluetoothLE: return "\(port.portName) (Bluetooth LE)"
        case .builtInSpeaker: return "Altavoz del iPhone"
        case .builtInReceiver: return "Auricular del iPhone"
        case .headphones: return "Auriculares con cable"
        default: return port.portName
        }
    }

    /// The brain reports the reply's language as an ISO 639-1 code (or "hinglish"); iOS wants a locale like "es-ES".
    private static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        let locales = ["es": "es-ES", "en": "en-US", "hinglish": "en-IN", "hi": "hi-IN", "fr": "fr-FR", "de": "de-DE",
                       "it": "it-IT", "pt": "pt-PT", "ca": "ca-ES", "zh": "zh-CN", "ja": "ja-JP", "ko": "ko-KR",
                       "ar": "ar-SA", "ru": "ru-RU", "tr": "tr-TR"]
        let code = (language ?? "es").lowercased()
        return AVSpeechSynthesisVoice(language: locales[code] ?? code) ?? AVSpeechSynthesisVoice(language: "es-ES")
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = true; self.refreshRoute() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.speaking = false
            if !synthesizer.isSpeaking { self.deactivateSession() }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }
}
