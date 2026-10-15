// Renders the Yap mark's five state animations side by side (startup, listening, thinking, pasted, recording):
// top row the mark as users see it, bottom row the construction: the three hidden rings, their centres and the
// ball boundary. Uses the app's motion rules and design/mark/mark-config.json.
//   swift scripts/mark-states-video.swift out.mp4 [seconds=9]
import AppKit
import AVFoundation
import CoreImage

let args = CommandLine.arguments
let outURL = URL(fileURLWithPath: args[1])
let seconds = args.count > 2 ? Double(args[2])! : 9
let fps = 60.0

// MARK: Config & motion (mirrors MarkMotion in the app)

struct Config: Decodable {
    let ease: [Double]; let holdMs: Double; let moveMs: Double
    let stroke: CGFloat; let rim: CGFloat; let fillet: CGFloat; let fullness: CGFloat
    let keys: [[[CGFloat]]]
    struct States: Decodable { let idleDrift: CGFloat; let listenBase: Double; let listenMax: Double; let thinkSpeed: Double
                               let pasteMs: Double; let startMs: Double; let recPulseMs: Double }
    let states: States
}
let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("../design/mark/mark-config.json")))
let keys = cfg.keys.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }

func perm(_ a: [CGPoint], _ b: [CGPoint]) -> [Int] {
    [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]].min { x, y in
        zip(a, x).reduce(0) { $0 + hypot($1.0.x - b[$1.1].x, $1.0.y - b[$1.1].y) } <
        zip(a, y).reduce(0) { $0 + hypot($1.0.x - b[$1.1].x, $1.0.y - b[$1.1].y) }
    }!
}
func match(_ a: [CGPoint], _ b: [CGPoint]) -> [CGPoint] { perm(a, b).map { b[$0] } }
var chain = [keys[0]]
for k in keys.dropFirst() + [keys[0]] { chain.append(match(chain.last!, k)) }
let splinePrev = match(chain[0], keys[keys.count - 1]), splineNext = match(chain[chain.count - 1], chain[1])

func bezier(_ c: (Double, Double, Double, Double), _ x: Double) -> Double {
    if x <= 0 { return 0 }; if x >= 1 { return 1 }
    func f(_ p: Double, _ q: Double, _ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * p + 3 * (1 - t) * t * t * q + t * t * t }
    var lo = 0.0, hi = 1.0
    for _ in 0..<30 { let m = (lo + hi) / 2; if f(c.0, c.2, m) < x { lo = m } else { hi = m } }
    return f(c.1, c.3, (lo + hi) / 2)
}
let ease = (cfg.ease[0], cfg.ease[1], cfg.ease[2], cfg.ease[3]), easeOut = (0.23, 1.0, 0.32, 1.0)
let hold = cfg.holdMs / 1000, move = cfg.moveMs / 1000, seg = hold + move
func lerp(_ a: [CGPoint], _ b: [CGPoint], _ e: Double) -> [CGPoint] { zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * e, y: $0.y + ($1.y - $0.y) * e) } }

func loopRings(_ t: Double) -> [CGPoint] {
    let L = seg * Double(chain.count - 1), u = t.truncatingRemainder(dividingBy: L)
    let i = min(chain.count - 2, Int(u / seg)), local = u - Double(i) * seg
    return lerp(chain[i], chain[i + 1], local < hold ? 0 : bezier(ease, (local - hold) / move))
}
func splineRings(_ t: Double) -> [CGPoint] {
    let n = chain.count - 1, L = seg * Double(n), u = t.truncatingRemainder(dividingBy: L)
    let i = min(n - 1, Int(u / seg)), x = CGFloat((u - Double(i) * seg) / seg)
    let p0 = i == 0 ? splinePrev : chain[i - 1], p1 = chain[i], p2 = chain[i + 1], p3 = i + 2 <= n ? chain[i + 2] : splineNext
    func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
        0.5 * ((2 * b) + (-a + c) * x + (2 * a - 5 * b + 4 * c - d) * x * x + (-a + 3 * b - 3 * c + d) * x * x * x)
    }
    return (0..<3).map { CGPoint(x: cr(p0[$0].x, p1[$0].x, p2[$0].x, p3[$0].x), y: cr(p0[$0].y, p1[$0].y, p2[$0].y, p3[$0].y)) }
}

struct Pose { var rings: [CGPoint]; var rim: CGFloat = 1; var alpha: CGFloat = 1; var scale: CGFloat = 1; var red = false }

// Stateful simulations, stepped once per frame.
var listenTime = 0.0, listenSpeed = cfg.states.listenBase, voice = 0.0
func listening(_ t: Double, _ dt: Double) -> Pose {
    let syl = max(0, sin(t * 13)), word = sin(t * 2.3) > -0.35 ? 1.0 : 0.05            // simulated speech
    voice += (0.15 + 0.75 * syl * word - voice) * min(1, dt * 4)
    let wanted = cfg.states.listenBase + (cfg.states.listenMax - cfg.states.listenBase) * min(1, voice * 1.4)
    listenSpeed += (wanted - listenSpeed) * min(1, dt * 2.2)
    listenTime += dt * listenSpeed
    return Pose(rings: splineRings(listenTime))
}
func thinking(_ t: Double) -> Pose { Pose(rings: loopRings(t * cfg.states.thinkSpeed)) }
func startup(_ t: Double) -> Pose {
    let period = 3.0, local = t.truncatingRemainder(dividingBy: period)
    let p = min(1, local / (cfg.states.startMs / 1000)), e = bezier(easeOut, p)
    let rings = keys[0].enumerated().map { i, k -> CGPoint in
        let ang = atan2(k.y == 0 ? -1 : k.y, k.x == 0 ? 0.001 : k.x) + Double(i) * 0.4
        return CGPoint(x: k.x + (cos(ang) * 330 - k.x) * (1 - e), y: k.y + (sin(ang) * 330 - k.y) * (1 - e))
    }
    return Pose(rings: rings, rim: CGFloat(bezier(easeOut, min(1, p * 1.25))))
}
func pasted(_ t: Double) -> Pose {
    let period = 1.6, n = Int(t / period), local = t - Double(n) * period
    let from = chain[n % (chain.count - 1)], to = chain[n % (chain.count - 1) + 1]
    return Pose(rings: lerp(from, to, bezier(easeOut, min(1, local / (cfg.states.pasteMs / 1000)))))
}
func recording(_ t: Double) -> Pose {
    let pulse = 0.5 + 0.5 * cos(t / (cfg.states.recPulseMs / 1000) * 2 * .pi)
    let amt = cfg.states.idleDrift * 0.6
    let rings = keys[0].enumerated().map { i, p in
        CGPoint(x: p.x + amt * sin(t * 0.9 + Double(i) * 2.1), y: p.y + amt * cos(t * 0.7 + Double(i) * 1.7)) }
    return Pose(rings: rings, alpha: 0.78 + 0.22 * pulse, scale: 1 + 0.015 * pulse, red: true)
}

// MARK: Drawing

let W = 1280, H = 720, cols = 5
let cs = CGColorSpace(name: CGColorSpace.sRGB)!, gray = CGColorSpaceCreateDeviceGray()
let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
let ringColors: [CGColor] = [
    CGColor(srgbRed: 0.95, green: 0.45, blue: 0.20, alpha: 1), CGColor(srgbRed: 0.18, green: 0.52, blue: 0.95, alpha: 1),
    CGColor(srgbRed: 0.20, green: 0.70, blue: 0.42, alpha: 1)]

/// The mark (liquid joins) as an image of `px` pixels with the ball radius `R` px, centred.
func markImage(_ pose: Pose, px: Int, R: CGFloat, ink: CGColor) -> CGImage {
    let s = R / 150 * pose.scale, c = CGFloat(px) / 2
    let g = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    g.setFillColor(gray: 1, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: px, height: px))
    g.setStrokeColor(gray: 0, alpha: 1); g.setLineWidth(cfg.stroke * s)
    for p in [CGPoint.zero] + pose.rings { g.strokeEllipse(in: CGRect(x: c + (p.x - 145) * s, y: c - (p.y + 145) * s, width: 290 * s, height: 290 * s)) }
    let k: CGFloat = 48, ic = CIColor(cgColor: ink)
    let img = CIImage(cgImage: g.makeImage()!).clampedToExtent().applyingGaussianBlur(sigma: Double(cfg.fillet * s))
        .cropped(to: CGRect(x: 0, y: 0, width: px, height: px))
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: -k, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: ic.red, y: ic.green, z: ic.blue, w: k * cfg.fullness + 0.5)])
        .applyingFilter("CIColorClamp").premultiplyingAlpha()
    let liquid = ci.createCGImage(img, from: CGRect(x: 0, y: 0, width: px, height: px))!
    let o = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    o.setAlpha(pose.alpha); o.beginTransparencyLayer(auxiliaryInfo: nil)
    let Rs = R * pose.scale
    o.saveGState(); o.addEllipse(in: CGRect(x: c - Rs, y: c - Rs, width: 2 * Rs, height: 2 * Rs)); o.clip()
    o.draw(liquid, in: CGRect(x: 0, y: 0, width: px, height: px)); o.restoreGState()
    o.setStrokeColor(ink); o.setLineWidth(cfg.rim * s); o.setLineCap(.round)
    o.addArc(center: CGPoint(x: c, y: c), radius: Rs - cfg.rim * s / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * pose.rim, clockwise: true)
    o.strokePath(); o.endTransparencyLayer()
    return o.makeImage()!
}

func label(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: Bool = true) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let w = (text as NSString).size(withAttributes: attrs).width
    (text as NSString).draw(at: NSPoint(x: center ? p.x - w / 2 : p.x, y: p.y), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
}

let names = ["Startup", "Listening", "Thinking", "Pasted", "Recording"]
let notes = ["rings slide in, outline draws on", "speed follows your voice", "steady loop through 5 frames", "one quick roll, then settle", "red, slow pulse"]
let ink = CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1), red = CGColor(srgbRed: 0.9, green: 0.22, blue: 0.23, alpha: 1)
let colW = CGFloat(W) / CGFloat(cols)

func frame(_ t: Double, _ dt: Double) -> CGImage {
    let poses = [startup(t), listening(t, dt), thinking(t), pasted(t), recording(t)]
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // bottom band for the construction row
    ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: 330))
    label(ctx, "The mark", at: CGPoint(x: 28, y: 676), size: 18, weight: .bold, color: .black, center: false)
    label(ctx, "Where the rings are", at: CGPoint(x: 28, y: 292), size: 18, weight: .bold, color: .black, center: false)
    for (i, pose) in poses.enumerated() {
        let cx = colW * (CGFloat(i) + 0.5)
        // Top: the mark as users see it.
        let top = markImage(pose, px: 220, R: 72, ink: pose.red ? red : ink)
        ctx.draw(top, in: CGRect(x: cx - 110, y: 430, width: 220, height: 220))
        label(ctx, names[i], at: CGPoint(x: cx, y: 400), size: 17, weight: .semibold, color: .black)
        label(ctx, notes[i], at: CGPoint(x: cx, y: 378), size: 12.5, weight: .regular, color: NSColor(white: 0.35, alpha: 1))
        // Bottom: construction. Small ball, the full rings (they extend outside it), and their centres.
        let R: CGFloat = 52, s = R / 150, cy: CGFloat = 170
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))                                          // the ball's face
        ctx.fillEllipse(in: CGRect(x: cx - R, y: cy - R, width: 2 * R, height: 2 * R))
        let faded = Pose(rings: pose.rings, rim: pose.rim, alpha: 0.22, scale: pose.scale, red: pose.red)
        let small = markImage(faded, px: 240, R: R, ink: pose.red ? red : ink)
        ctx.draw(small, in: CGRect(x: cx - 120, y: cy - 120, width: 240, height: 240))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: cx - colW / 2 + 6, y: 36, width: colW - 12, height: 274))
        ctx.setLineDash(phase: 0, lengths: [3, 3]); ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: cx - R + 0.5, y: cy - R + 0.5, width: 2 * R - 1, height: 2 * R - 1))     // the ball
        ctx.setLineDash(phase: 0, lengths: [])
        for (r, p) in pose.rings.enumerated() {
            let c = CGPoint(x: cx + p.x * s, y: cy - p.y * s), rr = 145 * s
            ctx.setStrokeColor(ringColors[r].copy(alpha: 0.9)!); ctx.setLineWidth(1.6)
            ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
            ctx.setFillColor(ringColors[r]); ctx.fillEllipse(in: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7))
        }
        ctx.restoreGState()
    }
    label(ctx, "Ball outline (dashed) + three rings the same size, sliding. Their seams are where they cross the ball.",
          at: CGPoint(x: CGFloat(W) / 2, y: 18), size: 12.5, weight: .regular, color: NSColor(white: 0.3, alpha: 1))
    return ctx.makeImage()!
}

// MARK: Encode

try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000]])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
let count = Int(seconds * fps)
for n in 0..<count {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    let img = frame(Double(n) / fps, 1 / fps)
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let c = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!),
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
print("wrote \(outURL.lastPathComponent): \(count) frames, \(seconds)s, status \(writer.status.rawValue)")
