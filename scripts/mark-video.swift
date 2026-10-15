// Renders the Yap mark morphing through its keyframes to an MP4 (60 fps), using the same construction as the app:
// ball outline + three offset rings, clipped to the ball, with liquid fillets (blur → threshold).
//   swift scripts/mark-video.swift <out.mp4> [speed=1] [loops=2] [size=720]
import AppKit
import AVFoundation
import CoreImage

let a = CommandLine.arguments
let outURL = URL(fileURLWithPath: a[1])
let speed = a.count > 2 ? Double(a[2])! : 1
let loops = a.count > 3 ? Int(a[3])! : 2
let side = a.count > 4 ? Int(a[4])! : 720

// Keyframes and timing from design/mark/mark-config.json (the Mark Lab settings).
struct Config: Decodable { let holdMs: Double; let moveMs: Double; let stroke: CGFloat; let rim: CGFloat
                           let fillet: CGFloat; let fullness: CGFloat; let keys: [[[CGFloat]]] }
let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("../design/mark/mark-config.json")))
func match(_ p: [CGPoint], _ q: [CGPoint]) -> [CGPoint] {
    let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    return perms.map { $0.map { q[$0] } }.min { x, y in
        zip(p, x).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) } < zip(p, y).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
    }!
}
let raw = cfg.keys.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
var keys = [raw[0]]
for k in raw.dropFirst() + [raw[0]] { keys.append(match(keys.last!, k)) }

let hold = cfg.holdMs / 1000 / speed, move = cfg.moveMs / 1000 / speed
let segment = hold + move
let fps = 60.0
let total = segment * Double(keys.count - 1) * Double(loops)

/// Strong ease-in-out for on-screen movement: cubic-bezier(0.77, 0, 0.175, 1).
func easeInOut(_ t: Double) -> Double {
    let (x1, y1, x2, y2) = (0.77, 0.0, 0.175, 1.0)
    var lo = 0.0, hi = 1.0
    for _ in 0..<40 {
        let m = (lo + hi) / 2, u = 1 - m
        let x = 3 * u * u * m * x1 + 3 * u * m * m * x2 + m * m * m
        if x < t { lo = m } else { hi = m }
    }
    let m = (lo + hi) / 2, u = 1 - m
    return 3 * u * u * m * y1 + 3 * u * m * m * y2 + m * m * m
}

func rings(at time: Double) -> [CGPoint] {
    let local = time.truncatingRemainder(dividingBy: segment * Double(keys.count - 1))
    let i = min(keys.count - 2, Int(local / segment))
    let t = local - Double(i) * segment
    let e = t < hold ? 0 : easeInOut((t - hold) / move)
    return zip(keys[i], keys[i + 1]).map { p, q in
        CGPoint(x: p.x + (q.x - p.x) * e, y: p.y + (q.y - p.y) * e)
    }
}

// MARK: Rendering

let W = side
let ball = CGFloat(side) * 0.62
let origin = (CGFloat(side) - ball) / 2
let s = ball / 300
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: cs])
let k: CGFloat = 40, thr: CGFloat = cfg.fullness, stroke: CGFloat = cfg.stroke, fillet: CGFloat = cfg.fillet

func frame(_ centres: [CGPoint]) -> CGImage {
    let ctx = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: W, height: W))
    ctx.setStrokeColor(.black); ctx.setLineWidth(stroke * s)
    for c in [CGPoint.zero] + centres {
        ctx.strokeEllipse(in: CGRect(x: origin + (150 + c.x - 145) * s, y: origin + (150 - c.y - 145) * s,
                                     width: 290 * s, height: 290 * s))
    }
    var img = CIImage(cgImage: ctx.makeImage()!)
    img = img.clampedToExtent().applyingGaussianBlur(sigma: Double(fillet * s)).cropped(to: img.extent)
    let b = 0.5 - k * thr
    img = img.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
    ]).applyingFilter("CIColorClamp")
    let liquid = ci.createCGImage(img, from: img.extent)!

    let out = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    out.setFillColor(.white); out.fill(CGRect(x: 0, y: 0, width: W, height: W))
    out.saveGState()
    out.addEllipse(in: CGRect(x: origin, y: origin, width: ball, height: ball)); out.clip()
    out.draw(liquid, in: CGRect(x: 0, y: 0, width: W, height: W))
    out.restoreGState()
    out.setStrokeColor(.black); out.setLineWidth(cfg.rim * s)
    out.strokeEllipse(in: CGRect(x: origin + cfg.rim * s / 2, y: origin + cfg.rim * s / 2, width: ball - cfg.rim * s, height: ball - cfg.rim * s))
    return out.makeImage()!
}

// MARK: Encoding

try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: W,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: W,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let count = Int(total * fps)
for n in 0..<count {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    let img = frame(rings(at: Double(n) / fps))
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let c = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: W, bitsPerComponent: 8,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: W, height: W))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("wrote \(outURL.path): \(count) frames, \(String(format: "%.1f", total))s, status \(writer.status.rawValue)")
