import AppKit

/// `yap://` links, so Shortcuts, Raycast, Alfred, Stream Deck or a script can drive Yap:
///
///     yap://dictate            start hands-free dictation, or finish it      (?action=start|stop|cancel)
///     yap://command            same, in Command Mode
///     yap://record             start or stop a screen recording              (?action=start|stop|discard)
///     yap://record-window      pick a window or app to record
///     yap://meeting            start or end meeting notes                    (?action=start|stop|discard)
///     yap://camera             show or hide the camera bubble
///     yap://copy-last          copy your last dictation to the clipboard
///     yap://library  ·  yap://settings
///
/// Turn them off in Settings → General. Browsers ask before opening a yap:// link.
@MainActor
enum URLCommands {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.Key.urlCommands) }

    /// Shown in Settings → General.
    static let reference: [(String, String)] = [
        ("yap://dictate", "Start hands-free dictation, or finish it"),
        ("yap://dictate?action=cancel", "Also: start, stop"),
        ("yap://command", "Command Mode on your selection"),
        ("yap://record", "Start or stop recording the screen"),
        ("yap://record?action=pause", "Also: start, stop, resume, discard"),
        ("yap://record-window", "Pick a window or app to record"),
        ("yap://meeting", "Start or end meeting notes"),
        ("yap://meeting?action=discard", "Also: start, stop"),
        ("yap://camera", "Show or hide the camera bubble"),
        ("yap://camera?mode=full", "Camera full screen, or back to the bubble"),
        ("yap://copy-last", "Copy your last dictation"),
        ("yap://pause?minutes=60", "Pause Yap (the dictation key) for a while"),
        ("yap://resume", "Resume Yap"),
        ("yap://library", "Open the Library"),
        ("yap://settings", "Open Settings"),
    ]

    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "yap" else { return }
        let command = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "action" }?.value?.lowercased()
        Log.write("url command: \(command) \(action ?? "")")
        let model = AppModel.shared
        switch command {
        case "library": model.showLibrary(); return
        case "settings":
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            model.showSettings(page: page.flatMap(SettingsView.Page.named)); return
        default: break
        }
        guard isEnabled else {
            HUD.shared.toast("yap:// links are turned off in Settings → General", symbol: "link.badge.plus")
            return
        }
        let d = model.dictation, rec = model.recorder
        switch command {
        case "dictate", "command":
            let running = d.phase == .listening || d.phase == .locked
            switch action {
            case "cancel": d.cancel()
            case "stop": if running { Task { await d.finish() } }
            case "start": if d.phase == .idle { d.beginHandsFree(command: command == "command") }
            default: if running { Task { await d.finish() } } else { d.beginHandsFree(command: command == "command") }
            }
        case "record":
            switch action {
            case "start": if !rec.isActive { rec.toggle() }
            case "stop": if rec.phase == .recording { Task { await rec.stop() } }
            case "discard": rec.cancel()
            case "pause": Task { await rec.pause() }
            case "resume": Task { await rec.resume() }
            default: rec.toggle()
            }
        case "pause":
            let m = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "minutes" }?.value.flatMap(Int.init)
            d.pauseYap(minutes: m ?? 60)
        case "resume": d.resumeYap()
        case "record-window": rec.recordPicked()
        case "meeting":
            let m = model.meeting
            switch action {
            case "start": m.start()
            case "stop": Task { await m.stop() }
            case "discard": m.discard()
            default: m.toggle()
            }
        case "camera":
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "mode" })?.value == "full" {
                rec.camera.toggleFullScreen()
            } else { rec.camera.toggle() }
        case "copy-last":
            guard let last = model.history.entries.first else { HUD.shared.toast("No dictations yet", symbol: "text.bubble"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(last.text, forType: .string)
            HUD.shared.toast("Last dictation copied", symbol: "doc.on.clipboard.fill")
        default:
            HUD.shared.toast("Unknown Yap link: \(command)", symbol: "questionmark.circle")
        }
    }
}
