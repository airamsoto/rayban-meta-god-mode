import Foundation

/// How a live conversation ended.
enum LiveEnd: Equatable {
    case bye, stop, idle, cancelled
    case failed(String)
    case notYet(String)  // the brain started something the iOS app can't do yet (dictation, translation…)
}

/// One real-time conversation with the brain (cj-mac/cj/live.py, port of the Android Live.kt): the mic streams up,
/// CJ's voice streams back and stops the moment you talk over it. Protocol:
///   phone → brain: {"type":"start",...} first, then binary 16 kHz PCM frames; {"type":"photo"}, {"type":"end"}
///   brain → phone: ready, heard, said, interrupted, turn_done, need_photo, route, phone, error, end; binary 24 kHz PCM
@MainActor
final class LiveSession: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var status = ""
    @Published private(set) var heardNow = ""   // what you're saying, as it's transcribed
    @Published private(set) var saidNow = ""    // what CJ is saying
    @Published private(set) var micName = ""
    @Published private(set) var micIsGlasses = false

    /// Each finished exchange, for the conversation log: (what you said, what CJ said).
    var onTurn: ((String, String) -> Void)?
    /// Takes a photo with the glasses when the model wants to look (nil when it can't).
    var takePhoto: (() async -> Snapshot?)?
    /// The photo CJ looked at, for the conversation log.
    var onPhoto: ((Snapshot) -> Void)?
    /// Timers, visual memory on/off: things the phone does while the conversation goes on.
    var onPhoneAction: ((PhoneAction) -> Void)?
    /// A number to call once the conversation ends (the call needs the audio).
    private(set) var pendingCall: String?

    static let idleSeconds: TimeInterval = 90  // quiet this long: close the session

    private var socket: URLSessionWebSocketTask?
    private var audio: LiveAudio?
    private var continuation: CheckedContinuation<LiveEnd, Never>?
    private var result: LiveEnd?
    private var nextStep: LiveEnd?
    private var lastActivity = Date()
    private var silenced = false        // you said "stop": the rest of this answer isn't played
    private var overTalk = ""           // only what you said while CJ was talking
    private var heard = ""
    private var tasks: [Task<Void, Never>] = []

    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        return URLSession(configuration: config)
    }()

    /// Runs one conversation until it ends. [history] gives the model context from earlier turns.
    func run(pairing: Pairing, history: [Turn]) async -> LiveEnd {
        guard !active else { return .failed("ya hay una conversación en marcha") }
        guard let base = pairing.baseURL,
              let url = URL(string: base.absoluteString.replacingOccurrences(of: "http", with: "ws", options: .anchored) + "/ws/live")
        else { return .failed(BrainError.badAddress.localizedDescription) }

        active = true
        result = nil
        nextStep = nil
        pendingCall = nil
        heard = ""; heardNow = ""; saidNow = ""; overTalk = ""
        silenced = false
        lastActivity = Date()
        status = "Conectando con el cerebro…"

        // The token goes in a header, not the address, so it stays out of the brain's request log.
        var request = URLRequest(url: url)
        request.setValue("Bearer \(pairing.token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        let socket = Self.urlSession.webSocketTask(with: request)
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.socket = socket
        socket.resume()

        let start: [String: Any] = [
            "type": "start", "mode": "assistant", "language": "", "user_language": "Spanish",
            "history": history.suffix(8).map { ["role": $0.role, "text": $0.text] },
        ]
        send(json: start)

        let audio = LiveAudio()
        self.audio = audio
        audio.onFrame = { [weak socket] frame in socket?.send(.data(frame)) { _ in } }
        do {
            try audio.start()
            micName = audio.inputName
            micIsGlasses = audio.inputIsGlasses
        } catch {
            finish(.failed("No pude abrir el micrófono: \(error.localizedDescription)"))
        }

        tasks.append(Task { [weak self] in await self?.receiveLoop() })
        tasks.append(Task { [weak self] in await self?.idleLoop() })

        let end = await withCheckedContinuation { continuation in
            if let result { continuation.resume(returning: result) } else { self.continuation = continuation }
        }
        await close(after: end)
        return end
    }

    /// Ends the conversation from the app (the "Terminar" button).
    func cancel() {
        finish(.cancelled)
    }

    // MARK: - events from the brain

    private func receiveLoop() async {
        while let socket, result == nil {
            do {
                switch try await socket.receive() {
                case .data(let pcm):
                    if !silenced { audio?.play(pcm) }
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        handle(event)
                    }
                @unknown default:
                    break
                }
            } catch {
                finish(nextStep ?? .failed("Se cortó la conexión con el cerebro."))
                return
            }
        }
    }

    private func handle(_ e: [String: Any]) {
        let now = Date()
        let text = e["text"] as? String ?? ""
        switch e["type"] as? String ?? "" {
        case "ready":
            status = "Escuchando… habla con normalidad, di «adiós» para terminar"
        case "heard":
            heard += text
            heardNow = heard
            lastActivity = now
            if audio?.speaking == true { overTalk += text } else { overTalk = "" }
            // "Stop" while CJ talks: quiet now, not when the server notices a moment later. Only words said over CJ
            // count, so a "basta" inside your own question doesn't cut the answer short.
            if !silenced && Phrases.isStopWord(overTalk) {
                silenced = true
                audio?.flush()
            }
        case "said":
            saidNow += text
            lastActivity = now
        case "interrupted":
            audio?.flush()
            saidNow = ""
        case "need_photo":
            // "What is this?", "add this to my calendar": the model called its look tool. An empty photo tells the
            // brain at once that the glasses couldn't take one, instead of it waiting 35 s.
            status = "Mirando por las gafas…"
            lastActivity = now  // a photo can take a while; that isn't silence
            Task { [weak self] in
                guard let self else { return }
                let snapshot = await self.takePhoto?()
                self.send(json: ["type": "photo", "image_b64": snapshot?.jpegBase64 ?? ""])
                if let snapshot { self.onPhoto?(snapshot) }
                self.status = snapshot == nil ? "No pude hacer la foto con las gafas." : "Escuchando…"
                self.lastActivity = Date()
            }
        case "phone":
            phoneAction(e)
        case "turn_done":
            silenced = false
            overTalk = ""
            lastActivity = now
            let you = ((e["heard"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? heard)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cj = (e["said"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            heard = ""
            if !you.isEmpty || !cj.isEmpty { onTurn?(you, cj) }
            heardNow = ""
            saidNow = ""
            if Phrases.wantsStop(you) { finish(.stop) } else if Phrases.wantsBye(you) || pendingCall != nil { finish(.bye) }
        case "end":
            finish(nextStep ?? .bye)
        case "error":
            finish(.failed(text.isEmpty ? "Error en la voz en tiempo real." : text))
        default:
            break
        }
    }

    private func phoneAction(_ e: [String: Any]) {
        guard let action = PhoneAction(event: e) else { return }
        switch action.action {
        case "dictation": nextStep = .notYet("El dictado de notas aún no está en la versión de iPhone.")
        case "translate": nextStep = .notYet("La traducción en directo aún no está en la versión de iPhone.")
        case "phone_task": nextStep = .notYet("En iPhone, CJ no puede manejar otras apps por ti.")
        case "call_number":
            pendingCall = action.number.flatMap { $0.isEmpty ? nil : $0 }
            status = "Llamaré cuando termine de hablar."
        default:
            onPhoneAction?(action)  // timer, visual_memory
        }
    }

    // MARK: - lifecycle

    private func idleLoop() async {
        while result == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Date().timeIntervalSince(lastActivity) > Self.idleSeconds, audio?.speaking != true {
                finish(.idle)
            }
        }
    }

    private func finish(_ end: LiveEnd) {
        guard result == nil else { return }
        result = end
        continuation?.resume(returning: end)
        continuation = nil
    }

    private func close(after end: LiveEnd) async {
        // Let the last words finish before closing (a goodbye).
        if case .failed = end {} else if end != .cancelled, let left = audio?.remaining, left > 0 {
            try? await Task.sleep(nanoseconds: UInt64(min(left + 0.2, 8) * 1_000_000_000))
        }
        tasks.forEach { $0.cancel() }
        tasks = []
        send(json: ["type": "end"])
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        audio?.onFrame = nil
        audio?.stop()
        audio = nil
        active = false
        status = ""
        heardNow = ""
        saidNow = ""
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }
}
