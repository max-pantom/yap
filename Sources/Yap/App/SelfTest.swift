import AVFoundation
import Foundation

/// `Yap --selftest <audio-file>`: runs the on-device pipeline (speech → cleanup → insights) and prints results.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--whisper-test"), i + 2 < args.count {
            let variant = args[i + 1], file = args[i + 2]
            Prefs.registerDefaults()
            Task { @MainActor in
                let w = WhisperEngine.shared
                let t0 = Date()
                await w.download(variant)
                print("download:", w.downloaded[variant] != nil ? "ok" : "FAILED (\(w.status))", String(format: "%.1fs", Date().timeIntervalSince(t0)))
                w.use(variant)
                do {
                    let t1 = Date()
                    try await w.ensureLoaded()
                    print("load:", String(format: "%.1fs", Date().timeIntervalSince(t1)))
                    let t2 = Date()
                    let segs = try await w.transcribe(file: file)
                    print("transcribe:", String(format: "%.2fs", Date().timeIntervalSince(t2)), "→", segs.map(\.text).joined(separator: " "))
                } catch { print("FAILED:", error) }
                w.delete(variant)
                print("cleaned up; engine =", UserDefaults.standard.string(forKey: Prefs.Key.speechEngine) ?? "?")
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--deliver"), i + 1 < args.count {
            Prefs.registerDefaults()
            MainActor.assumeIsolated { print("delivery:", TextBridge.deliver(args[i + 1])) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--tidy-test"), i + 1 < args.count {
            let src = URL(fileURLWithPath: args[i + 1]), out = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-\(UUID().uuidString).mp4")
            Prefs.registerDefaults()
            Task {
                do {
                    let words = try await Tighten.words(in: src)
                    print("words:", words.map { "\($0.text)@\(String(format: "%.2f", $0.start))" }.joined(separator: " "))
                    let d = try await AVURLAsset(url: src).load(.duration).seconds
                    print("cuts:", Tighten.cuts(words, duration: d).map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) })
                    let r = try await Tighten.apply(to: src, output: out)
                    let nd = try await AVURLAsset(url: r.url).load(.duration).seconds
                    print(String(format: "tidied: %.2fs → %.2fs, %d fillers, %.2fs removed", d, nd, r.fillers, r.removed), abs((d - r.removed) - nd) < 0.3 ? "ok" : "FAILED")
                    try? FileManager.default.removeItem(at: out)
                    exit(0)
                } catch { print("FAILED:", error); exit(1) }
            }
            RunLoop.main.run()
        }
        if args.contains("--ask-test") {
            Prefs.registerDefaults()
            let a = Meeting(title: "Pricing review", summary: "Agreed Pro stays at $8 a month; a yearly plan at $72 launches in November.",
                            actions: [.init(text: "Update the pricing page (Ada, Friday)")],
                            lines: [.init(start: 3, end: 6, speaker: .others, text: "Let's keep Pro at eight dollars a month.")],
                            created: Date().addingTimeInterval(-86400 * 3), duration: 1200)
            let b = Meeting(title: "Launch sync", summary: "1.2 ships Thursday. Maya writes the release notes.",
                            actions: [.init(text: "Write the release notes (Maya)")], lines: [], created: Date(), duration: 900)
            Task {
                for q in ["What did we decide about pricing?", "Who is writing the release notes?", "What colour is the new logo?"] {
                    let t0 = Date()
                    print(String(format: "Q: %@ (%.1fs)\nA: %@\n", q, Date().timeIntervalSince(t0), await Polisher.shared.ask(q, meetings: [a, b]) ?? "no model"))
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        if args.contains("--mic-users") {
            let apps = CallDetector.appsUsingMic()
            print("apps using a microphone:", apps.isEmpty ? "none" : apps.map { "\($0)\(CallDetector.callApps[$0].map { " (\($0))" } ?? "")" }.joined(separator: ", "))
            exit(0)
        }
        if args.contains("--backup-test") {
            Prefs.registerDefaults()
            MainActor.assumeIsolated {
                let data = try! Backup.data()
                let file = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
                let settings = file["settings"] as? [String: Any] ?? [:]
                let leaked = [Prefs.Key.recFolder, Prefs.Key.historyFolder, Prefs.Key.micID, Prefs.Key.cameraID].filter { settings[$0] != nil }
                let hist = (try? JSONDecoder().decode([DictationEntry].self, from: file["history"] as? Data ?? Data()))?.count ?? -1
                print("backup: \(data.count) bytes, \(settings.count) settings, \(hist) dictations, machine keys leaked: \(leaked)", leaked.isEmpty && hist >= 0 ? "ok" : "FAILED")
                exit(leaked.isEmpty && hist >= 0 ? 0 : 1)
            }
        }
        if args.contains("--history-move-test") {
            // Moving the dictation history: merged by id, newest first, the old file sent to the Trash.
            let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("yap-hist-\(UUID().uuidString)")
            let A = root.appendingPathComponent("A"), B = root.appendingPathComponent("B")
            try? fm.createDirectory(at: A, withIntermediateDirectories: true); try? fm.createDirectory(at: B, withIntermediateDirectories: true)
            let e1 = DictationEntry(date: Date(timeIntervalSince1970: 1), raw: "one", text: "one", duration: 1, isCommand: false)
            let e2 = DictationEntry(date: Date(timeIntervalSince1970: 2), raw: "two", text: "two", duration: 1, isCommand: false)
            let e3 = DictationEntry(date: Date(timeIntervalSince1970: 3), raw: "three", text: "three", duration: 1, isCommand: false)
            try! JSONEncoder().encode([e2, e1]).write(to: A.appendingPathComponent("history.json"))
            try! JSONEncoder().encode([e3, e2]).write(to: B.appendingPathComponent("history.json"))
            let d = UserDefaults.standard, prev = d.string(forKey: Prefs.Key.historyFolder)
            d.set(A.path, forKey: Prefs.Key.historyFolder)        // never touch the real history
            MainActor.assumeIsolated {
                let store = HistoryStore()
                let before = store.entries.count
                let after = store.relocate(to: B)
                let onDisk = (try? JSONDecoder().decode([DictationEntry].self, from: Data(contentsOf: B.appendingPathComponent("history.json")))) ?? []
                let ok = before == 2 && after == 3 && onDisk.map(\.text) == ["three", "two", "one"]
                    && !fm.fileExists(atPath: A.appendingPathComponent("history.json").path)
                print("history: \(before) → \(after), on disk \(onDisk.map(\.text)):", ok ? "ok" : "FAILED")
                if let prev { d.set(prev, forKey: Prefs.Key.historyFolder) } else { d.removeObject(forKey: Prefs.Key.historyFolder) }
                try? fm.removeItem(at: root)
                exit(ok ? 0 : 1)
            }
        }
        if args.contains("--folder-move-test") {
            // Moving recordings to a new folder: files move, existing folders merge, same-name files stay behind.
            let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("yap-move-\(UUID().uuidString)")
            let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
            func put(_ path: String, in dir: URL, _ text: String = "x") {
                let u = dir.appendingPathComponent(path)
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: u, atomically: true, encoding: .utf8)
            }
            for f in ["a.mp4", "a.yap.json", "a.clicks.json", "a.srt", ".originals/a.mp4", "Meetings/M1/meeting.json", "Meetings/M2/meeting.json", "dup.mp4"] { put(f, in: old) }
            put("Meetings/M1/meeting.json", in: new, "already here"); put("dup.mp4", in: new, "already here")
            let items = try! fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
            let (moved, skipped) = RecordingsFolder.move(items, to: new)
            let exists = { (p: String, d: URL) in fm.fileExists(atPath: d.appendingPathComponent(p).path) }
            let ok = ["a.mp4", "a.yap.json", "a.clicks.json", "a.srt", ".originals/a.mp4", "Meetings/M2/meeting.json"].allSatisfy { exists($0, new) }
                && exists("Meetings/M1/meeting.json", old) && exists("dup.mp4", old)          // conflicts stay behind, not lost
                && (try? String(contentsOf: new.appendingPathComponent("dup.mp4"), encoding: .utf8)) == "already here"
                && !exists("a.mp4", old) && !exists(".originals", old)
            print("moved \(moved), skipped \(skipped):", ok ? "ok" : "FAILED")
            try? fm.removeItem(at: root)
            exit(ok ? 0 : 1)
        }
        if args.contains("--meeting-test") {
            // Echo removal, the notes parser, then real notes from the on-device model.
            Prefs.registerDefaults()
            let others: [Meeting.Line] = [
                .init(start: 2, end: 6, speaker: .others, text: "Can you send the launch checklist by Friday?"),
                .init(start: 14, end: 18, speaker: .others, text: "Great, and Priya will book the venue for the 12th."),
            ]
            let you: [Meeting.Line] = [
                .init(start: 2.4, end: 6.3, speaker: .you, text: "can you send the launch checklist by friday"),  // echo
                .init(start: 8, end: 12, speaker: .you, text: "Yes, I'll send it Thursday and copy Sam."),
            ]
            let merged = MeetingController.merge(you: you, others: others)
            print("merge:", merged.map { "\($0.speaker.label): \($0.text)" }, merged.count == 3 ? "ok" : "FAILED")
            let parsed = Polisher.parseMeetingNotes("TITLE: Launch prep\nSUMMARY: Agreed dates.\nACTIONS:\n- Send checklist (You, Thursday)\n- Book venue (Priya)")
            print("parse:", parsed.map { "\($0.title) | \($0.actions)" } ?? "nil", parsed?.actions.count == 2 ? "ok" : "FAILED")
            Task {
                let t0 = Date()
                let notes = await Polisher.shared.meetingNotes(for: merged)
                print(String(format: "notes (%.1fs):", Date().timeIntervalSince(t0)), notes.map { "\($0.title) | \($0.summary) | \($0.actions)" } ?? "no model")
                exit(0)
            }
            RunLoop.main.run()
        }
        if args.contains("--devices") {
            MainActor.assumeIsolated {
                for d in Devices.shared.cameras { print("camera:", d.name, d.isPhone ? "(iPhone)" : "", "uid:", d.id) }
                for d in Devices.shared.microphones {
                    print("mic:", d.name, "coreaudio id:", Devices.audioDeviceID(forUID: d.id).map(String.init) ?? "nil")
                }
            }
            for k in KeyboardInfo.connected() { print("keyboard:", k.name, k.isVirtual ? "(virtual/Karabiner)" : k.isApple ? "(Apple)" : "(Windows-style)") }
            exit(0)
        }
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        Prefs.registerDefaults()
        Task {
            do {
                let t0 = Date()
                try await SpeechEngine.shared.prepare { print("speech:", $0) }
                let segs = try await SpeechEngine.shared.transcribe(file: url)
                let raw = segs.map(\.text).joined(separator: " ")
                print("raw (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s):", raw)
                print("model available:", Polisher.shared.modelAvailable)
                let t1 = Date()
                let cleaned = await Polisher.shared.clean(raw, app: "Slack")
                print("cleaned (\(String(format: "%.1f", Date().timeIntervalSince(t1)))s):", cleaned)
                if let cmd = await Polisher.shared.command("make this more formal", selection: raw, app: "Mail") { print("command:", cmd) }
                if let ins = await Polisher.shared.insights(for: segs) { print("title:", ins.title, "| summary:", ins.summary) }
                exit(0)
            } catch {
                print("FAILED:", error); exit(1)
            }
        }
        RunLoop.main.run()
    }
}
