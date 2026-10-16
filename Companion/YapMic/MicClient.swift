import AVFoundation
import Network
import SwiftUI

/// Connects to the paired Mac and streams the microphone while you talk.
@MainActor
final class MicClient: ObservableObject {
    enum Link: Equatable { case unpaired, searching, connected, failed(String) }

    @Published private(set) var link: Link = .unpaired
    @Published private(set) var pairing: MicLink.Pairing?
    @Published private(set) var talking = false
    @Published private(set) var level: Float = 0
    @Published private(set) var mac = MicLink.Status(state: .ready)

    private var connection: NWConnection?
    private var reader = MicLink.Reader()
    private let engine = AVAudioEngine()
    private var retry: Task<Void, Never>?

    init() {
        pairing = PairingStore.load()
        if pairing != nil { connect() }
    }

    // MARK: Pairing

    func pair(_ p: MicLink.Pairing) {
        PairingStore.save(p)
        pairing = p
        mac = .init(state: .ready)
        connect()
    }

    func unpair() {
        stop(send: false)
        PairingStore.clear()
        pairing = nil
        retry?.cancel()
        connection?.cancel(); connection = nil
        link = .unpaired
    }

    // MARK: Connection

    func connect() {
        retry?.cancel()
        connection?.cancel()
        guard let p = pairing else { link = .unpaired; return }
        link = .searching
        reader = MicLink.Reader()
        let c = NWConnection(to: .service(name: p.service, type: MicLink.serviceType, domain: "local.", interface: nil),
                             using: MicLink.parameters(p))
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            Task { @MainActor in
                guard let self, let c, self.connection === c else { return }
                switch state {
                case .ready:
                    self.link = .connected
                    c.send(content: MicLink.frame(.hello, json: MicLink.Hello(name: Platform.deviceName)), completion: .contentProcessed { _ in })
                case .waiting:
                    self.link = .searching
                    self.scheduleRetry()
                case .failed(let e):
                    self.link = .failed(e.localizedDescription)
                    self.scheduleRetry()
                case .cancelled:
                    if self.talking { self.stop(send: false) }
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    /// Re-dial after a short pause (Mac asleep, Wi-Fi changed, Yap quit…).
    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.link != .connected, self.pairing != nil else { return }
            self.connect()
        }
    }

    /// Call when the app comes back to the foreground.
    func refresh() { if pairing != nil, link != .connected { connect() } }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.connection === c else { return }
                if let data, !data.isEmpty {
                    guard let frames = self.reader.append(data) else { c.cancel(); return }
                    for (kind, payload) in frames where kind == .status {
                        if let s = try? JSONDecoder().decode(MicLink.Status.self, from: payload) { self.received(s) }
                    }
                }
                if done || error != nil { c.cancel(); self.link = .searching; self.scheduleRetry() } else { self.receive(on: c) }
            }
        }
    }

    private func received(_ s: MicLink.Status) {
        // Keep the last words on screen while a new status without text arrives.
        mac = MicLink.Status(state: s.state, text: s.text ?? (s.state == .thinking ? mac.text : nil))
        switch s.state {
        case .done: Platform.haptic(.success)
        case .error, .busy: Platform.haptic(.error); if talking { stop(send: false) }
        default: break
        }
    }

    // MARK: Talking

    func start(command: Bool) {
        guard link == .connected, !talking, let c = connection else { return }
        do {
            try Platform.activateRecordingSession()
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicLink.sampleRate, channels: 1, interleaved: false)!
            guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                mac = .init(state: .error, text: "No microphone available"); return
            }
            c.send(content: MicLink.frame(.begin, json: MicLink.Begin(command: command)), completion: .contentProcessed { _ in })
            let ratio = MicLink.sampleRate / inFormat.sampleRate
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
                guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
                var used = false
                converter.convert(to: out, error: nil) { _, status in
                    if used { status.pointee = .noDataNow; return nil }
                    used = true; status.pointee = .haveData
                    return buffer
                }
                guard let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
                let n = Int(out.frameLength)
                var pcm = Data(count: n * 2)
                var sum: Float = 0
                pcm.withUnsafeMutableBytes { raw in
                    let p = raw.bindMemory(to: Int16.self)
                    for i in 0..<n {
                        let v = max(-1, min(1, ch[i]))
                        sum += v * v
                        p[i] = Int16(v * 32767).littleEndian
                    }
                }
                c.send(content: MicLink.frame(.audio, pcm), completion: .idempotent)
                let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
                let lvl = max(0, min(1, (db + 55) / 45))
                Task { @MainActor in self?.level = lvl }
            }
            engine.prepare()
            try engine.start()
            talking = true
            mac = .init(state: .listening)
            Platform.haptic(.start)
        } catch {
            mac = .init(state: .error, text: error.localizedDescription)
        }
    }

    /// Finish talking: `send` pastes on the Mac; `cancel` throws it away.
    func stop(send: Bool = true, cancel: Bool = false) {
        guard talking else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Platform.deactivateRecordingSession()
        talking = false
        level = 0
        if send, let c = connection {
            c.send(content: MicLink.frame(cancel ? .cancel : .end), completion: .contentProcessed { _ in })
            Platform.haptic(.stop)
        }
    }
}

/// The pairing lives in the Keychain (the key) and UserDefaults (where to find the Mac).
enum PairingStore {
    private static let account = "pairing"
    private static let service = "app.yap.mic"

    static func save(_ p: MicLink.Pairing) {
        clear()
        let value = p.url.absoluteString
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> MicLink.Pairing? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), let url = URL(string: s) else { return nil }
        return MicLink.Pairing(url: url)
    }

    static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
