// Renders the app icon to Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift   (run from the repo root)
import AppKit

let canvas: CGFloat = 1024
// macOS icon grid: 824 pt body centered on a 1024 canvas, ~185 pt corner radius.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let accent = color(0.36, 0.62, 1.0)
let danger = color(1.0, 0.36, 0.40)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)

    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow + background gradient.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(color(0.06, 0.07, 0.09))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: nil,
                        colors: [color(0.13, 0.15, 0.20), color(0.05, 0.055, 0.07)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Faint horizontal gridlines.
    ctx.setStrokeColor(color(1, 1, 1, 0.06))
    ctx.setLineWidth(4)
    for y in stride(from: CGFloat(300), through: 700, by: 133) {
        ctx.move(to: CGPoint(x: 160, y: y))
        ctx.addLine(to: CGPoint(x: 864, y: y))
    }
    ctx.strokePath()

    // Frame-time trace: steady with one spike.
    let xs: [CGFloat] = [80, 260, 340, 420, 470, 520, 570, 650, 740, 944]
    let ys: [CGFloat] = [430, 445, 420, 440, 640, 400, 435, 425, 445, 430]
    let line = CGMutablePath()
    line.move(to: CGPoint(x: xs[0], y: ys[0]))
    for i in 1..<xs.count { line.addLine(to: CGPoint(x: xs[i], y: ys[i])) }

    // Area under the trace.
    let area = line.mutableCopy()!
    area.addLine(to: CGPoint(x: 944, y: 100))
    area.addLine(to: CGPoint(x: 80, y: 100))
    area.closeSubpath()
    ctx.saveGState()
    ctx.addPath(area)
    ctx.clip()
    let fill = CGGradient(colorsSpace: nil,
                          colors: [accent.copy(alpha: 0.35)!, accent.copy(alpha: 0)!] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 512, y: 640), end: CGPoint(x: 512, y: 160), options: [])
    ctx.restoreGState()

    // Glowing line.
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: accent)
    ctx.addPath(line)
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(26)
    ctx.strokePath()
    ctx.restoreGState()

    // Record dot.
    let dot = CGRect(x: 700, y: 700, width: 110, height: 110)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: danger)
    ctx.setFillColor(danger)
    ctx.fillEllipse(in: dot)
    ctx.restoreGState()
    ctx.restoreGState()

    // Hairline edge highlight.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: radius - 2, cornerHeight: radius - 2,
                       transform: nil))
    ctx.setStrokeColor(color(1, 1, 1, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try render(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
