import AppKit

/// `yap://` links, so Shortcuts, Raycast, Alfred, Stream Deck or a script can drive Yap:
///
///     yap://dictate            start hands-free dictation, or finish it      (?action=start|stop|cancel)
///     yap://command            same, in Command Mode
///     yap://record             start or stop a screen recording              (?action=start|stop|discard)
///     yap://record-window      pick a window or app to record
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
        ("yap://record?action=discard", "Also: start, stop"),
        ("yap://record-window", "Pick a window or app to record"),
        ("yap://camera", "Show or hide the camera bubble"),
        ("yap://copy-last", "Copy your last dictation"),
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
        case "settings": model.showSettings(); return
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
            default: rec.toggle()
            }
        case "record-window": rec.recordPicked()
        case "camera": rec.camera.toggle()
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
