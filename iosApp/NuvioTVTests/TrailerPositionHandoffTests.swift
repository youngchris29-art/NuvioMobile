import AVFoundation
import XCTest
@testable import NuvioTV

/// BUG-130 (u/an_angry_Moose, 2026-10-02): the full-screen trailer continues from the Detail
/// background copy's position instead of replaying the seconds already watched.
@MainActor
final class TrailerPositionHandoffTests: XCTestCase {
    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    func testSameStreamResumesOnce() {
        let handoff = TrailerPositionHandoff()
        handoff.record(url: "http://127.0.0.1:8230/a", time: t(6.4), duration: t(150))
        XCTAssertEqual(handoff.take(url: "http://127.0.0.1:8230/a")?.seconds ?? 0, 6.4, accuracy: 0.01)
        XCTAssertNil(handoff.take(url: "http://127.0.0.1:8230/a"), "consumed")
    }

    func testAnotherStreamOrStaleEntryStartsFromZero() {
        let handoff = TrailerPositionHandoff()
        handoff.record(url: "a", time: t(6), duration: t(150))
        XCTAssertNil(handoff.take(url: "b"), "a row clip is a different stream")
        handoff.record(url: "a", time: t(6), duration: t(150))
        XCTAssertNil(handoff.take(url: "a", now: ProcessInfo.processInfo.systemUptime + TrailerPositionHandoff.freshness + 1))
    }

    func testNearTheStartOrTheEndIsNotCarried() {
        XCTAssertFalse(TrailerPositionHandoff.isUsable(time: t(0.4), duration: t(150)))
        XCTAssertFalse(TrailerPositionHandoff.isUsable(time: t(148), duration: t(150)))
        XCTAssertTrue(TrailerPositionHandoff.isUsable(time: t(20), duration: t(150)))
        XCTAssertTrue(TrailerPositionHandoff.isUsable(time: t(20), duration: .indefinite), "unknown duration still carries")
        XCTAssertFalse(TrailerPositionHandoff.isUsable(time: .invalid, duration: nil))
    }

    // MARK: BUG-130 way back (decision AB)

    func testReturnSlotIsIndependentOfTheForwardSlot() {
        XCTAssertFalse(TrailerPositionHandoff.returning === TrailerPositionHandoff.shared)
        let forward = TrailerPositionHandoff()
        let back = TrailerPositionHandoff()
        back.record(url: "a", time: t(12), duration: t(150))
        XCTAssertNil(forward.take(url: "a"), "a return entry is invisible to the forward read")
        forward.record(url: "a", time: t(6), duration: t(150))
        XCTAssertEqual(back.take(url: "a")?.seconds ?? 0, 12, accuracy: 0.01)
        XCTAssertEqual(forward.take(url: "a")?.seconds ?? 0, 6, accuracy: 0.01, "forward carry unchanged")
    }

    func testReturnPositionIsConsumedOnceAndNeverReusedForAnotherTitle() {
        let back = TrailerPositionHandoff()
        back.record(url: "a", time: t(20), duration: t(150))
        XCTAssertNil(back.take(url: "b"), "another title never inherits it")
        XCTAssertNil(back.take(url: "a"), "the failed read for b consumed the entry")
        back.record(url: "a", time: t(20), duration: t(150))
        XCTAssertNotNil(back.take(url: "a"))
        XCTAssertNil(back.take(url: "a"), "consumed once: a later remount (scroll, picker) starts from 0")
    }

    func testReturnPositionHonoursFreshnessAndMargins() {
        let back = TrailerPositionHandoff()
        back.record(url: "a", time: t(20), duration: t(150))
        XCTAssertNil(back.take(url: "a", now: ProcessInfo.processInfo.systemUptime + TrailerPositionHandoff.freshness + 1))
        back.record(url: "a", time: t(20), duration: t(150))
        back.record(url: "a", time: t(149), duration: t(150))
        XCTAssertNil(back.take(url: "a"), "played to the end: the loop starts from 0 and the older entry is cleared")
        back.record(url: "a", time: t(0.5), duration: t(150))
        XCTAssertNil(back.take(url: "a"))
    }
}
