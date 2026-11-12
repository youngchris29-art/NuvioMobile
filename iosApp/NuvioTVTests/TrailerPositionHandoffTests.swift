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

    // MARK: BUG-130 way back (decision AB, review r1 P2): scoped to the presenting Detail visit

    private let visit = UUID()
    private let otherVisit = UUID()

    func testDecideTakesTheSameVisitsImmediateReturn() {
        XCTAssertEqual(TrailerReturnHandoff.decide(entryVisit: visit, entryURL: "a", age: 0.4, heroVisit: visit, heroURL: "a"), .take)
        XCTAssertEqual(TrailerReturnHandoff.decide(entryVisit: visit, entryURL: "a", age: TrailerReturnHandoff.window, heroVisit: visit, heroURL: "a"), .take)
    }

    func testDecideRefusesAnotherVisitOfTheSameTitleAndURL() {
        XCTAssertEqual(TrailerReturnHandoff.decide(entryVisit: visit, entryURL: "a", age: 0.1, heroVisit: otherVisit, heroURL: "a"), .dropOtherVisit)
        XCTAssertEqual(TrailerReturnHandoff.decide(entryVisit: visit, entryURL: "a", age: 0.1, heroVisit: nil, heroURL: "a"), .dropOtherVisit, "a hero with no visit token never takes")
    }

    func testDecideRefusesAnotherStreamAndAnElapsedWindow() {
        XCTAssertEqual(TrailerReturnHandoff.decide(entryVisit: visit, entryURL: "a", age: 0.1, heroVisit: visit, heroURL: "b"), .dropOtherStream)
        XCTAssertEqual(TrailerReturnHandoff.decide(entryVisit: visit, entryURL: "a", age: TrailerReturnHandoff.window + 0.01, heroVisit: visit, heroURL: "a"), .dropExpired)
        XCTAssertEqual(TrailerReturnHandoff.decide(entryVisit: visit, entryURL: "a", age: -1, heroVisit: visit, heroURL: "a"), .dropExpired)
    }

    func testSlotTakesOnceForTheSameVisitInsideTheWindow() {
        let back = TrailerReturnHandoff()
        let now = ProcessInfo.processInfo.systemUptime
        back.record(visit: visit, url: "a", time: t(20), duration: t(150), now: now)
        let taken = back.take(visit: visit, url: "a", now: now + 0.5)
        XCTAssertEqual(taken?.time.seconds ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(taken?.age ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(back.take(visit: visit, url: "a", now: now + 0.6), "consumed once")
    }

    func testANewVisitOfTheSameTitleStartsFromZeroAndConsumesTheEntry() {
        let back = TrailerReturnHandoff()
        let now = ProcessInfo.processInfo.systemUptime
        back.record(visit: visit, url: "a", time: t(20), duration: t(150), now: now)
        XCTAssertNil(back.take(visit: otherVisit, url: "a", now: now + 0.2))
        XCTAssertTrue(back.isEmpty, "a rejected read does not leave it for the next one")
    }

    func testElapsedWindowStartsFromZero() {
        let back = TrailerReturnHandoff()
        let now = ProcessInfo.processInfo.systemUptime
        back.record(visit: visit, url: "a", time: t(20), duration: t(150), now: now)
        XCTAssertNil(back.take(visit: visit, url: "a", now: now + TrailerReturnHandoff.window + 1))
    }

    func testIneligibleHeroClearsTheSlot() {
        let back = TrailerReturnHandoff()
        back.record(visit: visit, url: "a", time: t(20), duration: t(150))
        back.settle(visit: otherVisit, heroEligible: false)
        XCTAssertFalse(back.isEmpty, "another visit's settle does not touch it")
        back.settle(visit: visit, heroEligible: true)
        XCTAssertFalse(back.isEmpty, "an eligible hero keeps it for the remount")
        back.settle(visit: visit, heroEligible: false)
        XCTAssertTrue(back.isEmpty, "duration timer expired / gate closed: nothing left for a later remount")
    }

    func testIneligibleSettleBeforeTheCoverRecordsStillClears() {
        // `onDismiss` fires a few ms before the cover's player is dismantled and records.
        let back = TrailerReturnHandoff()
        let now = ProcessInfo.processInfo.systemUptime
        back.settle(visit: visit, heroEligible: false, now: now)
        back.record(visit: visit, url: "a", time: t(20), duration: t(150), now: now + 0.003)
        XCTAssertTrue(back.isEmpty, "duration timer expired / gate closed: the late record is refused")
        back.record(visit: visit, url: "a", time: t(20), duration: t(150), now: now + 5)
        XCTAssertFalse(back.isEmpty, "a refusal only covers the cover's own dismissal window")
    }

    func testEligibleSettleLeavesNoRefusal() {
        let back = TrailerReturnHandoff()
        let now = ProcessInfo.processInfo.systemUptime
        back.settle(visit: visit, heroEligible: false, now: now)
        back.settle(visit: visit, heroEligible: true, now: now + 0.001)
        back.record(visit: visit, url: "a", time: t(20), duration: t(150), now: now + 0.003)
        XCTAssertFalse(back.isEmpty)
    }

    func testRefusalIsPerVisit() {
        let back = TrailerReturnHandoff()
        let now = ProcessInfo.processInfo.systemUptime
        back.settle(visit: visit, heroEligible: false, now: now)
        back.record(visit: otherVisit, url: "a", time: t(20), duration: t(150), now: now + 0.003)
        XCTAssertFalse(back.isEmpty)
    }

    func testVisitLeavingClearsTheSlotButOnlyForThatVisit() {
        let back = TrailerReturnHandoff()
        back.record(visit: visit, url: "a", time: t(20), duration: t(150))
        back.discard(visit: otherVisit)
        XCTAssertFalse(back.isEmpty)
        back.discard(visit: visit)
        XCTAssertTrue(back.isEmpty)
    }

    func testCoverClosedWithNoHeroMountEmptiesTheSlotByItself() {
        let back = TrailerReturnHandoff()
        back.record(visit: visit, url: "a", time: t(20), duration: t(150))
        let gone = expectation(description: "slot emptied after the window")
        DispatchQueue.main.asyncAfter(deadline: .now() + TrailerReturnHandoff.window + 0.3) {
            XCTAssertTrue(back.isEmpty)
            gone.fulfill()
        }
        wait(for: [gone], timeout: TrailerReturnHandoff.window + 2)
    }

    func testUnusableReadingOrNoVisitNeverRecords() {
        let back = TrailerReturnHandoff()
        back.record(visit: visit, url: "a", time: t(20), duration: t(150))
        back.record(visit: visit, url: "a", time: t(149), duration: t(150))
        XCTAssertTrue(back.isEmpty, "played to the end: the loop starts from 0 and the older entry is cleared")
        back.record(visit: visit, url: "a", time: t(0.5), duration: t(150))
        XCTAssertTrue(back.isEmpty)
        back.record(visit: nil, url: "a", time: t(20), duration: t(150))
        XCTAssertTrue(back.isEmpty, "a cover with no visit token never records")
    }

    func testForwardSlotIsUnaffectedByTheReturnSlot() {
        XCTAssertFalse(TrailerPositionHandoff.shared === TrailerReturnHandoff.shared)
        let forward = TrailerPositionHandoff()
        let back = TrailerReturnHandoff()
        back.record(visit: visit, url: "a", time: t(12), duration: t(150))
        XCTAssertNil(forward.take(url: "a"), "a return entry is invisible to the forward read")
        forward.record(url: "a", time: t(6), duration: t(150))
        back.discard(visit: visit)
        back.settle(visit: visit, heroEligible: false)
        XCTAssertEqual(forward.take(url: "a")?.seconds ?? 0, 6, accuracy: 0.01, "forward carry unchanged")
    }
}
