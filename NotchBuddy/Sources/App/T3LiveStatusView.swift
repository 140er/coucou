import SwiftUI

// Standalone view: previews use the same card renderer as the live source.
struct T3ActivityCardView: View {
    let card: T3ActivityCard
    let now: Date
    var tint = Color(hex: "#38BDF8")
    var stopping = false
    var answering = false
    var onStop: () -> Void = {}
    var onOpen: () -> Void = {}
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}
    var onQuestion: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        switch card.status {
        case .approval, .question: .blue
        case .done: .green
        case .error: .red
        default: tint
        }
    }
    private var title: String {
        switch card.status {
        case .approval: "Needs your approval to run \(card.approvalPrompt ?? "command")"
        case .question: "Needs your answer"
        case .done:
            "Done" + (card.elapsed(now: now).map { " in \(T3ActivityTime.text($0))" } ?? "") +
                (card.filesChanged.map { " · \($0) \($0 == 1 ? "file" : "files") changed" } ?? "")
        case .error: "Run failed"
        default: card.action
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text("T3")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)
                    .background(accent.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(card.status == .running && !reduceMotion ? 0.84 + 0.16 * sin(now.timeIntervalSince1970 * .pi / 2) : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: Int(now.timeIntervalSince1970))
                Image(systemName: card.status == .done ? "checkmark.circle.fill" : card.status == .approval ? "hand.raised" : card.icon)
                    .font(.system(size: 12)).foregroundStyle(accent).frame(width: 14, height: 24)
                Text(title)
                    .font(.system(size: 12, weight: .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentTransition(.interpolate)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: title)
                    .help(title)
                if card.status != .done, let elapsed = card.elapsed(now: now) {
                    Text(T3ActivityTime.text(elapsed)).font(.system(size: 11, design: .monospaced))
                        .monospacedDigit().foregroundStyle(.secondary).frame(height: 24)
                }
            }
            HStack {
                if !card.model.isEmpty { Text(card.model).lineLimit(1) }
                Spacer(minLength: 8)
                if let step = card.stepNumber { Text("Step \(step) of \(card.plan.count)") }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            if !card.plan.isEmpty {
                HStack(spacing: card.plan.count > 32 ? 0.5 : 3) {
                    ForEach(Array(card.plan.enumerated()), id: \.offset) { _, step in
                        Capsule().fill(card.status == .done || step.status == "completed" ? accent : step.status == "running" ? accent.opacity(0.8) : Color.white.opacity(0.1))
                    }
                }.frame(height: 4)
                .accessibilityLabel("Step \(card.stepNumber ?? 0) of \(card.plan.count)")
            }
            if !card.log.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(card.log) { step in
                        let active = step.running && [.running, .approval, .question].contains(card.status)
                        HStack(spacing: 7) {
                            Image(systemName: active ? step.icon : step.status == "failed" ? "xmark" : "checkmark")
                                .font(.system(size: 9)).frame(width: 12)
                            Text(active ? step.activeLabel : step.doneLabel).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .help(active ? step.activeLabel : step.doneLabel)
                            if let elapsed = T3ActivityTime.elapsed(start: step.startedAt,
                                end: active ? nil : step.completedAt ?? card.completedAt, now: now) {
                                Text(T3ActivityTime.text(elapsed)).monospacedDigit()
                            }
                        }.font(.system(size: 11)).foregroundStyle(active ? Color.white : Color(hex: "#95989F"))
                    }
                }.clipped()
            }
            HStack(spacing: 8) {
                if card.status == .approval {
                    Button("Approve", action: onApprove).buttonStyle(.borderedProminent).tint(.blue).disabled(answering)
                    Button("Deny", action: onDeny).buttonStyle(.bordered).disabled(answering)
                } else if card.status == .question {
                    Button("Answer", action: onQuestion).buttonStyle(.borderedProminent).tint(.blue)
                } else if card.status == .running {
                    Button(action: onStop) {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill").font(.system(size: 8))
                            Text(stopping ? "Stopping…" : "Stop")
                        }.padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.white.opacity(0.07)).clipShape(Capsule())
                    }.buttonStyle(.plain).disabled(stopping)
                }
                Spacer()
                Button("Open run ↗", action: onOpen).buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 11))
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#17181C"))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(accent.opacity(card.status == .approval ? 0.5 : 0.13), lineWidth: 1))
        .foregroundStyle(Color(hex: "#F3F4F6"))
    }
}

struct T3ActivityChildView: View {
    let child: T3ActivityChild
    let now: Date
    var tint = Color(hex: "#38BDF8")
    var stopping = false
    var onStop: () -> Void = {}
    var onOpen: () -> Void = {}
    var onRequest: () -> Void = {}
    private var mark: String {
        switch child.status {
        case .running: "circle.fill"
        case .approval, .question: "exclamationmark.bubble.fill"
        case .error: "xmark.circle"
        default: "checkmark.circle"
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            if child.status == .approval || child.status == .question {
                Button(action: onRequest) { Image(systemName: mark).foregroundStyle(.blue).frame(width: 13) }
                    .buttonStyle(.plain).help("Answer request")
            } else {
                Image(systemName: mark).font(.system(size: child.status == .running ? 7 : 11))
                    .foregroundStyle(child.status == .error ? Color.red : child.status == .done ? .green : tint).frame(width: 13)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(child.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(child.action).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).help("\(child.title) · \(child.action)")
            if child.handoff {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 10)).foregroundStyle(.green)
                    .help("Handed off").accessibilityLabel("Handed off")
            }
            if let seconds = T3ActivityTime.elapsed(start: child.startedAt,
                end: child.status == .running ? nil : child.completedAt, now: now) {
                Text(T3ActivityTime.text(seconds)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if child.stop != nil {
                Button(action: onStop) { Image(systemName: "stop.fill").font(.system(size: 9)) }
                    .buttonStyle(.plain).disabled(stopping).help("Stop agent")
            }
            Button(action: onOpen) { Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                .buttonStyle(.plain).help("Open run")
        }.padding(.horizontal, 11).padding(.vertical, 8)
        .background(Color(hex: "#15161A")).clipShape(RoundedRectangle(cornerRadius: 9))
        .foregroundStyle(Color(hex: "#E9EAED"))
    }
}

struct T3LiveStatusView: View {
    @ObservedObject private var source = T3CodeSource.shared
    @ObservedObject private var app = AppState.shared
    private var tint: Color { Color(hex: app.focusTask?.color ?? "#38BDF8") }
    var body: some View {
        if let card = source.activityCard {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(spacing: 6) {
                        T3ActivityCardView(card: card, now: context.date, tint: tint,
                            stopping: source.stopping.contains(T3ActivityStop.thread(card.threadId).key),
                            answering: request(card).map { source.deciding.contains($0.id) } ?? false,
                            onStop: { source.stopActivity(.thread(card.threadId)) },
                            onOpen: { source.open(thread: source.session.threads[card.threadId]) },
                            onApprove: { if let request = request(card) { source.respond(request, accept: true) } },
                            onDeny: { if let request = request(card) { source.respond(request, accept: false) } },
                            onQuestion: { source.showRequests(threadId: card.threadId) })
                        ForEach(source.activityChildren) { child in
                            T3ActivityChildView(child: child, now: context.date, tint: tint,
                                stopping: child.stop.map { source.stopping.contains($0.key) } ?? false,
                                onStop: { if let target = child.stop { source.stopActivity(target) } },
                                onOpen: { source.open(thread: source.session.threads[child.threadId]) },
                                onRequest: { source.showRequests(threadId: child.threadId) })
                        }
                        if let error = source.activityError { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                    }.padding(6)
                }
            }
        } else {
            T3CodeCardView(pillId: app.focusId ?? T3ProjectPill.fallbackId)
        }
    }
    private func request(_ card: T3ActivityCard) -> T3PendingRequest? {
        source.pendingRequests.first { $0.threadId == card.threadId }
    }
}

#if DEBUG
struct T3LiveStatusPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            preview(.running).previewDisplayName("Running · orchestrator and children")
            preview(.approval).previewDisplayName("Approval · npm test")
            preview(.done).previewDisplayName("Done · handoff retained")
        }
    }
    private static func preview(_ scenario: T3ActivityFixtures.Scenario) -> some View {
        let scene = T3ActivityFixtures.scene(scenario)
        return VStack(spacing: 6) {
            T3ActivityCardView(card: scene.card, now: T3ActivityFixtures.now)
            ForEach(scene.children) { child in
                T3ActivityChildView(child: child, now: T3ActivityFixtures.now)
            }
        }
        .padding(12).frame(width: 390)
        .background(Color.black).preferredColorScheme(.dark)
    }
}
#endif
