import AppKit
import IOKit
import IOKit.hid
import SwiftUI

// MARK: - Connected keyboards

struct KeyboardInfo: Hashable {
    let name: String
    let isApple: Bool
    let isVirtual: Bool   // e.g. Karabiner-Elements' remapping keyboard

    /// Reads attached HID keyboards from the IORegistry (no permission needed).
    static func connected() -> [KeyboardInfo] {
        guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return [] }
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Keyboard
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [KeyboardInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let product = IORegistryEntryCreateCFProperty(service, kIOHIDProductKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            let maker = IORegistryEntryCreateCFProperty(service, kIOHIDManufacturerKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String ?? ""
            guard let product, !product.isEmpty else { continue }
            // Many cheap 2.4G/Windows boards spoof Apple's vendor ID, so trust the manufacturer string instead.
            let virtual = maker == "pqrs.org" || product.localizedCaseInsensitiveContains("virtual")
            let apple = maker.localizedCaseInsensitiveContains("apple") || product.localizedCaseInsensitiveContains("apple internal")
            out.append(KeyboardInfo(name: product, isApple: apple, isVirtual: virtual))
        }
        return Array(Set(out)).sorted { $0.name < $1.name }
    }
}

// MARK: - Settings tab

struct ShortcutsTab: View {
    @Local private var keyboards: [KeyboardInfo] = []

    private var physical: [KeyboardInfo] { keyboards.filter { !$0.isVirtual } }
    private var hasAppleKeyboard: Bool { physical.contains(where: \.isApple) }
    private var hasKarabiner: Bool { keyboards.contains(where: \.isVirtual) }

    var body: some View {
        Form {
            SettingsHeader(page: .shortcuts, text: "The keys that start dictation and recording. Pick any key on any keyboard.")
            Section {
                ForEach(Shortcut.Action.allCases) { ShortcutRow(action: $0) }
            } footer: {
                Text("Click a shortcut, then press the key you want. Hold-to-talk actions can be a single key on its own, like Right Alt or Right Ctrl. Esc cancels.")
            }

            Section("Your keyboards") {
                if physical.isEmpty {
                    Text("No keyboards detected.").foregroundStyle(.secondary)
                }
                ForEach(physical, id: \.self) { k in
                    Label {
                        Text(k.name)
                        Text(k.isApple ? "Apple layout · has Fn 🌐" : "Windows-style layout · Win = ⌘, Alt = ⌥")
                    } icon: { Image(systemName: "keyboard") }
                }
                if hasKarabiner {
                    Text("Karabiner-Elements is running. Yap sees keys after Karabiner remaps them, so a key you mapped to fn there works as Fn here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !physical.isEmpty, !hasAppleKeyboard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Windows keyboards handle Fn inside the keyboard, so macOS never sees it. Pick a key your board has:")
                            .font(.callout)
                        HStack {
                            suggestion("Right Alt", code: 61)
                            suggestion("Right Ctrl", code: 62)
                            suggestion("Right Win", code: 54)
                        }
                        Text("On a 60% board, Right Alt is usually the easiest to reach. If a key doesn't respond, check System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys; macOS may have swapped Win/Alt for this keyboard.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { keyboards = KeyboardInfo.connected() }
    }

    private func suggestion(_ title: String, code: UInt16) -> some View {
        Button("Use \(title)") {
            Shortcut.set(Shortcut(keyCode: code, modifiers: 0, isModifierOnly: true), for: .dictate)
        }
    }
}

// MARK: - One recordable shortcut

struct ShortcutRow: View {
    let action: Shortcut.Action
    @StateObject private var model: ShortcutRecorderModel

    init(action: Shortcut.Action) {
        self.action = action
        _model = StateObject(wrappedValue: ShortcutRecorderModel(action: action))
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Button { model.isRecording ? model.cancel() : model.begin() } label: {
                    Text(model.isRecording ? (model.live.isEmpty ? "Press a key…" : model.live) : model.label)
                        .frame(minWidth: 150)
                        .foregroundStyle(model.isRecording ? Color.accentColor : .primary)
                }
                Menu {
                    Button("Reset to Default") { Shortcut.reset(action) }
                    Button("Clear") { Shortcut.set(nil, for: action) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let w = model.windowsLabel { Text("Windows keyboard: \(w)").font(.caption).foregroundStyle(.secondary) }
                if action == .command, Shortcut.get(.command) == nil {
                    Text("Not set: hold your Dictate key + ⌃ Ctrl").font(.caption).foregroundStyle(.secondary)
                }
                if let warning = model.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

@MainActor
final class ShortcutRecorderModel: ObservableObject {
    let action: Shortcut.Action
    @Published var isRecording = false
    @Published var live = ""
    @Published var warning: String?
    @Published private(set) var current: Shortcut?
    private var monitor: Any?
    private var loneModifier: UInt16?
    private var observer: NSObjectProtocol?

    init(action: Shortcut.Action) {
        self.action = action
        current = Shortcut.get(action)
        observer = NotificationCenter.default.addObserver(forName: Shortcut.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.current = self.map { Shortcut.get($0.action) } ?? nil }
        }
    }

    var label: String { current?.display ?? "Record Shortcut" }
    var windowsLabel: String? { current?.windowsDisplay }

    func begin() {
        warning = nil
        live = ""
        loneModifier = nil
        isRecording = true
        HotkeyMonitor.isPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        live = ""
        HotkeyMonitor.isPaused = false
    }

    private func handle(_ e: NSEvent) {
        if e.type == .flagsChanged {
            let code = e.keyCode
            guard Shortcut.modifierKeyCodes.contains(code) else { return }
            let probe = Shortcut(keyCode: code, modifiers: 0, isModifierOnly: true)
            let isDown = probe.deviceFlagBit.map { UInt64(e.modifierFlags.rawValue) & $0 != 0 } ?? false
            if isDown {
                loneModifier = code
                live = probe.windowsDisplay.map { "\(probe.display) · \($0)" } ?? probe.display
            } else if loneModifier == code {
                loneModifier = nil
                if action.allowsModifierOnly { commit(probe) } else { warning = "This one needs a combo, e.g. ⌥⇧R." }
            }
            return
        }

        // keyDown
        loneModifier = nil
        let mods = e.modifierFlags.intersection(Shortcut.comboMask)
        if e.keyCode == 53, mods.isEmpty { cancel(); return }
        let s = Shortcut(keyCode: e.keyCode, modifiers: mods.rawValue, isModifierOnly: false)
        live = s.display
        if mods.isEmpty, !Self.isSafeAlone(e.keyCode) {
            warning = "Add a modifier (⌃ ⌥ ⇧ ⌘), or that key would stop typing normally."
            return
        }
        commit(s)
    }

    private func commit(_ s: Shortcut) {
        for other in Shortcut.Action.allCases where other != action && Shortcut.get(other) == s {
            warning = "Already used for “\(other.title)”."
            return
        }
        Shortcut.set(s, for: action)
        warning = nil
        cancel()
    }

    /// Keys nobody types with, so they're fine as a shortcut on their own.
    private static func isSafeAlone(_ code: UInt16) -> Bool {
        let fKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        let navKeys: Set<UInt16> = [114, 115, 119, 116, 121] // Insert/Help, Home, End, PgUp, PgDn
        return fKeys.contains(code) || navKeys.contains(code)
    }
}
