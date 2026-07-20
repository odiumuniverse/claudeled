// StatsWindow.swift -- the same report as `claudeled stats`, for people who are
// already in the menu rather than in a terminal.

import AppKit
import Foundation

final class StatsWindow: NSObject, NSWindowDelegate {
    static let shared = StatsWindow()

    private var window: NSWindow?
    private var periods: NSSegmentedControl!
    private var body: NSTextView!

    private var period: Period { Period.allCases[periods.selectedSegment] }

    func show() {
        if window == nil { build() }
        refresh()
        // An accessory app has no Dock icon to click, so it has to ask for the front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let frame = NSRect(x: 0, y: 0, width: 620, height: 470)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "claudeled"
        window.center()
        window.isReleasedWhenClosed = false      // reopened from the menu, not rebuilt
        window.delegate = self

        periods = NSSegmentedControl(
            labels: Period.allCases.map(\.label), trackingMode: .selectOne,
            target: self, action: #selector(refresh))
        periods.selectedSegment = 0
        periods.frame = NSRect(x: 20, y: frame.height - 52, width: frame.width - 40, height: 26)
        periods.autoresizingMask = [.width, .minYMargin]

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 62, width: frame.width - 40,
                                                height: frame.height - 128))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        body = NSTextView(frame: scroll.bounds)
        body.isEditable = false
        body.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        body.textContainerInset = NSSize(width: 10, height: 10)
        body.autoresizingMask = [.width]
        scroll.documentView = body

        let copy = NSButton(title: "Copy as Markdown", target: self,
                            action: #selector(copyMarkdown))
        copy.frame = NSRect(x: 20, y: 18, width: 180, height: 28)
        copy.autoresizingMask = [.maxXMargin]

        let card = NSButton(title: "Save PNG Card…", target: self, action: #selector(saveCard))
        card.frame = NSRect(x: frame.width - 190, y: 18, width: 170, height: 28)
        card.autoresizingMask = [.minXMargin]

        window.contentView?.addSubview(periods)
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(copy)
        window.contentView?.addSubview(card)
        self.window = window
    }

    @objc private func refresh() {
        let cap = Config.load().idleCap
        let report = period.report(cap: cap)
        body.string = report.sessions == 0
            ? noEventsYet
            : renderText([Summary(label: period.label, report: report)],
                         projects: report, cap: cap)
    }

    @objc private func copyMarkdown() {
        let cap = Config.load().idleCap
        let markdown = renderMarkdown(period.report(cap: cap), label: period.label, cap: cap)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    @objc private func saveCard() {
        let cap = Config.load().idleCap
        guard let png = Card.png(period.report(cap: cap), label: period.label, cap: cap)
        else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claudeled-\(period.rawValue).png"
        panel.allowedContentTypes = [.png]
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }
}
