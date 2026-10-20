import AppKit
import AVFoundation
import Combine

/// One meeting's notes: who said what, a summary and the action items. Saved as `meeting.json` next to the audio.
struct Meeting: Codable, Identifiable, Hashable {
    enum Speaker: String, Codable { case you, others
        var label: String { self == .you ? "You" : "Others" }
    }
    struct Line: Codable, Hashable { var start: Double; var end: Double; var speaker: Speaker; var text: String }
    struct Action: Codable, Hashable, Identifiable { var id = UUID(); var text: String; var done = false }

    var title: String
    var summary: String
    var actions: [Action]
    var lines: [Line]
    var created: Date
    var duration: Double
    /// The meeting's folder, set when loaded (not saved).
    var folder: URL = URL(fileURLWithPath: "/")
    var id: URL { folder }

    private enum CodingKeys: String, CodingKey { case title, summary, actions, lines, created, duration }

    var audio: URL { folder.appendingPathComponent("audio.m4a") }
    static func file(in folder: URL) -> URL { folder.appendingPathComponent("meeting.json") }

    /// The notes as Markdown, for pasting into Notion, Linear, Slack or an email.
    var markdown: String {
        var s = "# \(title)\n\n\(created.formatted(date: .long, time: .shortened)) · \(Polisher.stamp(duration))\n"
        if !summary.isEmpty { s += "\n## Summary\n\n\(summary)\n" }
        if !actions.isEmpty { s += "\n## Action items\n\n" + actions.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") + "\n" }
        if !lines.isEmpty {
            s += "\n## Transcript\n\n" + lines.map { "**\($0.speaker.label)** [\(Polisher.stamp($0.start))]: \($0.text)" }.joined(separator: "\n\n") + "\n"
        }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.file(in: folder), options: .atomic)
    }

    static func load(from folder: URL) -> Meeting? {
        guard let data = try? Data(contentsOf: file(in: folder)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var m = try? dec.decode(Meeting.self, from: data)
        m?.folder = folder
        return m
    }
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var selection: URL?

    static var folder: URL { Prefs.recordingsFolder.appendingPathComponent("Meetings", isDirectory: true) }

    func reload(select: URL? = nil) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        meetings = dirs.compactMap(Meeting.load).sorted { $0.created > $1.created }
        if let select { selection = select }
        if let s = selection, !meetings.contains(where: { $0.folder == s }) { selection = meetings.first?.folder }
    }

    func update(_ m: Meeting) {
        m.save()
        if let i = meetings.firstIndex(where: { $0.folder == m.folder }) { meetings[i] = m }
    }

    func trash(_ m: Meeting) {
        try? FileManager.default.trashItem(at: m.folder, resultingItemURL: nil)
        reload()
    }
}

/// Meeting notes: press ⌥⇧M when a call starts and again when it ends. Yap writes down who said what and
/// turns it into a summary and action items, all on this Mac. Works with any call app, no bot joins.
@MainActor
final class MeetingController: ObservableObject {
    enum Phase: Equatable { case idle, recording, processing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var status = ""

    let store = MeetingStore()
    private var recorder: MeetingRecorder?
    private var folder: URL?

    var isRecording: Bool { phase == .recording }

    func toggle() {
        if phase == .recording { Task { await stop() } } else { start() }
    }

    func start() {
        guard phase != .recording else { return }
        guard !AppModel.shared.recorder.isActive else {
            HUD.shared.toast("Stop the screen recording first", symbol: "record.circle"); return
        }
        guard Permission.screenRecording.isGranted else {
            Permission.screenRecording.request()
            HUD.shared.toast("Allow Screen Recording so Yap can hear the call, then try again", symbol: "rectangle.dashed.badge.record")
            return
        }
        let folder = MeetingStore.folder.appendingPathComponent("Meeting \(RecordingController.fileStamp.string(from: Date()))", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { fail(error); return }
        let recorder = MeetingRecorder(folder: folder)
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                if let error { HUD.shared.toast("Meeting notes stopped: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill") }
                await self.stop()
            }
        }
        self.recorder = recorder
        self.folder = folder
        phase = .recording
        Task {
            do {
                try await recorder.start(micID: Devices.selectedMicID)
                startedAt = Date()  // the clock starts when sound does, not when the key was pressed
                Sounds.start()
                HUD.shared.toast("Taking meeting notes. \(Shortcut.label(.meeting)) to stop", symbol: "person.2.wave.2.fill")
                MeetingBar.shared.show(for: self)
            } catch {
                fail(error)
            }
        }
    }

    func stop() async {
        guard phase == .recording, let recorder, let folder else { return }
        MeetingBar.shared.hide()
        Sounds.stop()
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        phase = .processing
        status = "Saving the audio…"
        self.recorder = nil
        startedAt = nil
        let sides: MeetingRecorder.Result
        do { sides = try await recorder.stop() } catch { fail(error); return }
        guard sides.you != nil || sides.others != nil else {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            fail(YapError("No sound was recorded. Check the microphone in Yap's menu."))
            return
        }

        var meeting = Meeting(title: "Meeting", summary: "", actions: [], lines: [], created: Date().addingTimeInterval(-duration),
                              duration: duration, folder: folder)
        await Self.mix(sides, into: meeting.audio)
        meeting.save()
        store.reload(select: folder)

        status = "Writing down who said what…"
        let you = await Self.transcribe(sides.you, as: .you)
        let others = await Self.transcribe(sides.others, as: .others)
        meeting.lines = Self.merge(you: you, others: others)

        if !meeting.lines.isEmpty {
            status = "Writing the summary and action items…"
            if let notes = await Polisher.shared.meetingNotes(for: meeting.lines) {
                meeting.title = notes.title
                meeting.summary = notes.summary
                meeting.actions = notes.actions.map { Meeting.Action(text: $0) }
            }
        }
        if meeting.title == "Meeting" { meeting.title = "Meeting, \(meeting.created.formatted(date: .abbreviated, time: .shortened))" }
        meeting.save()
        // The mixed file is what's kept; the two sides were only needed to tell the speakers apart.
        for side in [sides.you?.url, sides.others?.url].compactMap({ $0 }) { try? FileManager.default.removeItem(at: side) }

        store.reload(select: folder)
        status = ""
        phase = .idle
        self.folder = nil
        if UserDefaults.standard.bool(forKey: Prefs.Key.meetingCopyNotes) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(meeting.markdown, forType: .string)
            HUD.shared.toast("Meeting notes ready and copied", symbol: "checkmark.circle.fill")
        } else {
            HUD.shared.toast("Meeting notes ready in the Library", symbol: "checkmark.circle.fill")
        }
    }

    func discard() {
        guard phase == .recording, let recorder, let folder else { return }
        MeetingBar.shared.hide()
        self.recorder = nil
        self.folder = nil
        startedAt = nil
        phase = .idle
        Task {
            _ = try? await recorder.stop()
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            HUD.shared.toast("Meeting discarded", symbol: "trash")
        }
    }

    private func fail(_ error: Error) {
        MeetingBar.shared.hide()
        recorder = nil
        folder = nil
        startedAt = nil
        status = ""
        phase = .idle
        Sounds.error()
        HUD.shared.toast(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
    }

    // MARK: Processing

    /// One file to play back: both sides lined up and mixed.
    private static func mix(_ sides: MeetingRecorder.Result, into out: URL) async {
        let comp = AVMutableComposition()
        for side in [sides.you, sides.others].compactMap({ $0 }) {
            let asset = AVURLAsset(url: side.url)
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await src.load(.timeRange),
                  let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try? dst.insertTimeRange(range, of: src, at: CMTime(seconds: side.offset, preferredTimescale: 600))
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return }
        try? await export.export(to: out, as: .m4a)
    }

    private static func transcribe(_ side: (url: URL, offset: Double)?, as speaker: Meeting.Speaker) async -> [Meeting.Line] {
        guard let side else { return [] }
        do {
            let segments = await WhisperEngine.shared.isActive
                ? try await WhisperEngine.shared.transcribe(file: side.url.path)
                : try await SpeechEngine.shared.transcribe(file: side.url)
            return segments.map { .init(start: $0.start + side.offset, end: $0.end + side.offset, speaker: speaker, text: $0.text) }
        } catch {
            Log.write("meeting transcription (\(speaker.rawValue)) failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Puts both sides in order. Without headphones your mic also hears the others through the speakers, so a
    /// line of yours that repeats one of theirs at the same moment is their echo and is dropped.
    nonisolated static func merge(you: [Meeting.Line], others: [Meeting.Line]) -> [Meeting.Line] {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let theirs = others.map { ($0, words($0.text)) }
        let mine = you.filter { line in
            let w = words(line.text)
            guard !w.isEmpty else { return false }
            return !theirs.contains { other, ow in
                other.start < line.end + 1.5 && line.start < other.end + 1.5
                    && Double(w.intersection(ow).count) / Double(w.count) >= 0.6
            }
        }
        return (mine + others).sorted { $0.start < $1.start }
    }
}
