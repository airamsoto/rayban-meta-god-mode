import SwiftUI

/// Kitchen mode: the screen stays on, timers are big, the shopping list is at hand, and the orb is one tap away for
/// "next step", "add eggs to the shopping list" or "what can I cook with this?".
struct KitchenView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveSession
    @ObservedObject var timers: PhoneActions
    @ObservedObject var tools: PhoneTools
    @Environment(\.dismiss) private var dismiss
    @State private var items: [String] = []
    @State private var newItem = ""

    var body: some View {
        VStack(spacing: 16) {
                HStack {
                    Label("Cocina", systemImage: "fork.knife")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    RoundButton(icon: "xmark", size: 40) { dismiss() }
                }
                ScrollView {
                    VStack(spacing: 16) {
                        timersCard
                        shoppingCard
                    }
                }
                suggestions
                Button { model.toggleTalk() } label: { Orb(mode: orbMode, size: 76) }
                    .buttonStyle(.plain)
                Text(live.active ? (live.cjSpeaking ? "CJ está hablando" : "Te escucho") : "Toca para hablar · la pantalla no se apagará")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            .padding(20)
        .background { Backdrop() }
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task { await refreshList() }
        .onChange(of: live.active) { _, active in if !active { Task { await refreshList() } } }
    }

    private var timersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Temporizadores", systemImage: "timer").font(.headline).foregroundStyle(.white)
            if timers.timers.isEmpty {
                Text("Ninguno. Pide «pon un temporizador de 8 minutos para la pasta» o toca uno:")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(timers.timers) { timer in
                HStack {
                    Text(timer.label.isEmpty ? "Temporizador" : timer.label).font(.title3.weight(.semibold)).foregroundStyle(.white)
                    Spacer()
                    Text(timer.ends, style: .timer)
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 8) {
                ForEach([1, 3, 5, 10, 15], id: \.self) { minutes in
                    Button("\(minutes) min") { timers.startTimer(seconds: minutes * 60, label: "\(minutes) min") }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(Theme.stroke))
                }
            }
        }
        .padding(16)
        .card()
    }

    private var shoppingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Lista de la compra", systemImage: "cart").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { Task { await refreshList() } } label: { Image(systemName: "arrow.clockwise") }.foregroundStyle(.white.opacity(0.7))
            }
            if !tools.remindersAllowed {
                Button("Permitir Recordatorios") { Task { await tools.requestReminders(); await refreshList() } }
                    .buttonStyle(.borderedProminent).tint(Theme.violet)
            } else if items.isEmpty {
                Text("Vacía. Di «añade huevos a la compra».").font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "circle").foregroundStyle(.white)
            }
            HStack {
                TextField("Añadir…", text: $newItem).foregroundStyle(.white).onSubmit(addItem)
                Button(action: addItem) { Image(systemName: "plus.circle.fill").font(.title2) }
                    .foregroundStyle(Theme.cyan)
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .card()
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["Siguiente paso", "¿Qué cocino con lo que veo?", "¿Cuánto tiempo cuezo la pasta?", "Convierte 200 gramos a tazas"], id: \.self) { text in
                    Button(text) { model.ask(text) }
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(Theme.stroke))
                }
            }
        }
    }

    private var orbMode: Orb.Mode {
        if live.connecting { return .connecting }
        if live.active { return live.cjSpeaking ? .speaking : .listening }
        return .idle
    }

    private func refreshList() async {
        items = await tools.openItems(PhoneTools.shoppingList)
    }

    private func addItem() {
        let item = newItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return }
        newItem = ""
        Task {
            _ = await tools.reminderAdd(item, list: PhoneTools.shoppingList)
            await refreshList()
        }
    }
}
