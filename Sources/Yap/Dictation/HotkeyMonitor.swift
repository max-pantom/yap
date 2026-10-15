import AppKit
import CoreGraphics

/// Watches the user's Dictate and Command Mode shortcuts.
///
/// Lone-modifier shortcuts (Fn, Right Alt…) are seen through a **listen-only** event tap, which receives copies of
/// events and can never delay or block typing. Key-combo shortcuts (F13, ⌃Space…) go through Carbon hot keys,
/// which macOS delivers to us without Yap sitting in the path of any other keystroke.
///
/// A shortcut is either a lone modifier (Fn, Right Alt, Right Ctrl…) or a key combo (F13, ⌃Space…).
/// Gestures:
///  - hold            → push-to-talk, release to insert
///  - double-tap      → hands-free lock, press again to insert
///  - Command Mode    → its own shortcut, or the dictate key + ⌃ when none is set
///  - Esc             → cancel
///  - another key while holding a lone-modifier shortcut → cancel (it's being used as a modifier)
@MainActor
final class HotkeyMonitor {
    enum Event { case begin(command: Bool), lock, finish, cancel }

    var onEvent: ((Event) -> Void)?
    /// Set while the Settings shortcut recorder is listening, so the old shortcut doesn't fire.
    static var isPaused = false

    private enum State { case idle, holding, tapPending, locked }
    private var state: State = .idle
    private var active: Shortcut.Action = .dictate
    private var downAt = Date.distantPast
    private var held: Set<Shortcut.Action> = []
    private var bindings: [(Shortcut.Action, Shortcut)] = []
    private var pendingTimer: Timer?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private let comboKeys = GlobalHotKeys(signature: OSType(0x5941_5044)) // 'YAPD'

    private let holdThreshold: TimeInterval = 0.28
    private let doubleTapWindow: TimeInterval = 0.38

    var isRunning: Bool { tap != nil }

    init() {
        reload()
        NotificationCenter.default.addObserver(forName: Shortcut.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        // Command first so that, e.g., ⌃F13 (command) wins over F13 (dictate).
        bindings = [Shortcut.Action.command, .dictate].compactMap { a in Shortcut.get(a).map { (a, $0) } }
        held.removeAll()
        comboKeys.unregisterAll()
        for (action, s) in bindings where !s.isModifierOnly {
            comboKeys.register(key: Int(s.keyCode), modifiers: s.carbonModifiers,
                               onRelease: { [weak self] in self?.comboUp(action) },
                               handler: { [weak self] in self?.comboDown(action) })
        }
    }

    private func comboDown(_ action: Shortcut.Action) {
        guard !Self.isPaused, !held.contains(action) else { return }
        pressed(action, flags: [])
    }

    private func comboUp(_ action: Shortcut.Action) {
        guard held.contains(action) else { return }
        released(action)
    }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                MainActor.assumeIsolated { monitor.handle(type: type, keyCode: keyCode, flags: flags) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon)

        guard let tap else {
            // Input Monitoring not granted yet: retry quietly until it is.
            scheduleRetry()
            return
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Called by the controller when a session ends by other means.
    func reset() {
        state = .idle
        pendingTimer?.invalidate()
    }

    // MARK: Event handling (observe only, never swallow)

    private func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard !Self.isPaused else { return }

        if type == .flagsChanged {
            for (action, s) in bindings where s.isModifierOnly && s.keyCode == keyCode {
                guard let bit = s.deviceFlagBit else { continue }
                let isDown = flags.rawValue & bit != 0
                if isDown, !held.contains(action) { pressed(action, flags: flags) }
                else if !isDown, held.contains(action) { released(action) }
                return
            }
            return
        }

        // keyDown
        if keyCode == 53, state != .idle { cancelSession(); return } // Esc
        let activeIsModifier = bindings.first { $0.0 == active }?.1.isModifierOnly ?? false
        // Another key while holding a lone modifier means it's being used as a modifier (e.g. Alt+E): stand down.
        if state == .holding, activeIsModifier, held.contains(active) { cancelSession() }
    }

    private func pressed(_ action: Shortcut.Action, flags: CGEventFlags) {
        held.insert(action)
        switch state {
        case .idle:
            state = .holding
            active = action
            downAt = Date()
            let commandFallback = action == .dictate && Shortcut.get(.command) == nil && flags.contains(.maskControl)
            onEvent?(.begin(command: action == .command || commandFallback))
        case .tapPending where action == active:
            pendingTimer?.invalidate()
            state = .locked
            onEvent?(.lock)
        case .locked where action == active:
            state = .idle
            onEvent?(.finish)
        default:
            break
        }
    }

    private func released(_ action: Shortcut.Action) {
        held.remove(action)
        guard state == .holding, action == active else { return }
        if Date().timeIntervalSince(downAt) >= holdThreshold {
            state = .idle
            onEvent?(.finish)
        } else {
            // Quick tap: wait to see if a second tap turns this into hands-free mode.
            state = .tapPending
            pendingTimer?.invalidate()
            pendingTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .tapPending else { return }
                    self.state = .idle
                    self.onEvent?(.cancel)
                }
            }
        }
    }

    private func cancelSession() {
        state = .idle
        pendingTimer?.invalidate()
        onEvent?(.cancel)
    }
}
