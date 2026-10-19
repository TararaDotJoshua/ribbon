// Renders Ribbon's motion graphic, frame by frame, to an H.264 MP4.
//   swiftc -O scripts/make-video.swift -o build/make-video && build/make-video media/Ribbon.mp4
//   build/make-video --still 12.5 frame.png     one frame, for checking
import AppKit
import AVFoundation

let W: CGFloat = 1920, H: CGFloat = 1080
let fps: Int32 = 60
let duration = 34.0

// MARK: - Timing

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeOutBack(_ x: Double) -> Double {
    let c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
}
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}
/// Fades in over `fade` from `a`, holds, fades out over `fade` ending at `b`.
func envelope(_ t: Double, _ a: Double, _ b: Double, fade: Double = 0.35) -> Double {
    min(easeOut(progress(t, a, a + fade)), 1 - easeInOut(progress(t, b - fade, b)))
}
func rnd(_ i: Int) -> Double {
    let x = sin(Double(i) * 12.9898) * 43758.5453
    return x - floor(x)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

let accent = NSColor(hex: 0x6E8BFF)

// MARK: - Apps and windows

enum Kind { case notes, mail, browser, code, photos, music, terminal }

struct App {
    let name: String
    let title: String
    let color: NSColor
    let kind: Kind
}

let notes = App(name: "Notes", title: "Notes — Trip ideas", color: NSColor(hex: 0xF5C451), kind: .notes)
let mail = App(name: "Mail", title: "Inbox", color: NSColor(hex: 0x4A90E2), kind: .mail)
let browser = App(name: "Browser", title: "ribbon.app", color: NSColor(hex: 0x34C3A0), kind: .browser)
let code = App(name: "Code", title: "Strip.swift", color: NSColor(hex: 0x8B6CFF), kind: .code)
let photos = App(name: "Photos", title: "Photos — Lisbon", color: NSColor(hex: 0xFF7A59), kind: .photos)
let music = App(name: "Music", title: "Now Playing", color: NSColor(hex: 0xFF4F7B), kind: .music)
let terminal = App(name: "Terminal", title: "zsh — ribbon", color: NSColor(hex: 0x2ECC71), kind: .terminal)

let stripApps = [notes, mail, browser, code, photos, music, terminal]

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

@discardableResult
func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor = .white,
              center: CGPoint, alpha: Double = 1, rounded: Bool = false, kern: CGFloat = 0) -> CGSize {
    let font = rounded ? roundedFont(size, weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let text = NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: color.withAlphaComponent(color.alphaComponent * CGFloat(alpha)), .kern: kern,
    ])
    let sz = text.size()
    text.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
    return sz
}

func fill(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
    ctx.setFillColor(color.cgColor)
    if radius > 0 {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        ctx.fillPath()
    } else {
        ctx.fill(rect)
    }
}

func drawContent(_ ctx: CGContext, _ r: CGRect, _ app: App) {
    let c = app.color
    switch app.kind {
    case .notes:
        fill(ctx, r, NSColor(hex: 0xFFFDF5))
        fill(ctx, CGRect(x: r.minX + 28, y: r.minY + 26, width: min(260, r.width * 0.55), height: 18), c, radius: 5)
        for i in 0..<18 {
            let y = r.minY + 70 + CGFloat(i) * 30
            guard y < r.maxY - 20 else { break }
            let w = (r.width - 56) * CGFloat(0.35 + 0.6 * rnd(i + 3))
            fill(ctx, CGRect(x: r.minX + 28, y: y, width: w, height: 10), NSColor(hex: 0xD9D4C4), radius: 5)
        }
    case .mail:
        fill(ctx, r, .white)
        for i in 0..<12 {
            let y = r.minY + CGFloat(i) * 70
            guard y < r.maxY - 10 else { break }
            if i == 1 { fill(ctx, CGRect(x: r.minX, y: y, width: r.width, height: 70), c.withAlphaComponent(0.12)) }
            ctx.setFillColor(NSColor(hue: CGFloat(rnd(i)), saturation: 0.45, brightness: 0.9, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: r.minX + 20, y: y + 16, width: 38, height: 38))
            fill(ctx, CGRect(x: r.minX + 72, y: y + 18, width: (r.width - 100) * 0.45, height: 11), NSColor(hex: 0x5A5D6B), radius: 5)
            fill(ctx, CGRect(x: r.minX + 72, y: y + 38, width: (r.width - 100) * CGFloat(0.5 + 0.4 * rnd(i + 7)), height: 9), NSColor(hex: 0xC9CBD3), radius: 4)
            fill(ctx, CGRect(x: r.minX + 20, y: y + 69, width: r.width - 40, height: 1), NSColor(hex: 0xEDEEF2))
        }
    case .browser:
        fill(ctx, r, .white)
        fill(ctx, CGRect(x: r.minX + 20, y: r.minY + 14, width: r.width - 40, height: 30), NSColor(hex: 0xEEF0F4), radius: 15)
        let hero = CGRect(x: r.minX + 20, y: r.minY + 60, width: r.width - 40, height: r.height * 0.42)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: hero, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c.cgColor, NSColor(hex: 0x1D5E73).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: hero.minX, y: hero.minY), end: CGPoint(x: hero.maxX, y: hero.maxY), options: [])
        ctx.restoreGState()
        fill(ctx, CGRect(x: hero.minX + 32, y: hero.midY - 22, width: hero.width * 0.5, height: 22), NSColor.white.withAlphaComponent(0.9), radius: 6)
        fill(ctx, CGRect(x: hero.minX + 32, y: hero.midY + 12, width: hero.width * 0.32, height: 14), NSColor.white.withAlphaComponent(0.6), radius: 6)
        let cardW = (r.width - 40 - 2 * 16) / 3
        for i in 0..<3 {
            let card = CGRect(x: r.minX + 20 + CGFloat(i) * (cardW + 16), y: hero.maxY + 20, width: cardW, height: min(170, r.maxY - hero.maxY - 40))
            fill(ctx, card, NSColor(hex: 0xF3F4F8), radius: 12)
            fill(ctx, CGRect(x: card.minX + 14, y: card.minY + 16, width: card.width * 0.6, height: 11), NSColor(hex: 0x8A8E9C), radius: 5)
            fill(ctx, CGRect(x: card.minX + 14, y: card.minY + 38, width: card.width * 0.8, height: 9), NSColor(hex: 0xC9CBD3), radius: 4)
        }
    case .code:
        fill(ctx, r, NSColor(hex: 0x1F2030))
        let palette = [NSColor(hex: 0xC792EA), NSColor(hex: 0x82AAFF), NSColor(hex: 0xC3E88D), NSColor(hex: 0xF78C6C), NSColor(hex: 0x89DDFF), NSColor(hex: 0x676E95)]
        for line in 0..<30 {
            let y = r.minY + 22 + CGFloat(line) * 26
            guard y < r.maxY - 16 else { break }
            fill(ctx, CGRect(x: r.minX + 14, y: y, width: 16, height: 9), NSColor(hex: 0x3B3E55), radius: 3)
            var x = r.minX + 48 + CGFloat(Int(rnd(line * 5) * 4)) * 24
            for token in 0..<(1 + Int(rnd(line * 3 + 1) * 4)) {
                let w = CGFloat(30 + rnd(line * 11 + token) * 110)
                guard x + w < r.maxX - 16 else { break }
                fill(ctx, CGRect(x: x, y: y, width: w, height: 10), palette[Int(rnd(line * 7 + token) * 6) % 6], radius: 4)
                x += w + 10
            }
        }
    case .photos:
        fill(ctx, r, NSColor(hex: 0xF7F7F9))
        let cols = max(2, Int(r.width / 150))
        let tile = (r.width - 16 - CGFloat(cols - 1) * 6) / CGFloat(cols)
        for i in 0..<(cols * 8) {
            let rect = CGRect(x: r.minX + 8 + CGFloat(i % cols) * (tile + 6), y: r.minY + 8 + CGFloat(i / cols) * (tile + 6), width: tile, height: tile)
            guard rect.minY < r.maxY else { break }
            let hue = CGFloat((0.02 + 0.6 * rnd(i * 3)).truncatingRemainder(dividingBy: 1))
            fill(ctx, rect, NSColor(hue: hue, saturation: 0.45, brightness: 0.88, alpha: 1), radius: 6)
        }
    case .music:
        fill(ctx, r, NSColor(hex: 0x18181C))
        let art = CGRect(x: r.midX - min(r.width * 0.6, 300) / 2, y: r.minY + 40, width: min(r.width * 0.6, 300), height: min(r.width * 0.6, 300))
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: art, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c.cgColor, NSColor(hex: 0xFFB347).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: art.minX, y: art.minY), end: CGPoint(x: art.maxX, y: art.maxY), options: [])
        ctx.restoreGState()
        fill(ctx, CGRect(x: art.minX, y: art.maxY + 28, width: art.width * 0.7, height: 16), NSColor.white.withAlphaComponent(0.9), radius: 6)
        fill(ctx, CGRect(x: art.minX, y: art.maxY + 54, width: art.width * 0.45, height: 12), NSColor.white.withAlphaComponent(0.45), radius: 6)
        fill(ctx, CGRect(x: art.minX, y: art.maxY + 92, width: art.width, height: 5), NSColor.white.withAlphaComponent(0.2), radius: 2.5)
        fill(ctx, CGRect(x: art.minX, y: art.maxY + 92, width: art.width * 0.38, height: 5), NSColor.white.withAlphaComponent(0.85), radius: 2.5)
        for (i, size) in [CGFloat(26), 40, 26].enumerated() {
            ctx.setFillColor(NSColor.white.withAlphaComponent(i == 1 ? 0.95 : 0.6).cgColor)
            ctx.fillEllipse(in: CGRect(x: art.midX - size / 2 + CGFloat(i - 1) * 70, y: art.maxY + 128 - size / 2 + 20, width: size, height: size))
        }
    case .terminal:
        fill(ctx, r, NSColor(hex: 0x111317))
        for line in 0..<30 {
            let y = r.minY + 20 + CGFloat(line) * 24
            guard y < r.maxY - 16 else { break }
            let prompt = line % 4 == 0
            if prompt { fill(ctx, CGRect(x: r.minX + 16, y: y, width: 12, height: 10), NSColor(hex: 0x2ECC71), radius: 3) }
            let w = (r.width - 60) * CGFloat(0.2 + 0.6 * rnd(line + 40))
            fill(ctx, CGRect(x: r.minX + (prompt ? 36 : 16), y: y, width: w, height: 10),
                 prompt ? NSColor(hex: 0xE6E6E6) : NSColor(hex: 0x7A8290), radius: 4)
        }
    }
}

let titleBarHeight: CGFloat = 36

/// One window. `mixWith` cross-fades the content to another app (tab switch).
func drawWindow(_ ctx: CGContext, _ r: CGRect, _ app: App, alpha: Double = 1, focus: Double = 0, lift: Double = 0,
                rotation: CGFloat = 0, mixWith other: App? = nil, mix: Double = 0) {
    guard alpha > 0.001, r.width > 4, r.height > 4 else { return }
    ctx.saveGState()
    if rotation != 0 {
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.rotate(by: rotation)
        ctx.translateBy(x: -r.midX, y: -r.midY)
    }
    ctx.setAlpha(CGFloat(alpha))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let radius: CGFloat = 13
    let shape = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10 + 14 * lift), blur: 26 + 30 * CGFloat(lift),
                  color: NSColor.black.withAlphaComponent(0.45 + 0.15 * lift).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor(hex: 0xF7F7FA).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: titleBarHeight)
    let body = CGRect(x: r.minX, y: bar.maxY, width: r.width, height: r.height - titleBarHeight)
    drawContent(ctx, body, app)
    if let other, mix > 0 {
        ctx.setAlpha(CGFloat(mix))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawContent(ctx, body, other)
        ctx.endTransparencyLayer()
        ctx.setAlpha(1)
    }
    fill(ctx, bar, NSColor(hex: 0xECECF1))
    fill(ctx, CGRect(x: r.minX, y: bar.maxY - 1, width: r.width, height: 1), NSColor(hex: 0xD5D6DD))
    for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(NSColor(hex: UInt32(color)).cgColor)
        ctx.fillEllipse(in: CGRect(x: r.minX + 16 + CGFloat(i) * 20, y: r.minY + 12, width: 12, height: 12))
    }
    let title = (other != nil && mix > 0.5) ? other!.title : app.title
    if r.width > 220 {
        drawText(title, size: 14, weight: .medium, color: NSColor(hex: 0x3A3A44), center: CGPoint(x: r.midX + 20, y: bar.midY))
    }
    ctx.restoreGState()

    if focus > 0.01 {
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -3, dy: -3), cornerWidth: radius + 3, cornerHeight: radius + 3, transform: nil))
        ctx.setStrokeColor(accent.withAlphaComponent(CGFloat(focus)).cgColor)
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: - Scenery

func drawBackground(_ ctx: CGContext, _ t: Double) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let base = CGGradient(colorsSpace: space, colors: [NSColor(hex: 0x17123F).cgColor, NSColor(hex: 0x0A3F52).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: W, y: H), options: [])
    let glows: [(CGFloat, CGFloat, NSColor)] = [
        (0.25 + 0.05 * CGFloat(sin(t * 0.4)), 0.3, NSColor(hex: 0x6E5BFF, alpha: 0.35)),
        (0.8 + 0.04 * CGFloat(cos(t * 0.3)), 0.75, NSColor(hex: 0x1FB5A8, alpha: 0.25)),
    ]
    for (x, y, color) in glows {
        let g = CGGradient(colorsSpace: space, colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        let center = CGPoint(x: W * x, y: H * y)
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: 700, options: [])
    }
}

let screen = CGRect(x: 240, y: 118, width: 1440, height: 810)
let menuBarHeight: CGFloat = 26
let viewport = CGRect(x: screen.minX, y: screen.minY + menuBarHeight, width: screen.width, height: screen.height - menuBarHeight)
let gap: CGFloat = 12

func drawScreen(_ ctx: CGContext, alpha: Double, status: String) {
    guard alpha > 0.001 else { return }
    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let bezel = screen.insetBy(dx: -14, dy: -14)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    fill(ctx, bezel, NSColor(hex: 0x0D0D12), radius: 28)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let wall = CGGradient(colorsSpace: space, colors: [NSColor(hex: 0x33307A).cgColor, NSColor(hex: 0x1B6D7E).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(wall, start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
    fill(ctx, CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: menuBarHeight), NSColor.black.withAlphaComponent(0.35))
    let y = screen.minY + menuBarHeight / 2
    var x = screen.minX + 22
    for (i, item) in ["Ribbon", "File", "Edit", "View", "Window"].enumerated() {
        let size = NSAttributedString(string: item, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: i == 0 ? .bold : .regular)]).size()
        drawText(item, size: 13, weight: i == 0 ? .bold : .regular, color: .white, center: CGPoint(x: x + size.width / 2, y: y))
        x += size.width + 20
    }
    drawText("9:41", size: 13, weight: .medium, color: .white, center: CGPoint(x: screen.maxX - 34, y: y))
    drawText(status, size: 13, weight: .semibold, color: .white, center: CGPoint(x: screen.maxX - 104, y: y))
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func colPx(_ ratio: Double) -> CGFloat { CGFloat(ratio) * (viewport.width - gap) - gap }
func stripRects(_ widths: [Double], scroll: CGFloat) -> [CGRect] {
    var x: CGFloat = 0
    return widths.map { ratio in
        let w = colPx(ratio)
        defer { x += w + gap }
        return CGRect(x: viewport.minX + gap + x - scroll, y: viewport.minY + gap, width: w, height: viewport.height - 2 * gap)
    }
}

/// The canvas beyond the screen, faint, under the screen; then the part on
/// screen, clipped to it.
func drawStrip(_ ctx: CGContext, rects: [CGRect], apps: [App], focus: [Double], alpha: Double = 1, screenAlpha: Double, status: String) {
    for (r, app) in zip(rects, apps) { drawWindow(ctx, r, app, alpha: 0.22 * alpha) }
    drawScreen(ctx, alpha: screenAlpha, status: status)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.clip()
    for (i, (r, app)) in zip(rects, apps).enumerated() where r.intersects(viewport) {
        drawWindow(ctx, r, app, alpha: alpha, focus: focus[i])
    }
    ctx.restoreGState()
}

let modifierNames = ["⌃": "control", "⇧": "shift", "⌥": "option", "⌘": "command"]

func drawKeys(_ ctx: CGContext, _ keys: [String], center: CGPoint, alpha: Double, pop: Double) {
    guard alpha > 0.001 else { return }
    let size: CGFloat = 62, spacing: CGFloat = 12
    let widths = keys.map { modifierNames[$0] != nil ? 112 : size }
    let total = widths.reduce(0, +) + CGFloat(keys.count - 1) * spacing
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    let scale = CGFloat(0.85 + 0.15 * easeOutBack(pop))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -center.x, y: -center.y)
    let panel = CGRect(x: center.x - total / 2 - 18, y: center.y - size / 2 - 16, width: total + 36, height: size + 32)
    fill(ctx, panel, NSColor.black.withAlphaComponent(0.55 * alpha), radius: 22)
    var x = panel.minX + 18
    for (key, width) in zip(keys, widths) {
        let r = CGRect(x: x, y: center.y - size / 2, width: width, height: size)
        fill(ctx, r.offsetBy(dx: 0, dy: 3), NSColor.black.withAlphaComponent(0.35 * alpha), radius: 12)
        fill(ctx, r, NSColor(hex: 0xF4F5F8, alpha: CGFloat(alpha)), radius: 12)
        let ink = NSColor(hex: 0x2A2B33)
        if let name = modifierNames[key] {
            drawText(key, size: 20, weight: .medium, color: ink, center: CGPoint(x: r.maxX - 18, y: r.minY + 18), alpha: alpha)
            let label = NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(CGFloat(alpha)),
            ])
            label.draw(at: CGPoint(x: r.minX + 12, y: r.maxY - 12 - label.size().height))
        } else {
            drawText(key, size: 30, weight: .medium, color: ink, center: CGPoint(x: r.midX, y: r.midY), alpha: alpha)
        }
        x += width + spacing
    }
    ctx.restoreGState()
}

func drawCaption(_ text: String, t: Double, from a: Double, to b: Double) {
    let alpha = envelope(t, a, b, fade: 0.4)
    guard alpha > 0.001 else { return }
    let rise = CGFloat(1 - easeOut(progress(t, a, a + 0.5))) * 16
    drawText(text, size: 34, weight: .semibold, color: .white, center: CGPoint(x: W / 2, y: 1004 + rise), alpha: alpha)
}

func drawCursor(_ ctx: CGContext, at p: CGPoint, alpha: Double, pressed: Double = 0) {
    guard alpha > 0.001 else { return }
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    let s = CGFloat(1.7 * (1 - 0.12 * pressed))
    ctx.scaleBy(x: s, y: s)
    let path = CGMutablePath()
    path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.5, y: 13), CGPoint(x: 7.5, y: 20),
                            CGPoint(x: 10, y: 19), CGPoint(x: 7, y: 12.5), CGPoint(x: 12.5, y: 12.5)])
    path.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: NSColor.black.withAlphaComponent(0.4 * alpha).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(alpha)).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(CGFloat(alpha)).cgColor)
    ctx.setLineWidth(1.2)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Ribbon's app icon, drawn like scripts/make-icon.swift.
func iconImage() -> NSImage {
    NSImage(size: NSSize(width: 512, height: 512), flipped: false) { _ in
        let s: CGFloat = 512
        let inset = s * 0.09
        let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let background = NSBezierPath(roundedRect: tile, xRadius: s * 0.19, yRadius: s * 0.19)
        NSGradient(starting: NSColor(red: 0.16, green: 0.12, blue: 0.38, alpha: 1),
                   ending: NSColor(red: 0.07, green: 0.42, blue: 0.55, alpha: 1))!.draw(in: background, angle: -60)
        background.addClip()
        for c in [(0.02, 0.17, 0.35), (0.23, 0.30, 1.0), (0.57, 0.22, 0.75), (0.83, 0.25, 0.35)] as [(CGFloat, CGFloat, CGFloat)] {
            let rect = NSRect(x: s * c.0, y: s * 0.24, width: s * c.1, height: s * 0.52)
            NSColor(white: 1, alpha: c.2 * 0.92).setFill()
            NSBezierPath(roundedRect: rect, xRadius: s * 0.035, yRadius: s * 0.035).fill()
            NSColor(red: 0.16, green: 0.12, blue: 0.38, alpha: c.2 * 0.25).setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - s * 0.06, width: rect.width, height: s * 0.02)).fill()
        }
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
        return true
    }
}
let icon = iconImage()

func drawIcon(center: CGPoint, size: CGFloat, alpha: Double) {
    guard alpha > 0.001 else { return }
    icon.draw(in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), from: .zero,
              operation: .sourceOver, fraction: CGFloat(alpha), respectFlipped: true, hints: nil)
}

// MARK: - Strip simulation (Ribbon's own rules: scroll just enough; pages)

struct StripState { var focus: Int; var scroll: CGFloat }

let navWidths: [Double] = [0.5, 0.33, 0.5, 0.67, 0.33, 0.5, 0.45]
let content = viewport.width - 2 * gap

func offsets(_ widths: [Double]) -> [(x: CGFloat, w: CGFloat)] {
    var x: CGFloat = 0
    return widths.map { r in let w = colPx(r); defer { x += w + gap }; return (x, w) }
}

func ensureVisible(_ s: StripState, _ widths: [Double]) -> CGFloat {
    let c = offsets(widths)[s.focus]
    if c.x < s.scroll { return c.x }
    if c.x + c.w > s.scroll + content { return c.x + c.w - content }
    return s.scroll
}

func pageRight(_ s: StripState, _ widths: [Double]) -> StripState {
    let cols = offsets(widths)
    guard let j = cols.firstIndex(where: { $0.x + $0.w > s.scroll + content + 0.5 }) else { return s }
    let end = cols.last!.x + cols.last!.w
    return StripState(focus: j, scroll: min(cols[j].x, max(end - content, s.scroll)))
}

func pageLeft(_ s: StripState, _ widths: [Double]) -> StripState {
    let cols = offsets(widths)
    guard let p = cols.lastIndex(where: { $0.x < s.scroll - 0.5 }) else { return s }
    return StripState(focus: p, scroll: max(cols[p].x + cols[p].w - content, 0))
}

/// (time, state) after each key press in the navigation scene.
let navEvents: [(Double, StripState)] = {
    var s = StripState(focus: 0, scroll: 0)
    var events: [(Double, StripState)] = []
    for t in [10.0, 11.0, 12.0] {
        s.focus += 1
        s.scroll = ensureVisible(s, navWidths)
        events.append((t, s))
    }
    s = pageRight(s, navWidths); events.append((13.6, s))
    s = pageLeft(s, navWidths); events.append((15.2, s))
    return events
}()

func navState(_ t: Double) -> (focus: Double, scroll: CGFloat) {
    var focus = 0.0, scroll: CGFloat = 0
    for (time, state) in navEvents {
        let p = easeInOut(progress(t, time, time + 0.45))
        focus = lerp(focus, Double(state.focus), p)
        scroll = lerp(scroll, state.scroll, p)
    }
    return (focus, scroll)
}

/// Width steps of the focused column (index 3) in the widths scene.
let widthEvents: [(Double, Double, String)] = [(17.8, 0.5, "½"), (18.8, 0.33, "⅓"), (20.0, 0.5, "½"), (21.0, 0.67, "⅔")]

func widthsAt(_ t: Double) -> [Double] {
    var w = navWidths
    for (time, ratio, _) in widthEvents {
        w[3] = lerp(w[3], ratio, easeInOut(progress(t, time, time + 0.4)))
    }
    return w
}

// MARK: - Scenes

func frame(_ ctx: CGContext, _ t: Double) {
    drawBackground(ctx, t)

    // A: title
    let introOut = 1 - easeInOut(progress(t, 3.4, 4.0))
    if t < 4.2 {
        let pop = easeOutBack(progress(t, 0.2, 1.1))
        drawIcon(center: CGPoint(x: W / 2, y: 420 - 30 * CGFloat(1 - introOut)), size: 250 * CGFloat(0.6 + 0.4 * pop),
                 alpha: easeOut(progress(t, 0.2, 0.8)) * introOut)
        let titleIn = easeOut(progress(t, 1.0, 1.7))
        drawText("Ribbon", size: 120, weight: .bold, center: CGPoint(x: W / 2, y: 640 + 24 * CGFloat(1 - titleIn)),
                 alpha: titleIn * introOut, rounded: true, kern: -1)
        drawText("A scrolling window canvas for macOS", size: 38, weight: .regular, color: NSColor.white.withAlphaComponent(0.8),
                 center: CGPoint(x: W / 2, y: 735), alpha: easeOut(progress(t, 1.6, 2.4)) * introOut)
    }

    // B–D: the strip
    if t >= 3.8 && t < 22.9 {
        let screenAlpha = easeOut(progress(t, 3.8, 4.4)) * (1 - easeInOut(progress(t, 22.4, 22.9)))
        if t < 9.0 {
            // B: a pile of windows lines up into the strip.
            let pile: [CGRect] = [
                CGRect(x: 330, y: 230, width: 560, height: 420), CGRect(x: 640, y: 300, width: 620, height: 440),
                CGRect(x: 980, y: 190, width: 520, height: 400), CGRect(x: 470, y: 420, width: 700, height: 420),
                CGRect(x: 1130, y: 380, width: 460, height: 460), CGRect(x: 820, y: 520, width: 520, height: 360),
                CGRect(x: 400, y: 330, width: 500, height: 380),
            ]
            let angles: [CGFloat] = [-0.05, 0.035, -0.02, 0.025, -0.04, 0.05, -0.03]
            let target = stripRects(navWidths, scroll: 0)
            var rects: [CGRect] = []
            for i in pile.indices {
                let p = easeInOut(progress(t, 5.4 + Double(i) * 0.06, 6.4 + Double(i) * 0.06))
                rects.append(lerp(pile[i], target[i], p))
            }
            // Ghosts only once lined up; the pile lives on screen.
            let lined = progress(t, 6.2, 6.8)
            for (r, app) in zip(rects, stripApps) { drawWindow(ctx, r, app, alpha: 0.22 * lined) }
            drawScreen(ctx, alpha: screenAlpha, status: "◫ 1/7")
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.clip()
            for i in rects.indices {
                let appear = easeOut(progress(t, 4.2 + Double(i) * 0.1, 4.6 + Double(i) * 0.1))
                let p = easeInOut(progress(t, 5.4 + Double(i) * 0.06, 6.4 + Double(i) * 0.06))
                let r = rects[i]
                let grow = CGFloat(0.92 + 0.08 * appear)
                let shown = CGRect(x: r.midX - r.width * grow / 2, y: r.midY - r.height * grow / 2, width: r.width * grow, height: r.height * grow)
                drawWindow(ctx, shown, stripApps[i], alpha: appear, focus: i == 0 ? progress(t, 6.6, 7.0) : 0,
                           rotation: angles[i] * CGFloat(1 - p))
            }
            ctx.restoreGState()
            drawCaption("Windows pile up.", t: t, from: 4.4, to: 5.6)
            drawCaption("Ribbon lines them up, side by side, on one endless canvas", t: t, from: 5.9, to: 8.9)
        } else {
            // C and D: navigate, then resize.
            let nav = navState(t)
            let widths = widthsAt(t)
            let rects = stripRects(widths, scroll: nav.scroll)
            let focus = stripApps.indices.map { max(0, 1 - abs(nav.focus - Double($0))) }
            let shown = Int(nav.focus.rounded())
            drawStrip(ctx, rects: rects, apps: stripApps, focus: focus, screenAlpha: screenAlpha, status: "◫ \(shown + 1)/7")

            let keyCenter = CGPoint(x: screen.midX, y: screen.maxY - 80)
            let presses: [(Double, [String])] = [
                (9.8, ["⌃", "→"]), (10.8, ["⌃", "→"]), (11.8, ["⌃", "→"]), (13.4, ["⌃", "⇧", "→"]), (15.0, ["⌃", "⇧", "←"]),
                (17.6, ["⌃", "⌥", "←"]), (18.6, ["⌃", "⌥", "←"]), (19.8, ["⌃", "⌥", "→"]), (20.8, ["⌃", "⌥", "→"]),
            ]
            for (time, keys) in presses where t >= time - 0.05 && t < time + 0.95 {
                drawKeys(ctx, keys, center: keyCenter, alpha: envelope(t, time, time + 0.9, fade: 0.15), pop: progress(t, time, time + 0.35))
            }
            // Width badge on the column being resized.
            for (time, _, label) in widthEvents {
                let a = envelope(t, time + 0.1, time + 0.95, fade: 0.2)
                guard a > 0.001 else { continue }
                let r = rects[3]
                let pill = CGRect(x: r.midX - 60, y: r.midY - 44, width: 120, height: 88)
                fill(ctx, pill, NSColor.black.withAlphaComponent(0.6 * a), radius: 22)
                drawText(label, size: 56, weight: .bold, center: CGPoint(x: pill.midX, y: pill.midY), alpha: a, rounded: true)
            }
            drawCaption("Control + ← →   the next window. The canvas scrolls just enough", t: t, from: 9.4, to: 13.2)
            drawCaption("Control + Shift + ← →   the next set of windows", t: t, from: 13.4, to: 16.9)
            drawCaption("Control + Option + ← →   step through widths. Every window keeps its own", t: t, from: 17.2, to: 22.3)
        }
    }

    // E: tab groups
    if t >= 22.4 && t < 30.4 {
        let alpha = easeOut(progress(t, 22.5, 23.1)) * (1 - easeInOut(progress(t, 29.7, 30.3)))
        let apps = [notes, browser, music]
        let home = stripRects([0.45, 0.45, 0.45], scroll: 0)
        let tabBar: CGFloat = 34
        let drop = easeInOut(progress(t, 25.4, 25.9))
        // Notes makes room for the tab bar; Music slides into the gap.
        let groupRect = CGRect(x: home[0].minX, y: home[0].minY + tabBar * CGFloat(drop), width: home[0].width,
                               height: home[0].height - tabBar * CGFloat(drop))
        let musicRect = lerp(home[2], home[1], easeInOut(progress(t, 25.6, 26.3)))

        // The browser follows the cursor by its title bar.
        let grab = CGPoint(x: home[1].midX, y: home[1].minY + titleBarHeight / 2)
        let over = CGPoint(x: home[0].midX + 40, y: home[0].midY - 120)
        let dragP = easeInOut(progress(t, 23.7, 24.7))
        let cursorDrag = CGPoint(x: lerp(grab.x, over.x, dragP), y: lerp(grab.y, over.y, dragP))
        let dragged = home[1].offsetBy(dx: cursorDrag.x - grab.x, dy: cursorDrag.y - grab.y)
        let held = t >= 23.6 && t < 25.4

        ctx.setAlpha(1)
        drawScreen(ctx, alpha: alpha, status: "◫ 1/2")
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.clip()

        // Which tab shows: Browser after the drop, Notes after the click, Browser after ⌃⌥↓.
        let toNotes = easeInOut(progress(t, 27.25, 27.45))
        let backToBrowser = easeInOut(progress(t, 28.15, 28.35))
        let notesShowing = toNotes * (1 - backToBrowser)
        if drop < 1 {
            drawWindow(ctx, groupRect, notes, alpha: alpha)
        } else {
            drawWindow(ctx, groupRect, browser, alpha: alpha, focus: 1, mixWith: notes, mix: notesShowing)
        }
        drawWindow(ctx, musicRect, music, alpha: alpha)

        // The dragged window, then merging into the group.
        if t < 25.9 {
            let lift = held ? 1.0 : 0
            let into = lerp(dragged, groupRect, drop)
            drawWindow(ctx, into, browser, alpha: alpha * (1 - drop * 0.9) * (t >= 23.6 ? 0.96 : 1), lift: lift)
        }

        // Drop highlight.
        let highlight = easeOut(progress(t, 24.95, 25.15)) * (1 - easeOut(progress(t, 25.4, 25.6)))
        if highlight > 0.001 {
            let r = home[0].insetBy(dx: 3, dy: 3)
            fill(ctx, r, accent.withAlphaComponent(0.2 * highlight), radius: 14)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.setStrokeColor(accent.withAlphaComponent(0.95 * highlight).cgColor)
            ctx.setLineWidth(4)
            ctx.strokePath()
            let pill = CGRect(x: r.midX - 110, y: r.minY + 110, width: 220, height: 54)
            fill(ctx, pill, accent.withAlphaComponent(highlight), radius: 27)
            drawText("Add as Tab", size: 22, weight: .semibold, center: CGPoint(x: pill.midX, y: pill.midY), alpha: highlight)
        }

        // Tab bar.
        if drop > 0 {
            let bar = CGRect(x: home[0].minX, y: home[0].minY - 2, width: home[0].width, height: tabBar - 4)
            let a = alpha * drop
            fill(ctx, bar, NSColor(hex: 0x24252D, alpha: 0.96 * CGFloat(a)), radius: 10)
            for (i, app) in [notes, browser].enumerated() {
                let tab = CGRect(x: bar.minX + 3 + CGFloat(i) * (bar.width - 6) / 2, y: bar.minY + 3, width: (bar.width - 6) / 2 - 2, height: bar.height - 6)
                let active = i == 0 ? notesShowing : 1 - notesShowing
                fill(ctx, tab, accent.withAlphaComponent(CGFloat(0.35 * active * a)), radius: 7)
                fill(ctx, CGRect(x: tab.minX + 10, y: tab.midY - 8, width: 16, height: 16), app.color.withAlphaComponent(CGFloat(a)), radius: 4)
                let label = NSAttributedString(string: app.name, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: active > 0.5 ? .semibold : .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(CGFloat(a * (0.6 + 0.4 * active))),
                ])
                label.draw(at: CGPoint(x: tab.minX + 34, y: tab.midY - label.size().height / 2))
            }
        }
        ctx.restoreGState()

        // Cursor: grab, drag, drop, then click the Notes tab.
        let notesTab = CGPoint(x: home[0].minX + home[0].width / 4, y: home[0].minY + 14)
        var cursor = grab
        if t >= 23.7 { cursor = cursorDrag }
        if t >= 25.4 { cursor = over }
        let toTab = easeInOut(progress(t, 26.5, 27.1))
        cursor = CGPoint(x: lerp(cursor.x, notesTab.x, toTab), y: lerp(cursor.y, notesTab.y, toTab))
        let cursorAlpha = easeOut(progress(t, 23.2, 23.5)) * (1 - easeOut(progress(t, 27.7, 28.0)))
        let pressed = max(held ? 1.0 : 0.0, envelope(t, 27.15, 27.4, fade: 0.08))
        drawCursor(ctx, at: CGPoint(x: cursor.x - 2, y: cursor.y - 2), alpha: cursorAlpha * alpha, pressed: pressed)

        if t >= 27.95 && t < 28.95 {
            drawKeys(ctx, ["⌃", "⌥", "↓"], center: CGPoint(x: screen.midX + 250, y: screen.maxY - 80),
                     alpha: envelope(t, 28.0, 28.9, fade: 0.15), pop: progress(t, 28.0, 28.35))
        }
        drawCaption("Drop one window on another to tab them, even across apps", t: t, from: 23.2, to: 26.6)
        drawCaption("Click a tab, or press Control + Option + ↑ ↓, to switch", t: t, from: 26.8, to: 29.8)
    }

    // F: outro
    if t >= 30.0 {
        let fadeAll = 1 - easeInOut(progress(t, 33.3, 34.0))
        let pop = easeOutBack(progress(t, 30.3, 31.1))
        drawIcon(center: CGPoint(x: W / 2, y: 380), size: 220 * CGFloat(0.6 + 0.4 * pop), alpha: easeOut(progress(t, 30.3, 30.8)) * fadeAll)
        let titleIn = easeOut(progress(t, 30.9, 31.5))
        drawText("Ribbon", size: 110, weight: .bold, center: CGPoint(x: W / 2, y: 580 + 20 * CGFloat(1 - titleIn)),
                 alpha: titleIn * fadeAll, rounded: true, kern: -1)
        drawText("Endless canvas  ·  Widths that stay put  ·  Tab groups", size: 32, weight: .regular,
                 color: NSColor.white.withAlphaComponent(0.85), center: CGPoint(x: W / 2, y: 672), alpha: easeOut(progress(t, 31.4, 32.0)) * fadeAll)
        drawText("Inspired by Paneru and TrellisWM", size: 22, weight: .regular, color: NSColor.white.withAlphaComponent(0.5),
                 center: CGPoint(x: W / 2, y: 750), alpha: easeOut(progress(t, 31.9, 32.5)) * fadeAll)
        if t > 33.3 {
            ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(easeInOut(progress(t, 33.3, 34.0)))).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
    }
}

// MARK: - Output

func render(into ctx: CGContext, _ t: Double) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    frame(ctx, t)
    NSGraphicsContext.current = nil
    ctx.restoreGState()
}

let args = Array(CommandLine.arguments.dropFirst())
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

if args.first == "--still", args.count == 3, let t = Double(args[1]) {
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)!
    render(into: ctx, t)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

guard let outPath = args.first else {
    print("usage: make-video <out.mp4> | --still <seconds> <out.png>")
    exit(2)
}
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(W),
    AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 16_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(W),
    kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frames = Int(duration * Double(fps))
for i in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let pixels = buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(pixels, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: Int(W), height: Int(H), bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: sRGB, bitmapInfo: bitmapInfo)!
    autoreleasepool { render(into: ctx, Double(i) / Double(fps)) }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    if i % 120 == 0 { print("frame \(i)/\(frames)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(outPath)" : "failed: \(String(describing: writer.error))")
