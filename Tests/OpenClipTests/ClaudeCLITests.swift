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
        let usage = [Self.pinned: ClaudeCLI.ModelUsage(inputTokens: 4, outputTokens: 30)]
        let outcome = ClaudeCLI.modelUsageOutcome(usage)
        XCTAssertEqual(outcome, .matched(ClaudeCLI.ModelUsage(inputTokens: 4, outputTokens: 30)))
        XCTAssertNil(outcome.warning)
    }

    /// The measured realistic case: the pinned model plus a Haiku side-call the CLI makes on its
    /// own. Taking the *first* entry of an unordered dictionary would report a coin flip; reading
    /// by key always finds the pin.
    func testTwoEntryMapStillResolvesThePinnedModelByKey() {
        let usage = [
            "claude-haiku-4-5-20251001": ClaudeCLI.ModelUsage(inputTokens: 1, outputTokens: 2),
            Self.pinned: ClaudeCLI.ModelUsage(inputTokens: 4, outputTokens: 30),
        ]
        XCTAssertEqual(
            ClaudeCLI.modelUsageOutcome(usage),
            .matched(ClaudeCLI.ModelUsage(inputTokens: 4, outputTokens: 30))
        )
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
