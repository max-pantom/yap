import AppKit
import CoreAudio
import SwiftUI

/// Notices when a call app (Zoom, Teams, FaceTime, Meet in a browser…) starts using the microphone and offers
/// meeting notes. It only asks; nothing records until you say so. When the call app lets go of the mic while
/// notes are running, it offers to end them.
@MainActor
final class CallDetector {
    static let shared = CallDetector()

    /// Bundle IDs of apps whose microphone use means "a call", with a friendly name.
    nonisolated static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex", "Cisco-Systems.Spark": "Webex", "com.webex.meetingmanager": "Webex",
        "net.whatsapp.WhatsApp": "WhatsApp", "ru.keepcoder.Telegram": "Telegram", "com.skype.skype": "Skype",
        "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox", "com.microsoft.edgemac": "Edge", "com.brave.Browser": "Brave",
    ]

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.Key.meetingSuggest) }

    private var timer: Timer?
    private var inCall: Set<String> = []          // apps using the mic right now
    private var asked: Set<String> = []           // asked about this call already
    private var quietSince: Date?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { CallDetector.shared.tick() }
        }
    }

    private func tick() {
        let now = Set(Self.appsUsingMic().filter { Self.callApps[$0] != nil })
        let started = now.subtracting(inCall)
        asked.formIntersection(now)               // a new call later asks again
        inCall = now
        let meeting = AppModel.shared.meeting
        if meeting.phase == .idle, Self.isEnabled, let app = started.first(where: { !asked.contains($0) && !Self.muted.contains($0) }) {
            asked.insert(app)
            CallPrompt.shared.offerNotes(app: app, name: Self.callApps[app] ?? "A call app")
        }
        // Notes running and every call app has let go of the mic for a while: offer to end them.
        if meeting.phase == .recording {
            if now.isEmpty { quietSince = quietSince ?? Date() } else { quietSince = nil; CallPrompt.shared.hideEndOffer() }
            if let q = quietSince, Date().timeIntervalSince(q) > 8 { quietSince = .distantFuture; CallPrompt.shared.offerEnd() }
        } else { quietSince = nil }
    }

    /// Apps you said never to ask about.
    static var muted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Prefs.Key.meetingSuggestMuted) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Prefs.Key.meetingSuggestMuted) }
    }

    /// Bundle IDs of other apps capturing from a microphone right now (CoreAudio process objects, macOS 14+).
    nonisolated static func appsUsingMic() -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.compactMap { obj -> String? in
            var running: UInt32 = 0, rs = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(obj, &a, 0, nil, &rs, &running) == noErr, running != 0 else { return nil }
            var pid: pid_t = 0, ps = UInt32(MemoryLayout<pid_t>.size)
            a.mSelector = kAudioProcessPropertyPID
            if AudioObjectGetPropertyData(obj, &a, 0, nil, &ps, &pid) == noErr, pid == me { return nil }
            var bundle: Unmanaged<CFString>?, bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            a.mSelector = kAudioProcessPropertyBundleID
            guard AudioObjectGetPropertyData(obj, &a, 0, nil, &bs, &bundle) == noErr, let b = bundle?.takeRetainedValue() else { return nil }
            return b as String
        }
    }
}

/// The small prompt in the top-right corner: "Zoom is using your mic. Take meeting notes?"
@MainActor
final class CallPrompt {
    static let shared = CallPrompt()
    private var panel: OverlayPanel?
    private var hideTask: Task<Void, Never>?
    private var showingEnd = false

    func offerNotes(app: String, name: String) {
        show(PromptView(symbol: "person.2.wave.2.fill", text: "\(name) is using your mic. Take meeting notes?",
                        primary: "Take Notes", secondary: "Not Now", tertiary: "Never for \(name)",
                        onPrimary: { [weak self] in self?.hide(); AppModel.shared.meeting.start() },
                        onSecondary: { [weak self] in self?.hide() },
                        onTertiary: { [weak self] in CallDetector.muted.insert(app); self?.hide() }), seconds: 14)
    }

    func offerEnd() {
        showingEnd = true
        show(PromptView(symbol: "phone.down.fill", text: "The call seems to be over. End meeting notes?",
                        primary: "End Notes", secondary: "Keep Going", tertiary: nil,
                        onPrimary: { [weak self] in self?.hide(); Task { await AppModel.shared.meeting.stop() } },
                        onSecondary: { [weak self] in self?.hide() }, onTertiary: nil), seconds: 20)
    }

    func hideEndOffer() { if showingEnd { hide() } }

    private func show(_ view: PromptView, seconds: Double) {
        hide()
        let p = OverlayPanel(size: NSSize(width: 380, height: 118), interactive: true)
        p.contentView = NSHostingView(rootView: view)
        if let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.maxX - 380 - 16, y: f.maxY - 118 - 12))
        }
        p.orderFrontRegardless()
        panel = p
        Sounds.play("Tink")
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel(); hideTask = nil
        panel?.orderOut(nil); panel = nil
        showingEnd = false
    }
}

private struct PromptView: View {
    let symbol: String, text: String, primary: String, secondary: String, tertiary: String?
    let onPrimary: () -> Void, onSecondary: () -> Void, onTertiary: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.white)
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(primary, action: onPrimary).buttonStyle(.borderedProminent).controlSize(.small)
                Button(secondary, action: onSecondary).controlSize(.small)
                if let tertiary, let onTertiary { Spacer(); Button(tertiary, action: onTertiary).buttonStyle(.link).controlSize(.small).foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .padding(14)
        .frame(width: 380, height: 118, alignment: .topLeading)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}
