import AppKit
import SwiftUI

/// Monochrome "Port" glyph, brackets around a dot; a dot is added when any tunnel needs attention (spec §7).
struct MenuBarLabel: View {
    let connected: Int
    let attention: Bool

    var body: some View {
        Image(nsImage: Self.glyph(dot: attention))
            .accessibilityLabel(attention ? Text("Portkeep: \(connected) connected, needs attention") : Text("Portkeep: \(connected) connected"))
    }

    static func glyph(dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: dot ? 24 : 18, height: 18), flipped: true) { _ in
            // Same mark as the app icon, redrawn for 18 pt: 2 pt strokes centred on whole points
            // so their edges land on the pixel grid at 1x and 2x.
            let brackets = NSBezierPath()
            brackets.lineWidth = 2
            brackets.lineCapStyle = .round
            brackets.lineJoinStyle = .round
            for (outer, inner) in [(CGFloat(3), CGFloat(6)), (15, 12)] {
                brackets.move(to: NSPoint(x: inner, y: 3))
                brackets.line(to: NSPoint(x: outer, y: 3))
                brackets.line(to: NSPoint(x: outer, y: 15))
                brackets.line(to: NSPoint(x: inner, y: 15))
            }
            NSColor.black.set()
            brackets.stroke()
            NSBezierPath(ovalIn: NSRect(x: 6.6, y: 6.6, width: 4.8, height: 4.8)).fill()
            if dot {
                NSBezierPath(ovalIn: NSRect(x: 18, y: 1, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
