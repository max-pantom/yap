import Foundation
import FoundationModels
import Security

/// A language model backend. Apple Intelligence is always there; one "second model" can be added next to it.
enum LLMProvider: String, CaseIterable, Identifiable {
    case apple, ollama, openai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "None (Apple Intelligence only)"
        case .ollama: "Ollama (local, bigger open models)"
        case .openai: "OpenAI-compatible server"
        }
    }
}

/// The jobs a language model does in Yap. Each can be routed to Apple or the second model.
enum LLMTask: String, CaseIterable, Identifiable {
    case cleanup, command, summary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cleanup: "Dictation cleanup"
        case .command: "Command Mode"
        case .summary: "Recording titles & summaries"
        }
    }
    var hint: String {
        switch self {
        case .cleanup: "Runs on every dictation, so speed matters most"
        case .command: "Rewrites and writing: a bigger model shines here"
        case .summary: "Runs after recordings: quality over speed"
        }
    }
    var defaultsKey: String { "models.task." + rawValue }
}

enum LLM {
    /// The second model next to Apple Intelligence (`.apple` = none configured).
    static var second: LLMProvider {
        LLMProvider(rawValue: UserDefaults.standard.string(forKey: Prefs.Key.llmProvider) ?? "") ?? .apple
    }

    /// Which backend handles `task`: the second model if the task is routed to it and it's set up, else Apple.
    static func provider(for task: LLMTask) -> LLMProvider {
        let wantsSecond = UserDefaults.standard.string(forKey: task.defaultsKey) == "second"
        return wantsSecond && second != .apple && isConfigured(second) ? second : .apple
    }

    static var appleAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static func isConfigured(_ p: LLMProvider) -> Bool {
        switch p {
        case .apple: appleAvailable
        case .ollama: !ollamaModel.isEmpty
        case .openai: !openaiURL.isEmpty && !openaiModel.isEmpty
        }
    }

    /// A task can run if its chosen model is set up, or Apple can step in as the fallback.
    static func isAvailable(for task: LLMTask) -> Bool { isConfigured(provider(for: task)) || appleAvailable }

    static func label(_ p: LLMProvider) -> String {
        switch p {
        case .apple: "Apple Intelligence"
        case .ollama: ollamaModel.isEmpty ? "Ollama (no model picked)" : "Ollama · \(ollamaModel)"
        case .openai: openaiModel.isEmpty ? "Custom server (not set up)" : "\(openaiModel) @ \(URL(string: openaiURL)?.host ?? openaiURL)"
        }
    }

    /// e.g. "Apple Intelligence + Ollama · qwen2.5:7b"
    static var label: String {
        let used = Set(LLMTask.allCases.map { provider(for: $0) })
        return used.count > 1 || used.first != .apple ? "Apple Intelligence + \(label(second))" : "Apple Intelligence"
    }
    static var ollamaURL: String { UserDefaults.standard.string(forKey: Prefs.Key.ollamaURL) ?? "http://localhost:11434" }
    static var ollamaModel: String { UserDefaults.standard.string(forKey: Prefs.Key.ollamaModel) ?? "" }
    static var openaiURL: String { UserDefaults.standard.string(forKey: Prefs.Key.openaiURL) ?? "" }
    static var openaiModel: String { UserDefaults.standard.string(forKey: Prefs.Key.openaiModel) ?? "" }

    /// True when text sent to the second model leaves this Mac.
    static var isRemote: Bool {
        guard second == .openai, let host = URL(string: openaiURL)?.host else { return false }
        return !["localhost", "127.0.0.1", "::1"].contains(host)
    }

    /// One-shot chat completion for the non-Apple providers.
    static func chat(_ provider: LLMProvider, system: String, user: String, timeout: TimeInterval) async throws -> String {
        switch provider {
        case .apple:
            throw YapError("Apple provider is handled by FoundationModels directly.")
        case .ollama:
            let body: [String: Any] = [
                "model": ollamaModel, "stream": false, "keep_alive": "30m",
                "options": ["temperature": 0],
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ]
            let json = try await post("\(ollamaURL)/api/chat", body: body, timeout: timeout)
            guard let msg = json["message"] as? [String: Any], let content = msg["content"] as? String else {
                throw YapError((json["error"] as? String) ?? "Unexpected reply from Ollama")
            }
            return content
        case .openai:
            let base = openaiURL.hasSuffix("/") ? String(openaiURL.dropLast()) : openaiURL
            let body: [String: Any] = [
                "model": openaiModel, "temperature": 0,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ]
            let json = try await post("\(base)/chat/completions", body: body, timeout: timeout,
                                      bearer: Keychain.get("openai-compatible"))
            guard let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any], let content = msg["content"] as? String else {
                let err = (json["error"] as? [String: Any])?["message"] as? String
                throw YapError(err ?? "Unexpected reply from server")
            }
            return content
        }
    }

    /// Loads an Ollama model into memory ahead of time so the first cleanup isn't slow.
    static func prewarm() {
        guard second == .ollama, !ollamaModel.isEmpty,
              LLMTask.allCases.contains(where: { provider(for: $0) == .ollama }) else { return }
        Task { _ = try? await post("\(ollamaURL)/api/generate", body: ["model": ollamaModel, "keep_alive": "30m"], timeout: 60) }
    }

    static func post(_ url: String, body: [String: Any], timeout: TimeInterval, bearer: String? = nil) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw YapError("Invalid URL: \(url)") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer, !bearer.isEmpty { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

// MARK: - Ollama model management

@MainActor
final class OllamaManager: ObservableObject {
    static let shared = OllamaManager()

    struct Model: Identifiable, Hashable { let name: String; let size: Int64; var id: String { name } }

    /// Good picks for cleanup / rewriting, smallest first.
    static let suggestions: [(name: String, size: String, note: String)] = [
        ("llama3.2:3b", "2.0 GB", "Fast, solid cleanup"),
        ("gemma3:4b", "3.3 GB", "Great writing quality for its size"),
        ("qwen2.5:7b", "4.7 GB", "Strong rewriting & Command Mode"),
        ("gemma3:12b", "8.1 GB", "Best quality; needs 16 GB+ RAM"),
    ]

    @Published private(set) var isRunning = false
    @Published private(set) var installed: [Model] = []
    @Published private(set) var pulling: [String: Double] = [:]
    @Published private(set) var message = ""

    func refresh() async {
        guard let url = URL(string: "\(LLM.ollamaURL)/api/tags") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2))
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let models = (json?["models"] as? [[String: Any]]) ?? []
            installed = models.compactMap { m in
                (m["name"] as? String).map { Model(name: $0, size: (m["size"] as? NSNumber)?.int64Value ?? 0) }
            }.sorted { $0.name < $1.name }
            isRunning = true
        } catch {
            isRunning = false
            installed = []
        }
    }

    /// Streams `ollama pull` progress.
    func pull(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, pulling[name] == nil, let url = URL(string: "\(LLM.ollamaURL)/api/pull") else { return }
        pulling[name] = 0
        message = "Downloading \(name)…"
        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "stream": true])
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            for try await line in bytes.lines {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let err = obj["error"] as? String { throw YapError(err) }
                if let total = (obj["total"] as? NSNumber)?.doubleValue, total > 0,
                   let done = (obj["completed"] as? NSNumber)?.doubleValue {
                    pulling[name] = done / total
                }
                if let status = obj["status"] as? String { message = "\(name): \(status)" }
            }
            message = "\(name) is ready"
            if LLM.ollamaModel.isEmpty { UserDefaults.standard.set(name, forKey: Prefs.Key.ollamaModel) }
        } catch {
            message = "Couldn't download \(name): \(error.localizedDescription)"
        }
        pulling[name] = nil
        await refresh()
    }

    func delete(_ name: String) async {
        guard let url = URL(string: "\(LLM.ollamaURL)/api/delete") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        _ = try? await URLSession.shared.data(for: req)
        if LLM.ollamaModel == name { UserDefaults.standard.set("", forKey: Prefs.Key.ollamaModel) }
        await refresh()
    }
}

// MARK: - Keychain (API keys never go in UserDefaults)

enum Keychain {
    private static let service = "app.yap.mac"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
