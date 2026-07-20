// HookInstall.swift -- reading and writing the user's ~/.claude/settings.json.
// The merge itself lives in Core/HookPlan.swift, where it can be tested.

import Foundation

enum Hooks {
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// Absolute path into the bundle. Bare `claudeled` would depend on whatever PATH
    /// Claude Code happens to run hooks with, which is not ours to assume.
    static var executable: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }

    /// One-time backup, so a bad merge is always recoverable.
    private static func backupOnce() {
        let backup = settingsURL.appendingPathExtension("claudeled-backup")
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }

    static var installed: Bool { HookPlan.installed(in: load(), executable: executable) }

    static func install() throws {
        backupOnce()
        try write(HookPlan.install(into: load(), executable: executable))
    }

    static func remove() throws {
        try write(HookPlan.remove(from: load()))
    }
}
