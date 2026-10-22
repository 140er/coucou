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
                Text("Credentials are saved in this Mac’s Keychain. Questions are answered in T3 Code.")
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project?.name ?? "T3 Code").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(source.connection).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Button { source.restart() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Reconnect")
            }
            if let project {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(source.session.sortedThreads(projectId: project.projectId)) { thread in
                            Button {
                                source.selectThread(thread.id)
                                source.open(thread: thread)
                            } label: {
                                HStack {
                                    Text(thread.title).lineLimit(1)
                                    Spacer()
                                    Text(T3StatusLabel.text(thread.status)).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.right")
                                }.font(.system(size: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if project.threadId == nil {
                    Button("No threads yet — open T3 Code") { source.open() }.buttonStyle(.plain)
                }
            } else {
                Text(source.connected ? "No projects yet. Create a project in T3 Code." : "Set the server URL and token in Settings → Agents.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 116).padding(.trailing, 16).padding(.vertical, 12)
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
                    Text(app.focusTask?.name ?? "T3 Code").font(.system(size: 12, weight: .semibold))
                    Picker("Thread", selection: Binding(get: { thread.id }, set: { source.selectThread($0) })) {
                        ForEach(source.session.sortedThreads(projectId: thread.projectId)) { row in
                            Text(row.title).tag(row.id)
                        }
                    }.labelsHidden()
                    Button { source.open(thread: thread) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain)
                }
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(source.session.messages[thread.id] ?? []) { message in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(message.role == "assistant" ? "T3 Code" : "You")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    Text(message.text).font(.system(size: 12)).textSelection(.enabled)
                                    ForEach(Array(message.files.enumerated()), id: \.offset) { _, name in
                                        Label(name, systemImage: "paperclip").font(.system(size: 11))
                                    }
                                    if message.streaming { Text("Replying…").font(.system(size: 11)).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                            }
                        }
                    }
                    .onChange(of: source.session.messages[thread.id]) { _, rows in
                        if let last = rows?.last { scroll.scrollTo(last.id, anchor: .bottom) }
                    }
                }
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
                TextEditor(text: Binding(get: { source.draftTexts[thread.id] ?? "" }, set: { source.updateDraft(thread: thread.id, text: $0) }))
                    .font(.system(size: 12)).frame(height: 44).scrollContentBackground(.hidden)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    .disabled(source.sending.contains(thread.id))
                HStack {
                    Button { source.chooseFiles() } label: { Label("Attach", systemImage: "plus") }
                    Text(T3StatusLabel.text(thread.status)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(source.sending.contains(thread.id) ? "Sending…" : "Send") { source.sendMessage() }
                        .disabled(!source.connected || source.sending.contains(thread.id) || (source.draftFiles[thread.id] ?? []).contains { $0.attachment == nil })
                }
            } else {
                Text("Select a project with an existing thread to chat. Create new threads in T3 Code.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = source.chatError { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.leading, 108).padding(.trailing, 16).padding(.vertical, 8)
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
