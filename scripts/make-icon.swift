// Draws the StripMac app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024  // design on a 1024 grid

    // Squircle background with a deep indigo → violet gradient (macOS icon grid: 824 inset by 100).
    let bg = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = NSBezierPath(roundedRect: bg, xRadius: 185 * u, yRadius: 185 * u)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.12, blue: 0.42, alpha: 1),
                        NSColor(srgbRed: 0.45, green: 0.22, blue: 0.85, alpha: 1)])!.draw(in: shape, angle: 70)

    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    // Side columns run off the edges of the tile: the strip continues beyond the screen.
    let side = NSColor(white: 1, alpha: 0.28)
    for x in [40.0, 724.0] {
        side.setFill()
        NSBezierPath(roundedRect: NSRect(x: x * u, y: 250 * u, width: 260 * u, height: 524 * u),
                     xRadius: 44 * u, yRadius: 44 * u).fill()
    }
    // Focused column: bright, taller, with a soft glow.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.55, green: 0.9, blue: 1, alpha: 0.8)
    shadow.shadowBlurRadius = 60 * u
    shadow.set()
    let focus = NSBezierPath(roundedRect: NSRect(x: 352 * u, y: 200 * u, width: 320 * u, height: 624 * u),
                             xRadius: 52 * u, yRadius: 52 * u)
    NSGradient(colors: [NSColor(srgbRed: 0.55, green: 0.95, blue: 1, alpha: 1), .white])!.draw(in: focus, angle: 90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Title bar dots on the focused column.
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: (392 + CGFloat(i) * 44) * u, y: 760 * u, width: 28 * u, height: 28 * u)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
