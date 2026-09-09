// Renders the app icon (rounded square, list lines, bookmark) to an .iconset.
// Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
                        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)])!
        .draw(in: bg, angle: -90)
    // three "session rows": dot + bar
    let rows: [(NSColor, CGFloat)] = [(.systemOrange, 0.68), (.systemGreen, 0.50), (NSColor.white.withAlphaComponent(0.35), 0.32)]
    for (color, y) in rows {
        let cy = s * y
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: s * 0.22, y: cy - s * 0.035, width: s * 0.07, height: s * 0.07)).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.34, y: cy - s * 0.03, width: s * (y == 0.32 ? 0.26 : 0.36), height: s * 0.06),
                     xRadius: s * 0.03, yRadius: s * 0.03).fill()
    }
    // bookmark ribbon top-right
    let bx = s * 0.66, bw = s * 0.14, top = s - inset, bh = s * 0.26
    let ribbon = NSBezierPath()
    ribbon.move(to: NSPoint(x: bx, y: top))
    ribbon.line(to: NSPoint(x: bx + bw, y: top))
    ribbon.line(to: NSPoint(x: bx + bw, y: top - bh))
    ribbon.line(to: NSPoint(x: bx + bw / 2, y: top - bh + s * 0.06))
    ribbon.line(to: NSPoint(x: bx, y: top - bh))
    ribbon.close()
    NSColor(calibratedRed: 0.80, green: 0.36, blue: 0.02, alpha: 1).setFill()
    ribbon.fill()
    img.unlockFocus()
    return img
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] as [(String, Int)] {
    let img = draw(CGFloat(px))
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: px, height: px)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
