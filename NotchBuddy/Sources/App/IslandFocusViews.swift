import SwiftUI

// MARK: - How the Mac is doing (under the island)

/// A small line under the island while the pointer is on Mochi, when the Mac makes him react:
/// "CPU 94 % · node, Google Chrome", "Your Mac is hot", "Battery 14 %".
struct VitalsHoverLine: View {
    let islandW: CGFloat
    let islandH: CGFloat
    @ObservedObject private var vitals = MachineVitals.shared

    var body: some View {
        let show = vitals.hovered && vitals.summary != nil
        ZStack {
            if show, let text = vitals.summary {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(verbatim: text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#E1E3E6"))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.92)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: show)
        .position(x: islandW / 2, y: islandH + 18)
        .allowsHitTesting(false)
    }

    private var dotColor: Color {
        let m = vitals.mood
        if m.hot > 0 { return Color(hex: "#FF6B4A") }
        if m.busy > 0 { return Color(hex: "#3B9EFF") }
        if m.full > 0 { return Color(hex: "#A78BFA") }
        return Color(hex: "#F5A524")
    }
}

// MARK: - Focus in the compact island

/// The compact island's right side: the time left of a Focus session (or its break) in place
/// of the small Mochis of the pills.
struct CompactFocusOrGrid: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat
    @ObservedObject private var focus = FocusSession.shared

    var body: some View {
        if focus.phase == .off {
            CompactMiniGrid(state: state)
                .scaleEffect(IslandRestingLayout(width: islandW, height: islandH).miniGridScale)
                .position(x: islandW - 40, y: islandH / 2)
                .transition(.opacity)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(verbatim: focus.remainingText(at: timeline.date))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(FocusColors.tint(focus.phase))
                    .fixedSize()
            }
            .position(x: islandW - 38, y: islandH / 2)
            .transition(.opacity)
        }
    }
}

enum FocusColors {
    /// Violet during a session, green during the break.
    static func base(_ phase: FocusSession.Phase) -> Color {
        phase == .rest ? Color(hex: "#34D399") : Color(hex: "#A78BFA")
    }
    static func tint(_ phase: FocusSession.Phase) -> Color {
        phase == .rest ? Color(hex: "#6EE7B7") : Color(hex: "#C4B5FD")
    }
}

// MARK: - Focus in the island's header

/// The header's timer: a click starts a Focus session; while it runs, the time left, and a click
/// asks "Stop?" (a second click stops it).
struct FocusHeaderButton: View {
    @ObservedObject private var focus = FocusSession.shared
    @State private var hovered = false
    @State private var confirmStop = false

    var body: some View {
        Button(action: tap) {
            if focus.phase == .off {
                Image(systemName: "timer")
                    .font(.system(size: 14))
                    .foregroundColor(hovered ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let color = FocusColors.base(focus.phase)
                    HStack(spacing: 4) {
                        Image(systemName: focus.phase == .focus ? "headphones" : "cup.and.saucer.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(verbatim: confirmStop ? String(localized: "focus.stop?")
                                                   : focus.remainingText(at: timeline.date))
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .foregroundColor(FocusColors.tint(focus.phase))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(color.opacity(hovered || confirmStop ? 0.26 : 0.16)))
                    .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(focus.phase == .off
              ? String(format: String(localized: "focus.start-help %lld"), focus.minutes)
              : String(localized: "focus.stop-help"))
    }

    private func tap() {
        if focus.phase == .off {
            focus.start()
            return
        }
        if confirmStop {
            focus.stop()
            confirmStop = false
        } else {
            confirmStop = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmStop = false
            }
        }
    }
}
