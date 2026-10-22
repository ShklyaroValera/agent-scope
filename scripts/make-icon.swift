// Draws the app icon (the menu bar graph glyph on a dark rounded square) and writes
// Support/Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    // macOS icon grid: 824/1024 body with rounded corners.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: color(0x2A2A2E), ending: color(0x121214))!.draw(in: shape, angle: -90)

    // Glyph from the 24×24 design SVG, flipped to AppKit's y-up space.
    let scale = body.width * 0.62 / 24
    let origin = NSPoint(x: body.midX - 12 * scale, y: body.midY + 12 * scale)
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * scale, y: origin.y - y * scale) }
    let edges = NSBezierPath()
    edges.lineWidth = 2.2 * scale
    edges.lineCapStyle = .round
    edges.move(to: point(7, 7.5)); edges.line(to: point(10.5, 16))
    edges.move(to: point(17, 7.5)); edges.line(to: point(13.5, 16))
    color(0xD1D1D6).setStroke()
    edges.stroke()
    for (x, y, fill) in [(5.0, 6.0, 0xD97757), (19, 6, 0x7A4FD6), (12, 18, 0x2F6FEB)] as [(CGFloat, CGFloat, UInt32)] {
        let r = 3.1 * scale
        let center = point(x, y)
        color(fill).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
let output = root.appending(path: "Support/Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(output.path)
