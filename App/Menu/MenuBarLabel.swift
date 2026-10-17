import AppKit
import SwiftUI

/// Monochrome archway glyph; a dot is added when any tunnel needs attention (spec §7).
struct MenuBarLabel: View {
    let connected: Int
    let attention: Bool

    var body: some View {
        Image(nsImage: Self.glyph(dot: attention))
            .accessibilityLabel("Burrow: \(connected) connected\(attention ? ", needs attention" : "")")
    }

    static func glyph(dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: dot ? 22 : 18, height: 16), flipped: true) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            // Outer arch, inner arch, ground line.
            path.move(to: NSPoint(x: 2, y: 14)); path.line(to: NSPoint(x: 2, y: 8))
            path.appendArc(withCenter: NSPoint(x: 9, y: 8), radius: 7, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: 16, y: 14))
            path.move(to: NSPoint(x: 6, y: 14)); path.line(to: NSPoint(x: 6, y: 9))
            path.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 3, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: 12, y: 14))
            path.move(to: NSPoint(x: 1, y: 14)); path.line(to: NSPoint(x: 17, y: 14))
            NSColor.black.setStroke()
            path.stroke()
            if dot {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16, y: 1, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
