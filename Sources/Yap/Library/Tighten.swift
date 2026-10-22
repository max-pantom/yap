import AVFoundation
import Speech

/// "Remove Ums & Pauses": cuts filler words and shortens long pauses in a recording, using the time of every word.
/// The result is a new copy next to the original; captions and chapters are re-timed to match.
enum Tighten {
    struct Word { var start: Double; var end: Double; var text: String }
    struct Result { var url: URL; var fillers: Int; var removed: Double }

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "uhh", "erm", "er", "ah", "ahh", "hmm", "hm", "mm", "mhm", "eh"]
    /// Pauses longer than this are shortened, leaving `keepAround` of quiet on each side so speech doesn't feel cut.
    static let maxPause = 0.7
    static let keepBefore = 0.18, keepAfter = 0.12

    /// Every recognised word with its time, on this Mac.
    static func words(in audio: URL) async throws -> [Word] {
        if !SpeechEngine.shared.isReady { try await SpeechEngine.shared.prepare() }
        let module = SpeechTranscriber(locale: SpeechEngine.shared.locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () -> [Word] in
            var out: [Word] = []
            for try await r in module.results where r.isFinal {
                for run in r.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append(Word(start: range.start.seconds, end: range.end.seconds, text: text)) }
                }
            }
            return out
        }
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: audio), finishAfterFile: true)
        return try await collector.value.sorted { $0.start < $1.start }
    }

    static func isFiller(_ w: String) -> Bool {
        fillers.contains(w.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    /// The stretches to cut: filler words, long pauses between words, and long quiet at the start and end.
    static func cuts(_ words: [Word], duration: Double) -> [ClosedRange<Double>] {
        var cuts: [ClosedRange<Double>] = []
        let speech = words.filter { !isFiller($0.text) }
        for w in words where isFiller(w.text) { cuts.append(max(0, w.start - 0.03)...min(duration, w.end + 0.03)) }
        for (a, b) in zip(speech, speech.dropFirst()) where b.start - a.end > maxPause {
            cuts.append((a.end + keepBefore)...(b.start - keepAfter))
        }
        if let first = speech.first, first.start > 1.2 { cuts.append(0...(first.start - 0.35)) }
        if let last = speech.last, duration - last.end > 1.5 { cuts.append((last.end + 0.6)...duration) }
        // Merge overlaps.
        var merged: [ClosedRange<Double>] = []
        for c in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) where c.upperBound - c.lowerBound > 0.04 {
            if let l = merged.last, c.lowerBound <= l.upperBound + 0.02 { merged[merged.count - 1] = l.lowerBound...max(l.upperBound, c.upperBound) }
            else { merged.append(c) }
        }
        // Never cut into a real word: end each cut just before the next one starts, begin it just after the last one.
        return merged.compactMap { c -> ClosedRange<Double>? in
            var lo = c.lowerBound, hi = c.upperBound
            if let next = speech.first(where: { $0.start > lo && $0.start < hi }) { hi = next.start - 0.05 }
            if let prev = speech.last(where: { $0.end > lo && $0.end < hi }) { lo = prev.end + 0.05 }
            return hi - lo > 0.04 ? lo...hi : nil
        }
    }

    /// Where a moment of the original lands in the tightened copy (nil if it was cut).
    static func map(_ t: Double, through cuts: [ClosedRange<Double>]) -> Double? {
        var shift = 0.0
        for c in cuts {
            if t >= c.upperBound { shift += c.upperBound - c.lowerBound } else if t > c.lowerBound { return nil } else { break }
        }
        return t - shift
    }

    static func apply(to video: URL, output: URL) async throws -> Result {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw YapError("This recording has no sound, so there are no words to tidy.")
        }
        try await ex.export(to: audioURL, as: .m4a)
        let ws = try await words(in: audioURL)
        guard !ws.isEmpty else { throw YapError("No words were recognised in this recording.") }
        let cuts = cuts(ws, duration: duration)
        let removed = cuts.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        guard removed > 0.3 else { throw YapError("Nothing to remove: no ums, and no long pauses.") }

        // Keep everything between the cuts, end to end.
        let comp = AVMutableComposition()
        let srcVideo = try await asset.loadTracks(withMediaType: .video).first
        let srcAudio = try await asset.loadTracks(withMediaType: .audio).first
        let v = srcVideo.flatMap { _ in comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        let a = srcAudio.flatMap { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        if let srcVideo { v?.preferredTransform = try await srcVideo.load(.preferredTransform) }
        var keeps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for c in cuts { if c.lowerBound > cursor { keeps.append(cursor...c.lowerBound) }; cursor = c.upperBound }
        if cursor < duration { keeps.append(cursor...duration) }
        var at = CMTime.zero
        for k in keeps {
            let range = CMTimeRange(start: CMTime(seconds: k.lowerBound, preferredTimescale: 600), end: CMTime(seconds: k.upperBound, preferredTimescale: 600))
            if let srcVideo { try v?.insertTimeRange(range, of: srcVideo, at: at) }
            if let srcAudio { try a?.insertTimeRange(range, of: srcAudio, at: at) }
            at = at + range.duration
        }
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw YapError("Couldn't make the tidied copy.")
        }
        try await export.export(to: output, as: .mp4)
        let fillerCount = ws.filter { isFiller($0.text) }.count
        // Captions and chapters, re-timed.
        if var meta = RecordingMeta.load(for: video) {
            meta.segments = meta.segments.compactMap { s in
                guard let st = map(s.start, through: cuts) ?? map(s.start + 0.2, through: cuts), let en = map(s.end, through: cuts) ?? Optional(st + (s.end - s.start)) else { return nil }
                return .init(start: st, end: max(st + 0.3, en), text: s.text)
            }
            meta.chapters = meta.chapters.compactMap { c in map(c.start, through: cuts).map { .init(start: $0, title: c.title) } }
            meta.duration = duration - removed
            meta.title += " (tidied)"
            meta.created = Date()
            meta.save(for: output)
            try? RecordingProcessor.srt(meta.segments).write(to: RecordingMeta.captions(for: output), atomically: true, encoding: .utf8)
        }
        return Result(url: output, fillers: fillerCount, removed: removed)
    }
}
