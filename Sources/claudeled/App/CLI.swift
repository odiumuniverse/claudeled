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
