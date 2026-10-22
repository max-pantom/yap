import AppKit
import Carbon.HIToolbox
import Combine
import NaturalLanguage

@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable { case idle, listening, locked, thinking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isCommand = false
    @Published private(set) var liveText = ""
    @Published var engineStatus = "Loading speech model…"
    /// Short message shown on the Flow bar (errors, hints). Clears itself.
    @Published private(set) var notice: Notice?

    struct Notice: Equatable { var text: String; var symbol: String; var isError: Bool }
    private var noticeTask: Task<Void, Never>?

    let hotkeys = HotkeyMonitor()
    private let mic = MicCapture()
    private var session: SpeechEngine.LiveSession?
    private var targetApp: NSRunningApplication?
    private var selectionTask: Task<String?, Never>?
    private var startedAt = Date()
    private let history: HistoryStore
    /// Set while the iPhone is the microphone.
    private var remoteFeed: RemoteFeed?
    var isRemote: Bool { remoteFeed != nil }
    /// What was pasted last (shown on the iPhone).
    private(set) var lastOutput: String?
    /// Loudest level heard this session, for the "can't hear you" check.
    private var peakLevel: Float = 0
    private var silenceCheck: Task<Void, Never>?
    /// The last paste, so "scratch that" can take it back.
    private var lastDelivery: (app: pid_t, at: Date)?

    init(history: HistoryStore) {
        self.history = history
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        CorrectionLearner.shared.onLearn = { [weak self] pairs in
            let list = pairs.map { "“\($0.1)”" }.joined(separator: ", ")
            self?.show("Learned \(list) · edit in Settings → Words", symbol: "character.book.closed.fill", error: false, seconds: 3)
        }
    }

    func boot() {
        RemoteMic.shared.boot(self)
        hotkeys.start()
        FlowBar.shared.attach(self)
        Log.write("boot: mic=\(Permission.microphone.isGranted) ax=\(Permission.accessibility.isGranted) input=\(Permission.inputMonitoring.isGranted) tap=\(hotkeys.isRunning) inputs=\(Devices.shared.microphones.map(\.name)) dictate=\(Shortcut.label(.dictate))")
        Task {
            do {
                try await SpeechEngine.shared.prepare { status in
                    Task { @MainActor in self.engineStatus = status }
                }
                Log.write("speech ready: \(SpeechEngine.shared.locale.identifier) · whisper=\(WhisperEngine.shared.selectedVariant ?? "off") · llm=\(LLM.label)")
                if WhisperEngine.shared.isActive { _ = try? await WhisperEngine.shared.ensureLoaded() }
                LLM.prewarm()
            } catch {
                engineStatus = "Speech model unavailable: \(error.localizedDescription)"
                Log.write("speech prepare failed: \(error)")
            }
        }
    }

    // MARK: Pause Yap

    /// While paused the dictation key does nothing (for gaming, presenting, a screen share). Clicking the Flow bar
    /// and yap:// links still work.
    @Published private(set) var pausedUntil: Date?
    private var resumeTask: Task<Void, Never>?
    var isPaused: Bool { pausedUntil != nil }

    /// `minutes == nil` pauses until you resume.
    func pauseYap(minutes: Int?) {
        if phase == .listening || phase == .locked { cancel() }
        resumeTask?.cancel()
        pausedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        if let minutes {
            resumeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { return }
                self?.resumeYap(announce: true)
            }
        }
        let when = minutes.map { $0 >= 60 ? "for \($0 / 60) hour\($0 >= 120 ? "s" : "")" : "for \($0) minutes" } ?? "until you resume it"
        HUD.shared.toast("Yap is paused \(when). Your key does nothing until then", symbol: "pause.circle.fill")
    }

    func resumeYap(announce: Bool = true) {
        resumeTask?.cancel(); resumeTask = nil
        guard pausedUntil != nil else { return }
        pausedUntil = nil
        if announce { HUD.shared.toast("Yap is listening for \(Shortcut.label(.dictate)) again", symbol: "mic.fill") }
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        Log.write("hotkey: \(event) phase=\(phase)")
        if isPaused, case .begin = event { hotkeys.reset(); return }
        switch event {
        case .begin(let command):
            // Pressing the key while a click-started hands-free session runs finishes it.
            if phase == .locked { Task { await finish() } } else { begin(command: command) }
        case .lock: if phase == .listening { phase = .locked; Sounds.start() }
        case .finish: Task { await finish() }
        case .cancel: cancel()
        }
    }

    // MARK: Lifecycle

    /// Click on the Flow bar: start hands-free, or finish if already running.
    func toggleFromBar() {
        switch phase {
        case .idle:
            begin(command: false)
            if phase == .listening { phase = .locked }
        case .listening, .locked:
            Task { await finish() }
        case .thinking:
            break
        }
    }

    /// Starts dictation that keeps listening until finished (Flow bar click, yap:// links).
    func beginHandsFree(command: Bool) {
        begin(command: command)
        if phase == .listening { phase = .locked; FlowBar.shared.update() }
    }

    func begin(command: Bool) {
        guard phase == .idle else { return }
        guard SpeechEngine.shared.isReady, let format = SpeechEngine.shared.analyzerFormat else {
            show(engineStatus, symbol: "hourglass", error: false)
            hotkeys.reset()
            return
        }
        guard Permission.microphone.isGranted else {
            Permission.microphone.request()
            fail("Allow Microphone access for Yap", symbol: "mic.slash.fill")
            return
        }
        Devices.shared.refresh()
        guard !Devices.shared.microphones.isEmpty else {
            fail("No microphone connected. Plug one in or bring your iPhone close", symbol: "mic.slash.fill")
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        isCommand = command
        liveText = ""
        selectionTask = nil
        startedAt = Date()
        phase = .listening

        do {
            let session = try SpeechEngine.shared.startLive { [weak self] text in
                Task { @MainActor in self?.liveText = text }
            }
            self.session = session
            mic.collectWhisperAudio = WhisperEngine.shared.isActive
            try mic.start(target: format) { [weak self] buffer, level in
                session.feed(buffer)
                Task { @MainActor in self?.push(level: level) }
            }
        } catch {
            fail(error.localizedDescription, symbol: "mic.slash.fill")
            return
        }
        Log.write("listening (command=\(command)) app=\(targetApp?.localizedName ?? "?")")
        watchForSilence()
        Sounds.start()
        FlowBar.shared.update()
        if command {
            selectionTask = Task { await TextBridge.selectedText() }
        } else {
            let app = targetApp?.localizedName
            Task { await Polisher.shared.prewarmCleanup(app: app) }
        }
    }

    /// The iPhone started talking. Returns false if Yap is busy or not ready.
    @discardableResult
    func beginRemote(command: Bool) -> Bool {
        guard phase == .idle else { return false }
        guard SpeechEngine.shared.isReady, let format = SpeechEngine.shared.analyzerFormat else {
            show(engineStatus, symbol: "hourglass", error: false)
            return false
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        isCommand = command
        liveText = ""
        startedAt = Date()
        do {
            let session = try SpeechEngine.shared.startLive { [weak self] text in
                Task { @MainActor in self?.liveText = text }
            }
            guard let feed = RemoteFeed(target: format, onBuffer: { [weak self] buffer, level in
                session.feed(buffer)
                self?.push(level: level)
            }) else { session.cancel(); return false }
            self.session = session
            remoteFeed = feed
        } catch {
            fail(error.localizedDescription, symbol: "iphone.slash")
            return false
        }
        phase = .locked
        selectionTask = command ? Task { await TextBridge.selectedText() } : nil
        Log.write("listening via iPhone (command=\(command)) app=\(targetApp?.localizedName ?? "?")")
        Sounds.start()
        FlowBar.shared.update()
        if !command { let app = targetApp?.localizedName; Task { await Polisher.shared.prewarmCleanup(app: app) } }
        return true
    }

    func feedRemote(_ pcm: Data) { remoteFeed?.feed(pcm) }

    func cancel() {
        guard phase != .idle else { return }
        mic.stop()
        session?.cancel()
        session = nil
        reset()
    }

    func finish() async {
        guard phase == .listening || phase == .locked, let session else { return }
        mic.stop()
        self.session = nil
        phase = .thinking
        Sounds.stop()
        let stoppedAt = Date()
        let duration = stoppedAt.timeIntervalSince(startedAt)

        var raw: String
        do { raw = try await session.finish() } catch { fail(error.localizedDescription); return }
        if WhisperEngine.shared.isActive, mic.collectWhisperAudio || remoteFeed != nil {
            let samples = remoteFeed?.samples ?? mic.takeCollectedSamples()
            if samples.count > 8_000 { // > 0.5 s
                do {
                    let w = try await WhisperEngine.shared.transcribe(samples: samples)
                    if !w.isEmpty { raw = w }
                } catch {
                    Log.write("whisper failed, using Apple result: \(error.localizedDescription)")
                }
            }
        }
        let heardAt = Date()
        Log.write("heard \(raw.count) chars in \(String(format: "%.1f", duration))s")
        guard !raw.isEmpty else {
            reset()
            show("Didn't catch that", symbol: "ear.trianglebadge.exclamationmark", error: false)
            return
        }

        var commands = VoiceCommands.Parsed(text: raw)
        if !isCommand, VoiceCommands.isEnabled {
            commands = VoiceCommands.parse(raw)
            if commands.undoLast { await undoLastDictation(); return }
            raw = commands.text
            if raw.isEmpty {
                reset()
                if commands.pressReturn { TextBridge.press(kVK_Return) }
                return
            }
        }

        let appName = targetApp?.localizedName
        var output: String
        // Spoken maths ("what's 40 plus 20", "… 40 plus 20 equals") is worked out exactly, never by the AI.
        if !isCommand, VoiceCommands.isEnabled, let math = SpokenMath.evaluate(raw) {
            switch math {
            case .answer(let v): output = v
            case .inline(let s): output = s.prefix(1).uppercased() + s.dropFirst()
            }
        } else if isCommand {
            let selection = await selectionTask?.value
            guard let result = await Polisher.shared.command(raw, selection: selection, app: appName) else {
                fail("Command Mode needs Apple Intelligence enabled.")
                return
            }
            output = result
        } else {
            output = await Polisher.shared.clean(raw, app: appName)
            // "…translate to French", or Settings → Dictation → Always translate to.
            let saved = UserDefaults.standard.string(forKey: Prefs.Key.translateTo) ?? ""
            if let language = commands.translateTo ?? (saved.isEmpty ? nil : saved) {
                guard let translated = await Polisher.shared.translate(output, to: language, app: appName), !translated.isEmpty else {
                    fail("Translation needs Apple Intelligence or a second model (Settings → Models)")
                    return
                }
                Log.write("translated to \(language)")
                output = translated
            }
        }

        // Focus normally never leaves the target app (the Flow bar is non-activating), but be safe.
        if let app = targetApp, NSWorkspace.shared.frontmostApplication != app {
            app.activate()
            try? await Task.sleep(for: .milliseconds(120))
        }
        // Join the surrounding text: a space after a word, lowercase mid-sentence, no stray period.
        if !isCommand, UserDefaults.standard.bool(forKey: Prefs.Key.fitToCursor), let around = CursorContext.read() {
            output = CursorContext.fit(output, around, keepCapitalized: Self.isProperNoun)
        }
        let result = TextBridge.deliver(output)
        lastOutput = output
        if result != .copiedOnly {
            if let app = targetApp { lastDelivery = (app.processIdentifier, Date()) }
            if commands.pressReturn {
                try? await Task.sleep(for: .milliseconds(220)) // let the paste land before sending
                TextBridge.press(kVK_Return)
            } else {
                CorrectionLearner.shared.watch(pasted: output)
            }
        }
        Log.write("delivered \(result) ax=\(AXIsProcessTrusted()) post=\(CGPreflightPostEventAccess()) after \(String(format: "%.2f", Date().timeIntervalSince(stoppedAt)))s (speech→text \(String(format: "%.2f", heardAt.timeIntervalSince(stoppedAt)))s)")
        history.add(.init(raw: raw, text: output, app: appName, duration: duration, isCommand: isCommand))
        reset()
        MarkMotion.shared.play(.pasted)
        let kept = UserDefaults.standard.bool(forKey: Prefs.Key.keepOnClipboard)
        switch result {
        case .pasted where kept: show("Pasted · also on your clipboard", symbol: "checkmark.circle.fill", error: false, seconds: 1.4)
        case .pasted: break
        case .pastedBlind: show("Copied to clipboard. Press ⌘V if it didn't paste", symbol: "doc.on.clipboard.fill", error: false, seconds: 3)
        case .copiedOnly: show("Copied: press ⌘V. Allow Accessibility for auto-paste", symbol: "doc.on.clipboard.fill", error: false, seconds: 4)
        }
    }

    /// The paste-last shortcut: puts the last dictation at the cursor again.
    func pasteLast() {
        guard phase == .idle else { return }
        guard let text = lastOutput ?? history.entries.first?.text else {
            show("Nothing dictated yet", symbol: "text.bubble", error: false)
            return
        }
        TextBridge.deliver(text)
    }

    /// Names, places and your dictionary words keep their capital letter mid-sentence.
    private static func isProperNoun(_ word: String) -> Bool {
        if word == "I" || word.hasPrefix("I'") { return true }
        if Prefs.dictionary.vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { return true }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = word + " said hello."
        let (tag, _) = tagger.tag(at: tagger.string!.startIndex, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }

    /// After 2.5 s of near silence, say so while still listening (wrong or muted microphone).
    private func watchForSilence() {
        peakLevel = 0
        silenceCheck?.cancel()
        silenceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.phase == .listening || self.phase == .locked, !self.isRemote,
                  self.peakLevel < 0.12, self.liveText.isEmpty else { return }
            let mic = Devices.shared.microphones.first { $0.id == Devices.selectedMicID }?.name ?? "the default microphone"
            Log.write("no input heard after 2.5s on \(mic)")
            self.show("Can't hear you. Using \(mic): check it's not muted, or pick another in the menu", symbol: "mic.badge.xmark", error: false, seconds: 4)
        }
    }

    /// "Scratch that" on its own: undo the last paste in the app it went to.
    private func undoLastDictation() async {
        reset()
        guard let last = lastDelivery, Date().timeIntervalSince(last.at) < 180,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == last.app else {
            show("Nothing to scratch", symbol: "arrow.uturn.backward", error: false)
            return
        }
        lastDelivery = nil
        TextBridge.press(kVK_ANSI_Z, flags: .maskCommand)
        show("Removed your last dictation", symbol: "arrow.uturn.backward", error: false, seconds: 1.6)
    }

    /// Re-insert a past dictation (from the history list or the menu).
    func reinsert(_ text: String) { TextBridge.insert(text) }

    /// Feeds the Flow bar's 60 fps waveform without republishing the controller on every audio buffer.
    private func push(level: Float) {
        FlowBar.shared.meter.level = level
        if level > peakLevel { peakLevel = level }
    }

    private func reset() {
        silenceCheck?.cancel()
        remoteFeed = nil
        phase = .idle
        isCommand = false
        FlowBar.shared.meter.level = 0
        hotkeys.reset()
        FlowBar.shared.update()
    }

    private func fail(_ message: String, symbol: String = "exclamationmark.triangle.fill") {
        Log.write("error: \(message)")
        mic.stop()
        session?.cancel()
        session = nil
        reset()
        Sounds.error()
        show(message, symbol: symbol, error: true)
    }

    func show(_ text: String, symbol: String, error: Bool, seconds: Double? = nil) {
        noticeTask?.cancel()
        notice = Notice(text: text, symbol: symbol, isError: error)
        FlowBar.shared.update()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds ?? (error ? 4 : 2.5)))
            guard !Task.isCancelled else { return }
            notice = nil
            FlowBar.shared.update()
        }
    }

    /// Speech-like fake levels: syllable bursts with short pauses between words.
    private func speakDemo() {
        Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening || self.phase == .locked else { t.invalidate(); return }
                let x = Date().timeIntervalSinceReferenceDate / Motion.slowmo
                let syllable = max(0, sin(x * 13))                     // ~4 syllables/s
                let word = sin(x * 2.3) > -0.35 ? 1.0 : 0.05           // gaps between words
                self.push(level: Float(0.15 + 0.75 * syllable * word + Double.random(in: 0...0.08)))
            }
        }
    }

    // MARK: Demo (for screenshots: `Yap --demo-bar listening|locked|thinking|idle|error`)

    func demo(_ state: String) {
        switch state {
        case "listening", "locked":
            phase = state == "locked" ? .locked : .listening
            liveText = "Hey team, quick update on the launch: designs are done and"
            speakDemo()
        case "thinking": phase = .thinking
        case "hover": FlowBar.shared.scripted = true; FlowBar.shared.hover.isHovering = true
        case "pasted": show("Pasted · also on your clipboard", symbol: "checkmark.circle.fill", error: false, seconds: 600)
        case "sequence":
            // Walks every state so the motion can be recorded: idle → hover → listening → hands-free → thinking → notice → idle.
            let k = Motion.slowmo
            FlowBar.shared.scripted = true
            let steps: [(Double, () -> Void)] = [
                (1.0, { FlowBar.shared.hover.isHovering = true }),
                (2.0, { FlowBar.shared.hover.isHovering = false; self.phase = .listening; self.speakDemo() }),
                (3.4, { self.liveText = "Hey team, quick update on the launch" }),
                (4.4, { self.phase = .locked; self.liveText = "Hey team, quick update on the launch: designs are done and" }),
                (6.0, { self.phase = .thinking }),
                (7.6, { self.phase = .idle; self.liveText = ""; self.show("Pasted · also on your clipboard", symbol: "checkmark.circle.fill", error: false, seconds: 1.4 * k) }),
            ]
            for (at, step) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + at * k) { step(); FlowBar.shared.update() }
            }
        case "error": show("No microphone connected. Plug one in or bring your iPhone close", symbol: "mic.slash.fill", error: true)
        default: phase = .idle
        }
        FlowBar.shared.update()
    }
}

// MARK: - History

struct DictationEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var raw: String
    var text: String
    var app: String?
    var duration: TimeInterval
    var isCommand: Bool

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []
    private var url: URL { Prefs.historyFolder.appendingPathComponent("history.json") }

    init() { entries = Self.read(url) ?? [] }

    private static func read(_ u: URL) -> [DictationEntry]? {
        guard let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode([DictationEntry].self, from: data)
    }

    /// Moves history.json to `folder` (nil = the default). If one is already there (another Mac, an old copy),
    /// the two lists are merged, so no dictation is lost. Returns how many entries the history now holds.
    @discardableResult
    func relocate(to folder: URL?) -> Int {
        let old = url
        let d = UserDefaults.standard
        if let folder { d.set(folder.standardizedFileURL.path, forKey: Prefs.Key.historyFolder) } else { d.removeObject(forKey: Prefs.Key.historyFolder) }
        let new = url
        guard new.standardizedFileURL != old.standardizedFileURL else { return entries.count }
        var merged = entries
        if let there = Self.read(new) {
            let known = Set(merged.map(\.id))
            merged += there.filter { !known.contains($0.id) }
            merged.sort { $0.date > $1.date }
            if merged.count > 2000 { merged.removeLast(merged.count - 2000) }
        }
        entries = merged
        save()
        if FileManager.default.fileExists(atPath: new.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.trashItem(at: old, resultingItemURL: nil)   // to the Trash, not deleted
        }
        return entries.count
    }

    func add(_ e: DictationEntry) {
        entries.insert(e, at: 0)
        if entries.count > 2000 { entries.removeLast(entries.count - 2000) }
        save()
    }

    func delete(_ e: DictationEntry) {
        entries.removeAll { $0.id == e.id }
        save()
    }

    func clear() { entries = []; save() }

    var totalWords: Int { entries.reduce(0) { $0 + $1.words } }

    /// Typing at ~40 wpm vs. the time actually spent speaking.
    var minutesSaved: Double {
        let typing = Double(totalWords) / 40.0
        let speaking = entries.reduce(0) { $0 + $1.duration } / 60.0
        return max(0, typing - speaking)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
