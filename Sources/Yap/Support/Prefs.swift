import Foundation

/// All user settings live in UserDefaults so SwiftUI views can bind with @AppStorage
/// and controllers can read the same keys directly.
enum Prefs {
    enum Key {
        static let cleanupStyle = "dictation.style"         // CleanupStyle raw value
        static let locale = "dictation.locale"              // "" = system
        static let sounds = "general.sounds"
        static let dictionary = "dictation.dictionary"      // one entry per line: "word" or "heard => written"
        static let snippets = "dictation.snippets"          // "trigger => expansion" per line
        static let recCamera = "rec.camera"
        static let recMic = "rec.mic"
        static let recSystemAudio = "rec.systemAudio"
        static let recClicks = "rec.clicks"
        static let recCodec = "rec.codec"                   // "h264" | "hevc"
        static let recFPS = "rec.fps"
        static let recCountdown = "rec.countdown"
        static let recAutoCopy = "rec.autoCopy"
        static let recFolder = "rec.folder"
        static let bubbleSize = "rec.bubbleSize"
        static let onboarded = "general.onboarded"
        static let showFlowBar = "general.showFlowBar"
        static let startupAnimation = "general.startupAnimation"
        static let keepOnClipboard = "dictation.keepOnClipboard"
        static let flowBarX = "flowbar.x"   // fraction of screen width (pill centre)
        static let flowBarY = "flowbar.y"   // fraction of screen height (bottom edge)
        static let speechEngine = "models.speech"            // "apple" | "whisper:<variant>"
        static let llmProvider = "models.llm"                // LLMProvider raw value
        static let ollamaURL = "models.ollamaURL"
        static let ollamaModel = "models.ollamaModel"
        static let openaiURL = "models.openaiURL"
        static let openaiModel = "models.openaiModel"
        static let cameraID = "device.camera"             // "" = automatic
        static let micID = "device.mic"                   // "" = system default
        static let learnCorrections = "dictation.learnCorrections"
        static let voiceCommands = "dictation.voiceCommands"
        static let translateTo = "dictation.translateTo"    // "" = off, else a language name ("French")
        static let fitToCursor = "dictation.fitToCursor"    // match spacing/capitals to the text around the cursor
        static let showKeystrokes = "rec.showKeystrokes"
        static let urlCommands = "general.urlCommands"      // allow yap:// links (Shortcuts, Raycast…)
        static let autoZoom = "rec.autoZoom"
        static let zoomLevel = "rec.zoomLevel"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.cleanupStyle: CleanupStyle.polished.rawValue,
            Key.locale: "",
            Key.sounds: true,
            Key.dictionary: "",
            Key.snippets: "",
            Key.recCamera: true,
            Key.recMic: true,
            Key.recSystemAudio: false,
            Key.recClicks: true,
            Key.recCodec: "h264",
            Key.recFPS: 30,
            Key.recCountdown: true,
            Key.recAutoCopy: true,
            Key.recFolder: "",
            Key.bubbleSize: 220.0,
            Key.onboarded: false,
            Key.showFlowBar: true,
            Key.startupAnimation: true,
            Key.keepOnClipboard: true,
            Key.speechEngine: "apple",
            Key.llmProvider: "apple",
            Key.ollamaURL: "http://localhost:11434",
            Key.ollamaModel: "",
            Key.openaiURL: "",
            Key.openaiModel: "",
            Key.cameraID: "",
            Key.micID: "",
            Key.learnCorrections: true,
            Key.voiceCommands: true,
            Key.translateTo: "",
            Key.fitToCursor: true,
            Key.showKeystrokes: true,
            Key.urlCommands: true,
            Key.autoZoom: true,
            Key.zoomLevel: 1.8,
        ])
    }

    static var d: UserDefaults { .standard }
    static var style: CleanupStyle { CleanupStyle(rawValue: d.string(forKey: Key.cleanupStyle) ?? "") ?? .polished }
    static var sounds: Bool { d.bool(forKey: Key.sounds) }

    static var recordingsFolder: URL {
        if let p = d.string(forKey: Key.recFolder), !p.isEmpty { return URL(fileURLWithPath: p) }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("Yap", isDirectory: true)
    }

    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Yap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Parses "heard => written" lines. Bare words become vocabulary hints only.
    static var dictionary: (replacements: [(String, String)], vocabulary: [String]) {
        var reps: [(String, String)] = []
        var vocab: [String] = []
        for line in (d.string(forKey: Key.dictionary) ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                reps.append((parts[0], parts[1])); vocab.append(parts[1])
            } else if let w = parts.first, !w.isEmpty {
                vocab.append(w)
            }
        }
        return (reps, vocab)
    }

    /// Fills {date}, {time}, {day}, {year} and {clipboard} in a snippet.
    static func expandVariables(_ s: String, now: Date = Date(), clipboard: String? = nil) -> String {
        guard s.contains("{") else { return s }
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .none
        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
        let day = DateFormatter(); day.setLocalizedDateFormatFromTemplate("EEEE")
        let year = Calendar.current.component(.year, from: now)
        return s.replacingOccurrences(of: "{date}", with: df.string(from: now))
            .replacingOccurrences(of: "{time}", with: tf.string(from: now))
            .replacingOccurrences(of: "{day}", with: day.string(from: now))
            .replacingOccurrences(of: "{year}", with: String(year))
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
    }

    static var snippets: [String: String] {
        var out: [String: String] = [:]
        for line in (d.string(forKey: Key.snippets) ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count >= 2 else { continue }
            let key = normalizeForMatch(parts[0])
            let value = parts.dropFirst().joined(separator: "=>").trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n")
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    static func normalizeForMatch(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum CleanupStyle: String, CaseIterable, Identifiable {
    case verbatim, polished, casual, formal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .verbatim: "Verbatim"
        case .polished: "Polished"
        case .casual: "Casual"
        case .formal: "Formal"
        }
    }
    /// One line on what the style does, shown under the picker.
    var detail: String {
        switch self {
        case .verbatim: "Exactly what you said, with basic punctuation. No AI."
        case .polished: "Removes ums and false starts, fixes punctuation. Keeps your words."
        case .casual: "Relaxed, like a chat message."
        case .formal: "Complete sentences in a professional tone."
        }
    }
}
