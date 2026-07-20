// HookPlan.swift -- merging our hooks into the user's settings.json.
//
// settings.json belongs to the user and usually holds unrelated hooks, so every write
// is a merge. Pure functions over the parsed JSON, so the merge is testable without
// touching the real file.

import Foundation

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
