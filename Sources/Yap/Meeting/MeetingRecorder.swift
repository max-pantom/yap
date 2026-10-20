import AVFoundation
import ScreenCaptureKit

/// Records a call as two audio files: your microphone and everything your Mac plays (the other people).
/// Keeping the sides apart is what lets the notes say who said what, with no guessing.
final class MeetingRecorder: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    struct Result {
        /// Your side and the other side, each with when its first sound arrived (seconds after start).
        var you: (url: URL, offset: Double)?
        var others: (url: URL, offset: Double)?
    }

    private var stream: SCStream?
    private let sink = DispatchQueue(label: "yap.meeting.sink")
    private let folder: URL
    private var started = CMTime.invalid
    // Touched only on `sink`.
    private var tracks: [SCStreamOutputType: Track] = [:]
    var onUnexpectedStop: ((Error?) -> Void)?

    private final class Track {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let first: CMTime
        var appended = 0, dropped = 0
        init(writer: AVAssetWriter, input: AVAssetWriterInput, first: CMTime) { self.writer = writer; self.input = input; self.first = first }
    }

    init(folder: URL) { self.folder = folder }

    func start(micID: String?) async throws {
        let t0 = Date()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        Log.write(String(format: "meeting: shareable content %.2fs", Date().timeIntervalSince(t0)))
        guard let display = content.displays.first else { throw YapError("No display found.") }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        // Sound only: the smallest picture ScreenCaptureKit allows, once a second, and thrown away.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 1
        cfg.captureMicrophone = true
        cfg.microphoneCaptureDeviceID = micID

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sink)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sink)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sink)
        started = CMClockGetTime(CMClockGetHostTimeClock())
        try await stream.startCapture()
        Log.write(String(format: "meeting: capture started %.2fs", Date().timeIntervalSince(t0)))
        self.stream = stream
    }

    func stop() async throws -> Result {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let tracks = sink.sync { let t = self.tracks; self.tracks = [:]; return t }
        var result = Result()
        for (type, t) in tracks {
            t.input.markAsFinished()
            await t.writer.finishWriting()
            Log.write("meeting \(type == .microphone ? "mic" : "system"): \(t.appended) buffers, \(t.dropped) dropped, starts at \(String(format: "%.2f", (t.first - started).seconds))s, status \(t.writer.status.rawValue) \(t.writer.error?.localizedDescription ?? "")")
            guard t.writer.status == .completed else { continue }
            let offset = max(0, (t.first - started).seconds)
            if type == .microphone { result.you = (t.writer.outputURL, offset) } else { result.others = (t.writer.outputURL, offset) }
        }
        return result
    }

    // MARK: Delegates

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type != .screen, tracks[type] == nil {
            Log.write("meeting first \(type == .microphone ? "mic" : "system") buffer: valid \(buffer.isValid), samples \(buffer.numSamples), at \(String(format: "%.2f", (buffer.presentationTimeStamp - started).seconds))s")
        }
        guard type != .screen, buffer.isValid, buffer.numSamples > 0 else { return }
        guard let track = tracks[type] ?? makeTrack(type, for: buffer) else { return }
        if track.input.isReadyForMoreMediaData, track.input.append(buffer) { track.appended += 1 } else { track.dropped += 1 }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if self.stream != nil { onUnexpectedStop?(error) }
    }

    private func makeTrack(_ type: SCStreamOutputType, for buffer: CMSampleBuffer) -> Track? {
        guard let desc = buffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return nil }
        let url = folder.appendingPathComponent(type == .microphone ? "you.m4a" : "others.m4a")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return nil }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: min(2, max(1, Int(asbd.mChannelsPerFrame))),
            AVEncoderBitRateKey: 64_000,
        ], sourceFormatHint: desc)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        let first = buffer.presentationTimeStamp
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: first)
        let t = Track(writer: writer, input: input, first: first)
        tracks[type] = t
        return t
    }
}
