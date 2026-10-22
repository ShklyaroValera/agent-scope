import AgentScopeKit
import AppKit

/// Draws the menu bar glyph from `design/menubar-popover.html`: a three-node graph, the active count and
/// an attention dot. Without a dot the image is a template so macOS tints it; with one it draws in
/// `labelColor`, which resolves against the menu bar's appearance at draw time.
@MainActor
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    /// The same image object for the same state, so the status item is not redrawn on every refresh.
    static func cachedImage(activeCount: Int, attention: Attention?) -> NSImage {
        let key = "\(activeCount)-\(String(describing: attention))"
        if let image = cache[key] { return image }
        let image = image(activeCount: activeCount, attention: attention)
        cache[key] = image
        return image
    }

    static func image(activeCount: Int, attention: Attention?) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let text = activeCount > 0 ? "\(activeCount)" as NSString : nil
        let textWidth = text.map { ceil($0.size(withAttributes: [.font: font]).width) } ?? 0
        let glyph: CGFloat = 15
        let dot: CGFloat = 6
        var width = glyph
        if text != nil { width += 4 + textWidth }
        if attention != nil { width += 4 + dot }
        let size = NSSize(width: width, height: 18)

        let image = NSImage(size: size, flipped: true) { _ in
            let ink = attention == nil ? NSColor.black : NSColor.labelColor
            drawGlyph(in: NSRect(x: 0, y: 1.5, width: glyph, height: glyph), color: ink)
            var x = glyph
            if let text {
                x += 4
                let height = text.size(withAttributes: [.font: font]).height
                text.draw(at: NSPoint(x: x, y: (size.height - height) / 2), withAttributes: [.font: font, .foregroundColor: ink])
                x += textWidth
            }
            if let attention {
                x += 4
                let color = attention == .needsYou ? NSColor(hex: 0xE8890C) : NSColor(hex: 0xD93F3F)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: (size.height - dot) / 2, width: dot, height: dot)).fill()
            }
            return true
        }
        image.isTemplate = attention == nil
        image.accessibilityDescription = "AgentScope, \(activeCount) active"
        return image
    }

    /// The design's 24×24 SVG path scaled into `rect`.
    private static func drawGlyph(in rect: NSRect, color: NSColor) {
        let scale = rect.width / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        let path = NSBezierPath()
        path.lineWidth = 2.2 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (x, y) in [(5.0, 6.0), (19, 6), (12, 18)] {
            let radius = 2.5 * scale
            let center = point(x, y)
            path.appendOval(in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        path.move(to: point(7, 7.5))
        path.line(to: point(10.5, 16))
        path.move(to: point(17, 7.5))
        path.line(to: point(13.5, 16))
        color.setStroke()
        path.stroke()
    }
}
