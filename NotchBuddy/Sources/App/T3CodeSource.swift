import AppKit
import Combine
import Foundation

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
    private var base: URL?
    private var environment: String?
    private var supervisor: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var alerts = T3Alerts()
    private var finishedUntil: Date?
    private var cardIds: [String: UUID] = [:]
    private var dispatches: [String: String] = [:]
    private var enabledBefore = false
    private let http = URLSession(configuration: .ephemeral, delegate: T3NoRedirect(), delegateQueue: nil)

    private var enabled: Bool {
        let app = AppState.shared
        return !DemoEngine.isPollerPaused &&
            (app.mainPillId == Self.pillId || app.activeIntegrations.contains(Self.pillId))
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
                    self.presentApproval()
                    if let until = self.finishedUntil, Date() >= until {
                        self.finishedUntil = nil
                        self.publish()
                    }
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
        guard enabled else { connection = "Disabled"; return }
        let values = Self.keys.map { KeychainStore.shared.get($0) ?? "" }
        guard let base = T3Protocol.origin(values[0]),
              values.dropFirst().allSatisfy({ $0.isEmpty || T3Protocol.headerSafe($0) }) else {
            connection = "Check the server URL and credentials in Settings → Agents."
            return
        }
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
        alerts.disconnected(); cardIds.removeAll(); finishedUntil = nil
        // Keep seen approvals across reconnects, like the reference's Seen object.
        clearCard()
        AppState.shared.updateTask(id: Self.pillId, state: .idle)
        if let index = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            AppState.shared.tasks[index].pillBadge = nil
            AppState.shared.tasks[index].steps = []
        }
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
        var subscriptions: Set<String> = []
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
                    let wanted = Set(session.approvalThreads.map(\.id))
                    for thread in subscriptions.subtracting(wanted) {
                        try await send(["_tag": "Interrupt", "requestId": "thread:\(thread)"], socket: ws)
                    }
                    for thread in wanted.subtracting(subscriptions) {
                        try await send(T3Protocol.request(id: "thread:\(thread)", method: "orchestration.subscribeThread",
                                                          payload: ["threadId": thread]), socket: ws)
                    }
                    try check(current)
                    subscriptions = wanted
                    publish()
                case "Exit":
                    if id == "shell" { throw URLError(.cannotParseResponse) }
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
              shown.pillId == Self.pillId, cardId == nil || cardId == shown.id,
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
        let open = Set(session.approvalThreads.map(\.requestId))
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
        if let urgent = session.sortedThreads().first {
            var state: BotState = switch urgent.status {
            case .approval: .approval
            case .question: .question
            case .error: .error
            case .running: .working
            case .done, .idle: .idle
            }
            if state == .idle {
                if events.contains(.done) { finishedUntil = Date().addingTimeInterval(5.2) }
                if let until = finishedUntil, until > Date() { state = .finished }
            } else { finishedUntil = nil }
            app.updateTask(id: Self.pillId, state: state)
            if let index = app.tasks.firstIndex(where: { $0.id == Self.pillId }) {
                let project = session.projects[urgent.projectId]?.title ?? ""
                app.tasks[index].steps = [project, urgent.title].filter { !$0.isEmpty }
                app.tasks[index].stepIndex = 0
            }
            if app.focusId != Self.pillId {
                if let index = app.tasks.firstIndex(where: { $0.id == Self.pillId }) {
                    app.tasks[index].pillBadge = urgent.status == .approval ? .approval : urgent.status == .error ? .error : ([T3Status.question, .done].contains(urgent.status) && !events.isEmpty ? .finished : nil)
                }
            }
        } else { app.updateTask(id: Self.pillId, state: .idle) }
        presentApproval()
    }
    private func clearCard() {
        let app = AppState.shared
        guard app.pendingApproval?.pillId == Self.pillId else { return }
        app.pendingApproval = nil
        app.isPinned = false
        if app.view == .approval { app.view = .overview }
    }
    private func presentApproval() {
        let app = AppState.shared
        if let shown = app.pendingApproval, shown.pillId == Self.pillId {
            if let thread = session.threads[shown.sessionId], cardIds[thread.requestId] == shown.id, thread.isApproval {
                app.pendingApproval?.command = session.prompts[thread.id]?[thread.requestId] ?? thread.requestLabel
                app.pendingApproval?.queueCount = session.approvalThreads.count
                return
            }
            clearCard()
        }
        guard app.pendingApproval == nil, app.pendingQuestion == nil,
              let thread = session.approvalThreads.first else { return }
        let id = cardIds[thread.requestId] ?? UUID()
        cardIds[thread.requestId] = id
        app.pendingApproval = ApprovalInfo(sessionId: thread.id, tool: thread.requestLabel,
            command: session.prompts[thread.id]?[thread.requestId] ?? thread.requestLabel,
            inputKey: thread.requestId, pillId: Self.pillId, id: id, queueCount: session.approvalThreads.count,
            projectName: session.projects[thread.projectId]?.title ?? thread.title)
        app.isPinned = true
        app.focusId = Self.pillId
        if app.mode == .expanded { app.view = .approval }
        else { NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval) }
    }
    func open(thread: T3Thread? = nil) {
        guard let base else { return }
        NSWorkspace.shared.open(thread.map { T3Protocol.threadURL(base: base, environment: environment, thread: $0.id) } ?? base)
    }
}
