import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import Network

/// Lets the Yap Mic iPhone app act as a wireless microphone: hold the button on the phone, talk, and the text
/// pastes at the cursor on this Mac. Listens on the local network only while an iPhone is paired.
@MainActor
final class RemoteMic: ObservableObject {
    static let shared = RemoteMic()

    enum State: Equatable { case off, waiting, connected(String), failed(String) }
    @Published private(set) var state: State = .off
    @Published private(set) var pairing: MicLink.Pairing?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var reader = MicLink.Reader()
    private var observers: [AnyCancellable] = []
    private weak var dictation: DictationController?
    private var lastStatus: MicLink.Status?

    private static let keyAccount = "iphone-mic-key"
    private static let serviceKey = "remote.service"
    private static let macNameKey = "remote.macName"

    var isPaired: Bool { pairing != nil }

    func boot(_ dictation: DictationController) {
        self.dictation = dictation
        let d = UserDefaults.standard
        if let s = d.string(forKey: Self.serviceKey), let k = Keychain.get(Self.keyAccount).flatMap(MicLink.Pairing.unb64url), k.count == 32 {
            pairing = MicLink.Pairing(service: s, macName: d.string(forKey: Self.macNameKey) ?? Host.current().localizedName ?? "Mac", key: k)
        }
        // Tell the phone what's happening, and stream the words as they're heard.
        observers = [
            dictation.$phase.removeDuplicates().sink { [weak self] phase in
                guard let self, self.isRemoteSession || phase == .idle else { return }
                switch phase {
                case .listening, .locked: self.send(.init(state: .listening))
                case .thinking: self.send(.init(state: .thinking))
                case .idle:
                    guard self.lastStatus?.state == .thinking || self.lastStatus?.state == .listening else { return }
                    // Errors are posted right after the phase resets, so look one turn later.
                    DispatchQueue.main.async {
                        if let n = dictation.notice, n.isError { self.send(.init(state: .error, text: n.text)) }
                        else { self.send(.init(state: .done, text: dictation.lastOutput.map { String($0.prefix(400)) })) }
                    }
                }
            },
            dictation.$liveText.throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true).sink { [weak self] text in
                guard let self, self.isRemoteSession, !text.isEmpty else { return }
                self.send(.init(state: .listening, text: String(text.suffix(400))))
            },
        ]
        startListening()
    }

    private var isRemoteSession: Bool { dictation?.isRemote == true }

    // MARK: Pairing

    /// Makes a fresh key (any previously paired phone stops working) and returns it for the QR code.
    func pair() -> MicLink.Pairing {
        let p = MicLink.Pairing.generate(macName: Host.current().localizedName ?? "Mac")
        Keychain.set(MicLink.Pairing.b64url(p.key), account: Self.keyAccount)
        UserDefaults.standard.set(p.service, forKey: Self.serviceKey)
        UserDefaults.standard.set(p.macName, forKey: Self.macNameKey)
        pairing = p
        startListening()
        return p
    }

    func unpair() {
        Keychain.set(nil, account: Self.keyAccount)
        UserDefaults.standard.removeObject(forKey: Self.serviceKey)
        pairing = nil
        stopListening()
    }

    static func qrImage(for p: MicLink.Pairing, size: CGFloat = 220) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(p.url.absoluteString.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let k = size / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    // MARK: Listener

    private func startListening() {
        stopListening()
        guard let pairing else { state = .off; return }
        do {
            let l = try NWListener(using: MicLink.parameters(pairing))
            l.service = NWListener.Service(name: pairing.service, type: MicLink.serviceType)
            l.stateUpdateHandler = { [weak self] s in
                Task { @MainActor in
                    guard let self else { return }
                    switch s {
                    case .ready: if self.connection == nil { self.state = .waiting }
                    case .failed(let e): self.state = .failed(e.localizedDescription); Log.write("iphone mic listener failed: \(e)")
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
            l.start(queue: .main)
            listener = l
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func stopListening() {
        listener?.cancel(); listener = nil
        connection?.cancel(); connection = nil
        state = .off
    }

    private func accept(_ c: NWConnection) {
        connection?.cancel() // one phone at a time; the newest wins
        connection = c
        reader = MicLink.Reader()
        c.stateUpdateHandler = { [weak self, weak c] s in
            Task { @MainActor in
                guard let self, let c, self.connection === c else { return }
                switch s {
                case .ready: self.state = .connected("iPhone"); self.lastStatus = nil; self.send(.init(state: .ready))
                case .failed, .cancelled:
                    if self.isRemoteSession { self.dictation?.cancel() }
                    self.connection = nil
                    self.state = self.listener == nil ? .off : .waiting
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.connection === c else { return }
                if let data, !data.isEmpty {
                    guard let frames = self.reader.append(data) else { c.cancel(); return }
                    for (kind, payload) in frames { self.handle(kind, payload) }
                }
                if done || error != nil { c.cancel() } else { self.receive(on: c) }
            }
        }
    }

    private func handle(_ kind: MicLink.Kind, _ payload: Data) {
        guard let dictation else { return }
        switch kind {
        case .hello:
            if let h = try? JSONDecoder().decode(MicLink.Hello.self, from: payload) {
                state = .connected(String(h.name.prefix(60)))
                Log.write("iphone mic connected")
            }
        case .begin:
            let b = (try? JSONDecoder().decode(MicLink.Begin.self, from: payload)) ?? .init()
            if !dictation.beginRemote(command: b.command) { send(.init(state: .busy, text: dictation.notice?.text)) }
        case .audio:
            if dictation.isRemote { dictation.feedRemote(payload) }
        case .end:
            if dictation.isRemote { Task { await dictation.finish() } }
        case .cancel:
            if dictation.isRemote { dictation.cancel() }
        case .status:
            break
        }
    }

    private func send(_ status: MicLink.Status) {
        guard let c = connection, status != lastStatus else { return }
        lastStatus = status
        c.send(content: MicLink.frame(.status, json: status), completion: .contentProcessed { _ in })
    }
}
