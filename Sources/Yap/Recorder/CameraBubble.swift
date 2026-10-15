import AppKit
@preconcurrency import AVFoundation

/// Floating, draggable, circular camera preview. Because it's a real on-screen window it shows up
/// in display recordings (we explicitly keep it in the capture filter) at zero extra compositing cost.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    private var configured = false

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowNumber: Int? { panel?.windowNumber }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { Task { @MainActor in self.show() } }
            }
            return
        }
        if !configured { configure() }
        let size = CGFloat(UserDefaults.standard.double(forKey: Prefs.Key.bubbleSize))
        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        if !panel.isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.minX + 32, y: f.minY + 32))
        }
        panel.orderFrontRegardless()
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { if !session.isRunning { session.startRunning() } }
    }

    func hide() {
        panel?.orderOut(nil)
        let session = self.session
        DispatchQueue.global(qos: .utility).async { if session.isRunning { session.stopRunning() } }
    }

    func cycleSize() {
        guard let panel else { return }
        let sizes: [CGFloat] = [160, 220, 320]
        let current = panel.frame.width
        let next = sizes.first { $0 > current + 1 } ?? sizes[0]
        UserDefaults.standard.set(Double(next), forKey: Prefs.Key.bubbleSize)
        var frame = panel.frame
        frame.size = NSSize(width: next, height: next)
        panel.setFrame(frame, display: true, animate: true)
        panel.contentView?.layer?.cornerRadius = next / 2
    }

    private var preview: AVCaptureVideoPreviewLayer?

    private func configure() {
        configured = true
        useSelectedDevice()
    }

    /// Switches the bubble to the camera picked in Settings / the menu (e.g. an iPhone via Continuity Camera).
    func useSelectedDevice() {
        guard configured, let device = Devices.camera() else { return }
        if let current = session.inputs.first as? AVCaptureDeviceInput, current.device.uniqueID == device.uniqueID { return }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) { session.addInput(input) }
        session.sessionPreset = session.canSetSessionPreset(.high) ? .high : .medium
        session.commitConfiguration()
        updateMirroring(for: device)
    }

    /// Mirror front-facing webcams like a mirror; an iPhone's rear camera should show the world as-is.
    private func updateMirroring(for device: AVCaptureDevice) {
        guard let conn = preview?.connection, conn.isVideoMirroringSupported else { return }
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = device.deviceType != .continuityCamera
    }

    private func makePanel(size: CGFloat) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true

        let view = BubbleView(frame: panel.contentRect(forFrameRect: panel.frame))
        view.onDoubleClick = { [weak self] in self?.cycleSize() }
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(preview)
        self.preview = preview
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device { updateMirroring(for: device) }
        panel.contentView = view
        return panel
    }
}

private final class BubbleView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        window?.performDrag(with: event)
    }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
