import Foundation

/// Spoken commands that act on the text instead of being typed:
/// "scratch that" drops the sentence before it (on its own, it removes your last dictation),
/// ending with "send it" / "press enter" presses Return after pasting, and "…translate to French"
/// (or starting with "Translate to French:") pastes the translation instead.
enum VoiceCommands {
    struct Parsed: Equatable {
        var text: String
        var pressReturn = false
        var undoLast = false
        /// A language name ("French") when the dictation asked to be translated.
        var translateTo: String?
    }

    /// Languages people can name, spoken form → the name given to the model.
    static let languages: [String: String] = {
        var m: [String: String] = [:]
        for name in ["English", "French", "Spanish", "German", "Italian", "Portuguese", "Dutch", "Swedish", "Norwegian",
                     "Danish", "Finnish", "Polish", "Czech", "Greek", "Turkish", "Russian", "Ukrainian", "Arabic", "Hebrew",
                     "Hindi", "Bengali", "Urdu", "Chinese", "Japanese", "Korean", "Vietnamese", "Thai", "Indonesian",
                     "Malay", "Swahili", "Yoruba", "Igbo", "Hausa", "Amharic", "Zulu", "Afrikaans", "Romanian", "Hungarian"] {
            m[name.lowercased()] = name
        }
        m["mandarin"] = "Chinese (Mandarin, simplified)"; m["cantonese"] = "Cantonese"
        m["pidgin"] = "Nigerian Pidgin"; m["nigerian pidgin"] = "Nigerian Pidgin"
        m["brazilian portuguese"] = "Brazilian Portuguese"; m["spanish"] = "Spanish"
        return m
    }()
    private static let languagePattern = languages.keys.sorted { $0.count > $1.count }
        .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    private static let translateTail = try! NSRegularExpression(
        pattern: "[,;]?\\s*\\b(?:and\\s+)?(?:please\\s+)?translate(?:\\s+(?:it|this|that|everything|all of that|all of this))?\\s+(?:in)?to\\s+(\(languagePattern))\\b[\\s.,!?]*$",
        options: [.caseInsensitive])
    private static let translateHead = try! NSRegularExpression(
        pattern: "^\\s*(?:please\\s+)?translate(?:\\s+(?:this|that|it))?\\s+(?:in)?to\\s+(\(languagePattern))\\b[\\s:,.]*",
        options: [.caseInsensitive])

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.Key.voiceCommands) }

    private static let undoPhrases: Set<String> = ["scratch that", "undo that", "delete that", "scratch that please"]
    private static let sendPattern = try! NSRegularExpression(
        pattern: "[,;]?\\s*\\b(?:and\\s+)?(?:send it|send that|send|press enter|press return|hit enter|hit return)\\b[\\s.,!?]*$",
        options: [.caseInsensitive])
    private static let scratchPattern = try! NSRegularExpression(pattern: "\\b(?:scratch that|strike that)\\b[\\s,.!?]*", options: [.caseInsensitive])

    static func parse(_ raw: String) -> Parsed {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if undoPhrases.contains(Prefs.normalizeForMatch(text)) { return Parsed(text: "", undoLast: true) }

        var pressReturn = false
        // "send" alone at the end is too common in normal speech ("…and I'll send"), so it needs "send it/that"
        // unless it's the whole utterance.
        if let m = sendPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range, in: text) {
            let phrase = Prefs.normalizeForMatch(String(text[r]))
            let bareSend = phrase == "send" || phrase == "and send"
            if !bareSend || r.lowerBound == text.startIndex {
                pressReturn = true
                text = String(text[..<r.lowerBound])
            }
        }

        // "…translate to French" at the end, or "Translate to French: …" at the start.
        var translateTo: String?
        for pattern in [translateTail, translateHead] where Prefs.translateOn {
            if let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range, in: text), let lr = Range(m.range(at: 1), in: text) {
                translateTo = languages[text[lr].lowercased()]
                text.removeSubrange(r)
                break
            }
        }

        // Each "scratch that" removes the sentence (or clause run) right before it.
        while let m = scratchPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) {
            var before = String(text[..<r.lowerBound])
            before = before.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;")))
            if before.last.map({ ".!?".contains($0) }) == true { before.removeLast() }
            let cut = before.lastIndex(where: { ".!?\n".contains($0) }).map { before.index(after: $0) } ?? before.startIndex
            let kept = String(before[..<cut])
            let after = String(text[r.upperBound...])
            text = kept.isEmpty ? after : kept.trimmingCharacters(in: .whitespaces) + " " + after
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first.isLowercase, raw.first?.isUppercase == true { text = first.uppercased() + text.dropFirst() }
        return Parsed(text: text, pressReturn: pressReturn, translateTo: translateTo)
    }
}
