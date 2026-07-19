// claudeled -- Caps Lock LED indicator for Claude Code.
//
// Blinks the Caps Lock LED while a Claude Code session needs you. Drives the HID
// caps LED element directly (IOHIDDeviceSetValue), so the Caps Lock *modifier* is
// never asserted and typing case is unaffected. Verified on Apple Internal Keyboard
// (SPI) and Magic Keyboard (Bluetooth), with and without a Caps->Ctrl remap.
//
// One binary, two faces:
//   no arguments  -> menu bar app (LSUIElement), owns the LEDs
//   arguments     -> CLI, used by Claude Code hooks and by you
//
// Hooks report *events*; the app decides what they mean, because the blink mode is
// switched in the menu at runtime while settings.json stays static.

import AppKit
import Foundation
import IOKit
import IOKit.hid
import ServiceManagement

let githubURL = "https://github.com/odiumuniverse/claudeled"

// MARK: - paths

let home = FileManager.default.homeDirectoryForCurrentUser
let baseDir = home.appendingPathComponent(".config/claudeled", isDirectory: true)
let stateDir = baseDir.appendingPathComponent("sessions", isDirectory: true)
let configURL = baseDir.appendingPathComponent("config.json")

/// Backstop for sessions we could not tie to a process. The pid check does the real work.
let staleTTL: TimeInterval = 12 * 3600

func ensureDirs() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
}

// MARK: - model

/// What a hook told us last about a session.
enum SessionEvent: String {
    case prompt   // UserPromptSubmit -- you handed work to Claude
    case stop     // Stop -- Claude finished its turn, the ball is yours
    case notify   // Notification -- Claude is blocked on a permission prompt
}

enum BlinkMode: String, Codable, CaseIterable {
    case waiting   // blink while Claude waits on you
    case working   // blink while Claude is busy

    var title: String {
        switch self {
        case .waiting: return "Blink while Claude waits for me"
        case .working: return "Blink while Claude is working"
        }
    }

    /// Events that mean "blink" in this mode.
    var activeEvents: Set<SessionEvent> {
        switch self {
        case .waiting: return [.stop, .notify]
        case .working: return [.prompt]
        }
    }

    var pattern: [Int] {
        switch self {
        // double pulse, mostly dark -- noticeable without being a strobe
        case .waiting: return [120, 120, 120, 900]
        // Claude works for minutes at a stretch, so this one stays discreet
        case .working: return [100, 1900]
        }
    }
}

struct Config: Codable {
    /// Exact product names. Empty means "every keyboard that has a caps LED".
    var keyboards: [String] = []
    var mode: BlinkMode = .waiting

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    func save() {
        ensureDirs()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: configURL)
    }

    func selects(_ name: String) -> Bool {
        keyboards.isEmpty || keyboards.contains(name)
    }
}

// MARK: - Claude Code hooks

/// Installs itself into ~/.claude/settings.json. The file belongs to the user and
/// usually holds unrelated hooks, so every write is a merge: unknown keys are
/// preserved, our entries are matched by command path and never duplicated.
enum Hooks {
    /// Event name in settings.json -> argument we want passed to `claudeled hook`.
    static let events: [(claudeEvent: String, argument: String)] = [
        ("UserPromptSubmit", "prompt"),
        ("Stop", "stop"),
        ("Notification", "notify"),
        // A tool ran, so whatever the notification was blocking on is resolved. Without
        // this the light keeps blinking after you approve a permission prompt, all the
        // way until your next message.
        ("PostToolUse", "prompt"),
        ("SessionEnd", "end"),
        // SubagentStop is deliberately absent: it is what keeps subagents from
        // blinking the light on behalf of the main agent.
    ]

    static let settingsURL = home.appendingPathComponent(".claude/settings.json")

    /// Absolute path into the bundle. `claudeled` alone would depend on the PATH that
    /// Claude Code happens to run hooks with, which is not ours to assume.
    static var executable: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    private static func command(_ argument: String) -> String {
        "\"\(executable)\" hook \(argument)"
    }

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }

    /// True when every event we need already points at this executable.
    static var installed: Bool {
        let hooks = load()["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            guard let groups = hooks[event.claudeEvent] as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String)?.contains(executable) == true }
            }
        }
    }

    /// Keeps a one-time backup so a bad merge is always recoverable.
    private static func backupOnce() {
        let backup = settingsURL.appendingPathExtension("claudeled-backup")
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }

    static func install() throws {
        backupOnce()
        var settings = load()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var groups = hooks[event.claudeEvent] as? [[String: Any]] ?? []
            // Drop any entry of ours first: the bundle may have moved since last time.
            groups = groups.compactMap { group -> [String: Any]? in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                entries.removeAll { ($0["command"] as? String)?.contains("claudeled") == true }
                if entries.isEmpty { return nil }
                var updated = group
                updated["hooks"] = entries
                return updated
            }
            groups.append(["hooks": [["type": "command", "command": command(event.argument)]]])
            hooks[event.claudeEvent] = groups
        }

        settings["hooks"] = hooks
        try write(settings)
    }

    static func remove() throws {
        var settings = load()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in events {
            guard var groups = hooks[event.claudeEvent] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group -> [String: Any]? in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                entries.removeAll { ($0["command"] as? String)?.contains("claudeled") == true }
                if entries.isEmpty { return nil }
                var updated = group
                updated["hooks"] = entries
                return updated
            }
            if groups.isEmpty { hooks.removeValue(forKey: event.claudeEvent) }
            else { hooks[event.claudeEvent] = groups }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        try write(settings)
    }
}

// MARK: - process helpers

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
        // carries the name even though the executable is called after the version.
        let components = path.split(separator: "/").map(String.init)
        if components.contains("claude") || name.lowercased().hasPrefix("claude") {
            return pid
        }
        // Fallback for installs launched through node: the first ancestor that is not a
        // shell is the thing that spawned the hook, which is Claude Code.
        if firstNonShell == 0, !shellNames.contains(name), !name.isEmpty {
            firstNonShell = pid
        }
        if parent <= 1 { break }
        pid = parent
    }
    return firstNonShell
}

func isAlive(_ pid: pid_t) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
}

// MARK: - session state

struct Session {
    let id: String
    let pid: pid_t
    let event: SessionEvent
    let at: Date
}

func readSessions() -> [Session] {
    guard let files = try? FileManager.default.contentsOfDirectory(at: stateDir,
                                                                   includingPropertiesForKeys: nil)
    else { return [] }
    return files.compactMap { url in
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 3,
              let pid = pid_t(lines[0]),
              let stamp = TimeInterval(lines[1]),
              let event = SessionEvent(rawValue: lines[2]) else { return nil }
        return Session(id: url.lastPathComponent, pid: pid, event: event,
                       at: Date(timeIntervalSince1970: stamp))
    }
}

/// Drops sessions whose process is gone, or that outlived the TTL. This is what keeps a
/// kill -9'd terminal from blinking forever.
func pruneSessions() {
    let now = Date()
    for s in readSessions() {
        let dead = s.pid != 0 && !isAlive(s.pid)
        let stale = now.timeIntervalSince(s.at) > staleTTL
        if dead || stale {
            try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(s.id))
        }
    }
}

func record(session: String, event: SessionEvent) {
    ensureDirs()
    let body = "\(claudeAncestor())\n\(Date().timeIntervalSince1970)\n\(event.rawValue)\n"
    try? body.write(to: stateDir.appendingPathComponent(session), atomically: true, encoding: .utf8)
}

func forget(_ session: String) {
    try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(session))
}

// MARK: - keyboards

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
        let elems = (IOHIDDeviceCopyMatchingElements(
            device, [kIOHIDElementUsagePageKey: Int(kHIDPage_LEDs)] as CFDictionary, 0)
            as? [IOHIDElement]) ?? []
        return elems.first { IOHIDElementGetUsage($0) == UInt32(kHIDUsage_LED_CapsLock) }
    }

    static func describe(_ device: IOHIDDevice) -> KeyboardInfo {
        func prop<T>(_ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }
        return KeyboardInfo(
            device: device,
            element: capsElement(device),
            name: prop(kIOHIDProductKey) ?? "Unknown keyboard",
            vendor: prop(kIOHIDVendorIDKey) ?? -1,
            product: prop(kIOHIDProductIDKey) ?? -1,
            transport: prop(kIOHIDTransportKey) ?? "?")
    }

    static func matchingDict() -> CFArray {
        [[kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
          kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]] as CFArray
    }

    /// One-shot enumeration for the CLI.
    static func enumerate() -> [KeyboardInfo] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matchingDict())
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
        return devices.map(describe).sorted { $0.name < $1.name }
    }
}

/// Live registry driven by IOHIDManager callbacks, so sleep, Bluetooth reconnects and
/// receiver unplugs are handled without polling.
final class KeyboardRegistry {
    private let lock = NSLock()
    private var open: [(device: IOHIDDevice, element: IOHIDElement, name: String)] = []
    private var known: [IOHIDDevice] = []
    private var manager: IOHIDManager?
    private var config = Config.load()

    var selectedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return open.map(\.name)
    }

    func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, HID.matchingDict())
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<KeyboardRegistry>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<KeyboardRegistry>.fromOpaque(ctx).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
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

    /// Called on config changes too, so ticking a keyboard in the menu takes effect at once.
    func reopen() {
        let cfg = Config.load()
        lock.lock()
        config = cfg
        for entry in open {
            setLED(entry, on: false)
            IOHIDDeviceClose(entry.device, 0)
        }
        open.removeAll()
        for device in known {
            let info = HID.describe(device)
            guard let element = info.element, cfg.selects(info.name) else { continue }
            guard IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { continue }
            open.append((device, element, info.name))
        }
        lock.unlock()
    }

    private func setLED(_ entry: (device: IOHIDDevice, element: IOHIDElement, name: String), on: Bool) {
        let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, entry.element, 0, on ? 1 : 0)
        IOHIDDeviceSetValue(entry.device, entry.element, value)
    }

    func set(_ on: Bool) {
        lock.lock()
        let snapshot = open
        lock.unlock()
        for entry in snapshot { setLED(entry, on: on) }
    }

    /// All keyboards seen so far, whether or not they are selected. Menu uses this.
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

    var isActive: Bool {
        let cfg = Config.load()
        return readSessions().contains { cfg.mode.activeEvents.contains($0.event) }
    }

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
                let cfg = Config.load()
                let active = readSessions().contains { cfg.mode.activeEvents.contains($0.event) }
                guard active else {
                    registry.set(false)
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }
                for (index, ms) in cfg.mode.pattern.enumerated() {
                    guard running else { break }
                    registry.set(index % 2 == 0)
                    Thread.sleep(forTimeInterval: Double(ms) / 1000)
                }
                registry.set(false)
            }
        }
    }
}

// MARK: - menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let registry = KeyboardRegistry()
    private var blinker: Blinker!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDirs()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capslock",
                                           accessibilityDescription: "claudeled")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // The app is useless without hooks, so install them on launch. Idempotent, and
        // it re-points them if the bundle moved since last run.
        if !Hooks.installed {
            do { try Hooks.install() }
            catch { NSLog("claudeled: could not install hooks: \(error)") }
        }

        registry.start()
        blinker = Blinker(registry: registry)
        blinker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        blinker?.stop()
    }

    // Rebuilt on every open: keyboards come and go, and so does the waiting state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = Config.load()

        let waiting = readSessions().filter { cfg.mode.activeEvents.contains($0.event) }.count
        let status = waiting == 0 ? "Idle" : "\(waiting) session\(waiting == 1 ? "" : "s") waiting"
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for mode in BlinkMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.state = cfg.mode == mode ? .on : .off
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let kbHeader = NSMenuItem(title: "Keyboards", action: nil, keyEquivalent: "")
        kbHeader.isEnabled = false
        menu.addItem(kbHeader)

        let inventory = registry.inventory()
        if inventory.isEmpty {
            let none = NSMenuItem(title: "  none detected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for kb in inventory {
            let item = NSMenuItem(title: kb.name, action: #selector(toggleKeyboard(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kb.name
            if kb.drivable {
                item.state = cfg.selects(kb.name) ? .on : .off
            } else {
                // No caps LED element: nothing to drive, so do not pretend it is a choice.
                item.isEnabled = false
                item.title = "\(kb.name) (no caps LED)"
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let hooksInstalled = Hooks.installed
        let hooksItem = NSMenuItem(
            title: hooksInstalled ? "Claude Code hooks installed" : "Install Claude Code hooks",
            action: #selector(toggleHooks(_:)), keyEquivalent: "")
        hooksItem.target = self
        hooksItem.state = hooksInstalled ? .on : .off
        menu.addItem(hooksItem)

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let github = NSMenuItem(title: "Visit GitHub", action: #selector(openGitHub), keyEquivalent: "")
        github.target = self
        menu.addItem(github)

        let quit = NSMenuItem(title: "Quit claudeled", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = BlinkMode(rawValue: raw) else { return }
        var cfg = Config.load()
        cfg.mode = mode
        cfg.save()
    }

    @objc private func toggleKeyboard(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var cfg = Config.load()
        let drivable = registry.inventory().filter(\.drivable).map(\.name)
        // Empty means "all", so materialise the real list before removing one from it.
        var selected = cfg.keyboards.isEmpty ? drivable : cfg.keyboards
        if selected.contains(name) {
            selected.removeAll { $0 == name }
        } else {
            selected.append(name)
        }
        // Everything selected collapses back to "all", so newly plugged keyboards join in.
        cfg.keyboards = Set(selected) == Set(drivable) ? [] : selected
        cfg.save()
        registry.reopen()
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

func out(_ s: String) { print(s) }

func cliDevices(namesOnly: Bool) {
    let cfg = Config.load()
    let keyboards = HID.enumerate()
    if namesOnly {
        // Consumed by shell completion: one name per line, nothing else.
        for kb in keyboards where kb.drivable { out(kb.name) }
        return
    }
    if keyboards.isEmpty { out("no keyboards found"); return }
    out("mode: \(cfg.mode.rawValue)")
    out(cfg.keyboards.isEmpty ? "keyboards: all" : "keyboards: \(cfg.keyboards.joined(separator: ", "))")
    out("")
    for kb in keyboards {
        let mark = kb.drivable ? (cfg.selects(kb.name) ? "[x]" : "[ ]") : "[-]"
        out("\(mark) \(kb.name)")
        out("    vid=\(kb.vendor) pid=\(kb.product) transport=\(kb.transport) " +
            "capsLED=\(kb.drivable ? "yes" : "no")")
    }
}

func cliTest(_ query: String) {
    let matches = HID.enumerate().filter {
        query.isEmpty || $0.name.lowercased().contains(query.lowercased())
    }
    guard !matches.isEmpty else {
        out("no keyboard matching '\(query)'")
        exit(1)
    }
    for kb in matches {
        guard let element = kb.element else {
            out("\(kb.name): no caps LED, cannot be driven")
            continue
        }
        guard IOHIDDeviceOpen(kb.device, 0) == kIOReturnSuccess else {
            out("\(kb.name): open failed")
            continue
        }
        out("\(kb.name): LED on for 3s, watch it")
        // Re-assert: a single write fades on some Bluetooth keyboards.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            IOHIDDeviceSetValue(kb.device, element,
                IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 1))
            Thread.sleep(forTimeInterval: 0.05)
        }
        IOHIDDeviceSetValue(kb.device, element,
            IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0))
        IOHIDDeviceClose(kb.device, 0)
    }
}

func cliStatus() {
    let cfg = Config.load()
    out("mode: \(cfg.mode.rawValue) (\(cfg.mode.title))")
    let sessions = readSessions()
    if sessions.isEmpty { out("no sessions tracked"); return }
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss"
    for s in sessions.sorted(by: { $0.at < $1.at }) {
        let blinking = cfg.mode.activeEvents.contains(s.event) ? "BLINKING" : "quiet"
        let proc = s.pid == 0 ? "pid unknown" : (isAlive(s.pid) ? "pid \(s.pid)" : "pid \(s.pid) DEAD")
        out("\(s.id)  \(s.event.rawValue)  \(fmt.string(from: s.at))  \(proc)  \(blinking)")
    }
}

/// Hooks pipe their JSON on stdin. Never fail loudly: a broken hook must not break Claude.
func cliHook(_ eventName: String) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = json["session_id"] as? String, !raw.isEmpty else { exit(0) }
    // session_id becomes a filename.
    let session = raw.replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "..", with: "_")
    if eventName == "end" {
        forget(session)
    } else if let event = SessionEvent(rawValue: eventName) {
        record(session: session, event: event)
    }
    exit(0)
}

let usage = """
claudeled -- Caps Lock LED indicator for Claude Code

  claudeled                    run the menu bar app
  claudeled devices            list keyboards and which are selected
  claudeled devices --names    names only, for shell completion
  claudeled test <keyboard>    light a keyboard for 3s
  claudeled status             show tracked sessions and the current mode
  claudeled hooks              print the Claude Code hook config to install
  claudeled hook <event>       internal: called by hooks (prompt|stop|notify|end)

config: ~/.config/claudeled/config.json
"""

let hookConfig = """
Add to ~/.claude/settings.json (merge with existing hooks):

{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "claudeled hook prompt"}]}],
    "Stop":             [{"hooks": [{"type": "command", "command": "claudeled hook stop"}]}],
    "Notification":     [{"hooks": [{"type": "command", "command": "claudeled hook notify"}]}],
    "SessionEnd":       [{"hooks": [{"type": "command", "command": "claudeled hook end"}]}]
  }
}

SubagentStop is deliberately absent: that is what keeps subagents from
blinking the light on behalf of the main agent.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    app.run()
case "devices":
    cliDevices(namesOnly: arguments.contains("--names"))
case "test":
    cliTest(arguments.count > 1 ? arguments[1] : "")
case "status":
    cliStatus()
case "hooks":
    out(hookConfig)
case "hook":
    cliHook(arguments.count > 1 ? arguments[1] : "")
case "-h", "--help", "help":
    out(usage)
default:
    out("unknown command: \(arguments[0])\n")
    out(usage)
    exit(2)
}
