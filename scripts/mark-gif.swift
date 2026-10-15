// Renders the Yap mark's loop to an animated GIF from design/mark/mark-config.json (the Mark Lab settings),
// using the app's construction: rings → blur → threshold (liquid joins) → clipped to the ball → crisp outline.
//   swift scripts/mark-gif.swift <out.gif> <ink hex> <background hex> [size=320] [fps=25]
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let out = URL(fileURLWithPath: a[1])
func color(_ hex: String) -> CGColor {
    let v = UInt32(hex.dropFirst(hex.hasPrefix("#") ? 1 : 0), radix: 16)!
    return CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
let ink = color(a[2]), bg = color(a[3])
let side = a.count > 4 ? Int(a[4])! : 320
let fps = a.count > 5 ? Double(a[5])! : 25

// MARK: Config

struct Config: Decodable {
    let ease: [Double]; let holdMs: Double; let moveMs: Double
    let stroke: CGFloat; let rim: CGFloat; let fillet: CGFloat; let fullness: CGFloat
    let keys: [[[CGFloat]]]
}
let cfgURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../design/mark/mark-config.json")
let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: cfgURL))
let keys = cfg.keys.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }

func match(_ p: [CGPoint], _ q: [CGPoint]) -> [CGPoint] {
    let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    return perms.map { $0.map { q[$0] } }.min { x, y in
        zip(p, x).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) } < zip(p, y).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
    }!
}
var chain = [keys[0]]
for k in keys.dropFirst() + [keys[0]] { chain.append(match(chain.last!, k)) }

func bezier(_ x: Double) -> Double {
    let (x1, y1, x2, y2) = (cfg.ease[0], cfg.ease[1], cfg.ease[2], cfg.ease[3])
    func f(_ p: Double, _ q: Double, _ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * p + 3 * (1 - t) * t * t * q + t * t * t }
    var lo = 0.0, hi = 1.0
    for _ in 0..<30 { let m = (lo + hi) / 2; if f(x1, x2, m) < x { lo = m } else { hi = m } }
    return f(y1, y2, (lo + hi) / 2)
}
let hold = cfg.holdMs / 1000, move = cfg.moveMs / 1000, seg = hold + move
let loop = seg * Double(chain.count - 1)

func rings(_ t: Double) -> [CGPoint] {
    let i = min(chain.count - 2, Int(t / seg)), local = t - Double(i) * seg
    let e = local < hold ? 0 : bezier((local - hold) / move)
    return zip(chain[i], chain[i + 1]).map { p, q in CGPoint(x: p.x + (q.x - p.x) * e, y: p.y + (q.y - p.y) * e) }
}

// MARK: Render

let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])   // pass ink colours through exactly
let gray = CGColorSpaceCreateDeviceGray(), rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ball = CGFloat(side) * 0.82, origin = (CGFloat(side) - ball) / 2, s = ball / 300

func frame(_ r: [CGPoint]) -> CGImage {
    let W = side
    let g = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    g.setFillColor(gray: 1, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: W, height: W))
    g.setStrokeColor(gray: 0, alpha: 1); g.setLineWidth(cfg.stroke * s)
    for p in [CGPoint.zero] + r {
        g.strokeEllipse(in: CGRect(x: origin + (150 + p.x - 145) * s, y: origin + (150 - p.y - 145) * s, width: 290 * s, height: 290 * s))
    }
    let k: CGFloat = 48
    let inkC = CIColor(cgColor: ink)
    let img = CIImage(cgImage: g.makeImage()!).clampedToExtent().applyingGaussianBlur(sigma: Double(cfg.fillet * s))
        .cropped(to: CGRect(x: 0, y: 0, width: W, height: W))
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: -k, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: inkC.red, y: inkC.green, z: inkC.blue, w: k * cfg.fullness + 0.5),
        ]).applyingFilter("CIColorClamp").premultiplyingAlpha()
    let liquid = ci.createCGImage(img, from: CGRect(x: 0, y: 0, width: W, height: W))!
    let o = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0, space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    o.setFillColor(bg); o.fill(CGRect(x: 0, y: 0, width: W, height: W))
    o.saveGState(); o.addEllipse(in: CGRect(x: origin, y: origin, width: ball, height: ball)); o.clip()
    o.draw(liquid, in: CGRect(x: 0, y: 0, width: W, height: W)); o.restoreGState()
    o.setStrokeColor(ink); o.setLineWidth(cfg.rim * s)
    o.strokeEllipse(in: CGRect(x: origin + cfg.rim * s / 2, y: origin + cfg.rim * s / 2, width: ball - cfg.rim * s, height: ball - cfg.rim * s))
    return o.makeImage()!
}

// MARK: GIF

let count = Int(loop * fps)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1 / fps, kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
for n in 0..<count { CGImageDestinationAddImage(dest, frame(rings(Double(n) / fps)), delay) }
CGImageDestinationFinalize(dest)
let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
print("wrote \(out.lastPathComponent): \(count) frames, \(String(format: "%.1f", loop))s loop, \(bytes / 1024) KB")
