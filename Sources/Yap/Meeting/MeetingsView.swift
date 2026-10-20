import AVFoundation
import SwiftUI

/// Library → Meetings: every call's notes, with the summary and action items up top and who said what below.
struct MeetingsPane: View {
    @ObservedObject var meeting: MeetingController
    @ObservedObject var store: MeetingStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    if meeting.phase == .recording {
                        Button { Task { await meeting.stop() } } label: { Label("End Meeting Notes", systemImage: "stop.circle") }
                    } else {
                        Button { meeting.start() } label: { Label("Take Meeting Notes", systemImage: "person.2.wave.2") }
                            .disabled(meeting.phase == .processing)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.open(MeetingStore.folder) } label: { Image(systemName: "folder") }
                        .help("Open meetings folder")
                        .disabled(store.meetings.isEmpty)
                }
                .padding(10)
                if meeting.phase == .processing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(meeting.status).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                List(store.meetings, selection: $store.selection) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(.body.weight(.medium)).lineLimit(2)
                        HStack(spacing: 4) {
                            Text(m.created, format: .dateTime.day().month().hour().minute())
                            Text("· \(Polisher.stamp(m.duration))")
                            if !m.actions.isEmpty { Text("· \(m.actions.count) to do") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(m.folder)
                    .contextMenu {
                        Button("Copy Notes") { copy(m.markdown) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { store.trash(m) }
                    }
                }
                .overlay {
                    if store.meetings.isEmpty && meeting.phase == .idle {
                        ContentUnavailableView("No meetings yet", systemImage: "person.2.wave.2",
                                               description: Text("Press \(Shortcut.label(.meeting)) when a call starts and again when it ends. Works with Zoom, Meet, Teams, FaceTime and any other app."))
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            Group {
                if let s = store.selection, let m = store.meetings.first(where: { $0.folder == s }) {
                    MeetingDetail(meeting: m, store: store).id(m.folder)
                } else {
                    ContentUnavailableView("Select a meeting", systemImage: "person.2.wave.2")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { store.reload() }
    }
}

private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

private struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var store: MeetingStore
    @StateObject private var player = AudioPlayer()
    @Local private var query = ""

    private var lines: [Meeting.Line] {
        query.isEmpty ? meeting.lines : meeting.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text("\(meeting.created.formatted(date: .complete, time: .shortened)) · \(Polisher.stamp(meeting.duration))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button { player.toggle() } label: { Label(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill") }
                    Text("\(Polisher.stamp(player.time)) / \(Polisher.stamp(meeting.duration))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { copy(meeting.markdown) } label: { Label("Copy Notes", systemImage: "doc.on.doc") }
                        .help("Copy the summary, action items and transcript as Markdown")
                }

                if !meeting.summary.isEmpty {
                    section("Summary") { Text(meeting.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }
                if !meeting.actions.isEmpty {
                    section("Action items") {
                        ForEach(meeting.actions) { a in
                            Toggle(isOn: Binding(get: { a.done }, set: { done in
                                var m = meeting
                                if let i = m.actions.firstIndex(where: { $0.id == a.id }) { m.actions[i].done = done }
                                store.update(m)
                            })) {
                                Text(a.text).strikethrough(a.done).foregroundStyle(a.done ? .secondary : .primary)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                if meeting.summary.isEmpty && !meeting.lines.isEmpty {
                    Text("No AI model is on, so there's no summary. Turn on Apple Intelligence or pick a model in Settings → AI.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                section("Transcript") {
                    if meeting.lines.isEmpty {
                        Text("No words were recognised.").foregroundStyle(.secondary)
                    } else {
                        TextField("Search the transcript", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Button(Polisher.stamp(l.start)) { player.play(from: l.start) }
                                    .buttonStyle(.link).font(.caption.monospacedDigit()).frame(width: 44, alignment: .leading)
                                    .help("Play from here")
                                Text(l.speaker.label).font(.callout.weight(.semibold))
                                    .foregroundStyle(l.speaker == .you ? Color.accentColor : Color.orange)
                                    .frame(width: 52, alignment: .leading)
                                Text(l.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { player.load(meeting.audio) }
        .onDisappear { player.pause() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

@MainActor
private final class AudioPlayer: ObservableObject {
    @Published var playing = false
    @Published var time: Double = 0
    private var player: AVPlayer?
    private var observer: Any?

    func load(_ url: URL) {
        guard player == nil, FileManager.default.fileExists(atPath: url.path) else { return }
        let p = AVPlayer(url: url)
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.time = t.seconds
                self?.playing = (self?.player?.rate ?? 0) > 0
            }
        }
        player = p
    }

    func toggle() { playing ? pause() : play(from: nil) }
    func play(from t: Double?) {
        if let t { player?.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }
        player?.play()
        playing = player != nil
    }
    func pause() { player?.pause(); playing = false }
}
