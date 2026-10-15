import AVFoundation
import CoreAudio

struct MediaDevice: Identifiable, Hashable {
    let id: String          // AVCaptureDevice.uniqueID (for audio this is also the CoreAudio device UID)
    let name: String
    let isPhone: Bool       // Continuity Camera / iPhone mic

    var symbol: String { isPhone ? "iphone" : "video" }
}

/// Live list of cameras and microphones, including iPhones via Continuity Camera,
/// USB webcams, capture cards and external/Bluetooth mics.
@MainActor
final class Devices: ObservableObject {
    static let shared = Devices()

    @Published private(set) var cameras: [MediaDevice] = []
    @Published private(set) var microphones: [MediaDevice] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Devices.shared.refresh() }
            })
        }
    }

    func refresh() {
        cameras = Self.videoDiscovery().devices.map {
            MediaDevice(id: $0.uniqueID, name: $0.localizedName, isPhone: $0.deviceType == .continuityCamera)
        }
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map {
                MediaDevice(id: $0.uniqueID, name: $0.localizedName, isPhone: $0.localizedName.localizedCaseInsensitiveContains("iphone"))
            }
    }

    private static func videoDiscovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera],
                                         mediaType: .video, position: .unspecified)
    }

    // MARK: Resolving the user's choice ("" = automatic)

    nonisolated static var selectedCameraID: String { UserDefaults.standard.string(forKey: Prefs.Key.cameraID) ?? "" }
    nonisolated static var selectedMicID: String? {
        let id = UserDefaults.standard.string(forKey: Prefs.Key.micID) ?? ""
        return id.isEmpty ? nil : id
    }

    /// The chosen camera, or macOS's preferred one (which prefers a nearby iPhone when it's mounted).
    nonisolated static func camera() -> AVCaptureDevice? {
        let id = selectedCameraID
        if !id.isEmpty, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
    }

    /// Maps a microphone's UID to the CoreAudio device AVAudioEngine needs.
    nonisolated static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }
}

import SwiftUI

/// Camera / microphone pickers, used in Settings and as menu-bar submenus.
struct CameraPicker: View {
    @ObservedObject var devices = Devices.shared
    @AppStorage(Prefs.Key.cameraID) var cameraID = ""
    var onChange: () -> Void = {}

    var body: some View {
        Picker("Camera", selection: $cameraID) {
            Text("Automatic").tag("")
            ForEach(devices.cameras) { d in Label(d.name, systemImage: d.symbol).tag(d.id) }
        }
        .onChange(of: cameraID) { _, _ in onChange() }
    }
}

struct MicPicker: View {
    @ObservedObject var devices = Devices.shared
    @AppStorage(Prefs.Key.micID) var micID = ""

    var body: some View {
        Picker("Microphone", selection: $micID) {
            Text("System Default").tag("")
            ForEach(devices.microphones) { d in Label(d.name, systemImage: d.isPhone ? "iphone" : "mic").tag(d.id) }
        }
    }
}

struct ContinuityHint: View {
    var body: some View {
        Text("To use your iPhone, keep it near your Mac, locked and on its side or in a stand, on the same Apple Account with Wi‑Fi and Bluetooth on. It appears here automatically (Continuity Camera). USB webcams, capture cards and audio interfaces show up too.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
