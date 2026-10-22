import AVFoundation
import ScreenCaptureKit

/// Thin wrapper over SCStream + SCRecordingOutput: the system encodes straight to an .mp4,
/// so there's no custom muxer, no HLS segmenting and no frame copying in our process.
///
/// Pausing keeps the stream running and only detaches the recording output, so resuming is instant. Each stretch
/// between pauses is its own file; `stop()` joins them into the final video.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, SCStreamOutput {
    struct Options {
        var mic = true
        var systemAudio = false
        var clicks = true
        var fps = 30
        var hevc = false
        var micID: String? = nil
    }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var options = Options()
    /// One continuation per recording output that is finishing, keyed by the output.
    private var finishing: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private let lock = NSLock()                  // the delegate calls back on ScreenCaptureKit's own threads
    private func take(_ o: SCRecordingOutput) -> CheckedContinuation<Void, Error>? {
        lock.withLock { finishing.removeValue(forKey: ObjectIdentifier(o)) }
    }
    private var anyFinishing: Bool { lock.withLock { !finishing.isEmpty } }
    private let sink = DispatchQueue(label: "yap.capture.sink")
    private(set) var url: URL?
    private var segments: [URL] = []
    private(set) var isPaused = false
    var onUnexpectedStop: ((Error?) -> Void)?

    func start(filter: SCContentFilter, to url: URL, options: Options) async throws {
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // Even dimensions keep H.264/HEVC encoders happy.
        cfg.width = Int(filter.contentRect.width * scale) & ~1
        cfg.height = Int(filter.contentRect.height * scale) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        cfg.queueDepth = 6
        cfg.showsCursor = true
        cfg.showMouseClicks = options.clicks
        cfg.capturesAudio = options.systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = options.mic
        cfg.microphoneCaptureDeviceID = options.micID

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        // A no-op screen output keeps SCK from logging dropped frames; recording happens in SCRecordingOutput.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sink)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sink) }
        if options.mic { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sink) }
        self.options = options
        self.url = url
        self.segments = []
        let output = try makeOutput(for: url)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        segments.append(url)
    }

    private func makeOutput(for url: URL) throws -> SCRecordingOutput {
        let recCfg = SCRecordingOutputConfiguration()
        recCfg.outputURL = url
        recCfg.outputFileType = .mp4
        recCfg.videoCodecType = options.hevc ? .hevc : .h264
        // This setter was added after the macOS 26 SDK. Use it dynamically when
        // running on a newer system without making Xcode 26 builds reference it.
        let mixSelector = NSSelectorFromString("setMixesAudioWithMicrophone:")
        if recCfg.responds(to: mixSelector) {
            recCfg.setValue(true, forKey: "mixesAudioWithMicrophone")
        }
        return SCRecordingOutput(configuration: recCfg, delegate: self)
    }

    // MARK: Pause

    /// Stops writing (the current piece is finished and kept); the screen is still being captured.
    func pause() async throws {
        guard let stream, let output, !isPaused else { return }
        isPaused = true
        try await finish(output) { try stream.removeRecordingOutput(output) }
        self.output = nil
    }

    /// Starts writing a new piece; `stop()` joins it to the others.
    func resume() async throws {
        guard let stream, let url, isPaused else { return }
        let piece = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent) part \(segments.count + 1).mp4")
        try? FileManager.default.removeItem(at: piece)
        let output = try makeOutput(for: piece)
        try stream.addRecordingOutput(output)
        self.output = output
        segments.append(piece)
        isPaused = false
    }

    // MARK: Stop

    func stop() async throws -> URL? {
        guard let stream else { return url }
        if let output, !isPaused {
            try await finish(output) { Task { try? await stream.stopCapture() } }
        } else {
            try? await stream.stopCapture()
        }
        self.stream = nil
        self.output = nil
        isPaused = false
        guard let url else { return nil }
        if segments.count > 1 { try await join(segments, into: url) }
        return url
    }

    /// Waits for `output` to finish writing after `trigger` asks it to.
    private func finish(_ output: SCRecordingOutput, _ trigger: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.withLock { finishing[ObjectIdentifier(output)] = c }
            do { try trigger() } catch {
                take(output)?.resume(throwing: error)
            }
        }
    }

    /// Joins the pieces end to end into `out` (the first piece), then removes the others.
    private func join(_ pieces: [URL], into out: URL) async throws {
        let comp = AVMutableComposition()
        var cursor = CMTime.zero
        let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        for piece in pieces {
            let asset = AVURLAsset(url: piece)
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0.05 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try video?.insertTimeRange(range, of: v, at: cursor)
                if cursor == .zero { video?.preferredTransform = try await v.load(.preferredTransform) }
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first { try audio?.insertTimeRange(range, of: a, at: cursor) }
            cursor = cursor + duration
        }
        if let audio, audio.segments.isEmpty { comp.removeTrack(audio) }
        let joined = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw YapError("Couldn't join the paused parts of the recording.")
        }
        try await export.export(to: joined, as: .mp4)
        let fm = FileManager.default
        _ = try fm.replaceItemAt(out, withItemAt: joined)
        for piece in pieces.dropFirst() { try? fm.removeItem(at: piece) }
    }

    // MARK: Delegates

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        take(recordingOutput)?.resume()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        if let c = take(recordingOutput) { c.resume(throwing: error) } else { onUnexpectedStop?(error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if !anyFinishing, self.stream != nil { onUnexpectedStop?(error) }
    }
}
