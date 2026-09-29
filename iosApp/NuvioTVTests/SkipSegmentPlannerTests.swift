import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for `SkipSegmentPlanner` (`Screens/Player/SkipSegmentPlanner.swift`) — the pure skip
/// chip / auto-skip policy both player engines share (upstream cbe4dc0a..77ce8a73, tvOS half).
/// Intervals are real SharedCore `SkipInterval`s, so the shared `internalSkipAction` /
/// `intervalsAtSeekPositions` semantics are exercised too. Durations stay above the shared
/// short-placeholder floor (121 s), below which no skip action exists.
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

    // MARK: - Chip

    func testChipOffersIntroSkipToIntervalEnd() {
        var p = planner([interval(0, 90, "op")])
        let d = p.evaluate(positionSec: 10, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil)
        XCTAssertEqual(d.prompt, SkipPrompt(label: String(localized: "Skip Intro"), targetSec: 90))
        XCTAssertNil(d.autoSkipTargetSec)
    }

    func testChipHidesInTheLastSecondAndOutsideIntervals() {
        var p = planner([interval(0, 90, "op")])
        XCTAssertNil(p.evaluate(positionSec: 89.5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil).prompt)
        XCTAssertNil(p.evaluate(positionSec: 95, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil).prompt)
    }

    func testNoChipForPostCreditsInterval() {
        let credits = interval(6000, 6300, "movie-credits")
        let scene = interval(6400, 6500, "post-credits")
        var p = planner([credits, scene])
        XCTAssertNil(p.evaluate(positionSec: 6450, durationSec: movieDuration, isPlaying: true, autoSkipTypes: nil).prompt)
    }

    func testMovieCreditsSkipLandsOnPostCreditsSceneStart() {
        var p = planner([interval(6000, 6300, "movie-credits"), interval(6400, 6500, "post-credits")])
        let d = p.evaluate(positionSec: 6100, durationSec: movieDuration, isPlaying: true, autoSkipTypes: nil)
        XCTAssertEqual(d.prompt, SkipPrompt(label: String(localized: "Skip to Post-Credits"), targetSec: 6400))
    }

    func testMovieCreditsWithoutSceneOrTailSaysSkipCredits() {
        var p = planner([interval(6000, 6598, "movie-credits")])
        let d = p.evaluate(positionSec: 6100, durationSec: movieDuration, isPlaying: true, autoSkipTypes: nil)
        XCTAssertEqual(d.prompt, SkipPrompt(label: String(localized: "Skip Credits"), targetSec: 6598))
    }

    func testTargetIsClampedShortOfKnownDuration() {
        // Open-ended episode outro (Double.greatestFiniteMagnitude sentinel) stays actionable.
        var p = planner([interval(1400, .greatestFiniteMagnitude, "ed")])
        let d = p.evaluate(positionSec: 1450, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil)
        XCTAssertEqual(d.prompt?.targetSec, episodeDuration - 0.5)
    }

    func testOutroWithTailButNoExplicitPostCreditsSaysSkipOutro() {
        // Fork rule: the shared heuristic flags skipsToPostCredits for any >5 s tail (here 60 s of
        // next-episode preview); without an explicit post-credits interval the label stays "Skip Outro".
        var p = planner([interval(1380, 1440, "ed")])
        let d = p.evaluate(positionSec: 1400, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil)
        XCTAssertEqual(d.prompt, SkipPrompt(label: String(localized: "Skip Outro"), targetSec: 1440))
    }

    func testLabels() {
        XCTAssertEqual(SkipSegmentPlanner.label(for: "mixed-ed", skipsToPostCredits: false), String(localized: "Skip Outro"))
        XCTAssertEqual(SkipSegmentPlanner.label(for: "recap", skipsToPostCredits: false), String(localized: "Skip Recap"))
        XCTAssertEqual(SkipSegmentPlanner.label(for: "ed", skipsToPostCredits: true), String(localized: "Skip to Post-Credits"))
        XCTAssertEqual(SkipSegmentPlanner.label(for: "unknown", skipsToPostCredits: false), String(localized: "Skip Intro"))
    }

    // MARK: - Auto-skip

    func testAutoSkipFiresOncePerInterval() {
        var p = planner([interval(0, 90, "op")])
        let first = p.evaluate(positionSec: 5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
        XCTAssertEqual(first.autoSkipTargetSec, 90)
        XCTAssertNil(first.prompt)
        // A stale pre-seek tick still inside: neither a second skip nor a chip flash.
        let stale = p.evaluate(positionSec: 6, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
        XCTAssertNil(stale.autoSkipTargetSec)
        XCTAssertNil(stale.prompt)
        // Landed past it, then the user goes back in: chip only, no second auto-skip.
        _ = p.evaluate(positionSec: 90, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
        let back = p.evaluate(positionSec: 6, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
        XCTAssertNil(back.autoSkipTargetSec)
        XCTAssertNotNil(back.prompt)
    }

    func testAutoSkipNeedsSelectedTypePlayingAndSkipIntro() {
        var p = planner([interval(0, 90, "op")])
        XCTAssertNil(p.evaluate(positionSec: 5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.outro]).autoSkipTargetSec)
        XCTAssertNil(p.evaluate(positionSec: 5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: []).autoSkipTargetSec)
        XCTAssertNil(p.evaluate(positionSec: 5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil).autoSkipTargetSec)
        XCTAssertNil(p.evaluate(positionSec: 5, durationSec: episodeDuration, isPlaying: false, autoSkipTypes: [.intro]).autoSkipTargetSec)
        // None of the above consumed the interval.
        XCTAssertEqual(p.evaluate(positionSec: 5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec, 90)
    }

    func testAutoSkippedMovieCreditsLandOnTheScene() {
        var p = planner([interval(6000, 6300, "movie-credits"), interval(6400, 6500, "post-credits")])
        let d = p.evaluate(positionSec: 6001, durationSec: movieDuration, isPlaying: true, autoSkipTypes: [.movieCredits])
        XCTAssertEqual(d.autoSkipTargetSec, 6400)
        // The scene itself is never auto-skipped, whatever is selected.
        XCTAssertNil(p.evaluate(positionSec: 6401, durationSec: movieDuration, isPlaying: true,
                                autoSkipTypes: AutoSkipSegmentType.entries).autoSkipTargetSec)
    }

    func testResetForReplayRearmsConsumedInterval() {
        var p = planner([interval(0, 90, "op")])
        XCTAssertEqual(p.evaluate(positionSec: 5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec, 90)
        _ = p.evaluate(positionSec: 100, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
        p.noteUserSeek(fromSec: 1400, toSec: 20)
        XCTAssertNil(p.evaluate(positionSec: 21, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec)
        p.resetForReplay()
        XCTAssertEqual(p.evaluate(positionSec: 1, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec, 90)
    }

    /// Mirrors the coordinator's per-tick wiring: filter -> `noteUserSeek` -> `evaluate`.
    private struct TickHarness {
        var planner: SkipSegmentPlanner
        var filter = ProgrammaticSeekFilter()
        var last: Double = 0
        let duration: Double
        let types: [AutoSkipSegmentType]

        mutating func tick(_ pos: Double) -> SkipSegmentPlanner.Decision {
            if filter.isUserSeek(last: last, new: pos) { planner.noteUserSeek(fromSec: last, toSec: pos) }
            let decision = planner.evaluate(positionSec: pos, durationSec: duration, isPlaying: true, autoSkipTypes: types)
            last = pos
            return decision
        }
    }

    private func recapIntroHarness() -> TickHarness {
        TickHarness(planner: planner([interval(0, 60, "recap"), interval(60, 150, "op")]),
                    duration: episodeDuration, types: [.recap, .intro])
    }

    func testIntroFollowingRecapAutoSkipsAfterOwnSeekThroughTheFilter() {
        var h = recapIntroHarness()
        XCTAssertEqual(h.tick(3).autoSkipTargetSec, 60)
        h.filter.noteProgrammaticSeek(from: 3, to: 60)
        XCTAssertNil(h.tick(4).autoSkipTargetSec)          // stale pre-seek tick
        XCTAssertEqual(h.tick(66).autoSkipTargetSec, 150)  // landing after a keyframe: not a user seek
    }

    func testWithoutTheFilterTheOwnSeekConsumesTheFollowingIntro() {
        var h = recapIntroHarness()
        XCTAssertEqual(h.tick(3).autoSkipTargetSec, 60)
        // No noteProgrammaticSeek: the 3 -> 66 jump is forwarded as a user seek and consumes the intro.
        XCTAssertNil(h.tick(66).autoSkipTargetSec)
    }

    func testSlowReplayNeverAutoSkipsOnStalePositionAndOutroStillArmsForSecondViewing() {
        var p = planner([interval(0, 90, "op"), interval(1400, .greatestFiniteMagnitude, "ed")])
        p.resetForReplay()
        let types: [AutoSkipSegmentType] = [.intro, .outro]
        for tick in 1...25 {
            let d = p.evaluate(positionSec: episodeDuration - 0.5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: types)
            XCTAssertNil(d.autoSkipTargetSec, "tick \(tick)")
            XCTAssertNil(d.prompt, "tick \(tick)")
        }
        XCTAssertEqual(p.evaluate(positionSec: 1, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: types).autoSkipTargetSec, 90)
        // Second viewing: the playhead reaches the outro naturally and it still auto-skips.
        XCTAssertNotNil(p.evaluate(positionSec: 1401, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: types).autoSkipTargetSec)
    }

    func testFailedResumeSeekWithRealPlaybackRestoresChipAndAutoSkipAfterTimeout() {
        let intervals = [interval(0, 90, "op"), interval(1400, .greatestFiniteMagnitude, "ed")]
        // Resume to 1200 never happens; the stream plays from 0 (0.5 s per tick).
        var auto = planner(intervals)
        auto.noteResumeSeek(toSec: 1200)
        for tick in 1..<20 {
            let d = auto.evaluate(positionSec: Double(tick) * 0.5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
            XCTAssertNil(d.autoSkipTargetSec, "tick \(tick)")
            XCTAssertNil(d.prompt, "tick \(tick)")
        }
        XCTAssertEqual(auto.evaluate(positionSec: 10, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec, 90)

        var chip = planner(intervals)
        chip.noteResumeSeek(toSec: 1200)
        for tick in 1..<20 { _ = chip.evaluate(positionSec: Double(tick) * 0.5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil) }
        XCTAssertEqual(chip.evaluate(positionSec: 10, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil).prompt?.label,
                       String(localized: "Skip Intro"))
    }

    func testStalePositionWithActionlessIntervalListedFirstNeverAutoSkips() {
        // `post-credits` has no skip action; evaluate skips it, and the marker is position-based.
        var p = planner([interval(1450, 1500, "post-credits"), interval(1400, .greatestFiniteMagnitude, "ed")])
        p.resetForReplay()
        for tick in 1...25 {
            let d = p.evaluate(positionSec: episodeDuration - 0.5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.outro])
            XCTAssertNil(d.autoSkipTargetSec, "tick \(tick)")
        }
    }

    func testIntervalsArrivingAfterTheTimeoutStillHonourTheStaleMarker() {
        var p = SkipSegmentPlanner()
        p.resetForReplay()
        for _ in 1...25 {
            _ = p.evaluate(positionSec: episodeDuration - 0.5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.outro])
        }
        p.setIntervals([interval(1400, .greatestFiniteMagnitude, "ed")])
        let stale = p.evaluate(positionSec: episodeDuration - 0.5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.outro])
        XCTAssertNil(stale.autoSkipTargetSec)
        XCTAssertNil(stale.prompt)
        // Position moves: normal behaviour.
        XCTAssertNotNil(p.evaluate(positionSec: 1401, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.outro]).autoSkipTargetSec)
    }

    func testNormalResumeLandingShowsChipAndKeepsLaterIntervalsArmed() {
        let intervals = [interval(0, 90, "op"), interval(1400, 1440, "ed")]
        // Chip: resume lands inside the outro after two stale ticks.
        var chip = planner(intervals)
        chip.noteResumeSeek(toSec: 1410)
        for _ in 0..<2 {
            let d = chip.evaluate(positionSec: 0.2, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil)
            XCTAssertNil(d.prompt)
        }
        XCTAssertNotNil(chip.evaluate(positionSec: 1410, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil).prompt)
        // Later interval: resume lands between segments, the outro still auto-skips.
        var later = planner(intervals)
        later.noteResumeSeek(toSec: 600)
        _ = later.evaluate(positionSec: 600, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.outro])
        XCTAssertEqual(later.evaluate(positionSec: 1401, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.outro]).autoSkipTargetSec, 1440)
    }

    func testResetForReplayHoldsAutoSkipUntilPlayheadReturnsToStart() {
        var p = planner([interval(0, 90, "op"), interval(1400, .greatestFiniteMagnitude, "ed")])
        p.resetForReplay()
        // Stale end-of-file position inside the open-ended outro: no auto-skip, no chip.
        let stale = p.evaluate(positionSec: episodeDuration - 0.5, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro, .outro])
        XCTAssertNil(stale.autoSkipTargetSec)
        XCTAssertNil(stale.prompt)
        // Playhead back at the start: the intro (not consumed by the reset) auto-skips.
        XCTAssertEqual(p.evaluate(positionSec: 1, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro, .outro]).autoSkipTargetSec, 90)
    }

    func testMalformedPostCreditsEntryDoesNotEarnPostCreditsLabel() {
        // Tail after the outro exists (heuristic flag), but the only post-credits entry is invalid
        // (end <= start) or starts past the duration: the normal label is used.
        for bad in [interval(1450, 1450, "post-credits"), interval(1600, 1650, "post-credits")] {
            var p = planner([interval(1380, 1440, "ed"), bad])
            let d = p.evaluate(positionSec: 1400, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: nil)
            XCTAssertEqual(d.prompt?.label, String(localized: "Skip Outro"))
        }
    }

    // MARK: - Programmatic seek filter

    func testProgrammaticSeekIsNotAUserSeekEvenWithAStaleTick() {
        var f = ProgrammaticSeekFilter()
        f.noteProgrammaticSeek(from: 3, to: 63)
        XCTAssertFalse(f.isUserSeek(last: 3, new: 4))     // stale pre-seek tick
        XCTAssertFalse(f.isUserSeek(last: 4, new: 64))    // landing
        XCTAssertFalse(f.isUserSeek(last: 64, new: 67))   // normal playback
    }

    func testLandingAfterKeyframeAndOneTickIsNotAUserSeek() {
        var f = ProgrammaticSeekFilter()
        f.noteProgrammaticSeek(from: 3, to: 60)
        XCTAssertFalse(f.isUserSeek(last: 3, new: 66))   // target + 6 after one tick
    }

    // A back-scrub outside the stale window clears the pending seek and is judged by the plain 10 s jump rule.
    func testBackScrubWhilePendingIsJudgedByTheNormalJumpRule() {
        var f = ProgrammaticSeekFilter()
        f.noteProgrammaticSeek(from: 100, to: 160)
        XCTAssertTrue(f.isUserSeek(last: 100, new: 85))    // 15 s back: exceeds the jump threshold

        var g = ProgrammaticSeekFilter()
        g.noteProgrammaticSeek(from: 100, to: 160)
        XCTAssertFalse(g.isUserSeek(last: 100, new: 92))   // 8 s back: under the threshold
        XCTAssertTrue(g.isUserSeek(last: 92, new: 160))    // pending was cleared: judged normally, not a landing
    }

    func testUserScrubAfterProgrammaticSeekIsStillDetected() {
        var f = ProgrammaticSeekFilter()
        f.noteProgrammaticSeek(from: 3, to: 63)
        XCTAssertFalse(f.isUserSeek(last: 3, new: 64))
        XCTAssertTrue(f.isUserSeek(last: 64, new: 400))
        // A scrub before the landing tick is detected too.
        f.noteProgrammaticSeek(from: 100, to: 160)
        XCTAssertTrue(f.isUserSeek(last: 100, new: 900))
    }

    func testPlainJumpDetectionWithoutPendingSeek() {
        var f = ProgrammaticSeekFilter()
        XCTAssertFalse(f.isUserSeek(last: 10, new: 13))
        XCTAssertTrue(f.isUserSeek(last: 10, new: 40))
    }

    // MARK: - Deliberate entry

    func testUserSeekLandingInsideSuppressesAutoSkip() {
        var p = planner([interval(1300, 1380, "ed")])
        p.noteUserSeek(fromSec: 1000, toSec: 1320)
        let d = p.evaluate(positionSec: 1320, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.outro])
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
    }

    func testUserSeekStartingInsideSuppressesAutoSkip() {
        var p = planner([interval(0, 90, "op")])
        p.noteUserSeek(fromSec: 30, toSec: 20)
        XCTAssertNil(p.evaluate(positionSec: 20, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec)
    }

    func testSeekOutsideLeavesOtherIntervalsArmed() {
        var p = planner([interval(0, 90, "op"), interval(1300, 1380, "ed")])
        p.noteUserSeek(fromSec: 10, toSec: 200)   // started inside the intro only
        XCTAssertEqual(p.evaluate(positionSec: 1301, durationSec: episodeDuration, isPlaying: true,
                                  autoSkipTypes: [.outro]).autoSkipTargetSec, 1380)
    }

    func testResumeLandingInsideSuppressesAutoSkip() {
        var p = planner([interval(0, 90, "op")])
        p.noteResumeSeek(toSec: 45)
        let d = p.evaluate(positionSec: 45, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
        XCTAssertNil(d.autoSkipTargetSec)
        XCTAssertNotNil(d.prompt)
    }

    func testStalePositionBeforeResumeLandsNeverAutoSkips() {
        var p = planner([interval(0, 90, "op")])
        p.noteResumeSeek(toSec: 600)
        // The engine still reports the pre-seek position inside the intro.
        XCTAssertNil(p.evaluate(positionSec: 0.2, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec)
        _ = p.evaluate(positionSec: 600, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
        // Landed: a later genuine entry (e.g. replay from 0) is armed again.
        XCTAssertEqual(p.evaluate(positionSec: 1, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec, 90)
    }

    func testUnknownResumeTargetUsesFirstRealPositionAsLanding() {
        var p = planner([interval(100, 190, "op")])
        p.noteResumeSeek(toSec: nil)
        XCTAssertNil(p.evaluate(positionSec: 0, durationSec: 0, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec)
        XCTAssertNil(p.evaluate(positionSec: 150, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec)
        XCTAssertNil(p.evaluate(positionSec: 151, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec)
    }

    func testSeekNotedBeforeIntervalsArriveStillSuppresses() {
        var p = SkipSegmentPlanner()
        p.noteResumeSeek(toSec: 45)
        _ = p.evaluate(positionSec: 45, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro])
        p.setIntervals([interval(0, 90, "op")])
        XCTAssertNil(p.evaluate(positionSec: 48, durationSec: episodeDuration, isPlaying: true, autoSkipTypes: [.intro]).autoSkipTargetSec)
    }
}
