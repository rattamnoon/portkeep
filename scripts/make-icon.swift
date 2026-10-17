// Draws the Portkeep app icon and writes App/Resources/Assets.xcassets/AppIcon.appiconset
// and docs/images/icon.png. Run from the repo root: swift scripts/make-icon.swift
//
// Monochrome: a graphite squircle holding the "Port" mark, two square brackets around a dot,
// a port held open.
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
    NSGradient(colors: [NSColor(srgbRed: 0x34 / 255, green: 0x34 / 255, blue: 0x3a / 255, alpha: 1),
                        NSColor(srgbRed: 0x0c / 255, green: 0x0c / 255, blue: 0x0e / 255, alpha: 1)])!
        .draw(in: squircle, angle: -90)

    // A faint 3 px sheen just inside the edge, fading out by mid height.
    ctx.saveGState()
    squircle.addClip()
    ctx.addPath(squircle.cgPath)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)])!
        .draw(from: NSPoint(x: 0, y: body.maxY), to: NSPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // The mark: two square brackets holding a dot. Symmetric about y = 512, so the SVG
    // coordinates read the same with Core Graphics' y axis.
    let ink = NSColor(srgbRed: 0xf1 / 255, green: 0xf1 / 255, blue: 0xf4 / 255, alpha: 1)
    let brackets = NSBezierPath()
    brackets.lineWidth = 58
    brackets.lineCapStyle = .round
    brackets.lineJoinStyle = .round
    for (outer, inner) in [(CGFloat(330), CGFloat(418)), (694, 606)] {
        brackets.move(to: NSPoint(x: inner, y: 318))
        brackets.line(to: NSPoint(x: outer, y: 318))
        brackets.line(to: NSPoint(x: outer, y: 706))
        brackets.line(to: NSPoint(x: inner, y: 706))
    }
    ink.set()
    brackets.stroke()
    NSBezierPath(ovalIn: NSRect(x: 512 - 62, y: 512 - 62, width: 124, height: 124)).fill()

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
try render(512).write(to: URL(fileURLWithPath: "docs/images/icon.png"))
print("wrote \(images.count) icons to \(set.path) and docs/images/icon.png")
