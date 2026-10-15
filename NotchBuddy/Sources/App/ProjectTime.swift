import AppKit
import ApplicationServices
import CoreGraphics

/// Time per project, like WakaTime but without anything leaving the Mac: while a code editor
/// (VS Code, Cursor, Xcode, Zed…) or a terminal running an agent is in front, its project gets
/// the time. Event-driven: Coucou looks when the app in front changes, never on a timer.
///
/// The project is the folder open in the editor (read from its window title) or the folder a
/// Claude Code session runs in. Kept 90 days in Application Support/NotchBuddy/projecttime.json.
@MainActor
final class ProjectTime: ObservableObject {
    static let shared = ProjectTime()

    static let enabledKey = "projectTimeEnabled"

    /// Seconds per project, per day ("2026-10-15" → ["landing": 4320]).
    @Published private(set) var days: [String: [String: Double]] = [:]

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            if newValue { follow(NSWorkspace.shared.frontmostApplication) } else { close(at: Date()) }
        }
    }

    /// The project in front, and since when.
    private var current: (project: String, since: Date)?
    private var started = false

    private static let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NotchBuddy/projecttime.json")
    }()

    private init() { load() }

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                ProjectTime.shared.follow(pid.flatMap { NSRunningApplication(processIdentifier: $0) })
            }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ProjectTime.shared.close(at: Date()) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ProjectTime.shared.follow(NSWorkspace.shared.frontmostApplication) }
            }
        }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ProjectTime.shared.close(at: Date()) }
        }
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ProjectTime.shared.follow(NSWorkspace.shared.frontmostApplication) }
        }
        follow(NSWorkspace.shared.frontmostApplication)
    }

    /// Saves what is running (Coucou quits).
    func flush() { close(at: Date()) }

    // MARK: - Following the app in front

    private func follow(_ app: NSRunningApplication?) {
        let now = Date()
        close(at: now)
        guard enabled, let app, let project = Self.project(for: app) else { return }
        current = (project, now)
    }

    private func close(at end: Date) {
        guard let open = current else { return }
        current = nil
        var seconds = end.timeIntervalSince(open.since)
        // Away from the keyboard for more than 5 minutes: that part does not count.
        let idle = Self.secondsIdle()
        if idle > 300 { seconds -= idle }
        guard seconds > 5 else { return }
        let day = Self.dayKey(open.since)
        days[day, default: [:]][open.project, default: 0] += seconds
        save()
    }

    // MARK: - Reading it

    /// Seconds per project since `start` (today's start, the week's…), the one in front included.
    func totals(since start: Date) -> [(project: String, seconds: Double)] {
        let first = Self.dayKey(start)
        var sum: [String: Double] = [:]
        for (day, projects) in days where day >= first {
            for (project, seconds) in projects { sum[project, default: 0] += seconds }
        }
        if let open = current, open.since >= Calendar.current.startOfDay(for: start) {
            sum[open.project, default: 0] += Date().timeIntervalSince(open.since)
        }
        return sum.map { (project: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    func clear() {
        current = nil
        days = [:]
        save()
        follow(NSWorkspace.shared.frontmostApplication)
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Which project

    /// Code editors, by bundle id prefix: the project comes from their window title.
    private static let editors = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "dev.zed.Zed", "com.apple.dt.Xcode", "com.jetbrains.", "com.sublimetext.", "com.google.antigravity",
        "com.vscodium",
    ]

    static func project(for app: NSRunningApplication) -> String? {
        guard let id = app.bundleIdentifier else { return nil }
        if editors.contains(where: { id.hasPrefix($0) }) {
            let title = windowTitle(of: app) ?? ""
            return projectName(fromTitle: title, bundleId: id) ?? app.localizedName
        }
        if TerminalTarget.knownTerminals.contains(id) {
            // The terminal of an agent session: its folder.
            let sessions = AppState.shared.tasks.filter { !$0.isIntegration && $0.sessionCwd != nil }
            let own = sessions.first { $0.hostApp == id } ?? sessions.first
            if let cwd = own?.sessionCwd {
                let name = URL(fileURLWithPath: cwd).lastPathComponent
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    /// "page.tsx — landing — Visual Studio Code" → "landing"; Xcode's "App — Foo.swift" → "App";
    /// JetBrains' "app – Main.kt" → "app".
    static func projectName(fromTitle title: String, bundleId: String) -> String? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if bundleId == "com.apple.dt.Xcode" || bundleId.hasPrefix("com.jetbrains.") {
            let first = clean.components(separatedBy: bundleId.hasPrefix("com.jetbrains.") ? " – " : " — ").first ?? clean
            let name = first.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        var parts = clean.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 1 { parts.removeLast() }          // the app's name
        let name = parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: "●• ")) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The title of the app's front window (Accessibility; nil without it).
    private static func windowTitle(of app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    private static func secondsIdle() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else { return }
        days = decoded
    }

    private func save() {
        let oldest = Self.dayKey(Date().addingTimeInterval(-90 * 86400))
        days = days.filter { $0.key >= oldest }
        let url = Self.storageURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: url, options: .atomic) }
    }
}
