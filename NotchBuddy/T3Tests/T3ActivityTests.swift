import Foundation
import XCTest
@testable import T3Core

final class T3ActivityTests: XCTestCase {
    private func snapshot(_ items: [[String: Any]], plans: [[String: Any]] = [], checkpoints: [[String: Any]] = []) -> [String: Any] {
        ["kind": "snapshot", "projection": ["turnItems": items, "plans": plans, "checkpoints": checkpoints]]
    }
    private func event(_ type: String, _ payload: [String: Any]) -> [String: Any] {
        ["kind": "event", "event": ["type": type, "payload": payload]]
    }
    private func session(_ threads: [[String: Any]]) -> T3Session {
        var session = T3Session()
        session.applyShell(["kind": "snapshot", "snapshot": ["projects": [["id": "project", "title": "Billing"]], "threads": threads]])
        return session
    }
    private var root: T3Thread { T3Thread(T3ActivityFixtures.thread(id: "orchestrator"))! }

    func testVerbLabelsAndMissingTimestamps() throws {
        let cases: [(String, [String: Any], String, String)] = [
            ("file_change", ["fileName": "src/invoice.ts"], "Editing src/invoice.ts", "Edited src/invoice.ts"),
            ("command_execution", ["input": "tests 4 of 12"], "Running tests 4 of 12", "Ran tests 4 of 12"),
            ("file_search", ["pattern": "billing"], "Searching files · billing", "Searched files · billing"),
            ("web_search", ["patterns": ["SwiftUI"]], "Searching the web · SwiftUI", "Searched the web · SwiftUI"),
            ("dynamic_tool", ["toolName": "read_file", "input": ["path": "12 files"]], "Reading 12 files", "Read 12 files"),
            ("reasoning", [:], "Thinking", "Thought through next step"),
            ("subagent", ["progress": "Checking tests"], "Checking tests", "Delegated work")
        ]
        for (type, fields, active, done) in cases {
            let value = try XCTUnwrap(T3ActivityStep(T3ActivityFixtures.item(id: type, type: type, ordinal: 1, fields: fields)))
            XCTAssertEqual(value.activeLabel, active)
            XCTAssertEqual(value.doneLabel, done)
        }
        XCTAssertNil(T3ActivityStep(["id": "unknown", "type": "future_type"]))
        XCTAssertNil(T3ActivityTime.elapsed(start: nil, end: nil, now: T3ActivityFixtures.now))
        XCTAssertEqual(T3ActivityTime.elapsed(start: T3ActivityFixtures.now, end: T3ActivityFixtures.now.addingTimeInterval(-3), now: T3ActivityFixtures.now), 0)
    }

    func testUpsertsRollFiveRowsAndPreserveTheActiveAction() throws {
        var reducer = T3ActivityReducer()
        var items = (1...8).map { n in
            T3ActivityFixtures.item(id: "item-\(n)", type: "file_change", ordinal: n, status: "completed", start: Double(n), end: Double(n) + 1.9, fields: ["fileName": "file-\(n).swift"])
        }
        items.append(T3ActivityFixtures.item(id: "active", type: "command_execution", ordinal: 9, start: 10, fields: ["input": "swift test"]))
        reducer.apply(snapshot(items))
        var card = reducer.card(thread: root)
        XCTAssertEqual(card.log.count, 5)
        XCTAssertEqual(card.log.first?.id, "item-5")
        XCTAssertEqual(card.action, "Running swift test")
        let completed = T3ActivityFixtures.item(id: "active", type: "command_execution", ordinal: 9, status: "completed", start: 10, end: 12, fields: ["input": "swift test"])
        reducer.apply(event("turn-item.updated", completed))
        card = reducer.card(thread: root)
        XCTAssertEqual(card.log.count, 5)
        XCTAssertEqual(card.log.last?.doneLabel, "Ran swift test")
        XCTAssertEqual(card.filesChanged, 8)
        XCTAssertEqual(T3ActivityTime.text(T3ActivityTime.elapsed(start: card.log.first?.startedAt, end: card.log.first?.completedAt, now: T3ActivityFixtures.now)), "1.9s")
    }

    func testBoundedStorageKeepsOldActiveItemAndFileTotals() {
        var reducer = T3ActivityReducer()
        reducer.apply(snapshot([T3ActivityFixtures.item(id: "long-test", type: "command_execution", ordinal: 0, fields: ["input": "integration tests"])]))
        for n in 1...200 {
            reducer.apply(event("turn-item.updated", T3ActivityFixtures.item(id: "file-\(n)", type: "file_change", ordinal: n, status: "completed", fields: ["fileName": "file-\(n).swift"])))
        }
        let card = reducer.card(thread: root)
        XCTAssertEqual(reducer.items.count, 128)
        XCTAssertEqual(card.log.count, 5)
        XCTAssertEqual(card.log.last?.id, "long-test")
        XCTAssertEqual(card.action, "Running integration tests")
        XCTAssertEqual(card.filesChanged, 200)
    }

    func testNewRunAndSnapshotReplacementDoNotLeakOldActivity() throws {
        var reducer = T3ActivityReducer()
        reducer.apply(snapshot([T3ActivityFixtures.item(id: "old", type: "file_change", ordinal: 9, fields: ["fileName": "old.ts"])]))
        var raw = T3ActivityFixtures.thread(id: "orchestrator")
        raw["activeRunId"] = "new-run"; raw["latestRunId"] = "new-run"
        var new = T3ActivityFixtures.item(id: "new", type: "reasoning", ordinal: 10)
        new["runId"] = "new-run"
        reducer.apply(event("turn-item.updated", new))
        let card = reducer.card(thread: try XCTUnwrap(T3Thread(raw)))
        XCTAssertEqual(card.log.map(\.id), ["new"])
        XCTAssertEqual(card.filesChanged, 0)
        XCTAssertTrue(card.plan.isEmpty)
        XCTAssertNil(card.stepNumber)
        reducer.apply(snapshot([]))
        XCTAssertTrue(reducer.items.isEmpty)
    }

    func testBoundedVisibleItemsAndPlanEvents() throws {
        var reducer = T3ActivityReducer()
        let item = T3ActivityFixtures.item(id: "edit", type: "file_change", ordinal: 2, fields: ["fileName": "a.ts"])
        let plan: [String: Any] = ["id": "todo", "type": "todo_list", "runId": "run-orchestrator", "planId": "plan", "ordinal": 3,
            "steps": [["id": "s1", "text": "Read", "status": "completed", "durationMs": 1900], ["id": "s2", "text": "Test", "status": "running"]]]
        reducer.apply(["kind": "snapshot", "projection": ["visibleTurnItems": [["item": item], ["item": plan]]]])
        var card = reducer.card(thread: root)
        XCTAssertEqual(card.action, "Editing a.ts")
        XCTAssertEqual(card.stepNumber, 2)
        XCTAssertEqual(card.plan.first?.durationMs, 1900)
        reducer.apply(event("plan.updated", ["id": "plan", "runId": "run-orchestrator", "steps": [["id": "s1", "text": "Read", "status": "pending"]]]))
        card = reducer.card(thread: root)
        XCTAssertEqual(card.plan.count, 1)
        XCTAssertEqual(card.stepNumber, 1)
    }

    func testCheckpointFileCountIsUniqueAndRunScoped() {
        var reducer = T3ActivityReducer()
        reducer.apply(snapshot([T3ActivityFixtures.item(id: "file", type: "file_change", ordinal: 1, fields: ["fileName": "a.ts"])]))
        reducer.apply(event("checkpoint.captured", ["id": "checkpoint", "runId": "run-orchestrator", "status": "ready", "files": [["path": "a.ts"], ["path": "b.ts"]]]))
        reducer.apply(event("checkpoint.captured", ["id": "old", "runId": "old-run", "status": "ready", "files": [["path": "old.ts"]]]))
        XCTAssertEqual(reducer.card(thread: root).filesChanged, 2)
    }

    func testElapsedUsesActivityStartAndFreezesOnCompletion() throws {
        var raw = T3ActivityFixtures.thread(id: "orchestrator")
        raw["activityRunStartedAt"] = T3ActivityFixtures.stamp(4)
        var card = T3ActivityReducer().card(thread: try XCTUnwrap(T3Thread(raw)))
        XCTAssertEqual(card.elapsed(now: T3ActivityFixtures.now), 9)
        raw["status"] = "completed"; raw.removeValue(forKey: "activeRunId")
        raw["latestRunCompletedAt"] = T3ActivityFixtures.stamp(12)
        card = T3ActivityReducer().card(thread: try XCTUnwrap(T3Thread(raw)))
        XCTAssertEqual(card.elapsed(now: T3ActivityFixtures.now.addingTimeInterval(100)), 8)
    }

    func testOrchestratorTreeIncludesLaunchedAndNestedChildrenButNotForks() {
        var launched = T3ActivityFixtures.thread(id: "launched")
        launched["launchedByThreadId"] = "orchestrator"
        let child = T3ActivityFixtures.thread(id: "child", parent: "orchestrator")
        let nested = T3ActivityFixtures.thread(id: "nested", parent: "child")
        var fork = T3ActivityFixtures.thread(id: "fork")
        fork["lineage"] = ["parentThreadId": "orchestrator", "relationshipToParent": "fork"]
        let state = session([T3ActivityFixtures.thread(id: "orchestrator"), launched, child, nested, fork])
        XCTAssertEqual(Set(state.activityDescendants(root: "orchestrator").map(\.id)), Set(["launched", "child", "nested"]))
        XCTAssertEqual(state.activityRoot(project: "project", selected: "launched")?.id, "orchestrator")
    }

    func testHandoffRetainedUntilSettledAndNotReusedForNewRun() {
        var child = T3ActivityFixtures.thread(id: "child", status: "completed", parent: "orchestrator")
        child["lastHandoff"] = ["targetThreadId": "orchestrator", "target": "parent", "sentAt": T3ActivityFixtures.stamp(13)]
        var state = session([T3ActivityFixtures.thread(id: "orchestrator"), child])
        XCTAssertEqual(state.activityChildren(root: "orchestrator").first?.handoff, true)
        XCTAssertFalse(T3ActivityTree.subscriptions(session: state, root: "orchestrator", chat: nil, popup: nil).contains("child"))
        child["settledOverride"] = "settled"
        state.applyShell(["kind": "thread.updated", "thread": child])
        XCTAssertTrue(state.activityChildren(root: "orchestrator").isEmpty)
        child["settledOverride"] = "active"; child["status"] = "running"
        child["latestRunStartedAt"] = T3ActivityFixtures.stamp(15); child["activeRunId"] = "next"
        state.applyShell(["kind": "thread.updated", "thread": child])
        XCTAssertEqual(state.activityChildren(root: "orchestrator").first?.handoff, false)
    }

    func testNativeSubagentHasNativeStopAndAppOwnedDoesNotDuplicateShellRow() {
        var state = session([T3ActivityFixtures.thread(id: "orchestrator"), T3ActivityFixtures.thread(id: "child", parent: "orchestrator")])
        let native = T3ActivityFixtures.item(id: "native", type: "subagent", ordinal: 1,
            fields: ["origin": "provider_native", "subagentId": "native-node", "prompt": "Review changes"])
        let owned = T3ActivityFixtures.item(id: "owned", type: "subagent", ordinal: 2,
            fields: ["origin": "app_owned", "subagentId": "app-node", "childThreadId": "child", "prompt": "Test"])
        state.applyThread(id: "orchestrator", item: snapshot([native, owned]))
        let rows = state.activityChildren(root: "orchestrator")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.id == "native:native-node" })?.stop, .subagent(thread: "orchestrator", run: "run-orchestrator", id: "native-node"))
        XCTAssertEqual(rows.first(where: { $0.id == "child" })?.stop, .run(thread: "child", run: "run-child"))
    }

    func testSubscriptionCapPreservesRootChatPopupAndEvictsOldProject() {
        let children = (0..<20).map { T3ActivityFixtures.thread(id: "child-\($0)", parent: "orchestrator") }
        var state = session([T3ActivityFixtures.thread(id: "orchestrator"), T3ActivityFixtures.thread(id: "chat"), T3ActivityFixtures.thread(id: "popup")] + children)
        let wanted = T3ActivityTree.subscriptions(session: state, root: "orchestrator", chat: "chat", popup: "popup")
        XCTAssertEqual(wanted.count, 8)
        XCTAssertEqual(Array(wanted.prefix(3)), ["orchestrator", "popup", "chat"])
        var settled = children.first!; settled["status"] = "completed"; settled["settledOverride"] = "settled"
        state.applyShell(["kind": "thread.updated", "thread": settled])
        XCTAssertFalse(T3ActivityTree.subscriptions(session: state, root: "orchestrator", chat: nil, popup: nil).contains("child-0"))
        let switched = T3ActivityTree.subscriptions(session: state, root: "chat", chat: "chat", popup: nil)
        XCTAssertEqual(switched, ["chat"])
        XCTAssertTrue(T3ActivityTree.subscriptions(session: state, root: "chat", chat: nil, popup: nil, limit: 0).isEmpty)
    }

    func testSubagentItemLinksAndDroppedStreamCaches() {
        var state = session([T3ActivityFixtures.thread(id: "orchestrator"), T3ActivityFixtures.thread(id: "without-lineage")])
        let link = T3ActivityFixtures.item(id: "owned", type: "subagent", ordinal: 1,
            fields: ["origin": "app_owned", "subagentId": "node", "childThreadId": "without-lineage", "prompt": "Test"])
        state.applyThread(id: "orchestrator", item: snapshot([link]))
        XCTAssertEqual(state.activityRoot(project: "project", selected: "without-lineage")?.id, "orchestrator")
        XCTAssertEqual(state.activityDescendants(root: "orchestrator").map(\.id), ["without-lineage"])
        state.applyThread(id: "without-lineage", item: ["kind": "snapshot", "projection": ["messages": [["id": "m", "role": "assistant", "text": "Finished"]], "turnItems": []]])
        state.retainDetails(activity: ["orchestrator", "without-lineage"], streams: ["orchestrator"])
        XCTAssertNil(state.messages["without-lineage"])
        XCTAssertNotNil(state.activity["without-lineage"])
        var child = T3ActivityFixtures.thread(id: "without-lineage")
        child["settledOverride"] = "settled"
        state.applyShell(["kind": "thread.updated", "thread": child])
        XCTAssertTrue(state.activityChildren(root: "orchestrator").isEmpty)
        XCTAssertFalse(T3ActivityTree.subscriptions(session: state, root: "orchestrator", chat: nil, popup: nil).contains("without-lineage"))
    }

    func testStopCommandsAndScopedModelNames() {
        let stop = T3ActivityStop.thread("root").command(id: "c")
        XCTAssertEqual(stop["type"] as? String, "thread.stop")
        XCTAssertNil(stop["runId"])
        let interrupt = T3ActivityStop.run(thread: "child", run: "run-child").command(id: "c")
        XCTAssertEqual(interrupt["type"] as? String, "run.interrupt")
        XCTAssertEqual(interrupt["runId"] as? String, "run-child")
        let native = T3ActivityStop.subagent(thread: "root", run: "run-root", id: "native").command(id: "c")
        XCTAssertEqual(native["type"] as? String, "subagent.stop")
        XCTAssertEqual(native["subagentId"] as? String, "native")
        let names = T3ActivityTree.modelNames(config: ["providers": [
            ["instanceId": "a", "models": [["slug": "model", "name": "Pretty A", "aliases": ["alias"]]]],
            ["instanceId": "b", "models": [["slug": "model", "name": "Pretty B"]]]
        ]])
        XCTAssertEqual(names["a:alias"], "Pretty A")
        XCTAssertEqual(names["b:model"], "Pretty B")
        XCTAssertEqual(T3ActivityReducer().card(thread: root).model, "gpt-6.1")
    }

    func testPreviewFixturesAreRealReducerStates() {
        let running = T3ActivityFixtures.scene(.running)
        XCTAssertEqual(running.card.status, .running)
        XCTAssertEqual(running.card.action, "Running tests 4 of 12")
        XCTAssertLessThanOrEqual(running.card.log.count, 5)
        XCTAssertEqual(running.card.stepNumber, 4)
        XCTAssertEqual(running.card.model, "GPT-6.1")
        let approval = T3ActivityFixtures.scene(.approval)
        XCTAssertEqual(approval.card.status, .approval)
        XCTAssertEqual(approval.card.approvalPrompt, "npm test")
        let done = T3ActivityFixtures.scene(.done)
        XCTAssertEqual(done.card.status, .done)
        XCTAssertEqual(done.card.elapsed(now: T3ActivityFixtures.now), 13)
        XCTAssertEqual(done.card.filesChanged, 6)
        XCTAssertEqual(done.card.stepNumber, 6)
        XCTAssertTrue(done.children.contains(where: \.handoff))
    }
}
