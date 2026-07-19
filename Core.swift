// Core.swift -- everything that can be reasoned about without a keyboard or a screen.
// Kept free of AppKit and IOKit so tests.swift can compile against it directly.

import Foundation

// MARK: - paths
//
// Overridable so tests can run against a scratch directory instead of the real config.

var configRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/claudeled", isDirectory: true)

var sessionsDir: URL { configRoot.appendingPathComponent("sessions", isDirectory: true) }
var configFile: URL { configRoot.appendingPathComponent("config.json") }

/// Backstop for sessions we could not tie to a process. The pid check does the real work.
let staleTTL: TimeInterval = 12 * 3600

func ensureDirs() {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
}

// MARK: - model

/// What a hook last told us about a session.
enum SessionEvent: String {
    case prompt   // work handed to Claude, or a tool just ran
    case stop     // Claude finished its turn, the ball is yours
    case notify   // Claude is blocked on a permission prompt
}

/// Events that mean "Claude needs you". `prompt` is the absence of them: work is in
/// flight, so the light stays dark.
let blinkingEvents: Set<SessionEvent> = [.stop, .notify]

/// Milliseconds, alternating on/off starting with on: a double pulse, mostly dark.
let blinkPattern = [120, 120, 120, 900]

struct Config: Codable, Equatable {
    /// Exact product names. Empty means "every keyboard that has a caps LED", so a
    /// keyboard plugged in later joins in without the user touching anything.
    var keyboards: [String] = []

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configFile),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    func save() {
        ensureDirs()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: configFile)
    }

    func selects(_ name: String) -> Bool {
        keyboards.isEmpty || keyboards.contains(name)
    }
}

// MARK: - keyboard selection

enum Selection {
    /// Ticking and unticking keyboards in the menu.
    ///
    /// `current` is what the config holds, where empty means "all". The result uses the
    /// same convention, so selecting everything collapses back to empty and newly
    /// attached keyboards are included by default.
    ///
    /// Unticking the last keyboard would mean "light nothing", which is
    /// indistinguishable from "all" in the stored form and leaves the user with a menu
    /// full of ticks and a dead light. Refuse it: the last one stays on.
    static func toggle(_ name: String, current: [String], drivable: [String]) -> [String] {
        guard drivable.contains(name) else { return current }
        var selected = current.isEmpty ? drivable : current.filter { drivable.contains($0) }

        if selected.contains(name) {
            guard selected.count > 1 else { return current }
            selected.removeAll { $0 == name }
        } else {
            selected.append(name)
        }
        return Set(selected) == Set(drivable) ? [] : selected
    }
}

// MARK: - sessions

struct Session: Equatable {
    let id: String
    let pid: pid_t
    let event: SessionEvent
    let at: Date

    static func == (a: Session, b: Session) -> Bool { a.id == b.id && a.event == b.event }
}

func readSessions() -> [Session] {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }
    return files.compactMap { url in
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 3,
              let pid = pid_t(lines[0]),
              let stamp = TimeInterval(lines[1]),
              let event = SessionEvent(rawValue: lines[2]) else { return nil }
        return Session(id: url.lastPathComponent, pid: pid, event: event,
                       at: Date(timeIntervalSince1970: stamp))
    }
}

func isAlive(_ pid: pid_t) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
}

/// A session is stale when its process is gone, or when it outlived the TTL. This is
/// what stops a kill -9'd terminal from blinking forever.
func isStale(_ session: Session, now: Date = Date(),
             alive: (pid_t) -> Bool = isAlive) -> Bool {
    if session.pid != 0 && !alive(session.pid) { return true }
    return now.timeIntervalSince(session.at) > staleTTL
}

func pruneSessions() {
    for session in readSessions() where isStale(session) {
        try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent(session.id))
    }
}

func record(session: String, event: SessionEvent, pid: pid_t) {
    ensureDirs()
    let body = "\(pid)\n\(Date().timeIntervalSince1970)\n\(event.rawValue)\n"
    try? body.write(to: sessionsDir.appendingPathComponent(session),
                    atomically: true, encoding: .utf8)
}

func forget(_ session: String) {
    try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent(session))
}

/// session_id ends up as a filename.
func safeSessionID(_ raw: String) -> String {
    raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
}

/// Aggregation across windows is OR: any session needing you lights the lamp.
func shouldBlink(sessions: [Session]) -> Bool {
    sessions.contains { blinkingEvents.contains($0.event) }
}

// MARK: - hook merging
//
// settings.json belongs to the user and usually holds unrelated hooks, so every write
// is a merge. Pure functions over the parsed JSON, so the merge is testable without
// touching the real file.

enum HookPlan {
    /// Claude Code event -> argument passed to `claudeled hook`.
    static let events: [(claudeEvent: String, argument: String)] = [
        ("UserPromptSubmit", "prompt"),
        ("Stop", "stop"),
        ("Notification", "notify"),
        // A tool ran, so whatever the notification was blocking on is resolved. Without
        // this the light keeps blinking after you approve a permission prompt, right
        // up until your next message.
        ("PostToolUse", "prompt"),
        ("SessionEnd", "end"),
        // SubagentStop is deliberately absent: it is what keeps subagents from blinking
        // the light on behalf of the main agent.
    ]

    static func command(executable: String, argument: String) -> String {
        "\"\(executable)\" hook \(argument)"
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return command.contains("claudeled")
    }

    /// Strips our entries from one event's groups, dropping groups left empty.
    private static func stripped(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard var entries = group["hooks"] as? [[String: Any]] else { return group }
            entries.removeAll(where: isOurs)
            if entries.isEmpty { return nil }
            var updated = group
            updated["hooks"] = entries
            return updated
        }
    }

    static func install(into settings: [String: Any], executable: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            // Strip first: the bundle may have moved since last time, and we must not
            // leave a second entry pointing at the old path.
            var groups = stripped(hooks[event.claudeEvent] as? [[String: Any]] ?? [])
            groups.append(["hooks": [["type": "command",
                                      "command": command(executable: executable,
                                                         argument: event.argument)]]])
            hooks[event.claudeEvent] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    static func remove(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for event in events {
            guard let groups = hooks[event.claudeEvent] as? [[String: Any]] else { continue }
            let remaining = stripped(groups)
            if remaining.isEmpty { hooks.removeValue(forKey: event.claudeEvent) }
            else { hooks[event.claudeEvent] = remaining }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        return settings
    }

    static func installed(in settings: [String: Any], executable: String) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            guard let groups = hooks[event.claudeEvent] as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String)?.contains(executable) == true }
            }
        }
    }
}
