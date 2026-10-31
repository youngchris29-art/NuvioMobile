import XCTest
import SwiftUI
@testable import NuvioTV

/// BUG-96 (beta.18): the unit-point math that lands a focused detail row's top at
/// `DetailRowAnchor.topInset`. `scrollTo(_:anchor:)` aligns the row's anchor point with the scroll
/// view's same anchor point, so the point is solved, not guessed.
final class DetailRowAnchorTests: XCTestCase {

    /// Given the solved point, the row's top lands at the inset: `row.minY = k·vh − k·rh`.
    private func landedTop(rowHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let k = DetailRowAnchor.anchor(rowHeight: rowHeight, viewportHeight: viewportHeight).y
        return k * viewportHeight - k * rowHeight
    }

    func testTypicalRowsLandAtTheInset() {
        for rowHeight: CGFloat in [180, 320, 420, 560] {
            XCTAssertEqual(landedTop(rowHeight: rowHeight, viewportHeight: 1080),
                           DetailRowAnchor.topInset, accuracy: 0.001,
                           "row \(rowHeight)pt must rest with its top at the inset")
        }
    }

    func testAnchorXIsLeading() {
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 300, viewportHeight: 1080).x, 0)
    }

    func testARowTallerThanTheViewportTopAligns() {
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 1200, viewportHeight: 1080), .top)
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 1080, viewportHeight: 1080), .top)
    }

    func testAnchorNeverLeavesTheUnitRange() {
        // A row nearly as tall as the viewport would need k > 1 to reach the inset; it is clamped.
        let point = DetailRowAnchor.anchor(rowHeight: 1060, viewportHeight: 1080)
        XCTAssertEqual(point.y, 1, accuracy: 0.001)
        XCTAssertEqual(DetailRowAnchor.anchor(rowHeight: 0, viewportHeight: 1080, topInset: 0).y, 0)
    }

    func testCustomInsetIsHonoured() {
        XCTAssertEqual(landedTopWithInset(48), 48, accuracy: 0.001)
    }

    private func landedTopWithInset(_ inset: CGFloat) -> CGFloat {
        let k = DetailRowAnchor.anchor(rowHeight: 300, viewportHeight: 1080, topInset: inset).y
        return k * 1080 - k * 300
    }
}

/// BUG-99 (rc6, u/mrStevenx3): `DetailRowAnchor.decision` is the pure rule behind the direction
/// split — Up always anchors (unchanged behaviour); Down anchors only when the row's current
/// on-screen top straddles (is at or under) the `topScrimHeight` scrim near the top edge, i.e. is
/// below `screenRest`'s threshold, and otherwise stays `.free` so the engine's own minimal reveal
/// is left alone. See `DetailRowAnchor`'s doc comment for the tester report this decouples.
final class DetailRowAnchorDecisionTests: XCTestCase {
    func testUpAlwaysAnchorsRegardlessOfScreenTop() {
        XCTAssertEqual(DetailRowAnchor.decision(direction: .up, screenTop: 600, screenRest: DetailRowAnchor.screenRest), .anchor)
        XCTAssertEqual(DetailRowAnchor.decision(direction: .up, screenTop: 60, screenRest: DetailRowAnchor.screenRest), .anchor)
        XCTAssertEqual(DetailRowAnchor.decision(direction: .up, screenTop: 0, screenRest: DetailRowAnchor.screenRest), .anchor)
    }

    func testDownStaysFreeWhenClearOfTheRest() {
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: 600, screenRest: DetailRowAnchor.screenRest), .free)
    }

    func testDownAnchorsWhenStraddlingTheTopScrim() {
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: 60, screenRest: DetailRowAnchor.screenRest), .anchor)
    }

    func testDownBoundaryAtScreenRestIsFree() {
        // Closed lower bound on the FREE side: a row already resting exactly at `screenRest` does
        // not need rescuing, so the boundary itself must not anchor (only strictly *above* the
        // rest — a smaller screenTop — does).
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: DetailRowAnchor.screenRest, screenRest: DetailRowAnchor.screenRest), .free)
    }
}

/// Codex P2 review finding (BUG-99 follow-up, round 2): `DetailRowAnchor.direction` is the pure
/// rule behind which way a focus change moved, factored out of `DetailView.onChange(of:
/// focusedRow)` so every case is covered without a live view. Round 1 needed a `lastKnownTop`/
/// `contentOffset` heuristic because `focusedRow` reported nil both in the unanchored top block AND
/// in the (then-untracked) Comments section, and that heuristic broke whenever Comments was
/// reachable without scrolling past the last row's own rest. Round 2 makes Comments a TRACKED row
/// instead (`commentsSection` now carries `.detailRowAnchored(.comments, …)`), which retires the
/// heuristic entirely: `old == nil` now means only one thing — the top block.
final class DetailRowAnchorDirectionTests: XCTestCase {
    func testOldNilIsDown() {
        // The only row that ever reports `focusedRow == nil` now is the unanchored top block.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: nil, oldTop: nil, newTop: 300),
            .down
        )
    }

    func testOldAboveIsDown() {
        // The row that just lost focus sits higher in the content (a smaller top) than the
        // newly-focused one.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: .cast, oldTop: 300, newTop: 900),
            .down
        )
    }

    func testOldBelowIsUp() {
        // The row that just lost focus sits lower in the content than the newly-focused one —
        // covers an ordinary anchored-row-to-anchored-row Up, and leaving Comments (now a real,
        // measured row sitting below everything else) for any row above it.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: .comments, oldTop: 900, newTop: 300),
            .up
        )
    }

    func testOldCommentsWithMissingTopIsUp() {
        // Comments' very first `onGeometryChange` callback has not landed yet, so its top is
        // missing from the map even though `old` itself is `.comments` — Comments sits below every
        // anchored row, so leaving it can only be Up.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: .comments, oldTop: nil, newTop: 300),
            .up
        )
    }

    func testOldOtherRowWithMissingTopIsDown() {
        // Any other row's top dropping out of the map falls back to the original default: Down.
        XCTAssertEqual(
            DetailRowAnchor.direction(old: .cast, oldTop: nil, newTop: 300),
            .down
        )
    }
}

/// BUG-96 (Codex P2 follow-up): `DetailScrollMotion.segments` is the `moves=` oracle — one motion
/// (engine reveal blended with the anchor pass) must read as `1`, and the old land-then-nudge
/// design (a settle wait long enough for the engine to fully rest before the anchor slid it again)
/// would read as `2`. The split is TIME-based (see `DetailScrollMotion`'s doc comment for why:
/// `onScrollGeometryChange` delivers changes only, so a genuine pause can produce zero samples),
/// so every fixture here is a timestamped `MotionSample` array, not a bare offset array — these
/// shapes are ones the real callback can actually produce, unlike the old plateau-of-N-samples
/// fixtures it replaces.
final class DetailScrollMotionTests: XCTestCase {

    /// Builds a run of samples moving at a fixed cadence, starting at `t0`/`offset0`, each
    /// `interval` seconds after the last and `step` points further (step magnitude always at or
    /// above `stationaryThreshold` so every sample in the ramp counts as moving).
    private func ramp(t0: TimeInterval, offset0: CGFloat, count: Int, interval: TimeInterval, step: CGFloat) -> [MotionSample] {
        (0..<count).map { i in
            MotionSample(time: t0 + TimeInterval(i) * interval, offset: offset0 + CGFloat(i) * step)
        }
    }

    func testSingleRampIsOneSegment() {
        // 10 samples, 16ms apart (one 30fps-ish cadence), steadily moving.
        let samples = ramp(t0: 0, offset0: 0, count: 10, interval: 0.016, step: 20)
        XCTAssertEqual(DetailScrollMotion.segments(samples), 1)
    }

    func testRampPauseRampIsTwoSegments() {
        // A ramp, a 350ms gap (comfortably above `pauseToSplit` — the engine's reveal finishing
        // and the anchor pass starting, the old land-then-nudge shape), then a second ramp.
        let ramp1 = ramp(t0: 0, offset0: 0, count: 5, interval: 0.016, step: 20)
        let ramp2 = ramp(t0: (ramp1.last?.time ?? 0) + 0.350, offset0: 90, count: 5, interval: 0.016, step: 20)
        XCTAssertEqual(DetailScrollMotion.segments(ramp1 + ramp2), 2)
    }

    func testRampWithOneHiccupInsideIsOneSegment() {
        // A ramp where one inter-sample gap is 40ms instead of the usual 16ms — a dropped frame,
        // not a pause — must still read as one continuous motion (well under `pauseToSplit`, 0.10s).
        let samples: [MotionSample] = [
            MotionSample(time: 0.000, offset: 0),
            MotionSample(time: 0.016, offset: 20),
            MotionSample(time: 0.032, offset: 40),
            MotionSample(time: 0.072, offset: 60), // 40ms hiccup here
            MotionSample(time: 0.088, offset: 80),
            MotionSample(time: 0.104, offset: 100),
            MotionSample(time: 0.120, offset: 120)
        ]
        XCTAssertEqual(DetailScrollMotion.segments(samples), 1)
    }

    func testLoneJitterSampleAfterALongGapDoesNotStartASegment() {
        // A ramp (one segment), then a 400ms gap, then a single sub-threshold jitter sample —
        // sub-pixel `ScrollView` noise, not real motion — must not itself start a second segment.
        let ramp1 = ramp(t0: 0, offset0: 0, count: 5, interval: 0.016, step: 20)
        let jitter = MotionSample(time: (ramp1.last?.time ?? 0) + 0.400, offset: (ramp1.last?.offset ?? 0) + 0.3)
        XCTAssertEqual(DetailScrollMotion.segments(ramp1 + [jitter]), 1)
    }

    func testEmptyAndSingleSampleAreZeroSegments() {
        XCTAssertEqual(DetailScrollMotion.segments([]), 0)
        XCTAssertEqual(DetailScrollMotion.segments([MotionSample(time: 0, offset: 42)]), 0)
    }

    func testTwoRampsExactlyPauseToSplitApartIsTwoSegments() {
        // Boundary inclusive: a gap of exactly `pauseToSplit` (0.10s) since the last moving sample
        // must split, not join — `segments` treats the split as `gap >= pauseToSplit`.
        let ramp1 = ramp(t0: 0, offset0: 0, count: 3, interval: 0.016, step: 20)
        let ramp2 = ramp(t0: (ramp1.last?.time ?? 0) + DetailScrollMotion.pauseToSplit, offset0: 60, count: 3, interval: 0.016, step: 20)
        XCTAssertEqual(DetailScrollMotion.segments(ramp1 + ramp2), 2)
    }
}

/// FEAT-35 (Detail revamp, P1 §F + correction 9): the Cinematic hero's two transitions. `.exit` is
/// nil → row with the page at its top; `.enterHero` is any row → nil; the rest are ordinary.
@MainActor
final class DetailRowAnchorHeroTransitionTests: XCTestCase {
    func testHeroTransitionTable() {
        XCTAssertEqual(DetailRowAnchor.heroTransition(old: nil, new: .logos, pageAtTop: true), .exit)
        XCTAssertEqual(DetailRowAnchor.heroTransition(old: nil, new: .episodes, pageAtTop: true), .exit)
        XCTAssertEqual(DetailRowAnchor.heroTransition(old: .cast, new: nil, pageAtTop: false), .enterHero)
        XCTAssertEqual(DetailRowAnchor.heroTransition(old: .episodes, new: nil, pageAtTop: true), .enterHero)
        XCTAssertEqual(DetailRowAnchor.heroTransition(old: nil, new: nil, pageAtTop: true), DetailRowAnchor.HeroTransition.none)
        XCTAssertEqual(DetailRowAnchor.heroTransition(old: .cast, new: .trailers, pageAtTop: true), DetailRowAnchor.HeroTransition.none)
    }

    /// Correction 9: focus restored to a deep row after a push or a cover (Cast → Person → Back)
    /// also reads nil → row; with the page away from the top it must not be a hero exit.
    func testExitNeedsThePageAtTheTop() {
        XCTAssertEqual(DetailRowAnchor.heroTransition(old: nil, new: .cast, pageAtTop: false), DetailRowAnchor.HeroTransition.none)
        XCTAssertFalse(DetailRowAnchor.heroExit(old: nil, new: .cast, pageAtTop: false))
        XCTAssertTrue(DetailRowAnchor.heroExit(old: nil, new: .cast, pageAtTop: true))
    }

    func testExitAndReturnMirrorTheTable() {
        XCTAssertTrue(DetailRowAnchor.heroExit(old: nil, new: .logos, pageAtTop: true))
        XCTAssertFalse(DetailRowAnchor.heroExit(old: .cast, new: nil, pageAtTop: true))
        XCTAssertFalse(DetailRowAnchor.heroExit(old: nil, new: nil, pageAtTop: true))
        XCTAssertFalse(DetailRowAnchor.heroExit(old: .cast, new: .trailers, pageAtTop: true))

        XCTAssertTrue(DetailRowAnchor.heroReturn(old: .cast, new: nil))
        XCTAssertTrue(DetailRowAnchor.heroReturn(old: .episodes, new: nil))
        XCTAssertTrue(DetailRowAnchor.heroReturn(old: .about, new: nil))
        XCTAssertFalse(DetailRowAnchor.heroReturn(old: nil, new: .logos))
        XCTAssertFalse(DetailRowAnchor.heroReturn(old: nil, new: nil))
        XCTAssertFalse(DetailRowAnchor.heroReturn(old: .cast, new: .trailers))
    }

    func testHeroTopScrollTargetIsZero() {
        XCTAssertEqual(DetailRowAnchor.heroTopScrollTarget, 0)
    }

    /// The top rests at `contentOffset == −inset` on this runtime (`scrollTo(y: 0)` lands at
    /// `0 − inset`; Home's probe logs `y=-157 inset=157` at rest).
    func testIsAtTop() {
        XCTAssertTrue(DetailRowAnchor.isAtTop(contentOffset: -157, contentInsetTop: 157))
        XCTAssertTrue(DetailRowAnchor.isAtTop(contentOffset: -157 + DetailRowAnchor.verifyTolerance, contentInsetTop: 157))
        XCTAssertFalse(DetailRowAnchor.isAtTop(contentOffset: -157 + DetailRowAnchor.verifyTolerance + 1, contentInsetTop: 157))
        XCTAssertFalse(DetailRowAnchor.isAtTop(contentOffset: 675, contentInsetTop: 157))
        // Before the first geometry read both terms are 0.
        XCTAssertTrue(DetailRowAnchor.isAtTop(contentOffset: 0, contentInsetTop: 0))
    }

    func testDirectionWithAbout() {
        // About sits below every other row: a missing top for it reads Up, like Comments.
        XCTAssertEqual(DetailRowAnchor.direction(old: .about, oldTop: nil, newTop: 300), .up)
        // Comments → About is an ordinary Down.
        XCTAssertEqual(DetailRowAnchor.direction(old: .comments, oldTop: 900, newTop: 1400), .down)
        XCTAssertEqual(DetailRowAnchor.direction(old: .about, oldTop: 1400, newTop: 900), .up)
    }
}

/// W3-15 (BUG-153, "the first Down is too abrupt"): the anchor glide's duration follows its travel
/// — 0.3s up to 380pt (every short pass unchanged), ≈0.6s for the Cinematic hero's ~766pt exit,
/// never past 0.65s — and the verify pass waits for the glide to finish before it may re-issue.
@MainActor
final class DetailRowAnchorDurationTests: XCTestCase {
    /// The Cinematic hero exit's travel on the 1080 fixture: the hero is the container − 236.
    private let heroExitTravel: CGFloat = 766

    private func duration(_ travel: CGFloat) -> TimeInterval {
        DetailRowAnchor.anchorDuration(travel: travel, override: nil)
    }

    func testShortPassesKeepTheOldPointThreeSeconds() {
        XCTAssertEqual(DetailRowAnchor.anchorDurationFloor, 0.3)
        for travel: CGFloat in [0, 0.5, 24, 120, 300, 379.9, 380] {
            XCTAssertEqual(duration(travel), 0.3, accuracy: 1e-9, "travel \(travel)")
        }
    }

    func testTheHeroExitTakesAboutPointSix() {
        let seconds = duration(heroExitTravel)
        XCTAssertEqual(seconds, 0.3 * 766 / 380, accuracy: 1e-9)
        XCTAssertEqual(seconds, 0.6, accuracy: 0.01)
        // The hero return (`heroTopPass`) is the same distance in reverse.
        XCTAssertEqual(duration(-heroExitTravel), seconds, accuracy: 1e-9)
    }

    func testTheCapHolds() {
        XCTAssertEqual(DetailRowAnchor.anchorDurationCap, 0.65)
        for travel: CGFloat in [823.4, 900, 1080, 4000, .greatestFiniteMagnitude, .infinity, -.infinity] {
            XCTAssertEqual(duration(travel), 0.65, accuracy: 1e-9, "travel \(travel)")
        }
        XCTAssertLessThan(duration(820), 0.65)
    }

    func testDurationIsMonotonicInTravel() {
        var previous = duration(0)
        var travel: CGFloat = 0
        while travel <= 2000 {
            let current = duration(travel)
            XCTAssertGreaterThanOrEqual(current, previous, "travel \(travel)")
            XCTAssertEqual(duration(-travel), current, accuracy: 1e-12, "the sign of the travel never matters")
            previous = current
            travel += 0.5
        }
    }

    func testNaNTravelTakesTheFloor() {
        XCTAssertEqual(duration(.nan), 0.3, accuracy: 1e-9)
    }

    func testVerifyWaitsForTheGlidePlusSlack() {
        XCTAssertEqual(DetailRowAnchor.verifySlack, 0.1)
        // At the floor the verify keeps its old 0.45s.
        XCTAssertEqual(DetailRowAnchor.verifyDelay(for: 0.3), DetailRowAnchor.verifyDelay, accuracy: 1e-9)
        XCTAssertEqual(DetailRowAnchor.verifyDelay, 0.45)
        // The hero exit: the verify may not land before the 0.6s glide has finished.
        let hero = duration(heroExitTravel)
        XCTAssertEqual(DetailRowAnchor.verifyDelay(for: hero), hero + 0.1, accuracy: 1e-9)
        XCTAssertEqual(DetailRowAnchor.verifyDelay(for: DetailRowAnchor.anchorDurationCap), 0.75, accuracy: 1e-9)
        var travel: CGFloat = 0
        while travel <= 2000 {
            let glide = duration(travel)
            let verify = DetailRowAnchor.verifyDelay(for: glide)
            XCTAssertGreaterThanOrEqual(verify, glide + DetailRowAnchor.verifySlack - 1e-12, "travel \(travel)")
            XCTAssertGreaterThanOrEqual(verify, DetailRowAnchor.verifyDelay, "travel \(travel)")
            travel += 10
        }
    }

    // MARK: - debug.detailAnchorSeconds

    func testAnOverrideReplacesTheFormulaWhateverTheTravel() {
        for travel: CGFloat in [0, 380, 766, 4000] {
            XCTAssertEqual(DetailRowAnchor.anchorDuration(travel: travel, override: 0.45), 0.45, "travel \(travel)")
        }
        XCTAssertEqual(DetailRowAnchor.verifyDelay(for: 1.2), 1.3, accuracy: 1e-9,
                       "a long override still pushes the verify past its glide")
    }

    func testTheLiveFormUsesTheLatchedKnob() {
        for travel: CGFloat in [0, 766, 4000] {
            XCTAssertEqual(DetailRowAnchor.anchorDuration(travel: travel),
                           DetailRowAnchor.anchorDuration(travel: travel, override: DetailRowAnchor.anchorSecondsOverride))
        }
    }

    func testKnobParse() throws {
        let suite = "test.detailAnchorSeconds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = DetailRowAnchor.anchorSecondsKey
        XCTAssertEqual(key, "debug.detailAnchorSeconds")

        XCTAssertNil(DetailRowAnchor.anchorSecondsOverride(from: defaults), "unset = off")
        defaults.set(0.45, forKey: key)
        XCTAssertEqual(DetailRowAnchor.anchorSecondsOverride(from: defaults), 0.45)
        // A launch argument (`-debug.detailAnchorSeconds 0.3`) arrives as a string.
        defaults.set("0.3", forKey: key)
        XCTAssertEqual(DetailRowAnchor.anchorSecondsOverride(from: defaults), 0.3)
        defaults.set(0, forKey: key)
        XCTAssertNil(DetailRowAnchor.anchorSecondsOverride(from: defaults), "0 = off")
        defaults.set(-1, forKey: key)
        XCTAssertNil(DetailRowAnchor.anchorSecondsOverride(from: defaults), "negative = off")
        defaults.set("fast", forKey: key)
        XCTAssertNil(DetailRowAnchor.anchorSecondsOverride(from: defaults), "non-numeric = off")
        defaults.set(9, forKey: key)
        XCTAssertEqual(DetailRowAnchor.anchorSecondsOverride(from: defaults),
                       DetailRowAnchor.anchorSecondsOverrideMax, "clamped to the ceiling")
        XCTAssertEqual(DetailRowAnchor.anchorSecondsOverrideMax, 2)
    }

    // MARK: - BUG-217: a row rests where the focus engine wants its first item

    /// Sim reading (2026-10-31, The Dark Knight, Cinematic): the chip row anchored at screen 108
    /// (offset 712, row top 820) was pulled to screen 180 (offset 640) by the focus engine on the
    /// first Right press inside it, with no anchor pass. A move that stays in a row must not
    /// scroll, so the row rests at 180 from the start.
    func testTheCinematicChipRowRestsWhereTheEngineSettledIt() {
        XCTAssertEqual(DetailRowAnchor.firstItemLead(for: .logos, layout: .cinematic), 0)
        XCTAssertEqual(DetailRowAnchor.screenRest(for: .logos, layout: .cinematic), DetailRowAnchor.engineRevealTop)
        XCTAssertEqual(DetailRowAnchor.engineRevealTop, 180)
        let rowTop: CGFloat = 820, inset: CGFloat = 60
        let y = DetailRowAnchor.scrollTarget(rowTop: rowTop, contentInsetTop: inset,
                                             screenRest: DetailRowAnchor.screenRest(for: .logos, layout: .cinematic))
        XCTAssertEqual(DetailRowAnchor.expectedOffset(scrollTarget: y, contentInsetTop: inset), 640,
                       "the anchored offset is the offset the engine settled on, so nothing is left to reveal")
    }

    /// Classic's chips at 108 did not move on Right in the same run, so they keep 108.
    func testTheClassicChipRowKeepsTheOriginalRest() {
        XCTAssertNil(DetailRowAnchor.firstItemLead(for: .logos, layout: .classic))
        XCTAssertEqual(DetailRowAnchor.screenRest(for: .logos, layout: .classic), DetailRowAnchor.screenRest)
    }

    /// The measured headed rows, in both layouts (Up into the row, one Right, the page's shift:
    /// Cast 11, Collection 3, Trailers 3): the first item rests exactly at the engine's margin, and
    /// the row never rests higher than the original rest.
    func testMeasuredRowsPutTheirFirstItemAtTheEnginesMargin() {
        for layout: DetailLayout in [.classic, .cinematic] {
            for row: DetailRowID in [.cast, .collection, .trailers] {
                guard let lead = DetailRowAnchor.firstItemLead(for: row, layout: layout) else {
                    return XCTFail("\(row) has no lead in \(layout)")
                }
                let rest = DetailRowAnchor.screenRest(for: row, layout: layout)
                XCTAssertGreaterThanOrEqual(rest, DetailRowAnchor.screenRest, "\(row)")
                XCTAssertEqual(rest + lead, DetailRowAnchor.engineRevealTop, accuracy: 0.001, "\(row) in \(layout)")
            }
        }
        // Sim numbers (system font, section title line 36.99 + md 16): Cast 61 below the row top
        // (the avatar), Collection/Trailers 69 (the tile).
        let heading = Theme.Font.sectionTitleLineHeight + Theme.Spacing.md
        XCTAssertEqual(DetailRowAnchor.firstItemLead(for: .cast, layout: .cinematic), heading + 8)
        XCTAssertEqual(DetailRowAnchor.firstItemLead(for: .collection, layout: .classic), heading + 16)
        XCTAssertEqual(DetailRowAnchor.firstItemLead(for: .trailers, layout: .cinematic), heading + 16)
    }

    /// Rows not measured, and rows already clear of the margin, keep the original rest.
    func testUnmeasuredRowsKeepTheOriginalRest() {
        for layout: DetailLayout in [.classic, .cinematic] {
            for row: DetailRowID in [.parental, .episodes, .moreLikeThis, .comments, .about] {
                XCTAssertNil(DetailRowAnchor.firstItemLead(for: row, layout: layout), "\(row)")
                XCTAssertEqual(DetailRowAnchor.screenRest(for: row, layout: layout), DetailRowAnchor.screenRest, "\(row)")
            }
        }
        XCTAssertEqual(DetailRowAnchor.screenRest, 108, "the pinned rest the tester photos were tuned on")
    }

    /// The Cinematic ramp's shortening is the chip row's drop below the original rest.
    func testChipRowRestDropMatchesTheDimRamp() {
        XCTAssertEqual(DetailDim.chipRowRestDrop,
                       DetailRowAnchor.screenRest(for: .logos, layout: .cinematic) - DetailRowAnchor.screenRest)
    }

    /// Pure rule, no live state behind it: the Down straddle check takes the row's own rest, so a
    /// row above its rest anchors and a row at or below it is free.
    func testTheDownStraddleRuleTakesTheRowsOwnRest() {
        let rest = DetailRowAnchor.screenRest(for: .logos, layout: .cinematic)
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: 150, screenRest: rest), .anchor)
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: rest, screenRest: rest), .free)
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: 300, screenRest: rest), .free)
        XCTAssertEqual(DetailRowAnchor.decision(direction: .down, screenTop: 150,
                                                screenRest: DetailRowAnchor.screenRest), .free)
    }
}
