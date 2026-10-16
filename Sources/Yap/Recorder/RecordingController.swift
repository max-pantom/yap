import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
final class RecordingController: NSObject, ObservableObject, SCContentSharingPickerObserver {
    enum Phase: Equatable { case idle, countdown, recording, processing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var processingStatus = ""

    let camera = CameraBubble()
    private var recorder: ScreenRecorder?
    private let clicks = ClickTracker()
    private var trackedScreen: CGRect?
    private var cameraWasVisible = false
    private let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
        super.init()
    }

    var isActive: Bool { phase == .countdown || phase == .recording }

    func toggle() {
        switch phase {
        case .idle, .processing: Task { await recordDisplay() }
        case .recording: Task { await stop() }
        case .countdown: break
        }
    }

    // MARK: Start

    func recordDisplay() async {
        guard phase == .idle || phase == .processing, ensureScreenPermission() else { return }
        prepareCamera()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw YapError("No display found.")
            }
            // Hide all of Yap's own UI from the video except the camera bubble.
            let me = content.applications.filter { $0.processID == getpid() }
            let bubble = content.windows.filter { w in camera.windowNumber.map { CGWindowID($0) == w.windowID } ?? false }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: bubble)
            await begin(with: filter, screen: screen?.frame)
        } catch {
            fail(error)
        }
    }

    /// Lets the user pick a window or app with the system picker (no need for us to list windows).
    func recordPicked() {
        guard phase == .idle || phase == .processing, ensureScreenPermission() else { return }
        let picker = SCContentSharingPicker.shared
        var cfg = SCContentSharingPickerConfiguration()
        cfg.allowedPickerModes = [.singleWindow, .singleApplication, .singleDisplay]
        picker.defaultConfiguration = cfg
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            picker.remove(self)
            picker.isActive = false
            self.prepareCamera()
            await self.begin(with: filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in picker.remove(self); picker.isActive = false }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    /// `screen` is the recorded display's frame, for auto-zoom. Window and app recordings don't zoom.
    private func begin(with filter: SCContentFilter, screen: CGRect? = nil) async {
        if UserDefaults.standard.bool(forKey: Prefs.Key.recCountdown) {
            phase = .countdown
            let ok = await Countdown.run(seconds: 3)
            guard ok else { phase = .idle; camera.hideIfWeShowedIt(cameraWasVisible); return }
        }
        let d = UserDefaults.standard
        let options = ScreenRecorder.Options(
            mic: d.bool(forKey: Prefs.Key.recMic),
            systemAudio: d.bool(forKey: Prefs.Key.recSystemAudio),
            clicks: d.bool(forKey: Prefs.Key.recClicks),
            fps: max(15, min(60, d.integer(forKey: Prefs.Key.recFPS))),
            hevc: d.string(forKey: Prefs.Key.recCodec) == "hevc",
            micID: Devices.selectedMicID)

        let folder = Prefs.recordingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Yap \(Self.fileStamp.string(from: Date())).mp4")

        let recorder = ScreenRecorder()
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                if let error { HUD.shared.toast("Recording stopped: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill") }
                await self.stop()
            }
        }
        do {
            try await recorder.start(filter: filter, to: url, options: options)
        } catch {
            fail(error)
            return
        }
        self.recorder = recorder
        startedAt = Date()
        trackedScreen = screen
        if let screen { clicks.start(screen: screen) }
        phase = .recording
        ControlBar.shared.show(for: self)
    }

    // MARK: Stop

    func stop() async {
        guard phase == .recording, let recorder else { return }
        ControlBar.shared.hide()
        phase = .processing
        processingStatus = "Finishing video…"
        let url: URL?
        let clickLog = trackedScreen != nil ? clicks.stop() : nil
        trackedScreen = nil
        do { url = try await recorder.stop() } catch { fail(error); return }
        self.recorder = nil
        startedAt = nil
        camera.hideIfWeShowedIt(cameraWasVisible)
        guard let url else { phase = .idle; return }

        if UserDefaults.standard.bool(forKey: Prefs.Key.recAutoCopy) {
            Self.copyFileToClipboard(url)
            HUD.shared.toast("Saved & copied: paste anywhere", symbol: "checkmark.circle.fill")
        } else {
            HUD.shared.toast("Recording saved", symbol: "checkmark.circle.fill")
        }
        library.reload()

        if let clickLog, !clickLog.clicks.isEmpty {
            clickLog.save(for: url)
            if UserDefaults.standard.bool(forKey: Prefs.Key.autoZoom) {
                processingStatus = "Adding auto-zoom…"
                do {
                    // Same path, so a copy already on the clipboard pastes the zoomed version.
                    if try await VideoEffects.applyAutoZoom(to: url) { HUD.shared.toast("Auto-zoom added", symbol: "plus.magnifyingglass") }
                } catch {
                    Log.write("auto-zoom failed: \(error.localizedDescription)")
                }
            }
        }

        // Transcript, captions, AI title, summary and chapters, all on-device.
        let finalURL = await RecordingProcessor.process(url) { [weak self] status in
            Task { @MainActor in self?.processingStatus = status }
        }
        library.reload(select: finalURL)
        processingStatus = ""
        if phase == .processing { phase = .idle }
    }

    func cancel() {
        guard phase == .recording, let recorder else { return }
        ControlBar.shared.hide()
        clicks.stop(); trackedScreen = nil
        Task {
            let url = try? await recorder.stop()
            if let url { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            self.recorder = nil
            self.startedAt = nil
            self.phase = .idle
            self.camera.hideIfWeShowedIt(self.cameraWasVisible)
            HUD.shared.toast("Recording discarded", symbol: "trash")
        }
    }

    // MARK: Helpers

    private func prepareCamera() {
        cameraWasVisible = camera.isVisible
        if UserDefaults.standard.bool(forKey: Prefs.Key.recCamera), !camera.isVisible { camera.show() }
    }

    private func ensureScreenPermission() -> Bool {
        if Permission.screenRecording.isGranted { return true }
        Permission.screenRecording.request()
        HUD.shared.toast("Allow Screen Recording for Yap, then try again", symbol: "rectangle.dashed.badge.record")
        return false
    }

    private func fail(_ error: Error) {
        ControlBar.shared.hide()
        clicks.stop(); trackedScreen = nil
        recorder = nil
        startedAt = nil
        phase = .idle
        camera.hideIfWeShowedIt(cameraWasVisible)
        Sounds.error()
        HUD.shared.toast(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
    }

    static func copyFileToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}

extension CameraBubble {
    /// Leave the bubble up if the user had it open before recording; otherwise put it away.
    func hideIfWeShowedIt(_ wasVisible: Bool) { if !wasVisible { hide() } }
}

// MARK: - Post-processing

struct RecordingMeta: Codable, Hashable {
    var title: String
    var summary: String
    var chapters: [Polisher.Chapter]
    var segments: [SpeechEngine.Segment]
    var created: Date
    var duration: Double

    var transcript: String { segments.map(\.text).joined(separator: " ") }

    static func sidecar(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("yap.json") }
    static func captions(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("srt") }
    /// The un-zoomed original, kept in a hidden folder next to the recordings.
    static func original(for video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(".originals", isDirectory: true).appendingPathComponent(video.lastPathComponent)
    }
    /// Every file that belongs to a recording, other than the video itself.
    static func companions(for video: URL) -> [URL] { [sidecar(for: video), captions(for: video), ClickLog.url(for: video), original(for: video)] }

    static func load(for video: URL) -> RecordingMeta? {
        guard let data = try? Data(contentsOf: sidecar(for: video)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RecordingMeta.self, from: data)
    }

    func save(for video: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.sidecar(for: video), options: .atomic)
    }
}

enum RecordingProcessor {
    /// Returns the final URL of the video (it is renamed after its AI title).
    static func process(_ video: URL, status: @escaping @Sendable (String) -> Void) async -> URL {
        let asset = AVURLAsset(url: video)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var meta = RecordingMeta(title: video.deletingPathExtension().lastPathComponent, summary: "",
                                 chapters: [], segments: [], created: Date(), duration: duration)

        status("Transcribing…")
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        if (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false,
           let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            do {
                try await export.export(to: audioURL, as: .m4a)
                if await WhisperEngine.shared.isActive {
                    meta.segments = try await WhisperEngine.shared.transcribe(file: audioURL.path)
                } else {
                    meta.segments = try await SpeechEngine.shared.transcribe(file: audioURL)
                }
            } catch {
                status("Transcription failed: \(error.localizedDescription)")
            }
        }

        if !meta.segments.isEmpty {
            try? srt(meta.segments).write(to: RecordingMeta.captions(for: video), atomically: true, encoding: .utf8)
            status("Writing title & chapters…")
            if let insights = await Polisher.shared.insights(for: meta.segments) {
                meta.title = insights.title
                meta.summary = insights.summary
                meta.chapters = duration > 60 ? insights.chapters : []
            }
        }
        meta.save(for: video)
        return renamed(video, to: meta.title)
    }

    private static func renamed(_ video: URL, to title: String) -> URL {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty, safe != video.deletingPathExtension().lastPathComponent else { return video }
        let folder = video.deletingLastPathComponent()
        var target = folder.appendingPathComponent(String(safe.prefix(80))).appendingPathExtension("mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(safe.prefix(80)) \(n)").appendingPathExtension("mp4"); n += 1
        }
        let fm = FileManager.default
        do {
            try fm.moveItem(at: video, to: target)
            for (from, to) in zip(RecordingMeta.companions(for: video), RecordingMeta.companions(for: target)) { try? fm.moveItem(at: from, to: to) }
            return target
        } catch {
            return video
        }
    }

    static func srt(_ segments: [SpeechEngine.Segment]) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return segments.enumerated().map { i, s in "\(i + 1)\n\(ts(s.start)) --> \(ts(max(s.end, s.start + 0.5)))\n\(s.text)\n" }
            .joined(separator: "\n")
    }
}
