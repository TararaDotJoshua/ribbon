// Draws Ribbon's app icon: a strip of windows sliding past a viewport.
// usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let background = NSBezierPath(roundedRect: tile, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(starting: NSColor(red: 0.16, green: 0.12, blue: 0.38, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.42, blue: 0.55, alpha: 1))!.draw(in: background, angle: -60)
    background.addClip()
    // Columns of different widths; the outer ones run off the edges.
    let columns: [(x: CGFloat, w: CGFloat, alpha: CGFloat)] = [
        (0.02, 0.17, 0.35), (0.23, 0.30, 1.0), (0.57, 0.22, 0.75), (0.83, 0.25, 0.35),
    ]
    for c in columns {
        let rect = NSRect(x: s * c.x, y: s * 0.24, width: s * c.w, height: s * 0.52)
        NSColor(white: 1, alpha: c.alpha * 0.92).setFill()
        NSBezierPath(roundedRect: rect, xRadius: s * 0.035, yRadius: s * 0.035).fill()
        NSColor(red: 0.16, green: 0.12, blue: 0.38, alpha: c.alpha * 0.25).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - s * 0.06, width: rect.width, height: s * 0.02)).fill()
    }
    // Arrows under the strip: it scrolls.
    NSColor(white: 1, alpha: 0.85).setFill()
    for (x, dir) in [(0.40 as CGFloat, -1 as CGFloat), (0.60, 1)] {
        let p = NSBezierPath()
        let cx = s * x, cy = s * 0.15, h = s * 0.045
        p.move(to: NSPoint(x: cx + dir * h, y: cy))
        p.line(to: NSPoint(x: cx - dir * h, y: cy + h))
        p.line(to: NSPoint(x: cx - dir * h, y: cy - h))
        p.close()
        p.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
