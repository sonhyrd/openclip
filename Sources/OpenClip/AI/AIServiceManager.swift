// AIServiceManager.swift
// OpenClip
//
// Manages AI service provider selection, API credentials, and invocation of AI text processing actions.
import Foundation
import os
import SwiftUI
import Core
import os

extension Notification.Name {
    /// Posted by `AIServiceManager` after the AI preset list has been written, so observers
    /// (e.g. `AIActionSync`) can re-register AI actions against the freshly committed list.
    public static let aiActionPresetsDidChange = Notification.Name("OpenClip.AIActionPresetsDidChange")
}

@MainActor
public final class AIServiceManager: ObservableObject {
    public static let shared = AIServiceManager()

    // `@AppStorage` does not automatically publish `objectWillChange`; forward manually
    // so Preferences (and any other observers) refresh when settings change.
    @AppStorage("aiEnabled") public var isAIEnabled: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiActiveProvider") public var activeProviderRaw: String = AIProviderType.apple.rawValue {
        willSet { objectWillChange.send() }
    }
    // API key is stored in ~/.openclip/secrets.json via SecretStore.
    @Published public var cloudAPIKey: String {
        didSet {
            if cloudAPIKey.isEmpty {
                SecretStore.delete(account: Self.cloudAPIKeyAccount)
            } else {
                let didStore = SecretStore.set(cloudAPIKey, account: Self.cloudAPIKeyAccount)
                if !didStore {
                    Log.settings.error("Failed to persist cloud API key to SecretStore; reverting value.")
                    cloudAPIKey = oldValue
                }
            }
        }
    }
    @AppStorage("aiCloudService") public var cloudServiceRaw: String = "openai" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiCloudCustomURL") public var cloudCustomURL: String = "" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiCloudModel") public var cloudModel: String = "gpt-4o-mini" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiOllamaURL") public var ollamaURL: String = "http://localhost:11434" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiOllamaModel") public var ollamaModel: String = "llama3" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiBrowserPreset") public var browserPreset: String = "chatgpt" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiBrowserURLTemplate") public var browserURLTemplate: String = "https://chatgpt.com/?q={text}" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("aiActionPresetsJSON") public var actionPresetsJSON: String = "" {
        willSet { objectWillChange.send() }
    }

    // MARK: - Claude Code CLI resolution cache
    //
    // Deliberately NOT persisted — no `@AppStorage`, no `SettingsStore`. A binary path is derived
    // runtime state, not a setting: it goes stale across a CLI reinstall, a version-manager switch
    // or a home-directory move, and a persisted stale path fails at spawn with a confusing error
    // instead of simply being re-resolved. Do not "fix" this by persisting it. The repo's
    // no-raw-`UserDefaults` rule governs settings; this is a cache. Cost: one login-shell spawn per
    // app launch.
    //
    // It lives here, on the manager, rather than on the provider because `currentProvider` is a
    // computed property that constructs a fresh provider on every access — a provider-held cache
    // would be discarded between every call and each run would pay another login-shell spawn.

    /// The resolved `claude` binary, or nil when resolution has not run or found nothing.
    @Published public private(set) var claudeBinaryPath: String?

    /// User-facing account of the last resolution attempt (shown in Preferences → AI). Empty until
    /// resolution has run once.
    @Published public private(set) var claudeResolutionDetail: String = ""

    /// Resolution gets its **own** 10-second budget, separate from the 30-second invocation budget:
    /// a zsh *login* shell sources the user's entire profile, so a version manager that phones home,
    /// a hung completion initialiser, or an interactive `read` in a profile script can block
    /// indefinitely. Bounding it here keeps a pathological profile from wedging the first transform.
    private nonisolated static let claudeResolutionTimeout: TimeInterval = 10

    /// The cached path, resolving once on first use.
    /// - Throws: `ClaudeCLI.Failure.notFound` when nothing resolves — never a silent nil.
    @discardableResult
    public func resolvedClaudeBinaryPath() async throws -> String {
        if let claudeBinaryPath { return claudeBinaryPath }
        return try await redetectClaudeCLI()
    }

    /// Re-detection entry point: runs resolution again and overwrites both published values.
    /// - Throws: `ClaudeCLI.Failure.notFound` when nothing resolves.
    @discardableResult
    public func redetectClaudeCLI() async throws -> String {
        let (path, detail) = await Self.detectClaudeBinary()
        claudeBinaryPath = path
        claudeResolutionDetail = detail
        guard let path else {
            Log.ai.error("Claude CLI not found via login shell or known install directories")
            throw ClaudeCLI.Failure.notFound
        }
        Log.ai.info("Claude CLI resolved at \(path, privacy: .public)")
        return path
    }

    /// Login shell first, then the known install directories. Nonisolated: it only spawns a
    /// subprocess and reads the filesystem; the caller lands both values back on the main actor.
    private nonisolated static func detectClaudeBinary() async -> (path: String?, detail: String) {
        if let path = await loginShellClaudePath() {
            return (path, String(localized: "Found via login shell: \(path)"))
        }
        if let path = ClaudeCLI.resolveOnDisk() {
            return (path, String(localized: "Found on disk: \(path)"))
        }
        return (nil, String(localized: "claude not found — install Claude Code and run `claude login`"))
    }

    /// `/bin/zsh -l -c "command -v claude"` — a **login** shell, because a GUI app launched from
    /// Finder does not inherit the terminal's PATH. Without the `-l`, lookup fails on a machine
    /// where `claude` works perfectly well in Terminal, and that reads to the user as "the app is
    /// broken". This is the feature's number-one silent failure mode.
    ///
    /// Goes through the shared `ShellProcessRunner` executor (one watchdog, one process-group kill)
    /// rather than a hand-rolled `Process`.
    private nonisolated static func loginShellClaudePath() async -> String? {
        let invocation = ShellProcessRunner.Invocation(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-c", "command -v \(ClaudeCLI.binaryName)"],
            // The real environment, so HOME/USER are set and the login shell finds the profile
            // files whose PATH exports are the whole point of using `-l`.
            environment: ProcessInfo.processInfo.environment,
            timeout: claudeResolutionTimeout
        )
        guard let output = try? await ShellProcessRunner.runCapturingExit(invocation),
              output.terminationStatus == 0 else {
            return nil
        }
        let candidate = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeCLI.isUsableBinary(atPath: candidate) ? candidate : nil
    }

    public static let defaultPresets: [AIActionPreset] = [
        AIActionPreset(id: "proofread", title: String(localized: "Proofread"), prompt: String(localized: "Fix all spelling, punctuation, and grammatical errors while preserving the original wording, tone, and formatting"), isEnabled: true),
        AIActionPreset(id: "rewrite", title: String(localized: "Rewrite"), prompt: String(localized: "Rewrite to improve clarity, flow, and vocabulary while keeping the original meaning and language"), isEnabled: true),
        AIActionPreset(id: "summarize", title: String(localized: "Summarize"), prompt: String(localized: "Provide a concise bulleted summary capturing the key points"), isEnabled: true),
        AIActionPreset(id: "explain", title: String(localized: "Explain"), prompt: String(localized: "Explain the core concept clearly and concisely in simple terms"), isEnabled: true),
        AIActionPreset(id: "translate", title: String(localized: "Translate"), prompt: String(localized: "Translate the text accurately into natural English"), isEnabled: true),
        AIActionPreset(id: "fix_code", title: String(localized: "Fix Code"), prompt: String(localized: "Fix bugs, syntax errors, and logic issues in this code snippet. Return only the raw working code without markdown code blocks or explanations"), isEnabled: false),
        AIActionPreset(id: "make_shorter", title: String(localized: "Make Shorter"), prompt: String(localized: "Condense this text to be as concise as possible while keeping all essential information"), isEnabled: false),
        AIActionPreset(id: "formal_tone", title: String(localized: "Formal Tone"), prompt: String(localized: "Rewrite this text in a polished, professional, and formal tone"), isEnabled: false)
    ]

    private static let presetDecodeFailureLogged = OSAllocatedUnfairLock(initialState: false)

    public var presets: [AIActionPreset] {
        get {
            guard !actionPresetsJSON.isEmpty,
                  let data = actionPresetsJSON.data(using: .utf8) else {
                return Self.defaultPresets
            }
            if let decoded = try? JSONDecoder().decode([AIActionPreset].self, from: data) {
                return decoded
            }
            Self.presetDecodeFailureLogged.withLock { alreadyLogged in
                guard !alreadyLogged else { return }
                alreadyLogged = true
                Log.ai.error("Failed to decode saved AI action presets; using defaults")
            }
            return Self.defaultPresets
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                actionPresetsJSON = str
            } else {
                Log.ai.error("Failed to encode AI action presets for persistence")
            }
            // Posted after the value above has committed, so observers always read the fresh list
            // (objectWillChange fires before @AppStorage lands). AIActionSync keeps the registered
            // AI actions in step with this list.
            NotificationCenter.default.post(name: .aiActionPresetsDidChange, object: self)
        }
    }

    public var enabledPresets: [AIActionPreset] {
        let list = presets.filter { $0.isEnabled }
        return list.isEmpty ? [Self.defaultPresets[0]] : list
    }

    public func updatePreset(_ updated: AIActionPreset) {
        var current = presets
        if let idx = current.firstIndex(where: { $0.id == updated.id }) {
            current[idx] = updated
        } else {
            current.append(updated)
        }
        presets = current
    }

    /// Maps a registered AI action id (`ai.preset.<presetID>`, see `AIAction`) back to its live
    /// preset, so palette/preferences routing can resolve the preset without touching `AIAction`'s
    /// internals.
    public func preset(forActionID actionID: String) -> AIActionPreset? {
        let prefix = "ai.preset."
        guard actionID.hasPrefix(prefix) else { return nil }
        let presetID = String(actionID.dropFirst(prefix.count))
        return presets.first { $0.id == presetID }
    }

    public func resetPresetsToDefault() {
        presets = Self.defaultPresets
    }

    private static let cloudAPIKeyAccount = "aiCloudAPIKey"

    private init() {
        // Load the API key from the SecretStore (~/.openclip/secrets.json)
        if let stored = SecretStore.get(account: Self.cloudAPIKeyAccount) {
            self.cloudAPIKey = stored
        } else if let legacy = UserDefaults.standard.string(forKey: "aiCloudAPIKey"), !legacy.isEmpty {
            if SecretStore.set(legacy, account: Self.cloudAPIKeyAccount) {
                UserDefaults.standard.removeObject(forKey: "aiCloudAPIKey")
            }
            self.cloudAPIKey = legacy
        } else {
            self.cloudAPIKey = ""
        }
    }

    public var activeProviderType: AIProviderType {
        get { AIProviderType(rawValue: activeProviderRaw) ?? .apple }
        set { activeProviderRaw = newValue.rawValue }
    }

    public var cloudServiceProvider: CloudServiceProvider {
        get { CloudServiceProvider(rawValue: cloudServiceRaw) ?? .openai }
        set {
            cloudServiceRaw = newValue.rawValue
            if let firstModel = newValue.defaultModels.first {
                cloudModel = firstModel
            }
        }
    }

    public var effectiveBrowserURLTemplate: String {
        switch browserPreset {
        case "claude": return "https://claude.ai/new?q={text}"
        case "perplexity": return "https://www.perplexity.ai/search?q={text}"
        case "gemini": return "https://gemini.google.com/app?q={text}"
        case "deepseek": return "https://chat.deepseek.com/?q={text}"
        case "custom":
            let custom = browserURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? "https://chatgpt.com/?q={text}" : custom
        default:
            return "https://chatgpt.com/?q={text}"
        }
    }

    /// Overrides the AI provider instance (for testing/mocking).
    public var providerOverride: (any AIProvider)? = nil

    public var currentProvider: any AIProvider {
        if let providerOverride {
            return providerOverride
        }
        switch activeProviderType {
        case .apple:
            return AppleIntelligenceProvider()
        case .ollama:
            return OllamaProvider(baseURL: ollamaURL, model: ollamaModel)
        case .cloud:
            return CloudAPIProvider(apiKey: cloudAPIKey, model: cloudModel, serviceProvider: cloudServiceProvider, customBaseURL: cloudCustomURL)
        case .browser:
            return BrowserRedirectProvider(template: effectiveBrowserURLTemplate)
        case .claudeCLI:
            // The provider is handed the manager's cached resolver, not a path: this property
            // rebuilds the provider on every access, so the cache has to outlive it.
            return ClaudeCLIProvider(resolveBinaryPath: { [unowned self] in
                try await self.resolvedClaudeBinaryPath()
            })
        }
    }
}

public enum CloudServiceProvider: String, CaseIterable, Identifiable, Sendable {
    case openai = "openai"
    case anthropic = "anthropic"
    case google = "google"
    case deepseek = "deepseek"
    case groq = "groq"
    case openrouter = "openrouter"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI (ChatGPT)"
        case .anthropic: return "Anthropic (Claude)"
        case .google: return "Google Gemini"
        case .deepseek: return "DeepSeek"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter"
        case .custom: return "Custom OpenAI-Compatible Endpoint"
        }
    }

    public var defaultModels: [String] {
        switch self {
        case .openai: return ["gpt-4o-mini", "gpt-4o", "o1-mini", "o1", "gpt-4-turbo"]
        case .anthropic: return ["claude-3-5-sonnet-latest", "claude-3-5-haiku-latest", "claude-3-opus-latest"]
        case .google: return ["gemini-2.0-flash", "gemini-1.5-flash", "gemini-1.5-pro"]
        case .deepseek: return ["deepseek-chat", "deepseek-coder", "deepseek-reasoner"]
        case .groq: return ["llama-3.3-70b-versatile", "mixtral-8x7b-32768", "deepseek-r1-distill-llama-70b"]
        case .openrouter: return ["openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet", "deepseek/deepseek-r1", "google/gemini-2.0-flash-001"]
        case .custom: return ["default"]
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }
}

public struct AIActionPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var prompt: String
    public var isEnabled: Bool

    public init(id: String, title: String, prompt: String, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.isEnabled = isEnabled
    }
}
