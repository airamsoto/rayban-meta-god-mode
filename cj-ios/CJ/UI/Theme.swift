import SwiftUI

/// CJ's look: a deep night background, a cyan-to-violet accent, frosted cards.
enum Theme {
    static let cyan = Color(red: 0.32, green: 0.86, blue: 1.0)
    static let violet = Color(red: 0.62, green: 0.42, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.42, blue: 0.72)
    static let accent = LinearGradient(colors: [cyan, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let speaking = LinearGradient(colors: [violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.09)
}

/// The app background: dark gradient with two soft glows.
struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.07, green: 0.03, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Theme.cyan.opacity(0.18)).frame(width: 420).blur(radius: 120).offset(x: -150, y: -320)
            Circle().fill(Theme.violet.opacity(0.22)).frame(width: 460).blur(radius: 140).offset(x: 170, y: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
    }
}

/// Frosted rounded card.
struct CardStyle: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.stroke))
    }
}

extension View {
    func card(radius: CGFloat = 20) -> some View { modifier(CardStyle(radius: radius)) }
}

/// The big talk button: calm when idle, breathing while listening, glowing while CJ talks.
struct Orb: View {
    enum Mode { case idle, connecting, listening, speaking }
    let mode: Mode
    var size: CGFloat = 96

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse: Double = switch mode {
            case .idle: 0.02 * sin(t * 1.2)
            case .connecting: 0.05 * sin(t * 6)
            case .listening: 0.06 * sin(t * 2.4)
            case .speaking: 0.10 * abs(sin(t * 5.5)) + 0.04 * sin(t * 13)
            }
            ZStack {
                Circle()
                    .fill(mode == .speaking ? Theme.speaking : Theme.accent)
                    .opacity(mode == .idle ? 0.25 : 0.45)
                    .frame(width: size * 1.55, height: size * 1.55)
                    .blur(radius: 26)
                    .scaleEffect(1 + pulse * 2.2)
                Circle()
                    .stroke(Theme.accent, lineWidth: 1.5)
                    .frame(width: size * 1.22, height: size * 1.22)
                    .opacity(mode == .listening ? 0.5 + 0.5 * sin(t * 2.4) : 0.0)
                    .scaleEffect(1 + pulse)
                Circle()
                    .fill(mode == .speaking ? Theme.speaking : Theme.accent)
                    .frame(width: size, height: size)
                    .overlay(Circle().fill(.white.opacity(0.18)).frame(width: size * 0.55).offset(x: -size * 0.14, y: -size * 0.16).blur(radius: 10))
                    .scaleEffect(1 + pulse)
                    .shadow(color: (mode == .speaking ? Theme.pink : Theme.cyan).opacity(0.55), radius: 22)
                Image(systemName: icon)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: mode == .speaking || mode == .connecting)
            }
            .frame(width: size * 1.6, height: size * 1.6)
        }
    }

    private var icon: String {
        switch mode {
        case .idle: return "waveform"
        case .connecting: return "ellipsis"
        case .listening: return "mic.fill"
        case .speaking: return "waveform"
        }
    }
}

/// A small rounded status pill.
struct StatusChip: View {
    let icon: String
    let text: String
    var ok = true

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke))
    }
}

/// One message in the conversation.
struct ChatBubble: View {
    let turn: Turn
    var live = false  // still being said

    var body: some View {
        let mine = turn.role == "user"
        HStack(alignment: .bottom) {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 8) {
                if let image = turn.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !turn.text.isEmpty {
                    Text(turn.text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background {
                            if mine {
                                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.accent).opacity(live ? 0.6 : 0.9)
                            } else {
                                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card)
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
                            }
                        }
                        .opacity(live ? 0.85 : 1)
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A suggestion card for the empty conversation.
struct SuggestionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(14)
            .card(radius: 18)
        }
        .buttonStyle(.plain)
    }
}

/// A round secondary control (keyboard, camera, kitchen, settings).
struct RoundButton: View {
    let icon: String
    var size: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.card, in: Circle())
                .overlay(Circle().stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}
