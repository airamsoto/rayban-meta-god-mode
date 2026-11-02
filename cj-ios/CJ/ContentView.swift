import SwiftUI

/// CJ's single screen: brain pairing, glasses, voice, features, and the conversation with its talk buttons.
struct ContentView: View {
    @ObservedObject var glasses: Glasses
    @StateObject private var phone = PhoneActions()
    @ObservedObject private var router = IntentRouter.shared
    @AppStorage("visual_memory") private var visualMemory = false
    @State private var lastGlance = Date.distantPast

    static let glanceEvery: TimeInterval = 5 * 60  // visual memory: one photo every five minutes

    @State private var url = PairingStore.load()?.url ?? ""
    @State private var token = PairingStore.load()?.token ?? ""
    @State private var status = ""
    @State private var statusOK = false
    @State private var checking = false
    @State private var scanning = false

    @StateObject private var speaker = Speaker()
    @AppStorage("speak_answers") private var speakAnswers = true
    @StateObject private var recorder = Recorder()
    @State private var micError = ""
    @State private var holding = false  // finger on the talk button (recording starts a moment later)
    @StateObject private var live = LiveSession()

    @State private var question = ""
    @State private var turns: [Turn] = []
    @State private var asking = false

    private var pairing: Pairing { Pairing(url: url, token: token) }
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label("Escanear QR del cerebro", systemImage: "qrcode.viewfinder")
                    }
                    TextField("192.168.1.20:8765", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token de emparejamiento", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Text("Guardar y probar conexión")
                            if checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(checking || url.isEmpty || token.isEmpty)
                    if !status.isEmpty {
                        Label(status, systemImage: statusOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(statusOK ? .green : .orange)
                            .font(.callout)
                    }
                } header: {
                    Text("Cerebro")
                } footer: {
                    Text("Escanea el QR que imprime run.sh, o escribe la línea «Brain» y el token que va tras «token=» en la línea «Console». Si el Mac cambia de dirección, CJ lo vuelve a encontrar solo.")
                }

                GlassesSection(glasses: glasses)

                Section {
                    Toggle("Leer las respuestas en voz alta", isOn: $speakAnswers)
                        .onChange(of: speakAnswers) { _, on in if !on { speaker.stop() } }
                    Label(speaker.route, systemImage: speaker.onGlasses ? "eyeglasses" : "speaker.wave.2")
                        .foregroundStyle(speaker.onGlasses ? .green : .secondary)
                        .font(.callout)
                    Button {
                        speaker.say("Hola, soy CJ. Si me oyes en las gafas, el sonido funciona.", language: "es")
                    } label: {
                        Label(speaker.speaking ? "Hablando…" : "Probar sonido", systemImage: "play.circle")
                    }
                } header: {
                    Text("Voz")
                } footer: {
                    Text("Con las gafas conectadas al iPhone por Bluetooth, CJ suena en ellas. La línea de arriba indica por dónde sale el sonido ahora.")
                }

                Section {
                    Toggle("Memoria visual", isOn: $visualMemory)
                    ForEach(phone.timers) { timer in
                        Label {
                            Text(timer.label.isEmpty ? "Temporizador" : timer.label)
                            Text(timer.ends, style: .timer).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "timer")
                        }
                    }
                } header: {
                    Text("Funciones")
                } footer: {
                    Text("Memoria visual: mientras CJ está abierta, las gafas hacen una foto cada 5 minutos y el cerebro guarda solo una nota de texto. "
                         + "Para empezar a hablar sin tocar la pantalla, di «Oye Siri, hablar con CJ» o asigna «Hablar con CJ» al botón de Acción en Ajustes.")
                }

                Section("Conversación") {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.role == "user" ? "Tú" : "CJ")
                                .font(.caption.bold())
                                .foregroundStyle(turn.role == "user" ? Color.secondary : Color.accentColor)
                            Text(turn.text)
                            if let image = turn.image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    HStack {
                        TextField("Pregúntale algo a CJ", text: $question, axis: .vertical)
                            .onSubmit { Task { await send() } }
                        Button {
                            Task { await send() }
                        } label: {
                            if asking { ProgressView() } else { Image(systemName: "paperplane.fill") }
                        }
                        .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty || !statusOK)
                    }
                    if !statusOK {
                        Text("Prueba la conexión primero.").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Versión \(version)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) { talkBar }
            .navigationTitle("CJ")
            .task { if PairingStore.load() != nil { await check() } }
            .task { await backgroundWork() }
            .onAppear {
                phone.announce = { text in
                    turns.append(Turn(role: "assistant", text: "⏰ " + text))
                    if speakAnswers && !live.active { speaker.say(text, language: "es") }
                }
                if router.talkRequested { Task { await talkFromIntent() } }
            }
            .onChange(of: router.talkRequested) { _, requested in
                if requested { Task { await talkFromIntent() } }
            }
            .sheet(isPresented: $scanning) {
                QRScannerView { code in
                    if let scanned = Pairing(qr: code) {
                        url = scanned.url
                        token = scanned.token
                        Task { await check() }
                    } else {
                        status = "Ese QR no es el del cerebro de CJ."
                        statusOK = false
                    }
                }
            }
        }
    }

    /// Bottom bar: "Hablar con CJ" opens a real-time conversation; the mic button beside it is hold-to-talk.
    private var talkBar: some View {
        VStack(spacing: 6) {
            if live.active {
                liveCard
            } else if recorder.recording {
                Label(recorder.input, systemImage: recorder.fromGlasses ? "eyeglasses" : "iphone")
                    .font(.footnote)
                    .foregroundStyle(recorder.fromGlasses ? .green : .orange)
            } else if !micError.isEmpty {
                Text(micError).font(.footnote).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button {
                    if live.active { live.cancel() } else { Task { await talkLive() } }
                } label: {
                    Label(live.active ? "Terminar" : "Hablar con CJ",
                          systemImage: live.active ? "stop.fill" : "waveform")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(live.active ? Color.red : (canTalk ? Color.accentColor : Color.gray),
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!live.active && !canTalk)
                if !live.active { holdToTalkButton }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canTalk: Bool { statusOK && !asking && !recorder.recording }

    /// What's happening in the live conversation right now.
    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(live.micName, systemImage: live.micIsGlasses ? "eyeglasses" : "iphone")
                .font(.caption)
                .foregroundStyle(live.micIsGlasses ? .green : .orange)
            Text(live.status).font(.footnote).foregroundStyle(.secondary)
            if !live.heardNow.isEmpty { Text("Tú: " + live.heardNow).font(.callout) }
            if !live.saidNow.isEmpty { Text("CJ: " + live.saidNow).font(.callout).foregroundStyle(Color.accentColor) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func talkLive() async {
        speaker.stop()
        micError = ""
        live.onTurn = { you, cj in
            if !you.isEmpty { turns.append(Turn(role: "user", text: "🎙️ " + you)) }
            if !cj.isEmpty { turns.append(Turn(role: "assistant", text: cj)) }
        }
        live.takePhoto = { await photoForCJ() }
        live.onPhoto = { snapshot in
            turns.append(Turn(role: "user", text: "📷 Lo que veían las gafas", image: snapshot.image))
        }
        live.onPhoneAction = { action in apply(action) }
        let end = await live.run(pairing: pairing, history: turns.filter { $0.image == nil })
        switch end {
        case .failed(let why), .notYet(let why): micError = why
        case .idle: micError = "Conversación cerrada tras 90 s de silencio."
        default: break
        }
        if let number = live.pendingCall { phone.call(number) }
    }

    /// "Oye Siri, hablar con CJ" (or the Action Button): start talking as soon as the brain answers.
    private func talkFromIntent() async {
        router.talkRequested = false
        guard !live.active else { return }
        for _ in 0..<20 where !statusOK {  // just launched: the connection check may still be running
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard statusOK else { micError = "No llego al cerebro: revisa que run.sh esté en marcha."; return }
        await talkLive()
    }

    /// Things the phone does for the brain: timers, calls, visual memory on/off.
    private func apply(_ action: PhoneAction?, timer: TimerRequest? = nil) {
        if let timer, timer.seconds > 0 { phone.startTimer(seconds: timer.seconds, label: timer.label) }
        guard let action else { return }
        switch action.action {
        case "timer":
            if let seconds = action.seconds, seconds > 0 { phone.startTimer(seconds: seconds, label: action.label) }
        case "visual_memory":
            visualMemory = action.on ?? true
            lastGlance = .now  // the first photo comes in five minutes, not right now
        case "call_number":
            if let number = action.number, !number.isEmpty {
                Task {  // let CJ finish saying "Calling…" first
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    phone.call(number)
                }
            }
        case "translate": micError = "La traducción en directo aún no está en la versión de iPhone."
        case "phone_task": micError = "En iPhone, CJ no puede manejar otras apps por ti."
        default: break
        }
    }

    /// While the app runs: announce finished Claude Code jobs (every 10 s) and take visual-memory photos (every 5 min).
    private func backgroundWork() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard statusOK else { continue }
            let brain = BrainClient(pairing: pairing)
            if let jobs = try? await brain.finishedJobs() {
                for job in jobs {
                    let text = job.state == "done" ? "Claude Code terminó en \(job.project): \(job.summary)"
                                                   : "Claude Code tuvo un problema en \(job.project): \(job.summary)"
                    turns.append(Turn(role: "assistant", text: "💻 " + text))
                    if speakAnswers && !live.active { speaker.say(text, language: "es") }
                }
            }
            let idle = !live.active && !recorder.recording && !asking
            if visualMemory, idle, glasses.registration == .registered,
               Date().timeIntervalSince(lastGlance) >= Self.glanceEvery {
                lastGlance = .now
                if let shot = try? await glasses.takePhoto() {
                    _ = try? await brain.glance(jpegBase64: shot.jpegBase64)
                }
            }
        }
    }

    /// Hold to talk: records from the glasses while pressed, sends the question when released.
    private var holdToTalkButton: some View {
        Image(systemName: recorder.recording ? "mic.fill" : asking ? "ellipsis" : "mic")
            .font(.title2)
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(recorder.recording ? Color.red : (statusOK && !asking ? Color.accentColor.opacity(0.7) : Color.gray),
                        in: RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("Mantén pulsado para una pregunta corta")
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // Fires on every finger movement: start only once per press.
                        guard !holding, statusOK, !asking else { return }
                        holding = true
                        speaker.stop()
                        micError = ""
                        Task {
                            do { try await recorder.start() } catch { micError = error.localizedDescription }
                            if !holding { _ = recorder.stop() }  // released before the mic was ready
                        }
                    }
                    .onEnded { _ in
                        holding = false
                        guard let wav = recorder.stop() else { return }
                        Task { await sendSpoken(wav) }
                    })
    }

    private func sendSpoken(_ wav: Data) async {
        asking = true
        defer { asking = false }
        let history = turns.filter { $0.image == nil }
        let brain = BrainClient(pairing: pairing)
        do {
            let answer = try await brain.askSpoken(wav, history: history)
            turns.append(Turn(role: "user", text: answer.heard.isEmpty ? "🎙️ (no se entendió)" : "🎙️ " + answer.heard))
            var reply = answer.spoken
            var language = answer.language
            if answer.needsPhoto {
                // "What is this?": look through the glasses, then ask again with the photo.
                if speakAnswers { speaker.say("Déjame ver.", language: "es") }
                guard let snapshot = await photoForCJ() else {
                    reply = "No pude hacer la foto con las gafas. Revisa la sección Gafas."
                    turns.append(Turn(role: "assistant", text: reply))
                    if speakAnswers { speaker.say(reply, language: "es") }
                    return
                }
                turns.append(Turn(role: "user", text: "📷 Lo que veían las gafas", image: snapshot.image))
                let seen = try await brain.ask(answer.heard, history: history, imageJpegBase64: snapshot.jpegBase64)
                reply = seen.spoken
                language = seen.language
                apply(seen.phone, timer: seen.timer)
            } else {
                apply(answer.phone, timer: answer.timer)
            }
            guard !reply.isEmpty else { return }
            turns.append(Turn(role: "assistant", text: reply))
            if speakAnswers { speaker.say(reply, language: language) }
        } catch {
            turns.append(Turn(role: "assistant", text: "⚠️ " + error.localizedDescription))
        }
    }

    /// A photo from the glasses for the brain, or nil (not linked, no camera permission, glasses unreachable).
    private func photoForCJ() async -> Snapshot? {
        do {
            return try await glasses.takePhoto()
        } catch {
            micError = error.localizedDescription
            return nil
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        PairingStore.save(pairing)
        do {
            try await connect()
        } catch BrainError.unreachable {
            // The Mac may have a new address: look for it on the Wi-Fi and try again with the same token.
            status = "No responde en \(url). Buscando el cerebro en la red…"
            statusOK = false
            guard let found = await Discovery.find(), found != pairing.baseURL?.absoluteString else {
                status = BrainError.unreachable(url).localizedDescription
                return
            }
            url = found
            PairingStore.save(pairing)
            do {
                try await connect()
                status += " (dirección nueva: \(found))"
            } catch {
                status = error.localizedDescription
                statusOK = false
            }
        } catch {
            status = error.localizedDescription
            statusOK = false
        }
    }

    private func connect() async throws {
        let client = BrainClient(pairing: pairing)
        let providers = try await client.health()
        try await client.checkToken()  // /health is open; this proves the token too
        let active = providers.filter { $0.value && $0.key != "mock" }.keys.sorted()
        status = "Conectado. IA disponible: " + (active.isEmpty ? "ninguna" : active.joined(separator: ", "))
        statusOK = true
    }

    private func send() async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        asking = true
        defer { asking = false }
        let history = turns
        turns.append(Turn(role: "user", text: text))
        question = ""
        do {
            let answer = try await BrainClient(pairing: pairing).ask(text, history: history)
            turns.append(Turn(role: "assistant", text: answer.spoken))
            if speakAnswers { speaker.say(answer.spoken, language: answer.language) }
            apply(answer.phone, timer: answer.timer)
        } catch {
            turns.append(Turn(role: "assistant", text: "⚠️ " + (error.localizedDescription)))
        }
    }
}

#Preview {
    ContentView(glasses: Glasses())
}
