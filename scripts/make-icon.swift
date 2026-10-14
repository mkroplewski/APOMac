// Renders packaging/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // macOS icon grid: 824 pt body centred in 1024 with a soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.10, green: 0.11, blue: 0.27, alpha: 1),
        NSColor(red: 0.24, green: 0.16, blue: 0.52, alpha: 1),
        NSColor(red: 0.07, green: 0.42, blue: 0.75, alpha: 1)
    ])!.draw(in: shape, angle: 60)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()

    // Grid lines.
    NSColor.white.withAlphaComponent(0.08).setStroke()
    for index in 1..<6 {
        let y = body.minY + body.height * CGFloat(index) / 6
        let line = NSBezierPath()
        line.move(to: NSPoint(x: body.minX, y: y))
        line.line(to: NSPoint(x: body.maxX, y: y))
        line.lineWidth = 3
        line.stroke()
    }

    // Slider tracks and knobs.
    let knobLevels: [CGFloat] = [0.62, 0.74, 0.46, 0.34, 0.55]
    let left = body.minX + 150
    let spacing = (body.width - 300) / CGFloat(knobLevels.count - 1)
    var knobPoints: [NSPoint] = []
    for (index, level) in knobLevels.enumerated() {
        let x = left + spacing * CGFloat(index)
        let track = NSBezierPath(roundedRect: NSRect(x: x - 9, y: body.minY + 150, width: 18, height: body.height - 300), xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent(0.16).setFill()
        track.fill()
        knobPoints.append(NSPoint(x: x, y: body.minY + 150 + (body.height - 300) * level))
    }

    // Response curve through the knobs (Catmull-Rom), with a glow.
    let curve = NSBezierPath()
    let points = [NSPoint(x: body.minX - 20, y: knobPoints[0].y - 40)] + knobPoints + [NSPoint(x: body.maxX + 20, y: knobPoints.last!.y + 30)]
    curve.move(to: points[1])
    for index in 1..<(points.count - 2) {
        let p0 = points[index - 1], p1 = points[index], p2 = points[index + 1], p3 = points[index + 2]
        curve.curve(
            to: p2,
            controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
            controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        )
    }
    curve.lineCapStyle = .round
    curve.lineJoinStyle = .round
    for (width, alpha) in [(70.0, 0.10), (44.0, 0.18), (22.0, 1.0)] {
        NSColor(red: 0.55, green: 0.90, blue: 1.0, alpha: alpha).setStroke()
        curve.lineWidth = width
        curve.stroke()
    }

    for point in knobPoints {
        let knob = NSBezierPath(ovalIn: NSRect(x: point.x - 42, y: point.y - 42, width: 84, height: 84))
        NSColor.white.setFill()
        knob.fill()
        let inner = NSBezierPath(ovalIn: NSRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40))
        NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1).setFill()
        inner.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Subtle top highlight.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rim.lineWidth = 4
    rim.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 256).write(to: root.appendingPathComponent("docs/icon.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("packaging/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote packaging/AppIcon.icns" : "iconutil failed")
