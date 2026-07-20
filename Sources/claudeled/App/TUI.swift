// TUI.swift -- the arrow-key picker behind `claudeled stats -i`.
//
// Deliberately small: two lists, no calendar, no text entry. Everything it can pick is
// also reachable through flags, so this is a convenience, never the only way in.

import Darwin
import Foundation

enum Term {
    /// A picker only makes sense when both ends are a terminal. Piped or redirected,
    /// the caller wants output, not a menu.
    static var interactive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    private static var saved = termios()
    private static var raw = false

    /// Leaving a terminal in raw mode costs the user their echo until they type
    /// `reset`, so restoring is wired to every way out: normal return, exit(), and
    /// the signals that a terminal actually sends.
    static func enterRaw() {
        guard !raw else { return }
        tcgetattr(STDIN_FILENO, &saved)
        var mode = saved
        mode.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &mode)
        raw = true

        atexit { Term.restore() }
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig) { _ in
                Term.restore()
                print(showCursorCode, terminator: "")
                exit(130)
            }
        }
    }

    static func restore() {
        guard raw else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        raw = false
    }
}

private let showCursorCode = "\u{1B}[?25h"

enum Key {
    case up, down, enter, quit, other
}

private func readKey() -> Key {
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return .quit }
    switch byte {
    case 0x0D, 0x0A: return .enter
    case 0x03: return .quit                        // Ctrl-C
    case 0x71, 0x51: return .quit                  // q, Q
    case 0x6B: return .up                          // k
    case 0x6A: return .down                        // j
    case 0x1B:
        // An escape on its own is "cancel"; followed by [A or [B it is an arrow.
        var rest: [UInt8] = [0, 0]
        guard read(STDIN_FILENO, &rest[0], 1) == 1, rest[0] == 0x5B,
              read(STDIN_FILENO, &rest[1], 1) == 1 else { return .quit }
        switch rest[1] {
        case 0x41: return .up
        case 0x42: return .down
        default: return .other
        }
    default: return .other
    }
}

/// Draws a list, returns the chosen index, or nil if the user backed out.
func choose(_ title: String, _ options: [String]) -> Int? {
    Term.enterRaw()
    print("\u{1B}[?25l", terminator: "")            // hide the cursor while we redraw
    defer {
        print(showCursorCode, terminator: "")
        Term.restore()
    }

    var index = 0
    var drawn = 0
    while true {
        if drawn > 0 { print("\u{1B}[\(drawn)A\u{1B}[J", terminator: "") }
        print("\(title)  ↑↓ to move, ↵ to pick, q to cancel")
        for (position, option) in options.enumerated() {
            print(position == index ? "\u{1B}[7m ▸ \(option) \u{1B}[0m" : "   \(option)")
        }
        drawn = options.count + 1
        fflush(stdout)

        switch readKey() {
        case .up:    index = (index - 1 + options.count) % options.count
        case .down:  index = (index + 1) % options.count
        case .enter: return index
        case .quit:  return nil
        case .other: break
        }
    }
}
