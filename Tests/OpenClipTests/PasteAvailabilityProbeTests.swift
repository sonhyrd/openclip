import XCTest
import AppKit
@testable import Core
@testable import OpenClip

/// Tests the menu-item classification used by `PasteAvailabilityProbe`. The probe's decision
/// logic is exercised with plain AX attribute values so a non-English menu can be covered
/// without spawning a live AX session.
final class PasteAvailabilityProbeTests: XCTestCase {

    func testPasteMatchByNonEnglishTitle_WhenNoCommandEquivalent() {
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "Coller", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "Einfügen", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "Pegar", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "уметни", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "umetni", cmdChar: nil, cmdCharModifiers: nil))
    }

    func testPasteMatchByCJKTitle() {
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "粘贴", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "붙여넣기", cmdChar: nil, cmdCharModifiers: nil))
    }

    func testPasteMatchByCommandEquivalent_IndependentlyOfTitle() {
        // Additional modifiers like Shift should be rejected
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(
            title: "포함", cmdChar: "V", cmdCharModifiers: UInt(AXMenuItemModifiers.shift.rawValue)))
        // Zero modifiers matches regardless of casing
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(
            title: nil, cmdChar: "V", cmdCharModifiers: UInt(AXMenuItemModifiers().rawValue)))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(
            title: nil, cmdChar: "v", cmdCharModifiers: 0))
    }

    func testCopyMatchesCaseInsensitivelyAndRejectsExtraModifiers() {
        XCTAssertTrue(AXMenuNavigator.matches(.copy, title: nil, identifier: nil, cmdChar: "C", cmdModifiers: 0))
        XCTAssertTrue(AXMenuNavigator.matches(.copy, title: nil, identifier: nil, cmdChar: "c", cmdModifiers: 0))
        XCTAssertFalse(AXMenuNavigator.matches(.copy, title: nil, identifier: nil, cmdChar: "C", cmdModifiers: UInt(AXMenuItemModifiers.shift.rawValue)))
        XCTAssertFalse(AXMenuNavigator.matches(.copy, title: nil, identifier: nil, cmdChar: "C", cmdModifiers: UInt(AXMenuItemModifiers.option.rawValue)))
        XCTAssertFalse(AXMenuNavigator.matches(.copy, title: nil, identifier: nil, cmdChar: "C", cmdModifiers: UInt(AXMenuItemModifiers.control.rawValue)))
        XCTAssertFalse(AXMenuNavigator.matches(.copy, title: nil, identifier: nil, cmdChar: "C", cmdModifiers: UInt(AXMenuItemModifiers.noCommand.rawValue)))
    }

    func testNonPasteItemsAreRejected() {
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(title: "Copier", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(title: "Copy", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(title: nil, cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(
            title: "Cut", cmdChar: "X", cmdCharModifiers: UInt(AXMenuItemModifiers.control.rawValue)))
    }

    func testNonCommandModifierTokenIsRejected() {
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(
            title: nil, cmdChar: "V", cmdCharModifiers: UInt(AXMenuItemModifiers.noCommand.rawValue)))
    }

    func testFindMenuItemRespectsExpiredDeadline() {
        let expiredDeadline = Date().addingTimeInterval(-1.0)
        let result = AXMenuNavigator.findMenuItem(.paste, in: nil, deadline: expiredDeadline)
        XCTAssertNil(result, "An expired deadline must immediately yield nil without searching")
    }

    func testDeadlineAwareLookupReceivesDeadline() async {
        let deadlineReceived = expectation(description: "deadline received by lookup")
        let probe = PasteAvailabilityProbe(
            lookupWithDeadline: { pid, deadline in
                XCTAssertEqual(pid, 42)
                XCTAssertNotNil(deadline)
                if let deadline {
                    XCTAssertGreaterThan(deadline, Date())
                }
                deadlineReceived.fulfill()
                return true
            },
            timeout: 0.5
        )
        let result = await probe.probePaste(pid: 42)
        XCTAssertEqual(result, true)
        await fulfillment(of: [deadlineReceived], timeout: 1.0)
    }
}

/// This class covers issue #37. A blocked lookup must not stop later probes.
/// Tests replace the lookup with a semaphore. They do not need Accessibility.
///
/// `probeGate` is shared in the process. Each test releases its held workers.
/// Permits are released after the wait ends. Assertions allow 0.1 s for that delay.
final class PasteAvailabilityProbeGateTests: XCTestCase {

    private static let shortTimeout: TimeInterval = 0.1

    /// The caller must get unknown at the time limit. It must not wait for the held lookup.
    func testHungLookupReportsUnknownAtDeadlineWithoutWaitingForWorker() async {
        let unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() } // Release the held worker.
        let probe = PasteAvailabilityProbe(
            lookup: { _ in unblock.wait(); return true },
            timeout: Self.shortTimeout
        )

        let start = Date()
        let result = await probe.probePaste(pid: 1)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "watchdog must report unknown while the lookup is still blocked")
        XCTAssertGreaterThanOrEqual(elapsed, Self.shortTimeout - 0.02)
        XCTAssertLessThan(elapsed, 1.0, "the caller must resume at the deadline, not when the worker returns")
    }

    /// A new probe must start while a held worker is still blocked. The queue must be concurrent.
    func testFreshProbeRunsWhileAbandonedWorkerIsStillParked() async {
        let unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() }
        let hungProbe = PasteAvailabilityProbe(
            lookup: { _ in unblock.wait(); return true },
            timeout: Self.shortTimeout
        )
        let hung = await hungProbe.probePaste(pid: 1)
        XCTAssertNil(hung)

        let freshProbe = PasteAvailabilityProbe(lookup: { _ in true }, timeout: 1.0)
        let start = Date()
        let fresh = await freshProbe.probePaste(pid: 2)
        XCTAssertEqual(fresh, true, "a fresh probe must get a real answer, not unknown")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3,
                          "a fresh probe must not queue behind the abandoned worker")
    }

    /// When the gate is full, a new probe must fail immediately.
    /// After the time limit, the gate must work again while the workers stay blocked.
    func testSaturatedGateFailsFastThenRecoversAtDeadlineWhileWorkersStillHung() async {
        let limit = Constants.pasteProbeMaxConcurrent
        let started = expectation(description: "cap-filling lookups started")
        started.expectedFulfillmentCount = limit
        started.assertForOverFulfill = true
        let unblock = DispatchSemaphore(value: 0)
        defer { for _ in 0..<limit { unblock.signal() } }

        let hungProbe = PasteAvailabilityProbe(
            lookup: { _ in
                started.fulfill()
                unblock.wait()
                return true
            },
            timeout: 0.5
        )

        var parked: [Task<Bool?, Never>] = []
        for _ in 0..<limit {
            parked.append(Task { await hungProbe.probePaste(pid: 1) })
        }
        await fulfillment(of: [started], timeout: 2.0)

        let overflowProbe = PasteAvailabilityProbe(
            lookup: { _ in XCTFail("a saturated gate must not start another lookup"); return true },
            timeout: Self.shortTimeout
        )
        let overflowStart = Date()
        let overflow = await overflowProbe.probePaste(pid: 1)
        XCTAssertNil(overflow, "saturated gate must report unknown")
        XCTAssertLessThan(Date().timeIntervalSince(overflowStart), 0.3, "overflow must fail fast, not queue")

        for task in parked {
            let parkedResult = await task.value
            XCTAssertNil(parkedResult, "parked probes must report unknown at the deadline")
        }
        try? await Task.sleep(nanoseconds: 100_000_000) // Wait for the detached release.

        // Before the change, the blocked worker kept the permit.
        let freshProbe = PasteAvailabilityProbe(lookup: { _ in false }, timeout: 1.0)
        let freshStart = Date()
        let fresh = await freshProbe.probePaste(pid: 1)
        XCTAssertEqual(fresh, false, "permits must be free again after the deadline")
        XCTAssertLessThan(Date().timeIntervalSince(freshStart), 0.3,
                          "a fresh probe must not wait behind abandoned workers")
    }

    /// A completed lookup must release its permit. Later lookups must get their real result.
    func testCompletedLookupsReleasePermitsAndPropagateResults() async {
        let answers: [Bool?] = [true, false, nil, true, false, nil]
        XCTAssertGreaterThan(answers.count, Constants.pasteProbeMaxConcurrent)
        for expected in answers {
            let probe = PasteAvailabilityProbe(lookup: { _ in expected }, timeout: 1.0)
            let start = Date()
            let result = await probe.probePaste(pid: 1)
            XCTAssertEqual(result, expected)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "a fast lookup must not wait for the watchdog")
            try? await Task.sleep(nanoseconds: 50_000_000) // Wait for the permit release.
        }
    }
}