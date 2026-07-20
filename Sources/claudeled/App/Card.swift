// Card.swift -- the report as a PNG, for pasting somewhere that does not do monospace.
//
// Drawn with AppKit rather than templated into SVG, because the app already links
// AppKit and the icon is drawn the same way. No fonts to embed, no renderer to ship.

import AppKit
import Foundation

enum Card {
    private static let width: CGFloat = 760
    private static let margin: CGFloat = 44
    private static let ink = NSColor(calibratedWhite: 0.96, alpha: 1)
    private static let dim = NSColor(calibratedWhite: 0.55, alpha: 1)
    private static let green = NSColor(calibratedRed: 0.30, green: 0.92, blue: 0.44, alpha: 1)

    private static func text(_ string: String, _ size: CGFloat, _ colour: NSColor,
                             weight: NSFont.Weight = .regular,
                             mono: Bool = false) -> NSAttributedString {
        let font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: string,
                                  attributes: [.font: font, .foregroundColor: colour])
    }

    static func png(_ report: Report, label: String, cap: TimeInterval) -> Data? {
        // Title block, the two headline numbers, a line per project, then the footer.
        let rows = min(report.projects.count, 8)
        let height: CGFloat = rows > 0 ? 250 + CGFloat(rows) * 34 : 226

        // Drawn straight into a bitmap rather than through NSImage.lockFocus: the PNG
        // has to be taken after the focus is released, which is easy to get wrong, and
        // this way the 2x backing store is explicit.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Before the context is made: the size is what tells it a point is two pixels,
        // and a context built first draws at 1x into a corner of the bitmap.
        rep.size = NSSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = context.cgContext

        // Same slate as the app icon, so a shared card is recognisably from here.
        ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var y = height - margin - 26
        let heading = text("Claude Code", 26, ink, weight: .semibold)
        heading.draw(at: NSPoint(x: margin, y: y))
        text(label, 26, dim).draw(at: NSPoint(x: margin + heading.size().width + 12, y: y))

        // The two headline numbers, side by side, so the card stays wide and short.
        y -= 86
        for (column, caption, value, colour) in [
            (margin, "Claude worked", report.totals.worked, green),
            (width / 2, "waiting on you", report.totals.waiting, ink),
        ] {
            text(caption, 15, dim).draw(at: NSPoint(x: column, y: y + 44))
            text(formatDuration(value), 34, colour, weight: .medium)
                .draw(at: NSPoint(x: column, y: y))
        }

        y -= 26
        if rows > 0 {
            // Colour alone would say which column is which, but only to someone who
            // already knows. Two words cost a line.
            for (caption, offset) in [("worked", CGFloat(220)), ("waiting", 0)] {
                let head = text(caption, 11, dim)
                head.draw(at: NSPoint(x: width - margin - offset - head.size().width, y: y + 26))
            }
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.08).cgColor)
            ctx.fill(CGRect(x: margin, y: y + 22, width: width - margin * 2, height: 1))
            y -= 6
            for project in report.projects.prefix(rows) {
                text(project.name, 15, ink, mono: true).draw(at: NSPoint(x: margin, y: y))
                let worked = text(formatDuration(project.totals.worked), 15, green, mono: true)
                let waiting = text(formatDuration(project.totals.waiting), 15, dim, mono: true)
                worked.draw(at: NSPoint(x: width - margin - 220 - worked.size().width, y: y))
                waiting.draw(at: NSPoint(x: width - margin - waiting.size().width, y: y))
                y -= 34
            }
            y -= 12
        }

        text(footerLine(report, cap: cap), 13, dim).draw(at: NSPoint(x: margin, y: margin - 14))

        return rep.representation(using: .png, properties: [:])
    }

    private static func footerLine(_ report: Report, cap: TimeInterval) -> String {
        var text = "\(report.sessions) session\(report.sessions == 1 ? "" : "s")"
        if report.totals.away > 0 {
            text += " · \(formatDuration(report.totals.away)) not counted "
                + "(gaps over \(formatDuration(cap)))"
        }
        return text + " · claudeled"
    }
}
