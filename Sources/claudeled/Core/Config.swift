// Config.swift -- the user's choices, and the rules for changing them.

import Foundation

struct Config: Codable, Equatable {
    /// Exact product names. Empty means "every keyboard that has a caps LED", so a
    /// keyboard plugged in later joins in without the user touching anything.
    var keyboards: [String] = []

    /// Gaps longer than this are treated as "you were away" and left out of the
    /// statistics. Optional rather than defaulted: a synthesised Codable throws on a
    /// missing key, and Config.load falls back to defaults on any error -- so a
    /// non-optional field would silently wipe the keyboard selection of every config
    /// written before it existed.
    var idleCapSeconds: TimeInterval?

    var idleCap: TimeInterval { idleCapSeconds ?? 300 }

    /// How long the lamp keeps blinking once a session starts waiting. Absent means
    /// forever, which is what claudeled did before this existed -- so an upgrade
    /// changes nothing until the user asks it to. Optional for the same reason as
    /// `idleCapSeconds`; see the note above.
    var blinkTimeoutSeconds: TimeInterval?

    var blinkTimeout: BlinkTimeout {
        blinkTimeoutSeconds.map(BlinkTimeout.after) ?? .forever
    }

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

// MARK: - blink timeout

/// How long to blink for. Distinct from `TimeInterval?` so that "forever" is a value
/// rather than a missing one, and a failed parse stays distinguishable from both.
enum BlinkTimeout: Equatable {
    case forever
    case after(TimeInterval)

    /// What the menu offers. The CLI accepts anything `parse` understands.
    static let presets: [BlinkTimeout] = [.after(300), .after(600), .after(1800), .forever]

    var seconds: TimeInterval? {
        if case .after(let seconds) = self { return seconds }
        return nil
    }

    /// `5m`, `90s`, `1h`, `always`. A bare number is seconds, which is what the config
    /// file holds, so a value read back from it round trips through the CLI.
    static func parse(_ raw: String) -> BlinkTimeout? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if ["always", "forever", "off", "never", "none", "0"].contains(text) { return .forever }

        let unit = text.last.map(String.init) ?? ""
        let multiplier: TimeInterval
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        default:  multiplier = 1   // bare number: seconds
        }
        let number = "smh".contains(unit) ? String(text.dropLast()) : text
        guard let value = Double(number), value > 0, value.isFinite else { return nil }
        return .after(value * multiplier)
    }

    var label: String {
        guard case .after(let seconds) = self else { return "Always" }
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            return "\(Int(seconds) / 3600)h"
        }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(seconds) / 60) min"
        }
        return "\(Int(seconds.rounded()))s"
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
