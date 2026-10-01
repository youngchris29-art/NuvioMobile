import XCTest
@testable import NuvioTV

/// Unit tests for `MPVStartWatchdog` (`Screens/Player/MPVStartWatchdog.swift`) — the pure "no media
/// within N seconds" clock behind the libmpv player's failover signal. Time is a synthetic uptime
/// (`now:` in seconds); the struct has no timer and never touches libmpv.
@MainActor
final class MPVStartWatchdogTests: XCTestCase {

    private let t0: TimeInterval = 1_000

    private func armed(limit: Double = 25) -> MPVStartWatchdog {
        var watchdog = MPVStartWatchdog(limitSeconds: limit)
        watchdog.noteLoadStarted(at: t0)
        return watchdog
    }

    // MARK: Waiting

    func testWaitsInsideTheBudget() {
        let watchdog = armed()
        XCTAssertEqual(watchdog.verdict(now: t0), .waiting)
        XCTAssertEqual(watchdog.verdict(now: t0 + 1), .waiting)
        XCTAssertEqual(watchdog.verdict(now: t0 + 24.9), .waiting)
    }

    func testAClockStepBackwardsStillWaits() {
        XCTAssertEqual(armed().verdict(now: t0 - 5), .waiting)
    }

    func testNeverArmedIsInactive() {
        let watchdog = MPVStartWatchdog(limitSeconds: 25)
        XCTAssertEqual(watchdog.verdict(now: t0), .inactive)
        XCTAssertEqual(watchdog.verdict(now: t0 + 1_000), .inactive)
    }

    // MARK: Firing

    func testFiresAtTheLimitWithTheElapsedSeconds() {
        let watchdog = armed()
        XCTAssertEqual(watchdog.verdict(now: t0 + 25), .fired(elapsed: 25))
        XCTAssertEqual(watchdog.verdict(now: t0 + 31), .fired(elapsed: 31))
    }

    func testPollFiresExactlyOnce() {
        var watchdog = armed()
        XCTAssertEqual(watchdog.poll(now: t0 + 10), .waiting)
        XCTAssertEqual(watchdog.poll(now: t0 + 26), .fired(elapsed: 26))
        // Latched: the same watchdog never reports a second failure.
        XCTAssertEqual(watchdog.poll(now: t0 + 27), .inactive)
        XCTAssertEqual(watchdog.poll(now: t0 + 300), .inactive)
        XCTAssertEqual(watchdog.verdict(now: t0 + 300), .inactive)
    }

    func testPeekingDoesNotLatch() {
        let watchdog = armed()
        XCTAssertEqual(watchdog.verdict(now: t0 + 30), .fired(elapsed: 30))
        XCTAssertEqual(watchdog.verdict(now: t0 + 30), .fired(elapsed: 30))
    }

    func testALateRearmAfterFiringIsIgnored() {
        var watchdog = armed()
        _ = watchdog.poll(now: t0 + 30)
        watchdog.noteLoadStarted(at: t0 + 40)
        XCTAssertEqual(watchdog.poll(now: t0 + 100), .inactive)
    }

    // MARK: Standing down

    func testFileLoadedMakesItInactive() {
        var watchdog = armed()
        watchdog.noteFileLoaded()
        XCTAssertEqual(watchdog.verdict(now: t0 + 5), .inactive)
        XCTAssertEqual(watchdog.verdict(now: t0 + 500), .inactive)
        XCTAssertEqual(watchdog.poll(now: t0 + 500), .inactive)
    }

    func testCancelledMakesItInactive() {
        var watchdog = armed()
        watchdog.noteCancelled()
        XCTAssertEqual(watchdog.verdict(now: t0 + 5), .inactive)
        XCTAssertEqual(watchdog.verdict(now: t0 + 500), .inactive)
        XCTAssertEqual(watchdog.poll(now: t0 + 500), .inactive)
    }

    func testCancellingBeforeArmingKeepsItInactive() {
        var watchdog = MPVStartWatchdog(limitSeconds: 25)
        watchdog.noteCancelled()
        watchdog.noteLoadStarted(at: t0)
        XCTAssertEqual(watchdog.verdict(now: t0 + 500), .inactive)
    }

    // MARK: Shortened limit

    func testShortenedLimitIsFifteenSeconds() {
        XCTAssertEqual(MPVStartWatchdog.limitSeconds(shortened: false), 25)
        XCTAssertEqual(MPVStartWatchdog.limitSeconds(shortened: true), 15)

        let watchdog = armed(limit: MPVStartWatchdog.limitSeconds(shortened: true))
        XCTAssertEqual(watchdog.verdict(now: t0 + 14.9), .waiting)
        XCTAssertEqual(watchdog.verdict(now: t0 + 15), .fired(elapsed: 15))
    }

    func testDefaultLimitStillWaitsAtFifteenSeconds() {
        let watchdog = armed(limit: MPVStartWatchdog.limitSeconds(shortened: false))
        XCTAssertEqual(watchdog.verdict(now: t0 + 15), .waiting)
        XCTAssertEqual(watchdog.verdict(now: t0 + 25), .fired(elapsed: 25))
    }
}
