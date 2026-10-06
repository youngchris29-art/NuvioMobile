import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for `SkipSegmentPlanner` (`Screens/Player/SkipSegmentPlanner.swift`) — the pure skip
/// chip / auto-skip policy both player engines share (upstream cbe4dc0a..77ce8a73, tvOS half).
/// Intervals are real SharedCore `SkipInterval`s, so the shared `internalSkipAction` /
/// `intervalsAtSeekPositions` semantics are exercised too. Durations stay above the shared
/// short-placeholder floor (121 s), below which no skip action exists. Time is a synthetic clock
/// (`now:` in seconds); the planner has none of its own.
@MainActor
final class SkipSegmentPlannerTests: XCTestCase {

    private func interval(_ start: Double, _ end: Double, _ type: String) -> SkipInterval {
        SkipInterval(startTime: start, endTime: end, type: type, provider: "test")
    }

    private func planner(_ intervals: [SkipInterval]) -> SkipSegmentPlanner {
        var planner = SkipSegmentPlanner()
        planner.setIntervals(intervals)
        return planner
    }

    private let episodeDuration: Double = 1500
    private let movieDuration: Double = 6600

    /// One tick at `now` (episode duration, playing unless told otherwise).
    private func tick(_ p: inout SkipSegmentPlanner, _ pos: Double, at now: TimeInterval,
                      types: [AutoSkipSegmentType]? = nil, playing: Bool = true,
                      duration: Double? = nil) -> SkipSegmentPlanner.Decision {
        p.evaluate(positionSec: pos, durationSec: duration ?? episodeDuration, isPlaying: playing,
                   autoSkipTypes: types, now: now)
    }

    // MARK: - Chip

    func testChipOffersIntroSkipToIntervalEnd() {
        var p = planner([interval(0, 90, "op")])
        let d = tick(&p, 10, at: 0)
        XCTAssertEqual(d.prompt, SkipPrompt(label: String(localized: "Skip Intro"), targetSec: 90))
        XCTAssertNil(d.autoSkipTargetSec)
    }

    func testChipHidesInTheLastSecondAndOutsideIntervals() {
        var p = planner([interval(0, 90, "op")])
        XCTAssertNil(tick(&p, 89.5, at: 0).prompt)
        XCTAssertNil(tick(&p, 95, at: 0.5).prompt)
    }

    func testNoChipForPostCreditsInterval() {
        var p = planner([interval(6000, 6300, "movie-credits"), interval(6400, 6500, "post-credits")])
        XCTAssertNil(tick(&p, 6450, at: 0, duration: movieDuration).prompt)
    }

    func testMovieCreditsSkipLandsOnPostCreditsSceneStart() {
        var p = planner([interval(6000, 6300, "movie-credits"), interval(6400, 6500, "post-credits")])
        let d = tick(&p, 6100, at: 0, duration: movieDuration)
        XCTAssertEqual(d.prompt, SkipPrompt(label: String(localized: "Skip to Post-Credits"), targetSec: 6400))
    }

    func testMovieCreditsWithoutSceneOrTailSaysSkipCredits() {
        var p = planner([interval(6000, 6598, "movie-credits")])
        let d = tick(&p, 6100, at: 0, duration: movieDuration)
        XCTAssertEqual(d.prompt, SkipPrompt(label: String(localized: "Skip Credits"), targetSec: 6598))
    }

    func testTargetIsClampedShortOfKnownDuration() {
        // Open-ended episode outro (Double.greatestFiniteMagnitude sentinel) stays actionable.
        var p = planner([interval(1400, .greatestFiniteMagnitude, "ed")])
        XCTAssertEqual(tick(&p, 1450, at: 0).prompt?.targetSec, episodeDuration - 0.5)
    }

    func testOutroWithTailButNoExplicitPostCreditsSaysSkipOutro() {
        // Fork rule: the shared heuristic flags skipsToPostCredits for any >5 s tail (here 60 s of
        // next-episode preview); without an explicit post-credits interval the label stays "Skip Outro".
        var p = planner([interval(1380, 1440, "ed")])
        XCTAssertEqual(tick(&p, 1400, at: 0).prompt, SkipPrompt(label: String(localized: "Skip Outro"), targetSec: 1440))
    }

    func testMalformedPostCreditsEntryDoesNotEarnPostCreditsLabel() {
        // Tail after the outro exists (heuristic flag), but the only post-credits entry is invalid
        // (end <= start) or starts past the duration: the normal label is used.
        for bad in [interval(1450, 1450, "post-credits"), interval(1600, 1650, "post-credits")] {
            var p = planner([interval(1380, 1440, "ed"), bad])
            XCTAssertEqual(tick(&p, 1400, at: 0).prompt?.label, String(localized: "Skip Outro"))
        }
    }

    func testLabels() {
        XCTAssertEqual(SkipSegmentPlanner.label(for: "mixed-ed", skipsToPostCredits: false), String(localized: "Skip Outro"))
        XCTAssertEqual(SkipSegmentPlanner.label(for: "recap", skipsToPostCredits: false), String(localized: "Skip Recap"))
        XCTAssertEqual(SkipSegmentPlanner.label(for: "ed", skipsToPostCredits: true), String(localized: "Skip to Post-Credits"))
        XCTAssertEqual(SkipSegmentPlanner.label(for: "unknown", skipsToPostCredits: false), String(localized: "Skip Intro"))
    }

    // MARK: - Auto-skip

    func testAutoSkipFiresOncePerIntervalAndHidesItsChipUntilLeft() {
        var p = planner([interval(0, 90, "op")])
        let first = tick(&p, 5, at: 0, types: [.intro])
        XCTAssertEqual(first.autoSkipTargetSec, 90)
        XCTAssertNil(first.prompt)
        p.beginSeek(kind: .auto, targetSec: 90, now: 0)
        // A stale pre-seek tick still inside: neither a second skip nor a chip flash.
        let stale = tick(&p, 6, at: 0.5, types: [.intro])
        XCTAssertNil(stale.autoSkipTargetSec)
        XCTAssertNil(stale.prompt)
        p.seekCompleted(atSec: 90, now: 0.8)
        XCTAssertEqual(tick(&p, 90, at: 1, types: [.intro]), SkipSegmentPlanner.Decision())
        // The user goes back in: chip only, no second auto-skip.
        p.beginSeek(kind: .user, targetSec: 6, fromSec: 90, now: 2)
        p.seekCompleted(atSec: 6, now: 2.3)
        let back = tick(&p, 6, at: 2.5, types: [.intro])
        XCTAssertNil(back.autoSkipTargetSec)
        XCTAssertNotNil(back.prompt)
    }

    func testChipHiddenForAutoSkippedIntervalWhileStillInsideAfterCompletion() {
        // Completion confirmed, but a tick still reports a position inside: no chip flash.
        var p = planner([interval(0, 90, "op")])
        XCTAssertEqual(tick(&p, 5, at: 0, types: [.intro]).autoSkipTargetSec, 90)
        p.beginSeek(kind: .auto, targetSec: 90, now: 0)
        p.seekCompleted(atSec: 89.8, now: 0.4)
        XCTAssertNil(tick(&p, 89.8, at: 0.5, types: [.intro]).prompt)
    }

    func testAutoSkipNeedsSelectedTypePlayingAndSkipIntro() {
        var p = planner([interval(0, 90, "op")])
        XCTAssertNil(tick(&p, 5, at: 0, types: [.outro]).autoSkipTargetSec)
        XCTAssertNil(tick(&p, 5, at: 0.5, types: []).autoSkipTargetSec)
        XCTAssertNil(tick(&p, 5, at: 1, types: nil).autoSkipTargetSec)
        XCTAssertNil(tick(&p, 5, at: 1.5, types: [.intro], playing: false).autoSkipTargetSec)
        // None of the above consumed the interval.
        XCTAssertEqual(tick(&p, 5, at: 2, types: [.intro]).autoSkipTargetSec, 90)
    }

    func testAutoSkippedMovieCreditsLandOnTheScene() {
        var p = planner([interval(6000, 6300, "movie-credits"), interval(6400, 6500, "post-credits")])
        XCTAssertEqual(tick(&p, 6001, at: 0, types: [.movieCredits], duration: movieDuration).autoSkipTargetSec, 6400)
        p.beginSeek(kind: .auto, targetSec: 6400, now: 0)
        p.seekCompleted(atSec: 6400, now: 0.5)
        // The scene itself is never auto-skipped, whatever is selected.
        XCTAssertNil(tick(&p, 6401, at: 1, types: AutoSkipSegmentType.entries, duration: movieDuration).autoSkipTargetSec)
    }

    // MARK: - Deliberate entry (user seeks)

    func testUserSeekLandingInsideSuppressesAutoSkip() {
        var p = planner([interval(1300, 1380, "ed")])
        p.beginSeek(kind: .user, targetSec: 1320, fromSec: 1000, now: 0)
        p.seekCompleted(atSec: 1320, now: 0.3)
        let d = tick(&p, 1320, at: 0.5, types: [.outro])
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
    }

    func testUserSeekStartingInsideSuppressesAutoSkip() {
        var p = planner([interval(0, 90, "op")])
        p.beginSeek(kind: .user, targetSec: 20, fromSec: 30, now: 0)
        p.seekCompleted(atSec: 20, now: 0.3)
        XCTAssertNil(tick(&p, 20, at: 0.5, types: [.intro]).autoSkipTargetSec)
    }

    func testSeekOutsideLeavesOtherIntervalsArmed() {
        var p = planner([interval(0, 90, "op"), interval(1300, 1380, "ed")])
        p.beginSeek(kind: .user, targetSec: 200, fromSec: 10, now: 0)   // started inside the intro only
        p.seekCompleted(atSec: 200, now: 0.3)
        XCTAssertEqual(tick(&p, 1301, at: 0.5, types: [.outro]).autoSkipTargetSec, 1380)
    }

    func testHeldArrowChainKeepsTheGestureOrigin() {
        // Three chained seeks started inside the intro: the intro counts as deliberately left.
        var p = planner([interval(0, 90, "op")])
        p.beginSeek(kind: .user, targetSec: 40, fromSec: 30, now: 0)
        p.beginSeek(kind: .user, targetSec: 60, fromSec: 30, now: 0.4)   // stale cached from
        p.beginSeek(kind: .user, targetSec: 90, fromSec: 30, now: 0.8)
        p.seekCompleted(atSec: 120, now: 1.2)
        p.beginSeek(kind: .user, targetSec: 50, fromSec: 120, now: 3)
        p.seekCompleted(atSec: 50, now: 3.3)
        XCTAssertNil(tick(&p, 50, at: 3.5, types: [.intro]).autoSkipTargetSec)
    }

    // MARK: - Seek state machine

    /// 1
    func testResumeLandingInsideIntroIsNotAutoSkippedButShowsChipAfterCompletion() {
        var p = planner([interval(0, 90, "op")])
        p.beginSeek(kind: .resume, targetSec: 45, now: 0)
        XCTAssertEqual(tick(&p, 0.2, at: 0.5, types: [.intro]), SkipSegmentPlanner.Decision())
        p.seekCompleted(atSec: 45, now: 1)
        XCTAssertNil(p.seekInFlight)
        let d = tick(&p, 45, at: 1.5, types: [.intro])
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
    }

    /// 2
    func testUnknownTargetResumeWithSlowSeekNeverAutoSkipsOnStalePosition() {
        var p = planner([interval(0, 90, "op"), interval(1400, 1440, "ed")])
        p.beginSeek(kind: .resume, targetSec: nil, now: 0)
        for k in 1...25 {
            let d = tick(&p, 0, at: Double(k) * 0.5, types: [.intro, .outro])
            XCTAssertNil(d.autoSkipTargetSec, "tick \(k)")
            XCTAssertNil(d.prompt, "tick \(k)")
        }
        p.seekCompleted(atSec: 1200, now: 13)
        XCTAssertNil(p.seekInFlight)
        XCTAssertEqual(tick(&p, 1200, at: 13.5, types: [.intro, .outro]), SkipSegmentPlanner.Decision())
        XCTAssertEqual(tick(&p, 1401, at: 14, types: [.intro, .outro]).autoSkipTargetSec, 1440)
    }

    /// 3
    func testFailedResumeSeekWithRealPlaybackRestoresChipAndAutoSkipAfterTimeout() {
        let intervals = [interval(0, 90, "op"), interval(1400, .greatestFiniteMagnitude, "ed")]
        // Resume to 1200 never confirms; the stream really plays from 0 (0.5 s per tick).
        var auto = planner(intervals)
        auto.beginSeek(kind: .resume, targetSec: 1200, now: 0)
        var firstAutoAt: Double?
        for k in 1...30 {
            let now = Double(k) * 0.5
            let d = tick(&auto, now, at: now, types: [.intro])
            if now <= SkipSegmentPlanner.seekTimeoutSec {
                XCTAssertNil(d.autoSkipTargetSec, "tick \(k)")
                XCTAssertNil(d.prompt, "tick \(k)")
            }
            if d.autoSkipTargetSec != nil, firstAutoAt == nil {
                XCTAssertEqual(d.autoSkipTargetSec, 90)
                firstAutoAt = now
            }
        }
        XCTAssertNotNil(firstAutoAt)

        var chip = planner(intervals)
        chip.beginSeek(kind: .resume, targetSec: 1200, now: 0)
        var lastPrompt: SkipPrompt?
        for k in 1...30 {
            let now = Double(k) * 0.5
            lastPrompt = tick(&chip, now, at: now).prompt
        }
        XCTAssertEqual(lastPrompt?.label, String(localized: "Skip Intro"))
    }

    /// 4
    func testResumeSeekStuckAtOnePositionProducesNothingUntilThePositionMoves() {
        var p = planner([interval(0, 90, "op")])
        p.beginSeek(kind: .resume, targetSec: 1200, now: 0)
        for k in 1...40 {
            let d = tick(&p, 0.2, at: Double(k) * 0.5, types: [.intro])
            XCTAssertEqual(d, SkipSegmentPlanner.Decision(), "tick \(k)")
        }
        XCTAssertNil(p.seekInFlight)   // timed out, nothing consumed
        XCTAssertEqual(tick(&p, 5, at: 20.5, types: [.intro]).autoSkipTargetSec, 90)

        var chip = planner([interval(0, 90, "op")])
        chip.beginSeek(kind: .resume, targetSec: 1200, now: 0)
        for k in 1...40 { XCTAssertNil(tick(&chip, 0.2, at: Double(k) * 0.5).prompt) }
        XCTAssertNotNil(tick(&chip, 5, at: 20.5).prompt)
    }

    /// 5
    func testResumeLandingPastTheTargetClearsImmediatelyOnCompletion() {
        let intervals = [interval(0, 90, "op"), interval(1400, 1440, "ed")]
        // Lands 8 s past the target inside the outro (HLS segment boundary): chip, no auto-skip.
        var inside = planner(intervals)
        inside.beginSeek(kind: .resume, targetSec: 1395, now: 0)
        inside.seekCompleted(atSec: 1403, now: 0.4)
        XCTAssertNil(inside.seekInFlight)
        let d = tick(&inside, 1406, at: 3, types: [.outro])
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
        // Lands 8 s past a target between segments: the outro still auto-skips on arrival.
        var between = planner(intervals)
        between.beginSeek(kind: .resume, targetSec: 1300, now: 0)
        between.seekCompleted(atSec: 1308, now: 0.4)
        XCTAssertEqual(tick(&between, 1311, at: 3, types: [.outro]), SkipSegmentPlanner.Decision())
        XCTAssertEqual(tick(&between, 1401, at: 6, types: [.outro]).autoSkipTargetSec, 1440)
    }

    /// 6
    func testIntroFollowingRecapStillAutoSkipsAfterTheRecapSkipLands() {
        for landing in [60.0, 66.0] {
            var p = planner([interval(0, 60, "recap"), interval(60, 150, "op")])
            XCTAssertEqual(tick(&p, 3, at: 0, types: [.recap, .intro]).autoSkipTargetSec, 60)
            p.beginSeek(kind: .auto, targetSec: 60, now: 0)
            XCTAssertEqual(tick(&p, 4, at: 0.5, types: [.recap, .intro]), SkipSegmentPlanner.Decision())
            p.seekCompleted(atSec: landing, now: 0.8)
            XCTAssertEqual(tick(&p, landing, at: 1, types: [.recap, .intro]).autoSkipTargetSec, 150, "landing \(landing)")
        }
    }

    /// 7
    func testChipPressShowsNoChipAndAllowsNoSecondSeekWhileInFlight() {
        var p = planner([interval(0, 90, "op")])
        XCTAssertNotNil(tick(&p, 10, at: 0).prompt)
        p.beginSeek(kind: .chip, targetSec: 90, fromSec: 10, now: 0.2)
        XCTAssertEqual(tick(&p, 10.2, at: 0.5), SkipSegmentPlanner.Decision())
        XCTAssertEqual(tick(&p, 10.4, at: 1, types: [.intro]), SkipSegmentPlanner.Decision())
        p.seekCompleted(atSec: 90, now: 1.2)
        XCTAssertEqual(tick(&p, 90, at: 1.5, types: [.intro]), SkipSegmentPlanner.Decision())
        // Skipped by the chip = consumed: coming back shows the chip, never auto-skips.
        p.beginSeek(kind: .user, targetSec: 20, fromSec: 90, now: 5)
        p.seekCompleted(atSec: 20, now: 5.3)
        let back = tick(&p, 20, at: 5.5, types: [.intro])
        XCTAssertNil(back.autoSkipTargetSec)
        XCTAssertNotNil(back.prompt)
    }

    func testChipPressStillInsideAfterCompletionDoesNotFlashTheChip() {
        var p = planner([interval(0, 90, "op")])
        XCTAssertNotNil(tick(&p, 10, at: 0).prompt)
        p.beginSeek(kind: .chip, targetSec: 90, fromSec: 10, now: 0.2)
        p.seekCompleted(atSec: 89.9, now: 0.5)   // keyframe just short of the end
        XCTAssertNil(tick(&p, 89.9, at: 1).prompt)
    }

    /// 8
    func testUserArrowSeekDuringResumeMarksTheIntervalActuallyLandedIn() {
        var p = planner([interval(0, 90, "op"), interval(1205, 1300, "ed")])
        p.beginSeek(kind: .resume, targetSec: 1200, now: 0)
        XCTAssertEqual(tick(&p, 0, at: 0.5, types: [.intro, .outro]), SkipSegmentPlanner.Decision())
        // The engine only has the stale cached position (0); mpv's relative seek goes to ~1210.
        p.beginSeek(kind: .user, targetSec: 10, fromSec: 0, now: 0.6)
        p.seekCompleted(atSec: 1210, now: 1)
        let d = tick(&p, 1210, at: 1.5, types: [.intro, .outro])
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
        // The stale 0 was not taken as the gesture's start: the intro is still armed.
        XCTAssertEqual(tick(&p, 5, at: 2, types: [.intro, .outro]).autoSkipTargetSec, 90)
    }

    /// 9
    func testReplayRearmsEveryIntervalAndIgnoresStaleEndOfFileTicks() {
        var p = planner([interval(0, 90, "op"), interval(1400, .greatestFiniteMagnitude, "ed")])
        let types: [AutoSkipSegmentType] = [.intro, .outro]
        // First viewing: both skipped.
        XCTAssertEqual(tick(&p, 5, at: 0, types: types).autoSkipTargetSec, 90)
        p.beginSeek(kind: .auto, targetSec: 90, now: 0)
        p.seekCompleted(atSec: 90, now: 0.5)
        XCTAssertEqual(tick(&p, 1401, at: 50, types: types).autoSkipTargetSec, episodeDuration - 0.5)
        p.beginSeek(kind: .auto, targetSec: episodeDuration - 0.5, now: 50)
        p.seekCompleted(atSec: episodeDuration - 0.5, now: 50.5)
        // Play Again: stale end-of-file ticks inside the (re-armed) outro produce nothing.
        p.beginSeek(kind: .replay, targetSec: 0, now: 100)
        for k in 1...25 {
            let d = tick(&p, episodeDuration - 0.5, at: 100 + Double(k) * 0.3, types: types)
            XCTAssertEqual(d, SkipSegmentPlanner.Decision(), "tick \(k)")
        }
        p.seekCompleted(atSec: 0, now: 108)
        XCTAssertEqual(tick(&p, 0.5, at: 108.5, types: types).autoSkipTargetSec, 90)
        p.beginSeek(kind: .auto, targetSec: 90, now: 108.5)
        p.seekCompleted(atSec: 90, now: 109)
        // Second viewing: the outro auto-skips again.
        XCTAssertNotNil(tick(&p, 1401, at: 200, types: types).autoSkipTargetSec)
    }

    func testReplayTimeoutAtEndOfFileHonoursStalePositionEvenWhenIntervalsArriveLate() {
        var p = SkipSegmentPlanner()
        p.beginSeek(kind: .replay, targetSec: 0, now: 0)
        for k in 1...25 { _ = tick(&p, episodeDuration - 0.5, at: Double(k) * 0.5, types: [.outro]) }
        p.setIntervals([interval(1400, .greatestFiniteMagnitude, "ed")])
        XCTAssertEqual(tick(&p, episodeDuration - 0.5, at: 13, types: [.outro]), SkipSegmentPlanner.Decision())
        // Position moves: normal behaviour.
        XCTAssertNotNil(tick(&p, 1401, at: 13.5, types: [.outro]).autoSkipTargetSec)
    }

    /// 10
    func testSeekCompletedWithNoSeekInFlightIsANoOp() {
        var p = planner([interval(0, 90, "op")])
        p.seekCompleted(atSec: 45, now: 0)   // e.g. mpv playback-restart at start or on a track switch
        XCTAssertNil(p.seekInFlight)
        XCTAssertEqual(tick(&p, 45, at: 0.5, types: [.intro]).autoSkipTargetSec, 90)
    }

    /// 11
    func testIntervalsArrivingAfterResumeCompletedInsideThemAreStillDeliberate() {
        var p = SkipSegmentPlanner()
        p.beginSeek(kind: .resume, targetSec: 45, now: 0)
        p.seekCompleted(atSec: 45, now: 0.5)
        _ = tick(&p, 45, at: 1, types: [.intro])
        p.setIntervals([interval(0, 90, "op")])
        let d = tick(&p, 48, at: 1.5, types: [.intro])
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
    }

    func testSetIntervalsDoesNotDropTheSeekInFlight() {
        var p = SkipSegmentPlanner()
        p.beginSeek(kind: .resume, targetSec: 45, now: 0)
        p.setIntervals([interval(0, 90, "op")])
        XCTAssertNotNil(p.seekInFlight)
        XCTAssertEqual(tick(&p, 0.2, at: 0.5, types: [.intro]), SkipSegmentPlanner.Decision())
        p.seekCompleted(atSec: 45, now: 1)
        XCTAssertNil(tick(&p, 45, at: 1.5, types: [.intro]).autoSkipTargetSec)
    }

    func testTransportScrubInterruptingTheAppsSkipSeekIsJudgedAsAUserScrub() {
        // Auto-skip of the intro in flight on a slow remux; the user scrubs into the outro, AVPlayer
        // cancels our seek (finished = false): the outro the user chose is never auto-skipped.
        var p = planner([interval(0, 90, "op"), interval(1300, 1380, "ed")])
        let types: [AutoSkipSegmentType] = [.intro, .outro]
        XCTAssertFalse(p.observeTick(fromSec: 2, toSec: 5, now: 0))
        XCTAssertEqual(tick(&p, 5, at: 0, types: types).autoSkipTargetSec, 90)
        p.beginSeek(kind: .auto, targetSec: 90, fromSec: 5, now: 0)
        p.seekInterrupted()
        XCTAssertNil(p.seekInFlight)
        XCTAssertTrue(p.observeTick(fromSec: 5, toSec: 1320, now: 3))
        let d = tick(&p, 1320, at: 3, types: types)
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
    }

    func testRejectedSeekGoesIdleWithoutStaleGuardOrLateCompletion() {
        // mpv rejected the resume seek: playback simply continues from where it is.
        var p = planner([interval(0, 90, "op"), interval(1300, 1380, "ed")])
        p.beginSeek(kind: .resume, targetSec: 1200, now: 0)
        p.seekInterrupted()
        // No stale guard: the unchanged position is evaluated normally at once.
        XCTAssertEqual(tick(&p, 5, at: 0.5, types: [.intro, .outro]).autoSkipTargetSec, 90)
        // No late-completion record: a later mpv-internal restart is not taken as the resume.
        p.seekCompleted(atSec: 1320, now: 5)
        XCTAssertEqual(tick(&p, 1320, at: 5.5, types: [.intro, .outro]).autoSkipTargetSec, 1380)
        // Nothing in flight: a no-op.
        p.seekInterrupted()
        XCTAssertNil(p.seekInFlight)
    }

    /// 12
    func testScrubDetectedByJumpIsDeliberateButTheAppsOwnCompletedSeekIsNot() {
        // A system-transport scrub into the outro: deliberate.
        var p = planner([interval(0, 90, "op"), interval(1300, 1380, "ed")])
        XCTAssertTrue(p.observeTick(fromSec: 1000, toSec: 1320, now: 0))
        let scrub = tick(&p, 1320, at: 0, types: [.intro, .outro])
        XCTAssertNil(scrub.autoSkipTargetSec)
        XCTAssertNotNil(scrub.prompt)

        // The app's own skip completing between ticks: the next tick's jump is not a user scrub.
        var q = planner([interval(0, 90, "op"), interval(95, 180, "recap")])
        XCTAssertFalse(q.observeTick(fromSec: 0, toSec: 3, now: 0))
        XCTAssertEqual(tick(&q, 3, at: 0, types: [.intro, .recap]).autoSkipTargetSec, 90)
        q.beginSeek(kind: .auto, targetSec: 90, now: 0)
        q.seekCompleted(atSec: 90, now: 0.4)
        XCTAssertFalse(q.observeTick(fromSec: 3, toSec: 96, now: 3))
        XCTAssertEqual(tick(&q, 96, at: 3, types: [.intro, .recap]).autoSkipTargetSec, 180)
        // A jump seen while an app seek is still in flight is not a scrub either.
        q.beginSeek(kind: .auto, targetSec: 180, now: 3)
        XCTAssertFalse(q.observeTick(fromSec: 96, toSec: 180, now: 6))
        q.seekCompleted(atSec: 180, now: 6.2)
        XCTAssertFalse(q.observeTick(fromSec: 180, toSec: 183, now: 9))
        // Later genuine scrubs are still detected.
        XCTAssertTrue(q.observeTick(fromSec: 183, toSec: 40, now: 12))
        XCTAssertNil(tick(&q, 40, at: 12, types: [.intro, .recap]).autoSkipTargetSec)
    }

    // MARK: - Two-stage gesture (P1 preview-then-commit)

    func testRefineSeekAfterKeyframesLandingKeepsOneGestureSpan() {
        var p = planner([interval(100, 190, "op")])
        p.beginSeek(kind: .user, targetSec: 140, fromSec: 50, now: 0)
        p.seekCompleted(atSec: 138, now: 0.3)
        p.refineSeek(targetSec: 140, fromSec: 50, now: 0.45)
        XCTAssertNotNil(p.seekInFlight)
        p.seekCompleted(atSec: 140, now: 0.8)
        XCTAssertNil(p.seekInFlight)
        let d = tick(&p, 141, at: 1.2, types: [.intro])
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
    }

    func testRefineSeekWhileKeyframesInFlightReplacesTarget() {
        var p = planner([interval(100, 190, "op")])
        p.beginSeek(kind: .user, targetSec: 140, fromSec: 50, now: 0)
        p.refineSeek(targetSec: 160, fromSec: 140, now: 0.2)
        XCTAssertEqual(p.seekInFlight?.targetSec, 160)
        XCTAssertEqual(p.seekInFlight?.fromSec, 50)
        XCTAssertEqual(p.seekInFlight?.kind, .user)
    }

    func testRefineSeekDoesNotResetChipSuppression() {
        var p = planner([interval(100, 190, "op")])
        XCTAssertNotNil(tick(&p, 120, at: 0).prompt)
        p.beginSeek(kind: .chip, targetSec: 190, now: 1)
        p.refineSeek(targetSec: 125, fromSec: 120, now: 1.1)
        p.seekCompleted(atSec: 125, now: 1.4)
        XCTAssertNil(tick(&p, 126, at: 1.8).prompt)
        XCTAssertNil(tick(&p, 127, at: 2.0, types: [.intro]).autoSkipTargetSec)
    }

    func testRecordUserSpanConsumesScannedIntervals() {
        var control = planner([interval(100, 190, "op")])
        XCTAssertEqual(tick(&control, 120, at: 0, types: [.intro]).autoSkipTargetSec, 190)

        var p = planner([interval(100, 190, "op")])
        p.recordUserSpan(fromSec: 0, toSec: 300)
        p.beginSeek(kind: .user, targetSec: 120, fromSec: 300, now: 5)
        p.seekCompleted(atSec: 120, now: 5.3)
        XCTAssertNil(tick(&p, 120, at: 6, types: [.intro]).autoSkipTargetSec)
    }
}
