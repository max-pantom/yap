import AVFoundation
import Speech

/// On-device speech-to-text using SpeechAnalyzer (macOS 26+). No audio leaves the Mac.
final class SpeechEngine: @unchecked Sendable {
    static let shared = SpeechEngine()

    private(set) var locale = Locale(identifier: "en_US")
    private(set) var analyzerFormat: AVAudioFormat?
    private(set) var isReady = false

    /// Resolves the locale and downloads the on-device model if needed. Safe to call repeatedly.
    func prepare(progress: (@Sendable (String) -> Void)? = nil) async throws {
        // "auto" is for Whisper, which detects the language each time; Apple Speech then uses the Mac's language.
        let wanted = UserDefaults.standard.string(forKey: Prefs.Key.locale).flatMap { $0.isEmpty || $0 == Self.autoLanguage ? nil : Locale(identifier: $0) } ?? Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            locale = match
        } else {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) ?? Locale(identifier: "en_US")
        }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            progress?("Downloading speech model for \(locale.identifier)…")
            try await request.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        isReady = analyzerFormat != nil
        progress?("Ready")
    }

    static func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }

    /// The language setting that means "detect it" (Whisper models only).
    static let autoLanguage = "auto"
    static var detectsLanguage: Bool { UserDefaults.standard.string(forKey: Prefs.Key.locale) == autoLanguage }

    // MARK: Live sessions

    final class LiveSession: @unchecked Sendable {
        let input: AsyncStream<AnalyzerInput>.Continuation
        private let analyzer: SpeechAnalyzer
        private let startTask: Task<Void, Error>
        private let resultsTask: Task<String, Error>

        init(locale: Locale, format: AVAudioFormat, onText: @escaping @Sendable (String) -> Void) {
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let analyzer = SpeechAnalyzer(modules: [module])
            self.input = cont
            self.analyzer = analyzer
            resultsTask = Task {
                var finalText = ""
                for try await result in module.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        finalText = SpeechEngine.join(finalText, piece)
                        onText(finalText)
                    } else {
                        onText(SpeechEngine.join(finalText, piece))
                    }
                }
                return finalText
            }
            // Audio buffers queue up in the stream while the analyzer spins up, so no words are lost.
            startTask = Task {
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
            }
        }

        func feed(_ buffer: AVAudioPCMBuffer) { input.yield(AnalyzerInput(buffer: buffer)) }

        func finish() async throws -> String {
            input.finish()
            try await startTask.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await resultsTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func cancel() {
            input.finish()
            resultsTask.cancel()
            Task { [analyzer] in await analyzer.cancelAndFinishNow() }
        }
    }

    func startLive(onText: @escaping @Sendable (String) -> Void) throws -> LiveSession {
        guard let format = analyzerFormat else { throw YapError("Speech model isn't ready yet.") }
        return LiveSession(locale: locale, format: format, onText: onText)
    }

    // MARK: Files

    struct Segment: Codable, Hashable {
        var start: Double
        var end: Double
        var text: String
    }

    /// Transcribes an audio file into timestamped phrases.
    func transcribe(file url: URL) async throws -> [Segment] {
        if !isReady { try await prepare() }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () -> [Segment] in
            var out: [Segment] = []
            for try await r in module.results where r.isFinal {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(Segment(start: r.range.start.seconds, end: r.range.end.seconds, text: text))
            }
            return out
        }
        let file = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value
    }

    static func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

struct YapError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
