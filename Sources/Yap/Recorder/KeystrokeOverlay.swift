import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shows the shortcuts you press (⌘K, ⌃⌥V, Esc…) on screen during a recording, for tutorials.
/// Only combos with ⌘, ⌃ or ⌥ and a few special keys are shown, never plain typing, so text and
/// passwords can't end up in a video. The window is added to the capture like the camera bubble.
@MainActor
final class KeystrokeOverlay {
    private let model = Model()
    private var panel: OverlayPanel?
    private var monitor: Any?
    private var hideTask: Task<Void, Never>?

    final class Model: ObservableObject { @Published var keys: String = ""; @Published var visible = false }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.Key.showKeystrokes) }

    /// The overlay's window, for the capture filter. Creates it (invisible until a key) on the given screen.
    func prepare(on screen: NSScreen?) -> CGWindowID? {
        guard Self.isEnabled else { return nil }
        let p = panel ?? OverlayPanel(size: NSSize(width: 520, height: 96))
        p.contentView = NSHostingView(rootView: KeystrokeView(model: model))
        if let f = screen?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - 260, y: f.minY + 120)) }
        p.orderFrontRegardless()  // must be on screen to be captured; it draws nothing until a key
        panel = p
        return CGWindowID(p.windowNumber)
    }

    func start() {
        guard panel != nil, monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let label = Self.label(for: e)
            MainActor.assumeIsolated { if let label { self?.show(label) } }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hideTask?.cancel()
        model.visible = false
        panel?.orderOut(nil)
    }

    private func show(_ keys: String) {
        model.keys = keys
        withAnimation(Motion.enter) { model.visible = true }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.exit) { self?.model.visible = false }
        }
    }

    /// "⌘⇧P" for shortcuts, "Esc" / "↩" for special keys, nil for ordinary typing.
    nonisolated static func label(for e: NSEvent) -> String? {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let special: [Int: String] = [kVK_Return: "↩", kVK_Escape: "Esc", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
                                      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                      kVK_Space: "Space", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                                      kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        let isCombo = !mods.intersection([.command, .control, .option]).isEmpty
        let code = Int(e.keyCode)
        // Plain keys only for the few that mean something on their own; arrows and space only in combos.
        let standalone: Set<Int> = [kVK_Return, kVK_Escape, kVK_Tab]
        guard isCombo || standalone.contains(code) else { return nil }
        let s = Shortcut(keyCode: e.keyCode, modifiers: mods.rawValue, isModifierOnly: false)
        if let name = special[code] {
            var prefix = ""
            if mods.contains(.control) { prefix += "⌃" }
            if mods.contains(.option) { prefix += "⌥" }
            if mods.contains(.shift) { prefix += "⇧" }
            if mods.contains(.command) { prefix += "⌘" }
            return prefix + (prefix.isEmpty ? name : " " + name)
        }
        return s.display
    }
}

private struct KeystrokeView: View {
    @ObservedObject var model: KeystrokeOverlay.Model
    var body: some View {
        Text(model.keys)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .opacity(model.visible ? 1 : 0)
            .scaleEffect(model.visible ? 1 : 0.96)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
