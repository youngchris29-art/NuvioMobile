import XCTest
@testable import NuvioTV

/// Unit tests for `PlaybackHealthClock` and `PlaybackEndPolicy`
/// (`Screens/Player/PlaybackHealthClock.swift`): the play-time accumulator both engines feed for
/// `PlaybackFailure.secondsPlayed` / the 300 s healthy mark, and the libmpv end-of-file rule.
/// Time is a synthetic uptime in seconds; neither type touches a timer, AVPlayer or libmpv.
@MainActor
final class PlaybackHealthClockTests: XCTestCase {

    private let t0: TimeInterval = 1_000

    /// Samples `clock` every `step` seconds over `(from, to]`, all in the given state, the way an
    /// engine tick would.
    private func tick(_ clock: inout PlaybackHealthClock, playing: Bool,
                      from: TimeInterval, to: TimeInterval, step: TimeInterval = 0.5) {
        var at = from + step
        while at <= to + 0.000_001 {
            clock.note(playing: playing, at: t0 + at)
            at += step
        }
    }

    // MARK: Accumulation

    func testStartsAtZeroAndTheFirstSampleAddsNothing() {
        var clock = PlaybackHealthClock()
        XCTAssertEqual(clock.seconds, 0)
        clock.note(playing: true, at: t0)
        XCTAssertEqual(clock.seconds, 0)
    }

    func testContinuousPlaybackCountsEverySpan() {
        var clock = PlaybackHealthClock()
        clock.note(playing: true, at: t0)
        tick(&clock, playing: true, from: 0, to: 60)
        XCTAssertEqual(clock.seconds, 60, accuracy: 0.001)
    }

    func testPausedTimeDoesNotCount() {
        var clock = PlaybackHealthClock()
        clock.note(playing: true, at: t0)
        tick(&clock, playing: true, from: 0, to: 30)        // 30 s playing
        tick(&clock, playing: false, from: 30, to: 600)     // ten minutes paused
        XCTAssertEqual(clock.seconds, 30, accuracy: 0.001)
        tick(&clock, playing: true, from: 600, to: 630)     // resumed for 30 s
        // The span that ends the pause starts in the paused state, so it is left out: the
        // accumulator under-counts by at most one tick around each transition.
        XCTAssertEqual(clock.seconds, 59.5, accuracy: 0.001)
    }

    func testBufferingTimeDoesNotCount() {
        var clock = PlaybackHealthClock()
        clock.note(playing: true, at: t0)
        tick(&clock, playing: true, from: 0, to: 10)
        // A stalled stretch: the engine reports "not playing" every tick for a minute.
        tick(&clock, playing: false, from: 10, to: 70)
        XCTAssertEqual(clock.seconds, 10, accuracy: 0.001)
    }

    func testAnAlwaysPausedPlayerNeverAccumulates() {
        var clock = PlaybackHealthClock()
        clock.note(playing: false, at: t0)
        tick(&clock, playing: false, from: 0, to: 3_600, step: 3)
        XCTAssertEqual(clock.seconds, 0)
    }

    // MARK: Guards

    func testALateTickIsCappedAtTheMaxSpan() {
        var clock = PlaybackHealthClock()
        clock.note(playing: true, at: t0)
        clock.note(playing: true, at: t0 + 300)             // a suspended app resumed 5 minutes later
        XCTAssertEqual(clock.seconds, PlaybackHealthClock.defaultMaxSpanSeconds, accuracy: 0.001)

        var wide = PlaybackHealthClock(maxSpanSeconds: 10)
        wide.note(playing: true, at: t0)
        wide.note(playing: true, at: t0 + 300)
        XCTAssertEqual(wide.seconds, 10, accuracy: 0.001)
    }

    func testAClockStepBackwardsAddsNothingAndRebases() {
        var clock = PlaybackHealthClock()
        clock.note(playing: true, at: t0 + 100)
        clock.note(playing: true, at: t0 + 90)
        XCTAssertEqual(clock.seconds, 0)
        clock.note(playing: true, at: t0 + 91)
        XCTAssertEqual(clock.seconds, 1, accuracy: 0.001)
    }

    // MARK: The healthy mark

    func testPausedTimeCannotClearALinksRejection() {
        var clock = PlaybackHealthClock()
        clock.note(playing: true, at: t0)
        tick(&clock, playing: true, from: 0, to: 120)       // 2 minutes of real playback
        tick(&clock, playing: false, from: 120, to: 1_000)  // paused for the rest of the evening
        // A wall clock since load would read 1000 s here and keep the link.
        XCTAssertFalse(PlaybackFailoverPolicy.shouldKeep(secondsPlayed: clock.seconds))
        XCTAssertTrue(PlaybackFailoverPolicy.shouldReject(PlaybackFailure(
            reason: "stream ended early", positionSec: 120, secondsPlayed: clock.seconds, startedPlaying: true)))
    }

    func testFiveMinutesOfRealPlaybackReachesTheHealthyMark() {
        var clock = PlaybackHealthClock()
        clock.note(playing: true, at: t0)
        tick(&clock, playing: true, from: 0, to: 299)
        XCTAssertFalse(PlaybackFailoverPolicy.shouldKeep(secondsPlayed: clock.seconds))
        tick(&clock, playing: true, from: 299, to: 301)
        XCTAssertTrue(PlaybackFailoverPolicy.shouldKeep(secondsPlayed: clock.seconds))
    }

    // MARK: End-of-file rule (libmpv, keep-open)

    func testAutoFlowsTreatAnEndWellBeforeTheDurationAsAFailure() {
        for source in [PlaybackLaunchSource.autoPlay, .nextEpisode] {
            XCTAssertTrue(PlaybackEndPolicy.isEarlyEndFailure(
                position: 1_200, duration: 5_400, secondsPlayed: 20, launchSource: source), "\(source)")
            // Five minutes of real playback does not excuse an auto flow: the next candidate is cheap.
            XCTAssertTrue(PlaybackEndPolicy.isEarlyEndFailure(
                position: 1_200, duration: 5_400, secondsPlayed: 1_200, launchSource: source), "\(source)")
        }
    }

    func testAnEndWithinAMinuteOfTheDurationIsNormal() {
        XCTAssertFalse(PlaybackEndPolicy.isEarlyEndFailure(
            position: 5_341, duration: 5_400, secondsPlayed: 5_000, launchSource: .autoPlay))
        // Exactly at the slack is still a normal end; just past it is not.
        XCTAssertFalse(PlaybackEndPolicy.isEarlyEndFailure(
            position: 5_340, duration: 5_400, secondsPlayed: 5_000, launchSource: .autoPlay))
        XCTAssertTrue(PlaybackEndPolicy.isEarlyEndFailure(
            position: 5_339.9, duration: 5_400, secondsPlayed: 5_000, launchSource: .autoPlay))
    }

    func testAManualPickThatPlayedFiveMinutesGetsTheNormalEnd() {
        // A source declaring a duration far too long must not turn a finished episode into a failure.
        XCTAssertFalse(PlaybackEndPolicy.isEarlyEndFailure(
            position: 2_700, duration: 5_400, secondsPlayed: 2_700, launchSource: .manual))
        XCTAssertFalse(PlaybackEndPolicy.isEarlyEndFailure(
            position: 600, duration: 5_400, secondsPlayed: 300, launchSource: .manual))
    }

    func testAManualPickThatNeverGotGoingStillFails() {
        XCTAssertTrue(PlaybackEndPolicy.isEarlyEndFailure(
            position: 90, duration: 5_400, secondsPlayed: 299.9, launchSource: .manual))
    }

    func testAnUnknownDurationIsNeverAnEarlyEnd() {
        for duration in [0, -1, Double.nan, Double.infinity] {
            XCTAssertFalse(PlaybackEndPolicy.isEarlyEndFailure(
                position: 10, duration: duration, secondsPlayed: 5, launchSource: .autoPlay), "\(duration)")
        }
        XCTAssertFalse(PlaybackEndPolicy.isEarlyEndFailure(
            position: .nan, duration: 5_400, secondsPlayed: 5, launchSource: .autoPlay))
    }
}
