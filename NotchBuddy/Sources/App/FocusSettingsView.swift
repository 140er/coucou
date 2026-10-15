import SwiftUI

/// Settings → Focus: the session's length, macOS Focus through Shortcuts, and the time spent
/// on each project.
struct FocusSettingsView: View {
    @ObservedObject private var focus = FocusSession.shared
    @ObservedObject private var time = ProjectTime.shared
    @State private var period: Period = .today

    enum Period: String, CaseIterable, Identifiable {
        case today, week
        var id: String { rawValue }
        var label: String {
            self == .today ? String(localized: "focus.today") : String(localized: "focus.week")
        }
        var start: Date {
            let today = Calendar.current.startOfDay(for: Date())
            return self == .today ? today : (Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today)
        }
    }

    var body: some View {
        GroupBox(String(localized: "Focus")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("focus.about")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("focus.length")
                    Stepper(value: $focus.minutes, in: 5...180, step: 5) {
                        Text(String(format: String(localized: "focus.minutes %lld"), focus.minutes))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Text("focus.break")
                    Stepper(value: $focus.breakMinutes, in: 0...30) {
                        Text(focus.breakMinutes == 0 ? String(localized: "focus.no-break")
                             : String(format: String(localized: "focus.minutes %lld"), focus.breakMinutes))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                HStack(spacing: 10) {
                    Button(focus.phase == .off ? String(localized: "focus.start") : String(localized: "focus.stop")) {
                        focus.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(verbatim: status(at: timeline.date))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(String(format: String(localized: "focus.shortcut-hint %@"),
                            ShortcutLogic.displayString(for: ShortcutLogic.hotKey(for: .focusToggle))))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }

        #if !APPSTORE
        GroupBox(String(localized: "focus.macos")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("focus.macos-about")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("focus.shortcut-on")
                        .frame(width: 120, alignment: .leading)
                    TextField(String(localized: "focus.shortcut-placeholder"), text: $focus.shortcutOn)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                HStack(spacing: 8) {
                    Text("focus.shortcut-off")
                        .frame(width: 120, alignment: .leading)
                    TextField(String(localized: "focus.shortcut-placeholder"), text: $focus.shortcutOff)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                Button(String(localized: "focus.open-shortcuts")) {
                    if let url = URL(string: "shortcuts://") { NSWorkspace.shared.open(url) }
                }
            }
            .padding(6)
        }
        #endif

        GroupBox(String(localized: "focus.projects")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "focus.track"), isOn: Binding(get: { time.enabled }, set: { time.enabled = $0 }))
                Text("focus.track-about")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if time.enabled {
                    Picker("", selection: $period) {
                        ForEach(Period.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    ProjectTimeBars(rows: time.totals(since: period.start))
                    Button(String(localized: "Clear history")) { time.clear() }
                }
            }
            .padding(6)
        }
    }

    private func status(at now: Date) -> String {
        switch focus.phase {
        case .off:
            return String(format: String(localized: "focus.done-today %lld"), focus.doneToday)
        case .focus:
            return String(format: String(localized: "focus.left %@"), focus.remainingText(at: now))
        case .rest:
            return String(format: String(localized: "focus.break-left %@"), focus.remainingText(at: now))
        }
    }
}

/// The projects you spent the most time on, with a bar each.
private struct ProjectTimeBars: View {
    let rows: [(project: String, seconds: Double)]

    var body: some View {
        let top = Array(rows.prefix(8))
        let most = max(1, top.first?.seconds ?? 1)
        if top.isEmpty {
            Text("focus.no-time")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        ForEach(top, id: \.project) { row in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: row.project)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: Self.duration(row.seconds))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color(hex: "#A78BFA"))
                            .frame(width: max(4, geo.size.width * row.seconds / most))
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: 420)
        }
    }

    /// "3 h 12" or "18 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(format: String(localized: "focus.min %lld"), minutes) }
        return String(format: String(localized: "focus.hours %lld %lld"), minutes / 60, minutes % 60)
    }
}
