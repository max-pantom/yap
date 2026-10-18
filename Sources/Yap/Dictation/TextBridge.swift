import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads from and writes to whatever text field the user is focused on, via the pasteboard + a synthetic ⌘V,
/// which works in native, Electron and web apps alike.
enum TextBridge {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    enum Delivery {
        case pasted          // ⌘V sent into a text field
        case pastedBlind     // ⌘V sent, but we couldn't confirm a text field had focus
        case copiedOnly      // no Accessibility permission: it's on the clipboard for you to paste
    }

    /// Puts `text` on the clipboard and pastes it at the cursor.
    /// By default the text stays on the clipboard afterwards, so it's never lost if the paste lands nowhere.
    @MainActor
    @discardableResult
    static func deliver(_ text: String) -> Delivery {
        let pb = NSPasteboard.general
        let keep = UserDefaults.standard.bool(forKey: Prefs.Key.keepOnClipboard)
        let saved = keep ? [] : snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        if !keep { pb.setData(Data(), forType: transientType) } // clipboard managers: ignore this temporary copy

        guard canPaste else { return .copiedOnly }
        let editable = focusedElementIsEditable()
        postKey(kVK_ANSI_V, flags: .maskCommand)

        if !keep {
            let ourChange = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // Only restore if nobody else has touched the clipboard since.
                guard pb.changeCount == ourChange else { return }
                restore(saved, to: pb)
            }
        }
        return editable == false ? .pastedBlind : .pasted
    }

    @MainActor
    static func insert(_ text: String) { deliver(text) }

    static var canPaste: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    /// true/false when Accessibility can tell; nil when the app doesn't expose its focus (common in Electron/web apps).
    @MainActor
    static func focusedElementIsEditable() -> Bool? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused else { return nil }
        let element = ref as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        if let r = role as? String, textRoles.contains(r) { return true }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        return false
    }

    /// Selected text in the focused element via Accessibility, falling back to a ⌘C round-trip.
    @MainActor
    static func selectedText() async -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let element = focused {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
               let s = value as? String, !s.isEmpty {
                return s
            }
        }
        // Many Electron/web apps don't expose selection over AX; ask the app to copy it.
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postKey(kVK_ANSI_C, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(180))
        let result = pb.changeCount != before ? pb.string(forType: .string) : nil
        restore(saved, to: pb)
        return result
    }

    /// Presses a key in the focused app (Return after "send it", ⌘Z for "scratch that").
    static func press(_ key: Int, flags: CGEventFlags = []) { postKey(key, flags: flags) }

    private static func postKey(_ key: Int, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        }
    }

    private static func restore(_ snap: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !snap.isEmpty else { return }
        let items: [NSPasteboardItem] = snap.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}

// MARK: - Fitting text to what's around the cursor

/// Reads the characters on either side of the cursor (Accessibility) so dictation can join mid-sentence:
/// a leading space after a word, lowercase after a comma, no stray period before more text.
enum CursorContext {
    struct Around { var before: Character?; var after: Character? }

    @MainActor
    static func read() -> Around? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let el = ref as! AXUIElement
        var sub: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub)
        if (sub as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &sel), sel.location >= 0 else { return nil }
        func char(at loc: Int) -> Character? {
            guard loc >= 0 else { return nil }
            var r = CFRange(location: loc, length: 1)
            guard let param = AXValueCreate(.cfRange, &r) else { return nil }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success,
                  let s = out as? String else { return nil }
            return s.first
        }
        return Around(before: char(at: sel.location - 1), after: char(at: sel.location + sel.length))
    }

    /// Adjusts `text` so it fits between `around.before` and `around.after`.
    static func fit(_ text: String, _ around: Around, keepCapitalized: (String) -> Bool) -> String {
        guard var t = Optional(text), let first = t.first else { return text }
        if let b = around.before, !b.isWhitespace {
            let sentenceEnd = ".!?".contains(b)
            // Mid-sentence: "…and" + "Then we go" → "…and then we go".
            if !sentenceEnd, first.isUppercase {
                let word = String(t.prefix { $0.isLetter || $0 == "'" })
                if word.count > 1, word.dropFirst().allSatisfy({ $0.isLowercase }), !keepCapitalized(word) {
                    t = first.lowercased() + t.dropFirst()
                }
            }
            if !(t.first.map { ",.;:!?)".contains($0) } ?? false) && !"([{\"'/-".contains(b) { t = " " + t }
        } else if let b = around.before, b.isWhitespace || b.isNewline {
            // fine as is
        }
        if let a = around.after, a.isLetter || a.isNumber {
            // Inserting before more words: drop a closing period and keep them apart.
            if t.hasSuffix("."), !t.hasSuffix("..") { t.removeLast() }
            t += " "
        }
        return t
    }
}
