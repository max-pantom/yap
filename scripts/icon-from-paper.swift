// Renders the Paper icon designs onto the macOS icon grid (824pt squircle in a 1024 canvas).
// Interim static icon until the Liquid Glass .icon (Icon Composer + Xcode 26 actool) can be compiled.
//   swift scripts/icon-from-paper.swift design/icon-glass
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath(), a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi, ct = cos(t), st = sin(t)
        let pt = CGPoint(x: c.x + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n), y: c.y + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath(); return p
}

struct Variant { let name: String; let bg: NSColor; let mark: String; let inner: (offsetY: CGFloat, blur: CGFloat, alpha: CGFloat) }
let variants = [
    Variant(name: "light", bg: NSColor(srgbRed: 0xED / 255.0, green: 0xED / 255.0, blue: 0xED / 255.0, alpha: 1), mark: "mark-black.svg", inner: (-2, 58.5, 0.10)),
    Variant(name: "dark", bg: .black, mark: "mark-white.svg", inner: (5, 15.5, 0.25)),
    Variant(name: "yellow", bg: NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1), mark: "mark-black.svg", inner: (-2, 58.5, 0.10)),
]

func render(_ v: Variant) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let shape = squircle(body)
    // macOS drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape); ctx.setFillColor(v.bg.cgColor); ctx.fillPath()
    ctx.restoreGState()
    // inner shadow from the Paper design (CSS inset shadow; 160pt tile scaled to 824)
    let k: CGFloat = 824 / 160
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    let ring = CGMutablePath(); ring.addRect(body.insetBy(dx: -300, dy: -300)); ring.addPath(shape)
    ctx.setShadow(offset: CGSize(width: 0, height: -v.inner.offsetY * k), blur: v.inner.blur * k * 0.5, color: NSColor.black.withAlphaComponent(v.inner.alpha).cgColor)
    ctx.addPath(ring); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    // the mark (its SVG is laid out on the same tile, so it fills the body rect)
    if let mark = NSImage(contentsOf: dir.appendingPathComponent(v.mark)) {
        mark.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for v in variants {
    try render(v).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon-\(v.name).png"))
}
print("rendered", variants.map(\.name))
