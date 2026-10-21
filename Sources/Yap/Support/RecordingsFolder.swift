import AppKit
import SwiftUI

/// Where recordings live: the videos, their captions and notes (.yap.json, .clicks.json), the hidden un-zoomed
/// originals and Meetings. Changing it can bring the existing files along.
@MainActor
enum RecordingsFolder {
    static var isDefault: Bool { (UserDefaults.standard.string(forKey: Prefs.Key.recFolder) ?? "").isEmpty }

    static func choose() {
        guard let url = FolderPicker.pick("Choose where Yap saves recordings, their notes and meeting notes.",
                                          from: Prefs.recordingsFolder.deletingLastPathComponent()) else { return }
        change(to: url)
    }

    static func useDefault() { change(to: nil) }

    /// `nil` means the default, ~/Movies/Yap.
    private static func change(to url: URL?) {
        let old = Prefs.recordingsFolder.standardizedFileURL
        let d = UserDefaults.standard
        if let url { d.set(url.standardizedFileURL.path, forKey: Prefs.Key.recFolder) } else { d.removeObject(forKey: Prefs.Key.recFolder) }
        let new = Prefs.recordingsFolder.standardizedFileURL
        guard new != old else { return }
        try? FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        let items = movableItems(in: old, excluding: new)
        if !items.isEmpty, askToMove(count: items.count, to: new) {
            HUD.shared.toast("Moving your recordings…", symbol: "folder")
            Task.detached {
                let (moved, skipped) = move(items, to: new)
                await MainActor.run {
                    reloadEverything()
                    let note = skipped > 0 ? ", \(skipped) left behind (same name already there)" : ""
                    HUD.shared.toast("Moved \(moved) item\(moved == 1 ? "" : "s") to \(display(new))\(note)", symbol: "checkmark.circle.fill")
                }
            }
        } else {
            reloadEverything()
            HUD.shared.toast("New recordings will be saved in \(display(new))", symbol: "folder")
        }
    }

    static func display(_ url: URL) -> String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private static func reloadEverything() {
        AppModel.shared.library.reload()
        AppModel.shared.meeting.store.reload()
    }

    private static func movableItems(in folder: URL, excluding new: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // Never move the new folder into itself when it sits inside the old one.
        return all.filter { $0.lastPathComponent != ".DS_Store" && !new.path.hasPrefix($0.standardizedFileURL.path) }
    }

    private static func askToMove(count: Int, to new: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move your recordings to the new folder?"
        alert.informativeText = "\(count) item\(count == 1 ? "" : "s") (videos, captions, notes and meetings) will move to \(display(new)). Dictation history stays where it is."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Leave Them")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Moves each item; folders that already exist on the other side (Meetings, .originals) are merged.
    nonisolated static func move(_ items: [URL], to dest: URL) -> (Int, Int) {
        let fm = FileManager.default
        var moved = 0, skipped = 0
        for item in items {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
                var srcDir: ObjCBool = false
                if isDir.boolValue, fm.fileExists(atPath: item.path, isDirectory: &srcDir), srcDir.boolValue {
                    let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    let (m, s) = move(inner, to: target)
                    moved += m; skipped += s
                    let left = (try? fm.contentsOfDirectory(atPath: item.path))?.filter { $0 != ".DS_Store" } ?? ["?"]
                    if left.isEmpty { try? fm.removeItem(at: item) }   // never delete a folder that still holds files
                } else {
                    skipped += 1
                }
                continue
            }
            do { try fm.moveItem(at: item, to: target); moved += 1 } catch { skipped += 1 }
        }
        return (moved, skipped)
    }
}

/// "Saved in: ~/Movies/Yap   Change…  Use Default", for both Settings designs.
struct RecordingsFolderControl: View {
    @AppStorage(Prefs.Key.recFolder) private var custom = ""

    var body: some View {
        HStack(spacing: 10) {
            Button(RecordingsFolder.display(Prefs.recordingsFolder)) {
                try? FileManager.default.createDirectory(at: Prefs.recordingsFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Prefs.recordingsFolder)
            }
            .buttonStyle(.link)
            .help("Show in Finder")
            Button("Change…") { RecordingsFolder.choose() }
            if !custom.isEmpty { Button("Use Default") { RecordingsFolder.useDefault() } }
        }
        .id(custom)
    }
}

@MainActor
enum FolderPicker {
    static func pick(_ message: String, from start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = message
        panel.directoryURL = start
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// "~/Library/Application Support/Yap   Change…  Use Default" for the dictation history (history.json).
struct HistoryFolderControl: View {
    @AppStorage(Prefs.Key.historyFolder) private var custom = ""

    var body: some View {
        HStack(spacing: 10) {
            Button(RecordingsFolder.display(Prefs.historyFolder)) {
                NSWorkspace.shared.activateFileViewerSelecting([Prefs.historyFolder.appendingPathComponent("history.json")])
            }
            .buttonStyle(.link)
            .help("Show history.json in Finder")
            Button("Change…") {
                guard let url = FolderPicker.pick("Choose where Yap keeps your dictation history (history.json).", from: Prefs.historyFolder) else { return }
                moved(AppModel.shared.history.relocate(to: url))
            }
            if !custom.isEmpty { Button("Use Default") { moved(AppModel.shared.history.relocate(to: nil)) } }
        }
        .id(custom)
    }

    private func moved(_ count: Int) {
        HUD.shared.toast("Dictation history (\(count) entries) is now in \(RecordingsFolder.display(Prefs.historyFolder))", symbol: "folder")
    }
}
