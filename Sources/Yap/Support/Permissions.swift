import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

enum Permission: String, CaseIterable, Identifiable {
    case microphone, accessibility, inputMonitoring, screenRecording, camera
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen & System Audio Recording"
        case .camera: "Camera"
        }
    }

    var why: String {
        switch self {
        case .microphone: "Hear you while you hold the dictation key."
        case .accessibility: "Paste text into the app you're using and read selected text for Command Mode."
        case .inputMonitoring: "Notice when you hold the dictation key."
        case .screenRecording: "Record your screen. Only used while you're recording."
        case .camera: "Optional: the camera bubble in recordings."
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// The TCC service name used by `tccutil`.
    private var tccService: String {
        switch self {
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "ListenEvent"
        case .screenRecording: "ScreenCapture"
        }
    }

    /// Removes Yap's own (possibly stale) entry for this permission so macOS asks again cleanly.
    /// Entries left by earlier builds don't match the current app, which makes the switch in
    /// System Settings flip straight back off.
    private func resetStaleEntry() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", tccService, Bundle.main.bundleIdentifier ?? "app.yap.mac"]
        try? p.run()
        p.waitUntilExit()
        Log.write("tccutil reset \(tccService) → \(p.terminationStatus)")
    }

    func request() {
        guard !isGranted else { return }
        switch self {
        case .microphone, .camera:
            let type: AVMediaType = self == .microphone ? .audio : .video
            if AVCaptureDevice.authorizationStatus(for: type) == .denied { resetStaleEntry() }
        default:
            resetStaleEntry()
        }
        switch self {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        case .accessibility:
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) { openPane("Privacy_Accessibility") }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openPane("Privacy_ListenEvent") }
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            Task {
                _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try? await Task.sleep(for: .milliseconds(600))
                if !CGPreflightScreenCaptureAccess() { await MainActor.run { openPane("Privacy_ScreenCapture") } }
            }
        }
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static var dictationReady: Bool {
        Permission.microphone.isGranted && Permission.accessibility.isGranted && Permission.inputMonitoring.isGranted
    }
}

enum Sounds {
    static func play(_ name: String) {
        guard Prefs.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func error() { play("Basso") }
}
