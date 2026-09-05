// ClaudeCLI.swift
// Core
//
// The isolated argument list OpenClip hands to the user's `claude` binary. Pure value
// construction: nothing here launches a process, reads settings or logs.
//
// This file imports Foundation and nothing else — deliberately. It must stay free of
// `Constants`, `Log`, `ShellProcessRunner` and `SettingsStore` so the flag list can be
// compiled and red-verified with `swiftc` alone on a host with no Xcode.
import Foundation

/// Builds the isolated `claude` invocation.
public enum ClaudeCLI {
    /// Pinned, **dated** model identifier — never a floating alias. An alias silently moves the
    /// invocation onto a different (and more expensive) model; a stale dated id is rejected
    /// outright by the CLI, which makes the upgrade a visible maintenance task instead.
    public static let model = "claude-sonnet-4-5-20250929"

    /// One-line role only. The correction rules live in `-p`, not here — see `arguments(prompt:)`.
    public static let systemPromptRole = "You are an inline text transformation tool. Output only the transformed text."

    /// The full argument list, in order. Every element is load-bearing: `--setting-sources ""`,
    /// `--tools ""`, `--strict-mcp-config` and `--no-session-persistence` bound the blast radius of
    /// a transform that runs on arbitrary selected text and needs none of the user's tools, MCP
    /// servers, project settings or session history. Dropping one is an argument to be made against
    /// ADR 0001, not a simplification; `ClaudeCLITests` asserts this array exactly.
    ///
    /// - Parameter prompt: the fully-assembled `-p` payload (rules block plus the stdin sentence),
    ///   built by the caller in the app target. The user's selected text is **not** in here and not
    ///   in the argument list at all — it arrives over stdin, so quotes, backticks and newlines in
    ///   a selection can never be misread as arguments.
    public static func arguments(prompt: String) -> [String] {
        [
            // The rules stay in `-p`; `--system-prompt` stays a one-line role. Moving the rules
            // into `--system-prompt` measured 7/15 against 14/14 upstream, and it fails SILENTLY:
            // the text usually comes back unchanged (looking like "nothing needed fixing"), and
            // occasionally a *list of corrections* is what gets pasted over the user's selection.
            // No error, no non-zero exit. This is the most tempting tidy-up available here and it
            // must not be made.
            "-p", prompt,
            "--max-turns", "1",
            "--model", model,
            "--setting-sources", "",
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--system-prompt", systemPromptRole,
            "--output-format", "json",
        ]
    }
}

// MARK: - Response envelope

extension ClaudeCLI {
    /// The `--output-format json` envelope, decoded from the CLI's stdout.
    ///
    /// `subtype` is **deliberately not decoded**. A failing run was measured reporting
    /// `subtype: "success"` alongside `is_error: true`, so branching on it would call that run a
    /// success. `is_error` is the only signal.
    public struct Envelope: Decodable, Sendable, Equatable {
        public let isError: Bool
        public let result: String
        /// Keyed by model identifier. Measured with **two** entries under a realistic payload —
        /// the pinned model plus a Haiku side-call the CLI makes on its own — and one entry under
        /// a trivial prompt. Read it by key; never by position.
        public let modelUsage: [String: ModelUsage]?
        /// `usage.output_tokens_details.thinking_tokens`, measured against CLI 2.1.259. Telemetry
        /// only: the provider logs it to confirm `MAX_THINKING_TOKENS=0` is actually taking effect.
        /// Absent or unreadable is normal and never fatal.
        public let thinkingTokens: Int?

        private enum CodingKeys: String, CodingKey {
            // Note the mixed casing: the CLI emits `is_error` but `modelUsage`.
            case isError = "is_error"
            case result
            case modelUsage
            case usage
        }

        private struct Usage: Decodable {
            struct OutputTokensDetails: Decodable {
                let thinkingTokens: Int?

                private enum CodingKeys: String, CodingKey {
                    case thinkingTokens = "thinking_tokens"
                }
            }

            let outputTokensDetails: OutputTokensDetails?

            private enum CodingKeys: String, CodingKey {
                case outputTokensDetails = "output_tokens_details"
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            result = try container.decodeIfPresent(String.self, forKey: .result) ?? ""
            // `try?`, not `try`, for the SAME reason `usage` below uses it: this was the one strict
            // decode left in a deliberately lenient envelope. A `modelUsage` that arrives as
            // anything but a map of objects (null values, a numeric map, an array) would throw,
            // `parseEnvelope` would return nil, and a successful transform whose corrected text is
            // sitting right there in `result` would be discarded as `.malformedResponse` — the
            // exact trade this type is built to refuse. Ratified: a moved telemetry field is
            // logged, never fatal.
            modelUsage = try? container.decodeIfPresent([String: ModelUsage].self, forKey: .modelUsage)
            // A reshaped usage block is a telemetry loss, never a reason to refuse the transformed
            // text sitting in `result`.
            thinkingTokens = (try? container.decode(Usage.self, forKey: .usage))?.outputTokensDetails?.thinkingTokens
        }

    }

    /// One entry of the envelope's model-usage map. Deliberately empty: only the *presence of the
    /// pinned model as a key* is read (see `modelUsageOutcome`), and decoding no fields is what
    /// guarantees a telemetry field that moves or disappears can never turn a successful transform
    /// into a decoding failure.
    public struct ModelUsage: Decodable, Sendable, Equatable {
        public init() {}
    }

    /// Locates the outermost `{…}` in `stdout` and decodes it, so a banner, a warning line or any
    /// other noise around the envelope does not make an otherwise good response unreadable.
    /// Returns nil when there is no object to decode, or it does not decode.
    public static func parseEnvelope(stdout: String) -> Envelope? {
        guard let open = stdout.firstIndex(of: "{"),
              let close = stdout.lastIndex(of: "}"),
              open < close else {
            return nil
        }
        guard let data = String(stdout[open...close]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }
}

// MARK: - The keyed model lookup

extension ClaudeCLI {
    /// The outcome of reading the model-usage map **by the pinned identifier as the key**.
    ///
    /// This is data, not a failure and not a log call: the Core type may not log (Foundation only),
    /// so the app-target caller logs whatever this says. There is deliberately no case a caller
    /// could mistake for an error — a missing or unexpected entry is logged, never fatal. The
    /// transform succeeded and the corrected text is in hand; refusing to hand it to the user
    /// because a telemetry field moved is the wrong trade in a popup utility.
    public enum ModelUsageOutcome: Sendable, Equatable {
        /// The pinned identifier was present. Extra entries (the CLI's own side-calls) are normal.
        case matched(ModelUsage)
        /// The pinned identifier was absent. Carries the keys that were there, sorted — the only
        /// signal that would ever reveal the pin no longer resolving to what was requested, which
        /// is exactly what the dated pin exists to keep visible.
        case unexpected(reportedModels: [String])

        /// The model identifier to name in the caller's log line. Lives here, beside `warning`,
        /// because it is rendered from this enum's own payload — the app target was reaching in and
        /// re-deriving it from the associated values.
        public var loggedModel: String {
            switch self {
            case .matched:
                return ClaudeCLI.model
            case .unexpected(let models):
                return models.isEmpty ? "unreported" : models.joined(separator: ", ")
            }
        }

        /// A log line for the app target, or nil when there is nothing to report. Not localized:
        /// it is addressed to a developer reading the log, not to the user.
        public var warning: String? {
            switch self {
            case .matched:
                return nil
            case .unexpected(let models):
                let listed = models.isEmpty ? "none" : models.joined(separator: ", ")
                return "Claude CLI reported no usage for pinned model \(ClaudeCLI.model); reported: \(listed)"
            }
        }
    }

    /// Reads the model-usage map by key. Total: every input produces an outcome, never a failure.
    public static func modelUsageOutcome(_ usage: [String: ModelUsage]?) -> ModelUsageOutcome {
        if let entry = usage?[model] {
            return .matched(entry)
        }
        return .unexpected(reportedModels: usage.map { $0.keys.sorted() } ?? [])
    }

    /// A successful transform plus the (never fatal) model-lookup outcome for the caller to log.
    public struct Success: Sendable, Equatable {
        public let text: String
        public let modelUsage: ModelUsageOutcome
        /// Reported thinking tokens, for the caller's log. nil when the envelope carried none.
        public let thinkingTokens: Int?

        public init(text: String, modelUsage: ModelUsageOutcome, thinkingTokens: Int? = nil) {
            self.text = text
            self.modelUsage = modelUsage
            self.thinkingTokens = thinkingTokens
        }
    }
}

// MARK: - Failure taxonomy

extension ClaudeCLI {
    /// Every way the invocation can fail, exhaustively. Each case is constructible in a unit test
    /// with no subprocess, and each `message` tells the user what to **do**.
    ///
    /// These map to the shared AI error type's general provider-unavailable case at the boundary;
    /// no case is added to that shared enum, which would put this provider's vocabulary into every
    /// other provider's error surface.
    public enum Failure: Error, LocalizedError, Sendable, Equatable {
        /// No `claude` binary was resolved.
        case notFound
        /// The binary was found but the process could not be started.
        case launchFailed(String)
        /// The watchdog killed the child at its budget.
        case timedOut(seconds: Int)
        /// A non-zero exit that nothing more specific explains. Carries the raw stderr so a novel
        /// failure is still actionable rather than opaque.
        case exited(status: Int32, stderr: String)
        /// The CLI refused the invocation itself — an unknown flag or an unrecognised model, i.e.
        /// a CLI too old for the flags this provider pins.
        case rejectedInvocation(String)
        /// The CLI is installed but nobody has run `claude login`.
        case notAuthenticated
        /// stdout did not parse as an envelope **at all**. Never for a field inside a valid one.
        case malformedResponse
        /// A valid envelope whose `is_error` flag was set.
        case reportedError(String)
        /// A valid, non-error envelope carrying no text.
        case emptyOutput

        public var message: String {
            switch self {
            case .notFound:
                return String(localized: "Claude Code CLI not found. Install it, run `claude login`, then use Re-detect in Preferences → AI.")
            case .launchFailed(let detail):
                return String(localized: "Could not start the Claude Code CLI: \(detail). Check the path in Preferences → AI and use Re-detect.")
            case .timedOut(let seconds):
                return String(localized: "Claude Code did not respond within \(seconds) seconds. Try again, or try a shorter selection.")
            case .exited(let status, let stderr):
                guard let detail = Self.presentableDetail(stderr) else {
                    return String(localized: "Claude Code exited with code \(Int(status)). Run `claude doctor` in Terminal to check your installation.")
                }
                return String(localized: "Claude Code exited with code \(Int(status)): \(detail)")
            case .rejectedInvocation(let detail):
                guard let trimmed = Self.presentableDetail(detail) else {
                    return String(localized: "Your Claude Code CLI rejected this request — it is probably out of date. Run `claude update` in Terminal, then try again.")
                }
                return String(localized: "Your Claude Code CLI rejected this request — it is probably out of date. Run `claude update` in Terminal, then try again. Details: \(trimmed)")
            case .notAuthenticated:
                return String(localized: "Claude Code is not logged in. Run `claude login` in Terminal, then try again.")
            case .malformedResponse:
                return String(localized: "Claude Code returned a response OpenClip could not read. Run `claude update` in Terminal, then try again.")
            case .reportedError(let detail):
                guard let trimmed = Self.presentableDetail(detail) else {
                    return String(localized: "Claude Code reported an error. Run `claude update` in Terminal, then try again.")
                }
                return String(localized: "Claude Code reported an error: \(trimmed)")
            case .emptyOutput:
                return String(localized: "Claude Code returned an empty response. Try again, or try a shorter selection.")
            }
        }

        /// The trimmed detail, or nil when there is nothing worth showing the user. Three cases
        /// carried the same trim-and-test; only that is shared — each still picks its own copy for
        /// the with-detail and without-detail outcomes, because the advice differs.
        private static func presentableDetail(_ detail: String) -> String? {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        public var errorDescription: String? { message }
    }
}

// MARK: - Binary resolution (pure parts)

extension ClaudeCLI {
    /// The executable OpenClip looks for.
    public static let binaryName = "claude"

    /// Directories scanned when the login shell yields nothing — the documented Claude Code install
    /// locations plus the usual user-level bin directories. Order is preference order; `~` is
    /// expanded against the current user's home at call time, so this stays a plain list.
    ///
    /// Foundation only, on purpose: no `Constants`, no `Log`, no `ShellProcessRunner`. The process
    /// launch that consults this list lives in the app target.
    public static let searchDirectories = [
        "~/.claude/local",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.local/bin",
        "~/.bun/bin",
        "/usr/bin",
    ]

    /// Whether a resolution candidate is worth spawning: an absolute path that exists, is not a
    /// directory, and carries the executable bit. `command -v` can report a shell function or an
    /// alias name instead of a path, which this rejects for the same reason.
    public static func isUsableBinary(atPath path: String, fileManager: FileManager = .default) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    /// Resolution gets its **own** 10-second budget, separate from the 30-second invocation budget:
    /// a zsh *login* shell sources the user's entire profile, so a version manager that phones home,
    /// a hung completion initialiser, or an interactive `read` in a profile script can block
    /// indefinitely. Bounding it here keeps a pathological profile from wedging the first transform.
    ///
    /// It lives beside the code that explains why it exists, not in `Constants`: it bounds one
    /// CLI-specific call, not an app-wide policy. The literal is this file's own, so the
    /// Foundation-only rule is untouched.
    public static let discoveryTimeout: TimeInterval = 10

    /// `searchDirectories` with `~` expanded against `home`. **The** tilde expansion — both the
    /// disk candidates and the child `PATH` go through it. `NSString.expandingTildeInPath` reads
    /// `$HOME` while `NSHomeDirectory()` does not, so two expansions can disagree; there is one.
    public static func expandedSearchDirectories(home: String = NSHomeDirectory()) -> [String] {
        searchDirectories.map { $0.hasPrefix("~/") ? home + String($0.dropFirst(1)) : $0 }
    }

    /// The candidate paths to test, in order — `expandedSearchDirectories` with the binary name
    /// appended. Pure: touches no filesystem, so it is directly assertable in a test.
    public static func diskCandidatePaths(home: String = NSHomeDirectory()) -> [String] {
        expandedSearchDirectories(home: home).map { $0 + "/" + binaryName }
    }

    /// Variables removed from the child, all for one reason: each can redirect or re-bill an
    /// invocation this provider promises runs on *the user's own Claude subscription*, against
    /// Anthropic, on the pinned model. `--setting-sources ""` closes the settings-file door; this
    /// list closes the environment door beside it, which would otherwise be wide open.
    ///
    /// - `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` — shadow the subscription login and bill an
    ///   organisation instead. The headline invariant of this feature.
    /// - `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` — route the run to AWS or GCP billing,
    ///   which is neither the subscription nor an Anthropic endpoint.
    /// - `ANTHROPIC_BASE_URL`, `ANTHROPIC_CUSTOM_HEADERS` — send the user's selected text to an
    ///   arbitrary endpoint. On a utility that acts on whatever is selected, that is the whole
    ///   blast-radius argument ADR 0001 makes about tools and MCP servers, applied to the wire.
    /// - `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL` — compete with the dated `--model` pin.
    ///   The flag should win for the main call; the small fast model has no flag pinning it at all.
    public static let strippedEnvironmentKeys = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_CUSTOM_HEADERS",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
    ]

    /// The **complete** environment for the child: `ShellProcessRunner` assigns it verbatim rather
    /// than inheriting, so anything omitted here is simply absent from the child.
    ///
    /// - Parameters:
    ///   - inherited: the environment to shape, normally `ProcessInfo.processInfo.environment`.
    ///   - binaryPath: the resolved `claude` binary; its own directory goes first on `PATH`
    ///     because a version-managed install keeps its node runtime beside it.
    public static func childEnvironment(
        inherited: [String: String],
        binaryPath: String,
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment = inherited
        // Subscription-only, against Anthropic, on the pinned model — by construction rather than
        // by hoping the machine carries none of these. See `strippedEnvironmentKeys`.
        for key in strippedEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment["MAX_THINKING_TOKENS"] = "0"
        // A GUI app launched from Finder inherits a minimal PATH. Prefix the binary's own directory
        // and the known install directories, keeping whatever we did inherit as the tail.
        let directories = [(binaryPath as NSString).deletingLastPathComponent]
            + expandedSearchDirectories(home: home)
        environment["PATH"] = (directories + [inherited["PATH"] ?? ""])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return environment
    }

    /// The directory the `claude` child runs in: a private, **empty** folder under the temp
    /// directory, created on demand.
    ///
    /// Claude Code indexes its working directory at startup — a ripgrep-style walk probing
    /// `.gitignore`/`.rgignore` in every directory it can reach — even under `-p` with tools off.
    /// Left to inherit OpenClip's cwd, which is `/` for a Finder-launched app, it crawled the whole
    /// disk, and the moment the walk reached `~/Desktop`, `~/Documents` or `~/Downloads` macOS raised
    /// an "OpenClip would like to access files in your Desktop folder" prompt attributed to OpenClip
    /// (measured with `fs_usage`; one prompt per folder). An empty directory gives the walk nothing
    /// to find. This is the cwd door beside the settings door (`--setting-sources ""`) and the
    /// environment door (`strippedEnvironmentKeys`).
    ///
    /// Falls back to the temp directory itself if the folder cannot be created — still not `/`.
    public static func isolatedWorkingDirectory(fileManager: FileManager = .default) -> URL {
        let temp = fileManager.temporaryDirectory
        let dir = temp.appendingPathComponent("openclip-claude-cli", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return temp
        }
    }

    /// The first usable candidate from `diskCandidatePaths`, or nil.
    public static func resolveOnDisk(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> String? {
        diskCandidatePaths(home: home).first { isUsableBinary(atPath: $0, fileManager: fileManager) }
    }
}

// MARK: - Classification

extension ClaudeCLI {
    /// stderr fragments (lowercased, substring match) that mean the CLI refused the invocation.
    ///
    /// `unrecognized_model` — **underscored** — is the form the installed CLI actually emits
    /// (`[claude-code:unrecognized_model] {…}`). The upstream project's patterns are all
    /// space-separated and none of them match it; they are kept alongside because a future version
    /// may phrase it either way. `unknown option` was measured for a bogus flag, and is what makes
    /// a CLI that drops `--no-session-persistence` fail closed instead of quietly writing
    /// transcripts again.
    public static let rejectedInvocationPatterns = [
        "unrecognized_model",
        "unknown model",
        "invalid model",
        "unknown option",
        "unknown argument",
        "unrecognized option",
    ]

    /// stderr fragments (lowercased, substring match) that mean nobody has logged in. This is a
    /// pattern match and is honest about being one: anything unmatched falls through to `.exited`
    /// with the raw stderr still shown.
    public static let notAuthenticatedPatterns = [
        "claude login",
        "not logged in",
        "not authenticated",
        "unauthorized",
        "authentication_error",
        "invalid api key",
    ]

    /// Turns one finished invocation into a result or a typed failure.
    ///
    /// **Order is the design.** When stdout parses, the envelope is classified *before* the exit
    /// code: a bad model identifier exits 1 *and* prints a complete envelope carrying a
    /// human-readable explanation, which an exit-code-first classifier would bury in a generic
    /// failure. Only when stdout is not an envelope at all do the stderr patterns, and then the
    /// exit code, decide.
    ///
    /// `notFound`, `launchFailed` and `timedOut` are not decidable from a finished invocation —
    /// the caller constructs those.
    public static func classify(stdout: String, stderr: String, exitStatus: Int32) -> Result<Success, Failure> {
        if let envelope = parseEnvelope(stdout: stdout) {
            if envelope.isError {
                let detail = envelope.result.trimmingCharacters(in: .whitespacesAndNewlines)
                let reported = detail.isEmpty ? stderr : detail
                // The patterns are matched HERE too, not only on the no-envelope branch. A rejected
                // invocation was measured exiting 1 *with* a complete envelope, and a logged-out run
                // is the same shape — so consulting the patterns only when parsing fails leaves
                // `.rejectedInvocation` ("run `claude update`") and `.notAuthenticated`
                // ("run `claude login`") unreachable on the one path they were written for, and the
                // user is told to update a CLI that is fine while nobody has logged in.
                //
                // Matched against the ENVELOPE'S OWN text, never stderr: the measured bad-model run
                // prints `unrecognized_model` on stderr *and* a better explanation ("API Error: 404
                // model: …") in the envelope, and reading stderr here would throw that explanation
                // away for a generic "run `claude update`". Each branch reads the channel it is on.
                if let specific = patternFailure(in: reported) {
                    return .failure(specific)
                }
                return .failure(.reportedError(reported))
            }
            let text = envelope.result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(.emptyOutput) }
            // A miss here is data for the caller's log. It cannot produce a failure.
            return .success(Success(
                text: text,
                modelUsage: modelUsageOutcome(envelope.modelUsage),
                thinkingTokens: envelope.thinkingTokens
            ))
        }

        if let specific = patternFailure(in: stderr) {
            return .failure(specific)
        }
        if exitStatus != 0 {
            return .failure(.exited(status: exitStatus, stderr: stderr))
        }
        return .failure(stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .emptyOutput
            : .malformedResponse)
    }

    /// The rejection and not-logged-in patterns matched against one piece of CLI text — an
    /// envelope's `result` where the CLI emits one, stderr where it does not. Returns nil when
    /// nothing matches, so the caller falls through to its own less specific answer with the raw
    /// text still intact.
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
