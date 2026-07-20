// CLI.swift -- the face claudeled shows when it is given arguments.

import Foundation
import IOKit
import IOKit.hid

func cliDevices(namesOnly: Bool) {
    let config = Config.load()
    let keyboards = HID.enumerate()
    if namesOnly {
        // Consumed by shell completion: one name per line, nothing else.
        for keyboard in keyboards where keyboard.drivable { print(keyboard.name) }
        return
    }
    guard !keyboards.isEmpty else { print("no keyboards found"); return }
    print(config.keyboards.isEmpty
          ? "blinking on: all keyboards"
          : "blinking on: \(config.keyboards.joined(separator: ", "))")
    print("")
    for keyboard in keyboards {
        let mark = keyboard.drivable ? (config.selects(keyboard.name) ? "[x]" : "[ ]") : "[-]"
        print("\(mark) \(keyboard.name)")
        print("    vid=\(keyboard.vendor) pid=\(keyboard.product) " +
              "transport=\(keyboard.transport) capsLED=\(keyboard.drivable ? "yes" : "no")")
    }
}

func cliTest(_ query: String) {
    let matches = HID.enumerate().filter {
        query.isEmpty || $0.name.lowercased().contains(query.lowercased())
    }
    guard !matches.isEmpty else {
        print("no keyboard matching '\(query)'")
        exit(1)
    }
    for keyboard in matches {
        guard let element = keyboard.element else {
            print("\(keyboard.name): no caps LED, cannot be driven")
            continue
        }
        guard IOHIDDeviceOpen(keyboard.device, 0) == kIOReturnSuccess else {
            print("\(keyboard.name): open failed")
            continue
        }
        print("\(keyboard.name): LED on for 3s, watch it")
        // Re-assert: a single write fades on some Bluetooth keyboards.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            IOHIDDeviceSetValue(keyboard.device, element,
                IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 1))
            Thread.sleep(forTimeInterval: 0.05)
        }
        IOHIDDeviceSetValue(keyboard.device, element,
            IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0))
        IOHIDDeviceClose(keyboard.device, 0)
    }
}

func cliStatus() {
    let sessions = readSessions()
    guard !sessions.isEmpty else { print("no sessions tracked"); return }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    for session in sessions.sorted(by: { $0.at < $1.at }) {
        let blinking = blinkingEvents.contains(session.event) ? "BLINKING" : "quiet"
        let process = session.pid == 0
            ? "pid unknown"
            : (isAlive(session.pid) ? "pid \(session.pid)" : "pid \(session.pid) DEAD")
        print("\(session.id)  \(session.event.rawValue)  " +
              "\(formatter.string(from: session.at))  \(process)  \(blinking)")
    }
}

/// `claudeled blink` reports, `claudeled blink <value>` sets. The running app picks the
/// change up within a second; nothing needs restarting.
func cliBlink(_ argument: String?) {
    var config = Config.load()

    guard let argument, !argument.isEmpty else {
        switch config.blinkTimeout {
        case .forever:
            print("blinking until answered")
        case .after(let seconds):
            print("blinking for \(config.blinkTimeout.label) (\(Int(seconds))s), "
                  + "then dark until the next event")
        }
        return
    }

    guard let timeout = BlinkTimeout.parse(argument) else {
        print("cannot read '\(argument)' as a duration; try 5m, 30m, 90s, 1h or always")
        exit(2)
    }

    config.blinkTimeoutSeconds = timeout.seconds
    config.save()
    print(timeout == .forever
          ? "blinking until answered"
          : "blinking for \(timeout.label) after a session starts waiting")
}

// MARK: - stats

/// Where a card goes when the picker writes one, and when `--card` is given no path.
private func defaultCardPath(_ period: Period) -> URL {
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withFullDate]
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/claudeled-\(period.rawValue)-"
                                + "\(stamp.string(from: Date())).png")
}

private func writeCard(_ report: Report, period: Period, cap: TimeInterval, to url: URL) {
    guard let png = Card.png(report, label: period.label, cap: cap) else {
        print("could not render the card")
        exit(1)
    }
    do {
        try png.write(to: url)
        print("wrote \(url.path)")
    } catch {
        print("could not write \(url.path): \(error.localizedDescription)")
        exit(1)
    }
}

private func copyToClipboard(_ text: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let pipe = Pipe()
    task.standardInput = pipe
    guard (try? task.run()) != nil else { print(text); return }
    pipe.fileHandleForWriting.write(Data(text.utf8))
    try? pipe.fileHandleForWriting.close()
    task.waitUntilExit()
}

func cliStats(_ arguments: [String]) {
    let cap = Config.load().idleCap
    let now = Date()

    if arguments.contains("-i") || arguments.contains("--pick") {
        statsPicker(cap: cap, now: now)
        return
    }

    let period = arguments.compactMap(Period.init(rawValue:)).first
    let card = arguments.contains("--card")
    let json = arguments.contains("--json")
    let markdown = arguments.contains("--md")

    // Bare `claudeled stats` is the two-window view; anything else is one window.
    guard period != nil || card || json || markdown else {
        print(statsText(now: now, cap: cap))
        return
    }

    let chosen = period ?? .week
    let report = chosen.report(now: now, cap: cap)

    if card {
        let explicit = arguments.drop { $0 != "--card" }.dropFirst().first
        let url = explicit.map { URL(fileURLWithPath: $0) } ?? defaultCardPath(chosen)
        writeCard(report, period: chosen, cap: cap, to: url)
    } else if json {
        print(renderJSON(report, period: chosen, now: now, cap: cap))
    } else if markdown {
        print(renderMarkdown(report, label: chosen.label, cap: cap))
    } else {
        print(renderText([Summary(label: chosen.label, report: report)],
                         projects: report, cap: cap))
    }
}

/// Two lists: what to report on, and where to send it. The format follows from the
/// destination -- markdown is for pasting, a PNG is for sharing, a table is for looking
/// at now.
private func statsPicker(cap: TimeInterval, now: Date) {
    guard Term.interactive else {
        print(statsText(now: now, cap: cap))
        return
    }
    guard let periodIndex = choose("Period", Period.allCases.map(\.label)) else { return }
    let period = Period.allCases[periodIndex]

    guard let destination = choose("Send to",
                                   ["show it here", "copy as markdown", "save a PNG card"])
    else { return }

    let report = period.report(now: now, cap: cap)
    switch destination {
    case 0:
        print(renderText([Summary(label: period.label, report: report)],
                         projects: report, cap: cap))
    case 1:
        copyToClipboard(renderMarkdown(report, label: period.label, cap: cap))
        print("copied \(period.label) to the clipboard")
    default:
        writeCard(report, period: period, cap: cap, to: defaultCardPath(period))
    }
}

/// Hooks pipe their JSON on stdin. Never fail loudly: a broken hook must not break Claude.
func cliHook(_ eventName: String) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = json["session_id"] as? String, !raw.isEmpty else { exit(0) }
    let session = safeSessionID(raw)
    if eventName == "end" {
        forget(session)
    } else if let event = SessionEvent(rawValue: eventName) {
        record(session: session, event: event, pid: claudeAncestor())
        logEvent(session: session, event: event,
                 project: projectName(cwd: json["cwd"] as? String))
    }
    exit(0)
}

let usage = """
claudeled -- Caps Lock LED indicator for Claude Code

  claudeled                    run the menu bar app
  claudeled devices            list keyboards and which ones blink
  claudeled devices --names    names only, for shell completion
  claudeled test <keyboard>    light a keyboard for 3s
  claudeled status             show tracked sessions
  claudeled blink              show how long the lamp blinks for
  claudeled blink <duration>   5m | 30m | 90s | 1h | always
  claudeled stats              time spent, today and over the last 7 days
  claudeled stats <period>     week | month | year | all
  claudeled stats -i           pick a period and a destination with the arrow keys
  claudeled stats … --json     the same numbers, for scripts
  claudeled stats … --md       a markdown table, for pasting
  claudeled stats … --card [f] a PNG card, for sharing
  claudeled show               bring the menu bar icon back after hiding it
  claudeled hooks              print the hook config, to install it by hand
  claudeled hook <event>       internal: called by the hooks themselves

config: ~/.config/claudeled/config.json
"""

var hookConfig: String {
    let lines = HookPlan.events.map { event in
        "    \"\(event.claudeEvent)\": [{\"hooks\": [{\"type\": \"command\", " +
        "\"command\": \"\(HookPlan.command(executable: Hooks.executable, argument: event.argument))\"}]}]"
    }
    return """
    Merge into ~/.claude/settings.json:

    {
      "hooks": {
    \(lines.joined(separator: ",\n"))
      }
    }

    SubagentStop is deliberately absent: it is what keeps subagents from
    blinking the light on behalf of the main agent.
    """
}
