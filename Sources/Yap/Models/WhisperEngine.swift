import Foundation
@preconcurrency import WhisperKit

struct WhisperModelInfo: Identifiable, Hashable {
    let variant: String     // folder name in huggingface.co/argmaxinc/whisperkit-coreml
    let title: String
    let size: String
    let note: String
    var id: String { variant }
}

/// Optional on-device Whisper (via WhisperKit / Core ML). Models download into Application Support on demand.
/// Apple's live transcriber still drives the on-screen preview; Whisper produces the final text.
@MainActor
final class WhisperEngine: ObservableObject {
    static let shared = WhisperEngine()

    static let catalog: [WhisperModelInfo] = [
        .init(variant: "openai_whisper-tiny.en", title: "Tiny (English)", size: "~75 MB", note: "Fastest, least accurate"),
        .init(variant: "openai_whisper-base.en", title: "Base (English)", size: "~145 MB", note: "Fast"),
        .init(variant: "openai_whisper-small.en_217MB", title: "Small (English)", size: "~217 MB", note: "Good balance"),
        .init(variant: "distil-whisper_distil-large-v3_turbo_600MB", title: "Distil Large v3 Turbo (English)", size: "~600 MB", note: "Near-large accuracy, very fast"),
        .init(variant: "openai_whisper-large-v3-v20240930_turbo_632MB", title: "Large v3 Turbo (99 languages)", size: "~632 MB", note: "Recommended"),
        .init(variant: "openai_whisper-large-v3-v20240930", title: "Large v3 (99 languages)", size: "~1.6 GB", note: "Most accurate, slowest"),
    ]

    @Published private(set) var downloaded: [String: String] = [:]   // variant → folder path
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var status = ""
    @Published private(set) var loadedVariant: String?

    /// WhisperKit isn't marked Sendable; it's only ever driven from this main-actor engine, one call at a time.
    private final class Loaded: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    private var kit: Loaded?
    private var loading: Task<Loaded, Error>?
    private let storeKey = "whisper.downloaded"

    var downloadBase: URL { Prefs.supportFolder.appendingPathComponent("Models", isDirectory: true) }

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        downloaded = saved.filter { FileManager.default.fileExists(atPath: $0.value) }
    }

    /// The Whisper variant chosen in Settings, if the speech engine is set to Whisper.
    var selectedVariant: String? {
        let s = UserDefaults.standard.string(forKey: Prefs.Key.speechEngine) ?? "apple"
        return s.hasPrefix("whisper:") ? String(s.dropFirst("whisper:".count)) : nil
    }

    /// True when Whisper is selected and its model is on disk.
    var isActive: Bool { selectedVariant.map { downloaded[$0] != nil } ?? false }

    static func title(for variant: String) -> String { catalog.first { $0.variant == variant }?.title ?? variant }

    // MARK: Model files

    func download(_ variant: String) async {
        guard progress[variant] == nil else { return }
        progress[variant] = 0
        status = "Downloading \(Self.title(for: variant))…"
        do {
            let folder = try await WhisperKit.download(variant: variant, downloadBase: downloadBase) { p in
                Task { @MainActor in WhisperEngine.shared.progress[variant] = p.fractionCompleted }
            }
            downloaded[variant] = folder.path
            UserDefaults.standard.set(downloaded, forKey: storeKey)
            status = "Downloaded \(Self.title(for: variant))"
            Log.write("whisper downloaded \(variant) → \(folder.path)")
        } catch {
            status = "Download failed: \(error.localizedDescription)"
            Log.write("whisper download failed \(variant): \(error)")
        }
        progress[variant] = nil
    }

    func delete(_ variant: String) {
        if let path = downloaded[variant] { try? FileManager.default.removeItem(atPath: path) }
        downloaded[variant] = nil
        UserDefaults.standard.set(downloaded, forKey: storeKey)
        if selectedVariant == variant { use(nil) }
    }

    /// Switch the speech engine. `nil` = Apple's built-in transcriber.
    func use(_ variant: String?) {
        UserDefaults.standard.set(variant.map { "whisper:" + $0 } ?? "apple", forKey: Prefs.Key.speechEngine)
        kit = nil
        loadedVariant = nil
        loading = nil
        if variant != nil { Task { _ = try? await ensureLoaded() } }
        objectWillChange.send()
    }

    // MARK: Inference

    @discardableResult
    func ensureLoaded() async throws -> WhisperKit { try await loadModel().kit }

    private func loadModel() async throws -> Loaded {
        guard let variant = selectedVariant, let folder = downloaded[variant] else {
            throw YapError("No Whisper model downloaded.")
        }
        if let kit, loadedVariant == variant { return kit }
        if let loading { return try await loading.value }
        status = "Loading \(Self.title(for: variant))…"
        let base = downloadBase
        let task = Task { () throws -> Loaded in
            let config = WhisperKitConfig(model: variant, downloadBase: base, modelFolder: folder,
                                          verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
            return Loaded(try await WhisperKit(config))
        }
        loading = task
        do {
            let k = try await task.value
            kit = k
            loadedVariant = variant
            status = "\(Self.title(for: variant)) ready"
            loading = nil
            return k
        } catch {
            loading = nil
            status = "Couldn't load Whisper: \(error.localizedDescription)"
            throw error
        }
    }

    private var language: String? {
        guard let v = selectedVariant, !v.contains(".en") else { return "en" }
        return SpeechEngine.shared.locale.language.languageCode?.identifier
    }

    /// 16 kHz mono samples → text.
    func transcribe(samples: [Float]) async throws -> String {
        let k = try await ensureLoaded()
        let options = DecodingOptions(language: language, skipSpecialTokens: true, withoutTimestamps: true, chunkingStrategy: .vad)
        let results = try await k.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Audio file → timestamped phrases (for recording transcripts and captions).
    func transcribe(file path: String) async throws -> [SpeechEngine.Segment] {
        let k = try await ensureLoaded()
        let options = DecodingOptions(language: language, skipSpecialTokens: true, chunkingStrategy: .vad)
        let results = try await k.transcribe(audioPath: path, decodeOptions: options)
        return results.flatMap(\.segments).compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : SpeechEngine.Segment(start: Double(seg.start), end: Double(seg.end), text: text)
        }
    }
}
