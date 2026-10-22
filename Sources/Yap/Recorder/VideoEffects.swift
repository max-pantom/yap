import AppKit
import AVFoundation
import CoreImage

// MARK: - Click log

/// Where the pointer clicked (and roughly where it went) during a recording, saved next to the video as
/// `<name>.clicks.json`. Positions are 0…1 of the recorded screen, top-left origin.
struct ClickLog: Codable, Sendable {
    struct Event: Codable, Sendable { var t: Double; var x: Double; var y: Double; var click: Bool }
    var events: [Event] = []
    var clicks: [Event] { events.filter(\.click) }

    static func url(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("clicks.json") }
    static func load(for video: URL) -> ClickLog? {
        (try? Data(contentsOf: url(for: video))).flatMap { try? JSONDecoder().decode(ClickLog.self, from: $0) }
    }
    func save(for video: URL) { try? JSONEncoder().encode(self).write(to: Self.url(for: video), options: .atomic) }
}

/// Global mouse monitors (no extra permission needed for mouse events). Only listens; never changes input.
@MainActor
final class ClickTracker {
    private var monitors: [Any] = []
    private var log = ClickLog()
    private var start = Date()
    private var screen = CGRect.zero
    private var lastMove = 0.0
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    /// While paused nothing is logged, and the time spent paused is taken out so zooms line up with the video.
    func pause() { if pausedAt == nil { pausedAt = Date() } }
    func resume() { if let p = pausedAt { pausedTotal += Date().timeIntervalSince(p); pausedAt = nil } }

    func start(screen frame: CGRect) {
        stop()
        log = ClickLog(); start = Date(); screen = frame; lastMove = 0; pausedAt = nil; pausedTotal = 0
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.record(click: e.type != .mouseMoved && e.type != .leftMouseDragged) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
    }

    /// Stops listening and returns what was recorded.
    @discardableResult
    func stop() -> ClickLog {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        return log
    }

    private func record(click: Bool) {
        guard pausedAt == nil else { return }
        let t = Date().timeIntervalSince(start) - pausedTotal
        if !click, t - lastMove < 0.1 { return } // moves at ~10 per second are plenty
        let p = NSEvent.mouseLocation
        guard screen.width > 0, screen.contains(p) else { return }
        if !click { lastMove = t }
        log.events.append(.init(t: t, x: (p.x - screen.minX) / screen.width, y: 1 - (p.y - screen.minY) / screen.height, click: click))
    }
}

// MARK: - Zoom plan

/// A smooth camera path: zoom in around clicks, follow the pointer while zoomed, ease back out after a pause.
/// Spring-driven, so it never snaps, and computed once up front so rendering is a lookup.
struct ZoomPlan: Sendable {
    struct Sample: Sendable { var z: Double; var x: Double; var y: Double }
    private(set) var samples: [Sample] = []
    static let rate = 60.0

    init?(log: ClickLog, duration: Double, level: Double) {
        let clicks = log.clicks.sorted { $0.t < $1.t }
        guard !clicks.isEmpty, duration > 0 else { return nil }
        // Group nearby clicks into zoomed stretches.
        var segments: [(start: Double, end: Double)] = []
        var groupStart = clicks[0].t, groupEnd = clicks[0].t
        for c in clicks.dropFirst() {
            if c.t - groupEnd > 3 { segments.append((groupStart - 0.5, groupEnd + 2.0)); groupStart = c.t }
            groupEnd = c.t
        }
        segments.append((groupStart - 0.5, groupEnd + 2.0))
        var merged: [(start: Double, end: Double)] = []
        for s in segments {
            if let last = merged.last, s.start - last.end < 1 { merged[merged.count - 1].end = s.end } else { merged.append(s) }
        }

        let moves = log.events.sorted { $0.t < $1.t }
        let lookahead = 0.35 // start moving just before the click, so the zoom arrives with it
        var z = 1.0, vz = 0.0, x = 0.5, vx = 0.0, y = 0.5, vy = 0.0
        var tx = 0.5, ty = 0.5
        var ci = 0, mi = 0
        let dt = 1 / Self.rate
        let n = Int(duration * Self.rate) + 1
        samples.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) * dt, ta = t + lookahead
            let seg = merged.first { ta >= $0.start && ta <= $0.end }
            while ci < clicks.count, clicks[ci].t <= ta { ci += 1 }
            while mi < moves.count, moves[mi].t <= ta { mi += 1 }
            let zt = seg == nil ? 1 : level
            if let seg {
                // Aim at the latest click in this stretch, or at its first click before that lands.
                let anchor = ci > 0 && clicks[ci - 1].t >= seg.start ? clicks[ci - 1] : clicks[min(ci, clicks.count - 1)]
                tx = anchor.x; ty = anchor.y
                // Keep the pointer in view: if it leaves the middle of the zoomed frame, follow it.
                if mi > 0, moves[mi - 1].t > anchor.t {
                    let p = moves[mi - 1], half = 0.5 / max(z, 1) * 0.7
                    if abs(p.x - x) > half || abs(p.y - y) > half { tx = p.x; ty = p.y }
                }
            } else if z < 1.002, ci < clicks.count {
                tx = clicks[ci].x; ty = clicks[ci].y // park on the next click while fully zoomed out
            }
            // Critically damped springs.
            let wz = 5.0, wp = 4.0
            vz += (wz * wz * (zt - z) - 2 * wz * vz) * dt; z += vz * dt
            vx += (wp * wp * (tx - x) - 2 * wp * vx) * dt; x += vx * dt
            vy += (wp * wp * (ty - y) - 2 * wp * vy) * dt; y += vy * dt
            if z < 1.002, zt == 1 { x = tx; y = ty; vx = 0; vy = 0 }
            samples.append(.init(z: max(1, z), x: x, y: y))
        }
    }

    func at(_ t: Double) -> Sample {
        guard !samples.isEmpty else { return .init(z: 1, x: 0.5, y: 0.5) }
        let f = max(0, t * Self.rate), i = min(samples.count - 1, Int(f)), j = min(samples.count - 1, i + 1), k = f - Double(i)
        let a = samples[i], b = samples[j]
        return .init(z: a.z + (b.z - a.z) * k, x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }
}

// MARK: - Blur regions

/// A rectangle to hide (0…1 of the frame, top-left origin), for the whole video or a stretch of it.
struct BlurRegion: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var rect: CGRect
    var start: Double = 0
    var end: Double = .infinity
    var pixelate = false
}

// MARK: - Rendering

enum VideoEffects {
    /// Re-encodes `source` into `output` with blurred regions (in source coordinates) and then the zoom path.
    static func render(_ source: URL, to output: URL, zoom: ZoomPlan?, blurs: [BlurRegion], captions: [Caption] = []) async throws {
        let asset = AVURLAsset(url: source)
        let painter = captions.isEmpty ? nil : CaptionPainter(captions)
        let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
            var image = request.sourceImage.clampedToExtent()
            let extent = request.sourceImage.extent
            let W = extent.width, H = extent.height
            let t = request.compositionTime.seconds
            for b in blurs where t >= b.start && t <= b.end {
                let r = CGRect(x: b.rect.minX * W, y: (1 - b.rect.maxY) * H, width: b.rect.width * W, height: b.rect.height * H).integral
                guard r.width > 2, r.height > 2 else { continue }
                let hidden: CIImage = b.pixelate
                    ? image.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(12, min(W, H) / 40), kCIInputCenterKey: CIVector(x: r.midX, y: r.midY)])
                    : image.applyingGaussianBlur(sigma: max(18, min(W, H) / 45))
                image = hidden.cropped(to: r).composited(over: image)
            }
            if let zoom {
                let s = zoom.at(t)
                let half = 0.5 / s.z
                let cx = min(max(s.x, half), 1 - half), cy = min(max(s.y, half), 1 - half)
                let ox = (cx - half) * W, oy = (1 - (cy + half)) * H
                image = image.samplingLinear()
                    .transformed(by: CGAffineTransform(translationX: -ox, y: -oy).concatenating(CGAffineTransform(scaleX: s.z, y: s.z)))
            }
            image = image.cropped(to: extent)
            // Captions go on last, over the zoom, so they stay the same size and place.
            if let caption = painter?.image(at: t, in: extent) { image = caption.composited(over: image) }
            request.finish(with: image, context: nil)
        }
        let hevc = UserDefaults.standard.string(forKey: Prefs.Key.recCodec) == "hevc"
        guard let export = AVAssetExportSession(asset: asset, presetName: hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality) else {
            throw YapError("Can't re-encode this video.")
        }
        export.videoComposition = composition
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .mp4)
    }

    /// Auto-zooms a recording in place. The untouched original is kept in `.originals` so it can be restored.
    static func applyAutoZoom(to video: URL) async throws -> Bool {
        guard let log = ClickLog.load(for: video), !log.clicks.isEmpty else { return false }
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        let level = UserDefaults.standard.double(forKey: Prefs.Key.zoomLevel)
        guard let plan = ZoomPlan(log: log, duration: duration, level: max(1.2, min(3, level))) else { return false }
        let tmp = video.deletingLastPathComponent().appendingPathComponent(".zooming-\(UUID().uuidString).mp4")
        do { try await render(video, to: tmp, zoom: plan, blurs: []) } catch { try? FileManager.default.removeItem(at: tmp); throw error }
        let original = RecordingMeta.original(for: video), fm = FileManager.default
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: original)
        try fm.moveItem(at: video, to: original)
        try fm.moveItem(at: tmp, to: video)
        return true
    }

    /// Puts the un-zoomed original back.
    static func restoreOriginal(of video: URL) throws {
        let original = RecordingMeta.original(for: video), fm = FileManager.default
        guard fm.fileExists(atPath: original.path) else { return }
        try fm.trashItem(at: video, resultingItemURL: nil)
        try fm.moveItem(at: original, to: video)
    }
}

// MARK: - Burned-in captions

/// One line of on-screen text, in source time.
struct Caption: Sendable, Equatable { var start: Double; var end: Double; var text: String }

enum Captions {
    /// Splits transcript segments into short phrases (about 9 words), timed in proportion to their length.
    static func phrases(from segments: [SpeechEngine.Segment], maxWords: Int = 9) -> [Caption] {
        var out: [Caption] = []
        for s in segments {
            let words = s.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            let chunks = stride(from: 0, to: words.count, by: maxWords).map { Array(words[$0..<min($0 + maxWords, words.count)]) }
            let total = Double(words.count), span = max(0.5, s.end - s.start)
            var t = s.start
            for c in chunks {
                let d = span * Double(c.count) / total
                out.append(Caption(start: t, end: t + d, text: c.joined(separator: " ")))
                t += d
            }
        }
        return out
    }
}

/// Draws caption images on demand and keeps the current one, so each phrase is rendered once.
final class CaptionPainter: @unchecked Sendable {
    private let captions: [Caption]
    private let lock = NSLock()
    private var cached: (index: Int, width: CGFloat, image: CIImage)?

    init(_ captions: [Caption]) { self.captions = captions.sorted { $0.start < $1.start } }

    /// The caption image for time `t`, already positioned in a frame of `extent`.
    func image(at t: Double, in extent: CGRect) -> CIImage? {
        guard let i = captions.firstIndex(where: { t >= $0.start && t < $0.end }) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.index == i, c.width == extent.width { return c.image }
        guard let img = Self.draw(captions[i].text, frameWidth: extent.width, frameHeight: extent.height) else { return nil }
        let x = extent.minX + (extent.width - img.extent.width) / 2, y = extent.minY + extent.height * 0.06
        let placed = img.transformed(by: CGAffineTransform(translationX: x, y: y))
        cached = (i, extent.width, placed)
        return placed
    }

    /// White semibold text on a soft dark pill, sized to the video.
    private static func draw(_ text: String, frameWidth: CGFloat, frameHeight: CGFloat) -> CIImage? {
        let fontSize = max(16, min(frameWidth, frameHeight * 16 / 9) * 0.026)
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                                                     .foregroundColor: NSColor.white, .paragraphStyle: style]
        let s = NSAttributedString(string: text, attributes: attrs)
        let maxW = frameWidth * 0.8
        let bounds = s.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padX = fontSize * 0.7, padY = fontSize * 0.4
        let w = Int(ceil(bounds.width + padX * 2)), h = Int(ceil(bounds.height + padY * 2))
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let pill = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: fontSize * 0.5, cornerHeight: fontSize * 0.5, transform: nil)
        ctx.addPath(pill); ctx.setFillColor(CGColor(gray: 0, alpha: 0.72)); ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(with: CGRect(x: padX, y: padY, width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}
