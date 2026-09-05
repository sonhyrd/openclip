import XCTest
@testable import Core

final class ClaudeCLITests: XCTestCase {
    /// One exact literal array — not membership, not a subset, no allowlist. This guard exists to
    /// go red when someone drops `--strict-mcp-config` or loosens `--tools ""`, and to pin the
    /// dated model identifier against a floating alias.
    func testArgumentsAreTheExactIsolatedList() {
        XCTAssertEqual(
            ClaudeCLI.arguments(prompt: "PAYLOAD"),
            [
                "-p", "PAYLOAD",
                "--max-turns", "1",
                "--model", "claude-sonnet-4-5-20250929",
                "--setting-sources", "",
                "--tools", "",
                "--strict-mcp-config",
                "--no-session-persistence",
                "--system-prompt", "You are an inline text transformation tool. Output only the transformed text.",
                "--output-format", "json",
            ]
        )
    }
}

// MARK: - Envelope parsing

extension ClaudeCLITests {
    private static let pinned = "claude-sonnet-4-5-20250929"

    /// Builds an envelope the way the CLI does — including `subtype`, which nothing may branch on.
    private func envelopeJSON(
        isError: Bool,
        subtype: String = "success",
        result: String,
        modelUsage: String? = nil
    ) -> String {
        let usage = modelUsage.map { ",\"modelUsage\":\($0)" } ?? ""
        return """
        {"type":"result","subtype":"\(subtype)","is_error":\(isError),"duration_ms":1866,\
        "num_turns":1,"result":"\(result)","session_id":"abc"\(usage)}
        """
    }

    func testWellFormedResponseIsASuccess() {
        let stdout = envelopeJSON(isError: false, result: "<result>Corrected text.</result>")
        guard case .success(let success) = ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("Expected a success")
        }
        XCTAssertEqual(success.text, "<result>Corrected text.</result>")
    }

    /// The CLI is not the only thing that can write to stdout — a node warning or a shell banner
    /// must not make an otherwise perfect envelope unreadable.
    func testEnvelopeIsFoundInsideSurroundingNoise() {
        let stdout = """
        (node:123) ExperimentalWarning: something
        \(envelopeJSON(isError: false, result: "Hello"))
        trailing chatter
        """
        guard case .success(let success) = ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("Expected a success")
        }
        XCTAssertEqual(success.text, "Hello")
    }

    /// `malformedResponse` is for stdout that is not an envelope AT ALL — never for a field inside
    /// a valid one.
    func testStdoutThatIsNotAnEnvelopeIsMalformed() {
        XCTAssertEqual(
            failure(ClaudeCLI.classify(stdout: "just some prose, no JSON here", stderr: "", exitStatus: 0)),
            .malformedResponse
        )
    }

    /// The measured bad-model run: exit 1, a complete parseable envelope, `is_error: true` and
    /// `subtype: "success"`. The envelope is classified before the exit code, so the CLI's own
    /// human-readable explanation survives instead of being buried in a generic `.exited`.
    func testErrorFlagWinsOverSubtypeSayingSuccess() {
        let stdout = envelopeJSON(
            isError: true,
            subtype: "success",
            result: "API Error: 404 model: bogus-model-id"
        )
        let outcome = failure(ClaudeCLI.classify(stdout: stdout, stderr: "[claude-code:unrecognized_model] {}", exitStatus: 1))
        XCTAssertEqual(outcome, .reportedError("API Error: 404 model: bogus-model-id"))
        XCTAssertTrue(outcome?.message.contains("404") == true, "The CLI's explanation must reach the user")
    }

    func testNonErrorEnvelopeWithNoTextIsEmptyOutput() {
        XCTAssertEqual(
            failure(ClaudeCLI.classify(stdout: envelopeJSON(isError: false, result: "   "), stderr: "", exitStatus: 0)),
            .emptyOutput
        )
    }
}

// MARK: - Failure classification from stderr and exit code

extension ClaudeCLITests {
    /// The form the installed CLI actually emits. The upstream's patterns are all space-separated
    /// and none of them match this.
    func testUnderscoredModelRejection() {
        let stderr = "[claude-code:unrecognized_model] {\"model\":\"claude-nope\"}"
        let outcome = failure(ClaudeCLI.classify(stdout: "", stderr: stderr, exitStatus: 1))
        XCTAssertEqual(outcome, .rejectedInvocation(stderr))
        XCTAssertTrue(outcome?.message.contains("claude update") == true)
    }

    func testUnknownOptionRejection() {
        let stderr = "error: unknown option '--no-session-persistence'"
        XCTAssertEqual(
            failure(ClaudeCLI.classify(stdout: "", stderr: stderr, exitStatus: 1)),
            .rejectedInvocation(stderr)
        )
    }

    func testNotAuthenticatedStderr() {
        let outcome = failure(ClaudeCLI.classify(stdout: "", stderr: "Not logged in. Please run claude login.", exitStatus: 1))
        XCTAssertEqual(outcome, .notAuthenticated)
        XCTAssertTrue(outcome?.message.contains("claude login") == true)
    }

    /// The CLI's documented failure path is an `is_error: true` envelope, NOT a parse failure — so
    /// the patterns are matched against the envelope's own `result` too. Consulting them only when
    /// stdout fails to parse made `.notAuthenticated` unreachable on the one path it was written
    /// for, and told a logged-out user to run `claude update`.
    func testNotAuthenticatedIsFoundInsideAnErrorEnvelope() {
        let stdout = #"{"is_error":true,"result":"Invalid API key · Please run /login"}"#
        let outcome = failure(ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 1))
        XCTAssertEqual(outcome, .notAuthenticated)
        XCTAssertTrue(outcome?.message.contains("claude login") == true)
    }

    func testRejectedInvocationIsFoundInsideAnErrorEnvelope() {
        let stdout = #"{"is_error":true,"result":"unrecognized_model: claude-nope","subtype":"success"}"#
        let outcome = failure(ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 1))
        XCTAssertEqual(outcome, .rejectedInvocation("unrecognized_model: claude-nope"))
        XCTAssertTrue(outcome?.message.contains("claude update") == true)
    }

    /// An error envelope carrying nothing a pattern recognises still lands on `.reportedError`
    /// with its text intact — the fallback did not move.
    func testUnrecognisedErrorEnvelopeStillReportsItsOwnText() {
        let stdout = #"{"is_error":true,"result":"some novel failure nobody has a pattern for"}"#
        let outcome = failure(ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 1))
        XCTAssertEqual(outcome, .reportedError("some novel failure nobody has a pattern for"))
    }

    /// Anything unmatched falls through to the generic case **with the raw stderr still visible**,
    /// so a novel failure is still actionable rather than opaque.
    func testUnrecognisedNonZeroExitFallsThroughWithStderrVisible() {
        let stderr = "some novel failure nobody has a pattern for"
        let outcome = failure(ClaudeCLI.classify(stdout: "", stderr: stderr, exitStatus: 7))
        XCTAssertEqual(outcome, .exited(status: 7, stderr: stderr))
        XCTAssertTrue(outcome?.message.contains(stderr) == true, "Raw stderr must reach the user")
        XCTAssertTrue(outcome?.message.contains("7") == true)
    }

    func testEveryFailureCarriesAnActionableMessage() {
        let cases: [ClaudeCLI.Failure] = [
            .notFound,
            .launchFailed("permission denied"),
            .timedOut(seconds: 30),
            .exited(status: 2, stderr: ""),
            .rejectedInvocation("nope"),
            .notAuthenticated,
            .malformedResponse,
            .reportedError(""),
            .emptyOutput,
        ]
        XCTAssertEqual(cases.count, 9)
        for failure in cases {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no message")
            XCTAssertEqual(failure.errorDescription, failure.message)
        }
    }
}

// MARK: - The keyed model lookup (log-only, never fatal)

extension ClaudeCLITests {
    func testModelUsageIsReadByKeyWhenPresent() {
        let outcome = ClaudeCLI.modelUsageOutcome([Self.pinned: ClaudeCLI.ModelUsage()])
        XCTAssertEqual(outcome, .matched(ClaudeCLI.ModelUsage()))
        XCTAssertNil(outcome.warning)
    }

    /// The measured realistic case: the pinned model plus a Haiku side-call the CLI makes on its
    /// own. Taking the *first* entry of an unordered dictionary would report a coin flip; reading
    /// by key always finds the pin.
    func testTwoEntryMapStillResolvesThePinnedModelByKey() {
        let usage = [
            "claude-haiku-4-5-20251001": ClaudeCLI.ModelUsage(),
            Self.pinned: ClaudeCLI.ModelUsage(),
        ]
        guard case .matched = ClaudeCLI.modelUsageOutcome(usage) else {
            return XCTFail("Reading by key must find the pin regardless of dictionary order")
        }
    }

    func testAbsentModelUsageReportsWhatWasThereInsteadOfFailing() {
        let outcome = ClaudeCLI.modelUsageOutcome(["claude-haiku-4-5-20251001": ClaudeCLI.ModelUsage()])
        XCTAssertEqual(outcome, .unexpected(reportedModels: ["claude-haiku-4-5-20251001"]))
        XCTAssertNotNil(outcome.warning, "The caller needs something to log")
        XCTAssertEqual(ClaudeCLI.modelUsageOutcome(nil), .unexpected(reportedModels: []))
    }

    /// The severity rule, asserted directly: the transform succeeded and the corrected text is in
    /// hand, so a moved telemetry field must never withhold it from the user.
    func testAbsentModelUsageStillReturnsTheTransformedText() {
        let stdout = envelopeJSON(
            isError: false,
            result: "Corrected text.",
            modelUsage: "{\"some-other-model\":{\"inputTokens\":1,\"outputTokens\":2}}"
        )
        guard case .success(let success) = ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("A missing model-usage entry must never be a failure")
        }
        XCTAssertEqual(success.text, "Corrected text.")
        XCTAssertEqual(success.modelUsage, .unexpected(reportedModels: ["some-other-model"]))
    }

    /// `usage.output_tokens_details.thinking_tokens`, as measured against CLI 2.1.259. The
    /// provider logs it to confirm `MAX_THINKING_TOKENS=0` actually took effect.
    func testThinkingTokensAreDecodedFromTheUsageBlock() {
        let stdout = """
        {"is_error":false,"result":"Corrected text.",\
        "usage":{"output_tokens":9,"output_tokens_details":{"thinking_tokens":0}}}
        """
        guard case .success(let success) = ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("Expected a success")
        }
        XCTAssertEqual(success.thinkingTokens, 0)
    }

    /// A usage block that moved or changed shape is a telemetry loss, never a failed transform.
    func testAReshapedUsageBlockLosesOnlyTheTokenCount() {
        let stdout = #"{"is_error":false,"result":"Corrected text.","usage":"moved"}"#
        guard case .success(let success) = ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("A reshaped usage block must never be a failure")
        }
        XCTAssertEqual(success.text, "Corrected text.")
        XCTAssertNil(success.thinkingTokens)
    }

    func testMissingModelUsageMapEntirelyIsStillASuccess() {
        let stdout = envelopeJSON(isError: false, result: "Corrected text.")
        guard case .success(let success) = ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("A missing model-usage map must never be a failure")
        }
        XCTAssertEqual(success.modelUsage, .unexpected(reportedModels: []))
    }
}

// MARK: - Binary resolution (pure parts)

extension ClaudeCLITests {
    /// Ratified: a missing or unexpected `modelUsage` entry is logged, never fatal. That promise
    /// was one strict `try` away from being false — a `modelUsage` of a shape the decoder refuses
    /// used to throw out of `init(from:)`, take `parseEnvelope` to nil, and discard a perfectly
    /// good transform as `.malformedResponse`.
    func testAModelUsageOfTheWrongShapeStillReturnsTheTransformedText() {
        let stdout = #"{"is_error":false,"result":"Corrected.","modelUsage":["not","a","map"]}"#
        guard case .success(let success) = ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("A reshaped telemetry field must never withhold the transformed text")
        }
        XCTAssertEqual(success.text, "Corrected.")
        XCTAssertEqual(success.modelUsage, .unexpected(reportedModels: []))
    }

    /// The empty `ModelUsage` struct decodes no fields, so it absorbs whatever the value turns
    /// into — a number here — and presence-by-key still resolves. This is the mechanism that makes
    /// the ratified guarantee structural rather than a promise in a comment.
    func testANumericModelUsageValueStillMatchesByKey() {
        let stdout = #"{"is_error":false,"result":"Corrected.","modelUsage":{"claude-sonnet-4-5-20250929":123}}"#
        guard case .success(let success) = ClaudeCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("Expected a success")
        }
        XCTAssertEqual(success.modelUsage, .matched(ClaudeCLI.ModelUsage()))
    }

    func testLoggedModelRendersFromTheOutcomesOwnPayload() {
        XCTAssertEqual(ClaudeCLI.ModelUsageOutcome.matched(ClaudeCLI.ModelUsage()).loggedModel, ClaudeCLI.model)
        XCTAssertEqual(ClaudeCLI.ModelUsageOutcome.unexpected(reportedModels: []).loggedModel, "unreported")
        XCTAssertEqual(ClaudeCLI.ModelUsageOutcome.unexpected(reportedModels: ["a", "b"]).loggedModel, "a, b")
    }
}

extension ClaudeCLITests {
    func testDiskCandidatesExpandTildeAndAppendTheBinaryName() {
        let candidates = ClaudeCLI.diskCandidatePaths(home: "/Users/tester")
        XCTAssertEqual(candidates.first, "/Users/tester/.claude/local/claude")
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/claude"))
        XCTAssertTrue(candidates.allSatisfy { $0.hasPrefix("/") && $0.hasSuffix("/claude") })
        XCTAssertFalse(candidates.contains { $0.contains("~") })
    }

    func testAnExecutableFileIsUsable() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("claude").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                                                     attributes: [.posixPermissions: 0o755]))
        XCTAssertTrue(ClaudeCLI.isUsableBinary(atPath: path))
    }

    func testANonExecutableFileADirectoryAndARelativePathAreAllRejected() throws {
        let directory = try makeTemporaryDirectory()
        // `command -v` reporting a shell function or alias name rather than a path.
        XCTAssertFalse(ClaudeCLI.isUsableBinary(atPath: "claude"))
        XCTAssertFalse(ClaudeCLI.isUsableBinary(atPath: "/nonexistent/claude"))
        // A directory literally named `claude` must not be spawned.
        XCTAssertFalse(ClaudeCLI.isUsableBinary(atPath: directory.path))

        let plainFile = directory.appendingPathComponent("claude").path
        XCTAssertTrue(FileManager.default.createFile(atPath: plainFile, contents: Data(),
                                                    attributes: [.posixPermissions: 0o644]))
        XCTAssertFalse(ClaudeCLI.isUsableBinary(atPath: plainFile))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

extension ClaudeCLITests {
    /// Unwraps the failure half of a classification, or nil.
    fileprivate func failure(_ result: Result<ClaudeCLI.Success, ClaudeCLI.Failure>) -> ClaudeCLI.Failure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }
}


// MARK: - Child-environment shaping

extension ClaudeCLITests {
    private static let home = "/Users/someone"
    private static let binary = "/Users/someone/.claude/local/claude"

    /// User story 4: an API key on the machine would shadow the subscription login and quietly bill
    /// an organisation. Both credential variables go, even when the inherited environment has them.
    func testBothCredentialVariablesAreRemovedEvenWhenInherited() {
        let environment = ClaudeCLI.childEnvironment(
            inherited: [
                "ANTHROPIC_API_KEY": "sk-ant-whatever",
                "ANTHROPIC_AUTH_TOKEN": "token",
                "PATH": "/usr/bin",
            ],
            binaryPath: Self.binary,
            home: Self.home
        )
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_AUTH_TOKEN"])
    }

    /// Stripping the two credentials while letting the rest of the environment through leaves the
    /// door open on every invariant the credential strip exists to protect: Bedrock/Vertex re-bill
    /// the run away from the subscription, a base URL sends the user's selected text somewhere else
    /// entirely, and the model variables compete with the dated pin. Every key in the list goes,
    /// and this test is what stops one being dropped from it quietly.
    func testEveryRedirectingOrRebillingVariableIsRemoved() {
        let hostile = [
            "ANTHROPIC_API_KEY": "sk-ant-whatever",
            "ANTHROPIC_AUTH_TOKEN": "token",
            "ANTHROPIC_BASE_URL": "https://not-anthropic.example.com",
            "ANTHROPIC_CUSTOM_HEADERS": "X-Exfil: yes",
            "ANTHROPIC_MODEL": "claude-something-else",
            "ANTHROPIC_SMALL_FAST_MODEL": "claude-something-cheaper",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "PATH": "/usr/bin",
            "HOME": Self.home,
        ]
        let environment = ClaudeCLI.childEnvironment(
            inherited: hostile,
            binaryPath: Self.binary,
            home: Self.home
        )
        // The list is asserted as a LITERAL, not iterated. Looping over
        // `ClaudeCLI.strippedEnvironmentKeys` would delete its own assertion along with any key
        // someone removed from it — a test that goes green by shrinking is the exact failure the
        // flag-list guard exists to prevent, and it belongs here for the same reason.
        XCTAssertEqual(ClaudeCLI.strippedEnvironmentKeys, [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_CUSTOM_HEADERS",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
        ])
        for key in hostile.keys where key != "PATH" && key != "HOME" {
            XCTAssertNil(environment[key], "\(key) must never reach the child")
        }
        // Everything else is still inherited: this is a strip list, not an allow list.
        XCTAssertEqual(environment["HOME"], Self.home)
    }

    func testThinkingTokensAreDisabled() {
        let environment = ClaudeCLI.childEnvironment(inherited: [:], binaryPath: Self.binary, home: Self.home)
        XCTAssertEqual(environment["MAX_THINKING_TOKENS"], "0")
    }

    /// A GUI app launched from Finder inherits a minimal PATH, so the search directories are
    /// prefixed — with the binary's own directory first (a version-managed install keeps its node
    /// runtime beside it) and whatever we did inherit preserved as the tail.
    func testSearchDirectoriesArePrefixedOntoPATHWithTheInheritedTailPreserved() {
        let environment = ClaudeCLI.childEnvironment(
            inherited: ["PATH": "/usr/bin:/bin"],
            binaryPath: Self.binary,
            home: Self.home
        )
        let entries = (environment["PATH"] ?? "").components(separatedBy: ":")
        XCTAssertEqual(entries.first, "/Users/someone/.claude/local", "The binary's own directory goes first")
        XCTAssertEqual(
            entries,
            ["/Users/someone/.claude/local"]
                + ClaudeCLI.expandedSearchDirectories(home: Self.home)
                + ["/usr/bin", "/bin"]
        )
    }

    /// One expansion, used by both the disk candidates and the child PATH — two would be free to
    /// disagree (`NSHomeDirectory()` vs `$HOME`).
    func testTildeExpansionIsSharedWithTheDiskCandidates() {
        XCTAssertEqual(
            ClaudeCLI.diskCandidatePaths(home: Self.home),
            ClaudeCLI.expandedSearchDirectories(home: Self.home).map { $0 + "/" + ClaudeCLI.binaryName }
        )
        XCTAssertFalse(ClaudeCLI.expandedSearchDirectories(home: Self.home).contains { $0.contains("~") })
    }
}

// MARK: - Working directory

extension ClaudeCLITests {
    /// The child must never inherit OpenClip's cwd (`/` when Finder-launched): Claude Code walks its
    /// working directory at startup, and from `/` that crawl reaches `~/Desktop`, `~/Documents` and
    /// `~/Downloads` — one macOS consent prompt each, attributed to OpenClip.
    func testIsolatedWorkingDirectoryIsAPrivateEmptyFolderNotRoot() throws {
        let dir = ClaudeCLI.isolatedWorkingDirectory()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertNotEqual(dir.standardizedFileURL.path, "/")
        XCTAssertFalse(dir.path.hasPrefix(NSHomeDirectory() + "/Desktop"))
        XCTAssertFalse(dir.path.hasPrefix(NSHomeDirectory() + "/Documents"))
        XCTAssertFalse(dir.path.hasPrefix(NSHomeDirectory() + "/Downloads"))
        // Empty: nothing for the CLI's directory walk to find.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
