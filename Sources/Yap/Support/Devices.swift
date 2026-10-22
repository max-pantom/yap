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
        if id == priorityChoice {   // the first mic on your list that's plugged in, else the Mac's default
            return micPriority.first { AVCaptureDevice(uniqueID: $0.uid) != nil }?.uid
        }
        return id.isEmpty ? nil : id
    }

    /// The microphone setting that means "use my priority list".
    nonisolated static let priorityChoice = "priority"
    /// Your microphones, best first. Names are kept so unplugged ones still show in Settings.
    nonisolated static var micPriority: [(uid: String, name: String)] {
        get {
            (UserDefaults.standard.stringArray(forKey: Prefs.Key.micPriority) ?? []).compactMap {
                let parts = $0.split(separator: "|", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
        }
        set { UserDefaults.standard.set(newValue.map { "\($0.uid)|\($0.name)" }, forKey: Prefs.Key.micPriority) }
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
            Text("My Priority List").tag(Devices.priorityChoice)
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

/// The priority list: the first microphone here that's connected is used. Shown when "My Priority List" is picked.
struct MicPriorityEditor: View {
    @ObservedObject var devices = Devices.shared
    @AppStorage(Prefs.Key.micID) var micID = ""
    @Local private var list = Devices.micPriority

    var body: some View {
        if micID == Devices.priorityChoice {
            VStack(alignment: .leading, spacing: 5) {
                if list.isEmpty { Text("Add your microphones, best first.").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(list.enumerated()), id: \.element.uid) { i, mic in
                    let connected = devices.microphones.contains { $0.id == mic.uid }
                    let inUse = Devices.selectedMicID == mic.uid
                    HStack(spacing: 6) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                        Text(mic.name).foregroundStyle(connected ? .primary : .secondary)
                        if inUse { Text("in use").font(.caption).foregroundStyle(.green) }
                        else if !connected { Text("not connected").font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 8)
                        Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0).help("Higher")
                        Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == list.count - 1).help("Lower")
                        Button { list.remove(at: i); save() } label: { Image(systemName: "minus.circle") }.help("Remove")
                    }
                    .buttonStyle(.borderless)
                }
                let more = devices.microphones.filter { m in !list.contains { $0.uid == m.id } }
                Menu("Add a Microphone") {
                    ForEach(more) { m in Button(m.name) { list.append((m.id, m.name)); save() } }
                }
                .fixedSize()
                .disabled(more.isEmpty)
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    private func move(_ i: Int, _ by: Int) {
        let j = i + by
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j); save()
    }
    private func save() { Devices.micPriority = list }
}
