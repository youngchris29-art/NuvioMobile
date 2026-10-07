import XCTest
@testable import NuvioTV

final class HarvestSchedulerTests: XCTestCase {
    typealias H = HarvestScheduler

    /// Ticks once a second from `from` for `count` ticks; returns the times a harvest was due.
    @discardableResult
    private func run(_ h: inout H, from: TimeInterval, count: Int, playing: Bool = true, idle: Bool = true,
                     seek: Bool = false, input: Bool = false, startOnFire: Bool = false) -> [TimeInterval] {
        var fired: [TimeInterval] = []
        for i in 0..<count {
            let t = from + Double(i)
            if h.tick(now: t, playing: playing, transportIdle: idle, seekInFlight: seek, recentInput: input) {
                fired.append(t)
                if startOnFire { h.noteStarted(); h.noteFinished(tookMs: 5) }
            }
        }
        return fired
    }

    func testDueAfterTenSecondsOfEligibleTicks() {
        var h = H(intervalSec: 10)
        let fired = run(&h, from: 0, count: 12)
        XCTAssertEqual(fired.first, 10)
    }

    func testPausedTicksDoNotCount() {
        var h = H(intervalSec: 10)
        run(&h, from: 0, count: 6)                       // 5 s played
        XCTAssertTrue(run(&h, from: 6, count: 30, playing: false).isEmpty)
        let fired = run(&h, from: 36, count: 10)
        XCTAssertEqual(fired.first, 40)                  // 5 more seconds of play
    }

    func testNonIdleTransportDoesNotCount() {
        var h = H(intervalSec: 10)
        XCTAssertTrue(run(&h, from: 0, count: 30, idle: false).isEmpty)
        XCTAssertEqual(h.playedSinceLast, 0)
        XCTAssertTrue(run(&h, from: 30, count: 5, seek: true).isEmpty)
        XCTAssertEqual(h.playedSinceLast, 0)
    }

    func testSeekLandingFiresOneSecondLaterAndSecondLandingResets() {
        var h = H(intervalSec: 10)
        _ = h.tick(now: 0, playing: true, transportIdle: true, seekInFlight: false, recentInput: false)
        h.noteSeekLanded(now: 0.2)
        XCTAssertFalse(h.tick(now: 0.7, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
        h.noteSeekLanded(now: 0.8)                       // a newer landing replaces the first
        XCTAssertFalse(h.tick(now: 1.3, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
        XCTAssertTrue(h.tick(now: 1.8, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
        h.noteStarted()
        XCTAssertNil(h.seekHarvestDue)
        XCTAssertEqual(h.playedSinceLast, 0)
    }

    func testDueSeekHarvestWaitsForNextEligibleTick() {
        var h = H(intervalSec: 10)
        h.noteSeekLanded(now: 0)
        XCTAssertFalse(h.tick(now: 1.5, playing: false, transportIdle: true, seekInFlight: false, recentInput: false))
        XCTAssertFalse(h.tick(now: 2.0, playing: true, transportIdle: false, seekInFlight: false, recentInput: false))
        XCTAssertNotNil(h.seekHarvestDue, "still owed")
        XCTAssertTrue(h.tick(now: 2.5, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
    }

    func testNothingWhileInFlight() {
        var h = H(intervalSec: 10)
        XCTAssertEqual(run(&h, from: 0, count: 11).first, 10)
        h.noteStarted()
        XCTAssertTrue(run(&h, from: 11, count: 30).isEmpty)
        h.noteFinished(tookMs: 5)
        XCTAssertEqual(run(&h, from: 41, count: 12).first, 50)
    }

    func testIntervalZeroOrNegativeNeverFires() {
        var off = H(intervalSec: 0)
        XCTAssertTrue(run(&off, from: 0, count: 100).isEmpty)
        var neg = H(intervalSec: -1)
        neg.noteSeekLanded(now: 0)
        XCTAssertTrue(run(&neg, from: 0, count: 100).isEmpty)
    }

    func testDtCappedAtOneSecondAfterStall() {
        var h = H(intervalSec: 10)
        _ = h.tick(now: 0, playing: true, transportIdle: true, seekInFlight: false, recentInput: false)
        XCTAssertFalse(h.tick(now: 60, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
        XCTAssertEqual(h.playedSinceLast, 1)
    }

    // C18
    func testRecentInputMakesTickIneligible() {
        var h = H(intervalSec: 10)
        XCTAssertTrue(run(&h, from: 0, count: 30, input: true).isEmpty)
        XCTAssertEqual(h.playedSinceLast, 0)
        h.noteSeekLanded(now: 30)
        XCTAssertFalse(h.tick(now: 31.5, playing: true, transportIdle: true, seekInFlight: false, recentInput: true))
        XCTAssertTrue(h.tick(now: 32, playing: true, transportIdle: true, seekInFlight: false, recentInput: false))
    }

    func testSlowHarvestTriplesIntervalOnce() {
        var h = H(intervalSec: 10)
        h.noteStarted()
        XCTAssertFalse(h.noteFinished(tookMs: 60), "60 ms is not over the line")
        XCTAssertEqual(h.intervalSec, 10)
        h.noteStarted()
        XCTAssertTrue(h.noteFinished(tookMs: 75))
        XCTAssertEqual(h.intervalSec, 30)
        h.noteStarted()
        XCTAssertFalse(h.noteFinished(tookMs: 200), "logged and applied once per file")
        XCTAssertEqual(h.intervalSec, 30)
        XCTAssertFalse(h.inFlight)
        let fired = run(&h, from: 0, count: 32)
        XCTAssertEqual(fired.first, 30)
    }

    /// Review r1 P3 #8: once backed off, a landed seek schedules no extra harvest; the tripled
    /// interval keeps running.
    func testBackedOffFileSkipsSeekHarvest() {
        var h = H(intervalSec: 10)
        h.noteStarted()
        XCTAssertTrue(h.noteFinished(tookMs: 90))
        h.noteSeekLanded(now: 5)
        XCTAssertNil(h.seekHarvestDue)
        let fired = run(&h, from: 0, count: 32)
        XCTAssertEqual(fired.first, 30, "no harvest 1 s after the landing, only the 30 s interval")
    }

    func testFailedHarvestDoesNotBackOff() {
        var h = H(intervalSec: 10)
        h.noteStarted()
        XCTAssertFalse(h.noteFinished(tookMs: nil))
        XCTAssertEqual(h.intervalSec, 10)
    }

    func testIntervalFromSetting() {
        XCTAssertEqual(H.interval(fromSetting: 0), 10)
        XCTAssertEqual(H.interval(fromSetting: -1), 0)
        XCTAssertEqual(H.interval(fromSetting: 5), 5)
        XCTAssertEqual(H.interval(fromSetting: 30), 30)
    }
}
