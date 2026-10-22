import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Foundation-only port of windows/src-tauri/src/t3.rs (orchestration v2).
// The shell owns pending state; projections only enrich approval prompts.
enum T3Status: String, Sendable {
    case approval, question, error, running, done, idle
    var rank: Int {
        [.approval, .question, .error, .running, .done, .idle].firstIndex(of: self)!
    }
}

struct T3Thread: Identifiable, Equatable, Sendable {
    let id: String
    let projectId: String
    let title: String
    let updatedAt: String
    let archived: Bool
    let runStatus: String
    let requestId: String
    let requestKind: String
    let requestCreatedAt: String
    let blocking: Bool
    let lastError: String
    let activeRunId: String?
    let parentThreadId: String?
    let relationshipToParent: String?

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        activeRunId = raw["activeRunId"] as? String
        parentThreadId = (raw["lineage"] as? [String: Any])?["parentThreadId"] as? String
        relationshipToParent = (raw["lineage"] as? [String: Any])?["relationshipToParent"] as? String
        projectId = raw["projectId"] as? String ?? ""
        title = raw["title"] as? String ?? ""
        updatedAt = raw["updatedAt"] as? String ?? ""
        archived = ["archivedAt", "deletedAt"].contains { !(raw[$0] as? String ?? "").isEmpty }
        let activity = raw["activityRunStatus"] as? String ?? ""
        runStatus = activity.isEmpty ? raw["status"] as? String ?? "" : activity
        let pending = raw["pendingRuntimeRequest"] as? [String: Any] ?? [:]
        requestId = pending["id"] as? String ?? ""
        requestKind = pending["kind"] as? String ?? ""
        requestCreatedAt = pending["createdAt"] as? String ?? ""
        blocking = pending["blocking"] as? Bool ?? true
        lastError = raw["lastError"] as? String ?? ""
    }

    var isApproval: Bool {
        !requestId.isEmpty && !requestKind.isEmpty && !["user_input", "auth_refresh"].contains(requestKind)
    }
    var status: T3Status {
        if isApproval { return .approval }
        if requestKind == "user_input", !requestId.isEmpty,
           blocking || !["preparing", "starting", "running"].contains(runStatus) { return .question }
        let active = ["preparing", "queued", "starting", "running", "waiting"]
        if runStatus == "failed" || (!lastError.isEmpty && !active.contains(runStatus) && runStatus != "completed") {
            return .error
        }
        if active.contains(runStatus) { return .running }
        return runStatus == "completed" ? .done : .idle
    }
    var requestLabel: String {
        switch requestKind {
        case "command", "dynamic_tool_call": "Command"
        case "file-read": "File read"
        case "file-change": "File change"
        case "mcp-elicitation": "MCP"
        case "permission": "Permission"
        default: requestKind
        }
    }
}

struct T3Project: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

struct T3Session {
    private(set) var projects: [String: T3Project] = [:]
    private(set) var threads: [String: T3Thread] = [:]
    private(set) var messages: [String: [T3ChatMessage]] = [:]
    private(set) var prompts: [String: [String: String]] = [:]

    var sortedProjects: [T3Project] {
        projects.values.filter { project in threads.values.contains { $0.projectId == project.id } }
            .sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
    }
    func sortedThreads(projectId: String? = nil) -> [T3Thread] {
        threads.values.filter { projectId == nil || $0.projectId == projectId }.sorted {
            if $0.status.rank != $1.status.rank { return $0.status.rank < $1.status.rank }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return ($0.title, $0.id) < ($1.title, $1.id)
        }
    }
    var approvalThreads: [T3Thread] {
        threads.values.filter(\.isApproval).sorted { ($0.requestCreatedAt, $0.id) < ($1.requestCreatedAt, $1.id) }
    }

    mutating func applyShell(_ item: [String: Any]) {
        switch item["kind"] as? String {
        case "snapshot":
            guard let snapshot = item["snapshot"] as? [String: Any] else { return }
            let rows = snapshot["threads"] as? [[String: Any]] ?? []
            let projectRows = snapshot["projects"] as? [[String: Any]] ?? []
            let metadata = item["resolvedRepositoryIdentityRoots"] != nil
            let projectOnly = metadata || (!projectRows.isEmpty && rows.isEmpty &&
                (snapshot["archivedThreads"] as? [Any] ?? []).isEmpty && !threads.isEmpty)
            if !metadata { projects.removeAll() }
            for row in projectRows { upsertProject(row) }
            if !projectOnly {
                threads.removeAll()
                for row in rows { upsertThread(row) }
            }
        case "project.updated":
            if let row = item["project"] as? [String: Any] { upsertProject(row) }
        case "project.removed":
            if let id = item["projectId"] as? String {
                projects.removeValue(forKey: id)
                threads = threads.filter { $0.value.projectId != id }
            }
        case "thread.updated":
            if let row = item["thread"] as? [String: Any] {
                if item["location"] as? String == "archive", let id = row["id"] as? String {
                    threads.removeValue(forKey: id)
                } else { upsertThread(row) }
            }
        case "thread.removed":
            if let id = item["threadId"] as? String { threads.removeValue(forKey: id) }
        default: break
        }
        messages = messages.filter { threads[$0.key] != nil }
        prompts = prompts.filter { threads[$0.key] != nil }
    }
    private mutating func upsertProject(_ row: [String: Any]) {
        guard let id = row["id"] as? String else { return }
        projects[id] = T3Project(id: id, title: row["title"] as? String ?? "")
    }
    private mutating func upsertThread(_ row: [String: Any]) {
        guard let thread = T3Thread(row) else { return }
        if thread.archived { threads.removeValue(forKey: thread.id) }
        else { threads[thread.id] = thread }
    }
    mutating func applyThread(id: String, item: [String: Any]) {
        if item["kind"] as? String == "snapshot" {
            let snapshot = item["snapshot"] as? [String: Any]
            if let projection = (item["projection"] ?? snapshot?["projection"]) as? [String: Any] {
                prompts[id] = Self.collectPrompts(projection)
                messages[id] = (projection["messages"] as? [[String: Any]] ?? []).compactMap(T3ChatMessage.init).suffix(100).map { $0 }
            }
        } else if item["kind"] as? String == "event", let event = item["event"] as? [String: Any],
                  let payload = event["payload"] as? [String: Any] {
            let type = event["type"] as? String ?? ""
            if ["turn-item.updated", "runtime-request.updated"].contains(type) {
                prompts[id, default: [:]].merge(Self.collectPrompts(payload)) { _, new in new }
            }
            if type == "message.updated", let message = T3ChatMessage(payload) {
                var rows = messages[id] ?? []
                if let index = rows.firstIndex(where: { $0.id == message.id }) { rows[index] = message }
                else { rows.append(message) }
                messages[id] = Array(rows.suffix(100))
            }
        }
    }
    static func collectPrompts(_ value: [String: Any]) -> [String: String] {
        var found: [String: String] = [:]
        let item = value["item"] as? [String: Any] ?? value
        if item["type"] as? String == "approval_request", let id = item["requestId"] as? String,
           let text = item["prompt"] as? String, !text.isEmpty { found[id] = text }
        if value["kind"] != nil, let id = value["id"] as? String,
           let text = ["prompt", "detail", "summary"].compactMap({ value[$0] as? String }).first(where: { !$0.isEmpty }) {
            if found[id] == nil { found[id] = text }
        }
        for key in ["turnItems", "visibleTurnItems", "runtimeRequests"] {
            for child in value[key] as? [[String: Any]] ?? [] {
                found.merge(collectPrompts(child)) { first, _ in first }
            }
        }
        return found
    }
}

enum T3Protocol {
    static func origin(_ input: String) -> URL? {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = ["https", "wss"].contains(scheme) ? "https" : "http"
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.url
    }
    static func socketURL(base: URL, ticket: String?) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.path = "/ws"
        parts.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        if let ticket { parts.queryItems?.append(URLQueryItem(name: "wsTicket", value: ticket)) }
        return parts.url
    }
    static func threadURL(base: URL, environment: String?, thread: String) -> URL {
        guard let environment, !environment.isEmpty else { return base }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~"))
        // Encode each segment, including dots, so an ID cannot traverse the origin's paths.
        guard let env = environment.addingPercentEncoding(withAllowedCharacters: safe),
              let id = thread.addingPercentEncoding(withAllowedCharacters: safe) else { return base }
        parts.percentEncodedPath = "/\(env)/\(id)"
        return parts.url ?? base
    }
    static func headerSafe(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
    }
    static func frames(_ data: Data) -> [[String: Any]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
    }
    static func request(id: String, method: String, payload: [String: Any]) -> [String: Any] {
        ["_tag": "Request", "id": id, "tag": method, "payload": payload, "headers": []]
    }
    static func approvalCommand(thread: String, request: String, accept: Bool, commandId: String) -> [String: Any] {
        ["type": "runtime-request.respond", "commandId": commandId, "threadId": thread,
         "requestId": request, "decision": accept ? "accept" : "decline"]
    }
    static func environment(_ value: [String: Any]) -> String? {
        let nested = value["environment"] as? [String: Any]
        return [value["environmentId"], nested?["environmentId"]].compactMap { $0 as? String }.first { !$0.isEmpty }
    }
}

// Reconnects keep request deduplication but reset the baseline for terminal events.
struct T3Alerts {
    private var previous: [String: T3Status] = [:]
    private var approvals: Set<String> = []
    mutating func disconnected() { previous.removeAll() }
    mutating func take(_ session: T3Session) -> [T3Status] {
        var alerts: [T3Status] = []
        let open = Set(session.approvalThreads.map(\.requestId))
        for thread in session.threads.values {
            let status = thread.status
            if thread.isApproval && !approvals.contains(thread.requestId) { alerts.append(.approval) }
            if let before = previous[thread.id] {
                if before == .running && status == .done { alerts.append(.done) }
                else if before != .error && status == .error { alerts.append(.error) }
                else if before != .question && status == .question { alerts.append(.question) }
            }
        }
        previous = session.threads.mapValues(\.status)
        approvals = open
        return alerts
    }
}

// One stable pill per real shell project. Its representative prefers an active
// top-level parent of subagents, then the most urgent/recent thread. Status still
// includes child threads, so a child's approval cannot disappear behind its parent.
struct T3ProjectPill: Identifiable, Equatable, Sendable {
    let id: String
    let projectId: String
    let name: String
    let threadId: String?
    let status: T3Status
    static let fallbackId = "agent_t3"
    static func owns(_ id: String) -> Bool { id == fallbackId || id.hasPrefix("t3_project:") }
    static func id(project: String) -> String { "t3_project:\(project)" }
    static func map(_ session: T3Session) -> [T3ProjectPill] {
        session.projects.values.sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }.map { project in
            let threads = session.sortedThreads(projectId: project.id)
            let parentIds = Set(threads.filter { $0.relationshipToParent == "subagent" }.compactMap(\.parentThreadId))
            let orchestrator = threads.first {
                $0.relationshipToParent != "subagent" && parentIds.contains($0.id) &&
                    ["preparing", "starting", "running", "waiting"].contains($0.runStatus)
            }
            return T3ProjectPill(id: id(project: project.id), projectId: project.id, name: project.title,
                                 threadId: (orchestrator ?? threads.first)?.id,
                                 status: threads.first?.status ?? .idle)
        }
    }
}

struct T3ChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    let text: String
    let files: [String]
    let streaming: Bool
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, let role = raw["role"] as? String,
              ["user", "assistant"].contains(role) else { return nil }
        self.id = id; self.role = role
        text = raw["text"] as? String ?? ""
        files = (raw["attachments"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        streaming = raw["streaming"] as? Bool ?? false
    }
}

struct T3ClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct T3Attachment: Identifiable, Equatable, Sendable {
    let id: String
    let type: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
    var metadata: [String: Any] {
        ["type": type, "name": name, "mimeType": mimeType, "sizeBytes": sizeBytes]
    }
    var reference: [String: Any] { metadata.merging(["id": id]) { _, new in new } }
}

enum T3Composer {
    static let imageLimit = 10 * 1024 * 1024
    static let fileLimit = 50 * 1024 * 1024
    static let totalImageLimit = 80 * 1024 * 1024
    static let imageTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func validate(_ attachments: [T3Attachment], maxFileBytes: Int = fileLimit) throws {
        guard attachments.count <= 100 else { throw T3ClientError(message: "Attach at most 100 files per message.") }
        var imageBytes = 0
        for attachment in attachments {
            let image = attachment.type == "image"
            let limit = image ? imageLimit : min(maxFileBytes, fileLimit)
            guard attachment.sizeBytes > 0, attachment.sizeBytes <= limit else {
                let size = limit > 0 && limit % (1024 * 1024) == 0 ? "\(limit / 1024 / 1024) MiB" : "\(limit) bytes"
                throw T3ClientError(message: "\(attachment.name): file must be nonempty and at most \(size).")
            }
            guard !attachment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  attachment.name.utf16.count <= 255, !attachment.mimeType.isEmpty,
                  attachment.mimeType.utf16.count <= 100, T3Protocol.headerSafe(attachment.mimeType),
                  ["image", "file"].contains(attachment.type),
                  !image || imageTypes.contains(attachment.mimeType) else {
                throw T3ClientError(message: "Unsupported attachment name or image format. Use PNG, JPEG, GIF or WebP for images.")
            }
            if image || imageTypes.contains(attachment.mimeType) { imageBytes += attachment.sizeBytes }
        }
        guard imageBytes <= totalImageLimit else { throw T3ClientError(message: "Images can total at most 80 MiB per message.") }
    }
    static func uploadMetadata(name: String, mimeType: String, bytes: Int, maxFileBytes: Int = fileLimit) throws -> T3Attachment {
        let value = T3Attachment(id: "", type: imageTypes.contains(mimeType) ? "image" : "file",
                                 name: name, mimeType: mimeType, sizeBytes: bytes)
        try validate([value], maxFileBytes: maxFileBytes)
        return value
    }
    static func uploadURL(base: URL, relative: String) throws -> URL {
        guard relative.hasPrefix("/api/attachments/upload/"), !relative.contains("#"),
              let url = URL(string: relative, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else {
            throw T3ClientError(message: "The server returned an invalid attachment upload URL.")
        }
        return url
    }
    static func uploadRequest(base: URL, relative: String, mimeType: String) throws -> URLRequest {
        guard T3Protocol.headerSafe(mimeType) else { throw T3ClientError(message: "Invalid attachment content type.") }
        var request = URLRequest(url: try uploadURL(base: base, relative: relative), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        return request
    }
    static func message(thread: T3Thread, text: String, attachments: [T3Attachment],
                        commandId: String, messageId: String, serverResolvesContext: Bool) throws -> [String: Any] {
        guard text.utf16.count <= 120_000 else { throw T3ClientError(message: "Messages can contain at most 120,000 characters.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            throw T3ClientError(message: "Enter a message or attach a file.")
        }
        try validate(attachments)
        guard attachments.allSatisfy({ !$0.id.isEmpty }) else { throw T3ClientError(message: "Wait for attachments to finish uploading.") }
        let running = ["preparing", "starting", "running", "waiting"].contains(thread.runStatus)
        var mode: [String: Any] = ["type": "start_immediately"]
        if running && !serverResolvesContext {
            guard let run = thread.activeRunId, !run.isEmpty else {
                throw T3ClientError(message: "Waiting for the active run ID. Retry after the thread updates.")
            }
            mode = ["type": "steer_active", "targetRunId": run]
        }
        var command: [String: Any] = ["type": "message.dispatch", "commandId": commandId, "messageId": messageId,
            "threadId": thread.id, "createdBy": "user", "creationSource": "web", "text": text,
            "attachments": attachments.map(\.reference), "dispatchMode": mode]
        if serverResolvesContext { command["deliveryIntent"] = running ? "steer" : "auto" }
        return command
    }
}
