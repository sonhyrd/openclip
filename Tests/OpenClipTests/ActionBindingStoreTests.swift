import XCTest
@testable import Core

@MainActor
final class ActionBindingStoreTests: XCTestCase {
    private var store: MemorySettingsStore!
    private var bindings: ActionBindingStore!

    override func setUp() {
        super.setUp()
        store = MemorySettingsStore()
        bindings = ActionBindingStore(settingsStore: store)
    }

    func testSetAliasNormalizesAndRoundTrips() {
        XCTAssertEqual(bindings.setAlias("  TR  ", for: "builtin.search"), .accepted)
        XCTAssertEqual(bindings.alias(for: "builtin.search"), "tr")
        XCTAssertEqual(bindings.actionID(forAlias: "TR"), "builtin.search")
    }

    func testEmptyAliasClears() {
        _ = bindings.setAlias("tr", for: "builtin.search")
        XCTAssertEqual(bindings.setAlias("   ", for: "builtin.search"), .cleared)
        XCTAssertNil(bindings.alias(for: "builtin.search"))
    }

    func testWhitespaceAndEmptyRejectedAsNewAlias() {
        XCTAssertEqual(bindings.setAlias("t r", for: "builtin.search"), .invalid)
        XCTAssertNil(bindings.alias(for: "builtin.search"))
    }

    func testCollisionRejected() {
        XCTAssertEqual(bindings.setAlias("tr", for: "a.translate"), .accepted)
        XCTAssertEqual(bindings.setAlias("TR", for: "b.tree"), .collision(existingActionID: "a.translate"))
        XCTAssertNil(bindings.alias(for: "b.tree"))
        XCTAssertEqual(bindings.alias(for: "a.translate"), "tr")
    }

    func testSameActionCanResetOwnAlias() {
        _ = bindings.setAlias("tr", for: "a.translate")
        XCTAssertEqual(bindings.setAlias("tr", for: "a.translate"), .accepted)
        XCTAssertEqual(bindings.setAlias("tl", for: "a.translate"), .accepted)
        XCTAssertEqual(bindings.alias(for: "a.translate"), "tl")
    }
}
