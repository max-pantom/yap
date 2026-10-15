// Yap icon, "the wave lies down into words".
// A row of engraved sound bars progressively tips over and lies flat as words, ending at a glossy caret.
// Material: pastel painted metal with fine grain, true engraving (inner shadow + lip), glossy extruded caret.
// Rendered at 2048 and downsampled for clean edges.
//   swift scripts/icon-final.swift design/icons
import AppKit
import CoreText

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "design/icons")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}

struct Palette {
    let name: String
    let top: UInt32, bottom: UInt32       // body gradient
    let ink: UInt32                        // engraved marks
    let shadow: UInt32                     // tinted shadows (never pure black on pastel)
    let lip: CGFloat                       // strength of the light lip under grooves
    let dark: Bool
}

// MARK: Geometry

/// Apple-style continuous-corner squircle (superellipse, n ≈ 5) on the macOS 1024 grid: 824pt body, 100pt margin.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = c.y + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

/// Capsule centred at `c`, length `len`, thickness `w`, rotated by `angle` (0 = horizontal).
func capsule(center c: CGPoint, length len: CGFloat, width w: CGFloat, angle: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)
    return CGPath(roundedRect: CGRect(x: -len / 2, y: -w / 2, width: len, height: w), cornerWidth: w / 2, cornerHeight: w / 2, transform: &t)
}

// MARK: Painting helpers

func linear(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], _ a: CGPoint, _ b: CGPoint, locations: [CGFloat]? = nil) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!, start: a, end: b,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func radial(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], center: CGPoint, r: CGFloat) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: r, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Shadow cast *inside* `path` (for grooves and the body's lower edge).
func innerShadow(_ ctx: CGContext, _ path: CGPath, offset: CGSize, blur: CGFloat, color: CGColor) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let outer = CGMutablePath()
    outer.addRect(path.boundingBoxOfPath.insetBy(dx: -400, dy: -400))
    outer.addPath(path)
    ctx.setShadow(offset: offset, blur: blur, color: color)
    ctx.addPath(outer); ctx.setFillColor(hex(0x000000)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

/// Fine monochrome grain.
let grain: CGImage = {
    let n = 512
    var px = [UInt8](repeating: 0, count: n * n * 4)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for i in 0..<(n * n) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let v = UInt8(truncatingIfNeeded: seed >> 56)
        px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
    }
    let c = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return c.makeImage()!
}()

/// A debossed mark: light lip on the lower edge, ink fill, shadow on the inner top wall.
func engrave(_ ctx: CGContext, _ path: CGPath, _ p: Palette, alpha: CGFloat = 1) {
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    ctx.saveGState(); ctx.translateBy(x: 0, y: -3.5)
    ctx.addPath(path); ctx.setFillColor(hex(p.dark ? 0x000000 : 0xFFFFFF, p.lip * alpha)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path); ctx.setFillColor(hex(p.ink, alpha)); ctx.fillPath()
    innerShadow(ctx, path, offset: CGSize(width: 0, height: -5), blur: 5, color: hex(0x000000, 0.55 * alpha))
    innerShadow(ctx, path, offset: CGSize(width: 0, height: 3), blur: 2, color: hex(0xFFFFFF, 0.18 * alpha))
    ctx.restoreGState()
}

// MARK: Composition

func draw(_ ctx: CGContext, _ p: Palette) {
    // Body: tinted drop shadow, gradient, grain, top-left light, inner bottom shade, rim.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: hex(p.shadow, 0.38))
    ctx.addPath(shape); ctx.setFillColor(hex(p.bottom)); ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, shape, [hex(p.top), hex(p.bottom)], CGPoint(x: 260, y: 940), CGPoint(x: 760, y: 90))
    radial(ctx, shape, [hex(0xFFFFFF, p.dark ? 0.10 : 0.30), hex(0xFFFFFF, 0)], center: CGPoint(x: 250, y: 860), r: 620)
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    ctx.setBlendMode(.softLight); ctx.setAlpha(p.dark ? 0.28 : 0.34)
    ctx.draw(grain, in: CGRect(x: 0, y: 0, width: 512, height: 512), byTiling: true)
    ctx.restoreGState()
    innerShadow(ctx, shape, offset: CGSize(width: 0, height: 10), blur: 22, color: hex(p.shadow, p.dark ? 0.5 : 0.22))
    ctx.saveGState(); ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5)))
    ctx.setStrokeColor(hex(0xFFFFFF, p.dark ? 0.16 : 0.55)); ctx.setLineWidth(3); ctx.strokePath(); ctx.restoreGState()

    // Earlier "typed" lines, cropped by the edge (the composition is bigger than the frame).
    var gx: CGFloat = 52
    for w in [170, 96, 214, 128, 190] as [CGFloat] {
        engrave(ctx, capsule(center: CGPoint(x: gx + w / 2, y: 716), length: w, width: 24, angle: 0), p, alpha: 0.3)
        gx += w + 30
    }

    // The main line: sound bars that tip over into words. Every mark rotates about its own centre on one
    // baseline (like the reference's dial ticks) and is spaced by its rotated width, so nothing collides.
    let baseline: CGFloat = 478
    let thick: CGFloat = 25
    let marks: [(length: CGFloat, angle: CGFloat)] = [   // 90° = upright sound bar, 0° = word lying on the line
        (78, 90), (150, 90), (232, 90), (172, 90), (200, 90),
        (118, 64), (84, 36), (68, 12), (48, 0), (70, 0),
    ]
    func extent(_ m: (length: CGFloat, angle: CGFloat)) -> CGFloat {
        let a = m.angle * .pi / 180
        return m.length * abs(cos(a)) + thick * abs(sin(a))
    }
    func gap(_ m: (length: CGFloat, angle: CGFloat)) -> CGFloat { m.angle >= 89 ? 14 : 16 }
    let caretW: CGFloat = 34, caretGap: CGFloat = 22
    let rowWidth = marks.reduce(0) { $0 + extent($1) + gap($1) } - gap(marks.last!) + caretGap + caretW
    if p.name == "mint" { print("row width:", Int(rowWidth), "of", Int(body.width), "→ margins", Int((body.width - rowWidth) / 2)) }
    var cursor = body.midX - rowWidth / 2 + 6          // optically centred (caret is visually light)
    for m in marks {
        let e = extent(m)
        engrave(ctx, capsule(center: CGPoint(x: cursor + e / 2, y: baseline), length: m.length, width: thick, angle: m.angle * .pi / 180), p)
        cursor += e + gap(m)
    }
    cursor -= gap(marks.last!)
    // Glossy caret, standing just after the last word.
    drawCaret(ctx, p, x: cursor + caretGap + caretW / 2, bottom: baseline - 88, top: baseline + 88, width: caretW)

    // Record light (the screen-recording half): a tiny glossy bead in a drilled socket.
    let led = CGPoint(x: 808, y: 812)
    let socket = CGPath(ellipseIn: CGRect(x: led.x - 26, y: led.y - 26, width: 52, height: 52), transform: nil)
    engrave(ctx, socket, p, alpha: 0.55)
    let bead = CGPath(ellipseIn: CGRect(x: led.x - 17, y: led.y - 17, width: 34, height: 34), transform: nil)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 5, color: hex(0x7A0F0F, 0.6))
    ctx.addPath(bead); ctx.setFillColor(hex(0xF23B3B)); ctx.fillPath(); ctx.restoreGState()
    radial(ctx, bead, [hex(0xFF8A80), hex(0xE5262B), hex(0xA30F16)], center: CGPoint(x: led.x - 6, y: led.y + 7), r: 24)
    ctx.addEllipse(in: CGRect(x: led.x - 10, y: led.y + 3, width: 11, height: 8)); ctx.setFillColor(hex(0xFFFFFF, 0.85)); ctx.fillPath()
}

func drawCaret(_ ctx: CGContext, _ p: Palette, x: CGFloat, bottom: CGFloat, top: CGFloat, width w: CGFloat) {
    let len = top - bottom
    let c = CGPoint(x: x, y: (top + bottom) / 2)
    let path = capsule(center: c, length: len, width: w, angle: .pi / 2)
    // long soft cast shadow (light from top-left) + tight contact shadow
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 22, height: -26), blur: 34, color: hex(p.shadow, p.dark ? 0.7 : 0.45))
    ctx.addPath(path); ctx.setFillColor(hex(0xFFFFFF)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 4, height: -5), blur: 6, color: hex(p.shadow, 0.55))
    ctx.addPath(path); ctx.setFillColor(hex(0xFFFFFF)); ctx.fillPath(); ctx.restoreGState()
    ctx.restoreGState()
    // cylinder shading across the width
    linear(ctx, path, [hex(0xFFFFFF), hex(0xF3F7F8), hex(0xD5DFE3), hex(0xB9C7CC)],
           CGPoint(x: x - w / 2, y: c.y), CGPoint(x: x + w / 2, y: c.y), locations: [0, 0.35, 0.75, 1])
    // end caps catch light
    radial(ctx, path, [hex(0xFFFFFF, 0.9), hex(0xFFFFFF, 0)], center: CGPoint(x: x - 4, y: top - w / 2), r: w * 0.7)
    // inner groove
    let groove = capsule(center: CGPoint(x: x + 1, y: c.y), length: len - w * 0.9, width: w * 0.34, angle: .pi / 2)
    linear(ctx, groove, [hex(0xC3D1D6), hex(0xEEF3F5)], CGPoint(x: x - w * 0.17, y: c.y), CGPoint(x: x + w * 0.17, y: c.y))
    // specular stripe
    ctx.addPath(capsule(center: CGPoint(x: x - w * 0.27, y: c.y + 4), length: len - w * 1.2, width: w * 0.1, angle: .pi / 2))
    ctx.setFillColor(hex(0xFFFFFF, 0.95)); ctx.fillPath()
    // rim
    ctx.addPath(path); ctx.setStrokeColor(hex(0xFFFFFF, 0.7)); ctx.setLineWidth(1.5); ctx.strokePath()
}

let palettes: [Palette] = [
    .init(name: "mint",  top: 0xC4F5F0, bottom: 0x86D8D6, ink: 0x22737A, shadow: 0x1F7A80, lip: 0.75, dark: false),
    .init(name: "clay",  top: 0xFFE3D2, bottom: 0xF2AE93, ink: 0x8A3A26, shadow: 0xA4482F, lip: 0.7,  dark: false),
    // 4. dark: etched marks catch light (lighter than the metal), like engraved anodised aluminium
    .init(name: "graphite", top: 0x474C55, bottom: 0x1B1D22, ink: 0xA9B2BE, shadow: 0x000000, lip: 0.0, dark: true),
]

func render(_ p: Palette, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.interpolationQuality = .high
    g.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(g.cgContext, p)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func downsample(_ rep: NSBitmapImageRep, to size: Int) -> NSBitmapImageRep {
    let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)); img.addRepresentation(rep)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current!.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return out
}

for p in palettes {
    let big = downsample(render(p, size: 2048), to: 1024)
    try big.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("yap-\(p.name).png"))
}

// Presentation sheet: hero size + Dock (128) + Finder (64) + menu (32) + 16, on light and dark backgrounds.
let W: CGFloat = 1500, H: CGFloat = 1050
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
NSColor(calibratedWhite: 0.11, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: 230).fill()
for (i, p) in palettes.enumerated() {
    let img = NSImage(contentsOf: outDir.appendingPathComponent("yap-\(p.name).png"))!
    let x = 40 + CGFloat(i) * 490
    img.draw(in: NSRect(x: x, y: 330, width: 440, height: 440))
    (p.name as NSString).draw(at: NSPoint(x: x + 190, y: 290), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold)])
    var sx = x + 40
    for s in [128, 64, 32, 16] as [CGFloat] {
        img.draw(in: NSRect(x: sx, y: 800 + (128 - s) / 2, width: s, height: s))
        img.draw(in: NSRect(x: sx, y: 50 + (128 - s) / 2, width: s, height: s))
        sx += s + 28
    }
}
NSGraphicsContext.restoreGraphicsState()
try sheet.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("yap-final-sheet.png"))
print("done")
