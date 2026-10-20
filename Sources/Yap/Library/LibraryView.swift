import AVKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @Local private var section: Section = .recordings

    enum Section: String, CaseIterable, Identifiable {
        case recordings = "Recordings", meetings = "Meetings", dictations = "Dictations"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .recordings: "play.rectangle.on.rectangle"
            case .meetings: "person.2.wave.2"
            case .dictations: "text.bubble"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { s in Label(s.rawValue, systemImage: s.symbol).tag(s) }
            }
            .navigationSplitViewColumnWidth(170)
            .safeAreaInset(edge: .bottom) { StatsFooter(history: model.history) }
        } detail: {
            switch section {
            case .recordings: RecordingsPane(library: model.library, recorder: model.recorder)
            case .meetings: MeetingsPane(meeting: model.meeting, store: model.meeting.store)
            case .dictations: DictationsPane(history: model.history, dictation: model.dictation)
            }
        }
        .onAppear { model.library.reload() }
    }
}

private struct StatsFooter: View {
    @ObservedObject var history: HistoryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(history.totalWords.formatted()) words dictated").font(.caption.weight(.semibold))
            Text("≈ \(Int(history.minutesSaved)) min saved vs typing").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

// MARK: - Recordings

private struct RecordingsPane: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var recorder: RecordingController

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button { recorder.toggle() } label: { Label("Record Screen", systemImage: "record.circle") }
                    Button { recorder.recordPicked() } label: { Label("Window…", systemImage: "macwindow") }
                    Spacer()
                    Button { NSWorkspace.shared.open(Prefs.recordingsFolder) } label: { Image(systemName: "folder") }
                        .help("Open recordings folder")
                }
                .padding(10)
                if recorder.phase == .processing {
                    HStack { ProgressView().controlSize(.small); Text(recorder.processingStatus).font(.caption) }
                        .padding(.bottom, 6)
                }
                if library.recordings.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "record.circle",
                                           description: Text("Press \(Shortcut.label(.record)) anywhere to record your screen."))
                } else {
                    List(library.recordings, selection: $library.selection) { r in
                        RecordingRow(recording: r, library: library).tag(r.url)
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            Group {
                if let url = library.selection, let r = library.recordings.first(where: { $0.url == url }) {
                    RecordingDetail(recording: r, library: library).id(r.url)
                } else {
                    ContentUnavailableView("Select a recording", systemImage: "play.rectangle")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let library: LibraryStore
    @Local private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title).font(.callout.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(recording.created, format: .dateTime.month().day().hour().minute())
                    if let d = recording.meta?.duration, d > 0 { Text("· \(Polisher.stamp(d))") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .task { thumb = await library.thumbnail(for: recording.url) }
        .onDrag { NSItemProvider(contentsOf: recording.url) ?? NSItemProvider() }
    }
}

private struct RecordingDetail: View {
    let recording: Recording
    @ObservedObject var library: LibraryStore
    @StateObject private var player = PlayerHandle()
    @Local private var title = ""
    @Local private var transcriptQuery = ""
    @Local private var status = ""
    @Local private var busy = false
    @Local private var blurring = false
    @Local private var reloadToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlayerViewRep(handle: player, url: recording.url, token: reloadToken)
                .frame(minHeight: 260)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain).font(.title2.weight(.semibold))
                        .onSubmit { library.rename(recording, to: title) }
                    actions
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                    if let meta = recording.meta {
                        if !meta.summary.isEmpty {
                            Text(meta.summary).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !meta.chapters.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Chapters").font(.headline)
                                ForEach(meta.chapters, id: \.self) { c in
                                    Button { player.seek(c.start) } label: {
                                        HStack {
                                            Text(Polisher.stamp(c.start)).monospacedDigit().foregroundStyle(.tint)
                                            Text(c.title)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if !meta.segments.isEmpty { transcript(meta) }
                    } else {
                        Text("No transcript yet.").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .onAppear { title = recording.title }
        .sheet(isPresented: $blurring) {
            BlurEditor(url: recording.url, at: player.currentTime) { regions in
                blurring = false
                guard let regions, !regions.isEmpty else { return }
                run("Blurring…", done: "Blurred copy saved") { _ = try await library.exportBlurred(recording, regions: regions) }
            }
        }
    }

    private func run(_ working: String, done: String, _ work: @escaping () async throws -> Void) {
        busy = true; status = working
        Task {
            do { try await work(); status = done; reloadToken = UUID() } catch { status = error.localizedDescription }
            busy = false
        }
    }

    @ViewBuilder private var effects: some View {
        if library.hasOriginal(recording) {
            Button { run("Restoring…", done: "Original restored (zoomed copy is in the Trash)") { try library.restoreOriginal(recording) } } label: {
                Label("Remove Zoom", systemImage: "minus.magnifyingglass")
            }.help("Put back the recording without auto-zoom")
        } else if library.canAutoZoom(recording) {
            Button { run("Adding auto-zoom…", done: "Auto-zoom added") { try await library.autoZoom(recording) } } label: {
                Label("Auto-zoom", systemImage: "plus.magnifyingglass")
            }.help("Zoom in where you clicked")
        }
        Button { player.pause(); blurring = true } label: { Label("Blur…", systemImage: "eye.slash") }
            .help("Hide emails, keys or names")
        if let meta = recording.meta, !meta.segments.isEmpty {
            Button { run("Burning in captions…", done: "Captioned copy saved") { _ = try await library.exportCaptioned(recording) } } label: {
                Label("Captions", systemImage: "captions.bubble")
            }.help("Save a copy with captions burned into the video, for Slack and social")
        }
    }

    private var actions: some View {
        HStack {
            Button { RecordingController.copyFileToClipboard(recording.url); status = "Video copied: paste it into Slack, Mail, Linear…" } label: {
                Label("Copy Video", systemImage: "doc.on.doc")
            }
            if let meta = recording.meta, !meta.segments.isEmpty {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    var md = "# \(meta.title)\n\n\(meta.summary)\n\n"
                    if !meta.chapters.isEmpty { md += meta.chapters.map { "- \(Polisher.stamp($0.start)) \($0.title)" }.joined(separator: "\n") + "\n\n" }
                    md += meta.transcript
                    pb.setString(md, forType: .string)
                    status = "Summary + transcript copied as Markdown"
                } label: { Label("Copy Notes", systemImage: "text.quote") }
            }
            Button {
                player.trim { start, end in
                    Task {
                        do { _ = try await library.exportTrim(recording, start: start, end: end); status = "Trimmed copy saved" }
                        catch { status = error.localizedDescription }
                    }
                }
            } label: { Label("Trim", systemImage: "timeline.selection") }
            effects
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) } label: { Image(systemName: "magnifyingglass") }
                .help("Show in Finder")
            Button(role: .destructive) { library.trash(recording) } label: { Image(systemName: "trash") }
                .help("Move to Trash")
        }
    }

    private func transcript(_ meta: RecordingMeta) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                TextField("Search", text: $transcriptQuery).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            ForEach(meta.segments.filter { transcriptQuery.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptQuery) }, id: \.self) { s in
                Button { player.seek(s.start) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Polisher.stamp(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.tint)
                        Text(s.text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@MainActor
final class PlayerHandle: ObservableObject {
    weak var view: AVPlayerView?

    var currentTime: Double { view?.player?.currentTime().seconds ?? 0 }
    func pause() { view?.player?.pause() }

    func seek(_ seconds: Double) {
        view?.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        view?.player?.play()
    }

    /// Uses AVKit's built-in trimming UI, then hands back the chosen range.
    func trim(_ done: @escaping (CMTime, CMTime) -> Void) {
        guard let view, view.canBeginTrimming else { return }
        view.beginTrimming { result in
            guard result == .okButton, let item = view.player?.currentItem else { return }
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            done(start, end)
            item.reversePlaybackEndTime = .invalid
            item.forwardPlaybackEndTime = .invalid
        }
    }
}

struct PlayerViewRep: NSViewRepresentable {
    let handle: PlayerHandle
    let url: URL
    /// Change it to reload the file after it was rewritten in place (auto-zoom, restore).
    var token = UUID()

    final class Coordinator { var token: UUID?; }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsSharingServiceButton = true
        v.allowsPictureInPicturePlayback = true
        v.player = AVPlayer(url: url)
        context.coordinator.token = token
        handle.view = v
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url || context.coordinator.token != token {
            context.coordinator.token = token
            v.player = AVPlayer(url: url)
        }
        handle.view = v
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}

// MARK: - Dictations

private struct DictationsPane: View {
    @ObservedObject var history: HistoryStore
    let dictation: DictationController
    @Local private var query = ""

    var filtered: [DictationEntry] {
        query.isEmpty ? history.entries : history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.raw.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "mic",
                                       description: Text("Hold \(Shortcut.label(.dictate)) and speak in any text field. Double-tap it for hands-free."))
            } else {
                List(filtered) { e in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if e.isCommand { Image(systemName: "wand.and.stars").foregroundStyle(.purple) }
                            Text(e.app ?? "Unknown app").font(.caption.weight(.semibold))
                            Text(e.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { copy(e.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                            Button { history.delete(e) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
                        }
                        Text(e.text).textSelection(.enabled)
                        if e.raw != e.text {
                            DisclosureGroup("What you said") {
                                Text(e.raw).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .searchable(text: $query)
            }
        }
        .toolbar {
            if !history.entries.isEmpty {
                Button("Clear History", role: .destructive) { history.clear() }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
