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

        private enum CodingKeys: String, CodingKey {
            // Note the mixed casing: the CLI emits `is_error` but `modelUsage`.
            case isError = "is_error"
            case result
            case modelUsage
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            result = try container.decodeIfPresent(String.self, forKey: .result) ?? ""
            modelUsage = try container.decodeIfPresent([String: ModelUsage].self, forKey: .modelUsage)
        }

        public init(isError: Bool, result: String, modelUsage: [String: ModelUsage]? = nil) {
            self.isError = isError
            self.result = result
            self.modelUsage = modelUsage
        }
    }

    /// One entry of the envelope's model-usage map. Every field is optional: a telemetry field that
    /// moves or disappears must never turn a successful transform into a decoding failure.
    public struct ModelUsage: Decodable, Sendable, Equatable {
        public let inputTokens: Int?
        public let outputTokens: Int?

        public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
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

        public init(text: String, modelUsage: ModelUsageOutcome) {
            self.text = text
            self.modelUsage = modelUsage
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
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return String(localized: "Claude Code exited with code \(Int(status)). Run `claude doctor` in Terminal to check your installation.")
                }
                return String(localized: "Claude Code exited with code \(Int(status)): \(detail)")
            case .rejectedInvocation(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return String(localized: "Your Claude Code CLI rejected this request — it is probably out of date. Run `claude update` in Terminal, then try again.")
                }
                return String(localized: "Your Claude Code CLI rejected this request — it is probably out of date. Run `claude update` in Terminal, then try again. Details: \(trimmed)")
            case .notAuthenticated:
                return String(localized: "Claude Code is not logged in. Run `claude login` in Terminal, then try again.")
            case .malformedResponse:
                return String(localized: "Claude Code returned a response OpenClip could not read. Run `claude update` in Terminal, then try again.")
            case .reportedError(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return String(localized: "Claude Code reported an error. Run `claude update` in Terminal, then try again.")
                }
                return String(localized: "Claude Code reported an error: \(trimmed)")
            case .emptyOutput:
                return String(localized: "Claude Code returned an empty response. Try again, or try a shorter selection.")
            }
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

    /// The candidate paths to test, in order — `searchDirectories` with `~` expanded and the binary
    /// name appended. Pure: touches no filesystem, so it is directly assertable in a test.
    public static func diskCandidatePaths(home: String = NSHomeDirectory()) -> [String] {
        searchDirectories.map { directory in
            let expanded = directory.hasPrefix("~/") ? home + String(directory.dropFirst(1)) : directory
            return expanded + "/" + binaryName
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
                return .failure(.reportedError(detail.isEmpty ? stderr : detail))
            }
            let text = envelope.result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(.emptyOutput) }
            // A miss here is data for the caller's log. It cannot produce a failure.
            return .success(Success(text: text, modelUsage: modelUsageOutcome(envelope.modelUsage)))
        }

        let haystack = stderr.lowercased()
        if rejectedInvocationPatterns.contains(where: haystack.contains) {
            return .failure(.rejectedInvocation(stderr))
        }
        if notAuthenticatedPatterns.contains(where: haystack.contains) {
            return .failure(.notAuthenticated)
        }
        if exitStatus != 0 {
            return .failure(.exited(status: exitStatus, stderr: stderr))
        }
        guard stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.malformedResponse)
        }
        return .failure(.emptyOutput)
    }
}
