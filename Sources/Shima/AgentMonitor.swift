import AppKit
import Observation

/// A coding agent session (Claude Code, Codex) as the notch shows it.
struct AgentSession: Equatable, Identifiable {
    enum State: Equatable { case working, needsYou, done }

    let id: String
    let agent: String
    /// The project's folder name.
    var project: String
    var state: State
    /// What it's asking for, when it needs you.
    var message: String?
    /// When the current turn started, for the elapsed time.
    var since: Date
    var lastEvent: Date
    /// The app it runs in (a terminal, an editor), to bring to the front when clicked.
    var hostApp: String?

    var agentName: String { agent == "codex" ? "Codex" : "Claude" }
}

/// Coding agents working in the background. Claude Code and Codex call Shima's own executable from a
/// hook (`Shima --agent-hook <agent>`) when a turn starts, a tool finishes, it needs permission, or it's
/// done; that call hands the news to the running Shima and exits. Nothing polls, and nothing leaves the
/// Mac. The hooks are only added when you press Connect in Settings.
@Observable
final class AgentMonitor {
    static let shared = AgentMonitor()
    static let notificationName = Notification.Name("io.github.vendavalsc.shima.agent")
    /// "Done" shows this long.
    static let doneDuration: TimeInterval = 4
    /// A session that's said nothing for this long has probably been closed.
    static let staleAfter: TimeInterval = 20 * 60

    private(set) var sessions: [AgentSession] = []

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var cleanup: Timer?

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.notificationName, object: nil,
                                                                       queue: .main) { [weak self] note in
            self?.received(note.userInfo as? [String: String] ?? [:])
        }
    }

    // MARK: What the notch shows

    /// Sessions working right now.
    var working: [AgentSession] { sessions.filter { $0.state == .working } }
    /// The one to show as an alert: one that needs you, else one that just finished.
    var alert: AgentSession? {
        sessions.first { $0.state == .needsYou } ?? sessions.first { $0.state == .done }
    }

    /// Brings the app the session runs in to the front, and lets a finished one go.
    func open(_ session: AgentSession) {
        if let host = session.hostApp, let app = NSRunningApplication.runningApplications(withBundleIdentifier: host).first {
            app.activate()
        }
        if session.state == .done { sessions.removeAll { $0.id == session.id } }
    }

    // MARK: Events

    private func received(_ info: [String: String]) {
        guard AppSettings.shared.agentActivity, let id = info["session"], let event = info["event"] else { return }
        let agent = info["agent"] ?? "claude"
        let project = info["cwd"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? agent
        let now = Date()
        var session = sessions.first { $0.id == id }
            ?? AgentSession(id: id, agent: agent, project: project, state: .working, since: now, lastEvent: now,
                            hostApp: info["host"])
        session.lastEvent = now
        if let host = info["host"], !host.isEmpty { session.hostApp = host }

        switch event {
        case "UserPromptSubmit":
            session.state = .working
            session.since = now
            session.message = nil
        case "PostToolUse", "PreToolUse":
            if session.state != .working { session.state = .working; session.message = nil }
        case "Notification":
            // Permission requests, not the reminder that it's been waiting a while after finishing.
            let kind = info["kind"] ?? ""
            let message = info["message"] ?? ""
            guard kind != "idle_prompt", !message.localizedCaseInsensitiveContains("waiting for your input") else { return }
            session.state = .needsYou
            session.message = message
        case "Stop", "agent-turn-complete":
            session.state = .done
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doneDuration) { [weak self] in
                guard let self, let current = self.sessions.first(where: { $0.id == id }), current.state == .done,
                      current.lastEvent == now else { return }
                self.sessions.removeAll { $0.id == id }
            }
        case "SessionEnd":
            sessions.removeAll { $0.id == id }
            return
        default:
            return
        }
        Log.activity.info("agent \(agent, privacy: .public): \(event, privacy: .public)")
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = session } else { sessions.append(session) }
        scheduleCleanup()
    }

    /// Forgets sessions that went quiet (the terminal was closed mid-turn).
    private func scheduleCleanup() {
        cleanup?.invalidate()
        guard let oldest = sessions.map(\.lastEvent).min() else { return }
        let timer = Timer(fire: oldest.addingTimeInterval(Self.staleAfter + 1), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.sessions.removeAll { Date().timeIntervalSince($0.lastEvent) > Self.staleAfter }
            self.scheduleCleanup()
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        cleanup = timer
    }

    /// Fills in sessions, for snapshots.
    func loadSample(_ sessions: [AgentSession]) { self.sessions = sessions }
}

// MARK: The hook

/// Run as `Shima --agent-hook <agent>` by Claude Code (the event as JSON on standard input) or Codex
/// (as JSON in the last argument): tells the running Shima, then exits straight away.
enum AgentHook {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[1] == "--agent-hook" else { return false }
        let agent = arguments[2]
        let data: Data
        if arguments.count >= 4 {
            data = Data(arguments[3].utf8)
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var info: [String: String] = ["agent": agent]
        info["event"] = json["hook_event_name"] as? String ?? json["type"] as? String
        info["session"] = json["session_id"] as? String ?? json["thread-id"] as? String ?? json["turn-id"] as? String
        info["cwd"] = json["cwd"] as? String ?? ProcessInfo.processInfo.environment["PWD"]
        info["message"] = json["message"] as? String
        info["kind"] = json["notification_type"] as? String
        // The app the agent runs in, which macOS passes down to everything started from it.
        info["host"] = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        if info["session"] == nil { info["session"] = info["cwd"] ?? agent }
        DistributedNotificationCenter.default().postNotificationName(AgentMonitor.notificationName, object: nil,
                                                                     userInfo: info, deliverImmediately: true)
        return true
    }
}

// MARK: Connecting

/// Adds Shima's hook to Claude Code's settings (~/.claude/settings.json) and Codex's
/// (~/.codex/config.toml), or takes it out again. Everything else in those files is kept.
enum AgentConnection {
    static let claudeEvents = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    private static let marker = "--agent-hook"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    static var hasClaude: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) }
    static var hasCodex: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) }

    /// The command the agents run: this copy of Shima, quietly doing nothing if it's been moved.
    private static func command(for agent: String) -> String {
        let path = Bundle.main.executablePath ?? "/Applications/Shima.app/Contents/MacOS/Shima"
        return "'\(path)' \(marker) \(agent) 2>/dev/null || true"
    }

    static var isClaudeConnected: Bool {
        (try? String(contentsOf: claudeSettings, encoding: .utf8))?.contains("\(marker) claude") ?? false
    }

    static var isCodexConnected: Bool {
        (try? String(contentsOf: codexConfig, encoding: .utf8))?.contains(marker) ?? false
    }

    static func setClaude(connected: Bool) throws {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeSettings), !data.isEmpty {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            settings = existing
            backUp(claudeSettings)
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            // Shima's own entries out, everything else kept.
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var group = group
                let commands = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    !(($0["command"] as? String)?.contains(marker) ?? false)
                }
                guard !commands.isEmpty else { return nil }
                group["hooks"] = commands
                return group
            }
            if connected {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command(for: "claude"), "timeout": 5]]]
                if event == "PostToolUse" { group["matcher"] = "*" }
                groups.append(group)
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: claudeSettings, options: .atomic)
        Log.activity.info("agents: claude \(connected ? "connected" : "disconnected", privacy: .public)")
    }

    /// Codex runs one program when a turn finishes, set by a top-level `notify` line.
    static func setCodex(connected: Bool) throws {
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if !text.isEmpty { backUp(codexConfig) }
        var lines = text.components(separatedBy: "\n").filter { !$0.contains(marker) }
        if connected {
            guard !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                    "Codex already runs another program when it finishes (the notify setting in ~/.codex/config.toml)."])
            }
            let path = Bundle.main.executablePath ?? "/Applications/Shima.app/Contents/MacOS/Shima"
            // Top-level keys must come before any [table] in TOML.
            lines.insert("notify = [\"\(path)\", \"\(marker)\", \"codex\"]", at: 0)
        }
        text = lines.joined(separator: "\n")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
        Log.activity.info("agents: codex \(connected ? "connected" : "disconnected", privacy: .public)")
    }

    /// The file as it was before Shima first touched it, once.
    private static func backUp(_ url: URL) {
        let backup = url.appendingPathExtension("before-shima")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }
}
