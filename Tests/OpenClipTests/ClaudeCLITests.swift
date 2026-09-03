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
