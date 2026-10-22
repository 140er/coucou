import SwiftUI

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
                Text("Connect a T3 Code server, then enable its pill in Active pills.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Server URL (http://host:3773)", text: $url)
                    .textContentType(.URL)
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

// Uses the existing island card surface and typography; the list scrolls inside the card.
struct T3CodeCardView: View {
    @ObservedObject private var source = T3CodeSource.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("T3 Code").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(source.connection).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Button { source.restart() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Reconnect")
                Button { source.open() } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain).help("Open T3 Code")
            }
            if source.connected {
                if source.session.sortedProjects.isEmpty {
                    Text("No active threads.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(source.session.sortedProjects) { project in
                                Text(project.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                ForEach(source.session.sortedThreads(projectId: project.id)) { thread in
                                    Button { source.open(thread: thread) } label: {
                                        HStack(spacing: 8) {
                                            Text(thread.title).lineLimit(1)
                                            Spacer(minLength: 4)
                                            Text(label(thread.status)).foregroundStyle(color(thread.status))
                                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                                        }.font(.system(size: 12)).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(thread.status == .question ? "Answer in T3 Code" : thread.title)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Set the server URL and token in Settings → Agents.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 116).padding(.trailing, 16).padding(.vertical, 12)
    }
    private func label(_ status: T3Status) -> String {
        switch status {
        case .approval: String(localized: "Waiting for approval")
        case .question: String(localized: "Answer in T3 Code")
        case .error: String(localized: "Error")
        case .running: String(localized: "Running")
        case .done: String(localized: "Done")
        case .idle: String(localized: "Idle")
        }
    }
    private func color(_ status: T3Status) -> Color {
        switch status {
        case .approval, .question: .orange
        case .error: .red
        default: .secondary
        }
    }
}
