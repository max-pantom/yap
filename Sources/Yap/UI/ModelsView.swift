import FoundationModels
import SwiftUI

struct ModelsTab: View {
    var body: some View {
        Form {
            SettingsHeader(page: .models, text: "What turns your voice into text, and what cleans it up. All on this Mac unless you add a server.")
            SpeechModelSection(whisper: WhisperEngine.shared)
            LanguageModelSection(ollama: OllamaManager.shared)
            TaskRoutingSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speech recognition

private struct SpeechModelSection: View {
    @ObservedObject var whisper: WhisperEngine
    @Local private var customVariant = ""

    private var selected: String { whisper.selectedVariant ?? "apple" }

    var body: some View {
        Section {
            ModelRow(title: "Apple Speech (built-in)",
                     detail: "Managed by macOS · instant · live preview · \(SpeechEngine.shared.locale.identifier)",
                     isSelected: selected == "apple") {
                Button("Use") { whisper.use(nil) }.disabled(selected == "apple")
            }
            ForEach(WhisperEngine.catalog) { m in whisperRow(variant: m.variant, title: "Whisper \(m.title)", detail: "\(m.size) · \(m.note)") }
            ForEach(whisper.downloaded.keys.filter { v in !WhisperEngine.catalog.contains { $0.variant == v } }.sorted(), id: \.self) { v in
                whisperRow(variant: v, title: "Whisper \(v)", detail: "Custom model")
            }
            HStack {
                TextField("Any WhisperKit model, e.g. openai_whisper-medium", text: $customVariant)
                    .textFieldStyle(.roundedBorder)
                Button("Download") {
                    let v = customVariant.trimmingCharacters(in: .whitespaces)
                    Task { await whisper.download(v) }
                    customVariant = ""
                }
                .disabled(customVariant.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !whisper.status.isEmpty { Text(whisper.status).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Speech recognition")
        } footer: {
            Text("Apple Speech is built in and instant. Whisper models are downloads that can be more accurate; they run on this Mac too, and you still see live words while you talk.")
        }
    }

    private func whisperRow(variant: String, title: String, detail: String) -> some View {
        ModelRow(title: title, detail: detail, isSelected: selected == variant) {
            if let p = whisper.progress[variant] {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).frame(width: 34)
            } else if whisper.downloaded[variant] != nil {
                Button("Use") { whisper.use(variant) }.disabled(selected == variant)
                Button(role: .destructive) { whisper.delete(variant) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete model")
            } else {
                Button("Download") { Task { await whisper.download(variant) } }
            }
        }
    }
}

// MARK: - Language model

private struct LanguageModelSection: View {
    @ObservedObject var ollama: OllamaManager
    @AppStorage(Prefs.Key.llmProvider) var provider = LLMProvider.apple.rawValue
    @AppStorage(Prefs.Key.ollamaURL) var ollamaURL = "http://localhost:11434"
    @AppStorage(Prefs.Key.ollamaModel) var ollamaModel = ""
    @AppStorage(Prefs.Key.openaiURL) var openaiURL = ""
    @AppStorage(Prefs.Key.openaiModel) var openaiModel = ""
    @Local private var apiKey = Keychain.get("openai-compatible") ?? ""
    @Local private var customPull = ""
    @Local private var testResult = ""
    @Local private var testing = false

    var body: some View {
        Section {
            appleBody
        } header: {
            Text("Built-in AI · Apple Intelligence")
        }
        Section {
            Picker("Extra model", selection: $provider) {
                ForEach(LLMProvider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: provider) { _, _ in testResult = ""; Task { await ollama.refresh() } }

            switch LLMProvider(rawValue: provider) ?? .apple {
            case .apple:
                Text("Optional. Add a bigger model (free with Ollama, or any OpenAI-compatible server), then choose below which jobs it does.")
                    .font(.caption).foregroundStyle(.secondary)
            case .ollama: ollamaBody
            case .openai: openaiBody
            }

            HStack {
                Button(testing ? "Testing…" : "Test with a sample") {
                    testing = true
                    Task {
                        let (out, secs) = await Polisher.shared.test()
                        testResult = "\(String(format: "%.1f", secs))s → \(out)"
                        testing = false
                    }
                }
                .disabled(testing)
                Spacer()
            }
            if !testResult.isEmpty { Text(testResult).font(.callout).textSelection(.enabled) }
        } header: {
            Text("Extra AI model")
        }
        .task { await ollama.refresh() }
    }

    @ViewBuilder private var appleBody: some View {
        let available = SystemLanguageModel.default.isAvailable
        LabeledContent("Status", value: available ? "Ready · ~3B parameters, on-device, instant" : "Unavailable: turn on Apple Intelligence in System Settings")
        Text("Built into macOS and always on. If the extra model is slow or offline, Apple takes over automatically.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var ollamaBody: some View {
        if !ollama.isRunning {
            HStack {
                Text("Ollama isn't running. It's a free app that downloads and runs open models locally.")
                    .font(.callout)
                Button("Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                Button("Retry") { Task { await ollama.refresh() } }
            }
        } else {
            Picker("Use", selection: $ollamaModel) {
                Text("Choose…").tag("")
                ForEach(ollama.installed) { m in
                    Text("\(m.name)  (\(ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file)))").tag(m.name)
                }
            }
            .onChange(of: ollamaModel) { _, _ in LLM.prewarm() }
            ForEach(OllamaManager.suggestions, id: \.name) { s in
                if !ollama.installed.contains(where: { $0.name == s.name }) {
                    ModelRow(title: s.name, detail: "\(s.size) · \(s.note)", isSelected: false) {
                        if let p = ollama.pulling[s.name] {
                            ProgressView(value: p).frame(width: 90)
                            Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).frame(width: 34)
                        } else {
                            Button("Download") { Task { await ollama.pull(s.name) } }
                        }
                    }
                }
            }
            HStack {
                TextField("Any model from ollama.com/library, e.g. qwen3:14b", text: $customPull)
                    .textFieldStyle(.roundedBorder)
                Button("Download") {
                    let name = customPull
                    customPull = ""
                    Task { await ollama.pull(name) }
                }
                .disabled(customPull.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let m = ollama.installed.first(where: { $0.name == ollamaModel }) {
                Button("Delete \(m.name)", role: .destructive) { Task { await ollama.delete(m.name) } }
                    .buttonStyle(.borderless)
            }
            if !ollama.message.isEmpty { Text(ollama.message).font(.caption).foregroundStyle(.secondary) }
        }
        TextField("Server", text: $ollamaURL).textFieldStyle(.roundedBorder)
            .onSubmit { Task { await ollama.refresh() } }
    }

    @ViewBuilder private var openaiBody: some View {
        TextField("Base URL (e.g. http://localhost:1234/v1 for LM Studio)", text: $openaiURL).textFieldStyle(.roundedBorder)
        TextField("Model name", text: $openaiModel).textFieldStyle(.roundedBorder)
        SecureField("API key (stored in Keychain; optional for local servers)", text: $apiKey)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Keychain.set(apiKey, account: "openai-compatible") }
            .onChange(of: apiKey) { _, v in Keychain.set(v, account: "openai-compatible") }
        if LLM.isRemote {
            Label("Your dictated text is sent to \(URL(string: openaiURL)?.host ?? "this server"). Everything else stays on this Mac.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Text("Works with LM Studio, llama.cpp server, vLLM, Groq, OpenRouter, or anything that speaks the OpenAI chat API.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Choose, per job, whether Apple Intelligence or the second model does it.
private struct TaskRoutingSection: View {
    @AppStorage(Prefs.Key.llmProvider) var second = LLMProvider.apple.rawValue
    @AppStorage("models.task.cleanup") var cleanup = "apple"
    @AppStorage("models.task.command") var command = "apple"
    @AppStorage("models.task.summary") var summary = "apple"

    var body: some View {
        let hasSecond = (LLMProvider(rawValue: second) ?? .apple) != .apple
        Section {
            row(.cleanup, $cleanup, hasSecond)
            row(.command, $command, hasSecond)
            row(.summary, $summary, hasSecond)
            if hasSecond {
                Button("Suggested: Apple for clean-up, extra model for the rest") {
                    cleanup = "apple"; command = "second"; summary = "second"
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("Which model does what")
        } footer: {
            Text(hasSecond ? "If the second model fails or takes too long, Apple Intelligence finishes the job automatically."
                           : "Add a second model above to split jobs between two models.")
        }
    }

    private func row(_ task: LLMTask, _ choice: Binding<String>, _ hasSecond: Bool) -> some View {
        Picker(selection: choice) {
            Text("Apple Intelligence").tag("apple")
            Text(hasSecond ? LLM.label(LLM.second) : "Second model (not set up)").tag("second")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                Text(task.hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!hasSecond)
    }
}

private struct ModelRow<Trailing: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}
