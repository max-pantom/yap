import AppKit
import CoreImage
import SwiftUI

/// The Yap mark: the ball outline plus three rings of the same size, offset from the centre and clipped to the ball.
/// The seams are where the rings cross the ball; the motion is the rings sliding between keyframes.
/// Values come from Yap Mark Lab (design/mark/mark-config.json).
enum MarkConfig {
    /// Ring centres per keyframe, relative to the ball centre, ball radius 150, y pointing down.
    static let keys: [[CGPoint]] = [
        [(-54, -3), (-50, -86), (46, -66)],
        [(-58, 0), (-109, -61), (-55, -87)],
        [(-58, 0), (-138, -20), (-202, -48)],
        [(24, -28), (60, -140), (-72, -82)],
        [(164, -8), (-38, -150), (-160, 0)],
    ].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }

    static let hold: Double = 0.220          // rest on each keyframe (s)
    static let move: Double = 0.860          // travel between keyframes (s)
    static let ease = (0.77, 0.0, 0.175, 1.0)
    static let stroke: CGFloat = 10
    static let rim: CGFloat = 9
    static let fillet: CGFloat = 5.8
    static let fullness: CGFloat = 0.62
    static let smallBoost: CGFloat = 1.55

    static let idleFrame = 0                 // keyframe 1
    static let idleDrift: CGFloat = 7
    static let listenBase: Double = 0.2
    static let listenMax: Double = 3.4
    static let thinkSpeed: Double = 1.6
    static let pasteDuration: Double = 0.420
    static let startDuration: Double = 1.100
    static let recordPulse: Double = 3.100
}

// MARK: - Motion

/// One shared clock and state machine for every place the mark appears (startup, menu bar, Flow bar).
/// It only ticks while something is animating, so an idle Yap costs nothing. Ticks come from a display link
/// (in step with the screen's refresh), and every state change blends from wherever the rings are, so nothing snaps.
@MainActor
final class MarkMotion: NSObject, ObservableObject {
    static let shared = MarkMotion()

    enum State: Equatable { case idle, startup, listening, thinking, pasted, recording }

    struct Frame: Equatable {
        var rings: [CGPoint]
        var rimProgress: CGFloat = 1
        var alpha: CGFloat = 1
        var scale: CGFloat = 1
        var recording = false
    }

    @Published private(set) var frame = Frame(rings: MarkConfig.keys[MarkConfig.idleFrame])
    private(set) var state: State = .idle
    /// The state to return to after a transient one (startup, pasted).
    private var base: State = .idle
    /// 0…1 microphone level while listening.
    var voiceLevel: Double = 0

    private var loopTime: Double = 0
    private var stateTime: Double = 0
    private var pasteFrom: [CGPoint] = []
    private var pasteTo: [CGPoint] = []
    private var link: CADisplayLink?
    private var lastTick = CACurrentMediaTime()
    private let chain: [[CGPoint]]
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    // Blend from the previous state's position into the new one.
    private var blendFrom: [CGPoint]?
    private var blendPerm = [0, 1, 2]
    private var blendTime: Double = 0
    private let blendDuration: Double = 0.3
    /// Smoothed listening speed, so the motion glides instead of twitching with every syllable.
    private var listenSpeed: Double = MarkConfig.listenBase

    private override init() {
        // Keyframes in play order with ring identity matched for minimum travel; frame 1 repeats to close the loop.
        var c = [MarkConfig.keys[0]]
        for k in MarkConfig.keys.dropFirst() + [MarkConfig.keys[0]] { c.append(Self.match(c.last!, k)) }
        chain = c
        super.init()
    }

    /// Set the ongoing state (idle, listening, thinking, recording).
    func set(_ s: State) {
        base = s
        if state == .startup || state == .pasted { return }   // let the transient finish first
        enter(s)
    }

    /// A one-off moment that returns to the ongoing state when done.
    func play(_ s: State) {
        guard s == .startup || s == .pasted else { set(s); return }
        enter(s)
    }

    private func enter(_ s: State) {
        if s == .pasted {
            pasteFrom = frame.rings
            let next = chain[(currentKey() + 1) % (chain.count - 1)]
            pasteTo = Self.match(pasteFrom, next)
        }
        let wasLooping = state == .listening || state == .thinking
        state = s
        stateTime = 0
        if (s == .listening || s == .thinking) && !wasLooping {
            loopTime = 0                       // start the loop from keyframe 1, where idle rests
            listenSpeed = MarkConfig.listenBase
        }
        if s != .pasted && s != .startup && !reduceMotion {
            blendFrom = frame.rings            // glide from here into the new state
            blendTime = 0
            blendPerm = Self.bestPermutation(from: frame.rings, to: target(for: s, dt: 0))
        } else {
            blendFrom = nil
        }
        if s == .idle && blendFrom == nil {
            stopTicking()
            frame = Frame(rings: MarkConfig.keys[MarkConfig.idleFrame])
        } else {
            startTicking()
        }
    }

    private func startTicking() {
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let l = NSScreen.main?.displayLink(target: self, selector: #selector(step(_:)))
        l?.add(to: .main, forMode: .common)
        link = l
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ l: CADisplayLink) { tick() }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        stateTime += dt
        var f = Frame(rings: frame.rings)
        f.rings = target(for: state, dt: dt, frame: &f)
        if let from = blendFrom {
            blendTime += dt
            let e = Self.easeOut(min(1, blendTime / blendDuration))
            let to = blendPerm.map { f.rings[$0] }
            f.rings = zip(from, to).map { a, b in CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e) }
            if blendTime >= blendDuration {
                blendFrom = nil
                if state == .idle { frame = Frame(rings: MarkConfig.keys[MarkConfig.idleFrame]); stopTicking(); return }
            }
        }
        if state == .startup, stateTime >= MarkConfig.startDuration { frame = f; finishTransient(); return }
        if state == .pasted, stateTime >= MarkConfig.pasteDuration + 0.5 { frame = f; finishTransient(); return }
        if Self.trace {   // YAP_MOTION_TRACE=1: per-frame timing and ring travel, for smoothness checks
            let perm = Self.bestPermutation(from: frame.rings, to: f.rings)   // rings are identical: ignore relabels
            let move = zip(frame.rings, perm).map { hypot($0.x - f.rings[$1].x, $0.y - f.rings[$1].y) }.max() ?? 0
            fputs(String(format: "trace %@ dt=%.2fms move=%.2f\n", "\(state)", dt * 1000, move), stderr)
        }
        if f != frame { frame = f }
    }
    private static let trace = ProcessInfo.processInfo.environment["YAP_MOTION_TRACE"] != nil

    private func target(for s: State, dt: Double) -> [CGPoint] {
        var scratch = Frame(rings: frame.rings)
        let saved = (loopTime, listenSpeed, voiceLevel)
        defer { (loopTime, listenSpeed, voiceLevel) = saved }   // a probe, not a step
        return target(for: s, dt: dt, frame: &scratch)
    }

    /// Where the rings belong for `s` right now (advances the loop clock by `dt`).
    private func target(for s: State, dt: Double, frame f: inout Frame) -> [CGPoint] {
        let c = MarkConfig.self
        switch s {
        case .idle:
            return c.keys[c.idleFrame]
        case .startup:
            let p = min(1, stateTime / c.startDuration)
            let e = reduceMotion ? 1 : Self.easeOut(p)
            let rings = c.keys[c.idleFrame].enumerated().map { i, t in
                let ang = atan2(t.y == 0 ? -1 : t.y, t.x == 0 ? 0.001 : t.x) + Double(i) * 0.4
                let far = CGPoint(x: cos(ang) * 330, y: sin(ang) * 330)
                return CGPoint(x: t.x + (far.x - t.x) * (1 - e), y: t.y + (far.y - t.y) * (1 - e))
            }
            f.rimProgress = reduceMotion ? 1 : Self.easeOut(min(1, p * 1.25))
            return rings
        case .listening:
            // Voice → speed, both smoothed (~0.45 s), then a continuous flow with no rests on keyframes.
            voiceLevel += (Double(FlowBar.shared.meter.level) - voiceLevel) * min(1, dt * 4)
            let wanted = c.listenBase + (c.listenMax - c.listenBase) * min(1, voiceLevel * 1.4)
            listenSpeed += (wanted - listenSpeed) * min(1, dt * 2.2)
            if !reduceMotion { loopTime += dt * listenSpeed }
            return splineRings(atLoop: loopTime, segment: c.hold + c.move)
        case .thinking:
            if !reduceMotion { loopTime += dt * c.thinkSpeed }
            return rings(atLoop: loopTime, hold: c.hold, move: c.move, curve: c.ease)
        case .pasted:
            let p = min(1, stateTime / c.pasteDuration)
            let e = reduceMotion ? 1 : Self.easeOut(p)
            return zip(pasteFrom, pasteTo).map { a, b in CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e) }
        case .recording:
            let ph = stateTime / c.recordPulse * 2 * .pi
            let pulse = 0.5 + 0.5 * cos(ph)
            f.alpha = 0.78 + 0.22 * pulse
            f.scale = reduceMotion ? 1 : 1 + 0.015 * pulse
            f.recording = true
            return reduceMotion ? c.keys[c.idleFrame] : drift(c.keys[c.idleFrame], stateTime, c.idleDrift * 0.6)
        }
    }

    private func finishTransient() {
        let b = base
        state = .idle
        enter(b)
    }

    // MARK: Loop math

    private func rings(atLoop t: Double, hold: Double, move: Double, curve: (Double, Double, Double, Double)) -> [CGPoint] {
        let seg = hold + move
        let L = seg * Double(chain.count - 1)
        let u = (t.truncatingRemainder(dividingBy: L) + L).truncatingRemainder(dividingBy: L)
        let i = min(chain.count - 2, Int(u / seg))
        let local = u - Double(i) * seg
        let e = local < hold ? 0 : Self.bezier(curve, (local - hold) / move)
        return zip(chain[i], chain[i + 1]).map { a, b in CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e) }
    }

    /// Listening: each ring glides along a closed Catmull-Rom spline through the keyframes, passing exactly
    /// through your frames with continuous velocity: no rests, no slow-downs, no kinks.
    private func splineRings(atLoop t: Double, segment: Double) -> [CGPoint] {
        let n = chain.count - 1                      // segments in the loop
        let L = segment * Double(n)
        let u = (t.truncatingRemainder(dividingBy: L) + L).truncatingRemainder(dividingBy: L)
        let i = min(n - 1, Int(u / segment))
        let x = (u - Double(i) * segment) / segment
        let p0 = i == 0 ? splinePrev : chain[i - 1]
        let p1 = chain[i], p2 = chain[i + 1]
        let p3 = i + 2 <= n ? chain[i + 2] : splineNext
        return (0..<3).map { r in
            func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                let t = CGFloat(x)
                return 0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t * t * t)
            }
            return CGPoint(x: cr(p0[r].x, p1[r].x, p2[r].x, p3[r].x), y: cr(p0[r].y, p1[r].y, p2[r].y, p3[r].y))
        }
    }

    /// Neighbours beyond the loop's ends, with ring identity matched, so the spline closes smoothly.
    private lazy var splinePrev: [CGPoint] = Self.match(chain[0], MarkConfig.keys[MarkConfig.keys.count - 1])
    private lazy var splineNext: [CGPoint] = Self.match(chain[chain.count - 1], chain[1])

    private func currentKey() -> Int {
        let seg = MarkConfig.hold + MarkConfig.move
        let L = seg * Double(chain.count - 1)
        let u = (loopTime.truncatingRemainder(dividingBy: L) + L).truncatingRemainder(dividingBy: L)
        return min(chain.count - 2, Int(u / seg))
    }

    private func drift(_ r: [CGPoint], _ t: Double, _ amt: CGFloat) -> [CGPoint] {
        r.enumerated().map { i, p in
            CGPoint(x: p.x + amt * sin(t * 0.9 + Double(i) * 2.1), y: p.y + amt * cos(t * 0.7 + Double(i) * 1.7))
        }
    }

    /// Index order of `b` that minimises total travel from `a`.
    static func bestPermutation(from a: [CGPoint], to b: [CGPoint]) -> [Int] {
        let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        return perms.min { x, y in
            zip(a, x).reduce(0) { $0 + hypot($1.0.x - b[$1.1].x, $1.0.y - b[$1.1].y) } <
            zip(a, y).reduce(0) { $0 + hypot($1.0.x - b[$1.1].x, $1.0.y - b[$1.1].y) }
        }!
    }

    static func match(_ a: [CGPoint], _ b: [CGPoint]) -> [CGPoint] {
        bestPermutation(from: a, to: b).map { b[$0] }
    }

    static func ease(_ x: Double) -> Double { bezier(MarkConfig.ease, x) }
    static func easeOut(_ x: Double) -> Double { bezier((0.23, 1, 0.32, 1), x) }

    static func bezier(_ c: (Double, Double, Double, Double), _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func f(_ a: Double, _ b: Double, _ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 { let m = (lo + hi) / 2; if f(c.0, c.2, m) < x { lo = m } else { hi = m } }
        return f(c.1, c.3, (lo + hi) / 2)
    }
}

// MARK: - Renderer

/// Draws the mark exactly like Yap Mark Lab: rings → blur → threshold (liquid joins) → clip to the ball → crisp outline.
enum MarkRenderer {
    // No colour management in the mask step, so the ink comes out exactly as given (no grey shift on dark inks).
    private static let ci = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private static let gray = CGColorSpaceCreateDeviceGray()
    private static let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `points` is the drawn size; `pixelScale` the backing scale (2 on Retina).
    static func image(_ frame: MarkMotion.Frame, points: CGFloat, pixelScale: CGFloat = 2, ink: NSColor) -> CGImage? {
        let px = max(8, Int((points * pixelScale).rounded()))
        let small = points < 40
        let boost = small ? MarkConfig.smallBoost : 1
        let s = CGFloat(px) / 300 * frame.scale
        let c = CGFloat(px) / 2
        let R = 150 * s

        // 1. rings, black on white
        guard let g = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        g.setFillColor(gray: 1, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: px, height: px))
        g.setStrokeColor(gray: 0, alpha: 1); g.setLineWidth(MarkConfig.stroke * boost * s)
        for p in [CGPoint.zero] + frame.rings {   // y-down design space → y-up bitmap
            g.strokeEllipse(in: CGRect(x: c + (p.x - 145) * s, y: c - (p.y + 145) * s, width: 290 * s, height: 290 * s))
        }
        guard let ringsImage = g.makeImage() else { return nil }

        // 2. liquid joins: blur, then a steep threshold straight into an alpha mask
        var img = CIImage(cgImage: ringsImage)
        let blur = MarkConfig.fillet * s * (small ? 0.85 : 1)
        if blur > 0.2 { img = img.clampedToExtent().applyingGaussianBlur(sigma: Double(blur)).cropped(to: img.extent) }
        let k: CGFloat = small ? 14 : 48
        let ic = CIColor(color: ink) ?? CIColor(red: 0, green: 0, blue: 0)
        img = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: -k, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: ic.red, y: ic.green, z: ic.blue, w: k * MarkConfig.fullness + 0.5),
        ]).applyingFilter("CIColorClamp").premultiplyingAlpha()
        guard let liquid = ci.createCGImage(img, from: CGRect(x: 0, y: 0, width: px, height: px)) else { return nil }

        // 3. compose: clip to the ball, then the outline (drawn on top so its edge stays crisp)
        guard let out = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.setAlpha(frame.alpha)
        out.beginTransparencyLayer(auxiliaryInfo: nil)
        out.saveGState()
        out.addEllipse(in: CGRect(x: c - R, y: c - R, width: 2 * R, height: 2 * R)); out.clip()
        out.draw(liquid, in: CGRect(x: 0, y: 0, width: px, height: px))
        out.restoreGState()
        let rimW = MarkConfig.rim * boost * s
        let rimR = R - rimW / 2
        out.setStrokeColor(ink.cgColor); out.setLineWidth(rimW); out.setLineCap(.round)
        out.addArc(center: CGPoint(x: c, y: c), radius: rimR, startAngle: .pi / 2,
                   endAngle: .pi / 2 - 2 * .pi * frame.rimProgress, clockwise: true)
        out.strokePath()
        out.endTransparencyLayer()
        return out.makeImage()
    }

    /// Menu-bar image: a template (macOS tints it for light/dark bars), or red while recording.
    static func menuBarImage(_ frame: MarkMotion.Frame) -> NSImage {
        let pts: CGFloat = 18
        let ink: NSColor = frame.recording ? NSColor(srgbRed: 0.9, green: 0.22, blue: 0.23, alpha: 1) : .black
        guard let cg = image(frame, points: pts, pixelScale: 2, ink: ink) else { return NSImage() }
        let img = NSImage(cgImage: cg, size: NSSize(width: pts, height: pts))
        img.isTemplate = !frame.recording
        return img
    }
}

// MARK: - SwiftUI

/// The live mark at any size; follows MarkMotion.
struct MarkView: View {
    @ObservedObject private var motion = MarkMotion.shared
    var size: CGFloat
    var color: NSColor = .labelColor

    var body: some View {
        let ink = motion.frame.recording ? NSColor(srgbRed: 0.9, green: 0.22, blue: 0.23, alpha: 1) : color
        if let cg = MarkRenderer.image(motion.frame, points: size, pixelScale: 2, ink: ink) {
            Image(decorative: cg, scale: 2).resizable().frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}
