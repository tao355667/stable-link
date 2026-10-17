import AppKit

// Native drawing only: no external artwork or runtime asset dependency.
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

func drawIcon(pixels: Int, path: String) throws {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()

    let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                                  xRadius: 194, yRadius: 194)
    NSGradient(starting: NSColor(red: 0.10, green: 0.20, blue: 0.30, alpha: 1),
               ending: NSColor(red: 0.035, green: 0.08, blue: 0.16, alpha: 1))!.draw(in: background, angle: 90)

    let cyan = NSColor(red: 0.22, green: 0.88, blue: 0.86, alpha: 1)
    let soft = NSColor(red: 0.70, green: 0.96, blue: 0.94, alpha: 1)
    let route = NSBezierPath()
    route.move(to: NSPoint(x: 290, y: 332))
    route.line(to: NSPoint(x: 466, y: 632))
    route.curve(to: NSPoint(x: 559, y: 632), controlPoint1: NSPoint(x: 489, y: 675), controlPoint2: NSPoint(x: 535, y: 675))
    route.line(to: NSPoint(x: 738, y: 332))
    route.lineWidth = 52
    route.lineCapStyle = .round
    route.lineJoinStyle = .round
    cyan.setStroke()
    route.stroke()

    let bridge = NSBezierPath()
    bridge.move(to: NSPoint(x: 375, y: 475))
    bridge.line(to: NSPoint(x: 645, y: 475))
    bridge.lineWidth = 40
    bridge.lineCapStyle = .round
    soft.setStroke()
    bridge.stroke()

    for point in [NSPoint(x: 290, y: 332), NSPoint(x: 513, y: 660), NSPoint(x: 738, y: 332)] {
        let halo = NSBezierPath(ovalIn: NSRect(x: point.x - 70, y: point.y - 70, width: 140, height: 140))
        NSColor(red: 0.05, green: 0.14, blue: 0.23, alpha: 1).setFill()
        halo.fill()
        let node = NSBezierPath(ovalIn: NSRect(x: point.x - 45, y: point.y - 45, width: 90, height: 90))
        soft.setFill()
        node.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size, path: "\(destination)/icon_\(size)x\(size).png")
    try drawIcon(pixels: size * 2, path: "\(destination)/icon_\(size)x\(size)@2x.png")
}
