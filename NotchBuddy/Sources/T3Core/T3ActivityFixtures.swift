import Foundation

// Wire-shaped, deterministic fixtures shared by reducer tests and Xcode previews.
// No network, credentials, filesystem access or live actions are used.
enum T3ActivityFixtures {
    enum Scenario: CaseIterable { case running, approval, done }
    static let now = Date(timeIntervalSince1970: 1_792_836_013)
    static func scene(_ scenario: Scenario) -> (card: T3ActivityCard, children: [T3ActivityChild]) {
        var session = T3Session()
        var root = thread(id: "orchestrator", status: scenario == .done ? "completed" : "running")
        if scenario == .approval { root["pendingRuntimeRequest"] = ["id": "approval-1", "kind": "command"] }
        var child = thread(id: "tests", status: scenario == .running ? "running" : "completed", parent: "orchestrator")
        child["title"] = "Test suite"
        child["latestRunStartedAt"] = stamp(7)
        var handedOff = thread(id: "review", status: "completed", parent: "orchestrator")
        handedOff["title"] = "Review changes"
        handedOff["lastHandoff"] = ["targetThreadId": "orchestrator", "target": "parent", "sentAt": stamp(11)]
        session.applyShell(["kind": "snapshot", "snapshot": ["projects": [["id": "project", "title": "Billing"]], "threads": [root, child, handedOff]]])
        var items: [[String: Any]] = [item(id: "read", type: "dynamic_tool", ordinal: 1, status: "completed", start: 0, end: 1.9,
            fields: ["toolName": "read_file", "input": ["path": "12 source files"]])]
        for index in 0..<6 {
            items.append(item(id: "file-\(index)", type: "file_change", ordinal: index + 2,
                status: scenario == .done || index < 3 ? "completed" : "pending", start: Double(index + 2), end: Double(index + 3),
                fields: ["fileName": index == 0 ? "src/billing/invoice.ts" : "src/billing/file-\(index).ts"]))
        }
        if scenario != .done {
            items.append(item(id: "command", type: "command_execution", ordinal: 9, status: "running", start: 9,
                fields: ["input": "tests 4 of 12"]))
        }
        let steps: [[String: Any]] = (0..<6).map { index in
            ["id": "step-\(index)", "text": "Update billing \(index + 1)",
             "status": scenario == .done || index < 3 ? "completed" : index == 3 ? "running" : "pending", "durationMs": 1900]
        }
        items.append(["id": "todos", "runId": "run-orchestrator", "type": "todo_list", "ordinal": 10, "planId": "plan", "steps": steps])
        items.append(["id": "approval", "type": "approval_request", "requestId": "approval-1", "prompt": "npm test"])
        session.applyThread(id: "orchestrator", item: ["kind": "snapshot", "projection": ["turnItems": items]])
        session.applyThread(id: "tests", item: ["kind": "snapshot", "projection": ["turnItems": [item(id: "test", type: "command_execution", ordinal: 1,
            status: scenario == .running ? "running" : "completed", start: 7, end: scenario == .running ? nil : 12,
            fields: ["input": "unit tests"]) .merging(["runId": "run-tests"]) { _, new in new }]]])
        let models = T3ActivityTree.modelNames(config: ["providers": [["instanceId": "codex", "models": [["slug": "gpt-6.1", "name": "GPT-6.1"]]]]])
        return (session.activityCard(thread: "orchestrator", models: models)!, session.activityChildren(root: "orchestrator"))
    }
    static func stamp(_ offset: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(offset - 13))
    }
    static func thread(id: String, status: String = "running", parent: String? = nil) -> [String: Any] {
        var raw: [String: Any] = ["id": id, "title": "Billing orchestrator", "projectId": "project", "status": status,
            "providerInstanceId": "codex", "modelSelection": ["instanceId": "codex", "model": "gpt-6.1"],
            "latestRunId": "run-\(id)", "latestRunStartedAt": stamp(0), "updatedAt": stamp(13)]
        if ["running", "waiting", "starting", "preparing"].contains(status) { raw["activeRunId"] = "run-\(id)" }
        else { raw["latestRunCompletedAt"] = stamp(13) }
        if let parent { raw["lineage"] = ["parentThreadId": parent, "rootThreadId": "orchestrator", "relationshipToParent": "subagent"] }
        return raw
    }
    static func item(id: String, type: String, ordinal: Int, status: String = "running", start: Double = 0,
                     end: Double? = nil, fields: [String: Any] = [:]) -> [String: Any] {
        var raw: [String: Any] = ["id": id, "type": type, "runId": "run-orchestrator", "ordinal": ordinal,
                                  "status": status, "startedAt": stamp(start)]
        if let end { raw["completedAt"] = stamp(end) }
        return raw.merging(fields) { _, new in new }
    }
}
