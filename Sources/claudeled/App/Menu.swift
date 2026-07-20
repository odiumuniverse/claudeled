// Menu.swift -- the menu bar item and everything reachable from it.

import AppKit
import Foundation
import ServiceManagement

let githubURL = "https://github.com/odiumuniverse/claudeled"
let showNotification = "com.odiumuniverse.claudeled.show"

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
