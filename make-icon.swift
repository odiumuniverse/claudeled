// Renders claudeled's app icon into Resources/claudeled.iconset.
// Run through make-icon.sh, which turns the iconset into an .icns.
//
// The glyph is drawn rather than shipped as a binary blob so it stays reviewable
// and tweakable in a text diff.

import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "claudeled.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Rounded-square body, dark slate so the lit glyph reads as a lamp.
    let inset = size * 0.06
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = size * 0.225
    let bodyPath = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner,
                          transform: nil)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1).cgColor,
                                 NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.12, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Caps lock arrow: a chevron head over a stem, the shape every keyboard uses.
    let green = NSColor(calibratedRed: 0.30, green: 0.92, blue: 0.44, alpha: 1)
    let w = size * 0.46          // arrow width
    let cx = size / 2
    let top = size * 0.80        // apex
    let shoulder = size * 0.50   // where the head meets the stem
    let stemW = w * 0.42
    let stemBottom = size * 0.30

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: cx, y: top))
    arrow.addLine(to: CGPoint(x: cx + w / 2, y: shoulder))
    arrow.addLine(to: CGPoint(x: cx + stemW / 2, y: shoulder))
    arrow.addLine(to: CGPoint(x: cx + stemW / 2, y: stemBottom))
    arrow.addLine(to: CGPoint(x: cx - stemW / 2, y: stemBottom))
    arrow.addLine(to: CGPoint(x: cx - stemW / 2, y: shoulder))
    arrow.addLine(to: CGPoint(x: cx - w / 2, y: shoulder))
    arrow.closeSubpath()

    // Glow, so the icon reads as "lamp on" at Launchpad size.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.09, color: green.withAlphaComponent(0.85).cgColor)
    ctx.addPath(arrow)
    ctx.setFillColor(green.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // The bar under the arrow, as on a physical caps lock key.
    let barW = stemW * 1.9
    let bar = CGRect(x: cx - barW / 2, y: size * 0.19, width: barW, height: size * 0.065)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.07, color: green.withAlphaComponent(0.7).cgColor)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2,
                       cornerHeight: bar.height / 2, transform: nil))
    ctx.setFillColor(green.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    _ = rect
    image.unlockFocus()
    return image
}

func write(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

// iconutil expects both @1x and @2x for each nominal size.
for size in [16, 32, 128, 256, 512] {
    write(drawIcon(size: CGFloat(size)), to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    write(drawIcon(size: CGFloat(size * 2)),
          to: outDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
_ = sizes
print("wrote iconset to \(outDir.path)")
