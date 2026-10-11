#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// MARK: - VoiceCaptionState

/// Holds the two text lines shown in the caption capsule.
/// Mutated only from @MainActor (VoiceCaptionManager).
final class VoiceCaptionState: ObservableObject {
    @Published var userLine: String = ""
    @Published var responseLine: String = ""
    @Published var isVisible: Bool = false
    /// Live words while the mic is open for a command (mirrors VoiceEngine).
    @Published var liveLine: String = ""
    @Published var isListening: Bool = false
    /// Capsule is expanded (full response readable, scrollable).
    @Published var isExpanded: Bool = false
}

// MARK: - VoiceCaptionManager
//
// Manages a borderless, non-activating NSPanel positioned below the notch center.
// Shows a compact capsule with:
//   – user transcript (gray, top line)
//   – AI response    (white, bottom line, streams in)
// Tap the capsule to expand (full response + scroll). Tap again or click elsewhere to close.
// Fades in/out in 0.2 s. Auto-hides 2 s after endConversation().
// Repositions with the island using the same open spring (0.5 s ease-out).
//
// Usage:
//   VoiceCaptionManager.shared.show(on: screen, notchHeight: 36)
//   VoiceCaptionManager.shared.setUserLine("Ajoute GitHub")
//   VoiceCaptionManager.shared.appendResponse("D'accord.")
//   VoiceCaptionManager.shared.endConversation()

@MainActor
final class VoiceCaptionManager {
    static let shared = VoiceCaptionManager()

    let state = VoiceCaptionState()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var subs: Set<AnyCancellable> = []
    private var mouseMonitors: [Any] = []

    /// The panel never changes size: only the capsule inside it unfolds, in one SwiftUI spring,
    /// so the black background and the text always move together. The panel is transparent
    /// and lets clicks through, except over the capsule itself.
    static let panelWidth:  CGFloat = 400
    static let panelHeight: CGFloat = 300
    private let notchGap:   CGFloat = 6

    /// Height of the black capsule, reported by the view (it follows the answer's length).
    var capsuleHeight: CGFloat = 0 {
        didSet { if capsuleHeight != oldValue { updateMouseAcceptance() } }
    }

    private init() {
        // Only these engine properties: observing the whole engine redraws on every mic frame.
        let engine = VoiceEngine.shared
        engine.$commandTranscript
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                MainActor.assumeIsolated { self?.state.liveLine = t }
            }
            .store(in: &subs)
        // Follow the island: it can open or close while speaking.
        let app = AppState.shared
        app.$mode.combineLatest(app.$view)
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition(animated: true) }
            }
            .store(in: &subs)
        engine.$isListeningForCommand
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state.isListening = on
                    if on { self.state.liveLine = "" }
                }
            }
            .store(in: &subs)
        // Collapse on tap-outside (global mouse-down while expanded).
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.state.isExpanded == true else { return }
                self?.setExpanded(false, animated: true)
            }
        }
    }

    // MARK: - Show / hide

    func show(on screen: NSScreen, notchHeight: CGFloat) {
        guard VoiceSettings.captionEnabled else { return }
        hideTask?.cancel()
        hideTask = nil
        state.isExpanded = false

        if panel == nil { _buildPanel() }
        self.screen = screen
        reposition(animated: false)

        guard let p = panel else { return }
        if !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }

        state.isVisible = true
        startMouseTracking()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
    }

    func hide(after delay: TimeInterval = 0) {
        state.isExpanded = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self._fadeOut() }
        }
    }

    // MARK: - Content updates

    func setUserLine(_ text: String) {
        state.userLine = text
        state.responseLine = ""
        state.isExpanded = false
    }

    func appendResponse(_ chunk: String) {
        if state.responseLine.isEmpty {
            state.responseLine = chunk
        } else {
            state.responseLine += " " + chunk
        }
    }

    func clearResponse() {
        state.responseLine = ""
    }

    /// Call when the conversation ends. Panel fades out after 2 s.
    func endConversation() {
        hide(after: 2.0)
    }

    // MARK: - Expand / collapse

    /// Called from VoiceCaptionView tap gesture.
    func toggleExpanded() {
        setExpanded(!state.isExpanded, animated: true)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard state.isExpanded != expanded else { return }
        state.isExpanded = expanded
    }

    // MARK: - Private

    private func _buildPanel() {
        let size = NSSize(width: Self.panelWidth, height: Self.panelHeight)
        let view = NSHostingView(rootView: VoiceCaptionView(state: state, manager: self))
        view.frame = NSRect(origin: .zero, size: size)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Same level as the island, so the caption is never hidden behind it.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = view
        p.alphaValue = 0
        panel = p
    }

    private var screen: NSScreen?

    /// Just under the visible island (compact, open or hidden), centred on it.
    /// Uses the same open spring duration as the island (easeOut 0.5 s).
    private func reposition(animated: Bool) {
        guard let p = panel, let screen else { return }
        let app = AppState.shared
        let (_, fixedH) = islandSize(mode: app.mode, view: app.view, progress: app.uploadProgress,
                                     nw: app.notchWidth, nh: app.notchHeight)
        var islandH = fixedH
        if app.mode == .expanded && app.view == .prompt {
            islandH = min(300, 240 + CGFloat(app.chatHistory.count) * 40)
        }
        let visibleH = max(islandH, app.notchHeight)
        let sf = screen.frame
        let w = Self.panelWidth, h = Self.panelHeight
        // The capsule sits at the top of the panel, notchGap below the island; it unfolds downward.
        let origin = NSPoint(x: sf.midX - w / 2, y: sf.maxY - visibleH - notchGap - h)
        let newFrame = NSRect(origin: origin, size: NSSize(width: w, height: h))

        if animated && p.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                // Match the island's open spring (response 0.5, damping 0.72 ≈ easeOut 0.5 s).
                ctx.duration = 0.5
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(newFrame, display: true)
            }
        } else {
            p.setFrame(newFrame, display: true)
        }
        updateMouseAcceptance()
    }

    // MARK: - Clicks only on the capsule

    private func startMouseTracking() {
        guard mouseMonitors.isEmpty else { updateMouseAcceptance(); return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMouseAcceptance() }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            Task { @MainActor [weak self] in self?.updateMouseAcceptance() }
            return e
        }) { mouseMonitors.append(l) }
        updateMouseAcceptance()
    }

    private func stopMouseTracking() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
        panel?.ignoresMouseEvents = true
    }

    private func updateMouseAcceptance() {
        guard let p = panel, state.isVisible, capsuleHeight > 0 else {
            if panel?.ignoresMouseEvents == false { panel?.ignoresMouseEvents = true }
            return
        }
        let f = p.frame
        let capsule = NSRect(x: f.minX, y: f.maxY - capsuleHeight, width: f.width, height: capsuleHeight)
        let inside = capsule.contains(NSEvent.mouseLocation)
        if p.ignoresMouseEvents == inside { p.ignoresMouseEvents = !inside }
    }

    private func _fadeOut() {
        state.isVisible = false
        state.isExpanded = false
        stopMouseTracking()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in self.panel?.orderOut(nil) }
        })
    }
}

// MARK: - VoiceCaptionView
//
// One black capsule. Folded: what I said + the first two lines of the answer, with a small chevron
// when there is more. Unfolded: the capsule grows to fit the whole answer (up to maxBody, then it
// scrolls). The height is measured from the text itself, and the text is clipped by the capsule,
// so the background and the words open together in the same spring.

struct VoiceCaptionView: View {
    @ObservedObject var state: VoiceCaptionState
    let manager: VoiceCaptionManager

    @State private var fullHeight: CGFloat = 0
    @State private var twoLineHeight: CGFloat = 0

    private static let hPad: CGFloat = 14
    private static let vPad: CGFloat = 9
    private static let chevronRoom: CGFloat = 14
    private static let maxBody: CGFloat = 250
    private static let radius: CGFloat = 14
    private var textWidth: CGFloat { VoiceCaptionManager.panelWidth - 2 * Self.hPad - Self.chevronRoom }
    private let answerFont = Font.system(size: 12, weight: .medium)

    /// While the mic is open: what I am saying, live. Afterwards: what I said + the answer.
    private var heard: String {
        guard state.isListening else { return state.userLine }
        return state.liveLine.isEmpty
            ? VoiceActionRunner.localizedString("voice.caption-listening", locale: VoiceSettings.answerLocale)
            : state.liveLine
    }
    private var answer: String { state.isListening ? "" : state.responseLine }

    /// More than two lines: the chevron shows and a tap unfolds.
    private var hasMore: Bool { twoLineHeight > 0 && fullHeight > twoLineHeight + 1 }
    private var expanded: Bool { state.isExpanded && hasMore }
    private var bodyHeight: CGFloat {
        guard !answer.isEmpty else { return 0 }
        return expanded ? min(fullHeight, Self.maxBody) : min(fullHeight, twoLineHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !heard.isEmpty || !answer.isEmpty {
                capsule.transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: VoiceCaptionManager.panelWidth, height: VoiceCaptionManager.panelHeight, alignment: .top)
        .background(alignment: .topLeading) { measurement }
        .animation(.easeOut(duration: 0.2), value: heard.isEmpty && answer.isEmpty)
        .environment(\.colorScheme, .dark)
    }

    private var capsule: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 3) {
            if !heard.isEmpty {
                Text(verbatim: heard)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: textWidth, alignment: .leading)
            }
            if !answer.isEmpty {
                answerText
                    .frame(width: textWidth, height: bodyHeight, alignment: .topLeading)
                    .clipped()
            }
        }
        .padding(.leading, Self.hPad)
        .padding(.trailing, Self.hPad + Self.chevronRoom)
        .padding(.vertical, Self.vPad)
        .frame(width: VoiceCaptionManager.panelWidth, alignment: .leading)
        .background(shape.fill(Color.black.opacity(0.92)))
        .overlay(alignment: .bottomTrailing) {
            if hasMore {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .padding(.trailing, 12)
                    .padding(.bottom, Self.vPad + 2)
            }
        }
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { if hasMore { manager.toggleExpanded() } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { manager.capsuleHeight = $0 }
        .onDisappear { manager.capsuleHeight = 0 }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: expanded)
        .animation(.easeOut(duration: 0.2), value: fullHeight)
    }

    @ViewBuilder private var answerText: some View {
        if expanded && fullHeight > Self.maxBody {
            ScrollView(.vertical, showsIndicators: false) {
                Text(verbatim: answer)
                    .font(answerFont)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: textWidth, alignment: .leading)
            }
        } else {
            Text(verbatim: answer)
                .font(answerFont)
                .foregroundColor(.white)
                .lineLimit(expanded ? nil : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .leading)
        }
    }

    /// Invisible copies of the answer, laid out at the same width: its full height and the height of two lines.
    private var measurement: some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: answer.isEmpty ? " " : answer)
                .font(answerFont)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            Text(verbatim: "A\nA")
                .font(answerFont)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { twoLineHeight = $0 }
        }
        .hidden()
        .allowsHitTesting(false)
    }
}
#endif
