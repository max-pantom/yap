import AppKit
import SwiftUI

/// The startup moment: the mark's rings slide in and its outline draws on, then it fades away.
/// Click-through, never takes focus, about 1.8 s in total.
@MainActor
enum Splash {
    private static var panel: NSPanel?

    static func show() {
        let size = NSSize(width: 176, height: 176)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: SplashView())
        if let f = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.08))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p

        MarkMotion.shared.play(.startup)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + MarkConfig.startDuration + 0.45) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) {
                Task { @MainActor in p.orderOut(nil); panel = nil }
            }
        }
    }
}

private struct SplashView: View {
    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            MarkView(size: 112)
        }
        .frame(width: 168, height: 168)
        .frame(width: 176, height: 176)
    }
}
