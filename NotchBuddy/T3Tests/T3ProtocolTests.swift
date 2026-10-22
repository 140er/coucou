import Foundation
import XCTest
@testable import T3Core

final class T3ProtocolTests: XCTestCase {
    private func thread(_ status: String = "running", kind: String? = nil, blocking: Bool = true) -> [String: Any] {
        var value: [String: Any] = ["id": "t", "projectId": "p", "title": "Build", "status": status,
                                    "updatedAt": "2026-10-22T12:00:00Z"]
        if let kind { value["pendingRuntimeRequest"] = ["id": "r", "kind": kind, "blocking": blocking] }
        return value
    }
    private func snapshot(_ rows: [[String: Any]]) -> [String: Any] {
        ["kind": "snapshot", "snapshot": ["projects": [["id": "p", "title": "Coucou"]],
                                           "threads": rows, "archivedThreads": []]]
    }
    func testV2StatusMapping() throws {
        for status in ["preparing", "queued", "starting", "running", "waiting"] {
            XCTAssertEqual(try XCTUnwrap(T3Thread(thread(status))).status, .running)
        }
        for status in ["idle", "interrupted", "cancelled", "rolled_back"] {
            XCTAssertEqual(try XCTUnwrap(T3Thread(thread(status))).status, .idle)
        }
        XCTAssertEqual(T3Thread(thread("completed"))?.status, .done)
        XCTAssertEqual(T3Thread(thread("failed"))?.status, .error)
        var failed = thread("idle"); failed["lastError"] = "provider failed"
        XCTAssertEqual(T3Thread(failed)?.status, .error)
        var active = thread("completed"); active["activityRunStatus"] = "running"
        XCTAssertEqual(T3Thread(active)?.status, .running)
        XCTAssertEqual(T3Thread(thread(kind: "command"))?.status, .approval)
        XCTAssertEqual(T3Thread(thread(kind: "file-read"))?.status, .approval)
        XCTAssertEqual(T3Thread(thread(kind: "user_input"))?.status, .question)
        XCTAssertEqual(T3Thread(thread(kind: "user_input", blocking: false))?.status, .running)
        XCTAssertEqual(T3Thread(thread("waiting", kind: "user_input", blocking: false))?.status, .question)
        XCTAssertEqual(T3Thread(thread(kind: "auth_refresh"))?.status, .running)
        let legacy: [String: Any] = ["id": "legacy", "session": ["status": "running"], "hasPendingApprovals": true]
        XCTAssertEqual(T3Thread(legacy)?.status, .idle)
    }
    func testSnapshotsAndMetadataRefresh() {
        var state = T3Session()
        var archived = thread(); archived["id"] = "old"; archived["archivedAt"] = "2026-10-21"
        var deleted = thread(); deleted["id"] = "gone"; deleted["deletedAt"] = "2026-10-21"
        state.applyShell(snapshot([thread(kind: "command"), archived, deleted]))
        XCTAssertEqual(state.threads.count, 1)
        XCTAssertEqual(state.approvalThreads.first?.requestId, "r")
        state.applyShell(snapshot([])) // v2 resume metadata must not wipe existing threads
        XCTAssertEqual(state.threads.count, 1)
        state.applyShell(["kind": "snapshot", "resolvedRepositoryIdentityRoots": ["/work"],
                          "snapshot": ["projects": [["id": "other", "title": "Notes"]], "threads": []]])
        XCTAssertEqual(state.projects.count, 2)
        XCTAssertEqual(state.threads.count, 1)
        state.applyShell(["kind": "snapshot", "snapshot": ["projects": [], "threads": []]])
        XCTAssertTrue(state.threads.isEmpty)
    }
    func testV2EventsAndRemoval() {
        var state = T3Session()
        state.applyShell(snapshot([thread()]))
        state.applyShell(["kind": "thread-upserted", "thread": thread("completed")])
        XCTAssertEqual(state.threads["t"]?.status, .running)
        state.applyShell(["kind": "thread.updated", "thread": thread("completed")])
        XCTAssertEqual(state.threads["t"]?.status, .done)
        state.applyShell(["kind": "thread.updated", "location": "archive", "thread": thread()])
        XCTAssertTrue(state.threads.isEmpty)
        state.applyShell(["kind": "thread.updated", "thread": thread()])
        state.applyShell(["kind": "thread.removed", "threadId": "t"])
        XCTAssertTrue(state.threads.isEmpty)
        state.applyShell(snapshot([thread()]))
        state.applyShell(["kind": "project.removed", "projectId": "p"])
        XCTAssertTrue(state.projects.isEmpty)
        XCTAssertTrue(state.threads.isEmpty)
    }
    func testProjectionEnrichesButCannotResolveApproval() {
        var state = T3Session()
        state.applyShell(snapshot([thread(kind: "command")]))
        state.applyThread(id: "t", item: ["kind": "snapshot", "projection": [
            "runtimeRequests": [["id": "r", "kind": "command", "detail": "fallback"]],
            "turnItems": [["type": "approval_request", "requestId": "r", "prompt": "npm test"]],
            "visibleTurnItems": [["item": ["type": "approval_request", "requestId": "r", "prompt": "duplicate"]]]
        ]])
        XCTAssertEqual(state.prompts["t"]?["r"], "npm test")
        state.applyThread(id: "t", item: ["kind": "event", "event": ["type": "turn-item.updated",
            "payload": ["type": "approval_request", "requestId": "r", "prompt": "swift test"]]])
        XCTAssertEqual(state.prompts["t"]?["r"], "swift test")
        state.applyThread(id: "t", item: ["kind": "snapshot", "snapshot": ["thread": ["activities": []]]])
        XCTAssertEqual(state.approvalThreads.count, 1)
        state.applyShell(["kind": "thread.updated", "thread": thread()])
        XCTAssertTrue(state.approvalThreads.isEmpty)
    }
    func testOrderingAndGrouping() {
        var state = T3Session()
        var done = thread("completed"); done["id"] = "done"
        var question = thread(kind: "user_input"); question["id"] = "question"
        state.applyShell(snapshot([done, question, thread(kind: "command")]))
        XCTAssertEqual(state.sortedThreads(projectId: "p").map(\.id), ["t", "question", "done"])
        XCTAssertEqual(state.sortedProjects.map(\.title), ["Coucou"])
    }
    func testAlertsBaselineTransitionsAndReconnectDeduplication() {
        var state = T3Session()
        var alerts = T3Alerts()
        state.applyShell(snapshot([thread("failed")]))
        XCTAssertTrue(alerts.take(state).isEmpty) // existing failure is a baseline
        state.applyShell(["kind": "thread.updated", "thread": thread()])
        XCTAssertTrue(alerts.take(state).isEmpty)
        state.applyShell(["kind": "thread.updated", "thread": thread("completed")])
        XCTAssertEqual(alerts.take(state), [.done])
        XCTAssertTrue(alerts.take(state).isEmpty)
        state.applyShell(["kind": "thread.updated", "thread": thread(kind: "user_input")])
        XCTAssertEqual(alerts.take(state), [.question])
        state.applyShell(["kind": "thread.updated", "thread": thread(kind: "command")])
        XCTAssertEqual(alerts.take(state), [.approval])
        XCTAssertTrue(alerts.take(state).isEmpty)
        alerts.disconnected()
        XCTAssertTrue(alerts.take(state).isEmpty) // reconnect must not ring again
        state.applyShell(["kind": "thread.updated", "thread": thread()])
        _ = alerts.take(state)
        state.applyShell(["kind": "thread.updated", "thread": thread(kind: "command")])
        XCTAssertEqual(alerts.take(state), [.approval]) // resolved request may recur
    }
    func testOriginAndSafeLinks() throws {
        XCTAssertNil(T3Protocol.origin("https://user:secret@example.org"))
        XCTAssertNil(T3Protocol.origin("file:///etc/passwd"))
        let base = try XCTUnwrap(T3Protocol.origin(" wss://example.org:3773/path?token=discard#fragment "))
        XCTAssertEqual(base.absoluteString, "https://example.org:3773")
        let ws = try XCTUnwrap(T3Protocol.socketURL(base: base, ticket: "ticket&?+"))
        let parts = try XCTUnwrap(URLComponents(url: ws, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "wss")
        XCTAssertEqual(parts.path, "/ws")
        XCTAssertEqual(parts.queryItems?.first?.value, "2")
        XCTAssertEqual(parts.queryItems?.last?.value, "ticket&?+")
        XCTAssertFalse(ws.absoluteString.contains("Bearer"))
        let url = T3Protocol.threadURL(base: base, environment: "env 1", thread: "https://evil.example/../x")
        XCTAssertEqual(url.host, "example.org")
        XCTAssertTrue(url.absoluteString.contains("/env%201/https%3A%2F%2Fevil%2Eexample%2F%2E%2E%2Fx"))
        XCTAssertEqual(T3Protocol.threadURL(base: base, environment: nil, thread: "t"), base)
        XCTAssertNotNil(T3Protocol.origin("http://[::1]:3773"))
        XCTAssertFalse(T3Protocol.headerSafe("secret\r\nInjected: value"))
        XCTAssertFalse(T3Protocol.headerSafe(""))
    }
    func testEffectFramesAndDispatchShape() throws {
        XCTAssertEqual(T3Protocol.frames(Data("invalid".utf8)).count, 0)
        XCTAssertEqual(T3Protocol.frames(Data("[{\"_tag\":\"Ping\"},{\"_tag\":\"Pong\"}]".utf8)).count, 2)
        let request = T3Protocol.request(id: "shell", method: "orchestration.subscribeShell", payload: [:])
        XCTAssertEqual(request["_tag"] as? String, "Request")
        XCTAssertEqual(request["tag"] as? String, "orchestration.subscribeShell")
        XCTAssertEqual(request["id"] as? String, "shell")
        XCTAssertEqual((request["headers"] as? [Any])?.count, 0)
        for accept in [true, false] {
            let command = T3Protocol.approvalCommand(thread: "t", request: "r", accept: accept, commandId: "c")
            XCTAssertEqual(command["type"] as? String, "runtime-request.respond")
            XCTAssertEqual(command["threadId"] as? String, "t")
            XCTAssertEqual(command["requestId"] as? String, "r")
            XCTAssertEqual(command["decision"] as? String, accept ? "accept" : "decline")
            XCTAssertEqual(command["commandId"] as? String, "c")
        }
        XCTAssertEqual(T3Protocol.environment(["environment": ["environmentId": "env"]]), "env")
    }
}
