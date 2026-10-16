import AVFoundation
import Accelerate
import AudioToolbox

/// Pulls microphone audio, converts it to the analyzer's format, and reports a level for the HUD.
final class MicCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private(set) var isRunning = false
    /// When true, also keeps a 16 kHz mono copy of everything heard (Whisper's input format).
    var collectWhisperAudio = false
    private let lock = NSLock()
    private var collected: [Float] = []

    func takeCollectedSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = collected
        collected = []
        return out
    }

    func start(target: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer, Float) -> Void) throws {
        stop()
        let input = engine.inputNode
        if let uid = Devices.selectedMicID, var deviceID = Devices.audioDeviceID(forUID: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw YapError("No microphone found. Connect one, or bring your iPhone nearby and pick it under Yap → Microphone.")
        }
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw YapError("Can't convert microphone audio to \(target).")
        }
        self.converter = converter
        let ratio = target.sampleRate / inFormat.sampleRate
        let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let whisperConverter = collectWhisperAudio ? AVAudioConverter(from: inFormat, to: whisperFormat) : nil
        let whisperRatio = 16_000 / inFormat.sampleRate
        lock.lock(); collected = []; lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            let level = Self.level(of: buffer)
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { onBuffer(out, level) }

            if let whisperConverter,
               let w = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * whisperRatio) + 32) {
                var used = false
                whisperConverter.convert(to: w, error: nil) { _, status in
                    if used { status.pointee = .noDataNow; return nil }
                    used = true
                    status.pointee = .haveData
                    return buffer
                }
                if let ch = w.floatChannelData?[0], w.frameLength > 0 {
                    let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(w.frameLength)))
                    self.lock.lock(); self.collected.append(contentsOf: chunk); self.lock.unlock()
                }
            }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// 0...1 loudness, roughly perceptual.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 55) / 45))
    }
}

/// Audio arriving from the iPhone (16 kHz mono Int16), converted to the analyzer's format.
final class RemoteFeed {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let onBuffer: (AVAudioPCMBuffer, Float) -> Void
    private(set) var samples: [Float] = []   // kept for Whisper, which wants exactly this format

    init?(target: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer, Float) -> Void) {
        guard let c = AVAudioConverter(from: source, to: target) else { return nil }
        converter = c; self.target = target; self.onBuffer = onBuffer
    }

    func feed(_ pcm: Data) {
        let n = pcm.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(n)), let ch = buf.floatChannelData?[0] else { return }
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n { ch[i] = Float(Int16(littleEndian: p[i])) / 32768 }
        }
        buf.frameLength = AVAudioFrameCount(n)
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(n))
        let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 55) / 45))
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(n) * target.sampleRate / 16_000) + 32) else { return }
        var used = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true; status.pointee = .haveData
            return buf
        }
        if error == nil, out.frameLength > 0 { onBuffer(out, level) }
    }
}
