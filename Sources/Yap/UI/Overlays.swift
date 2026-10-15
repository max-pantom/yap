import AppKit
import SwiftUI

/// Borderless, non-activating panel: never steals focus from the app you're typing into.
final class OverlayPanel: NSPanel {
    init(size: NSSize, interactive: Bool = false) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = !interactive
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func placeBottomCenter(offset: CGFloat = 72) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + offset))
    }
}

// MARK: - Dictation HUD + toasts

@MainActor
final class HUD {
    static let shared = HUD()
    private var toastPanel: OverlayPanel?
    private var toastTimer: Timer?

    func toast(_ message: String, symbol: String) {
        toastPanel?.orderOut(nil)
        let p = OverlayPanel(size: NSSize(width: 460, height: 64))
        p.contentView = NSHostingView(rootView: ToastView(message: message, symbol: symbol))
        p.placeBottomCenter(offset: 150)
        p.orderFrontRegardless()
        toastPanel = p
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: false) { [weak p] _ in
            Task { @MainActor in p?.orderOut(nil) }
        }
    }
}

struct ToastView: View {
    var message: String
    var symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            Text(message).font(.system(size: 13, weight: .medium)).lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.85), in: Capsule())
        .frame(width: 460, height: 64)
    }
}

// MARK: - Recording control bar

@MainActor
final class ControlBar {
    static let shared = ControlBar()
    private var panel: OverlayPanel?

    func show(for recorder: RecordingController) {
        let p = OverlayPanel(size: NSSize(width: 300, height: 52), interactive: true)
        p.contentView = NSHostingView(rootView: ControlBarView(recorder: recorder))
        p.isMovableByWindowBackground = true
        p.placeBottomCenter(offset: 24)
        p.orderFrontRegardless()
        panel = p
    }

    func hide() { panel?.orderOut(nil); panel = nil }
}

struct ControlBarView: View {
    @ObservedObject var recorder: RecordingController

    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await recorder.stop() } } label: {
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30).background(.red, in: Circle())
            }
            .help("Stop & save (\(Shortcut.label(.record)))")
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                Text(elapsed(at: ctx.date)).font(.system(size: 14, weight: .semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
            Button { recorder.camera.toggle() } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 15))
            }
            .help("Toggle camera bubble")
            Button { recorder.cancel() } label: {
                Image(systemName: "trash").font(.system(size: 14))
            }
            .help("Discard recording")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(width: 300, height: 52)
        .background(.black.opacity(0.85), in: Capsule())
    }

    private func elapsed(at now: Date) -> String {
        let s = Int(now.timeIntervalSince(recorder.startedAt ?? now))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Countdown

@MainActor
enum Countdown {
    /// Shows 3‑2‑1. Returns false if the user pressed Esc.
    static func run(seconds: Int) async -> Bool {
        let model = CountdownModel(value: seconds)
        let p = OverlayPanel(size: NSSize(width: 200, height: 200))
        p.contentView = NSHostingView(rootView: CountdownView(model: model))
        if let f = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.frame {
            p.setFrameOrigin(NSPoint(x: f.midX - 100, y: f.midY - 100))
        }
        p.orderFrontRegardless()
        var cancelled = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in if e.keyCode == 53 { cancelled = true } }
        defer { if let monitor { NSEvent.removeMonitor(monitor) }; p.orderOut(nil) }
        for v in stride(from: seconds, to: 0, by: -1) {
            model.value = v
            try? await Task.sleep(for: .seconds(1))
            if cancelled { return false }
        }
        return true
    }
}

@MainActor
final class CountdownModel: ObservableObject {
    @Published var value: Int
    init(value: Int) { self.value = value }
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    var body: some View {
        Text("\(model.value)")
            .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 180, height: 180)
            .background(.black.opacity(0.7), in: Circle())
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: model.value)
            .frame(width: 200, height: 200)
    }
}
