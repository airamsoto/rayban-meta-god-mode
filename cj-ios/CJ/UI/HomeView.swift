import SwiftUI

/// CJ's main screen: status at the top, the conversation in the middle, the orb and quick actions at the bottom.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveSession
    @ObservedObject var glasses: Glasses
    @ObservedObject var timers: PhoneActions
    @ObservedObject private var router = IntentRouter.shared

    @State private var typing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            controls
        }
        .background { Backdrop() }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model, glasses: glasses, tools: model.tools) }
        .fullScreenCover(isPresented: $model.showKitchen) {
            KitchenView(model: model, live: live, timers: timers, tools: model.tools)
        }
        .task { await model.start() }
        .onAppear { if router.talkRequested { router.talkRequested = false; Task { await model.talkFromIntent() } } }
        .onChange(of: router.talkRequested) { _, requested in
            if requested { router.talkRequested = false; Task { await model.talkFromIntent() } }
        }
        .onChange(of: model.checking) { _, checking in
            if !checking && !model.connected && model.url.isEmpty { model.showSettings = true }
        }
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting).font(.subheadline).foregroundStyle(.white.opacity(0.6))
                    Text("CJ").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent)
                }
                Spacer()
                RoundButton(icon: "fork.knife", size: 42) { model.showKitchen = true }
                RoundButton(icon: "gearshape.fill", size: 42) { model.showSettings = true }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StatusChip(icon: "desktopcomputer", text: model.connected ? "Cerebro" : "Sin cerebro", ok: model.connected)
                    StatusChip(icon: "eyeglasses", text: glassesText, ok: glasses.connected)
                    ForEach(timers.timers) { timer in
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                            Text(timer.ends, style: .timer).monospacedDigit()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.violet.opacity(0.35), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour < 6 ? "Buenas noches" : hour < 13 ? "Buenos días" : hour < 21 ? "Buenas tardes" : "Buenas noches"
    }

    private var glassesText: String {
        guard glasses.registration == .registered else { return "Gafas sin vincular" }
        guard glasses.connected else { return "Gafas desconectadas" }
        return glasses.battery.map { "Gafas · \($0) %" } ?? "Gafas"
    }

    // MARK: - conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.turns.isEmpty && !live.active {
                        emptyState
                    } else {
                        ForEach(model.turns) { ChatBubble(turn: $0) }
                        if !live.heardNow.isEmpty { ChatBubble(turn: Turn(role: "user", text: live.heardNow), live: true) }
                        if !live.saidNow.isEmpty { ChatBubble(turn: Turn(role: "assistant", text: live.saidNow), live: true) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .animation(.spring(duration: 0.35), value: model.turns.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.turns.count) { withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: live.saidNow) { proxy.scrollTo("bottom") }
            .onChange(of: live.heardNow) { proxy.scrollTo("bottom") }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("¿En qué te ayudo?").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Toca el orbe y habla, o di «Oye Siri, hablar con CJ».").font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 24)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                SuggestionCard(icon: "calendar", title: "Mi día", subtitle: "Reuniones y planes de hoy") {
                    model.ask("¿Qué tengo hoy en el calendario?")
                }
                SuggestionCard(icon: "video.fill", title: "Próxima reunión", subtitle: "Entrar en Teams") {
                    model.ask("Únete a mi próxima reunión de Teams")
                }
                SuggestionCard(icon: "eye.fill", title: "¿Qué estoy viendo?", subtitle: "Mira por las gafas") {
                    model.ask("¿Qué estoy viendo?")
                }
                SuggestionCard(icon: "cart.fill", title: "Lista de la compra", subtitle: "Qué falta en casa") {
                    model.ask("¿Qué hay en mi lista de la compra?")
                }
                SuggestionCard(icon: "message.fill", title: "WhatsApp", subtitle: "«Dile a mamá que llego tarde»") {
                    model.toggleTalk()
                }
                SuggestionCard(icon: "house.fill", title: "Casa", subtitle: model.shortcuts.first.map { "«\($0)»" } ?? "Tus Atajos de Apple") {
                    if let first = model.shortcuts.first { model.ask("Ejecuta el atajo \(first)") } else { model.showSettings = true }
                }
            }
        }
    }

    // MARK: - bottom controls

    private var controls: some View {
        VStack(spacing: 10) {
            if !model.notice.isEmpty {
                Text(model.notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }
            if typing {
                HStack(spacing: 10) {
                    TextField("Escribe a CJ…", text: $draft, axis: .vertical)
                        .focused($fieldFocused)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .card(radius: 18)
                        .onSubmit(sendDraft)
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(Theme.accent, in: Circle())
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16)
            }
            HStack(alignment: .center) {
                RoundButton(icon: typing ? "keyboard.chevron.compact.down" : "keyboard") {
                    withAnimation { typing.toggle() }
                    fieldFocused = typing
                }
                Spacer()
                Button { model.toggleTalk() } label: { Orb(mode: orbMode, size: 84) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(live.active ? "Terminar conversación" : "Hablar con CJ")
                Spacer()
                RoundButton(icon: "camera.viewfinder") { model.ask("¿Qué estoy viendo?") }
            }
            .padding(.horizontal, 28)
            Text(orbCaption)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 6)
        }
        .padding(.top, 18)
        .background(alignment: .top) {
            // The conversation fades out under the controls instead of being cut off.
            LinearGradient(colors: [.clear, Color(red: 0.06, green: 0.03, blue: 0.14).opacity(0.92)],
                           startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
                .padding(.top, -24)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }

    private var orbMode: Orb.Mode {
        if live.connecting { return .connecting }
        if live.active { return live.cjSpeaking ? .speaking : .listening }
        return .idle
    }

    private var orbCaption: String {
        if live.connecting { return "Conectando…" }
        if live.active {
            if live.cjSpeaking { return "CJ está hablando · interrúmpele cuando quieras" }
            return live.status.isEmpty || live.status == "Te escucho" ? "Te escucho · toca para terminar" : live.status
        }
        return model.connected ? "Toca para hablar" : "Conecta el cerebro en Ajustes"
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        model.ask(text)
    }
}
