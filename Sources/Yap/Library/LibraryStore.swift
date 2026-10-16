import AppKit
import AVFoundation

struct Recording: Identifiable, Hashable {
    var url: URL
    var meta: RecordingMeta?
    var created: Date
    var id: URL { url }
    var title: String { meta?.title ?? url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published var selection: URL?
    private var thumbs: [URL: NSImage] = [:]

    func reload(select: URL? = nil) {
        let folder = Prefs.recordingsFolder
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                  options: [.skipsHiddenFiles])) ?? []
        recordings = files
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return Recording(url: url, meta: RecordingMeta.load(for: url), created: created)
            }
            .sorted { $0.created > $1.created }
        if let select { selection = select }
        if let s = selection, !recordings.contains(where: { $0.url == s }) { selection = recordings.first?.url }
    }

    func thumbnail(for url: URL) async -> NSImage? {
        if let t = thumbs[url] { return t }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 300)
        guard let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        thumbs[url] = img
        return img
    }

    func trash(_ r: Recording) {
        let fm = FileManager.default
        try? fm.trashItem(at: r.url, resultingItemURL: nil)
        for f in RecordingMeta.companions(for: r.url) { try? fm.trashItem(at: f, resultingItemURL: nil) }
        reload()
    }

    func rename(_ r: Recording, to title: String) {
        var meta = r.meta ?? RecordingMeta(title: title, summary: "", chapters: [], segments: [], created: r.created, duration: 0)
        meta.title = title
        meta.save(for: r.url)
        reload()
    }

    func hasOriginal(_ r: Recording) -> Bool { FileManager.default.fileExists(atPath: RecordingMeta.original(for: r.url).path) }
    func canAutoZoom(_ r: Recording) -> Bool { !(ClickLog.load(for: r.url)?.clicks.isEmpty ?? true) }

    /// Zooms an existing recording around its clicks (in place, keeping the original).
    func autoZoom(_ r: Recording) async throws {
        if hasOriginal(r) { try VideoEffects.restoreOriginal(of: r.url) } // re-zoom from the clean source
        guard try await VideoEffects.applyAutoZoom(to: r.url) else { throw YapError("This recording has no clicks to zoom on.") }
        thumbs[r.url] = nil
        reload(select: r.url)
    }

    func restoreOriginal(_ r: Recording) throws {
        try VideoEffects.restoreOriginal(of: r.url)
        thumbs[r.url] = nil
        reload(select: r.url)
    }

    /// Saves a copy with the given areas blurred or pixelated.
    func exportBlurred(_ r: Recording, regions: [BlurRegion]) async throws -> URL {
        let out = uniqueURL(next: r.url, suffix: "blurred")
        try await VideoEffects.render(r.url, to: out, zoom: nil, blurs: regions)
        if var meta = r.meta {
            meta.title += " (blurred)"
            meta.created = Date()
            meta.save(for: out)
            try? RecordingProcessor.srt(meta.segments).write(to: RecordingMeta.captions(for: out), atomically: true, encoding: .utf8)
        }
        reload(select: out)
        return out
    }

    private func uniqueURL(next video: URL, suffix: String) -> URL {
        let base = video.deletingPathExtension().lastPathComponent + " (\(suffix))"
        var out = video.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = video.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension("mp4"); n += 1
        }
        return out
    }

    /// Exports [start, end] of a recording as a new file next to the original.
    func exportTrim(_ r: Recording, start: CMTime, end: CMTime) async throws -> URL {
        let asset = AVURLAsset(url: r.url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw YapError("Can't trim this file.")
        }
        export.timeRange = CMTimeRange(start: start, end: end)
        let out = uniqueURL(next: r.url, suffix: "trimmed")
        try await export.export(to: out, as: .mp4)
        if var meta = r.meta {
            let s = start.seconds, e = end.seconds
            meta.title += " (trimmed)"
            meta.duration = e - s
            meta.segments = meta.segments.filter { $0.end > s && $0.start < e }
                .map { .init(start: max(0, $0.start - s), end: $0.end - s, text: $0.text) }
            meta.chapters = meta.chapters.filter { $0.start >= s && $0.start < e }.map { .init(start: $0.start - s, title: $0.title) }
            meta.created = Date()
            meta.save(for: out)
            try? RecordingProcessor.srt(meta.segments).write(to: RecordingMeta.captions(for: out), atomically: true, encoding: .utf8)
        }
        reload(select: out)
        return out
    }
}
