import AppKit

// Renders the QuotaMeter app icon (two quota rings on a graphite tile)
// into an .iconset directory passed as argv[1].
let outDir = CommandLine.arguments[1]

func render(px: Int, path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let body = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.045, dy: s * 0.045),
                            xRadius: s * 0.225, yRadius: s * 0.225)
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1),
    ])
    grad?.draw(in: body, angle: -90)
    func ring(cx: CGFloat, frac: CGFloat, color: NSColor) {
        let center = NSPoint(x: cx * s, y: 0.5 * s)
        let radius = 0.20 * s
        let lw = 0.072 * s
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lw
        NSColor(white: 1, alpha: 0.14).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - 360 * frac, clockwise: true)
        arc.lineWidth = lw
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
    ring(cx: 0.36, frac: 0.74, color: NSColor(calibratedRed: 0.18, green: 0.83, blue: 0.75, alpha: 1))
    ring(cx: 0.65, frac: 0.51, color: NSColor(calibratedRed: 0.39, green: 0.82, blue: 1.0, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    render(px: px, path: outDir + "/" + name + ".png")
}
print("iconset rendered")
