// Draws Brim's app icon at every size macOS asks for.
// Usage: swiftc make-icon.swift -o make-icon && ./make-icon <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // The macOS icon grid: an 824-point squircle centred in 1024.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSGradient(starting: color(0x1C1C1F), ending: color(0x050506))?.draw(in: shape, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // A notch welded to the tile's right edge, with its inverse flares.
    let notch = NSBezierPath()
    let edge = tile.maxX
    let top = tile.midY + 250 * s, bottom = tile.midY - 250 * s, depth = 150 * s, flare = 70 * s
    notch.move(to: NSPoint(x: edge, y: top + flare))
    notch.curve(to: NSPoint(x: edge - flare, y: top), controlPoint1: NSPoint(x: edge, y: top + flare * 0.45),
                controlPoint2: NSPoint(x: edge - flare * 0.45, y: top))
    notch.line(to: NSPoint(x: edge - depth + 40 * s, y: top))
    notch.curve(to: NSPoint(x: edge - depth, y: top - 40 * s), controlPoint1: NSPoint(x: edge - depth + 18 * s, y: top),
                controlPoint2: NSPoint(x: edge - depth, y: top - 18 * s))
    notch.line(to: NSPoint(x: edge - depth, y: bottom + 40 * s))
    notch.curve(to: NSPoint(x: edge - depth + 40 * s, y: bottom), controlPoint1: NSPoint(x: edge - depth, y: bottom + 18 * s),
                controlPoint2: NSPoint(x: edge - depth + 18 * s, y: bottom))
    notch.line(to: NSPoint(x: edge - flare, y: bottom))
    notch.curve(to: NSPoint(x: edge, y: bottom - flare), controlPoint1: NSPoint(x: edge - flare * 0.45, y: bottom),
                controlPoint2: NSPoint(x: edge, y: bottom - flare * 0.45))
    notch.close()
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    color(0x000000).setFill()
    notch.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // The usage ring: track and a 73% arc from twelve o'clock, clockwise.
    let centre = NSPoint(x: tile.midX - 70 * s, y: tile.midY)
    let radius = 230 * s
    let track = NSBezierPath()
    track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = 62 * s
    color(0xFFFFFF, 0.14).setStroke()
    track.stroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: centre, radius: radius, startAngle: 90, endAngle: 90 - 0.73 * 360, clockwise: true)
    arc.lineWidth = 62 * s
    arc.lineCapStyle = .round
    color(0x00FF88).setStroke()
    arc.stroke()

    // A small dot at the ring's centre, like the glyph a ring carries.
    color(0xFFFFFF, 0.92).setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - 46 * s, y: centre.y - 46 * s, width: 92 * s, height: 92 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, CGFloat)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for (name, size) in sizes {
    guard let data = draw(size: size) else { fatalError("could not draw \(name)") }
    try data.write(to: output.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(sizes.count) images to \(output.path)")
