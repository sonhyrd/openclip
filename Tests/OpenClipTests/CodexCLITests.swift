import XCTest
@testable import Core

final class CodexCLITests: XCTestCase {
    /// One exact literal array — not membership, not a subset, no allowlist. This guard exists to
    /// go red when someone drops `--ephemeral`, `--disable hooks` or `-c mcp_servers={}`, or
    /// loosens `-s read-only`. The model and the directory are the ones passed in, verbatim.
    func testArgumentsAreTheExactIsolatedList() {
        XCTAssertEqual(
            CodexCLI.arguments(prompt: "PAYLOAD", model: "WIRE-ID", workingDirectory: "/tmp/empty"),
            [
                "exec",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--disable", "hooks",
                "--skip-git-repo-check",
                "-s", "read-only",
                "--color", "never",
                "-C", "/tmp/empty",
                "-m", "WIRE-ID",
                "-c", "model_reasoning_effort=\"low\"",
                "-c", "mcp_servers={}",
                "--json",
                "PAYLOAD",
            ]
        )
    }

    func testTheDefaultModelIsAStableLiteralAndTheCatalogCommandIsBare() {
        XCTAssertEqual(CodexCLI.defaultModel, "gpt-5.5")
        // `codex debug models` rejects `--color` (measured), so the listing takes nothing else.
        XCTAssertEqual(CodexCLI.catalogArguments, ["debug", "models"])
    }
}

// MARK: - Child-environment shaping

extension CodexCLITests {
    private static let home = "/Users/someone"
    private static let binary = "/Users/someone/.local/share/mise/installs/node/24/bin/codex"

    /// The list is asserted as a LITERAL, never iterated, so a key cannot be dropped quietly. These
    /// are the names the native codex binary references, `OPENAI_BASE_URL` included (ADR 0002 §4).
    func testEveryRebillingVariableIsRemovedAndCodexHomeSurvives() {
        XCTAssertEqual(CodexCLI.strippedEnvironmentKeys, [
            "OPENAI_API_KEY",
            "OPENAI_BASE_URL",
            "CODEX_API_KEY",
            "CODEX_ACCESS_TOKEN",
            "CODEX_AUTH",
            "CODEX_URL",
        ])
        let hostile = [
            "OPENAI_API_KEY": "sk-whatever",
            "CODEX_API_KEY": "key",
            "CODEX_ACCESS_TOKEN": "token",
            "CODEX_AUTH": "auth",
            "CODEX_URL": "https://not-openai.example.com",
            "CODEX_HOME": "/Users/someone/.codex",
            "PATH": "/usr/bin",
            "HOME": Self.home,
        ]
        let environment = CodexCLI.childEnvironment(inherited: hostile, binaryPath: Self.binary, home: Self.home)
        for key in CodexCLI.strippedEnvironmentKeys {
            XCTAssertNil(environment[key], "\(key) must never reach the child")
        }
        // The subscription login lives under CODEX_HOME; stripping it would log the user out.
        XCTAssertEqual(environment["CODEX_HOME"], "/Users/someone/.codex")
        XCTAssertEqual(environment["HOME"], Self.home)
    }

    func testSearchDirectoriesArePrefixedOntoPATHWithTheInheritedTailPreserved() {
        let environment = CodexCLI.childEnvironment(
            inherited: ["PATH": "/usr/bin:/bin"],
            binaryPath: Self.binary,
            home: Self.home
        )
        XCTAssertEqual(
            (environment["PATH"] ?? "").components(separatedBy: ":"),
            ["/Users/someone/.local/share/mise/installs/node/24/bin"]
                + ClaudeCLI.expandedSearchDirectories(home: Self.home)
                + ["/usr/bin", "/bin"]
        )
    }

    func testDiskCandidatesAreTheSharedDirectoriesWithTheCodexName() {
        XCTAssertEqual(
            ClaudeCLI.diskCandidatePaths(binaryName: "codex", home: Self.home),
            ClaudeCLI.expandedSearchDirectories(home: Self.home).map { $0 + "/codex" }
        )
    }

    func testIsolatedWorkingDirectoryIsAPrivateEmptyFolderDistinctFromClaudes() throws {
        let dir = CodexCLI.isolatedWorkingDirectory()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertNotEqual(dir.standardizedFileURL.path, "/")
        XCTAssertNotEqual(dir.path, ClaudeCLI.isolatedWorkingDirectory().path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}

// MARK: - JSONL classification, from measured fixtures

extension CodexCLITests {
    private static let started = #"{"type":"thread.started","thread_id":"01a074f0"}"# + "\n" + #"{"type":"turn.started"}"#

    private static func agentMessage(_ text: String) -> String {
        #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"\#(text)"}}"#
    }

    /// The measured logged-out run: exit 1, `error` events carrying the 401, tracing on stderr.
    private static let loggedOut401 = #"{"type":"error","message":"Reconnecting... 1/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses)"}"#

    func testALoneAgentMessageWithExitZeroIsASuccessWithItsText() {
        let stdout = Self.started + "\n" + Self.agentMessage("Corrected text.") + "\n" + #"{"type":"turn.completed","usage":{}}"#
        guard case .success(let text) = CodexCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("Expected a success")
        }
        XCTAssertEqual(text, "Corrected text.")
    }

    func testTheLoggedOut401EventClassifiesAsNotAuthenticated() {
        let stderr = "2026-09-06T04:18:20Z ERROR codex_api::endpoint::responses_websocket: failed to connect to websocket: HTTP error: 401 Unauthorized"
        let outcome = failure(CodexCLI.classify(stdout: Self.started + "\n" + Self.loggedOut401, stderr: stderr, exitStatus: 1))
        XCTAssertEqual(outcome, .notAuthenticated)
        XCTAssertTrue(outcome?.message.contains("codex login") == true)
    }

    /// Measured for `-a`: clap rejects the flag on stderr, exit 2, nothing on stdout.
    func testAnUnexpectedArgumentOnStderrIsARejectedInvocation() {
        let stderr = "error: unexpected argument '-a' found\n\n  tip: to pass '-a' as a value, use '-- -a'"
        let outcome = failure(CodexCLI.classify(stdout: "", stderr: stderr, exitStatus: 2))
        XCTAssertEqual(outcome, .rejectedInvocation(stderr))
        XCTAssertTrue(outcome?.message.contains("codex update") == true)
    }

    /// Measured for a wrongly-typed `mcp_servers` override: the config fails to load.
    func testAConfigLoadErrorIsARejectedInvocation() {
        let stderr = "Error loading config.toml: invalid type: string \"bogus\", expected a map\nin `mcp_servers`"
        XCTAssertEqual(failure(CodexCLI.classify(stdout: "", stderr: stderr, exitStatus: 1)), .rejectedInvocation(stderr))
    }

    func testAnErrorEventAfterTheAgentMessageIsAFailureWithItsText() {
        let stdout = Self.agentMessage("Corrected.") + "\n" + #"{"type":"error","message":"stream aborted"}"#
        XCTAssertEqual(failure(CodexCLI.classify(stdout: stdout, stderr: "", exitStatus: 0)), .reportedError("stream aborted"))
    }

    /// The other shape an error takes in `--json`: an `error` item, completed like any other item.
    func testAnErrorItemAfterTheAgentMessageIsAFailureWithItsText() {
        let stdout = Self.agentMessage("Corrected.") + "\n" + #"{"type":"item.completed","item":{"id":"item_2","type":"error","message":"turn aborted"}}"#
        XCTAssertEqual(failure(CodexCLI.classify(stdout: stdout, stderr: "", exitStatus: 0)), .reportedError("turn aborted"))
    }

    /// A transport retry that then succeeded is not a failed transform: the text arrived.
    func testAnErrorEventBeforeTheAgentMessageDoesNotFailTheTransform() {
        let stdout = #"{"type":"error","message":"Reconnecting... 1/5 (websocket)"}"# + "\n" + Self.agentMessage("Corrected.")
        guard case .success(let text) = CodexCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("A retry the CLI recovered from must not withhold the text")
        }
        XCTAssertEqual(text, "Corrected.")
    }

    /// The model's own words must never classify the run.
    func testAnAgentMessageMentioning401IsStillASuccess() {
        let stdout = Self.agentMessage("The status was 401 unauthorized, not logged in.")
        guard case .success = CodexCLI.classify(stdout: stdout, stderr: "", exitStatus: 0) else {
            return XCTFail("Patterns match error events and stderr only")
        }
    }

    func testStdoutThatIsNotAnEventAtAllIsMalformed() {
        XCTAssertEqual(failure(CodexCLI.classify(stdout: "just prose", stderr: "", exitStatus: 0)), .malformedResponse)
    }

    func testEventsWithNoAgentMessageAreEmptyOutput() {
        XCTAssertEqual(failure(CodexCLI.classify(stdout: Self.started, stderr: "", exitStatus: 0)), .emptyOutput)
        XCTAssertEqual(failure(CodexCLI.classify(stdout: Self.agentMessage("   "), stderr: "", exitStatus: 0)), .emptyOutput)
    }

    func testAnUnrecognisedNonZeroExitFallsThroughWithStderrVisible() {
        let outcome = failure(CodexCLI.classify(stdout: "", stderr: "some novel failure", exitStatus: 7))
        XCTAssertEqual(outcome, .exited(status: 7, stderr: "some novel failure"))
        XCTAssertTrue(outcome?.message.contains("some novel failure") == true)
    }

    func testEveryFailureCarriesAnActionableMessage() {
        let cases: [CodexCLI.Failure] = [
            .notFound, .launchFailed("permission denied"), .timedOut(seconds: 60), .exited(status: 2, stderr: ""),
            .rejectedInvocation("nope"), .notAuthenticated, .malformedResponse, .reportedError(""), .emptyOutput,
        ]
        XCTAssertEqual(cases.count, 9)
        for failure in cases {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no message")
            XCTAssertEqual(failure.errorDescription, failure.message)
        }
    }
}

// MARK: - The catalog, from the measured `codex debug models` output

extension CodexCLITests {
    /// Cut from codex-cli 0.153.4 on 2026-09-06: six listed, five hidden.
    private static let catalogFixture = "{\"models\": [{\"slug\": \"gpt-6-astra\", \"display_name\": \"GPT-6-Astra\", \"visibility\": \"list\"}, {\"slug\": \"gpt-5.6-sol\", \"display_name\": \"GPT-5.6-Sol\", \"visibility\": \"list\"}, {\"slug\": \"gpt-5.6-terra\", \"display_name\": \"GPT-5.6-Terra\", \"visibility\": \"list\"}, {\"slug\": \"gpt-5.6-luna\", \"display_name\": \"GPT-5.6-Luna\", \"visibility\": \"list\"}, {\"slug\": \"gpt-daybreak-blue-latest\", \"display_name\": \"Daybreak Blue\", \"visibility\": \"hide\"}, {\"slug\": \"gpt-daybreak-red-latest\", \"display_name\": \"Daybreak Red\", \"visibility\": \"hide\"}, {\"slug\": \"gpt-5.5\", \"display_name\": \"GPT-5.5\", \"visibility\": \"list\"}, {\"slug\": \"gpt-5.4\", \"display_name\": \"GPT-5.4\", \"visibility\": \"hide\"}, {\"slug\": \"gpt-5.4-mini\", \"display_name\": \"GPT-5.4-Mini\", \"visibility\": \"hide\"}, {\"slug\": \"gpt-5.2\", \"display_name\": \"GPT-5.2\", \"visibility\": \"list\"}, {\"slug\": \"codex-auto-review\", \"display_name\": \"Codex Auto Review\", \"visibility\": \"hide\"}]}"

    func testTheCatalogKeepsListedEntriesAndDropsHiddenOnes() {
        let models = CodexCLI.decodeCatalog(stdout: Self.catalogFixture)
        XCTAssertEqual(models?.map(\.wireID), ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.2"])
        XCTAssertEqual(models?.first?.displayName, "GPT-6-Astra")
        XCTAssertTrue(models?.contains { $0.wireID == CodexCLI.defaultModel } == true, "The default must be a listed model")
    }

    func testTheCatalogIsFoundInsideSurroundingNoise() {
        XCTAssertEqual(CodexCLI.decodeCatalog(stdout: "warning: something\n" + Self.catalogFixture + "\ntrailing")?.count, 6)
    }

    func testStdoutThatIsNotACatalogIsNil() {
        XCTAssertNil(CodexCLI.decodeCatalog(stdout: "Not logged in"))
        XCTAssertNil(CodexCLI.decodeCatalog(stdout: ""))
    }

    func testDisplayNameFallsBackToTheWireIdBeforeTheCatalogLoads() {
        let models = CodexCLI.decodeCatalog(stdout: Self.catalogFixture) ?? []
        XCTAssertEqual(CodexCLI.displayName(for: "gpt-5.5", in: models), "GPT-5.5")
        XCTAssertEqual(CodexCLI.displayName(for: "gpt-5.5", in: []), "gpt-5.5")
    }
}

extension CodexCLITests {
    fileprivate func failure(_ result: Result<String, CodexCLI.Failure>) -> CodexCLI.Failure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }
}
