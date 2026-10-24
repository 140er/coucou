import SwiftUI
import UniformTypeIdentifiers

struct T3CodeSettingsView: View {
    @ObservedObject private var source = T3CodeSource.shared
    @State private var url = KeychainStore.shared.get("t3-url") ?? ""
    @State private var token = KeychainStore.shared.get("t3-token") ?? ""
    @State private var accessId = KeychainStore.shared.get("t3-cf-client-id") ?? ""
    @State private var accessSecret = KeychainStore.shared.get("t3-cf-client-secret") ?? ""
    @State private var validation: String?

    var body: some View {
        GroupBox("T3 Code") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect a T3 Code server. Its projects appear automatically as live pills.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Server URL (http://host:3773)", text: $url)
                SecureField("Session token (optional for a local server)", text: $token)
                DisclosureGroup("Cloudflare Access (optional)") {
                    TextField("Client ID", text: $accessId)
                    SecureField("Client secret", text: $accessSecret)
                }
                HStack {
                    Button("Save and reconnect") {
                        guard T3Protocol.origin(url) != nil,
                              [token, accessId, accessSecret].allSatisfy({ $0.isEmpty || T3Protocol.headerSafe($0) }),
                              accessId.isEmpty == accessSecret.isEmpty else {
                            validation = "Enter an HTTP(S) server URL without credentials, and both Cloudflare fields or neither."
                            return
                        }
                        for (key, value) in zip(T3CodeSource.keys, [url.trimmingCharacters(in: .whitespacesAndNewlines), token, accessId, accessSecret]) {
                            if value.isEmpty { KeychainStore.shared.remove(key) }
                            else { KeychainStore.shared.set(key, value: value) }
                        }
                        validation = nil
                        source.restart()
                    }
                    Button("Disconnect and forget") {
                        T3CodeSource.keys.forEach { KeychainStore.shared.remove($0) }
                        url = ""; token = ""; accessId = ""; accessSecret = ""
                        validation = nil
                        source.restart()
                    }
                    Text(source.connection).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let validation { Text(validation).font(.system(size: 11)).foregroundStyle(.red) }
                Text("Credentials are saved in this Mac’s Keychain. Requests appear as popups in Coucou.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
}

// Existing island surface and typography; real projects replace the old catalog.
struct T3CodeCardView: View {
    let pillId: String
    @ObservedObject private var source = T3CodeSource.shared
    private var project: T3ProjectPill? { source.pills.first { $0.id == pillId } }
    private var color: Color { Color(hex: AppState.shared.focusTask?.color ?? "#38BDF8") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(project?.name ?? "T3 Code").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(source.connected ? Color.green : Color.orange).frame(width: 5, height: 5).help(source.connection)
                Button { source.open() } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain).help("Open selected thread in browser")
            }
            if let project {
                let requests = source.pendingRequests.filter { $0.projectId == project.projectId }
                if !requests.isEmpty {
                    Button { source.showRequests(projectId: project.projectId) } label: {
                        Label("\(requests.count) waiting for you", systemImage: "exclamationmark.bubble")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }.buttonStyle(.plain)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(source.session.chatThreads(projectId: project.projectId)) { thread in
                            Button {
                                source.selectThread(thread.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(thread.title).font(.system(size: 12)).lineLimit(1)
                                    Text(T3StatusLabel.text(thread.status)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 5)
                                .background(source.selectedThread?.id == thread.id ? color.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).help(thread.title)
                        }
                    }
                }
                if project.threadId != nil {
                    Button("Chat with selected thread") { source.openChat() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                } else {
                    Text("No top-level threads yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text(source.connected ? "No projects yet. Create a project in T3 Code." : "Set the server URL and token in Settings → Agents.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Reconnect") { source.restart() }.buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }
}

struct T3ProjectsSettingsView: View {
    @ObservedObject private var source = T3CodeSource.shared
    var body: some View {
        GroupBox("T3 Code projects") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Each server project appears automatically. Active orchestrators open ahead of other threads; status includes pending requests in their child threads.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(source.connection).font(.system(size: 12))
                ForEach(source.pills) { pill in
                    HStack {
                        Text(pill.name)
                        Spacer()
                        Text(T3StatusLabel.text(pill.status)).foregroundStyle(.secondary)
                        Button("Open") { source.select(pill: pill.id, openInT3: true) }
                    }
                }
                if source.pills.isEmpty { Text("Connect in Agents to load projects.").foregroundStyle(.secondary) }
            }.padding(6)
        }
    }
}

enum T3StatusLabel {
    static func text(_ state: BotState) -> String {
        switch state {
        case .working, .thinking, .searching: String(localized: "Running")
        case .approval: String(localized: "Approval")
        case .question: String(localized: "Needs answer")
        case .finished: String(localized: "Done")
        case .error: String(localized: "Error")
        default: String(localized: "Idle")
        }
    }
    static func text(_ status: T3Status) -> String {
        switch status {
        case .running: String(localized: "Running")
        case .approval: String(localized: "Approval")
        case .question: String(localized: "Needs answer")
        case .done: String(localized: "Done")
        case .error: String(localized: "Error")
        case .idle: String(localized: "Idle")
        }
    }
}

struct T3ChatView: View {
    @ObservedObject private var source = T3CodeSource.shared
    @ObservedObject private var app = AppState.shared
    @State private var dropTarget = false
    private var thread: T3Thread? { source.selectedThread }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thread {
                HStack {
                    Menu {
                        ForEach(source.pills) { pill in
                            Button(pill.name) { source.select(pill: pill.id) }
                        }
                    } label: {
                        Text(app.focusTask?.name ?? "T3 Code").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }.menuStyle(.borderlessButton).frame(width: 160, alignment: .leading)
                    Picker("Thread", selection: Binding(get: { thread.id }, set: { source.selectThread($0) })) {
                        ForEach(source.session.chatThreads(projectId: thread.projectId)) { row in
                            Text(row.title).tag(row.id)
                        }
                    }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity)
                    if source.pendingRequests.contains(where: { $0.projectId == thread.projectId }) {
                        Button { source.showRequests(projectId: thread.projectId) } label: { Image(systemName: "exclamationmark.bubble") }
                            .buttonStyle(.plain).foregroundStyle(.orange).help("Answer pending request")
                    }
                    Button { source.open(thread: thread) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain)
                }
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(source.session.messages[thread.id] ?? []) { message in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(message.role == "assistant" ? "T3 Code" : "You")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    Text(message.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    ForEach(Array(message.files.enumerated()), id: \.offset) { _, name in
                                        Label(name, systemImage: "paperclip").font(.system(size: 11))
                                    }
                                    if message.streaming { Text("Replying…").font(.system(size: 11)).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hex: "#111214"))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onAppear { if let last = source.session.messages[thread.id]?.last { scroll.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: thread.id) { _, _ in if let last = source.session.messages[thread.id]?.last { scroll.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: source.session.messages[thread.id]) { _, rows in
                        if let last = rows?.last { scroll.scrollTo(last.id, anchor: .bottom) }
                    }
                }.frame(maxHeight: .infinity)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(source.draftFiles[thread.id] ?? []) { file in
                            HStack(spacing: 4) {
                                Text(file.name).lineLimit(1)
                                Text(file.error ?? (file.attachment == nil ? "Uploading…" : "Ready"))
                                    .foregroundStyle(file.error == nil ? Color.secondary : Color.red)
                                Button { source.removeFile(thread: thread.id, id: file.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                            }.font(.system(size: 11)).help(file.error ?? file.name)
                        }
                    }
                }.frame(maxHeight: (source.draftFiles[thread.id] ?? []).isEmpty ? 0 : 24)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 7).fill(Color(hex: "#24262A"))
                    if (source.draftTexts[thread.id] ?? "").isEmpty {
                        Text("Message this thread…").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.leading, 9).padding(.top, 9).allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(get: { source.draftTexts[thread.id] ?? "" }, set: { source.updateDraft(thread: thread.id, text: $0) }))
                        .font(.system(size: 12)).scrollContentBackground(.hidden).padding(4)
                        .disabled(source.sending.contains(thread.id))
                }.frame(height: 60)

                HStack {
                    Button { source.chooseFiles() } label: { Label("Attach", systemImage: "plus") }
                    Text(T3StatusLabel.text(thread.status)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(source.sending.contains(thread.id) ? "Sending…" : "Send") { source.sendMessage() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: app.focusTask?.color ?? "#38BDF8"))
                        .disabled(!source.connected || source.sending.contains(thread.id) ||
                                  ((source.draftTexts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (source.draftFiles[thread.id] ?? []).isEmpty) ||
                                  (source.draftFiles[thread.id] ?? []).contains { $0.attachment == nil })
                }
            } else {
                Text("Select a project with an existing thread to chat. Create new threads in T3 Code.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = source.chatError { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onDrop(of: [UTType.fileURL, UTType.png, UTType.jpeg, UTType.plainText], isTargeted: $dropTarget) { providers in
            let client = source
            guard let target = client.selectedThread?.id else { return false }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in client.attachFiles([url], to: target) }
                    }
                } else if let type = [UTType.png, UTType.jpeg].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                    let suffix = type == .png ? "png" : "jpg"
                    _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in client.attachImage(data, extension: suffix, to: target) }
                    }
                } else {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                        guard let data, let text = String(data: data, encoding: .utf8) else { return }
                        Task { @MainActor in client.attachText(text, to: target) }
                    }
                }
            }
            return !providers.isEmpty
        }
    }
}

struct T3RequestPopup: View {
    let request: T3PendingRequest
    @ObservedObject private var source = T3CodeSource.shared
    @State private var selections: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]
    private var live: T3PendingRequest { source.pendingRequests.first { $0.id == request.id && $0.threadId == request.threadId } ?? request }
    private var busy: Bool { source.deciding.contains(request.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(live.kind == "user_input" ? "Answer needed" : live.kind == "auth_refresh" ? "Sign-in needed" : "Approval requested")
                    .font(.system(size: 18, weight: .semibold))
                HStack {
                    Text("\(live.projectName) · \(live.threadTitle)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button { source.open(thread: source.session.threads[live.threadId]) } label: { Image(systemName: "arrow.up.right") }
                        .buttonStyle(.plain).help("Open request in T3 Code")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if live.kind == "user_input" {
                        if live.questions.isEmpty { Text("Loading question details…").foregroundStyle(.secondary) }
                        ForEach(live.questions) { question in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(question.question).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                                    Button {
                                        var selected = selections[question.id] ?? []
                                        if question.multiple {
                                            if selected.contains(option.value) { selected.removeAll { $0 == option.value } }
                                            else { selected.append(option.value) }
                                        } else { selected = [option.value] }
                                        selections[question.id] = selected
                                        custom[question.id] = ""
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: (selections[question.id] ?? []).contains(option.value) ? "checkmark.circle.fill" : "circle")
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(option.label).font(.system(size: 12, weight: .medium))
                                                if !option.description.isEmpty { Text(option.description).font(.system(size: 11)).foregroundStyle(.secondary) }
                                            }
                                            Spacer(minLength: 0)
                                        }.padding(9).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                if question.custom {
                                    TextField(question.options.isEmpty ? "Your answer" : "Or enter your own answer", text: Binding(
                                        get: { custom[question.id] ?? "" }, set: { custom[question.id] = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    } else {
                        Text(live.prompt).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 60, maxHeight: 340)
            if let error = source.requestError { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            if busy { Text("Sent. Waiting for T3 to resolve this request…").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Button("Later") { source.dismissRequest() }
                Spacer()
                if live.kind == "auth_refresh" {
                    Button("Open T3 Code") { source.open(thread: source.session.threads[live.threadId]) }
                } else if live.kind == "user_input" {
                    Button("Send answer") { source.respond(live, selections: selections, custom: custom) }
                        .buttonStyle(.borderedProminent).disabled(busy || live.questions.isEmpty).keyboardShortcut(.defaultAction)
                } else {
                    Button("Deny") { source.respond(live, accept: false) }.disabled(busy)
                    Button("Allow") { source.respond(live, accept: true) }.buttonStyle(.borderedProminent).disabled(busy).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22).frame(width: 460)
        .background(Color(hex: "#17181B")).foregroundStyle(Color.white)
        .preferredColorScheme(.dark)
    }
}
