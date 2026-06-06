// Renders the DMG window background (assets/dmg-background.png) headlessly with
// AppKit. Warm cream backdrop, title, a drag-to-Applications arrow, and captions
// for the Extension and INSTALL items. Coordinates are top-left origin in points
// and match the icon positions set by package.sh.
//
// Usage: swift assets/make-background.swift [output.png]

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/dmg-background.png"

let scale: CGFloat = 2
let w: CGFloat = 640, h: CGFloat = 440

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("could not allocate bitmap")
}
rep.size = NSSize(width: w, height: h)

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.scaleBy(x: scale, y: scale)

// Layout below is authored in top-left coordinates (y down) to match Finder's
// icon positions; flipY converts to AppKit's bottom-left origin for drawing.
func flipY(_ y: CGFloat) -> CGFloat { h - y }

let clay = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)      // #D97757
let ink  = NSColor(srgbRed: 0.227, green: 0.165, blue: 0.137, alpha: 1)      // #3A2A23
let mute = NSColor(srgbRed: 0.451, green: 0.376, blue: 0.341, alpha: 1)

// Background gradient.
NSGradient(colors: [
    NSColor(srgbRed: 0.992, green: 0.965, blue: 0.945, alpha: 1),
    NSColor(srgbRed: 0.957, green: 0.886, blue: 0.835, alpha: 1)
])!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

// y is the distance of the text's top edge from the top of the image.
func draw(_ text: String, centerX: CGFloat, y: CGFloat, size: CGFloat,
          color: NSColor, bold: Bool = false) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let s = NSAttributedString(string: text, attributes: attrs)
    let sz = s.size()
    s.draw(at: NSPoint(x: centerX - sz.width / 2, y: flipY(y) - sz.height))
}

// Headline.
draw("ClaudeUsageBar", centerX: 320, y: 28, size: 30, color: ink, bold: true)
draw("Your Claude usage, in the menu bar", centerX: 320, y: 66, size: 14, color: mute)

// Drag arrow between the two top icons (app at x150, Applications at x490).
draw("drag to install", centerX: 320, y: 150, size: 12, color: clay, bold: true)
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 225, y: flipY(182)))
arrow.line(to: NSPoint(x: 412, y: flipY(182)))
clay.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 415, y: flipY(182)))
head.line(to: NSPoint(x: 398, y: flipY(173)))
head.line(to: NSPoint(x: 398, y: flipY(191)))
head.close()
clay.setFill()
head.fill()

// Captions above the bottom-row icons (Extension at x150, INSTALL at x490).
draw("Extension", centerX: 150, y: 270, size: 13, color: ink, bold: true)
draw("copy out, then load in Chrome", centerX: 150, y: 288, size: 11, color: mute)
draw("INSTALL.txt", centerX: 490, y: 270, size: 13, color: ink, bold: true)
draw("read me for full steps", centerX: 490, y: 288, size: 11, color: mute)

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode png")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
