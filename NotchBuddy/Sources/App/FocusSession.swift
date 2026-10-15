import AppKit
import Foundation

/// A Focus session: a timer in the island (25 minutes by default), Mochi with his headphones on,
/// and Coucou keeping quiet until it ends. A permission request or a question from an agent still
/// comes through: an agent must never wait on a timer. Then a short break, and back to normal.
///
/// One timer for the end of the session, nothing ticking in between: the island draws the time
/// left only while it is on screen.
@MainActor
final class FocusSession: ObservableObject {
    static let shared = FocusSession()

    enum Phase: Equatable { case off, focus, rest }

    @Published private(set) var phase: Phase = .off
    /// When the session (or the break) ends.
    @Published private(set) var endsAt: Date? = nil
    /// Alerts held back during the session (finished or failed turns).
    @Published private(set) var held = 0

    @Published var minutes: Int {
        didSet { UserDefaults.standard.set(minutes, forKey: Self.minutesKey) }
    }
    @Published var breakMinutes: Int {
        didSet { UserDefaults.standard.set(breakMinutes, forKey: Self.breakKey) }
    }
    /// Shortcuts (the macOS app) run when a session starts and ends, to turn a Focus of macOS on
    /// and off: an app can't do that by itself. Empty: none.
    @Published var shortcutOn: String {
        didSet { UserDefaults.standard.set(shortcutOn, forKey: Self.shortcutOnKey) }
    }
    @Published var shortcutOff: String {
        didSet { UserDefaults.standard.set(shortcutOff, forKey: Self.shortcutOffKey) }
    }

    static let minutesKey = "focusMinutes"
    static let breakKey = "focusBreakMinutes"
    static let shortcutOnKey = "focusShortcutOn"
    static let shortcutOffKey = "focusShortcutOff"
    private static let doneKey = "focusDoneByDay"

    /// The sounds that still play during a session: what an agent waiting on you makes.
    static let soundsDuringFocus: Set<String> = ["approval", "question", "approve"]

    private var work: DispatchWorkItem?

    private init() {
        let ud = UserDefaults.standard
        minutes = max(1, ud.object(forKey: Self.minutesKey) as? Int ?? 25)
        breakMinutes = max(0, ud.object(forKey: Self.breakKey) as? Int ?? 5)
        shortcutOn = ud.string(forKey: Self.shortcutOnKey) ?? ""
        shortcutOff = ud.string(forKey: Self.shortcutOffKey) ?? ""
    }

    /// Coucou keeps quiet: no sounds, the island no longer opens by itself.
    var isQuiet: Bool { phase == .focus }

    /// What Mochi wears: nothing but his headphones during a session.
    func wear(_ outfit: Outfit) -> Outfit { phase == .focus ? .none : outfit }

    // MARK: - Starting and stopping

    func start(minutes requested: Int? = nil) {
        let length = min(240, max(1, requested ?? minutes))
        SoundEngine.shared.play("tick")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        phase = .focus
        held = 0
        let end = Date().addingTimeInterval(TimeInterval(length * 60))
        endsAt = end
        schedule(at: end) { [weak self] in self?.finishFocus() }
        runShortcut(shortcutOn)
    }

    /// Ends the session or the break now.
    func stop() {
        work?.cancel()
        work = nil
        if phase == .focus { runShortcut(shortcutOff) }
        phase = .off
        endsAt = nil
        SoundEngine.shared.play("close")
    }

    /// The island's Focus button: start, or stop what is running.
    func toggle() {
        if phase == .off { start() } else { stop() }
    }

    /// An alert that would have opened the island, kept for the end of the session.
    func noteHeld() { held += 1 }

    private func finishFocus() {
        runShortcut(shortcutOff)
        countDone()
        if breakMinutes > 0 {
            phase = .rest
            let end = Date().addingTimeInterval(TimeInterval(breakMinutes * 60))
            endsAt = end
            schedule(at: end) { [weak self] in self?.finishBreak() }
        } else {
            phase = .off
            endsAt = nil
        }
        SoundEngine.shared.play("finish")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
        NotificationCenter.default.post(name: .hookReveal, object: nil)
    }

    private func finishBreak() {
        phase = .off
        endsAt = nil
        held = 0
        SoundEngine.shared.play("pop")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.wink)
        NotificationCenter.default.post(name: .hookReveal, object: nil)
    }

    private func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow), execute: item)
    }

    // MARK: - Reading it

    /// "18:42": the time left, rounded up to the second.
    func remainingText(at now: Date) -> String {
        guard let end = endsAt else { return "" }
        let left = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        return Self.clock(left)
    }

    /// 0…1: how much of the session or break is done.
    func progress(at now: Date) -> Double {
        guard let end = endsAt else { return 0 }
        let total = Double((phase == .rest ? breakMinutes : minutes) * 60)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - end.timeIntervalSince(now) / total))
    }

    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Sessions finished today.
    var doneToday: Int {
        let byDay = UserDefaults.standard.dictionary(forKey: Self.doneKey) as? [String: Int] ?? [:]
        return byDay[ProjectTime.dayKey(Date())] ?? 0
    }

    private func countDone() {
        var byDay = UserDefaults.standard.dictionary(forKey: Self.doneKey) as? [String: Int] ?? [:]
        let today = ProjectTime.dayKey(Date())
        byDay = byDay.filter { $0.key >= ProjectTime.dayKey(Date().addingTimeInterval(-30 * 86400)) }
        byDay[today, default: 0] += 1
        UserDefaults.standard.set(byDay, forKey: Self.doneKey)
    }

    // MARK: - macOS Focus through Shortcuts

    private func runShortcut(_ name: String) {
        #if !APPSTORE
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["run", trimmed]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { appendAppLog("nb.log", "[Focus] shortcut \(trimmed) failed: \(error)") }
        #endif
    }
}
