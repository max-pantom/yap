import AppKit
import SwiftUI

/// The always-on pill at the bottom of the screen: tiny when idle, a live waveform while you speak, controls in hands-free mode, and errors right where you look.
/// It's click-through except for the pill itself, never takes focus, follows you across Spaces, and can be
/// dragged anywhere (the position is remembered per screen as a fraction, so it survives resolution changes).
@MainActor
final class FlowBar {
    static let shared = FlowBar()

    private var panel: FlowBarPanel?
    private weak var controller: DictationController?
    private var screenObserver: Any?
    private var lastScreen: NSScreen?
    private var mouseMonitors: [Any] = []
    private var drag: (mouse: NSPoint, origin: NSPoint)?
    let hover = HoverState()
    /// Audio level for the waveform. Plain storage read by the 60 fps canvas, so speaking
    /// doesn't trigger SwiftUI diffing 50 times a second.
    let meter = LevelMeter()

    static let size = NSSize(width: 460, height: 150)
    private static let pillBottomInset: CGFloat = 6

    func attach(_ controller: DictationController) {
        self.controller = controller
        let p = FlowBarPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        p.contentView = NSHostingView(rootView: FlowBarView(controller: controller))
        panel = p
        // Click-through everywhere except the pill: only accept the mouse while the pointer is over it.
        let track: (NSEvent?) -> Void = { _ in MainActor.assumeIsolated { FlowBar.shared.trackMouse() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited], handler: { e in track(e); return e }) { mouseMonitors.append(l) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FlowBar.shared.place(force: true) }
        }
        update()
    }

    /// Re-evaluates visibility and position after any state change.
    func update() {
        guard let panel, let controller else { return }
        let active = controller.phase != .idle || controller.notice != nil
        let showIdle = UserDefaults.standard.bool(forKey: Prefs.Key.showFlowBar)
        if active || showIdle {
            if active { place(force: false) } else if !panel.isVisible { place(force: true) }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        if controller.phase != .listening && controller.phase != .locked { meter.reset() }
    }

    // MARK: Mouse

    /// The pill's clickable area in screen coordinates (a little larger than the pill so it's easy to hit).
    private var hitRect: NSRect? {
        guard let panel, panel.isVisible, let controller else { return nil }
        let size: CGSize = switch controller.phase {
        case .idle: hover.isHovering ? CGSize(width: 290, height: 40) : CGSize(width: 90, height: 30)
        case .listening: CGSize(width: 150, height: 46)
        case .locked: CGSize(width: 210, height: 50)
        case .thinking: CGSize(width: 110, height: 42)
        }
        let f = panel.frame
        return NSRect(x: f.midX - size.width / 2, y: f.minY, width: size.width, height: size.height)
    }

    /// Set by the motion demo so scripted hover isn't overridden by real mouse movement.
    var scripted = false

    func trackMouse() {
        guard let panel, drag == nil, !scripted else { return }
        let inside = hitRect.map { NSMouseInRect(NSEvent.mouseLocation, $0, false) } ?? false
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if hover.isHovering != inside { hover.isHovering = inside }
    }

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if drag == nil {
            drag = (mouse, panel.frame.origin)
            hover.isDragging = true
        }
        guard let drag else { return }
        var origin = NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y)
        // Keep the pill on a screen.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX - Self.size.width / 2 + 40), vf.maxX - Self.size.width / 2 - 40)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - Self.size.height)
        }
        panel.setFrameOrigin(origin)
    }

    func dragEnded() {
        guard let panel, drag != nil else { return }
        drag = nil
        hover.isDragging = false
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            UserDefaults.standard.set(Double((center.x - vf.minX) / vf.width), forKey: Prefs.Key.flowBarX)
            UserDefaults.standard.set(Double((panel.frame.minY - vf.minY) / vf.height), forKey: Prefs.Key.flowBarY)
            lastScreen = screen
        }
        trackMouse()
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Prefs.Key.flowBarX)
        UserDefaults.standard.removeObject(forKey: Prefs.Key.flowBarY)
        place(force: true)
    }

    /// The remembered spot (default: bottom-centre, just above the Dock) on the screen the mouse is on.
    func place(force: Bool) {
        guard let panel, drag == nil else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen, force || screen != lastScreen else { return }
        lastScreen = screen
        let vf = screen.visibleFrame
        let d = UserDefaults.standard
        let fx = d.object(forKey: Prefs.Key.flowBarX) as? Double ?? 0.5
        let fy = d.object(forKey: Prefs.Key.flowBarY) as? Double
        let x = vf.minX + vf.width * fx - Self.size.width / 2
        let y = fy.map { vf.minY + vf.height * $0 } ?? vf.minY + Self.pillBottomInset
        panel.setFrameOrigin(NSPoint(x: x, y: min(y, vf.maxY - Self.size.height)))
    }
}

final class FlowBarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Fully click-through by default; FlowBar.trackMouse() enables it only while the pointer is on the pill.
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Motion tokens for the Flow bar. It's summoned from the keyboard tens of times a day, so state changes are
/// fast and bounce-free: a strong ease-out (Emil Kowalski's cubic-bezier(0.23, 1, 0.32, 1)), under 200 ms.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Debug: `Yap --slowmo 5` plays every Flow bar animation 5× slower to inspect it frame by frame.
    static let slowmo: Double = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--slowmo"), i + 1 < a.count, let v = Double(a[i + 1]) else { return 1 }
        return max(1, v)
    }()
    /// Entering / morphing between states.
    static var enter: Animation { .timingCurve(0.23, 1, 0.32, 1, duration: 0.18 * slowmo) }
    /// Leaving: a touch quicker than entering.
    static var exit: Animation { .timingCurve(0.23, 1, 0.32, 1, duration: 0.14 * slowmo) }
    /// Button press feedback.
    static var press: Animation { .timingCurve(0.23, 1, 0.32, 1, duration: 0.12 * slowmo) }
    /// Drag lift/settle: a critically damped spring so it carries the gesture's velocity without bouncing.
    static var drag: Animation { .spring(duration: 0.3 * slowmo, bounce: 0) }

    /// Bubbles above the pill rise out of it and sink back into it: the same path both ways.
    static var bubble: AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .offset(y: 6))
    }
}

@MainActor
final class HoverState: ObservableObject {
    @Published var isHovering = false
    @Published var isDragging = false
}

/// Smoothed audio level: fast attack, slow release, like a VU meter. Not observable on purpose.
@MainActor
final class LevelMeter {
    var level: Float = 0
    private(set) var smoothed: CGFloat = 0
    /// Recent smoothed levels, newest last, sampled ~30×/s. The centre bar shows "now", outer bars the recent past.
    private(set) var history = [CGFloat](repeating: 0, count: 8)
    private var lastTick = Date.timeIntervalSinceReferenceDate
    private var lastSample = 0.0

    /// Back to silence, so a new session never starts with the last one's bars.
    func reset() {
        level = 0
        smoothed = 0
        history = history.map { _ in 0 }
    }

    func tick(_ now: TimeInterval) -> CGFloat {
        let dt = CGFloat(min(0.1, max(0.001, now - lastTick)))
        lastTick = now
        let target = CGFloat(level)
        let rate: CGFloat = target > smoothed ? 30 : 9   // fast attack, gentle release (per second)
        smoothed += (target - smoothed) * min(1, rate * dt)
        if now - lastSample > 1.0 / 30 {
            lastSample = now
            history.removeFirst()
            history.append(smoothed)
        }
        return smoothed
    }
}

// MARK: - View

struct FlowBarView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var hover = FlowBar.shared.hover

    private enum Mode: Equatable { case idle, hover, listening, locked, thinking }

    private var mode: Mode {
        switch controller.phase {
        case .idle: hover.isHovering || hover.isDragging ? .hover : .idle
        case .listening: .listening
        case .locked: .locked
        case .thinking: .thinking
        }
    }

    private var accent: Color { controller.isCommand ? Color(red: 0.75, green: 0.58, blue: 1) : .white }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if let notice = controller.notice {
                NoticeView(notice: notice).transition(Motion.bubble)
            } else if mode == .listening || mode == .locked, !controller.liveText.isEmpty {
                Text(tail(controller.liveText))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .frame(maxWidth: 400)
                    // Updates several times a second while you talk: never interpolate them.
                    .transaction(value: controller.liveText) { $0.animation = nil }
                    .transition(Motion.bubble.animation(Motion.enter))
            }
            pill.padding(.bottom, 2)
        }
        .frame(width: FlowBar.size.width, height: FlowBar.size.height, alignment: .bottom)
        .animation(mode == .idle ? Motion.exit : Motion.enter, value: mode)
        .animation(controller.notice == nil ? Motion.exit : Motion.enter, value: controller.notice)
        .animation(Motion.enter, value: controller.liveText.isEmpty)
    }

    /// Background, stroke and clip all hang off the same frame, so content can never drift outside the pill
    /// mid-morph; the shadow is cast by the composited result.
    private var pill: some View {
        pillContent
            .frame(width: pillSize.width, height: pillSize.height)
            .background(Capsule(style: .continuous).fill(.black.opacity(mode == .idle ? 0.55 : 0.9)))
            .overlay(Capsule(style: .continuous).strokeBorder(
                LinearGradient(colors: [.white.opacity(mode == .idle ? 0.28 : 0.2), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .clipShape(Capsule(style: .continuous))
            .compositingGroup()
            .shadow(color: .black.opacity(hover.isDragging ? 0.45 : mode == .idle ? 0.15 : 0.35),
                    radius: hover.isDragging ? 16 : mode == .idle ? 2 : 10, y: hover.isDragging ? 6 : 3)
            // Picked up: a slight lift (scale + deeper shadow), never a jump.
            .scaleEffect(hover.isDragging && !Motion.reduce ? 1.03 : 1)
            .animation(Motion.drag, value: hover.isDragging)
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in FlowBar.shared.dragChanged() }
                .onEnded { _ in FlowBar.shared.dragEnded() })
            .onTapGesture { if mode == .idle || mode == .hover { controller.toggleFromBar() } }
            // A fixed-height slot: bubbles above never move (or collide) while the pill changes height.
            .frame(height: 44, alignment: .bottom)
    }

    /// Every state's content is always present and only its opacity/scale changes, so the pill keeps one
    /// identity: no insert/remove transitions, no ghost pills. The waveform stays put while hands-free controls
    /// fade in at the pill's edges as it widens.
    private var pillContent: some View {
        let hearing = mode == .listening || mode == .locked
        let locked = mode == .locked
        let reduce = Motion.reduce
        return ZStack {
            HStack(spacing: 6) {
                Image(systemName: hover.isDragging ? "arrow.up.and.down.and.arrow.left.and.right" : "mic.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(hover.isDragging ? "Drop anywhere" : "Click or hold \(Shortcut.get(.dictate)?.display ?? "your key") · drag to move")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.88))
            .fixedSize()
            .opacity(mode == .hover ? 1 : 0)
            .scaleEffect(mode == .hover || reduce ? 1 : 0.95)

            HStack(spacing: 8) {
                if controller.isCommand {
                    Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                }
                LiveWaveform(color: hearing ? accent : .white, thinking: !hearing,
                             active: hearing || mode == .thinking)
                    .frame(width: hearing ? 92 : 60, height: hearing ? 24 : 18)
            }
            .fixedSize()
            .opacity(hearing || mode == .thinking ? 1 : 0)
            .scaleEffect(hearing || mode == .thinking || reduce ? 1 : 0.95)

            // Pinned to the pill's own edges (not the widest content), so they ride in as it widens.
            HStack {
                CircleButton(symbol: "xmark", help: "Cancel (Esc)") { controller.cancel() }
                Spacer(minLength: 0)
                CircleButton(symbol: "stop.fill", tint: .red, help: "Finish & paste") { Task { await controller.finish() } }
            }
            .padding(.horizontal, 9)
            .frame(width: pillSize.width)
            .opacity(locked ? 1 : 0)
            .allowsHitTesting(locked)
        }
    }

    private var pillSize: CGSize {
        switch mode {
        case .idle: CGSize(width: 40, height: 8)
        case .hover: CGSize(width: hover.isDragging ? 150 : 280, height: 28)
        case .listening: CGSize(width: controller.isCommand ? 136 : 116, height: 36)
        case .locked: CGSize(width: 184, height: 40)
        case .thinking: CGSize(width: 88, height: 30)
        }
    }

    private func tail(_ s: String) -> String { s.count > 120 ? "…" + s.suffix(120) : s }
}

/// 60 fps bars drawn with Canvas. Listening: the centre bar is the current level and each bar outward shows
/// a moment earlier, so speech visibly flows outward; it's the real signal, not a decorative wobble.
/// Thinking: a highlight moves across low bars at constant (linear) speed.
struct LiveWaveform: View {
    var color: Color
    var thinking: Bool
    /// Paused while hidden, so the idle bar costs nothing.
    var active: Bool = true
    private let count = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let meter = FlowBar.shared.meter
            let now = meter.tick(t)
            let history = meter.history
            let reduce = Motion.reduce
            Canvas { g, size in
                let barW: CGFloat = 3
                let gap = (size.width - barW * CGFloat(count)) / CGFloat(count - 1)
                let mid = (count - 1) / 2
                for i in 0..<count {
                    let d = abs(i - mid)                                   // 0 at centre … mid at edges
                    var h: CGFloat
                    var alpha: CGFloat = 1
                    if thinking {
                        let pos = CGFloat(i) / CGFloat(count - 1)
                        let sweep = reduce ? 0.5 : CGFloat((t / (1.3 * Motion.slowmo)).truncatingRemainder(dividingBy: 1)) * 1.8 - 0.4
                        let k = max(0, 1 - abs(pos - sweep) * 4)
                        h = 3 + 5 * k
                        alpha = 0.3 + 0.7 * k
                    } else {
                        let sample = d == 0 ? now : history[max(0, history.count - 1 - d)]
                        let envelope = 1 - CGFloat(d * d) / CGFloat(mid * mid) * 0.65    // taller in the middle
                        let loud = sample * 1.6 / (sample * 1.6 + 0.45) * 1.25   // soft knee, ~0.9 at full voice
                        h = 3 + (size.height - 3) * min(1, loud) * envelope
                        alpha = 0.45 + 0.55 * min(1, sample * 2.5)
                    }
                    let rect = CGRect(x: CGFloat(i) * (barW + gap), y: (size.height - h) / 2, width: barW, height: max(3, h))
                    g.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(color.opacity(alpha)))
                }
            }
        }
    }
}

private struct CircleButton: View {
    var symbol: String
    var tint: Color = .white.opacity(0.22)
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint, in: Circle())
        }
        .buttonStyle(PressScale())
        .help(help)
    }
}

/// Press feedback: shrink slightly while held, release on a strong ease-out.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduce ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

private struct NoticeView: View {
    var notice: DictationController.Notice
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notice.isError ? Color(red: 1, green: 0.45, blue: 0.42) : .white)
            Text(notice.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: 440)
    }
}
