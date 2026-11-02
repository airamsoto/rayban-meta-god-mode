import Foundation
import Combine

/// Everything CJ's screens show and do: the brain connection, the conversation, the glasses, timers and phone tools.
/// Views observe this plus the live session and glasses directly.
@MainActor
final class AppModel: ObservableObject {
    // Connection to the brain
    @Published var url = PairingStore.load()?.url ?? ""
    @Published var token = PairingStore.load()?.token ?? ""
    @Published private(set) var connected = false
    @Published private(set) var connectionText = ""
    @Published private(set) var checking = false

    // Conversation
    @Published private(set) var turns: [Turn] = []
    @Published var notice = ""  // a short message under the controls (errors, hints)
    @Published private(set) var asking = false

    // Screens opened from outside (cjglasses://cocina, cjglasses://ajustes)
    @Published var showKitchen = false
    @Published var showSettings = false

    // Settings
    @Published var speakAnswers = UserDefaults.standard.object(forKey: "speak_answers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakAnswers, forKey: "speak_answers"); if !speakAnswers { speaker.stop() } }
    }
    @Published var visualMemory = UserDefaults.standard.bool(forKey: "visual_memory") {
        didSet { UserDefaults.standard.set(visualMemory, forKey: "visual_memory") }
    }
    /// One Apple Shortcut name per line (lights, scenes…), offered to the model so it knows what it can run.
    @Published var shortcutNames = UserDefaults.standard.string(forKey: "home_shortcuts") ?? "" {
        didSet { UserDefaults.standard.set(shortcutNames, forKey: "home_shortcuts") }
    }

    let glasses: Glasses
    let live = LiveSession()
    let speaker = Speaker()
    let timers = PhoneActions()
    let tools = PhoneTools()

    private var lastGlance = Date.distantPast
    private var started = false
    static let glanceEvery: TimeInterval = 5 * 60

    var pairing: Pairing { Pairing(url: url, token: token) }
    var shortcuts: [String] {
        shortcutNames.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    init(glasses: Glasses) {
        self.glasses = glasses
        glasses.configure()  // first of all: Meta's SDK crashes the app if anything touches it before this
        timers.announce = { [weak self] text in
            guard let self else { return }
            self.turns.append(Turn(role: "assistant", text: "⏰ " + text))
            if self.speakAnswers && !self.live.active { self.speaker.say(text, language: "es") }
        }
        tools.callRequested = { [weak self] number, _ in self?.live.callAfterTurn(number) }
        live.onTurn = { [weak self] you, cj in
            guard let self else { return }
            if !you.isEmpty { self.turns.append(Turn(role: "user", text: you)) }
            if !cj.isEmpty { self.turns.append(Turn(role: "assistant", text: cj)) }
        }
        live.takePhoto = { [weak self] in await self?.photo() }
        live.onPhoto = { [weak self] shot in
            self?.turns.append(Turn(role: "user", text: "Lo que veían las gafas", image: shot.image))
        }
        live.onPhoneAction = { [weak self] action in self?.apply(action) }
        live.onPhoneTool = { [weak self] action, args in
            await self?.tools.run(action, args) ?? "FAILED"
        }
    }

    /// Once, when the app opens: connect, then keep the background chores going.
    func start() async {
        guard !started else { return }
        started = true
        // Launch argument for screenshots and testing: -openScreen cocina|ajustes
        switch UserDefaults.standard.string(forKey: "openScreen") {
        case "cocina": showKitchen = true
        case "ajustes": showSettings = true
        default: break
        }
        if PairingStore.load() != nil { await check() }
        await backgroundWork()
    }

    // MARK: - brain connection

    func check() async {
        checking = true
        defer { checking = false }
        PairingStore.save(pairing)
        do {
            try await connect()
        } catch BrainError.unreachable {
            // The Mac may have a new address: look for it on the Wi-Fi and try again with the same token.
            connectionText = "Buscando el cerebro en la red…"
            connected = false
            guard let found = await Discovery.find(), found != pairing.baseURL?.absoluteString else {
                connectionText = BrainError.unreachable(url).localizedDescription
                return
            }
            url = found
            PairingStore.save(pairing)
            do { try await connect() } catch { connectionText = error.localizedDescription; connected = false }
        } catch {
            connectionText = error.localizedDescription
            connected = false
        }
    }

    func pair(with scanned: Pairing) async {
        url = scanned.url
        token = scanned.token
        await check()
    }

    private func connect() async throws {
        let client = BrainClient(pairing: pairing)
        let providers = try await client.health()
        try await client.checkToken()  // /health is open; this proves the token too
        let active = providers.filter { $0.value && $0.key != "mock" }.keys.sorted()
        connectionText = "Conectado · IA: " + (active.isEmpty ? "ninguna" : active.joined(separator: ", "))
        connected = true
    }

    // MARK: - talking

    /// The orb: start a conversation, or end the one going on.
    func toggleTalk() {
        if live.active { live.cancel() } else { Task { await talk() } }
    }

    /// A typed question or a quick action. Goes into the live conversation, so every tool (calendar, WhatsApp…) works.
    func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        turns.append(Turn(role: "user", text: text))
        if live.active { live.sendText(text) } else { Task { await talk(firstText: text) } }
    }

    func talk(firstText: String? = nil) async {
        guard !live.active else { return }
        guard connected else { notice = "Conecta con el cerebro primero (Ajustes)."; return }
        speaker.stop()
        notice = ""
        let end = await live.run(pairing: pairing, history: turns.filter { $0.image == nil }, firstText: firstText,
                                 phoneTools: PhoneTools.actions, shortcuts: shortcuts)
        switch end {
        case .failed(let why):
            notice = why
            if let firstText { await answerByText(firstText) }  // live voice unavailable: still answer the question
        case .notYet(let why): notice = why
        case .idle: notice = "Conversación cerrada tras 90 s de silencio."
        default: break
        }
        if let number = live.pendingCall { timers.call(number) }
    }

    /// Fallback when real-time voice is down (Gemini Live busy): the plain question-answer endpoint.
    private func answerByText(_ text: String) async {
        asking = true
        defer { asking = false }
        do {
            let answer = try await BrainClient(pairing: pairing).ask(text, history: turns.filter { $0.image == nil })
            turns.append(Turn(role: "assistant", text: answer.spoken))
            if speakAnswers { speaker.say(answer.spoken, language: answer.language) }
            apply(answer.phone, timer: answer.timer)
            notice = ""
        } catch {
            notice = error.localizedDescription
        }
    }

    /// "Oye Siri, hablar con CJ" or the Action Button.
    func talkFromIntent() async {
        guard !live.active else { return }
        for _ in 0..<20 where !connected { try? await Task.sleep(nanoseconds: 250_000_000) }
        await talk()
    }

    func clearConversation() { turns.removeAll() }

    // MARK: - phone

    private func photo() async -> Snapshot? {
        do { return try await glasses.takePhoto() } catch { notice = error.localizedDescription; return nil }
    }

    /// Things the brain hands back: timers, visual memory on/off, calls.
    func apply(_ action: PhoneAction?, timer: TimerRequest? = nil) {
        if let timer, timer.seconds > 0 { timers.startTimer(seconds: timer.seconds, label: timer.label) }
        guard let action else { return }
        switch action.action {
        case "timer":
            if let seconds = action.seconds, seconds > 0 { timers.startTimer(seconds: seconds, label: action.label) }
        case "visual_memory":
            visualMemory = action.on ?? true
            lastGlance = .now
        case "call_number":
            if let number = action.number, !number.isEmpty {
                if live.active { live.callAfterTurn(number) } else { timers.call(number) }
            }
        case "translate": notice = "La traducción en directo aún no está en la versión de iPhone."
        case "phone_task": notice = "En iPhone, CJ no maneja otras apps; prueba con WhatsApp, Teams o un Atajo."
        default: break
        }
    }

    /// While the app runs: glasses status, finished Claude Code jobs (every 10 s), visual-memory photos (every 5 min).
    private func backgroundWork() async {
        while !Task.isCancelled {
            glasses.refreshState()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard connected else { continue }
            let brain = BrainClient(pairing: pairing)
            if let jobs = try? await brain.finishedJobs() {
                for job in jobs {
                    let text = job.state == "done" ? "Claude Code terminó en \(job.project): \(job.summary)"
                                                   : "Claude Code tuvo un problema en \(job.project): \(job.summary)"
                    turns.append(Turn(role: "assistant", text: text))
                    if speakAnswers && !live.active { speaker.say(text, language: "es") }
                }
            }
            if visualMemory, !live.active, !asking, glasses.registration == .registered,
               Date().timeIntervalSince(lastGlance) >= Self.glanceEvery {
                lastGlance = .now
                if let shot = try? await glasses.takePhoto() { _ = try? await brain.glance(jpegBase64: shot.jpegBase64) }
            }
        }
    }
}
