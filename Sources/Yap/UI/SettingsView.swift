import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Local private var page: Page = .shortcuts

    enum Page: String, CaseIterable, Identifiable {
        case shortcuts = "Shortcuts", dictation = "Dictation", models = "Models", words = "Words", recording = "Recording",
             permissions = "Permissions", general = "General"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .shortcuts: "keyboard"
            case .dictation: "mic"
            case .models: "cpu"
            case .words: "character.book.closed"
            case .recording: "record.circle"
            case .permissions: "lock.shield"
            case .general: "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(Page.allCases, selection: Binding(get: { page }, set: { if let p = $0 { page = p } })) { p in
                Label(p.rawValue, systemImage: p.symbol).tag(p)
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            Group {
                switch page {
                case .shortcuts: ShortcutsTab()
                case .dictation: DictationTab()
                case .models: ModelsTab()
                case .words: WordsTab()
                case .recording: RecordingTab()
                case .permissions: ScrollView { PermissionsView().padding(20) }
                case .general: GeneralTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.Key.sounds) var sounds = true
    @AppStorage(Prefs.Key.showFlowBar) var showFlowBar = true
    @AppStorage(Prefs.Key.startupAnimation) var startupAnimation = true
    @AppStorage(Prefs.Key.urlCommands) var urlCommands = true
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Play sounds", isOn: $sounds)
            Toggle("Always show the Flow bar", isOn: $showFlowBar)
                .onChange(of: showFlowBar) { _, _ in FlowBar.shared.update() }
            Text("The little pill on your screen. Click it to dictate, drag it to move it. It grows into a waveform while you talk.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset Flow bar position") { FlowBar.shared.resetPosition() }
            Toggle("Play the mark animation when Yap starts", isOn: $startupAnimation)
            if Updater.shared.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(get: { Updater.shared.automaticallyChecks }, set: { Updater.shared.automaticallyChecks = $0 }))
                Button("Check for Updates Now") { Updater.shared.checkForUpdates() }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                    catch { launchAtLogin = !on }
                }
            Section("Shortcuts & automation") {
                Toggle("Allow yap:// links", isOn: $urlCommands)
                Text("Lets Shortcuts, Raycast, Alfred, Stream Deck or scripts control Yap. In Shortcuts, use the “Open URLs” action. Browsers ask before opening a link.")
                    .font(.caption).foregroundStyle(.secondary)
                if urlCommands {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(URLCommands.reference, id: \.0) { url, what in
                            HStack(alignment: .firstTextBaseline) {
                                Text(url).font(.caption.monospaced()).textSelection(.enabled).frame(width: 190, alignment: .leading)
                                Text(what).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Privacy") {
                Text("Everything runs on this Mac: speech recognition, AI cleanup, summaries. No account, no uploads, no analytics.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DictationTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.Key.cleanupStyle) var style = CleanupStyle.polished.rawValue
    @AppStorage(Prefs.Key.locale) var locale = ""
    @AppStorage(Prefs.Key.keepOnClipboard) var keepOnClipboard = true
    @AppStorage(Prefs.Key.learnCorrections) var learnCorrections = true
    @AppStorage(Prefs.Key.voiceCommands) var voiceCommands = true
    @AppStorage(Prefs.Key.translateTo) var translateTo = ""
    @AppStorage(Prefs.Key.fitToCursor) var fitToCursor = true
    @Local private var locales: [String] = []

    var body: some View {
        Form {
            LabeledContent("Dictation key", value: Shortcut.label(.dictate))
            if Shortcut.get(.dictate)?.keyCode == 63 {
                HStack {
                    Text("Set “Press 🌐 key to” → “Do Nothing” so macOS doesn't open the emoji picker.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }.controlSize(.small)
                }
            }
            MicPicker()
            Toggle("Keep dictation on the clipboard after pasting", isOn: $keepOnClipboard)
            Text("When you stop talking, Yap pastes at your cursor. With this on, the text also stays on your clipboard, so it's never lost if no text field was focused.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Match the text around my cursor", isOn: $fitToCursor)
            Text("Dictating mid-sentence adds the space and keeps it lowercase, and drops the period when more text follows. Names keep their capitals.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Learn from my corrections", isOn: $learnCorrections)
            Text("Fix a word right after Yap pastes it (say “Jon” → “John”) and Yap adds it to your dictionary. It only reads the text field you just dictated into, for 45 seconds, on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Voice commands", isOn: $voiceCommands)
            Text("Say “scratch that” to drop the sentence before it, or on its own to remove your last dictation. End with “send it” or “press enter” to press Return after pasting. End with “translate to French” (any language) to paste the translation. Say “what's 40 plus 20” for the answer, or end a sum with “equals” to have it worked out. “New line” and “new paragraph” always work.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Always translate to", selection: $translateTo) {
                Text("Off (keep my language)").tag("")
                ForEach(Array(Set(VoiceCommands.languages.values)).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Text("Talk in any language Yap understands and paste in this one. Uses your AI model (Settings → Models); quality varies by language.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Cleanup", selection: $style) {
                ForEach(CleanupStyle.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if !Polisher.shared.modelAvailable {
                Text("No AI model is available (\(LLM.label)), so Yap uses rule-based cleanup and Command Mode is disabled. Pick one in Models.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Language", selection: $locale) {
                Text("System (\(Locale.current.identifier))").tag("")
                ForEach(locales, id: \.self) { id in
                    Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                }
            }
            .onChange(of: locale) { _, _ in model.dictation.boot() }
            LabeledContent("Speech model", value: model.dictation.engineStatus)
            IPhoneMicSection(remote: RemoteMic.shared)
            Section { PracticeView(dictation: model.dictation) }
        }
        .formStyle(.grouped)
        .task { locales = await SpeechEngine.supportedLocales().map(\.identifier).sorted() }
    }
}

private struct IPhoneMicSection: View {
    @ObservedObject var remote: RemoteMic
    @Local private var showingCode = false
    @Local private var confirmUnpair = false

    var body: some View {
        Section {
            if let p = remote.pairing {
                LabeledContent("Status") {
                    switch remote.state {
                    case .connected(let name): Label("\(name) connected", systemImage: "iphone.radiowaves.left.and.right").foregroundStyle(.green)
                    case .waiting: Text("Waiting for your iPhone").foregroundStyle(.secondary)
                    case .failed(let e): Text(e).foregroundStyle(.orange)
                    case .off: Text("Off").foregroundStyle(.secondary)
                    }
                }
                if showingCode, let img = RemoteMic.qrImage(for: p) {
                    HStack(alignment: .top, spacing: 16) {
                        Image(nsImage: img).interpolation(.none).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scan with Yap Mic").font(.headline)
                            Text("Open Yap Mic on your iPhone, tap Pair, and point it at this code. Keep it private: it's the key to this Mac's microphone link.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Done") { showingCode = false }
                        }
                    }
                } else {
                    HStack {
                        Button("Show Pairing Code") { showingCode = true }
                        Button("Unpair", role: .destructive) { confirmUnpair = true }
                            .confirmationDialog("Unpair your iPhone?", isPresented: $confirmUnpair) {
                                Button("Unpair", role: .destructive) { remote.unpair() }
                            } message: { Text("Yap stops listening on your network. You can pair again any time.") }
                    }
                }
            } else {
                Button("Pair iPhone…") { _ = remote.pair(); showingCode = true }
            }
        } header: {
            Text("iPhone as microphone")
        } footer: {
            Text("With the Yap Mic app, hold the button on your phone and talk from anywhere in the room; the text pastes at your cursor here. Audio is encrypted with a key only your phone and this Mac have, and stays on your Wi-Fi. Build the app from Companion/ in the Yap repository.")
        }
    }
}

private struct WordsTab: View {
    @AppStorage(Prefs.Key.dictionary) var dictionary = ""
    @AppStorage(Prefs.Key.snippets) var snippets = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $dictionary).font(.body.monospaced()).frame(height: 120)
            } header: {
                Text("Dictionary")
            } footer: {
                Text("One per line. A bare word (e.g. `Kubernetes`) teaches spelling. `heard => written` forces a replacement, e.g. `chat gpt => ChatGPT`.")
            }
            Section {
                TextEditor(text: $snippets).font(.body.monospaced()).frame(height: 120)
            } header: {
                Text("Snippets")
            } footer: {
                Text("Say the trigger on its own to paste the expansion, e.g. `my calendar link => https://cal.com/me`. Use \\n for line breaks, and {date}, {time}, {day}, {year} or {clipboard} to fill them in.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingTab: View {
    @AppStorage(Prefs.Key.recCamera) var camera = true
    @AppStorage(Prefs.Key.recMic) var mic = true
    @AppStorage(Prefs.Key.recSystemAudio) var systemAudio = false
    @AppStorage(Prefs.Key.recClicks) var clicks = true
    @AppStorage(Prefs.Key.recCountdown) var countdown = true
    @AppStorage(Prefs.Key.recAutoCopy) var autoCopy = true
    @AppStorage(Prefs.Key.recCodec) var codec = "h264"
    @AppStorage(Prefs.Key.recFPS) var fps = 30
    @AppStorage(Prefs.Key.autoZoom) var autoZoom = true
    @AppStorage(Prefs.Key.zoomLevel) var zoomLevel = 1.8
    @AppStorage(Prefs.Key.showKeystrokes) var showKeystrokes = true

    var body: some View {
        Form {
            Section("Devices") {
                CameraPicker { AppModel.shared.recorder.camera.useSelectedDevice() }
                MicPicker()
                ContinuityHint()
                Button("Preview Camera Bubble") { AppModel.shared.recorder.camera.toggle() }
            }
            Toggle("Show camera bubble", isOn: $camera)
            Toggle("Record microphone", isOn: $mic)
            Toggle("Record system audio", isOn: $systemAudio)
            Toggle("Highlight mouse clicks", isOn: $clicks)
            Toggle("Show keyboard shortcuts on screen", isOn: $showKeystrokes)
            Text("Shortcuts like ⌘K or ⌃⌥V appear at the bottom of full-screen recordings. Ordinary typing is never shown.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Auto-zoom on clicks", isOn: $autoZoom)
            if autoZoom {
                LabeledContent("Zoom") {
                    Slider(value: $zoomLevel, in: 1.3...2.6, step: 0.1) { Text("Zoom") } minimumValueLabel: { Text("Subtle") } maximumValueLabel: { Text("Close") }
                        .labelsHidden().frame(width: 260)
                }
            }
            Text("When you stop a full-screen recording, Yap smoothly zooms in where you click and follows your pointer, then eases back out. The original is kept: use Remove Zoom in the Library to get it back.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("3-second countdown", isOn: $countdown)
            Toggle("Copy video to clipboard when done", isOn: $autoCopy)
            Picker("Format", selection: $codec) {
                Text("H.264 (plays everywhere)").tag("h264")
                Text("HEVC (half the size)").tag("hevc")
            }
            Picker("Frame rate", selection: $fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            LabeledContent("Saved to") {
                Button(Prefs.recordingsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    try? FileManager.default.createDirectory(at: Prefs.recordingsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Prefs.recordingsFolder)
                }
                .buttonStyle(.link)
            }
            Text("No time limits. Recordings, captions (.srt) and AI notes are plain files you own.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct PermissionsView: View {
    @Local private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Permission.allCases) { p in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: p.isGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(p.isGranted ? .green : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.headline)
                        Text(p.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !p.isGranted { Button("Allow") { p.request() } }
                }
            }
            .id(tick)
            HStack {
                Text("Yap missing from a list in System Settings? Click + there and add Yap, or drag it in from Finder. Still off after allowing? Quit and reopen Yap.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Yap in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    .controlSize(.small)
            }
            HStack {
                Text("Switch keeps turning itself off? Click Allow here. It clears Yap's old entry and asks again. Turn Yap on in the list that opens, then relaunch. Screen Recording always needs a relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Relaunch Yap") { AppModel.relaunch() }.controlSize(.small)
            }
        }
        .onReceive(timer) { _ in tick &+= 1 }
    }
}

struct OnboardingView: View {
    let dictation: DictationController
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 44)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Welcome to Yap").font(.largeTitle.bold())
                    Text("Talk instead of typing. Record instead of explaining. 100% on-device.")
                        .foregroundStyle(.secondary)
                }
            }
            PermissionsView()
            Divider()
            PracticeView(dictation: dictation)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Hold **\(Shortcut.label(.dictate))** and talk in any text field. Release to paste.", systemImage: "mic")
                Label("**Double-tap** it for hands-free. Press again to finish.", systemImage: "lock")
                Label("Select text, use **Command Mode** and say “make this friendlier”.", systemImage: "wand.and.stars")
                Label("Press **\(Shortcut.label(.record))** to record your screen with your camera.", systemImage: "record.circle")
                Label("No Fn key (Windows / 60% keyboard)? Pick any key in Settings → Shortcuts.", systemImage: "keyboard")
            }
            HStack {
                Spacer()
                Button("Get Started") { done() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 600)
    }
}

/// "Try it now": a text box that confirms the key, the microphone and the paste all work.
struct PracticeView: View {
    @ObservedObject var dictation: DictationController
    @Local private var text = ""
    @Local private var keyOK = false
    @Local private var heardOK = false

    private var pastedOK: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it now").font(.headline)
            Text("Click in the box, hold **\(Shortcut.label(.dictate))**, say “Hello Yap, this is my first dictation”, then let go.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Practice text box")
            HStack(spacing: 18) {
                check("Key works", keyOK)
                check("Heard you", heardOK)
                check("Pasted", pastedOK)
                Spacer()
                if pastedOK { Button("Clear") { text = ""; keyOK = false; heardOK = false }.controlSize(.small) }
            }
            .font(.callout)
            if keyOK && !heardOK && dictation.phase == .idle && !pastedOK {
                Text("The key works but no words came through. Check the microphone under Yap → Microphone.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onChange(of: dictation.phase) { _, p in if p == .listening || p == .locked { keyOK = true } }
        .onChange(of: dictation.liveText) { _, t in if !t.isEmpty { heardOK = true } }
        .onChange(of: text) { _, t in if !t.isEmpty { keyOK = true; heardOK = true } }
    }

    private func check(_ label: String, _ ok: Bool) -> some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .animation(Motion.enter, value: ok)
    }
}
