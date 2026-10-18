import Combine
import ServiceManagement
import SwiftUI

/// Which Settings page is showing; shared so other screens (and yap://settings) can open a page directly.
@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsView.Page = .dictation
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var nav = SettingsNav.shared

    enum Page: String, CaseIterable, Identifiable {
        case dictation = "Dictation", commands = "Voice Commands", words = "Words & Snippets", recording = "Recording",
             iphone = "iPhone Mic", models = "AI Models", shortcuts = "Shortcuts", permissions = "Permissions", general = "General"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dictation: "mic"
            case .commands: "text.bubble"
            case .words: "character.book.closed"
            case .recording: "record.circle"
            case .iphone: "iphone"
            case .models: "cpu"
            case .shortcuts: "keyboard"
            case .permissions: "lock.shield"
            case .general: "gearshape"
            }
        }
        /// "commands", "voice-commands", "Voice Commands" → .commands (for --settings and yap://settings?page=).
        static func named(_ s: String) -> Page? {
            let k = s.lowercased().filter(\.isLetter)
            return allCases.first { String(describing: $0).lowercased() == k || $0.rawValue.lowercased().filter(\.isLetter) == k }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) {
                Section { ForEach(Page.allCases.prefix(4)) { p in Label(p.rawValue, systemImage: p.symbol).tag(p) } }
                Section("More") { ForEach(Page.allCases.dropFirst(4).prefix(3)) { p in Label(p.rawValue, systemImage: p.symbol).tag(p) } }
                Section("Setup") { ForEach(Page.allCases.suffix(2)) { p in Label(p.rawValue, systemImage: p.symbol).tag(p) } }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Group {
                switch nav.page {
                case .dictation: DictationTab()
                case .commands: VoiceCommandsTab()
                case .words: WordsTab()
                case .recording: RecordingTab()
                case .iphone: IPhoneTab(remote: RemoteMic.shared)
                case .models: ModelsTab()
                case .shortcuts: ShortcutsTab()
                case .permissions:
                    Form {
                        SettingsHeader(page: .permissions, text: "What Yap needs from macOS, and why. Green means it's on.")
                        Section { PermissionsView() }
                    }.formStyle(.grouped)
                case .general: GeneralTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 600)
    }
}

/// The top of every page: its icon, name and one sentence on what it's for.
struct SettingsHeader: View {
    let page: SettingsView.Page
    let text: String
    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: page.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.rawValue).font(.title3.weight(.semibold))
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A link-style button that opens another Settings page.
private struct GoTo: View {
    let page: SettingsView.Page
    var title: String? = nil
    var body: some View {
        Button(title ?? "Open \(page.rawValue)") { SettingsNav.shared.page = page }.buttonStyle(.link)
    }
}

// MARK: - Dictation

private struct DictationTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.Key.cleanupStyle) var style = CleanupStyle.polished.rawValue
    @AppStorage(Prefs.Key.locale) var locale = ""
    @AppStorage(Prefs.Key.keepOnClipboard) var keepOnClipboard = true
    @AppStorage(Prefs.Key.learnCorrections) var learnCorrections = true
    @AppStorage(Prefs.Key.translateTo) var translateTo = ""
    @AppStorage(Prefs.Key.fitToCursor) var fitToCursor = true
    @Local private var locales: [String] = []

    private var currentStyle: CleanupStyle { CleanupStyle(rawValue: style) ?? .polished }

    var body: some View {
        Form {
            SettingsHeader(page: .dictation, text: "Hold your key, talk, let go. Yap types what you said wherever your cursor is.")

            Section("Basics") {
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(Shortcut.label(.dictate)).foregroundStyle(.secondary)
                        GoTo(page: .shortcuts, title: "Change")
                    }
                } label: {
                    Text("Dictation key")
                    Text("Hold to talk. Double-tap for hands-free, press again to finish.")
                }
                if Shortcut.get(.dictate)?.keyCode == 63 {
                    HStack {
                        Text("Fn also opens the emoji picker. In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }.controlSize(.small)
                    }
                }
                MicPicker()
                Picker(selection: $locale) {
                    Text("Same as my Mac").tag("")
                    ForEach(locales, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) }
                } label: {
                    Text("Language you speak")
                }
                .onChange(of: locale) { _, _ in model.dictation.boot() }
            }

            Section("What gets typed") {
                Picker(selection: $style) {
                    ForEach(CleanupStyle.allCases) { Text($0.label).tag($0.rawValue) }
                } label: {
                    Text("Clean-up")
                    Text(currentStyle.detail)
                }
                if !Polisher.shared.modelAvailable && currentStyle != .verbatim {
                    Label("No AI model is on, so only basic clean-up happens. Turn on Apple Intelligence, or pick a model.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    GoTo(page: .models)
                }
                Toggle(isOn: $fitToCursor) {
                    Text("Fit in with the text around the cursor")
                    Text("Mid-sentence, Yap adds the space and keeps it lowercase. Names keep their capitals.")
                }
                Picker(selection: $translateTo) {
                    Text("Off").tag("")
                    ForEach(Array(Set(VoiceCommands.languages.values)).sorted(), id: \.self) { Text($0).tag($0) }
                } label: {
                    Text("Always translate to")
                    Text("Talk in your language, type in this one. To translate just once, say “…translate to French”.")
                }
                Toggle(isOn: $keepOnClipboard) {
                    Text("Also copy it to the clipboard")
                    Text("If no text box was selected, press ⌘V to paste it yourself.")
                }
            }

            Section("Learning") {
                Toggle(isOn: $learnCorrections) {
                    Text("Learn from my corrections")
                    Text("Fix a word right after it's typed (Jon → John) and Yap spells it right next time.")
                }
                LabeledContent("Learned words and spellings") { GoTo(page: .words, title: "See list") }
            }

            Section("Speech recognition") {
                LabeledContent("Status", value: model.dictation.engineStatus)
                LabeledContent("Engine") { GoTo(page: .models, title: "Change in AI Models") }
            }

            Section { PracticeView(dictation: model.dictation) }
        }
        .formStyle(.grouped)
        .task { locales = await SpeechEngine.supportedLocales().map(\.identifier).sorted() }
    }
}

// MARK: - Voice commands

private struct VoiceCommandsTab: View {
    @AppStorage(Prefs.Key.voiceCommands) var voiceCommands = true

    var body: some View {
        Form {
            SettingsHeader(page: .commands, text: "Things you can say that do something instead of being typed.")
            Section {
                Toggle(isOn: $voiceCommands) {
                    Text("Voice commands")
                    Text("Off: every word is typed exactly as you say it.")
                }
            }
            Group {
                Section("Fix as you go") {
                    CommandRow(say: "…scratch that…", does: "Removes the sentence you just said")
                    CommandRow(say: "scratch that", note: "on its own", does: "Takes back your last dictation")
                    CommandRow(say: "new line  ·  new paragraph", does: "Starts a new line or paragraph")
                }
                Section("Send") {
                    CommandRow(say: "…send it", does: "Types the message, then presses Return")
                    CommandRow(say: "…press enter", does: "Same as “send it”")
                }
                Section("Translate") {
                    CommandRow(say: "…translate to French", does: "Types it in French. Works with about 40 languages")
                    CommandRow(say: "Translate to Spanish: …", does: "Same, said at the start")
                }
                Section("Maths") {
                    CommandRow(say: "what's 40 plus 20", does: "Types 60")
                    CommandRow(say: "…40 plus 20 equals", does: "Types 40 + 20 = 60")
                    CommandRow(say: "calculate 15 percent of 200", does: "Types 30")
                }
            }
            .disabled(!voiceCommands)
            .opacity(voiceCommands ? 1 : 0.5)
            Section {
                CommandRow(say: "make this friendlier", note: "with text selected", does: "Rewrites the selected text")
                CommandRow(say: "write a thank-you note", note: "nothing selected", does: "Writes new text for you")
            } header: {
                Text("Command Mode")
            } footer: {
                Text("Hold \(Shortcut.label(.command) == "not set" ? "your dictation key + ⌃" : Shortcut.label(.command)) instead of the dictation key. Needs Apple Intelligence or another AI model.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CommandRow: View {
    let say: String
    var note: String? = nil
    let does: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(say)”").font(.body.weight(.medium))
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: 240, alignment: .leading)
            Text(does).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Words

private struct WordsTab: View {
    @AppStorage(Prefs.Key.dictionary) var dictionary = ""
    @AppStorage(Prefs.Key.snippets) var snippets = ""

    var body: some View {
        Form {
            SettingsHeader(page: .words, text: "Teach Yap your names and terms, and save phrases you say often.")
            Section {
                TextEditor(text: $dictionary).font(.body.monospaced()).frame(height: 120)
            } header: {
                Text("Dictionary")
            } footer: {
                Text("One per line. `Kubernetes` teaches a spelling. `chat gpt => ChatGPT` always replaces what was heard. Words Yap learns from your corrections are added here.")
            }
            Section {
                TextEditor(text: $snippets).font(.body.monospaced()).frame(height: 120)
            } header: {
                Text("Snippets")
            } footer: {
                Text("Say the trigger on its own to type the text: `my link => https://cal.com/me`. Fill-ins: {date} {time} {day} {year} {clipboard}. Use \\n for a new line.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recording

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
            SettingsHeader(page: .recording, text: "Press \(Shortcut.label(.record)) to record your screen. When you stop, the video is copied, ready to paste.")

            Section("Camera and sound") {
                Toggle(isOn: $camera) {
                    Text("Show my camera")
                    Text("A round bubble you can drag anywhere.")
                }
                CameraPicker { AppModel.shared.recorder.camera.useSelectedDevice() }
                Button("Preview camera bubble") { AppModel.shared.recorder.camera.toggle() }
                Toggle("Record my microphone", isOn: $mic)
                MicPicker()
                Toggle(isOn: $systemAudio) {
                    Text("Record sound from my Mac")
                    Text("Audio from apps, like a video you play.")
                }
                DisclosureGroup("Use your iPhone as the camera") { ContinuityHint() }
            }

            Section("While recording") {
                Toggle(isOn: $countdown) {
                    Text("Count down 3, 2, 1")
                    Text("Time to get ready before it starts.")
                }
                Toggle(isOn: $clicks) {
                    Text("Highlight clicks")
                    Text("A ring appears where you click.")
                }
                Toggle(isOn: $showKeystrokes) {
                    Text("Show keyboard shortcuts")
                    Text("Shortcuts like ⌘K appear on screen. Ordinary typing never does.")
                }
            }

            Section {
                Toggle(isOn: $autoCopy) {
                    Text("Copy the video when I stop")
                    Text("Paste it straight into Slack, Mail or an issue.")
                }
                Toggle(isOn: $autoZoom) {
                    Text("Zoom in where I click")
                    Text("Smooth zooms on full-screen recordings. The original is kept.")
                }
                if autoZoom {
                    LabeledContent("Zoom strength") {
                        Slider(value: $zoomLevel, in: 1.3...2.6, step: 0.1) { Text("Zoom strength") } minimumValueLabel: { Text("Subtle") } maximumValueLabel: { Text("Close") }
                            .labelsHidden().frame(width: 240)
                    }
                }
            } header: {
                Text("After recording")
            } footer: {
                Text("Every recording also gets a transcript, captions, a title, a summary and chapters, made on this Mac. Find them in the Library.")
            }

            Section("Video file") {
                Picker("Format", selection: $codec) {
                    Text("H.264, plays everywhere").tag("h264")
                    Text("HEVC, half the size").tag("hevc")
                }
                Picker("Smoothness", selection: $fps) {
                    Text("30 frames a second").tag(30)
                    Text("60 frames a second").tag(60)
                }
                LabeledContent("Saved in") {
                    Button(Prefs.recordingsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        try? FileManager.default.createDirectory(at: Prefs.recordingsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Prefs.recordingsFolder)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - iPhone

private struct IPhoneTab: View {
    @ObservedObject var remote: RemoteMic
    @Local private var showingCode = false
    @Local private var confirmUnpair = false

    var body: some View {
        Form {
            SettingsHeader(page: .iphone, text: "Talk into your iPhone from anywhere in the room. The text appears at your cursor on this Mac.")
            if let p = remote.pairing {
                Section("Your iPhone") {
                    LabeledContent("Status") {
                        switch remote.state {
                        case .connected(let name): Label("\(name) is connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .waiting: Text("Paired. Open Yap Mic on your iPhone to connect").foregroundStyle(.secondary)
                        case .failed(let e): Text(e).foregroundStyle(.orange)
                        case .off: Text("Off").foregroundStyle(.secondary)
                        }
                    }
                    if showingCode { code(p) }
                    HStack {
                        Button(showingCode ? "Hide pairing code" : "Show pairing code") { showingCode.toggle() }
                        Spacer()
                        Button("Unpair", role: .destructive) { confirmUnpair = true }
                            .confirmationDialog("Unpair your iPhone?", isPresented: $confirmUnpair) {
                                Button("Unpair", role: .destructive) { remote.unpair() }
                            } message: { Text("Yap stops listening for it. You can pair again any time.") }
                    }
                }
            } else {
                Section("Set up in three steps") {
                    Label("Install Yap Mic on your iPhone (build it from the Companion folder in Yap's source).", systemImage: "1.circle")
                    Label("Click Pair iPhone below. A code appears.", systemImage: "2.circle")
                    Label("In Yap Mic, tap Pair and scan the code.", systemImage: "3.circle")
                    Button("Pair iPhone") { _ = remote.pair(); showingCode = true }.buttonStyle(.borderedProminent)
                }
            }
            Section("Privacy") {
                Text("Your voice goes straight from the phone to this Mac over your Wi-Fi, encrypted with a key only the two of them share. Nothing goes through the internet.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func code(_ p: MicLink.Pairing) -> some View {
        if let img = RemoteMic.qrImage(for: p) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: img).interpolation(.none).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Pairing code")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan with Yap Mic").font(.headline)
                    Text("In Yap Mic, tap Pair and point the camera here. Keep this code private: anyone with it can use this Mac's dictation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.Key.sounds) var sounds = true
    @AppStorage(Prefs.Key.showFlowBar) var showFlowBar = true
    @AppStorage(Prefs.Key.startupAnimation) var startupAnimation = true
    @AppStorage(Prefs.Key.urlCommands) var urlCommands = true
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            SettingsHeader(page: .general, text: "How Yap starts, sounds and shows itself.")

            Section("Flow bar") {
                Toggle(isOn: $showFlowBar) {
                    Text("Always show the Flow bar")
                    Text("The small pill at the bottom of your screen. Off: it only appears while you talk.")
                }
                .onChange(of: showFlowBar) { _, _ in FlowBar.shared.update() }
                LabeledContent {
                    Button("Move to bottom centre") { FlowBar.shared.resetPosition() }
                } label: {
                    Text("Position")
                    Text("Drag the pill to move it anywhere.")
                }
            }

            Section("Startup and sounds") {
                Toggle("Open Yap when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = !on }
                    }
                Toggle("Play the logo animation at startup", isOn: $startupAnimation)
                Toggle(isOn: $sounds) {
                    Text("Play sounds")
                    Text("A soft tone when Yap starts and stops listening.")
                }
            }

            if Updater.shared.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(get: { Updater.shared.automaticallyChecks }, set: { Updater.shared.automaticallyChecks = $0 }))
                    Button("Check now") { Updater.shared.checkForUpdates() }
                }
            }

            Section("Automation") {
                Toggle(isOn: $urlCommands) {
                    Text("Let other apps control Yap")
                    Text("Shortcuts, Raycast, Stream Deck or scripts can open yap:// links. Browsers ask first.")
                }
                if urlCommands {
                    DisclosureGroup("All links") {
                        ForEach(URLCommands.reference, id: \.0) { url, what in
                            LabeledContent {
                                Text(what).foregroundStyle(.secondary)
                            } label: {
                                Text(url).font(.callout.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            Section("Privacy") {
                Text("Everything runs on this Mac: speech recognition, AI clean-up and summaries. No account, no uploads, no analytics.")
                    .foregroundStyle(.secondary)
            }
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
            DisclosureGroup("Having trouble?") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Yap not in a list in System Settings? Click + there and add Yap, or drag it in from Finder.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Yap in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                            .controlSize(.small)
                    }
                    HStack {
                        Text("A switch keeps turning off? Click Allow above to reset it, turn Yap on again, then relaunch. Screen Recording always needs a relaunch.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Yap") { AppModel.relaunch() }.controlSize(.small)
                    }
                }
                .padding(.top, 6)
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
