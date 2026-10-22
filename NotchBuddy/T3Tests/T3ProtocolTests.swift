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
    func testProjectPillsIncludeEmptyProjectsAndStableIds() {
        var session = T3Session()
        session.applyShell(["kind": "snapshot", "snapshot": ["projects": [
            ["id": "z", "title": "Zeta"], ["id": "p", "title": "Coucou"], ["id": "e", "title": "Empty"]
        ], "threads": [thread()]]])
        let pills = T3ProjectPill.map(session)
        XCTAssertEqual(pills.map(\.name), ["Coucou", "Empty", "Zeta"])
        XCTAssertEqual(pills[0].status, .running)
        XCTAssertEqual(pills[1].status, .idle)
        XCTAssertNil(pills[1].threadId)
        let id = pills[0].id
        session.applyShell(["kind": "project.updated", "project": ["id": "p", "title": "Renamed"]])
        XCTAssertEqual(T3ProjectPill.map(session).first { $0.projectId == "p" }?.id, id)
        XCTAssertTrue(T3ProjectPill.owns(id))
        XCTAssertFalse(T3ProjectPill.owns("integration_github"))
        session.applyShell(["kind": "project.removed", "projectId": "p"])
        XCTAssertFalse(T3ProjectPill.map(session).contains { $0.id == id })
    }
    func testProjectStatusAggregatesChildrenAndPrefersActiveOrchestrator() {
        var parent = thread(); parent["id"] = "parent"
        var child = thread(kind: "command"); child["id"] = "child"
        child["lineage"] = ["parentThreadId": "parent", "relationshipToParent": "subagent"]
        var session = T3Session()
        session.applyShell(snapshot([parent, child]))
        XCTAssertEqual(T3ProjectPill.map(session).first?.threadId, "parent")
        XCTAssertEqual(T3ProjectPill.map(session).first?.status, .approval)
        parent["status"] = "completed"
        session.applyShell(["kind": "thread.updated", "thread": parent])
        XCTAssertEqual(T3ProjectPill.map(session).first?.threadId, "child")
        session.applyShell(["kind": "thread.removed", "threadId": "child"])
        XCTAssertEqual(T3ProjectPill.map(session).first?.status, .done)
        session.applyShell(["kind": "thread.updated", "thread": thread(kind: "user_input")])
        XCTAssertEqual(T3ProjectPill.map(session).first?.status, .question)
        session.applyShell(["kind": "thread.removed", "threadId": "t"])
        parent["status"] = "failed"
        session.applyShell(["kind": "thread.updated", "thread": parent])
        XCTAssertEqual(T3ProjectPill.map(session).first?.status, .error)
    }
    func testMessageStartsIdleAndSteersRunningThread() throws {
        let idle = try XCTUnwrap(T3Thread(thread("idle")))
        let start = try T3Composer.message(thread: idle, text: "Hello", attachments: [], commandId: "c", messageId: "m", serverResolvesContext: false)
        XCTAssertEqual(start["type"] as? String, "message.dispatch")
        XCTAssertEqual(start["threadId"] as? String, "t")
        XCTAssertEqual(start["messageId"] as? String, "m")
        XCTAssertEqual(start["createdBy"] as? String, "user")
        XCTAssertEqual(start["creationSource"] as? String, "web")
        XCTAssertEqual((start["dispatchMode"] as? [String: String])?["type"], "start_immediately")
        var raw = thread(); raw["activeRunId"] = "run-1"
        let active = try XCTUnwrap(T3Thread(raw))
        let steer = try T3Composer.message(thread: active, text: "Change direction", attachments: [], commandId: "c", messageId: "m", serverResolvesContext: false)
        XCTAssertEqual(steer["dispatchMode"] as? [String: String], ["type": "steer_active", "targetRunId": "run-1"])
        let resolved = try T3Composer.message(thread: active, text: "Steer", attachments: [], commandId: "c", messageId: "m", serverResolvesContext: true)
        XCTAssertEqual(resolved["deliveryIntent"] as? String, "steer")
        XCTAssertEqual((resolved["dispatchMode"] as? [String: String])?["type"], "start_immediately")
        XCTAssertThrowsError(try T3Composer.message(thread: XCTUnwrap(T3Thread(thread())), text: "Hi", attachments: [], commandId: "c", messageId: "m", serverResolvesContext: false))
        XCTAssertThrowsError(try T3Composer.message(thread: idle, text: " ", attachments: [], commandId: "c", messageId: "m", serverResolvesContext: true))
        XCTAssertThrowsError(try T3Composer.message(thread: idle, text: String(repeating: "x", count: 120001), attachments: [], commandId: "c", messageId: "m", serverResolvesContext: true))
    }
    func testAttachmentsUseUploadMetadataAndPersistedReferences() throws {
        let file = try T3Composer.uploadMetadata(name: "notes.md", mimeType: "text/markdown", bytes: 200)
        XCTAssertEqual(file.type, "file")
        XCTAssertNil(file.metadata["id"])
        XCTAssertNil(file.metadata["dataUrl"])
        XCTAssertEqual(file.metadata["sizeBytes"] as? Int, 200)
        let ready = T3Attachment(id: "pending_abc", type: file.type, name: file.name, mimeType: file.mimeType, sizeBytes: file.sizeBytes)
        let command = try T3Composer.message(thread: XCTUnwrap(T3Thread(thread("idle"))), text: "", attachments: [ready], commandId: "c", messageId: "m", serverResolvesContext: true)
        let attachment = try XCTUnwrap((command["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(attachment["id"] as? String, "pending_abc")
        XCTAssertNil(attachment["dataUrl"])
        XCTAssertNil(attachment["path"])
        XCTAssertEqual(command["deliveryIntent"] as? String, "auto")
        XCTAssertThrowsError(try T3Composer.message(thread: XCTUnwrap(T3Thread(thread("idle"))), text: "", attachments: [file], commandId: "c", messageId: "m", serverResolvesContext: true))
        let image = try T3Composer.uploadMetadata(name: "shot.png", mimeType: "image/png", bytes: 100)
        XCTAssertEqual(image.type, "image")
    }
    func testAttachmentLimitsAndSignedUploadOrigin() throws {
        XCTAssertThrowsError(try T3Composer.uploadMetadata(name: "a", mimeType: "text/plain", bytes: 0))
        XCTAssertThrowsError(try T3Composer.uploadMetadata(name: "a", mimeType: "text/plain", bytes: T3Composer.fileLimit + 1))
        XCTAssertThrowsError(try T3Composer.uploadMetadata(name: "a", mimeType: "text/plain", bytes: 1025, maxFileBytes: 1024))
        XCTAssertThrowsError(try T3Composer.uploadMetadata(name: "a.png", mimeType: "image/png", bytes: T3Composer.imageLimit + 1))
        let image = T3Attachment(id: "image", type: "image", name: "x.png", mimeType: "image/png", sizeBytes: T3Composer.imageLimit)
        XCTAssertNoThrow(try T3Composer.validate(Array(repeating: image, count: 8)))
        XCTAssertThrowsError(try T3Composer.validate(Array(repeating: image, count: 9)))
        let file = T3Attachment(id: "file", type: "file", name: "x.txt", mimeType: "text/plain", sizeBytes: 1)
        XCTAssertThrowsError(try T3Composer.validate(Array(repeating: file, count: 101)))
        let base = try XCTUnwrap(URL(string: "https://t3.example"))
        XCTAssertEqual(try T3Composer.uploadURL(base: base, relative: "/api/attachments/upload/signed.token").host, "t3.example")
        for bad in ["https://evil.example/upload", "//evil.example/upload", "/other/upload", "/api/attachments/upload/token#fragment"] {
            XCTAssertThrowsError(try T3Composer.uploadURL(base: base, relative: bad))
        }
    }
    func testUploadRequestMatchesWebComposerByteTransport() throws {
        let base = try XCTUnwrap(URL(string: "https://t3.example"))
        let request = try T3Composer.uploadRequest(base: base, relative: "/api/attachments/upload/signed.token", mimeType: "application/pdf")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertEqual(request.timeoutInterval, 300)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody) // upload(for:fromFile:) supplies the raw bytes
        XCTAssertThrowsError(try T3Composer.uploadRequest(base: base, relative: "/api/attachments/upload/signed.token", mimeType: "text/plain\r\nX-Injected: yes"))
    }
    func testChatSnapshotAndStreamedRepliesReplaceById() {
        var session = T3Session()
        session.applyShell(snapshot([thread()]))
        session.applyThread(id: "t", item: ["kind": "snapshot", "projection": ["messages": [
            ["id": "m", "role": "assistant", "text": "First", "streaming": true]
        ]]])
        session.applyThread(id: "t", item: ["kind": "event", "event": ["type": "message.updated", "payload": [
            "id": "m", "role": "assistant", "text": "First reply complete", "streaming": false
        ]]])
        XCTAssertEqual(session.messages["t"]?.count, 1)
        XCTAssertEqual(session.messages["t"]?.first?.text, "First reply complete")
        XCTAssertEqual(session.messages["t"]?.first?.streaming, false)
        session.applyShell(["kind": "thread.removed", "threadId": "t"])
        XCTAssertNil(session.messages["t"])
    }

}
