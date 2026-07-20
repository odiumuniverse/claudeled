// claudeled -- Caps Lock LED indicator for Claude Code.
//
// Blinks the Caps Lock LED while a Claude Code session needs you. Drives the HID caps
// LED element directly (IOHIDDeviceSetValue), so the Caps Lock *modifier* is never
// asserted and typing case is unaffected. Verified on Apple Internal Keyboard (SPI)
// and Magic Keyboard (Bluetooth), with and without a Caps->Ctrl remap.
//
// One binary, two faces:
//   no arguments  -> menu bar app (LSUIElement), owns the LEDs
//   arguments     -> CLI, used by Claude Code hooks and by you
//
// Core/ holds everything that can be reasoned about without a keyboard or a screen,
// and is the only part the tests compile against. App/ is the AppKit and IOKit shell.

import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    app.run()
case "show":
    DistributedNotificationCenter.default()
        .postNotificationName(Notification.Name(showNotification), object: nil,
                              userInfo: nil, deliverImmediately: true)
case "devices": cliDevices(namesOnly: arguments.contains("--names"))
case "test":    cliTest(arguments.count > 1 ? arguments[1] : "")
case "status":  cliStatus()
case "stats":   cliStats(Array(arguments.dropFirst()))
case "hooks":   print(hookConfig)
case "hook":    cliHook(arguments.count > 1 ? arguments[1] : "")
case "-h", "--help", "help": print(usage)
default:
    print("unknown command: \(arguments[0])\n")
    print(usage)
    exit(2)
}
