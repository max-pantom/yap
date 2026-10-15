import AVFoundation
import ScreenCaptureKit

/// Thin wrapper over SCStream + SCRecordingOutput: the system encodes straight to an .mp4,
/// so there's no custom muxer, no HLS segmenting and no frame copying in our process.
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
    private var finished: CheckedContinuation<Void, Error>?
    private let sink = DispatchQueue(label: "yap.capture.sink")
    private(set) var url: URL?
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

        let recCfg = SCRecordingOutputConfiguration()
        recCfg.outputURL = url
        recCfg.outputFileType = .mp4
        recCfg.videoCodecType = options.hevc ? .hevc : .h264
        #if compiler(>=6.3)   // property only exists in the macOS 27 SDK (Xcode 26 builds skip it)
        if #available(macOS 27.0, *) { recCfg.mixesAudioWithMicrophone = true }
        #endif

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        let output = SCRecordingOutput(configuration: recCfg, delegate: self)
        // A no-op screen output keeps SCK from logging dropped frames; recording happens in SCRecordingOutput.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sink)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sink) }
        if options.mic { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sink) }
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        self.url = url
    }

    var duration: TimeInterval { output?.recordedDuration.seconds ?? 0 }

    func stop() async throws -> URL? {
        guard let stream else { return url }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            finished = c
            Task {
                do { try await stream.stopCapture() } catch {
                    self.finished?.resume(throwing: error); self.finished = nil
                }
            }
        }
        self.stream = nil
        self.output = nil
        return url
    }

    // MARK: Delegates

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished?.resume(); finished = nil
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        if let finished { finished.resume(throwing: error); self.finished = nil } else { onUnexpectedStop?(error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if finished == nil { onUnexpectedStop?(error) }
    }
}
