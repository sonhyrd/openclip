// AIConfigureForm.swift
// OpenClip
//
// Reusable AI engine + provider configuration form, shared by the AI preferences
// tab and the first-launch onboarding flow so both surfaces expose the same settings.
import SwiftUI
import Core

@MainActor
public struct AIConfigureForm: View {
    @ObservedObject private var aiManager = AIServiceManager.shared

    @State private var fetchedCloudModels: [String] = []
    @State private var isFetchingCloudModels: Bool = false
    @State private var cloudFetchError: String? = nil
    @State private var cloudFetchGeneration: Int = 0

    @State private var fetchedOllamaModels: [String] = []
    @State private var isFetchingOllamaModels: Bool = false
    @State private var ollamaFetchError: String? = nil
    @State private var ollamaFetchGeneration: Int = 0

    @State private var isRedetectingClaudeCLI: Bool = false

    @State private var isRedetectingCodexCLI: Bool = false
    @State private var isFetchingCodexModels: Bool = false
    @State private var codexFetchError: String? = nil

    public init() {}

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active AI Engine")
                        .font(.headline)
                    Text("Select which provider powers AI features when invoked.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 4)

                Picker("", selection: $aiManager.activeProviderRaw) {
                    Text("Apple").tag(AIProviderType.apple.rawValue)
                    Text("Ollama").tag(AIProviderType.ollama.rawValue)
                    Text("Cloud API").tag(AIProviderType.cloud.rawValue)
                    Text("Browser").tag(AIProviderType.browser.rawValue)
                    Text("Claude CLI").tag(AIProviderType.claudeCLI.rawValue)
                    Text("Codex CLI").tag(AIProviderType.codexCLI.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section(header: Text("Provider Settings")) {
                if aiManager.activeProviderType == .apple {
                    HStack(spacing: 8) {
                        Image(systemName: "applelogo")
                            .font(.system(size: 14, weight: .medium))
                        Text("Apple Intelligence (On-Device)")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.vertical, 4)
                } else if aiManager.activeProviderType == .cloud {
                    Picker("Service Provider", selection: $aiManager.cloudServiceProvider) {
                        ForEach(CloudServiceProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    if aiManager.cloudServiceProvider == .custom {
                        TextField("Base Endpoint URL", text: $aiManager.cloudCustomURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    SecureField("API Key", text: $aiManager.cloudAPIKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        let defaultModels = aiManager.cloudServiceProvider.defaultModels
                        let combinedModels = Array(Set(defaultModels + fetchedCloudModels + [aiManager.cloudModel])).sorted()

                        Picker("Model", selection: $aiManager.cloudModel) {
                            ForEach(combinedModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }

                        Button(action: fetchModels) {
                            if isFetchingCloudModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Fetch available models live from API")
                        .disabled(aiManager.cloudAPIKey.isEmpty || isFetchingCloudModels)
                    }

                    if let cloudFetchError {
                        Text("Query failed: \(cloudFetchError)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } else if aiManager.activeProviderType == .ollama {
                    TextField("Server Endpoint", text: $aiManager.ollamaURL, prompt: Text("http://localhost:11434"))
                    HStack(spacing: 8) {
                        let defaultOllamaModels = ["llama3", "llama3.1", "mistral", "qwen2.5", "deepseek-r1"]
                        let combinedOllamaModels = Array(Set(defaultOllamaModels + fetchedOllamaModels + [aiManager.ollamaModel])).sorted()

                        Picker("Model Name", selection: $aiManager.ollamaModel) {
                            ForEach(combinedOllamaModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }

                        Button(action: fetchOllamaModels) {
                            if isFetchingOllamaModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Fetch installed models from local Ollama instance")
                        .disabled(isFetchingOllamaModels)
                    }

                    if let ollamaFetchError {
                        Text("Query failed: \(ollamaFetchError)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } else if aiManager.activeProviderType == .claudeCLI {
                    // Display names in the picker, the wire id as a caption: the human reads
                    // "Sonnet 4.5", and what actually goes over `--model` stays visible beside it
                    // (ADR 0001 §4, as amended). A stored id that is not in the table is folded in
                    // raw, the way the cloud picker keeps its stored value, so it is never snapped
                    // to the default behind the user's back.
                    VStack(alignment: .leading, spacing: 2) {
                        let wireIDs = ClaudeCLI.models.map(\.wireID)
                        let choices = wireIDs.contains(aiManager.claudeCLIModel)
                            ? wireIDs
                            : wireIDs + [aiManager.claudeCLIModel]
                        Picker("Model", selection: $aiManager.claudeCLIModel) {
                            ForEach(choices, id: \.self) { wireID in
                                Text(verbatim: ClaudeCLI.displayName(for: wireID)).tag(wireID)
                            }
                        }
                        Text(verbatim: aiManager.claudeCLIModel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Command Line Tool")
                            Text(aiManager.claudeResolutionDetail.isEmpty
                                 ? String(localized: "Not detected yet.")
                                 : aiManager.claudeResolutionDetail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: redetectClaudeCLI) {
                            if isRedetectingClaudeCLI {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Re-detect the Claude Code CLI installation")
                        .disabled(isRedetectingClaudeCLI)
                    }
                    // Resolution is lazy, so without this the user would sit on a fourth state
                    // ("Not detected yet.") until they pressed Re-detect or ran a transform. Only
                    // when this branch is on screen — never at app launch.
                    .task {
                        guard aiManager.claudeResolutionDetail.isEmpty else { return }
                        try? await aiManager.resolvedClaudeBinaryPath()
                    }
                } else if aiManager.activeProviderType == .codexCLI {
                    // Mirrors the Claude row: display name in the picker, the slug as a caption.
                    // The picker is fed by what the installed codex lists (`codex debug models`),
                    // never a literal in the app; before it loads, or when it fails, the stored
                    // slug is folded in raw so the choice is never snapped behind the user's back.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            let wireIDs = aiManager.codexModels.map(\.wireID)
                            let choices = wireIDs.contains(aiManager.codexModel)
                                ? wireIDs
                                : wireIDs + [aiManager.codexModel]
                            Picker("Model", selection: $aiManager.codexModel) {
                                ForEach(choices, id: \.self) { wireID in
                                    Text(verbatim: CodexCLI.displayName(for: wireID, in: aiManager.codexModels)).tag(wireID)
                                }
                            }

                            Button(action: fetchCodexModels) {
                                if isFetchingCodexModels {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                            }
                            .buttonStyle(.borderless)
                            .help("Fetch the models the installed Codex CLI lists")
                            .disabled(isFetchingCodexModels)
                        }
                        Text(verbatim: aiManager.codexModel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    if let codexFetchError {
                        Text("Query failed: \(codexFetchError)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Command Line Tool")
                            Text(aiManager.codexResolutionDetail.isEmpty
                                 ? String(localized: "Not detected yet.")
                                 : aiManager.codexResolutionDetail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: redetectCodexCLI) {
                            if isRedetectingCodexCLI {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Re-detect the Codex CLI installation")
                        .disabled(isRedetectingCodexCLI)
                    }
                    // Lazy, like the Claude row: resolve the binary and list the catalog only when
                    // this branch is on screen, never at app launch, and only once per launch.
                    .task {
                        if aiManager.codexResolutionDetail.isEmpty {
                            try? await aiManager.resolvedCodexBinaryPath()
                        }
                        if aiManager.codexModels.isEmpty, !isFetchingCodexModels {
                            fetchCodexModels()
                        }
                    }
                } else if aiManager.activeProviderType == .browser {
                    Picker("Default Chatbot", selection: $aiManager.browserPreset) {
                        Text("ChatGPT (OpenAI)").tag("chatgpt")
                        Text("Claude (Anthropic)").tag("claude")
                        Text("Perplexity AI").tag("perplexity")
                        Text("Google Gemini").tag("gemini")
                        Text("DeepSeek").tag("deepseek")
                        Text("Custom URL...").tag("custom")
                    }

                    if aiManager.browserPreset == "custom" {
                        TextField("Custom Web URL", text: $aiManager.browserURLTemplate, prompt: Text("https://custom-ai.com/?q={text}"))
                        Text("Use **{text}** as a placeholder for the prompt and selection.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(!aiManager.isAIEnabled)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func fetchModels() {
        cloudFetchGeneration += 1
        let currentGeneration = cloudFetchGeneration
        let targetProvider = aiManager.cloudServiceProvider
        let targetCustomURL = aiManager.cloudCustomURL
        let targetAPIKey = aiManager.cloudAPIKey

        isFetchingCloudModels = true
        cloudFetchError = nil
        Task {
            do {
                let models = try await CloudAPIProvider.fetchAvailableModels(
                    apiKey: targetAPIKey,
                    provider: targetProvider,
                    customBaseURL: targetCustomURL
                )
                await MainActor.run {
                    guard currentGeneration == self.cloudFetchGeneration,
                          aiManager.cloudServiceProvider == targetProvider,
                          aiManager.cloudCustomURL == targetCustomURL,
                          aiManager.cloudAPIKey == targetAPIKey else {
                        return
                    }
                    self.fetchedCloudModels = models
                    self.isFetchingCloudModels = false
                    if let first = models.first, !models.contains(aiManager.cloudModel) {
                        aiManager.cloudModel = first
                    }
                }
            } catch {
                await MainActor.run {
                    guard currentGeneration == self.cloudFetchGeneration,
                          aiManager.cloudServiceProvider == targetProvider,
                          aiManager.cloudCustomURL == targetCustomURL,
                          aiManager.cloudAPIKey == targetAPIKey else {
                        return
                    }
                    self.cloudFetchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isFetchingCloudModels = false
                }
            }
        }
    }

    private func fetchOllamaModels() {
        ollamaFetchGeneration += 1
        let currentGeneration = ollamaFetchGeneration
        let targetURL = aiManager.ollamaURL

        isFetchingOllamaModels = true
        ollamaFetchError = nil
        Task {
            do {
                let models = try await OllamaProvider.fetchAvailableModels(baseURL: targetURL)
                await MainActor.run {
                    guard currentGeneration == self.ollamaFetchGeneration,
                          aiManager.ollamaURL == targetURL else {
                        return
                    }
                    self.fetchedOllamaModels = models
                    self.isFetchingOllamaModels = false
                    if let first = models.first, !models.contains(aiManager.ollamaModel) {
                        aiManager.ollamaModel = first
                    }
                }
            } catch {
                await MainActor.run {
                    guard currentGeneration == self.ollamaFetchGeneration,
                          aiManager.ollamaURL == targetURL else {
                        return
                    }
                    self.ollamaFetchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isFetchingOllamaModels = false
                }
            }
        }
    }

    /// Re-runs binary resolution. The error is swallowed deliberately: `claudeResolutionDetail`
    /// already states the outcome in the row above, and a second error surface for the same fact
    /// would just say it twice.
    private func redetectClaudeCLI() {
        isRedetectingClaudeCLI = true
        Task { @MainActor in
            try? await aiManager.redetectClaudeCLI()
            isRedetectingClaudeCLI = false
        }
    }

    private func redetectCodexCLI() {
        isRedetectingCodexCLI = true
        Task { @MainActor in
            try? await aiManager.redetectCodexCLI()
            isRedetectingCodexCLI = false
        }
    }

    /// Lists the catalog the installed codex renders. A failure is shown beside the picker, which
    /// keeps offering the stored slug so the provider still runs with it.
    private func fetchCodexModels() {
        isFetchingCodexModels = true
        codexFetchError = nil
        Task { @MainActor in
            do {
                try await aiManager.fetchCodexCatalog()
            } catch {
                codexFetchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isFetchingCodexModels = false
        }
    }
}
