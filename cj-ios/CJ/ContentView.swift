import SwiftUI

/// Step 2 of the port: pair by hand (address + token), check the brain answers, and chat with CJ by text.
struct ContentView: View {
    @State private var url = PairingStore.load()?.url ?? ""
    @State private var token = PairingStore.load()?.token ?? ""
    @State private var status = ""
    @State private var statusOK = false
    @State private var checking = false

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
                    Text("La dirección es la línea «Brain» de run.sh; el token, lo que va tras «token=» en la línea «Console».")
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
            .navigationTitle("CJ")
            .task { if PairingStore.load() != nil { await check() } }
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        PairingStore.save(pairing)
        let client = BrainClient(pairing: pairing)
        do {
            let providers = try await client.health()
            try await client.checkToken()  // /health is open; this proves the token too
            let active = providers.filter { $0.value && $0.key != "mock" }.keys.sorted()
            status = "Conectado. IA disponible: " + (active.isEmpty ? "ninguna" : active.joined(separator: ", "))
            statusOK = true
        } catch {
            status = error.localizedDescription
            statusOK = false
        }
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
        } catch {
            turns.append(Turn(role: "assistant", text: "⚠️ " + (error.localizedDescription)))
        }
    }
}

#Preview {
    ContentView()
}
