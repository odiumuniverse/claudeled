// Paths.swift -- where claudeled keeps its state, and how it reports on itself.

import Foundation

/// Overridable so tests can run against a scratch directory instead of the real config.
var configRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/claudeled", isDirectory: true)

var sessionsDir: URL { configRoot.appendingPathComponent("sessions", isDirectory: true) }
var configFile: URL { configRoot.appendingPathComponent("config.json") }

func ensureDirs() {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
}

/// Appends a line to ~/.config/claudeled/diagnostics.log. Permission problems are
/// invisible from outside the app, so it keeps its own account of what it can see.
func diagnose(_ message: String) {
    ensureDirs()
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp)  \(message)\n"
    let url = configRoot.appendingPathComponent("diagnostics.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
