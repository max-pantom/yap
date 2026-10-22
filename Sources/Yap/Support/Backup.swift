import AppKit
import UniformTypeIdentifiers

/// One file with everything you've set up: settings, shortcuts, dictionary, snippets, app styles and the dictation
/// history. For a new Mac or a backup. Recordings stay in their folder (copy that folder too), and an API key
/// for a custom server stays in the Keychain.
@MainActor
enum Backup {
    private static let skippedPrefixes = ["NS", "SU", "Apple", "com.apple", "WebKit", "AK"]
    /// Things that belong to one Mac: folders that may not exist on the other, and this Mac's camera and mic.
    private static let machineKeys: Set<String> = [Prefs.Key.recFolder, Prefs.Key.historyFolder, Prefs.Key.micID, Prefs.Key.cameraID]
    private static func portable(_ key: String) -> Bool { !machineKeys.contains(key) && !skippedPrefixes.contains { key.hasPrefix($0) } }

    static func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Yap Backup \(Date().formatted(.iso8601.year().month().day())).yapbackup"
        panel.allowedContentTypes = [.propertyList]
        panel.allowsOtherFileTypes = true
        panel.message = "Settings, shortcuts, dictionary, snippets and your dictation history."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data().write(to: url, options: .atomic)
            HUD.shared.toast("Backed up to \(url.lastPathComponent)", symbol: "checkmark.circle.fill")
        } catch {
            HUD.shared.toast("Couldn't save the backup: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    static func data() throws -> Data {
        let id = Bundle.main.bundleIdentifier ?? "app.yap.mac"
        let prefs = (UserDefaults.standard.persistentDomain(forName: id) ?? [:])
            .filter { key, _ in portable(key) }
        let history = try JSONEncoder().encode(AppModel.shared.history.entries)
        let file: [String: Any] = ["format": "yap-backup", "version": 1, "created": Date(),
                                   "yap": Updater.shared.currentVersion, "settings": prefs, "history": history]
        return try PropertyListSerialization.data(fromPropertyList: file, format: .binary, options: 0)
    }

    static func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yapbackup") ?? .data, .propertyList]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a Yap backup (.yapbackup)."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              file["format"] as? String == "yap-backup" else {
            HUD.shared.toast("That isn't a Yap backup", symbol: "exclamationmark.triangle.fill"); return
        }
        let alert = NSAlert()
        let when = (file["created"] as? Date)?.formatted(date: .abbreviated, time: .shortened) ?? "an earlier date"
        alert.messageText = "Restore this backup from \(when)?"
        alert.informativeText = "Your settings, shortcuts, dictionary and snippets are replaced by the backup's. Your dictation history is merged with it, so nothing is lost."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let count = restore(file)
        let done = NSAlert()
        done.messageText = "Restored"
        done.informativeText = "Your history now has \(count) dictations. Relaunch Yap so every setting takes effect."
        done.addButton(withTitle: "Relaunch Now")
        done.addButton(withTitle: "Later")
        if done.runModal() == .alertFirstButtonReturn { AppModel.relaunch() }
    }

    /// Applies a backup; returns the size of the merged history.
    @discardableResult
    static func restore(_ file: [String: Any]) -> Int {
        let d = UserDefaults.standard
        for (key, value) in file["settings"] as? [String: Any] ?? [:] where portable(key) {
            d.set(value, forKey: key)
        }
        NotificationCenter.default.post(name: Shortcut.didChange, object: nil)
        if let data = file["history"] as? Data, let entries = try? JSONDecoder().decode([DictationEntry].self, from: data) {
            return AppModel.shared.history.merge(entries)
        }
        return AppModel.shared.history.entries.count
    }
}
