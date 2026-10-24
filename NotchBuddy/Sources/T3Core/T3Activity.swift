import Foundation

enum T3ActivityTime {
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func elapsed(start: Date?, end: Date?, now: Date) -> TimeInterval? {
        start.map { max(0, (end ?? now).timeIntervalSince($0)) }
    }
    static func text(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds))s" }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

struct T3Handoff: Equatable, Sendable {
    let targetThreadId: String
    let sentAt: Date
    init?(_ raw: [String: Any]) {
        guard let target = raw["targetThreadId"] as? String,
              let sent = T3ActivityTime.date(raw["sentAt"] as? String) else { return nil }
        targetThreadId = target; sentAt = sent
    }
}

struct T3ActivityStep: Identifiable, Equatable, Sendable {
    let id: String
    let runId: String?
    let ordinal: Int
    let kind: String
    let status: String
    let activeLabel: String
    let doneLabel: String
    let startedAt: Date?
    let completedAt: Date?
    let fileName: String?
    let childThreadId: String?
    let subagentId: String?
    let nativeSubagent: Bool
    var running: Bool { status == "running" }
    var label: String { running ? activeLabel : doneLabel }
    var icon: String {
        switch kind {
        case "command_execution": "terminal"
        case "file_change": "pencil"
        case "file_search": "doc.text.magnifyingglass"
        case "web_search": "globe"
        case "subagent": "person.2"
        case "reasoning": "sparkle"
        default: "wrench.and.screwdriver"
        }
    }
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, let kind = raw["type"] as? String,
              ["command_execution", "file_change", "file_search", "web_search", "dynamic_tool", "subagent", "reasoning"].contains(kind) else { return nil }
        self.id = id; self.kind = kind
        runId = raw["runId"] as? String; ordinal = raw["ordinal"] as? Int ?? 0
        status = raw["status"] as? String ?? "pending"
        startedAt = T3ActivityTime.date(raw["startedAt"] as? String)
        completedAt = T3ActivityTime.date(raw["completedAt"] as? String)
        fileName = raw["fileName"] as? String
        childThreadId = raw["childThreadId"] as? String
        subagentId = raw["subagentId"] as? String
        nativeSubagent = raw["origin"] as? String == "provider_native"
        let title = Self.short(raw["title"] as? String ?? "")
        let input = raw["input"] as? [String: Any] ?? [:]
        let target = Self.short(fileName ?? input["file_path"] as? String ?? input["path"] as? String ?? title)
        switch kind {
        case "file_change":
            activeLabel = "Editing \(target)"; doneLabel = "Edited \(target)"
        case "command_execution":
            let command = Self.short(raw["input"] as? String ?? title)
            activeLabel = "Running \(command)"; doneLabel = "Ran \(command)"
        case "file_search":
            let pattern = Self.short(raw["pattern"] as? String ?? title)
            activeLabel = pattern.isEmpty ? "Searching files" : "Searching files · \(pattern)"
            doneLabel = pattern.isEmpty ? "Searched files" : "Searched files · \(pattern)"
        case "web_search":
            let pattern = Self.short((raw["patterns"] as? [String])?.first ?? title)
            activeLabel = pattern.isEmpty ? "Searching the web" : "Searching the web · \(pattern)"
            doneLabel = pattern.isEmpty ? "Searched the web" : "Searched the web · \(pattern)"
        case "reasoning": activeLabel = "Thinking"; doneLabel = "Thought through next step"
        case "subagent":
            let progress = Self.short(raw["progress"] as? String ?? raw["prompt"] as? String ?? title)
            activeLabel = progress.isEmpty ? "Delegating work" : progress
            doneLabel = title.isEmpty ? "Delegated work" : "Completed \(title)"
        default:
            let tool = Self.short(raw["toolName"] as? String ?? title)
            if tool.lowercased().contains("read") {
                activeLabel = target.isEmpty ? "Reading files" : "Reading \(target)"
                doneLabel = target.isEmpty ? "Read files" : "Read \(target)"
            } else {
                activeLabel = tool.isEmpty ? "Using tool" : "Using \(tool)"
                doneLabel = tool.isEmpty ? "Used tool" : "Used \(tool)"
            }
        }
    }
    static func short(_ value: String) -> String {
        String(value.split(whereSeparator: { $0.isNewline }).first.map(String.init)?.prefix(240) ?? "")
    }
}

struct T3ActivityPlanStep: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let status: String
    let durationMs: Int?
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, let text = raw["text"] as? String else { return nil }
        self.id = id; self.text = T3ActivityStep.short(text)
        status = raw["status"] as? String ?? "pending"
        durationMs = raw["durationMs"] as? Int
    }
}

// Snapshot replacement and event upserts are deliberately independent of SwiftUI.
// Tool outputs/diffs are never retained here. A bounded log plus cumulative file
// sets preserves the summary when old rows roll out.
struct T3ActivityReducer: Equatable, Sendable {
    private(set) var items: [String: T3ActivityStep] = [:]
    private var plans: [String: Plan] = [:]
    private var files: [String: Set<String>] = [:]
    private var fileRuns: [String] = []
    private var planRevision = 0
    private(set) var loaded = false
    private struct Plan: Equatable, Sendable {
        let runId: String?
        let ordinal: Int
        let steps: [T3ActivityPlanStep]
    }
    mutating func apply(_ envelope: [String: Any]) {
        if envelope["kind"] as? String == "snapshot" {
            let snapshot = envelope["snapshot"] as? [String: Any]
            guard let projection = (envelope["projection"] ?? snapshot?["projection"]) as? [String: Any] else { return }
            self = T3ActivityReducer(); loaded = true
            for raw in projection["turnItems"] as? [[String: Any]] ?? [] { upsert(raw) }
            // Some bounded projections put local items only in the visible list.
            for row in projection["visibleTurnItems"] as? [[String: Any]] ?? [] {
                if let raw = row["item"] as? [String: Any], let id = raw["id"] as? String, items[id] == nil { upsert(raw) }
            }
            for plan in projection["plans"] as? [[String: Any]] ?? [] { upsertPlan(plan) }
            for checkpoint in projection["checkpoints"] as? [[String: Any]] ?? [] { capture(checkpoint) }
        } else if envelope["kind"] as? String == "event", let event = envelope["event"] as? [String: Any],
                  let raw = event["payload"] as? [String: Any] {
            switch event["type"] as? String {
            case "turn-item.updated": loaded = true; upsert(raw)
            case "plan.updated": loaded = true; upsertPlan(raw)
            case "checkpoint.captured": loaded = true; capture(raw)
            default: break
            }
        }
    }
    private mutating func upsert(_ raw: [String: Any]) {
        if raw["type"] as? String == "todo_list" { upsertPlan(raw) }
        guard let item = T3ActivityStep(raw) else { return }
        items[item.id] = item
        if let file = item.fileName { recordFiles(run: item.runId ?? "", paths: [file]) }
        if items.count > 128 {
            let retained = items.values.sorted {
                if $0.running != $1.running { return $0.running }
                return ($0.ordinal, $0.id) > ($1.ordinal, $1.id)
            }.prefix(128)
            items = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        }
    }
    private mutating func upsertPlan(_ raw: [String: Any]) {
        guard let id = (raw["planId"] ?? raw["id"]) as? String,
              let rows = raw["steps"] as? [[String: Any]] else { return }
        planRevision += 1
        plans[id] = Plan(runId: raw["runId"] as? String, ordinal: planRevision,
                         steps: rows.compactMap(T3ActivityPlanStep.init))
        if plans.count > 8 {
            let keep = plans.sorted { ($0.value.ordinal, $0.key) > ($1.value.ordinal, $1.key) }.prefix(8)
            plans = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
    private mutating func capture(_ raw: [String: Any]) {
        guard raw["status"] as? String == "ready", let rows = raw["files"] as? [[String: Any]] else { return }
        recordFiles(run: raw["runId"] as? String ?? "", paths: rows.compactMap { $0["path"] as? String })
    }
    private mutating func recordFiles(run: String, paths: [String]) {
        if !fileRuns.contains(run) { fileRuns.append(run) }
        files[run, default: []].formUnion(paths)
        while fileRuns.count > 4 { files.removeValue(forKey: fileRuns.removeFirst()) }
    }
    func card(thread: T3Thread, models: [String: String] = [:]) -> T3ActivityCard {
        let run = thread.activeRunId ?? thread.latestRunId ?? items.values.max(by: { $0.ordinal < $1.ordinal })?.runId
        let rows = items.values.filter { $0.runId == run }.sorted { ($0.ordinal, $0.id) < ($1.ordinal, $1.id) }
        let active = rows.last(where: \.running)
        var log = Array(rows.filter { ["running", "completed", "failed", "cancelled", "interrupted"].contains($0.status) }.suffix(5))
        if let active, !log.contains(where: { $0.id == active.id }) { log = Array(log.suffix(4)) + [active] }
        let plan = plans.values.filter { $0.runId == run }.max { $0.ordinal < $1.ordinal }?.steps ?? []
        let prompt = thread.isApproval ? thread.requestLabel : nil
        return T3ActivityCard(threadId: thread.id, runId: run, title: thread.title,
            model: models["\(thread.providerInstanceId):\(thread.modelId)"] ?? thread.modelId,
            status: thread.status, action: active?.activeLabel ?? (thread.status == .running ? "Working" : "Idle"),
            icon: active?.icon ?? "sparkle", startedAt: thread.runStartedAt, completedAt: thread.runCompletedAt,
            log: log, plan: plan, filesChanged: loaded ? files[run ?? "", default: []].count : nil,
            approvalPrompt: prompt, nativeChildren: rows.filter { $0.kind == "subagent" && $0.nativeSubagent })
    }
}

struct T3ActivityCard: Equatable, Sendable {
    let threadId: String
    let runId: String?
    let title: String
    let model: String
    let status: T3Status
    let action: String
    let icon: String
    let startedAt: Date?
    let completedAt: Date?
    let log: [T3ActivityStep]
    let plan: [T3ActivityPlanStep]
    let filesChanged: Int?
    var approvalPrompt: String?
    let nativeChildren: [T3ActivityStep]
    var stepNumber: Int? {
        guard !plan.isEmpty else { return nil }
        if status == .done { return plan.count }
        return min(plan.count, (plan.firstIndex { $0.status == "running" } ?? plan.firstIndex { $0.status != "completed" } ?? (plan.count - 1)) + 1)
    }
    func elapsed(now: Date) -> TimeInterval? {
        T3ActivityTime.elapsed(start: startedAt, end: status == .running || status == .approval || status == .question ? nil : completedAt, now: now)
    }
}

struct T3ActivityChild: Identifiable, Equatable, Sendable {
    let id: String
    let threadId: String
    let title: String
    let status: T3Status
    let action: String
    let startedAt: Date?
    let completedAt: Date?
    let handoff: Bool
    let stop: T3ActivityStop?
}

enum T3ActivityStop: Equatable, Sendable {
    case thread(String)
    case run(thread: String, run: String)
    case subagent(thread: String, run: String, id: String)
    var key: String {
        switch self {
        case .thread(let id): "thread:\(id)"
        case .run(let thread, let run): "run:\(thread):\(run)"
        case .subagent(let thread, let run, let id): "subagent:\(thread):\(run):\(id)"
        }
    }
    func command(id: String) -> [String: Any] {
        switch self {
        case .thread(let thread): ["type": "thread.stop", "threadId": thread, "commandId": id]
        case .run(let thread, let run): ["type": "run.interrupt", "threadId": thread, "runId": run, "holdQueue": true, "commandId": id]
        case .subagent(let thread, let run, let subagent): ["type": "subagent.stop", "threadId": thread, "runId": run, "subagentId": subagent, "commandId": id]
        }
    }
}

extension T3Session {
    func activityRoot(project: String, selected: String?) -> T3Thread? {
        let topLevel = chatThreads(projectId: project)
        var parents = Set(threads.values.filter { $0.projectId == project }.compactMap { $0.launchedByThreadId ?? ($0.relationshipToParent == "subagent" ? $0.parentThreadId : nil) })
        for (id, reducer) in activity where threads[id]?.projectId == project {
            if reducer.items.values.contains(where: { !$0.nativeSubagent && $0.childThreadId.flatMap { threads[$0] }?.projectId == project }) { parents.insert(id) }
        }
        if let root = topLevel.first(where: { parents.contains($0.id) && ($0.status == .running || !activityChildren(root: $0.id).isEmpty) }) { return root }
        return topLevel.first(where: { $0.id == selected }) ?? topLevel.first
    }
    // Traverse explicit app-owned relationships; a fork is its own conversation,
    // not a subagent. Root IDs provide a fallback for incomplete ancestry.
    func activityDescendants(root: String) -> [T3Thread] {
        guard let parent = threads[root] else { return [] }
        var known: Set<String> = [root]
        var changed = true
        while changed {
            changed = false
            // App-owned delegation events may arrive before the shell ancestry.
            for owner in Array(known) {
                for item in activity[owner]?.items.values ?? Dictionary<String, T3ActivityStep>().values where !item.nativeSubagent {
                    if let id = item.childThreadId, threads[id]?.projectId == parent.projectId, !known.contains(id) {
                        known.insert(id); changed = true
                    }
                }
            }
            for thread in threads.values where thread.projectId == parent.projectId && !known.contains(thread.id) {
                let owner = thread.launchedByThreadId ?? (thread.isSubagent ? thread.parentThreadId : nil)
                if owner.map({ known.contains($0) }) == true || (thread.isSubagent && thread.rootThreadId == root) {
                    known.insert(thread.id); changed = true
                }
            }
        }
        return sortedThreads(projectId: parent.projectId).filter { $0.id != root && known.contains($0.id) }
    }
    func activityChildren(root: String, models: [String: String] = [:]) -> [T3ActivityChild] {
        guard let parent = threads[root] else { return [] }
        let descendants = activityDescendants(root: root).filter { thread in
            guard !thread.settled else { return false }
            if thread.status == .running || !thread.requestId.isEmpty { return true }
            if let handoff = thread.handoff, handoff.sentAt >= (thread.runStartedAt ?? .distantPast) { return true }
            return thread.runCompletedAt.map { $0 >= (parent.runStartedAt ?? .distantFuture) } ?? false
        }
        var rows = descendants.map { thread in
            let card = (activity[thread.id] ?? T3ActivityReducer()).card(thread: thread, models: models)
            return T3ActivityChild(id: thread.id, threadId: thread.id, title: thread.title, status: thread.status,
                action: card.log.last(where: \.running)?.activeLabel ?? card.log.last?.doneLabel ?? T3ActivityTree.statusLabel(thread.status),
                startedAt: thread.runStartedAt, completedAt: thread.runCompletedAt,
                handoff: !thread.settled && (thread.handoff.map { $0.sentAt >= (thread.runStartedAt ?? .distantPast) } ?? false),
                stop: thread.status == .running ? thread.activeRunId.map { .run(thread: thread.id, run: $0) } : nil)
        }
        let parentCard = (activity[root] ?? T3ActivityReducer()).card(thread: parent, models: models)
        for item in parentCard.nativeChildren where item.running || !parent.settled {
            guard let id = item.subagentId else { continue }
            rows.append(T3ActivityChild(id: "native:\(id)", threadId: root, title: item.activeLabel,
                status: item.running ? .running : item.status == "failed" ? .error : .done,
                action: item.label, startedAt: item.startedAt, completedAt: item.completedAt, handoff: false,
                stop: item.running ? item.runId.map { .subagent(thread: root, run: $0, id: id) } : nil))
        }
        return rows
    }
    func activityCard(thread: String, models: [String: String] = [:]) -> T3ActivityCard? {
        guard let shell = threads[thread] else { return nil }
        var card = (activity[thread] ?? T3ActivityReducer()).card(thread: shell, models: models)
        if shell.isApproval { card.approvalPrompt = prompts[thread]?[shell.requestId] ?? shell.requestLabel }
        return card
    }
}

enum T3ActivityTree {
    // Requests/chat are never evicted in favor of speculative activity streams.
    // Queued requests outside the cap get detail priority as their popup opens.
    static func subscriptions(session: T3Session, root: String?, chat: String?, popup: String?, limit: Int = 8) -> [String] {
        var ids: [String] = []
        func add(_ id: String?) {
            guard let id, session.threads[id] != nil, !ids.contains(id), ids.count < max(0, limit) else { return }
            ids.append(id)
        }
        add(root); add(popup); add(chat)
        if let root {
            for child in session.activityDescendants(root: root) where child.status == .running && !child.settled { add(child.id) }
        }
        for thread in session.pendingThreads { add(thread.id) }
        return ids
    }
    static func statusLabel(_ status: T3Status) -> String {
        switch status {
        case .running: "Working"
        case .approval: "Needs approval"
        case .question: "Needs an answer"
        case .done: "Done"
        case .error: "Failed"
        case .idle: "Idle"
        }
    }
    static func modelNames(config: [String: Any]) -> [String: String] {
        var names: [String: String] = [:]
        for provider in config["providers"] as? [[String: Any]] ?? [] {
            guard let instance = provider["instanceId"] as? String else { continue }
            for model in provider["models"] as? [[String: Any]] ?? [] {
                guard let slug = model["slug"] as? String, let name = model["name"] as? String else { continue }
                names["\(instance):\(slug)"] = name
                for alias in model["aliases"] as? [String] ?? [] { names["\(instance):\(alias)"] = name }
            }
        }
        return names
    }
}
