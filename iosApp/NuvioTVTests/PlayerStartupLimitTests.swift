import XCTest
@testable import NuvioTV

/// W4: the start-up limit (`Screens/Player/PlayerStartupLimit.swift`): the pure clock and the box
/// `PlayerScreen` drives it with, as event sequences on a synthetic uptime (no timer).
@MainActor
final class PlayerStartupLimitTests: XCTestCase {

    private let t0: TimeInterval = 1_000

    private func armed(_ limit: Double = 15) -> PlayerStartupLimit {
        var clock = PlayerStartupLimit(limitSeconds: limit)
        clock.arm(at: t0)
        return clock
    }

    // MARK: Pure clock

    func testNothingFiresBeforeArming() {
        var clock = PlayerStartupLimit(limitSeconds: 15)
        XCTAssertEqual(clock.poll(now: t0 + 100), .inactive)
        XCTAssertFalse(clock.isArmed)
    }

    func testStartedBeforeTheLimitNeverReaches() {
        var clock = armed()
        XCTAssertEqual(clock.poll(now: t0 + 14), .waiting)
        clock.noteStarted()
        XCTAssertEqual(clock.poll(now: t0 + 15), .inactive)
        XCTAssertEqual(clock.poll(now: t0 + 60), .inactive)
    }

    func testReachedOnceAtTheLimitThenInactive() {
        var clock = armed()
        XCTAssertEqual(clock.poll(now: t0 + 14.9), .waiting)
        XCTAssertEqual(clock.poll(now: t0 + 15), .reached(elapsed: 15))
        XCTAssertEqual(clock.poll(now: t0 + 16), .inactive, "fires once")
        clock.arm(at: t0 + 20)
        XCTAssertEqual(clock.poll(now: t0 + 40), .inactive, "a finished clock is never re-armed")
    }

    func testAHandoffBeforeTheLimitReArmsAFullLimit() {
        var clock = armed()
        clock.noteHandoff(at: t0 + 12)
        XCTAssertEqual(clock.poll(now: t0 + 15), .waiting, "mpv gets its own limit")
        XCTAssertEqual(clock.poll(now: t0 + 26.9), .waiting)
        XCTAssertEqual(clock.poll(now: t0 + 27), .reached(elapsed: 15))
    }

    func testAHandoffAfterTheStartOrTheLimitIsIgnored() {
        var started = armed()
        started.noteStarted()
        started.noteHandoff(at: t0 + 5)
        XCTAssertEqual(started.poll(now: t0 + 30), .inactive)

        var reached = armed()
        XCTAssertEqual(reached.poll(now: t0 + 15), .reached(elapsed: 15))
        reached.noteHandoff(at: t0 + 16)
        XCTAssertEqual(reached.poll(now: t0 + 40), .inactive)
    }

    func testCancelledNeverFires() {
        var clock = armed()
        clock.noteCancelled()
        XCTAssertEqual(clock.poll(now: t0 + 100), .inactive)
    }

    // MARK: The box PlayerScreen drives

    private final class Sink {
        var now: TimeInterval = 1_000
        var reached = 0
    }

    private func makeClock(_ sink: Sink) -> PlayerStartupLimitClock {
        PlayerStartupLimitClock(now: { sink.now }, usesTimer: false)
    }

    func testTheBoxFiresTheHostOnceAtTheLimit() {
        let sink = Sink()
        let clock = makeClock(sink)
        clock.arm(contextID: "ctx-1", limitSeconds: 15, onReached: { sink.reached += 1 })
        XCTAssertTrue(clock.isArmed)
        sink.now += 14; clock.tick()
        XCTAssertEqual(sink.reached, 0)
        sink.now += 1; clock.tick()
        XCTAssertEqual(sink.reached, 1)
        sink.now += 30; clock.tick()
        XCTAssertEqual(sink.reached, 1, "once")
        XCTAssertFalse(clock.isArmed)
    }

    /// A manual pick (no limit) or no host callback arms nothing.
    func testNoLimitOrNoHostArmsNothing() {
        let sink = Sink()
        let manual = makeClock(sink)
        manual.arm(contextID: "ctx-1", limitSeconds: nil, onReached: { sink.reached += 1 })
        sink.now += 100; manual.tick()
        let noHost = makeClock(sink)
        noHost.arm(contextID: "ctx-1", limitSeconds: 15, onReached: nil)
        sink.now += 100; noHost.tick()
        XCTAssertEqual(sink.reached, 0)
        XCTAssertFalse(manual.isArmed)
        XCTAssertFalse(noHost.isArmed)
    }

    /// `PlayerScreen`'s `onAppear` runs again for each engine view it switches to: arming the same
    /// context again changes nothing (the clock is not restarted by deciding → native → mpv).
    func testArmingTheSameContextAgainChangesNothing() {
        let sink = Sink()
        let clock = makeClock(sink)
        clock.arm(contextID: "ctx-1", limitSeconds: 15, onReached: { sink.reached += 1 })
        sink.now += 10
        clock.arm(contextID: "ctx-1", limitSeconds: 15, onReached: { sink.reached += 100 })
        sink.now += 5; clock.tick()
        XCTAssertEqual(sink.reached, 1, "still the first arm's clock and callback")
    }

    /// A context change (a host that swaps without rebuilding) starts over for the new context.
    func testANewContextStartsOver() {
        let sink = Sink()
        let clock = makeClock(sink)
        clock.arm(contextID: "ctx-1", limitSeconds: 15, onReached: { sink.reached += 1 })
        sink.now += 10
        clock.arm(contextID: "ctx-2", limitSeconds: 15, onReached: { sink.reached += 10 })
        sink.now += 10; clock.tick()
        XCTAssertEqual(sink.reached, 0)
        sink.now += 5; clock.tick()
        XCTAssertEqual(sink.reached, 10)
    }

    /// Native fails at 12 s of a 15 s limit and hands to mpv (I5): mpv gets 15 s from the handoff.
    func testTheBoxReArmsOnAnEngineHandoff() {
        let sink = Sink()
        let clock = makeClock(sink)
        clock.arm(contextID: "ctx-1", limitSeconds: 15, onReached: { sink.reached += 1 })
        sink.now += 12
        clock.noteHandoff()
        sink.now += 14; clock.tick()
        XCTAssertEqual(sink.reached, 0)
        sink.now += 1; clock.tick()
        XCTAssertEqual(sink.reached, 1)
    }

    /// The first frame stands the limit down and is forwarded once, whichever engine sends it and
    /// however often (I1: a start before the poll wins).
    func testTheFirstFrameStandsDownAndIsForwardedOnce() {
        let sink = Sink()
        let clock = makeClock(sink)
        clock.arm(contextID: "ctx-1", limitSeconds: 15, onReached: { sink.reached += 1 })
        sink.now += 15
        XCTAssertTrue(clock.noteStarted(), "forwarded the first time")
        XCTAssertFalse(clock.noteStarted(), "a second engine's start is not forwarded again")
        clock.tick()
        XCTAssertEqual(sink.reached, 0)
        clock.noteHandoff()
        sink.now += 60; clock.tick()
        XCTAssertEqual(sink.reached, 0)
    }

    /// The limit fired, the next source resolves, then the slow source starts: the start is still
    /// forwarded (the host abandons the failover on it, I2).
    func testAStartAfterTheLimitFiredIsStillForwarded() {
        let sink = Sink()
        let clock = makeClock(sink)
        clock.arm(contextID: "ctx-1", limitSeconds: 15, onReached: { sink.reached += 1 })
        sink.now += 15; clock.tick()
        XCTAssertEqual(sink.reached, 1)
        XCTAssertTrue(clock.noteStarted())
    }

    func testCancelNeverFires() {
        let sink = Sink()
        let clock = makeClock(sink)
        clock.arm(contextID: "ctx-1", limitSeconds: 15, onReached: { sink.reached += 1 })
        clock.cancel()
        sink.now += 60; clock.tick()
        XCTAssertEqual(sink.reached, 0)
    }
}
