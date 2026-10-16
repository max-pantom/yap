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
