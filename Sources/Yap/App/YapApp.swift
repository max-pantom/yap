import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@main
struct YapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    init() { SelfTest.runIfRequested() }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(nsImage: model.menuImage)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.boot() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(URLCommands.handle) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let history = HistoryStore()
    let library = LibraryStore()
    lazy var dictation = DictationController(history: history)
    lazy var recorder = RecordingController(library: library)

    /// The live mark in the menu bar (a template image, so macOS tints it for light and dark bars).
    @Published private(set) var menuImage = MarkRenderer.menuBarImage(MarkMotion.shared.frame)
    private var windows: [String: NSWindow] = [:]
    private var hotKeys = GlobalHotKeys()
    private var observers: [Any] = []

    func boot() {
        Prefs.registerDefaults()
        Updater.shared.start()
        dictation.boot()
        library.reload()

        registerGlobalHotKeys()
        observers.append(NotificationCenter.default.addObserver(forName: Shortcut.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.registerGlobalHotKeys() }
        })

        // What the mark does follows what Yap is doing.
        observers.append(recorder.$phase.combineLatest(dictation.$phase).sink { rec, dic in
            let state: MarkMotion.State = switch (rec, dic) {
            case (.recording, _), (.countdown, _): .recording
            case (_, .listening), (_, .locked): .listening
            case (_, .thinking), (.processing, _): .thinking
            default: .idle
            }
            MarkMotion.shared.set(state)
        })
        // The menu bar redraws at most 30×/s, and only while the mark is moving.
        observers.append(MarkMotion.shared.$frame
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] f in self?.menuImage = MarkRenderer.menuBarImage(f) })

        if UserDefaults.standard.bool(forKey: Prefs.Key.startupAnimation), !CommandLine.arguments.contains("--demo-bar") {
            Splash.show()
        }

        if let i = CommandLine.arguments.firstIndex(of: "--demo-bar"), i + 1 < CommandLine.arguments.count {
            dictation.demo(CommandLine.arguments[i + 1])
        } else if CommandLine.arguments.contains("--settings") {
            showSettings()
        } else if !UserDefaults.standard.bool(forKey: Prefs.Key.onboarded) || !Permission.dictationReady {
            showOnboarding()
        }
    }

    func registerGlobalHotKeys() {
        hotKeys.unregisterAll()
        if let s = Shortcut.get(.record) {
            hotKeys.register(key: Int(s.keyCode), modifiers: s.carbonModifiers) { [weak self] in self?.recorder.toggle() }
        }
        if let s = Shortcut.get(.camera) {
            hotKeys.register(key: Int(s.keyCode), modifiers: s.carbonModifiers) { [weak self] in self?.recorder.camera.toggle() }
        }
        if let s = Shortcut.get(.pasteLast) {
            hotKeys.register(key: Int(s.keyCode), modifiers: s.carbonModifiers) { [weak self] in self?.dictation.pasteLast() }
        }
    }

    // MARK: Windows (AppKit-hosted so they can be opened from hotkeys and the menu alike)

    func showLibrary() {
        library.reload()
        show(id: "library", title: "Yap", size: NSSize(width: 1060, height: 680), resizable: true) {
            LibraryView().environmentObject(self)
        }
    }

    func showSettings() {
        show(id: "settings", title: "Yap Settings", size: NSSize(width: 760, height: 560), resizable: false) {
            SettingsView().environmentObject(self)
        }
    }

    func showOnboarding() {
        show(id: "onboarding", title: "Welcome to Yap", size: NSSize(width: 600, height: 800), resizable: false) {
            OnboardingView(dictation: dictation) { [weak self] in
                UserDefaults.standard.set(true, forKey: Prefs.Key.onboarded)
                self?.windows["onboarding"]?.close()
                self?.dictation.hotkeys.start()
            }
        }
    }

    private func show<V: View>(id: String, title: String, size: NSSize, resizable: Bool, @ViewBuilder content: () -> V) {
        let window = windows[id] ?? {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if resizable { style.insert(.resizable); style.insert(.fullSizeContentView) }
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: content())
            w.setContentSize(size)
            w.center()
            if id == "onboarding" {
                // Stay visible above System Settings while permissions are granted, parked on the left.
                w.level = .floating
                if let f = NSScreen.main?.visibleFrame {
                    w.setFrameOrigin(NSPoint(x: f.minX + 24, y: f.maxY - w.frame.height - 24))
                }
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.updateActivationPolicy() } }
            })
            windows[id] = w
            return w
        }()
        // While a window is open, show in the Dock and ⌘-Tab so it can't get lost behind other apps.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func updateActivationPolicy() {
        let anyOpen = windows.values.contains { $0.isVisible }
        NSApp.setActivationPolicy(anyOpen ? .regular : .accessory)
    }

    /// macOS applies some permissions (Input Monitoring, Screen Recording) only after a restart.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        MenuStatus(dictation: model.dictation, recorder: model.recorder)
        Divider()
        RecordButtons(recorder: model.recorder)
        Button((model.recorder.camera.isVisible ? "Hide Camera Bubble" : "Show Camera Bubble") + "  (\(Shortcut.label(.camera)))") { model.recorder.camera.toggle() }
        CameraPicker { model.recorder.camera.useSelectedDevice() }
        MicPicker()
        Divider()
        RecentDictations(history: model.history, dictation: model.dictation)
        Button("Open Library…") { model.showLibrary() }.keyboardShortcut("l")
        Button("Settings…") { model.showSettings() }.keyboardShortcut(",")
        if Updater.shared.isAvailable { Button("Check for Updates…") { Updater.shared.checkForUpdates() } }
        Divider()
        Button("Quit Yap") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private struct MenuStatus: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var recorder: RecordingController
    var body: some View {
        if recorder.phase == .processing {
            Text(recorder.processingStatus.isEmpty ? "Processing recording…" : recorder.processingStatus)
        } else if !Permission.dictationReady {
            Text("⚠︎ Permissions needed: open Settings")
        } else {
            Text("Hold \(Shortcut.label(.dictate)) to dictate · \(dictation.engineStatus)")
            Text("Speech: \(WhisperEngine.shared.selectedVariant.map { "Whisper " + WhisperEngine.title(for: $0) } ?? "Apple") · AI: \(LLM.label)")
        }
    }
}

private struct RecordButtons: View {
    @ObservedObject var recorder: RecordingController
    var body: some View {
        if recorder.phase == .recording {
            Button("Stop Recording  (\(Shortcut.label(.record)))") { Task { await recorder.stop() } }
            Button("Discard Recording") { recorder.cancel() }
        } else {
            Button("Record Screen  (\(Shortcut.label(.record)))") { recorder.toggle() }
            Button("Record Window or App…") { recorder.recordPicked() }
        }
    }
}

private struct RecentDictations: View {
    @ObservedObject var history: HistoryStore
    let dictation: DictationController
    var body: some View {
        if !history.entries.isEmpty {
            Menu("Recent Dictations") {
                ForEach(history.entries.prefix(8)) { e in
                    Button(String(e.text.prefix(60)) + (e.text.count > 60 ? "…" : "")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.text, forType: .string)
                    }
                }
                Text("Click to copy")
            }
        }
    }
}

/// Carbon global hotkeys: system-level, need no permission, swallow only their own combo, and never
/// sit in the path of normal typing. Supports press and release (for hold-to-talk combos).
final class GlobalHotKeys {
    private var pressHandlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private let signature: OSType

    init(signature: OSType = OSType(0x5941_5021)) { self.signature = signature } // 'YAP!'

    func register(key: Int, modifiers: Int, onRelease: (@MainActor () -> Void)? = nil, handler: @escaping @MainActor () -> Void) {
        if handlerRef == nil { install() }
        let id = nextID
        nextID += 1
        pressHandlers[id] = { MainActor.assumeIsolated { handler() } }
        if let onRelease { releaseHandlers[id] = { MainActor.assumeIsolated { onRelease() } } }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        pressHandlers.removeAll()
        releaseHandlers.removeAll()
    }

    private func install() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            guard hk.signature == me.signature else { return OSStatus(eventNotHandledErr) } // another instance's key
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { me.releaseHandlers[hk.id]?() } else { me.pressHandlers[hk.id]?() }
            return noErr
        }, specs.count, &specs, me, &handlerRef)
    }
}
