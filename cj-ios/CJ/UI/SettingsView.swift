import SwiftUI

/// Everything that is set up once: the brain, the glasses, permissions, home shortcuts, voice and features.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var glasses: Glasses
    @ObservedObject var tools: PhoneTools
    @ObservedObject private var speakerState: Speaker
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false

    init(model: AppModel, glasses: Glasses, tools: PhoneTools) {
        self.model = model
        self.glasses = glasses
        self.tools = tools
        speakerState = model.speaker
    }

    var body: some View {
        NavigationStack {
            Form {
                brain
                GlassesSection(glasses: glasses)
                permissions
                home
                voice
                features
                about
            }
            .scrollContentBackground(.hidden)
            .background(Backdrop())
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { BackButton { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScannerView { code in
                    if let scanned = Pairing(qr: code) { Task { await model.pair(with: scanned) } }
                }
            }
            .onAppear { tools.refreshPermissions() }
        }
        .preferredColorScheme(.dark)
    }

    private var brain: some View {
        Section {
            if !model.connectionText.isEmpty {
                Label(model.connectionText, systemImage: model.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.connected ? .green : .orange)
                    .font(.callout)
            }
            Button { scanning = true } label: { Label("Escanear QR del cerebro", systemImage: "qrcode.viewfinder") }
            TextField("192.168.1.20:8765", text: $model.url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Token de emparejamiento", text: $model.token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button {
                Task { await model.check() }
            } label: {
                HStack {
                    Label("Probar conexión", systemImage: "bolt.horizontal.circle")
                    if model.checking { Spacer(); ProgressView() }
                }
            }
            .disabled(model.checking || model.url.isEmpty || model.token.isEmpty)
        } header: {
            Text("Cerebro")
        } footer: {
            Text("El QR lo muestra run.sh en tu Mac. Si el Mac cambia de dirección, CJ lo vuelve a encontrar solo.")
        }
    }

    private var permissions: some View {
        Section {
            permissionRow("Calendario", icon: "calendar", allowed: tools.calendarAllowed) { await tools.requestCalendar() }
            permissionRow("Recordatorios y compra", icon: "checklist", allowed: tools.remindersAllowed) { await tools.requestReminders() }
            permissionRow("Contactos", icon: "person.crop.circle", allowed: tools.contactsAllowed) { await tools.requestContacts() }
        } header: {
            Text("Permisos del iPhone")
        } footer: {
            Text("Para tu agenda (también Outlook/Teams si la cuenta está en el iPhone), la lista de la compra, WhatsApp y llamadas por nombre. Si ya los denegaste, actívalos en Ajustes → CJ.")
        }
    }

    private func permissionRow(_ title: String, icon: String, allowed: Bool, request: @escaping () async -> Void) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if allowed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Permitir") { Task { await request() } }.buttonStyle(.borderedProminent).tint(Theme.violet)
            }
        }
    }

    private var home: some View {
        Section {
            TextEditor(text: $model.shortcutNames)
                .frame(minHeight: 90)
                .font(.callout)
                .overlay(alignment: .topLeading) {
                    if model.shortcutNames.isEmpty {
                        Text("Luces salón\nApagar todo\nModo cine").foregroundStyle(.secondary).font(.callout)
                            .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
        } header: {
            Text("Casa y Atajos")
        } footer: {
            Text("Escribe aquí, uno por línea, los nombres de tus Atajos de Apple (app Atajos). CJ los ejecuta por voz: «enciende las luces del salón». Con Atajos puedes controlar Casa (HomeKit), música y casi cualquier app.")
        }
    }

    private var voice: some View {
        Section {
            Toggle("Leer en voz alta fuera de la conversación", isOn: $model.speakAnswers)
            Label(speakerState.route, systemImage: speakerState.onGlasses ? "eyeglasses" : "speaker.wave.2")
                .foregroundStyle(speakerState.onGlasses ? .green : .secondary)
                .font(.callout)
            Button {
                model.speaker.say("Hola, soy CJ. Si me oyes en las gafas, el sonido funciona.", language: "es")
            } label: {
                Label(speakerState.speaking ? "Hablando…" : "Probar sonido", systemImage: "play.circle")
            }
        } header: {
            Text("Voz")
        }
    }

    private var features: some View {
        Section {
            Toggle(isOn: $model.visualMemory) { Label("Memoria visual", systemImage: "eye") }
        } header: {
            Text("Funciones")
        } footer: {
            Text("Memoria visual: con CJ abierta, las gafas hacen una foto cada 5 minutos y el cerebro guarda solo una nota de texto. "
                 + "Manos libres: di «Oye Siri, hablar con CJ», o asigna «Hablar con CJ» al botón de Acción.")
        }
    }

    private var about: some View {
        Group {
            Section {
                Button(role: .destructive) { model.clearConversation() } label: { Label("Borrar conversación", systemImage: "trash") }
                LabeledContent("Versión", value: version)
            }
            Section {
                Button { dismiss() } label: {
                    Label("Volver a CJ", systemImage: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
