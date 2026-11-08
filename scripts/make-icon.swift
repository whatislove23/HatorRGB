// Renders the app icon: a dark rounded tile with an RGB-lit keyboard.
// usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Tile (macOS icon grid: 824pt tile centred in 1024).
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.20, alpha: 1),
               ending: NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.07, alpha: 1))!
        .draw(in: tilePath, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Keyboard body.
    let body = NSRect(x: 158 * s, y: 356 * s, width: 708 * s, height: 312 * s)
    NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: 48 * s, yRadius: 48 * s).fill()

    // Keycaps: 4 rows, rainbow by column, with a soft glow.
    let rows: [[CGFloat]] = [
        Array(repeating: 1, count: 10),
        Array(repeating: 1, count: 10),
        [1.5] + Array(repeating: 1, count: 7) + [1.5],
        [1.5, 1, 5, 1, 1.5],
    ]
    let unit: CGFloat = 58 * s, gap: CGFloat = 8 * s
    let left = body.minX + 28 * s
    var y = body.maxY - 28 * s - unit
    for row in rows {
        var x = left
        for w in row {
            let width = w * unit + (w - 1) * gap
            let rect = NSRect(x: x, y: y, width: width, height: unit)
            let hue = (x + width / 2 - left) / (body.width - 56 * s) * 0.85
            let color = NSColor(calibratedHue: hue, saturation: 0.85, brightness: 1, alpha: 1)
            NSGraphicsContext.current?.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = color.withAlphaComponent(0.9)
            glow.shadowBlurRadius = 22 * s
            glow.set()
            color.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10 * s, yRadius: 10 * s).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            x += width + gap
        }
        y -= unit + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try? fm.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
