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
