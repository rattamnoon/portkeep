// Draws the Portkeep app icon and writes App/Resources/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

let set = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8)
    .write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"))

/// The icon at `side` pixels, on Apple's 1024 grid: an 824 squircle with a white archway and a lit port.
func render(_ side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(side) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Squircle body with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(red: 0.07, green: 0.16, blue: 0.42, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()
    NSGradient(colors: [
        NSColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(red: 0.05, green: 0.14, blue: 0.45, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    // Ground line and nested arches: the tunnel mouth.
    NSColor.white.setStroke()
    func arch(_ halfWidth: CGFloat, _ top: CGFloat, width: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let base: CGFloat = 300
        path.move(to: NSPoint(x: 512 - halfWidth, y: base))
        path.line(to: NSPoint(x: 512 - halfWidth, y: top - halfWidth))
        path.appendArc(withCenter: NSPoint(x: 512, y: top - halfWidth), radius: halfWidth, startAngle: 180, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: 512 + halfWidth, y: base))
        path.stroke()
    }
    arch(250, 760, width: 56)
    arch(130, 600, width: 48)
    let ground = NSBezierPath()
    ground.lineWidth = 56
    ground.lineCapStyle = .round
    ground.move(to: NSPoint(x: 210, y: 300))
    ground.line(to: NSPoint(x: 814, y: 300))
    ground.stroke()

    // The kept port: a warm light inside the tunnel.
    let glow = NSRect(x: 512 - 44, y: 370, width: 88, height: 88)
    NSGradient(colors: [NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), NSColor(red: 1, green: 0.62, blue: 0.2, alpha: 1)])!
        .draw(in: NSBezierPath(ovalIn: glow), relativeCenterPosition: NSPoint(x: 0, y: 0.3))

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
