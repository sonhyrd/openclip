import XCTest
@testable import OpenClip
@testable import Core

@MainActor
final class RevealInFinderActionTests: XCTestCase {
    func testPathResolution() {
        let action = RevealInFinderAction()
        
        // Existing path (current working directory)
        let currentDir = FileManager.default.currentDirectoryPath
        let resolved = action.resolvePath(from: currentDir)
        XCTAssertEqual(resolved, currentDir)
        
        // Non-existent path
        let nonExistent = "/non/existent/path/for/unit/test/12345"
        XCTAssertNil(action.resolvePath(from: nonExistent))

        // Existing file (this test source file)
        let existingFile = #filePath
        XCTAssertEqual(action.resolvePath(from: existingFile), existingFile)

        // Compiler error format (:line:col)
        let withLineCol = "\(existingFile):42:15"
        XCTAssertEqual(action.resolvePath(from: withLineCol), existingFile)

        // Single colon line number
        let withLine = "\(existingFile):42"
        XCTAssertEqual(action.resolvePath(from: withLine), existingFile)

        // Quoted paths (ASCII and smart quotes)
        XCTAssertEqual(action.resolvePath(from: "\"\(existingFile)\""), existingFile)
        XCTAssertEqual(action.resolvePath(from: "'\(existingFile)'"), existingFile)
        XCTAssertEqual(action.resolvePath(from: "“\(existingFile)”"), existingFile)

        // Markdown / Bracket wrapped
        XCTAssertEqual(action.resolvePath(from: "<\(existingFile)>"), existingFile)
        XCTAssertEqual(action.resolvePath(from: "(\(existingFile))"), existingFile)

        // Embedded in log line
        let logLine = "Error in \(existingFile):80:15: syntax error"
        XCTAssertEqual(action.resolvePath(from: logLine), existingFile)

        // Trailing sentence punctuation
        XCTAssertEqual(action.resolvePath(from: "Check \(existingFile)."), existingFile)
        XCTAssertEqual(action.resolvePath(from: "See \(existingFile),"), existingFile)

        // file:// URI
        XCTAssertEqual(action.resolvePath(from: "file://\(existingFile)"), existingFile)
    }
    
    func testIsEnabledOnlyForExistingPaths() {
        let action = RevealInFinderAction()
        let currentDir = FileManager.default.currentDirectoryPath
        
        let app = AppIdentity(NSRunningApplication.current)
        let validContext = ActionContext(
            selection: SelectionContext(
                text: currentDir,
                sourceApp: app,
                cursorPosition: .zero,
                selectionBounds: nil,
                timestamp: Date(),
                appPolicy: .default
            ),
            modifiers: []
        )
        
        XCTAssertTrue(action.isEnabled(for: validContext))
        
        let invalidContext = ActionContext(
            selection: SelectionContext(
                text: "Just random text here",
                sourceApp: app,
                cursorPosition: .zero,
                selectionBounds: nil,
                timestamp: Date(),
                appPolicy: .default
            ),
            modifiers: []
        )
        
        XCTAssertFalse(action.isEnabled(for: invalidContext))

        let existingFile = #filePath
        let embeddedValidContext = ActionContext(
            selection: SelectionContext(
                text: "Found error in \(existingFile):10:5",
                sourceApp: app,
                cursorPosition: .zero,
                selectionBounds: nil,
                timestamp: Date(),
                appPolicy: .default
            ),
            modifiers: []
        )
        XCTAssertTrue(action.isEnabled(for: embeddedValidContext))
    }

    /// The visibility pass must never stat inside Desktop/Documents/Downloads: that raises the
    /// macOS TCC consent prompt, attributed to OpenClip, on nothing more than a selection that
    /// happens to mention such a path. A path-shaped candidate there is taken on trust for
    /// visibility and only really stat-ed when the user invokes the action.
    func testVisibilityDoesNotStatProtectedDirectories() {
        let action = RevealInFinderAction()
        let missing = NSHomeDirectory() + "/Desktop/openclip-does-not-exist-\(UUID().uuidString).txt"

        // Visibility pass: enabled without touching the file system.
        XCTAssertEqual(action.resolvePath(from: missing, probingProtectedDirectories: false), missing)
        // Invocation pass: the real stat, and this file really is absent.
        XCTAssertNil(action.resolvePath(from: missing, probingProtectedDirectories: true))
        // Outside the protected folders, the visibility pass still stats and still says no.
        XCTAssertNil(action.resolvePath(from: "/non/existent/path/for/unit/test/12345",
                                        probingProtectedDirectories: false))
    }

    func testProtectedDirectoryMatchingIsPrefixExact() {
        let home = "/Users/tester"
        XCTAssertTrue(RevealInFinderAction.isInProtectedDirectory("\(home)/Desktop/a.txt", home: home))
        XCTAssertTrue(RevealInFinderAction.isInProtectedDirectory("\(home)/Downloads/b/c.txt", home: home))
        // The folder itself is not a file inside it, and a lookalike sibling is not a match.
        XCTAssertFalse(RevealInFinderAction.isInProtectedDirectory("\(home)/Desktop", home: home))
        XCTAssertFalse(RevealInFinderAction.isInProtectedDirectory("\(home)/DesktopStuff/a.txt", home: home))
        XCTAssertFalse(RevealInFinderAction.isInProtectedDirectory("/tmp/Desktop/a.txt", home: home))
    }
}
