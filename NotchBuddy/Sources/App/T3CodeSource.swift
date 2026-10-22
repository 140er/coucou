import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

// Do not follow redirects with bearer or Cloudflare credentials.
private final class T3NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class T3CodeSource: ObservableObject {
    static let shared = T3CodeSource()
    static let pillId = "agent_t3"
    static let keys = ["t3-url", "t3-token", "t3-cf-client-id", "t3-cf-client-secret"]
    @Published private(set) var session = T3Session()
    @Published private(set) var connection = "Not configured"
    @Published private(set) var connected = false
    @Published private(set) var deciding: Set<String> = []
    @Published private(set) var presentedRequest: T3PendingRequest?
    @Published private(set) var requestError: String?
    private var dismissedRequests: Set<String> = []
    private var rememberedThreads: [String: String] = [:]
    private var base: URL?
    private var environment: String?
    private var supervisor: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var alerts = T3Alerts()
    @Published private(set) var selectedThreadId: String?
    @Published private(set) var draftFiles: [String: [T3DraftFile]] = [:]
    @Published var draftTexts: [String: String] = [:]
    @Published private(set) var sending: Set<String> = []
    @Published private(set) var chatError: String?
    private var subscriptions: Set<String> = []
    private var pendingRPC: [String: CheckedContinuation<Data, Error>] = [:]
    private var serverResolvesContext = false
    private var supportsUploads = false
    private var maxFileBytes: Int?
    private var activeUploads = 0
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var draftOrigin: URL?
    private var draftCommands: [String: (command: String, message: String)] = [:]
    private var cardIds: [String: UUID] = [:]
    private var dispatches: [String: String] = [:]
    private var enabledBefore = false
    private let http = URLSession(configuration: .ephemeral, delegate: T3NoRedirect(), delegateQueue: nil)

    private var enabled: Bool {
        !DemoEngine.isPollerPaused
    }
    func start() {
        guard supervisor == nil else { return }
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.enabled != self.enabledBefore {
                    self.enabledBefore = self.enabled
                    self.restart()
                }
                if self.connected {
                    self.presentRequests()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func restart() {
        generation = UUID()
        worker?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
        clearLive()
        base = nil; environment = nil
        alerts = T3Alerts()
        dismissedRequests.removeAll()
        guard enabled else { connection = "Disabled"; return }
        let values = Self.keys.map { KeychainStore.shared.get($0) ?? "" }
        guard let base = T3Protocol.origin(values[0]),
              values.dropFirst().allSatisfy({ $0.isEmpty || T3Protocol.headerSafe($0) }) else {
            connection = "Check the server URL and credentials in Settings → Agents."
            return
        }
        if let draftOrigin, draftOrigin != base {
            draftFiles = [:]; draftTexts = [:]; draftCommands = [:]
            chatError = "Server changed. Select a thread and attach files again."
        }
        draftOrigin = base
        self.base = base
        let current = generation
        worker = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self, self.generation == current else { return }
                self.connection = "Connecting…"
                let started = Date()
                do { try await self.serve(base: base, values: values, generation: current) }
                catch {
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    self.socket = nil
                    self.clearLive()
                    // Never interpolate errors: URLSession errors can include ticket URLs.
                    self.connection = "Connection failed. Check the URL, token and network. Retrying…"
                }
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(started) > 20 { delay = 1 }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }
    private func clearLive() {
        connected = false; session = T3Session(); deciding.removeAll(); dispatches.removeAll()
        for task in uploadTasks.values { task.cancel() }
        alerts.disconnected(); cardIds.removeAll(); subscriptions.removeAll()
        let waiting = pendingRPC; pendingRPC.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: T3ClientError(message: "Disconnected. Draft kept; check the thread before retrying a send.")) }
        supportsUploads = false; maxFileBytes = nil; serverResolvesContext = false
        // Keep seen approvals across reconnects, like the reference's Seen object.
        clearCard()
        presentedRequest = nil; requestError = nil
        AppState.shared.isPinned = false
        AppState.shared.replaceT3Tasks([])
    }
    private func check(_ current: UUID) throws {
        try Task.checkCancellation()
        guard generation == current, enabled else { throw URLError(.cancelled) }
    }
    private func serve(base: URL, values: [String], generation current: UUID) async throws {
        func request(_ path: String) -> URLRequest {
            var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 10)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if !values[2].isEmpty && !values[3].isEmpty {
                req.setValue(values[2], forHTTPHeaderField: "CF-Access-Client-Id")
                req.setValue(values[3], forHTTPHeaderField: "CF-Access-Client-Secret")
            }
            return req
        }
        var ticket: String?
        if !values[1].isEmpty {
            var req = request("api/auth/websocket-ticket")
            req.httpMethod = "POST"
            req.setValue("Bearer \(values[1])", forHTTPHeaderField: "Authorization")
            let (data, response) = try await http.data(for: req)
            try check(current)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let issued = json["ticket"] as? String, !issued.isEmpty else { throw URLError(.userAuthenticationRequired) }
            ticket = issued
        }
        environment = nil
        if let (data, response) = try? await http.data(for: request(".well-known/t3/environment")),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try check(current)
            environment = T3Protocol.environment(json)
        }
        try check(current)
        guard let url = T3Protocol.socketURL(base: base, ticket: ticket) else { throw URLError(.badURL) }
        var upgrade = request("ws")
        upgrade.url = url
        upgrade.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        let ws = http.webSocketTask(with: upgrade)
        ws.maximumMessageSize = 16 * 1024 * 1024
        socket = ws; ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }
        try await send(T3Protocol.request(id: "shell", method: "orchestration.subscribeShell", payload: [:]), socket: ws)
        try await send(T3Protocol.request(id: "config", method: "server.getConfig", payload: [:]), socket: ws)
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(20))
                    try await self.send(["_tag": "Ping"], socket: ws)
                } catch { ws.cancel(with: .goingAway, reason: nil); return }
            }
        }
        defer { heartbeat.cancel() }
        while !Task.isCancelled {
            let message = try await ws.receive()
            try check(current)
            let data: Data
            switch message {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: continue
            }
            for frame in T3Protocol.frames(data) {
                let id = (frame["requestId"] as? String) ?? (frame["requestId"] as? NSNumber)?.stringValue ?? ""
                switch frame["_tag"] as? String {
                case "Ping": try await send(["_tag": "Pong"], socket: ws)
                case "Chunk":
                    if !id.isEmpty { try await send(["_tag": "Ack", "requestId": id], socket: ws) }
                    try check(current)
                    let values = (frame["values"] as? [[String: Any]]) ?? (frame["values"] as? [String: Any]).map { [$0] } ?? []
                    for item in values {
                        if id == "shell" { session.applyShell(item); connected = true; connection = "Connected" }
                        else if id.hasPrefix("thread:") { session.applyThread(id: String(id.dropFirst(7)), item: item) }
                    }
                    publish()
                    try await syncSubscriptions()
                    try check(current)
                case "Exit":
                    if id == "shell" { throw URLError(.cannotParseResponse) }
                    let exit = frame["exit"] as? [String: Any] ?? [:]
                    if id == "config", exit["_tag"] as? String == "Success",
                       let config = exit["value"] as? [String: Any],
                       let env = config["environment"] as? [String: Any] {
                        environment = env["environmentId"] as? String ?? environment
                        let caps = env["capabilities"] as? [String: Any] ?? [:]
                        serverResolvesContext = caps["serverResolvedCommandContext"] as? Bool == true
                        supportsUploads = caps["attachmentUploads"] as? Bool == true
                        maxFileBytes = (caps["fileAttachments"] as? [String: Any])?["maxUploadBytes"] as? Int
                    }
                    if let continuation = pendingRPC.removeValue(forKey: id) {
                        if exit["_tag"] as? String == "Success" {
                            let value = exit["value"] ?? NSNull()
                            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: T3ClientError(message: "T3 rejected the request. Check the selected thread and the token’s permissions, then retry."))
                        }
                    }
                    if let request = dispatches.removeValue(forKey: id) {
                        let exit = frame["exit"] as? [String: Any]
                        if exit?["_tag"] as? String != "Success" {
                            deciding.remove(request)
                            connection = "Decision failed. Retry or open the thread in T3 Code."
                        }
                    }
                    if id.hasPrefix("thread:") { subscriptions.remove(String(id.dropFirst(7))) }
                case "Defect", "ClientProtocolError": throw URLError(.cannotParseResponse)
                default: break
                }
                try check(current)
            }
        }
    }
    private func send(_ frame: [String: Any], socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        try await socket.send(.string(text))
    }
    func decide(cardId: UUID?, accept: Bool) {
        guard connected, let socket, let shown = AppState.shared.pendingApproval,
              T3ProjectPill.owns(shown.pillId), cardId == nil || cardId == shown.id,
              let thread = session.threads[shown.sessionId], thread.isApproval,
              cardIds[thread.requestId] == shown.id, !deciding.contains(thread.requestId) else { return }
        deciding.insert(thread.requestId)
        let rpc = UUID().uuidString
        dispatches[rpc] = thread.requestId
        let current = generation
        Task {
            do {
                try await send(T3Protocol.request(id: rpc, method: "orchestration.dispatchCommand",
                    payload: T3Protocol.approvalCommand(thread: thread.id, request: thread.requestId,
                                                       accept: accept, commandId: UUID().uuidString)), socket: socket)
                try check(current)
            } catch {
                guard current == generation else { return }
                deciding.remove(thread.requestId); dispatches.removeValue(forKey: rpc)
                connection = "Decision failed. Retry or open the thread in T3 Code."
            }
        }
    }
    private func publish() {
        let app = AppState.shared
        let open = Set(session.pendingThreads.map(\.requestId))
        deciding.formIntersection(open)
        cardIds = cardIds.filter { open.contains($0.key) }
        let events = alerts.take(session)
        for status in events {
            let sound: String = switch status {
            case .approval: "approval"
            case .question: "question"
            case .error: "error"
            default: "finish"
            }
            if app.soundEnabled { SoundEngine.shared.play(sound) }
        }
        if events.contains(where: { $0 != .approval }), app.pendingApproval == nil {
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        app.replaceT3Tasks(T3ProjectPill.map(session))
        if let selectedThreadId, session.threads[selectedThreadId] == nil { self.selectedThreadId = nil }
        presentRequests()
    }
    private func clearCard() {
        let app = AppState.shared
        guard let pill = app.pendingApproval?.pillId, T3ProjectPill.owns(pill) else { return }
        app.pendingApproval = nil
        app.isPinned = false
        if app.view == .approval { app.view = .overview }
    }
    var pendingRequests: [T3PendingRequest] { T3PendingRequest.list(session) }
    private func presentRequests() {
        let pending = pendingRequests
        dismissedRequests.formIntersection(Set(pending.map(\.id)))
        if let shown = presentedRequest {
            if let live = pending.first(where: { $0.id == shown.id && $0.threadId == shown.threadId }) {
                if live != shown { presentedRequest = live }
            } else {
                presentedRequest = nil
                requestError = nil
                AppState.shared.isPinned = false
            }
            return
        }
        guard let next = pending.first(where: { !dismissedRequests.contains($0.id) }) else { return }
        showRequest(next)
    }
    private func showRequest(_ request: T3PendingRequest) {
        presentedRequest = request
        requestError = nil
        AppState.shared.isPinned = true
        if AppState.shared.mode != .expanded {
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)
        }
    }
    func showRequests(projectId: String? = nil) {
        if let request = pendingRequests.first(where: { projectId == nil || $0.projectId == projectId }) {
            dismissedRequests.remove(request.id)
            showRequest(request)
        }
    }
    func dismissRequest() {
        if let shown = presentedRequest { dismissedRequests.insert(shown.id) }
        presentedRequest = nil
        requestError = nil
        AppState.shared.isPinned = false
    }
    func respond(_ request: T3PendingRequest, accept: Bool? = nil, selections: [String: [String]] = [:], custom: [String: String] = [:]) {
        guard connected, pendingRequests.contains(where: { $0.id == request.id && $0.threadId == request.threadId }),
              !deciding.contains(request.id) else { return }
        do {
            let command = try request.response(commandId: UUID().uuidString, accept: accept, selections: selections, custom: custom)
            deciding.insert(request.id); requestError = nil
            let current = generation
            Task {
                do { _ = try await rpc("orchestration.dispatchCommand", payload: command) }
                catch {
                    guard generation == current else { return }
                    deciding.remove(request.id)
                    if presentedRequest?.id == request.id {
                        requestError = (error as? T3ClientError)?.message ?? "Could not send the answer. Try again."
                    }
                }
            }
        } catch { requestError = (error as? T3ClientError)?.message ?? "Check your answer." }
    }
    func open(thread: T3Thread? = nil) {
        guard let base else { return }
        NSWorkspace.shared.open((thread ?? selectedThread).map { T3Protocol.threadURL(base: base, environment: environment, thread: $0.id) } ?? base)
    }
    var pills: [T3ProjectPill] { T3ProjectPill.map(session) }
    var selectedThread: T3Thread? {
        let project = pills.first { $0.id == AppState.shared.focusId }
        if let selectedThreadId, let thread = session.threads[selectedThreadId], !thread.isSubagent, thread.projectId == project?.projectId { return thread }
        return project?.threadId.flatMap { session.threads[$0] }
    }
    func select(pill id: String, openInT3: Bool = false) {
        guard let pill = pills.first(where: { $0.id == id }) else { return }
        AppState.shared.setFocus(id)
        let remembered = rememberedThreads[pill.projectId].flatMap { session.threads[$0] }
        selectedThreadId = remembered?.isSubagent == false ? remembered?.id : pill.threadId
        chatError = nil
        Task { try? await syncSubscriptions() }
        if openInT3 { open(thread: selectedThread) }
    }
    func selectThread(_ id: String) {
        guard let thread = session.threads[id], !thread.isSubagent, pills.contains(where: { $0.projectId == thread.projectId }) else { return }
        AppState.shared.setFocus(T3ProjectPill.id(project: thread.projectId))
        selectedThreadId = id
        rememberedThreads[thread.projectId] = id
        chatError = nil
        Task { try? await syncSubscriptions() }
    }
    func openChat() {
        if let thread = selectedThread { selectedThreadId = thread.id }
        AppState.shared.view = .prompt
        Task { try? await syncSubscriptions() }
    }
    private func syncSubscriptions() async throws {
        guard let socket else { return }
        let current = generation
        var wanted = Set(session.pendingThreads.map(\.id))
        if let thread = selectedThread { wanted.insert(thread.id) }
        let old = subscriptions
        subscriptions = wanted
        for id in old.subtracting(wanted) {
            try await send(["_tag": "Interrupt", "requestId": "thread:\(id)"], socket: socket)
            try check(current)
        }
        for id in wanted.subtracting(old) {
            try await send(T3Protocol.request(id: "thread:\(id)", method: "orchestration.subscribeThread", payload: ["threadId": id]), socket: socket)
            try check(current)
        }
    }
    private func rpc(_ method: String, payload: [String: Any]) async throws -> Data {
        guard connected, let socket else { throw T3ClientError(message: "Connect to T3 Code before sending or uploading.") }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pendingRPC[id] = continuation
            Task {
                do { try await send(T3Protocol.request(id: id, method: method, payload: payload), socket: socket) }
                catch { pendingRPC.removeValue(forKey: id)?.resume(throwing: T3ClientError(message: "Send failed. Draft kept; check the thread before retrying.")) }
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                pendingRPC.removeValue(forKey: id)?.resume(throwing: T3ClientError(message: "T3 did not acknowledge the request. Draft kept; check the thread before retrying."))
            }
        }
    }
    func updateDraft(thread: String, text: String) {
        guard !sending.contains(thread) else { return }
        if draftTexts[thread] != text { draftCommands[thread] = nil }
        draftTexts[thread] = text
    }
    func sendMessage() {
        guard let thread = selectedThread, !sending.contains(thread.id) else { return }
        let text = draftTexts[thread.id] ?? ""
        let files = draftFiles[thread.id] ?? []
        guard files.allSatisfy({ $0.attachment != nil }) else {
            chatError = "Wait for uploads to finish, or remove failed files."; return
        }
        let ids = draftCommands[thread.id] ?? (command: UUID().uuidString, message: UUID().uuidString)
        draftCommands[thread.id] = ids
        do {
            let command = try T3Composer.message(thread: thread, text: text, attachments: files.compactMap(\.attachment),
                commandId: ids.command, messageId: ids.message, serverResolvesContext: serverResolvesContext)
            sending.insert(thread.id); chatError = nil
            Task {
                defer { sending.remove(thread.id) }
                do {
                    _ = try await rpc("orchestration.dispatchCommand", payload: command)
                    draftTexts[thread.id] = ""; draftFiles[thread.id] = []; draftCommands[thread.id] = nil
                } catch { chatError = (error as? T3ClientError)?.message ?? "Message failed. Draft kept." }
            }
        } catch { chatError = (error as? T3ClientError)?.message ?? "Message could not be sent." }
    }
    func chooseFiles() {
        openChat()
        guard let target = selectedThread?.id else { chatError = "Select an existing T3 thread first."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK { Task { @MainActor in self.attachFiles(panel.urls, to: target) } }
        }
    }
    func attachText(_ text: String, to target: String? = nil) {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            try Data(text.utf8).write(to: url)
            attachFiles([url], to: target, removeAfterUpload: true)
        } catch { chatError = "Could not stage the dropped text." }
    }
    func attachFiles(_ urls: [URL], to target: String? = nil, removeAfterUpload: Bool = false) {
        openChat()
        let destination = target == nil ? selectedThread : target.flatMap { session.threads[$0] }
        guard connected, supportsUploads, let thread = destination else {
            chatError = "Select a thread on a connected T3 server that supports attachment uploads."
            if removeAfterUpload { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            return
        }
        guard !sending.contains(thread.id) else {
            chatError = "Wait for the current message to finish sending."
            if removeAfterUpload { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            return
        }
        guard (draftFiles[thread.id]?.count ?? 0) + urls.count <= 100 else {
            chatError = "Attach at most 100 files per message."
            if removeAfterUpload { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            return
        }
        for url in urls {
            let itemId = UUID()
            let current = generation
            let item = T3DraftFile(id: itemId, name: url.lastPathComponent, attachment: nil, error: nil)
            draftFiles[thread.id, default: []].append(item)
            uploadTasks[itemId] = Task {
                defer { uploadTasks.removeValue(forKey: itemId) }
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    if removeAfterUpload { try? FileManager.default.removeItem(at: url) }
                }
                var pendingId: String?
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
                    guard values.isRegularFile == true else { throw T3ClientError(message: "Attach regular files, not folders.") }
                    let mime = values.contentType?.preferredMIMEType ?? "application/octet-stream"
                    if !T3Composer.imageTypes.contains(mime), maxFileBytes == nil { throw T3ClientError(message: "This server does not support file attachments.") }
                    let metadata = try T3Composer.uploadMetadata(name: url.lastPathComponent, mimeType: mime,
                        bytes: values.fileSize ?? 0, maxFileBytes: maxFileBytes ?? 0)
                    guard let index = draftFiles[thread.id]?.firstIndex(where: { $0.id == itemId }) else { return }
                    let staged = (draftFiles[thread.id] ?? []).filter { $0.id != itemId }.compactMap(\.metadata) + [metadata]
                    try T3Composer.validate(staged, maxFileBytes: maxFileBytes ?? 0)
                    draftFiles[thread.id]?[index].metadata = metadata
                    while activeUploads >= 3 {
                        try await Task.sleep(for: .milliseconds(200))
                        try check(current)
                    }
                    guard draftFiles[thread.id]?.contains(where: { $0.id == itemId }) == true else { return }
                    activeUploads += 1
                    defer { activeUploads -= 1 }
                    let response = try await rpc("attachments.createUploadUrl", payload: metadata.metadata)
                    try check(current)
                    guard let minted = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                          let id = minted["attachmentId"] as? String, let relative = minted["relativeUrl"] as? String,
                          let base else { throw T3ClientError(message: "Invalid upload response from T3.") }
                    pendingId = id
                    var request = try T3Composer.uploadRequest(base: base, relative: relative, mimeType: mime)
                    if let accessId = KeychainStore.shared.get("t3-cf-client-id"), !accessId.isEmpty,
                       let accessSecret = KeychainStore.shared.get("t3-cf-client-secret"), !accessSecret.isEmpty {
                        request.setValue(accessId, forHTTPHeaderField: "CF-Access-Client-Id")
                        request.setValue(accessSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
                    }
                    let (_, result) = try await http.upload(for: request, fromFile: url)
                    try check(current)
                    guard let status = (result as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                        throw T3ClientError(message: "Upload failed or expired. Remove the file and attach it again.")
                    }
                    guard let index = draftFiles[thread.id]?.firstIndex(where: { $0.id == itemId }) else {
                        _ = try? await rpc("attachments.delete", payload: ["attachmentId": id]); return
                    }
                    draftFiles[thread.id]?[index].attachment = T3Attachment(id: id, type: metadata.type, name: metadata.name, mimeType: mime, sizeBytes: metadata.sizeBytes)
                } catch {
                    if current == generation, let id = pendingId { _ = try? await rpc("attachments.delete", payload: ["attachmentId": id]) }
                    if let index = draftFiles[thread.id]?.firstIndex(where: { $0.id == itemId }) {
                        draftFiles[thread.id]?[index].metadata = nil
                        draftFiles[thread.id]?[index].error = (error as? T3ClientError)?.message ?? "Upload failed. Check the connection and attach the file again."
                    }
                }
            }
        }
    }
    func attachImage(_ data: Data, extension suffix: String, to target: String?) {
        do {
            guard data.count <= T3Composer.imageLimit else { throw T3ClientError(message: "Images must be at most 10 MiB.") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
            try data.write(to: url)
            attachFiles([url], to: target, removeAfterUpload: true)
        } catch { chatError = (error as? T3ClientError)?.message ?? "Could not stage the dropped image." }
    }
    func removeFile(thread: String, id: UUID) {
        guard !sending.contains(thread), let item = draftFiles[thread]?.first(where: { $0.id == id }) else { return }
        uploadTasks[id]?.cancel()
        draftFiles[thread]?.removeAll { $0.id == id }
        draftCommands[thread] = nil
        if let attachment = item.attachment { Task { _ = try? await rpc("attachments.delete", payload: ["attachmentId": attachment.id]) } }
    }

}

struct T3DraftFile: Identifiable {
    let id: UUID
    let name: String
    var attachment: T3Attachment?
    var metadata: T3Attachment? = nil
    var error: String?
}
