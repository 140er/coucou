#if !APPSTORE
import Foundation

// GitHub build only (#if !APPSTORE): the App Store build is sandboxed and may not run
// another program. Starts the GOWA binary the user picked as a child of Coucou, on the
// address set in Settings, and stops it when Coucou quits.

/// GOWA launched by Coucou ("Start GOWA automatically" in Settings).
@MainActor
final class WhatsAppGOWAProcess {
    static let shared = WhatsAppGOWAProcess()

    private var process: Process?
    private var lastStart: Date = .distantPast

    static var autoStart: Bool {
        get { UserDefaults.standard.bool(forKey: "whatsappAutoStartGOWA") }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappAutoStartGOWA") }
    }

    /// The binary's path (not a secret: UserDefaults).
    static var binaryPath: String {
        get { UserDefaults.standard.string(forKey: "whatsappGOWAPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappGOWAPath") }
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Where GOWA keeps its own WhatsApp session (its database, not Coucou's): one folder in
    /// Application Support, so the link survives restarts.
    static var workingDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coucou/GOWA", isDirectory: true)
    }

    /// Starts GOWA unless it already runs (or was started less than a minute ago).
    /// Returns false when the binary can't be run.
    @discardableResult
    func startIfNeeded() -> Bool {
        guard Self.autoStart, WhatsAppSettings.gateway == .gowa else { return false }
        if isRunning { return true }
        guard Date().timeIntervalSince(lastStart) > 60 else { return true }
        let path = (Self.binaryPath as NSString).expandingTildeInPath
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path),
              let url = URL(string: WhatsAppSettings.url) else {
            appendAppLog("nb.log", "[WhatsApp] GOWA binary missing or not executable")
            return false
        }
        // Only ever on this Mac: an address elsewhere is someone else's gateway.
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { return false }
        try? FileManager.default.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = WAGOWA.launchArguments(for: url)
        p.currentDirectoryURL = Self.workingDirectory
        var env = ProcessInfo.processInfo.environment
        // The credential goes through the environment, not the command line (`ps` shows that).
        if let auth = KeychainStore.shared.get(WhatsAppSettings.credentialKey), auth.contains(":") {
            env["APP_BASIC_AUTH"] = auth
        }
        p.environment = env
        // GOWA's own output may name contacts or quote messages: it goes nowhere.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                appendAppLog("nb.log", "[WhatsApp] GOWA exited (\(status))")
            }
        }
        do {
            try p.run()
            process = p
            lastStart = Date()
            appendAppLog("nb.log", "[WhatsApp] GOWA started (pid \(p.processIdentifier))")
            return true
        } catch {
            appendAppLog("nb.log", "[WhatsApp] GOWA could not start: \(error.localizedDescription)")
            return false
        }
    }

    /// Stops GOWA if Coucou started it (Coucou quits, the option or WhatsApp is turned off).
    func stop() {
        lastStart = .distantPast
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        p.terminate()
        // Still there after 2 s: killed.
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// At quit: the gateway can't outlive Coucou, and there is no time to wait.
    func stopNow() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(1)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
    }
}
#endif
