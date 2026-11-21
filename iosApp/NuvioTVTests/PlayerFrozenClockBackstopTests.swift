import XCTest
@testable import NuvioTV

/// Return from background, decision G: the frozen-clock backstop (pure).
final class PlayerFrozenClockBackstopTests: XCTestCase {

    private func sample(_ now: Double, clock: Double?, paused: Bool = false,
                        playing: Bool = true, buffering: Bool = false) -> PlayerBackstopSample {
        PlayerBackstopSample(now: now, clockSec: clock, userPaused: paused,
                             reportsPlaying: playing, reportsBuffering: buffering)
    }

    func testNotArmedWaits() {
        var b = PlayerFrozenClockBackstop()
        XCTAssertFalse(b.isArmed)
        XCTAssertEqual(b.note(sample(1000, clock: 5)), .wait)
        XCTAssertEqual(b.note(sample(2000, clock: 5, buffering: true)), .wait)
    }

    func testClockMovingByHalfASecondDisarms() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: 10)
        XCTAssertEqual(b.note(sample(101, clock: 10.4)), .wait)
        XCTAssertEqual(b.note(sample(102, clock: 10.5)), .disarm)
        XCTAssertFalse(b.isArmed)
        XCTAssertEqual(b.note(sample(300, clock: 10.5)), .wait)
    }

    func testUserPauseDisarms() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: 10)
        XCTAssertEqual(b.note(sample(101, clock: 10, paused: true)), .disarm)
        XCTAssertFalse(b.isArmed)
        XCTAssertEqual(b.note(sample(500, clock: 10)), .wait)
    }

    func testPlayingLimitIsEightSeconds() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: 10)
        XCTAssertEqual(PlayerFrozenClockBackstop.playingLimitSec, 8)
        XCTAssertEqual(b.note(sample(107.9, clock: 10)), .wait)
        XCTAssertEqual(b.note(sample(108, clock: 10)), .rebuild)
    }

    func testBufferingLimitIsTwentySeconds() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: 10)
        XCTAssertEqual(PlayerFrozenClockBackstop.bufferingLimitSec, 20)
        XCTAssertEqual(b.note(sample(119.9, clock: 10, playing: false, buffering: true)), .wait)
        XCTAssertEqual(b.note(sample(120, clock: 10, playing: false, buffering: true)), .rebuild)
    }

    func testBufferingWinsOverPlayingWhenBothReport() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: 10)
        XCTAssertEqual(b.note(sample(110, clock: 10, playing: true, buffering: true)), .wait)
    }

    func testNeitherPlayingNorBufferingNeverFires() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: 10)
        XCTAssertEqual(b.note(sample(1000, clock: 10, playing: false, buffering: false)), .wait)
    }

    func testFirstExpiryRebuildsSecondHandsOff() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: 10)
        XCTAssertEqual(b.note(sample(108, clock: 10)), .rebuild)
        XCTAssertEqual(b.rebuilds, 1)
        XCTAssertFalse(b.isArmed)
        XCTAssertEqual(b.note(sample(200, clock: 10)), .wait)
        b.arm(now: 210, clockSec: 10)
        XCTAssertEqual(b.rebuilds, 1, "re-arming keeps the rebuild count")
        XCTAssertEqual(b.note(sample(218, clock: 10)), .handOff)
        XCTAssertEqual(b.rebuilds, 2)
    }

    func testNonFiniteClockSamplesAreIgnored() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: 10)
        XCTAssertEqual(b.note(sample(500, clock: nil)), .wait)
        XCTAssertEqual(b.note(sample(500, clock: .nan)), .wait)
        XCTAssertEqual(b.note(sample(500, clock: .infinity)), .wait)
        XCTAssertTrue(b.isArmed)
        XCTAssertEqual(b.rebuilds, 0)
    }

    func testArmedWithoutAClockTakesTheFirstFiniteSampleAsBaseline() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: nil)
        XCTAssertEqual(b.note(sample(101, clock: 30)), .wait)
        XCTAssertEqual(b.armedClock, 30)
        XCTAssertEqual(b.note(sample(109, clock: 30)), .rebuild)
    }

    func testNonFiniteArmClockIsDropped() {
        var b = PlayerFrozenClockBackstop()
        b.arm(now: 100, clockSec: .nan)
        XCTAssertNil(b.armedClock)
    }
}
