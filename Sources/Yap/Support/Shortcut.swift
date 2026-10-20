import AppKit
import Carbon.HIToolbox

/// A user-recorded shortcut: either a lone modifier key you hold (Fn, Right Alt, Right Ctrl…)
/// or a regular key with optional modifiers (F13, ⌃Space, ⌥⇧R…).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// Device-independent modifiers (⌘⌥⌃⇧) for key combos; empty for lone-modifier shortcuts.
    var modifiers: UInt
    var isModifierOnly: Bool

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.comboMask) }
    static let comboMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    // MARK: Names (Mac symbol + Windows-keyboard name, since ⌘ = Win and ⌥ = Alt)

    var display: String {
        if isModifierOnly { return Self.modifierName(keyCode) ?? "Key \(keyCode)" }
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Same shortcut spelled the way it's printed on a Windows keyboard.
    var windowsDisplay: String? {
        if isModifierOnly { return Self.modifierWindowsName(keyCode) }
        guard flags.contains(.command) || flags.contains(.option) else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Ctrl") }
        if flags.contains(.option) { parts.append("Alt") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Win") }
        return (parts + [Self.keyName(keyCode)]).joined(separator: "+")
    }

    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    static func modifierName(_ code: UInt16) -> String? {
        switch code {
        case 63: "Fn 🌐"
        case 54: "Right ⌘"
        case 55: "Left ⌘"
        case 61: "Right ⌥"
        case 58: "Left ⌥"
        case 62: "Right ⌃"
        case 59: "Left ⌃"
        case 60: "Right ⇧"
        case 56: "Left ⇧"
        default: nil
        }
    }

    static func modifierWindowsName(_ code: UInt16) -> String? {
        switch code {
        case 54: "Right Win"
        case 55: "Left Win"
        case 61: "Right Alt / AltGr"
        case 58: "Left Alt"
        case 62: "Right Ctrl"
        case 59: "Left Ctrl"
        case 60: "Right Shift"
        case 56: "Left Shift"
        default: nil
        }
    }

    /// Device-specific flag bit that is set while this exact modifier key is held.
    var deviceFlagBit: UInt64? {
        switch keyCode {
        case 59: 0x0000_0001   // left ctrl
        case 56: 0x0000_0002   // left shift
        case 60: 0x0000_0004   // right shift
        case 55: 0x0000_0008   // left cmd
        case 54: 0x0000_0010   // right cmd
        case 58: 0x0000_0020   // left alt
        case 61: 0x0000_0040   // right alt
        case 62: 0x0000_2000   // right ctrl
        case 63: CGEventFlags.maskSecondaryFn.rawValue
        default: nil
        }
    }

    static func keyName(_ code: UInt16) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "Esc", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn", kVK_Help: "Insert",
            kVK_CapsLock: "Caps Lock", kVK_ANSI_Grave: "`",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
            kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
            kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let s = special[Int(code)] { return s }
        return translate(code)?.uppercased() ?? "Key \(code)"
    }

    /// Character the key produces on the current keyboard layout (handles non-US layouts).
    private static func translate(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: Carbon (for the record/camera hotkeys)

    var carbonModifiers: Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    // MARK: Storage

    enum Action: String, CaseIterable, Identifiable {
        case dictate, command, record, meeting, camera, pasteLast
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictate: "Dictate (hold · double-tap for hands-free)"
            case .command: "Command Mode (hold)"
            case .record: "Start / stop screen recording"
            case .meeting: "Start / end meeting notes"
            case .camera: "Show / hide camera bubble"
            case .pasteLast: "Paste your last dictation again"
            }
        }

        /// Hold-to-talk actions can be a lone modifier; the others need a key combo.
        var allowsModifierOnly: Bool { self == .dictate || self == .command }

        var defaultValue: Shortcut? {
            switch self {
            case .dictate: Shortcut(keyCode: 63, modifiers: 0, isModifierOnly: true)
            case .command: nil  // falls back to "dictate key + ⌃"
            case .record: Shortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue, isModifierOnly: false)
            case .meeting: Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue, isModifierOnly: false)
            case .camera: Shortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue, isModifierOnly: false)
            case .pasteLast: Shortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, isModifierOnly: false)
            }
        }

        var defaultsKey: String { "shortcut." + rawValue }
    }

    static let didChange = Notification.Name("YapShortcutsDidChange")

    static func get(_ action: Action) -> Shortcut? {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: action.defaultsKey) else { return action.defaultValue }
        if data.isEmpty { return nil } // explicitly cleared
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func set(_ shortcut: Shortcut?, for action: Action) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func reset(_ action: Action) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// What to show in hints, e.g. "Fn 🌐" or "Right ⌥ (Right Alt / AltGr)".
    static func label(_ action: Action) -> String {
        guard let s = get(action) else { return "not set" }
        if let w = s.windowsDisplay, s.isModifierOnly { return "\(s.display) (\(w))" }
        return s.display
    }
}
