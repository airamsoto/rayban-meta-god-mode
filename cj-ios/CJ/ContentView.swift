import SwiftUI

/// Step 2 of the port: pair by hand (address + token), check the brain answers, and chat with CJ by text.
struct ContentView: View {
    @ObservedObject var glasses: Glasses

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

                Section("Conversación") {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.role == "user" ? "Tú" : "CJ")
                                .font(.caption.bold())
                                .foregroundStyle(turn.role == "user" ? Color.secondary : Color.accentColor)
                            Text(turn.text)
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
        let end = await live.run(pairing: pairing, history: turns)
        switch end {
        case .failed(let why), .notYet(let why): micError = why
        case .idle: micError = "Conversación cerrada tras 90 s de silencio."
        default: break
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
        let history = turns
        do {
            let answer = try await BrainClient(pairing: pairing).askSpoken(wav, history: history)
            turns.append(Turn(role: "user", text: answer.heard.isEmpty ? "🎙️ (no se entendió)" : "🎙️ " + answer.heard))
            let reply = answer.needsPhoto
                ? "Para eso necesito ver lo que miras. Las fotos de las gafas llegarán en el paso 7."
                : answer.spoken
            guard !reply.isEmpty else { return }
            turns.append(Turn(role: "assistant", text: reply))
            if speakAnswers { speaker.say(reply, language: answer.needsPhoto ? "es" : answer.language) }
        } catch {
            turns.append(Turn(role: "assistant", text: "⚠️ " + error.localizedDescription))
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
        } catch {
            turns.append(Turn(role: "assistant", text: "⚠️ " + (error.localizedDescription)))
        }
    }
}

#Preview {
    ContentView(glasses: Glasses())
}
