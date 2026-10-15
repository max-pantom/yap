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
