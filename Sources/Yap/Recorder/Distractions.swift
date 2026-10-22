import AppKit
import ScreenCaptureKit

/// Keeps distractions out of recordings without touching Finder or Focus settings:
/// - desktop icons are covered by a window showing the wallpaper, just above the icons and below every app,
/// - notification banners are left out of the capture (see `quietApps`).
@MainActor
final class DesktopCover {
    private var panels: [NSPanel] = []

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.Key.recHideDistractions) }

    /// Covers the icons on `screen` and returns the cover's window, which the capture must keep.
    func show(on screen: NSScreen?) -> [CGWindowID] {
        hide()
        guard Self.isEnabled, let screen else { return [] }
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.isOpaque = true
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.imageScaling = .scaleAxesIndependently
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
            view.image = Self.filled(image, to: screen.frame.size)
        }
        view.wantsLayer = true
        view.layer?.backgroundColor = (NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor ?? .black).cgColor
        p.contentView = view
        p.setFrame(screen.frame, display: true)
        p.orderFrontRegardless()
        panels = [p]
        return [CGWindowID(p.windowNumber)]
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    /// Notification banners and alerts: left out of the video so they never end up in a recording.
    static func quietApps(in content: SCShareableContent) -> [SCRunningApplication] {
        guard isEnabled else { return [] }
        let ids: Set<String> = ["com.apple.notificationcenterui", "com.apple.UserNotificationCenter"]
        return content.applications.filter { ids.contains($0.bundleIdentifier) }
    }

    /// The wallpaper scaled to fill the screen (cropping the overflow), like the usual "Fill Screen" setting.
    private static func filled(_ image: NSImage, to size: CGSize) -> NSImage {
        let src = image.size
        guard src.width > 0, src.height > 0 else { return image }
        let k = max(size.width / src.width, size.height / src.height)
        let w = src.width * k, h = src.height * k
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        out.unlockFocus()
        return out
    }
}
