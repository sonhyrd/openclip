// CodexCLI.swift
// Core
//
// The isolated argument list OpenClip hands to the user's `codex` binary, and the reading of what
// comes back. Pure value construction: nothing here launches a process, reads settings or logs.
//
// This file imports Foundation and nothing else — deliberately, like `ClaudeCLI` beside it. It
// must stay free of `Constants`, `Log`, `ShellProcessRunner` and `SettingsStore` so the flag list
// can be compiled and red-verified with `swiftc` alone on a host with no Xcode.
//
// `codex exec --help` (codex-cli 0.153.4) is the contract. It is not a clone of `claude`'s flag
// set; each flag below names the Claude flag it stands in for, and ADR 0002 names the gaps.
import Foundation

/// Builds the isolated `codex` invocation and classifies its result.
public enum CodexCLI {
    /// The executable OpenClip looks for.
    public static let binaryName = "codex"

    /// The **default** wire id, a stable literal: the catalog's first listed entry moves without
    /// notice, and the top tier is the wrong default for a one-shot text transform.
    public static let defaultModel = "gpt-5.5"

    /// A literal, not a setting. A transform is one shot over selected text; the deliberation
    /// meant for coding tasks is not wanted here. It is in the asserted array, so a change is
    /// visible.
    public static let reasoningEffort = "low"

    /// The full argument list, in order. Every element is load-bearing and `CodexCLITests` asserts
    /// this array exactly; dropping one is an argument to be made against ADR 0002, not a
    /// simplification.
    ///
    /// - `exec`: headless, non-interactive (Claude's `-p`).
    /// - `--ephemeral`: no session files (Claude's `--no-session-persistence`).
    /// - `--ignore-user-config`: skips `~/.codex/config.toml`, where MCP servers and every user
    ///   setting live (Claude's `--setting-sources ""`).
    /// - `--ignore-rules`: no user or project execpolicy rules.
    /// - `--disable hooks`: hooks off. Measured as a hard switch even with hook trust bypassed;
    ///   `--ignore-user-config` alone does NOT stop a trusted hook.
    /// - `--skip-git-repo-check`: the isolated directory is not a repository.
    /// - `-s read-only` and `-C <empty directory>`: codex has no tools-off flag, so the shell tool
    ///   it always carries is confined to reading an empty private folder. This is the nearest
    ///   thing to Claude's `--tools ""`, and it is a bound, not a removal.
    /// - `--color never`, `--json`: machine-readable JSONL on stdout.
    /// - `-m <wire id>`, `-c model_reasoning_effort="low"`: both visible in the array.
    /// - `-c mcp_servers={}`: states the no-MCP invariant in the argument list and fails closed
    ///   if `--ignore-user-config` ever stops covering it (Claude's `--strict-mcp-config`).
    ///   Measured: accepted, and a wrong type is rejected at config load.
    ///
    /// - Parameters:
    ///   - prompt: the rules block plus the stdin sentence, built in the app target. The user's
    ///     selected text is **not** in here and not in the argument list at all — it arrives over
    ///     stdin, which `codex exec` appends to the prompt as a `<stdin>` block.
    ///   - model: the wire id sent over `-m`, verbatim.
    ///   - workingDirectory: the isolated empty directory, from `isolatedWorkingDirectory()`.
    public static func arguments(prompt: String, model: String, workingDirectory: String) -> [String] {
        [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--disable", "hooks",
            "--skip-git-repo-check",
            "-s", "read-only",
            "--color", "never",
            "-C", workingDirectory,
            "-m", model,
            "-c", "model_reasoning_effort=\"\(reasoningEffort)\"",
            "-c", "mcp_servers={}",
            "--json",
            prompt,
        ]
    }

    /// The catalog listing: `codex debug models` renders the model catalog as JSON, locally,
    /// logged in or not. It reads the user's config.toml (`debug` takes no
    /// `--ignore-user-config`, and rejects `--color`, both measured) and never runs a model.
    /// `debug` is a subcommand whose name may move; a rejected listing shows the stored slug only.
    public static let catalogArguments = ["debug", "models"]

    /// The directory the `codex` child runs in, and reads: a private, **empty** folder. See
    /// `ClaudeCLI.isolatedWorkingDirectory` for why not `/`.
    public static func isolatedWorkingDirectory(fileManager: FileManager = .default) -> URL {
        ClaudeCLI.isolatedWorkingDirectory(name: "openclip-codex-cli", fileManager: fileManager)
    }
}

// MARK: - The catalog

extension CodexCLI {
    /// One catalog entry: what the human sees, and what goes over `-m`.
    public struct Model: Sendable, Equatable, Hashable {
        public let displayName: String
        public let wireID: String

        public init(displayName: String, wireID: String) {
            self.displayName = displayName
            self.wireID = wireID
        }
    }

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            let slug: String
            let displayName: String?
            let visibility: String?

            private enum CodingKeys: String, CodingKey {
                case slug
                case displayName = "display_name"
                case visibility
            }
        }

        let models: [Entry]
    }

    /// Decodes `codex debug models` output, keeping the entries the CLI itself lists
    /// (`visibility == "list"`) in catalog order. nil when stdout is not a catalog at all.
    public static func decodeCatalog(stdout: String) -> [Model]? {
        guard let open = stdout.firstIndex(of: "{"),
              let close = stdout.lastIndex(of: "}"),
              open < close,
              let data = String(stdout[open...close]).data(using: .utf8),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return nil
        }
        return catalog.models
            .filter { $0.visibility == "list" }
            .map { Model(displayName: $0.displayName ?? $0.slug, wireID: $0.slug) }
    }

    /// The display name for a wire id from `models`, or the wire id itself when it is not there —
    /// before the catalog has loaded, or when the listing failed.
    public static func displayName(for wireID: String, in models: [Model]) -> String {
        models.first { $0.wireID == wireID }?.displayName ?? wireID
    }
}

// MARK: - Environment

extension CodexCLI {
    /// Variables removed from the child, for one reason: each can redirect or re-bill an
    /// invocation this provider promises runs on *the user's own ChatGPT subscription*. These are
    /// the names the installed native binary references; `OPENAI_BASE_URL` is not among them and
    /// so is not listed. `CODEX_HOME` is deliberately kept: the subscription login lives there.
    public static let strippedEnvironmentKeys = [
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "CODEX_AUTH",
        "CODEX_URL",
    ]

    /// The **complete** environment for the child, assigned verbatim by the executor.
    public static func childEnvironment(
        inherited: [String: String],
        binaryPath: String,
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        ClaudeCLI.shapedEnvironment(
            inherited: inherited,
            stripping: strippedEnvironmentKeys,
            binaryPath: binaryPath,
            home: home
        )
    }

    /// The candidate paths to test when the login shell yields nothing.
    public static func diskCandidatePaths(home: String = NSHomeDirectory()) -> [String] {
        ClaudeCLI.diskCandidatePaths(binaryName: binaryName, home: home)
    }

    /// The first usable candidate from `diskCandidatePaths`, or nil.
    public static func resolveOnDisk(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> String? {
        ClaudeCLI.resolveOnDisk(binaryName: binaryName, home: home, fileManager: fileManager)
    }
}

// MARK: - Failure taxonomy

extension CodexCLI {
    /// Every way the invocation can fail, exhaustively; mirrors `ClaudeCLI.Failure` case for case
    /// with codex wording, and is its own type so neither provider's vocabulary leaks into the
    /// other's. Each `message` tells the user what to **do**.
    public enum Failure: Error, LocalizedError, Sendable, Equatable {
        case notFound
        case launchFailed(String)
        case timedOut(seconds: Int)
        case exited(status: Int32, stderr: String)
        case rejectedInvocation(String)
        case notAuthenticated
        case malformedResponse
        case reportedError(String)
        case emptyOutput

        public var message: String {
            switch self {
            case .notFound:
                return String(localized: "Codex CLI not found. Install it, run `codex login`, then use Re-detect in Preferences → AI.")
            case .launchFailed(let detail):
                return String(localized: "Could not start the Codex CLI: \(detail). Check the path in Preferences → AI and use Re-detect.")
            case .timedOut(let seconds):
                return String(localized: "Codex did not respond within \(seconds) seconds. Try again, or try a shorter selection.")
            case .exited(let status, let stderr):
                guard let detail = Self.presentableDetail(stderr) else {
                    return String(localized: "Codex exited with code \(Int(status)). Run `codex doctor` in Terminal to check your installation.")
                }
                return String(localized: "Codex exited with code \(Int(status)): \(detail)")
            case .rejectedInvocation(let detail):
                guard let trimmed = Self.presentableDetail(detail) else {
                    return String(localized: "Your Codex CLI rejected this request. Run `codex update` in Terminal or pick another model in Preferences → AI, then try again.")
                }
                return String(localized: "Your Codex CLI rejected this request. Run `codex update` in Terminal or pick another model in Preferences → AI, then try again. Details: \(trimmed)")
            case .notAuthenticated:
                return String(localized: "Codex is not logged in. Run `codex login` in Terminal, then try again.")
            case .malformedResponse:
                return String(localized: "Codex returned a response OpenClip could not read. Run `codex update` in Terminal, then try again.")
            case .reportedError(let detail):
                guard let trimmed = Self.presentableDetail(detail) else {
                    return String(localized: "Codex reported an error. Run `codex update` in Terminal, then try again.")
                }
                return String(localized: "Codex reported an error: \(trimmed)")
            case .emptyOutput:
                return String(localized: "Codex returned an empty response. Try again, or try a shorter selection.")
            }
        }

        private static func presentableDetail(_ detail: String) -> String? {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        public var errorDescription: String? { message }
    }
}

// MARK: - Classification

extension CodexCLI {
    /// A successful transform. Codex has no thinking-token knob to report.
    public struct Success: Sendable, Equatable {
        public let text: String

        public init(text: String) {
            self.text = text
        }
    }

    /// Fragments (lowercased, substring match) that mean the CLI refused the invocation: a flag it
    /// does not know (`unexpected argument`, measured for `-a`), a subcommand that moved, a model
    /// it does not know, or a config override it could not parse (`Error loading config`,
    /// measured for a wrongly-typed `mcp_servers`).
    public static let rejectedInvocationPatterns = [
        "unexpected argument",
        "unrecognized subcommand",
        "unknown model",
        "error loading config",
    ]

    /// Fragments (lowercased, substring match) that mean nobody has logged in. `401 Unauthorized:
    /// Missing bearer or basic authentication` is the measured logged-out shape. The bare word
    /// "login" is deliberately not here: it would match a login shell or a login hook.
    public static let notAuthenticatedPatterns = [
        "not logged in",
        "401",
        "unauthorized",
        "codex login",
    ]

    /// One `--json` event, decoded leniently: only the fields classification reads.
    private struct Event: Decodable {
        struct Item: Decodable {
            let type: String?
            let text: String?
            let message: String?
        }

        let type: String?
        let message: String?
        let item: Item?
    }

    /// Turns one finished invocation into a result or a typed failure.
    ///
    /// Every JSONL line is scanned. The last `item.completed` whose item is an `agent_message` is
    /// the result — **unless an error event follows it** or the exit is non-zero. An error event
    /// *before* the message (a transport retry that then succeeded) does not fail a transform whose
    /// text arrived. The patterns are matched against error events and stderr only, never against
    /// an agent message: the model's own words must not be able to classify the run.
    ///
    /// `notFound`, `launchFailed` and `timedOut` are not decidable from a finished invocation —
    /// the caller constructs those.
    public static func classify(stdout: String, stderr: String, exitStatus: Int32) -> Result<Success, Failure> {
        var parsedAny = false
        var message: String?
        var errorAfterMessage: String?

        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: data) else {
                continue
            }
            parsedAny = true
            if event.type == "item.completed", event.item?.type == "agent_message" {
                message = event.item?.text ?? ""
                errorAfterMessage = nil
            } else if event.type == "error" {
                errorAfterMessage = event.message ?? ""
            } else if event.type == "item.completed", event.item?.type == "error" {
                errorAfterMessage = event.item?.message ?? ""
            }
        }

        // Errors first, on the channel they arrived on: a trailing error event carries codex's own
        // explanation; stderr carries clap's for a rejected flag.
        if let reported = errorAfterMessage {
            if let specific = patternFailure(in: reported) { return .failure(specific) }
            if let specific = patternFailure(in: stderr) { return .failure(specific) }
            return .failure(.reportedError(reported.isEmpty ? stderr : reported))
        }
        if let specific = patternFailure(in: stderr), message == nil {
            return .failure(specific)
        }
        if exitStatus != 0 {
            if let specific = patternFailure(in: stderr) { return .failure(specific) }
            return .failure(.exited(status: exitStatus, stderr: stderr))
        }
        guard parsedAny else {
            return .failure(stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .emptyOutput
                : .malformedResponse)
        }
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyOutput) }
        return .success(Success(text: text))
    }

    private static func patternFailure(in text: String) -> Failure? {
        let haystack = text.lowercased()
        if rejectedInvocationPatterns.contains(where: haystack.contains) {
            return .rejectedInvocation(text)
        }
        if notAuthenticatedPatterns.contains(where: haystack.contains) {
            return .notAuthenticated
        }
        return nil
    }
}
