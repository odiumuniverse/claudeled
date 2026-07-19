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
// The logic worth testing lives in Core.swift; this file is the AppKit and IOKit shell.

import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.hid
import ServiceManagement

let githubURL = "https://github.com/odiumuniverse/claudeled"
let showNotification = "com.odiumuniverse.claudeled.show"

// MARK: - finding the session that owns a hook

func parentOf(_ pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Executable path, not `p_comm`: Claude Code rewrites its process title to its version
/// number ("2.1.215"), so the short name tells you nothing. The path stays honest.
func executablePath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return written > 0 ? String(cString: buffer) : ""
}

private let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]

/// A hook runs as a short-lived child, usually under a shell, so getppid() dies at once
/// and would prune the session immediately. Walk up to the Claude Code process instead.
/// Returns 0 when it cannot be identified: that means "TTL only, no pid check".
func claudeAncestor() -> pid_t {
    var pid = getppid()
    var firstNonShell: pid_t = 0

    for _ in 0..<8 {
        guard let parent = parentOf(pid) else { break }
        let path = executablePath(pid)
        let name = (path as NSString).lastPathComponent

        // A native install lives under .../claude/versions/<version>, so the directory
        // carries the name even though the executable is named after the version.
        if path.split(separator: "/").contains("claude") || name.lowercased().hasPrefix("claude") {
            return pid
        }
        // Fallback for installs launched through node: the first ancestor that is not a
        // shell is whatever spawned the hook, which is Claude Code.
        if firstNonShell == 0, !shellNames.contains(name), !name.isEmpty {
            firstNonShell = pid
        }
        if parent <= 1 { break }
        pid = parent
    }
    return firstNonShell
}

// MARK: - Input Monitoring
//
// macOS gates IOHIDDeviceOpen and element enumeration on keyboards behind Input
// Monitoring, whether you intend to read keystrokes or only write to an LED. Without
// it the caps LED element is invisible, which looks exactly like a keyboard that has
// no LED at all -- so check explicitly and say so, rather than lying in the menu.
//
// The CLI usually works without it because it inherits the terminal's grant. The app
// is its own subject and needs its own.

enum InputMonitoring {
    static var granted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt, once per app identity.
    static func request() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static var description: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown (never asked)"
        }
    }

    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - settings.json

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

// MARK: - HID

struct KeyboardInfo {
    let device: IOHIDDevice
    let element: IOHIDElement?
    let name: String
    let vendor: Int
    let product: Int
    let transport: String
    var drivable: Bool { element != nil }
}

enum HID {
    static func capsElement(_ device: IOHIDDevice) -> IOHIDElement? {
        let elements = (IOHIDDeviceCopyMatchingElements(
            device, [kIOHIDElementUsagePageKey: Int(kHIDPage_LEDs)] as CFDictionary, 0)
            as? [IOHIDElement]) ?? []
        return elements.first { IOHIDElementGetUsage($0) == UInt32(kHIDUsage_LED_CapsLock) }
    }

    static func describe(_ device: IOHIDDevice) -> KeyboardInfo {
        func property<T>(_ key: String) -> T? {
            IOHIDDeviceGetProperty(device, key as CFString) as? T
        }
        return KeyboardInfo(
            device: device,
            element: capsElement(device),
            name: property(kIOHIDProductKey) ?? "Unknown keyboard",
            vendor: property(kIOHIDVendorIDKey) ?? -1,
            product: property(kIOHIDProductIDKey) ?? -1,
            transport: property(kIOHIDTransportKey) ?? "?")
    }

    static var keyboardMatch: CFArray {
        [[kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
          kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]] as CFArray
    }

    /// One-shot enumeration, for the CLI.
    static func enumerate() -> [KeyboardInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, keyboardMatch)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return devices.map(describe).sorted { $0.name < $1.name }
    }
}

/// Live registry driven by IOHIDManager callbacks, so sleep, Bluetooth reconnects and
/// receiver unplugs are handled without polling.
final class KeyboardRegistry {
    private let lock = NSLock()
    private var open: [(device: IOHIDDevice, element: IOHIDElement)] = []
    private var known: [IOHIDDevice] = []
    private var manager: IOHIDManager?

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, HID.keyboardMatch)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KeyboardRegistry>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KeyboardRegistry>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func attach(_ device: IOHIDDevice) {
        lock.lock()
        if !known.contains(device) { known.append(device) }
        lock.unlock()
        reopen()
    }

    private func detach(_ device: IOHIDDevice) {
        lock.lock()
        known.removeAll { $0 == device }
        open.removeAll { $0.device == device }
        lock.unlock()
    }

    /// Also called when the selection changes, so ticking a keyboard takes effect at once.
    func reopen() {
        let config = Config.load()
        lock.lock()
        for entry in open {
            write(entry, on: false)
            IOHIDDeviceClose(entry.device, 0)
        }
        open.removeAll()
        for device in known {
            let info = HID.describe(device)
            guard let element = info.element, config.selects(info.name),
                  IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { continue }
            open.append((device, element))
        }
        lock.unlock()
    }

    private func write(_ entry: (device: IOHIDDevice, element: IOHIDElement), on: Bool) {
        let value = IOHIDValueCreateWithIntegerValue(
            kCFAllocatorDefault, entry.element, 0, on ? 1 : 0)
        IOHIDDeviceSetValue(entry.device, entry.element, value)
    }

    func set(_ on: Bool) {
        lock.lock()
        let snapshot = open
        lock.unlock()
        for entry in snapshot { write(entry, on: on) }
    }

    /// Every keyboard seen so far, selected or not. The menu lists these.
    func inventory() -> [KeyboardInfo] {
        lock.lock()
        let devices = known
        lock.unlock()
        return devices.map(HID.describe).sorted { $0.name < $1.name }
    }
}

// MARK: - blinker

final class Blinker {
    private let registry: KeyboardRegistry
    private let queue = DispatchQueue(label: "claudeled.blink")
    private var running = true

    init(registry: KeyboardRegistry) { self.registry = registry }

    func stop() {
        running = false
        registry.set(false)
    }

    func start() {
        queue.async { [self] in
            var lastPrune = Date.distantPast
            while running {
                if Date().timeIntervalSince(lastPrune) > 1 {
                    pruneSessions()
                    lastPrune = Date()
                }
                guard shouldBlink(sessions: readSessions()) else {
                    registry.set(false)
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }
                for (index, milliseconds) in blinkPattern.enumerated() {
                    guard running else { break }
                    registry.set(index % 2 == 0)
                    Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
                }
                registry.set(false)
            }
        }
    }
}

// MARK: - menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let registry = KeyboardRegistry()
    private var blinker: Blinker!
    private var accessAtLaunch = InputMonitoring.granted
    private var relaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDirs()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capslock",
                                           accessibilityDescription: "claudeled")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Ask on launch: without this the keyboards silently look LED-less.
        if !InputMonitoring.granted { InputMonitoring.request() }

        // The privacy database keys on the code signature, and an ad-hoc signature
        // changes with every build -- so a grant given to yesterday's build does not
        // apply today. Record what we actually see, so diagnosing does not rely on
        // guessing from the outside.
        diagnose("launched from \(Bundle.main.bundlePath)")
        diagnose("input monitoring: \(InputMonitoring.description)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            let inventory = self?.registry.inventory() ?? []
            diagnose("keyboards seen: \(inventory.count), " +
                     "drivable: \(inventory.filter(\.drivable).count)")
            for keyboard in inventory {
                diagnose("  \(keyboard.name): capsLED=\(keyboard.drivable)")
            }
        }

        // `claudeled show` brings a hidden icon back from the command line.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showIcon),
            name: Notification.Name(showNotification), object: nil)

        // The app does nothing without hooks, so install them on launch. Idempotent, and
        // it re-points them if the bundle has moved since last run.
        if !Hooks.installed {
            do { try Hooks.install() }
            catch { NSLog("claudeled: could not install hooks: \(error)") }
        }

        registry.start()
        blinker = Blinker(registry: registry)
        blinker.start()

        // An Input Monitoring change only reaches a fresh process. Granting it while we
        // run would otherwise leave the app permanently broken-looking, so restart.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.relaunching,
                  InputMonitoring.granted != self.accessAtLaunch else { return }
            self.relaunching = true
            self.relaunch()
        }
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to be gone before reopening, or macOS reactivates it
        // instead of starting the replacement.
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        blinker?.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        blinker?.stop()
    }

    // Rebuilt on every open: keyboards come and go, and so does the waiting state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = Config.load()

        // Without Input Monitoring the keyboards look like they have no LED, so lead
        // with the real reason instead of letting the list mislead.
        guard InputMonitoring.granted else {
            let problem = NSMenuItem(title: "Input Monitoring is off", action: nil,
                                     keyEquivalent: "")
            problem.isEnabled = false
            menu.addItem(problem)

            let explain = NSMenuItem(title: "claudeled cannot reach the LEDs without it",
                                     action: nil, keyEquivalent: "")
            explain.isEnabled = false
            menu.addItem(explain)
            menu.addItem(.separator())

            let fix = NSMenuItem(title: "Open Privacy settings…",
                                 action: #selector(openInputMonitoring), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())

            let quit = NSMenuItem(title: "Quit claudeled", action: #selector(quit),
                                  keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            return
        }

        let waiting = readSessions().filter { blinkingEvents.contains($0.event) }.count
        let header = NSMenuItem(
            title: waiting == 0 ? "No session waiting"
                                : "\(waiting) session\(waiting == 1 ? "" : "s") waiting",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let keyboardHeader = NSMenuItem(title: "Blink on", action: nil, keyEquivalent: "")
        keyboardHeader.isEnabled = false
        menu.addItem(keyboardHeader)

        let inventory = registry.inventory()
        if inventory.isEmpty {
            let none = NSMenuItem(title: "no keyboards detected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for keyboard in inventory {
            let item = NSMenuItem(title: keyboard.name, action: #selector(toggleKeyboard(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = keyboard.name
            if keyboard.drivable {
                item.state = config.selects(keyboard.name) ? .on : .off
            } else {
                // No caps LED: nothing to drive, so do not pretend it is a choice.
                item.action = nil
                item.title = "\(keyboard.name) — no caps LED"
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let hooksInstalled = Hooks.installed
        let hooks = NSMenuItem(
            title: hooksInstalled ? "Claude Code hooks installed" : "Install Claude Code hooks",
            action: #selector(toggleHooks(_:)), keyEquivalent: "")
        hooks.target = self
        hooks.state = hooksInstalled ? .on : .off
        menu.addItem(hooks)

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin(_:)),
                               keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide icon", action: #selector(hideIcon),
                              keyEquivalent: "h")
        hide.target = self
        hide.toolTip = "Keeps blinking. Launch claudeled again, or run `claudeled show`, "
            + "to bring the icon back."
        menu.addItem(hide)

        let github = NSMenuItem(title: "Visit GitHub", action: #selector(openGitHub),
                                keyEquivalent: "")
        github.target = self
        menu.addItem(github)

        let quit = NSMenuItem(title: "Quit claudeled", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// AppKit closes a menu as soon as an item is chosen. For tick boxes that is the
    /// wrong feel -- you want to see the tick land, and tick a second keyboard without
    /// reopening. Reopening immediately is the only way to keep a stock NSMenu up.
    private func reopenMenu() {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    @objc private func toggleKeyboard(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var config = Config.load()
        let drivable = registry.inventory().filter(\.drivable).map(\.name)
        config.keyboards = Selection.toggle(name, current: config.keyboards, drivable: drivable)
        config.save()
        registry.reopen()
        reopenMenu()
    }

    @objc private func toggleHooks(_ sender: NSMenuItem) {
        do {
            if Hooks.installed { try Hooks.remove() } else { try Hooks.install() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update ~/.claude/settings.json"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
        reopenMenu()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("claudeled: login item toggle failed: \(error)")
        }
        reopenMenu()
    }

    @objc private func openInputMonitoring() {
        InputMonitoring.request()      // no-op once the user has answered once
        InputMonitoring.openSettings()
    }

    /// Hiding only takes the icon out of the menu bar. The blinking is the point of the
    /// app, so it keeps running.
    @objc private func hideIcon() {
        statusItem.isVisible = false
    }

    @objc private func showIcon() {
        statusItem.isVisible = true
    }

    /// Launching an already-running app does not start a second copy, it reopens this
    /// one -- which is how a hidden icon comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showIcon()
        return true
    }

    @objc private func openGitHub() {
        if let url = URL(string: githubURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() {
        blinker.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - CLI

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
case "hooks":   print(hookConfig)
case "hook":    cliHook(arguments.count > 1 ? arguments[1] : "")
case "-h", "--help", "help": print(usage)
default:
    print("unknown command: \(arguments[0])\n")
    print(usage)
    exit(2)
}
