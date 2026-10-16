import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
import VisionKit
#endif

/// Everything iOS-specific lives here, so the rest of the app also type-checks against the macOS SDK.
enum Platform {
    enum Haptic { case start, stop, success, error }

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "iPhone"
        #endif
    }

    static func haptic(_ h: Haptic) {
        #if os(iOS)
        switch h {
        case .start: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .stop: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }

    static func activateRecordingSession() throws {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .spokenAudio)
        try s.setActive(true)
        #endif
    }

    static func deactivateRecordingSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// The phone stays awake while Yap Mic is open, so it's ready when you pick it up.
    @MainActor static func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    static var canScan: Bool {
        #if os(iOS)
        DataScannerViewController.isSupported
        #else
        false
        #endif
    }
}

/// Live camera QR scanner (VisionKit). Calls `found` once with the first Yap pairing code it sees.
struct PairScanner: View {
    let found: (MicLink.Pairing) -> Void

    var body: some View {
        #if os(iOS)
        ScannerRep(found: found).ignoresSafeArea()
        #else
        Text("Scanning needs an iPhone")
        #endif
    }
}

#if os(iOS)
private struct ScannerRep: UIViewControllerRepresentable {
    let found: (MicLink.Pairing) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (MicLink.Pairing) -> Void
        private var done = false
        init(found: @escaping (MicLink.Pairing) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let s = code.payloadStringValue, let url = URL(string: s), let p = MicLink.Pairing(url: url) else { continue }
                done = true
                found(p)
            }
        }
    }
}
#endif
