import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The new Settings design (Labs, on by default): icon tabs in the window toolbar, labels right-aligned
/// against checkboxes and radio buttons, like Apple's own apps and Things. A native toolbar tab controller,
/// so macOS draws the toolbar in Liquid Glass and resizes the window to each page.
@MainActor
final class ToolbarSettingsController: NSTabViewController {
    typealias Page = SettingsView.Page
    private var subs: Set<AnyCancellable> = []
    private var shownIPhone = Prefs.iPhoneMicOn

    /// Toolbar order. The iPhone tab only appears once its experiment is on.
    private var pages: [Page] {
        [.general, .dictation, .commands, .recording, .words, .models, .shortcuts, .permissions] + (shownIPhone ? [.iphone] : [])
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.allowUserInteraction]
        for p in pages { addTabViewItem(item(for: p)) }
        select(SettingsNav.shared.page)
        SettingsNav.shared.$page.removeDuplicates().sink { [weak self] in self?.select($0) }.store(in: &subs)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIPhoneTab() }
            .store(in: &subs)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Loading the view selects the first tab; keep the page that was asked for instead.
    private var loaded = false
    override func viewDidLoad() {
        let wanted = SettingsNav.shared.page
        super.viewDidLoad()
        loaded = true
        select(wanted)
    }

    private func item(for p: Page) -> NSTabViewItem {
        let host = NSHostingController(rootView: ToolbarPage(page: p).environmentObject(AppModel.shared))
        host.sizingOptions = [.preferredContentSize]
        host.title = p.rawValue
        let it = NSTabViewItem(viewController: host)
        it.identifier = p.rawValue
        it.label = p.tabLabel
        it.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.rawValue)
        return it
    }

    private func select(_ p: Page) {
        guard let i = tabViewItems.firstIndex(where: { $0.identifier as? String == p.rawValue }), i != selectedTabViewItemIndex else { return }
        selectedTabViewItemIndex = i
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if loaded, let id = item?.identifier as? String, let p = Page(rawValue: id), SettingsNav.shared.page != p { SettingsNav.shared.page = p }
    }

    private func refreshIPhoneTab() {
        guard Prefs.iPhoneMicOn != shownIPhone else { return }
        shownIPhone = Prefs.iPhoneMicOn
        if shownIPhone {
            addTabViewItem(item(for: .iphone))
        } else if let i = tabViewItems.firstIndex(where: { $0.identifier as? String == Page.iphone.rawValue }) {
            if selectedTabViewItemIndex == i { selectedTabViewItemIndex = 0 }
            removeTabViewItem(tabViewItems[i])
        }
    }
}

extension SettingsView.Page {
    /// Short names that fit under a toolbar icon.
    var tabLabel: String {
        switch self {
        case .commands: "Commands"
        case .words: "Words"
        case .models: "AI"
        case .shortcuts: "Keys"
        case .iphone: "iPhone"
        default: rawValue
        }
    }
}

private struct ToolbarPage: View {
    let page: SettingsView.Page
    var body: some View {
        switch page {
        case .general: ColumnsPage { GeneralColumns() }
        case .dictation: ColumnsPage { DictationColumns() }
        case .recording: ColumnsPage { RecordingColumns() }
        case .words: ColumnsPage { WordsColumns() }
        // Lists and tables keep the grouped layout; the window title already names the page.
        case .commands: GroupedPage { VoiceCommandsTab() }
        case .models: GroupedPage(height: 600) { ModelsTab() }
        case .shortcuts: GroupedPage { ShortcutsTab() }
        case .iphone: GroupedPage { IPhoneTab(remote: RemoteMic.shared) }
        case .permissions:
            GroupedPage(height: 400) {
                Form {
                    Section {
                        PermissionsView()
                    } footer: {
                        Text("What Yap needs from macOS, and why. Everything stays on this Mac.")
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

private let pageWidth: CGFloat = 640

/// A page of label: control rows that sizes the window to fit.
private struct ColumnsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.columns)
            .padding(.horizontal, 40)
            .padding(.vertical, 26)
            .frame(width: pageWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GroupedPage<Content: View>: View {
    var height: CGFloat = 540
    @ViewBuilder var content: Content
    var body: some View {
        content
            .environment(\.settingsHeaderHidden, true)
            .frame(width: pageWidth, height: height)
    }
}

/// The thin rule between groups of rows.
private struct GroupRule: View {
    var body: some View { Divider().padding(.vertical, 8) }
}

/// The grey line under a checkbox or radio button.
private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
    }
}

/// A label on the left, a column of controls on the right.
private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        LabeledContent("\(label):") {
            VStack(alignment: .leading, spacing: 6) { content }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - General

private struct GeneralColumns: View {
    @AppStorage(Prefs.Key.sounds) var sounds = true
    @AppStorage(Prefs.Key.showFlowBar) var showFlowBar = true
    @AppStorage(Prefs.Key.startupAnimation) var startupAnimation = true
    @AppStorage(Prefs.Key.urlCommands) var urlCommands = true
    @AppStorage(Prefs.Key.showExperimental) var showExperimental = false
    @AppStorage(Prefs.Key.labsIPhoneMic) var iPhoneMic = false
    @AppStorage(Prefs.Key.labsNewSettings) var newSettings = true
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Section {
            Row("Startup") {
                Toggle("Open Yap when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = !on }
                    }
                Toggle("Play the logo animation", isOn: $startupAnimation)
            }
            Row("Sounds") {
                Toggle("Play a tone when Yap starts and stops listening", isOn: $sounds)
            }
            Row("Flow bar") {
                Toggle("Always show the Flow bar", isOn: $showFlowBar)
                    .onChange(of: showFlowBar) { _, _ in FlowBar.shared.update() }
                Hint("Off: the pill only appears while you talk. Drag it to move it.")
                Button("Move to Bottom Centre") { FlowBar.shared.resetPosition() }.padding(.top, 2)
            }
        }
        GroupRule()
        Section {
            if Updater.shared.isAvailable {
                Row("Updates") {
                    Toggle("Check for updates automatically",
                           isOn: Binding(get: { Updater.shared.automaticallyChecks }, set: { Updater.shared.automaticallyChecks = $0 }))
                    Button("Check Now") { Updater.shared.checkForUpdates() }.padding(.top, 2)
                }
            }
            Row("Automation") {
                Toggle("Let other apps control Yap", isOn: $urlCommands)
                Hint("Shortcuts, Raycast, Stream Deck or scripts can open yap:// links.")
            }
        }
        GroupRule()
        Section {
            Row("Experimental") {
                Toggle("New Settings design", isOn: $newSettings)
                    .onChange(of: newSettings) { _, _ in AppModel.shared.reopenSettings() }
                Hint("These tabs. Off: the sidebar layout.")
                Toggle("Show more experimental features", isOn: $showExperimental)
                if showExperimental {
                    Toggle("iPhone Mic", isOn: $iPhoneMic)
                        .onChange(of: iPhoneMic) { _, _ in RemoteMic.shared.refresh() }
                        .padding(.leading, 20)
                    Hint("Use your iPhone as a wireless microphone. Adds an iPhone tab.").padding(.leading, 20)
                }
            }
        } footer: {
            Text("Everything runs on this Mac: speech, AI clean-up and summaries. No account, no uploads, no analytics.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 8)
        }
    }
}

// MARK: - Dictation

private struct DictationColumns: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.Key.cleanupStyle) var style = CleanupStyle.polished.rawValue
    @AppStorage(Prefs.Key.locale) var locale = ""
    @AppStorage(Prefs.Key.keepOnClipboard) var keepOnClipboard = true
    @AppStorage(Prefs.Key.learnCorrections) var learnCorrections = true
    @AppStorage(Prefs.Key.translateTo) var translateTo = ""
    @AppStorage(Prefs.Key.fitToCursor) var fitToCursor = true
    @AppStorage(Prefs.Key.voiceCommands) var voiceCommands = true
    @Local private var locales: [String] = []

    private var currentStyle: CleanupStyle { CleanupStyle(rawValue: style) ?? .polished }

    var body: some View {
        Section {
            Row("Dictation key") {
                HStack(spacing: 8) {
                    Text(Shortcut.label(.dictate)).font(.body.weight(.semibold)).lineLimit(1).fixedSize()
                        .frame(minWidth: 120).padding(.vertical, 3).padding(.horizontal, 10)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button("Change…") { SettingsNav.shared.page = .shortcuts }
                }
                Hint("Hold to talk. Double-tap for hands-free.").padding(.leading, -20)
            }
            LabeledContent("Microphone:") { MicPicker().labelsHidden().fixedSize() }
            LabeledContent("Language:") {
                Picker("Language", selection: $locale) {
                    Text("Same as my Mac").tag("")
                    ForEach(locales, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: locale) { _, _ in model.dictation.boot() }
            }
        }
        GroupRule()
        Section {
            LabeledContent("Clean-up:") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Clean-up", selection: $style) {
                        ForEach(CleanupStyle.allCases) { s in Text(s.label).tag(s.rawValue) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    Hint(currentStyle.detail)
                    if !Polisher.shared.modelAvailable && currentStyle != .verbatim {
                        Button("No AI model is on, so only basic clean-up happens. Choose one…") { SettingsNav.shared.page = .models }
                            .buttonStyle(.link).font(.caption).padding(.leading, 20)
                    }
                }
            }
            Row("When typing") {
                Toggle("Fit in with the text around the cursor", isOn: $fitToCursor)
                Toggle("Also copy it to the clipboard", isOn: $keepOnClipboard)
                Toggle("Learn from my corrections", isOn: $learnCorrections)
                Toggle("Understand voice commands", isOn: $voiceCommands)
                Button("See what you can say…") { SettingsNav.shared.page = .commands }.buttonStyle(.link).font(.caption).padding(.leading, 20)
            }
            LabeledContent("Translate to:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Translate to", selection: $translateTo) {
                        Text("Off").tag("")
                        ForEach(Array(Set(VoiceCommands.languages.values)).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text("Or just once: say “…translate to French”.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        GroupRule()
        Section {
            LabeledContent("History:") {
                VStack(alignment: .leading, spacing: 4) {
                    HistoryFolderControl()
                    Text("Every dictation (history.json), for the Library's Dictations list.").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Speech:") {
                HStack(spacing: 8) {
                    Text(model.dictation.engineStatus).foregroundStyle(.secondary)
                    Button("Change…") { SettingsNav.shared.page = .models }.buttonStyle(.link)
                }
            }
        }
        .task { locales = await SpeechEngine.supportedLocales().map(\.identifier).sorted() }
    }
}

// MARK: - Recording

private struct RecordingColumns: View {
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
    @AppStorage(Prefs.Key.meetingCopyNotes) var meetingCopyNotes = true

    var body: some View {
        Section {
            Row("Camera") {
                Toggle("Show my camera in a round bubble", isOn: $camera)
                HStack(spacing: 8) {
                    CameraPicker { AppModel.shared.recorder.camera.useSelectedDevice() }.labelsHidden().fixedSize()
                    Button("Preview") { AppModel.shared.recorder.camera.toggle() }
                }
                .disabled(!camera)
            }
            Row("Sound") {
                Toggle("Record my microphone", isOn: $mic)
                MicPicker().labelsHidden().fixedSize().disabled(!mic)
                Toggle("Record sound from my Mac", isOn: $systemAudio)
            }
        }
        GroupRule()
        Section {
            Row("While recording") {
                Toggle("Count down 3, 2, 1", isOn: $countdown)
                Toggle("Highlight clicks", isOn: $clicks)
                Toggle("Show keyboard shortcuts on screen", isOn: $showKeystrokes)
            }
            Row("When I stop") {
                Toggle("Copy the video, ready to paste", isOn: $autoCopy)
                Toggle("Zoom in where I click", isOn: $autoZoom)
                if autoZoom {
                    Slider(value: $zoomLevel, in: 1.3...2.6, step: 0.1) { Text("Zoom strength") }
                        minimumValueLabel: { Text("Subtle").font(.caption) } maximumValueLabel: { Text("Close").font(.caption) }
                        .labelsHidden().frame(width: 240).padding(.leading, 20)
                }
            }
        }
        GroupRule()
        Section {
            Row("Meetings") {
                Toggle("Copy the notes when a meeting ends", isOn: $meetingCopyNotes)
                Hint("Press \(Shortcut.label(.meeting)) when a call starts. Yap writes who said what, a summary and action items. Headphones give the cleanest notes.")
            }
        }
        GroupRule()
        Section {
            LabeledContent("Format:") {
                Picker("Format", selection: $codec) {
                    Text("H.264, plays everywhere").tag("h264")
                    Text("HEVC, half the size").tag("hevc")
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            LabeledContent("Frame rate:") {
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
            }
            LabeledContent("Saved in:") {
                VStack(alignment: .leading, spacing: 4) {
                    RecordingsFolderControl()
                    Text("Videos, captions, their notes and meeting notes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Words

private struct WordsColumns: View {
    @AppStorage(Prefs.Key.dictionary) var dictionary = ""
    @AppStorage(Prefs.Key.snippets) var snippets = ""

    var body: some View {
        Section {
            LabeledContent("Dictionary:") {
                VStack(alignment: .leading, spacing: 6) {
                    editor($dictionary)
                    Text("One per line. `Kubernetes` teaches a spelling; `chat gpt => ChatGPT` always replaces it. Words learned from your corrections land here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        GroupRule()
        Section {
            LabeledContent("Snippets:") {
                VStack(alignment: .leading, spacing: 6) {
                    editor($snippets)
                    Text("Say the trigger on its own: `my link => https://cal.com/me`. Fill-ins: {date} {time} {day} {year} {clipboard}. \\n for a new line.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(width: 380, height: 120)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }
}
