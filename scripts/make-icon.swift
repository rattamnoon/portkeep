// Draws the Portkeep app icon and writes App/Resources/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root: swift scripts/make-icon.swift
//
// Monochrome: a graphite squircle with a tunnel seen head-on, three arches receding into the
// mountain and the light at the end of it.
import AppKit

let set = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8)
    .write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"))

func render(_ side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(side) / 1024, y: CGFloat(side) / 1024)

    // Body: Apple's 824 squircle on the 1024 grid, with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    NSColor(white: 0.1, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor(white: 0.26, alpha: 1), NSColor(white: 0.07, alpha: 1)])!.draw(in: squircle, angle: -90)

    // A hairline highlight along the top edge, like machined metal.
    ctx.saveGState()
    squircle.addClip()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
    rim.lineWidth = 4
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
        .draw(in: rim, angle: -90)
    NSColor(white: 1, alpha: 0.10).setStroke()
    rim.stroke()
    ctx.restoreGState()

    // The light at the end of the tunnel, a soft glow behind the innermost arch.
    let center = NSPoint(x: 512, y: 430)
    let glow = NSGradient(colors: [NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0)])!
    glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: 190, options: [])

    // Three arches, each further in: narrower, thinner and dimmer.
    let base: CGFloat = 300
    let arches: [(halfWidth: CGFloat, height: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (270, 470, 54, 1.0), (178, 330, 40, 0.75), (98, 205, 30, 0.5),
    ]
    for arch in arches {
        let path = NSBezierPath()
        path.lineWidth = arch.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let shoulder = base + arch.height - arch.halfWidth
        path.move(to: NSPoint(x: 512 - arch.halfWidth, y: base))
        path.line(to: NSPoint(x: 512 - arch.halfWidth, y: shoulder))
        path.appendArc(withCenter: NSPoint(x: 512, y: shoulder), radius: arch.halfWidth,
                       startAngle: 180, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: 512 + arch.halfWidth, y: base))
        NSColor(white: 1, alpha: arch.alpha).setStroke()
        path.stroke()
    }

    // Ground line.
    let ground = NSBezierPath()
    ground.lineWidth = 54
    ground.lineCapStyle = .round
    ground.move(to: NSPoint(x: 200, y: base))
    ground.line(to: NSPoint(x: 824, y: base))
    NSColor.white.setStroke()
    ground.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: set.appendingPathComponent(name))
        images.append(#"{"idiom":"mac","size":"\#(points)x\#(points)","scale":"\#(scale)x","filename":"\#(name)"}"#)
    }
}
try Data(#"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#.utf8)
    .write(to: set.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(set.path)")
