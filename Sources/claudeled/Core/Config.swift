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
