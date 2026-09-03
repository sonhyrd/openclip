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
