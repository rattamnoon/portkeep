import AppKit
import SwiftUI

/// Monochrome archway glyph; a dot is added when any tunnel needs attention (spec §7).
struct MenuBarLabel: View {
    let connected: Int
    let attention: Bool

    var body: some View {
        Image(nsImage: Self.glyph(dot: attention))
            .accessibilityLabel(attention ? Text("Portkeep: \(connected) connected, needs attention") : Text("Portkeep: \(connected) connected"))
    }

    static func glyph(dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: dot ? 22 : 18, height: 16), flipped: true) { _ in
            // Same mark as the app icon: three arches receding into the tunnel, on a ground line.
            let arches: [(halfWidth: CGFloat, top: CGFloat, width: CGFloat, alpha: CGFloat)] = [
                (7, 1.2, 1.6, 1), (4.6, 5, 1.3, 0.7), (2.4, 8.6, 1.1, 0.45),
            ]
            for arch in arches {
                let path = NSBezierPath()
                path.lineWidth = arch.width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                let shoulder = arch.top + arch.halfWidth
                path.move(to: NSPoint(x: 9 - arch.halfWidth, y: 14))
                path.line(to: NSPoint(x: 9 - arch.halfWidth, y: shoulder))
                path.appendArc(withCenter: NSPoint(x: 9, y: shoulder), radius: arch.halfWidth,
                               startAngle: 180, endAngle: 0, clockwise: true)
                path.line(to: NSPoint(x: 9 + arch.halfWidth, y: 14))
                NSColor.black.withAlphaComponent(arch.alpha).setStroke()
                path.stroke()
            }
            let ground = NSBezierPath()
            ground.lineWidth = 1.6
            ground.lineCapStyle = .round
            ground.move(to: NSPoint(x: 1, y: 14)); ground.line(to: NSPoint(x: 17, y: 14))
            NSColor.black.setStroke()
            ground.stroke()
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
