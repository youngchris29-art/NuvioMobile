import XCTest
import CoreGraphics
@testable import NuvioTV

/// BUG-87/88/89 (beta.18) — unit tests for `PinnedRowGeometry.plan`, the structural fit for the
/// pinned rows layout.
///
/// The tester's shape (Apple TV 4K, Poster Size **Large**, Hide Labels **ON**, No Zoom **ON**, Show
/// Hero **OFF** ⇒ FEAT-15's focus panel, `nuvioStyle` pinned layout) revealed a 535.3pt focusable
/// link frame resting inside a 523.3pt viewport. An over-tall frame has two legal rests — the
/// simulator top-anchors it, hardware bottom-anchors it ~75pt deeper — so the settle corrector and
/// the focus engine fought forever: titles that "keep trying to move back", a title glitch during
/// horizontal travel, and a second-to-last row that regressed after Medium → Large until restart.
///
/// These are pure-arithmetic tests on purpose. The plan is a value: no SwiftUI layout pass, no
/// hosting controller, nothing measured. What it CANNOT prove is where the focus engine actually
/// rests a frame that fits — that is the device pass.
final class PinnedRowGeometryTests: XCTestCase {

    // MARK: - The real Poster Size presets

    /// The three synced `widthDp` values the Appearance pane offers
    /// (`Settings/AppearanceSettingsPane.swift`, `PosterStyleControls.sizes`), run through
    /// `PosterStyle.init(from:)`'s own arithmetic: `width = dp * (Theme.Size.posterWidth / 126)`,
    /// `height = width * 1.5`. Derived rather than pasted so a change to `posterWidth` moves the
    /// tests with the app.
    private static func posterHeight(dp: CGFloat) -> CGFloat {
        dp * (Theme.Size.posterWidth / 126.0) * 1.5
    }
    private static let small = posterHeight(dp: 105)    // 275.0
    private static let medium = posterHeight(dp: 126)   // 330.0 == Theme.Size.posterHeight
    private static let large = posterHeight(dp: 154)    // 403.33…

    private static let allSizes: [(name: String, height: CGFloat)] = [
        ("Small", small), ("Medium", medium), ("Large", large),
    ]

    /// Every flag combination, as the app can actually produce them.
    private static func crossProduct() -> [(name: String, plan: PinnedRowGeometry.Plan)] {
        var out: [(name: String, plan: PinnedRowGeometry.Plan)] = []
        for (name, height) in allSizes {
            for captions in [false, true] {
                for cta in [false, true] {
                    for landscape in [false, true] {
                        let label = "\(name) captions=\(captions) showsCTA=\(cta) landscape=\(landscape)"
                        let plan = PinnedRowGeometry.plan(posterHeight: height,
                                                          captionVisible: captions,
                                                          showsCTA: cta,
                                                          landscapeRows: landscape)
                        out.append((name: label, plan: plan))
                    }
                }
            }
        }
        return out
    }

    private let epsilon: CGFloat = 0.001

    // MARK: - The bit-identical guarantee

    /// Wave 10's promise, kept: Small and Medium compute a ZERO compression at every flag
    /// combination, so their layout is bit-identical to what shipped.
    ///
    ///     Small   24 + 88 + 275.0 + 8 = 395.0  →  under 455
    ///     Medium  24 + 88 + 330.0 + 8 = 450.0  →  under 455 (5pt spare)
    ///
    /// This is the scope decision the plan documents: Medium is the DEFAULT Poster Size with
    /// captions ON, its recorded band table shows zero corrections, and keying its compression to
    /// the link frame would compress the default configuration's hero by ~82pt to fix a rest nobody
    /// has reported. The fix applies to the sizes that were already compressing.
    func testSmallAndMediumSpendNothingAtEveryFlagCombination() {
        for (label, plan) in Self.crossProduct() where label.hasPrefix("Small") || label.hasPrefix("Medium") {
            XCTAssertEqual(plan.compression, 0, accuracy: epsilon, label)
            XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon, label)
            XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon, label)
            XCTAssertEqual(plan.viewport, Theme.Size.heroPinnedRowsViewportBudget, accuracy: epsilon, label)
        }
    }

    /// Landscape catalog rows are 203pt tall (`Theme.Size.landscapeHeight`) — 323 against the 455
    /// budget with the band and cushion — so nothing is ever spent for them, at any Poster Size.
    func testLandscapeRowsSpendNothingAtEverySize() {
        for (label, plan) in Self.crossProduct() where label.contains("landscape=true") {
            XCTAssertEqual(plan.compression, 0, accuracy: epsilon, label)
            XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon, label)
            XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon, label)
            XCTAssertTrue(plan.fits, label)
        }
    }

    // MARK: - Floors and bounds

    /// No dial may leave its legal range, ever — including for a synced `widthDp` past Large, which
    /// `PosterStyle.init(from:)` accepts without clamping and is therefore an ordinary payload here.
    /// The top reach in particular is only ever LOWERED (reach 100 kills focus resolution outright).
    func testFloorsAreNeverBreached() {
        var cases = Self.crossProduct()
        for captions in [false, true] {
            for cta in [false, true] {
                let oversized = PinnedRowGeometry.plan(posterHeight: Self.posterHeight(dp: 200),
                                                       captionVisible: captions,
                                                       showsCTA: cta,
                                                       landscapeRows: false)
                cases.append((name: "Oversized captions=\(captions) showsCTA=\(cta)", plan: oversized))
            }
        }
        for (label, plan) in cases {
            XCTAssertLessThanOrEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad + epsilon, label)
            XCTAssertGreaterThanOrEqual(plan.topReach, PinnedRowGeometry.topReachFloor - epsilon, label)
            XCTAssertLessThanOrEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach + epsilon, label)
            XCTAssertGreaterThanOrEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor - epsilon, label)
            XCTAssertGreaterThanOrEqual(plan.compression, 0, label)
            XCTAssertLessThanOrEqual(plan.compression,
                                     PinnedRowGeometry.elasticGive(showsCTA: label.contains("showsCTA=true")) + epsilon,
                                     label)
        }
    }

    /// The invariant the whole fix exists for: wherever the plan claims a fit, the frame the focus
    /// engine reveals really is inside the viewport it has to rest in — and `restRange` is exactly
    /// the room left over, i.e. the width of the set of legal rests.
    func testFitsMeansTheLinkFrameIsInsideTheViewport() {
        for (label, plan) in Self.crossProduct() {
            XCTAssertEqual(plan.viewport,
                           Theme.Size.heroPinnedRowsViewportBudget + plan.compression,
                           accuracy: epsilon, label)
            if plan.fits {
                XCTAssertLessThanOrEqual(plan.linkFrame, plan.viewport + epsilon, label)
                XCTAssertEqual(plan.restRange, plan.viewport - plan.linkFrame, accuracy: epsilon, label)
            } else {
                XCTAssertGreaterThan(plan.linkFrame, plan.viewport, label)
                XCTAssertEqual(plan.restRange, 0, accuracy: epsilon, label)
            }
        }
    }

    // MARK: - The tester's shape

    /// Large + Hide Labels ON + FEAT-15 focus panel — the configuration BUG-87/88/89 were filmed
    /// in. It must FIT, and it must fit at Wave 10's OWN compression rather than a larger one.
    ///
    /// rc2 (2026-09-06) reordered the dials. The first cut spent compression first, which at this
    /// shape meant 108pt out of the panel's synopsis slot (its whole give; the remaining 4.33 came
    /// from the logo): 144 − 108 = 36 ⇒ one line of description, which the tester filmed and
    /// objected to ("one line is not enough"). Christian's
    /// call: spend the two reach CUSHIONS first — they exist to absorb rest error, and a frame that
    /// fits has no rest error — and let the compression take only the remainder.
    ///
    ///     demand      24 + 88 + 403.33 + 0 + 44 + 8 − 455      = 112.33   (formula unchanged)
    ///     (a) bottom  44 → 24 (bottomReachFloor)                 −20  ⇒ 92.33 left
    ///     (b) top     88 → 64 (topReachFloor)                    −24  ⇒ 68.33 left
    ///     (c) hero    min(68.33, panel give 142)                = 68.33  ⇒ 0 left
    ///     viewport    455 + 68.33                              = 523.33
    ///     linkFrame   64 + 403.33 + 0 + 24                      = 491.33
    ///     restRange                                            = 32  (Spacing.lg + cushion)
    ///
    /// 68.33 is exactly `PinnedRowTitle.pinnedHeroCompression` at Large — the number beta.17
    /// shipped and the tester never complained about — so the panel is back to a 108pt synopsis
    /// slot and three lines (`PinnedRowGeometryHeroSlotGiveTests`).
    ///
    /// What this test CANNOT prove: that reach 64 behaves on hardware. It is below the long-proven
    /// 72 and leaves the settled title 2pt of clearance above the artwork rather than BUG-53's 26 —
    /// device pass only.
    func testStevensShapeFitsOnTheReachCushionsAtWave10Compression() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 68.333, accuracy: 0.01)
        XCTAssertEqual(plan.compression,
                       PinnedRowTitle.pinnedHeroCompression(rowArtworkHeight: Self.large),
                       accuracy: epsilon)
        XCTAssertEqual(plan.topReach, PinnedRowGeometry.topReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 523.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 491.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
        XCTAssertEqual(plan.regimeKey, "L403c0p1r0")
    }

    /// The set of legal rests must be narrower than the legibility band `PinnedRowSettle` corrects
    /// into, or the engine could still park somewhere the corrector wants to move — which is the
    /// bouncing the tester reported.
    ///
    /// The band, from `PinnedRowSettle`'s `bandLow`/`bandHigh` in BrowseComponents (~L2674-2677 at the
    /// time of writing; grep the symbols, the line numbers drift) with the row's own geometry,
    /// at the rc2 reach of 64 (the plan now spends both reaches to their floors here):
    ///
    ///     clearance = max((Spacing.lg 24 + reach 64) − (titleInset 48 + title 38), 0) = 2
    ///     bandLow   = −clearance.focused = −2        (No Zoom ⇒ zero lift ⇒ focused == atRest)
    ///     lockup    = 24 + 64 + 403.33               = 491.33
    ///     bandHigh  = min(48, 48 + 523.33 − 491.33 − 8) = min(48, 72) = 48
    ///     width     = 50
    ///
    /// against `restRange` = 32, so the invariant still holds — but note the band NARROWED from 74
    /// to 50, and it narrowed at the clearance end: the settled title now rests 2pt above the
    /// artwork rather than 26. That is the reach floor's real cost, and it is the thing the device
    /// pass has to look at (see `PinnedRowGeometry`'s header).
    func testStevensShapeRestRangeIsNarrowerThanTheLegibilityBand() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false)
        // No Zoom on Focus ⇒ `focusLiftAllowance` is 0, so the focused clearance is the static one.
        let clearance = PinnedRowTitle.staticClearance(titleHeight: PinnedRowGeometry.measuredTitleHeight,
                                                       cardTopReach: plan.topReach)
        let lockupExtent = Theme.Spacing.lg + plan.topReach + Self.large  // Hide Labels ⇒ no caption
        let bandLow = -clearance
        let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                           Theme.Size.heroPinnedRowTitleInset + plan.viewport - lockupExtent
                               - Theme.Size.heroPinnedRowsSettledCushion)
        let bandWidth = bandHigh - bandLow
        XCTAssertEqual(clearance, 2, accuracy: epsilon)
        XCTAssertEqual(bandWidth, 50, accuracy: epsilon)
        XCTAssertLessThanOrEqual(plan.restRange, bandWidth)
    }

    /// The same Poster Size with the CAROUSEL hero, which has only 70pt of elastic give where the
    /// panel has 142. Under the rc2 order that no longer matters: the reaches are spent first, and
    /// the 68.33 left over is inside 70 either way, so the carousel and the panel produce the SAME
    /// plan at Hide Labels ON.
    ///
    ///     demand 112.33 → bottom 44→24 (−20) → top 88→64 (−24) → compression min(68.33, 70)
    ///
    /// Before the reordering this regime compressed the full 70 and stopped the top reach at 65.67;
    /// it now stops at the floor and compresses 68.33 — 1.67pt LESS hero compression, both reaches
    /// at their floors.
    func testLargeHideLabelsWithCarouselHeroSpendsBothReachesThenTheRemainder() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: true,
                                          landscapeRows: false)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 68.333, accuracy: 0.01)
        XCTAssertLessThanOrEqual(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: true) + epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.topReach, PinnedRowGeometry.topReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 523.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 491.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
    }

    /// Large + captions + carousel hero is unsatisfiable by design: ~155.8pt of demand against 44pt
    /// of reach give and 70pt of elastic give — 114 against 156, in either spend order. Under the
    /// rc2 order the reaches floor at 24/64 and 111.83 is left over, which the carousel's 70pt cap
    /// cannot cover. The plan must NOT pretend — it reports `fits == false` and hands back TODAY'S
    /// numbers verbatim (compression 68.33, reaches 88/44), so the visibility belt owns the residue
    /// in exactly the regime that shipped in beta.17.
    func testLargeWithCaptionsAndCarouselHeroFallsBackToTodaysNumbers() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: true,
                                          showsCTA: true,
                                          landscapeRows: false)
        XCTAssertFalse(plan.fits)
        XCTAssertEqual(plan.compression,
                       PinnedRowTitle.pinnedHeroCompression(rowArtworkHeight: Self.large),
                       accuracy: epsilon)
        XCTAssertEqual(plan.compression, 68.333, accuracy: 0.01)
        XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 523.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 578.833, accuracy: 0.01)
    }

    /// Large + captions in the FEAT-15 panel IS satisfiable: both reaches go to their floors and
    /// the panel's 142pt of give covers the 111.83 that is left, short of its own cap.
    ///
    ///     demand    24 + 88 + 403.33 + 43.5 + 44 + 8 − 455 = 155.83
    ///     (a) bottom 44 → 24                                −20  ⇒ 135.83
    ///     (b) top    88 → 64                                −24  ⇒ 111.83
    ///     (c) hero   min(111.83, 142)                      = 111.83, 30.17 of give unspent
    ///     viewport  455 + 111.83                           = 566.83
    ///     linkFrame 64 + 403.33 + 43.5 + 24                = 534.83
    ///     restRange                                        = 32
    ///
    /// Before the reordering this regime compressed the full 142 and left the top reach at 88; it
    /// now compresses 111.83 with both reaches floored — 30.17pt LESS hero compression. The panel's
    /// synopsis still ends up at one line here (`HeroSlotGive` tiers: 36 + 32 + 41.83), which is
    /// what this shape showed before too, so nothing regresses for it.
    func testLargeWithCaptionsInPanelModeFitsAfterBothReachesFloor() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: true,
                                          showsCTA: false,
                                          landscapeRows: false)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 111.833, accuracy: 0.01)
        XCTAssertLessThan(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: false))
        XCTAssertEqual(plan.topReach, PinnedRowGeometry.topReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 566.833, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 534.833, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
    }

    // MARK: - The spend order itself

    /// The rc2 order, stated as an invariant rather than as a number: the reaches are spent BEFORE
    /// the compression, so any plan that ends up compressing at all must already have both reaches
    /// on their floors. (The demand always exceeds the 44pt of reach give wherever the scope gate
    /// is open at all: `demand == legacyRawDemand + captionChrome + 44`.)
    ///
    /// The mirror clause covers the two paths that spend nothing: the closed gate (Small, Medium,
    /// landscape) and the unsatisfiable fallback both hand back the shipped reaches untouched.
    func testCompressionIsOnlySpentAfterBothReachesAreOnTheirFloors() {
        for (label, plan) in Self.crossProduct() {
            if plan.fits, plan.compression > 0 {
                XCTAssertEqual(plan.topReach, PinnedRowGeometry.topReachFloor, accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon, label)
            } else {
                XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon, label)
            }
        }
    }

    // MARK: - Give, purity, identity

    /// The panel's give is the carousel's plus the CTA slot it absorbed — the arithmetic that made
    /// the tester's shape satisfiable at all, and the number `HomeHeroForeground.synopsisSlotGive`
    /// has to be able to actually spend.
    func testElasticGiveMatchesTheHeroFormOnScreen() {
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: true),
                       Theme.Size.heroPinnedCompressionCap, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: true), 70, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: false), 142, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: false)
                        - PinnedRowGeometry.elasticGive(showsCTA: true),
                       Theme.Size.heroButtonSlotHeight + Theme.Spacing.md, accuracy: epsilon)
    }

    /// A pure function: the plan depends on its inputs and on nothing else (no live layout, no
    /// per-row or per-focus state). This is what lets `onChange(of: pinnedPlan.regimeKey)` be the
    /// only re-reveal trigger.
    func testPlanIsPure() {
        for (label, plan) in Self.crossProduct() {
            let again = PinnedRowGeometry.plan(posterHeight: planHeight(for: label),
                                               captionVisible: label.contains("captions=true"),
                                               showsCTA: label.contains("showsCTA=true"),
                                               landscapeRows: label.contains("landscape=true"))
            XCTAssertEqual(plan, again, label)
        }
    }

    /// One key per regime, and a different key for every other regime — the `onChange` contract.
    func testRegimeKeysAreDistinctAcrossTheCrossProduct() {
        let keys = Self.crossProduct().map { $0.plan.regimeKey }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(PinnedRowGeometry.plan(posterHeight: Self.medium,
                                              captionVisible: true,
                                              showsCTA: true,
                                              landscapeRows: false).regimeKey,
                       "M330c1p0r0")
    }

    private func planHeight(for label: String) -> CGFloat {
        if label.hasPrefix("Small") { return Self.small }
        if label.hasPrefix("Medium") { return Self.medium }
        return Self.large
    }
}

/// rc2 (2026-09-06) — `PinnedRowGeometry.HeroSlotGive`, the split of one `compression` across the
/// pinned hero's two elastic slots. Extracted out of `HomeHeroForeground` so this arithmetic is
/// asserted rather than reasoned about; the view's `synopsisSlotGive` / `logoSlotGive` are thin
/// wrappers over it.
///
/// The tester's objection was about LINES OF DESCRIPTION, and the line count is a floor division:
/// `HomeHeroForeground.synopsisLineLimit` is `floor(slotHeight / (heroSynopsisSlotHeightPinned/2))`,
/// i.e. 36pt per line. So the tests below assert the slot height AND the line count it implies —
/// the second is the thing the tester actually sees.
final class PinnedRowGeometryHeroSlotGiveTests: XCTestCase {

    private let epsilon: CGFloat = 0.001

    /// Mirror of `HomeHeroForeground.synopsisSlotHeight`'s compact branch.
    private func slotHeight(showsCTA: Bool, synopsisGive: CGFloat) -> CGFloat {
        let slot = showsCTA ? Theme.Size.heroSynopsisSlotHeightPinned
                            : Theme.Size.heroSynopsisSlotHeightPinnedPanel
        return slot - synopsisGive
    }

    /// Mirror of `HomeHeroForeground.synopsisLineLimit`'s compact branch.
    private func lineLimit(slotHeight: CGFloat) -> Int {
        max(1, Int((slotHeight / (Theme.Size.heroSynopsisSlotHeightPinned / 2)).rounded(.down)))
    }

    // MARK: - The three tiers

    /// The whole point of the rc2 change, at the tester's shape.
    ///
    ///     compression 68.33  (PinnedRowGeometry.plan, Large + Hide Labels + panel)
    ///     tier 1  synopsis   min(68.33, heroSynopsisSlotPinnedGive 36)          = 36
    ///     tier 2  logo       min(32.33, heroLogoSlotPinnedGive 32)              = 32
    ///     tier 3  synopsis   max(68.33 − 36 − 32 − slack 2, 0) = 0              = 0
    ///     ⇒ synopsis slot 144 − 36 = 108   ⇒ floor(108/36) = 3 lines
    ///
    /// The 0.33 that tiers 1+2 do not cover is the hero frame's own `heroPinnedFrameSlack` — 2pt of
    /// frame that holds no content — which is why tier 3 stays shut. Spending it would take the
    /// slot to 107.67 and `floor(107.67/36)` is 2, i.e. the regression this test exists to catch.
    func testPanelAtStevensCompressionKeepsThreeSynopsisLines() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 68.333,
                                                         showsCTA: false,
                                                         folderHero: false)
        XCTAssertEqual(split.synopsis, Theme.Size.heroSynopsisSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 36, accuracy: epsilon)
        XCTAssertEqual(split.logo, Theme.Size.heroLogoSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.logo, 32, accuracy: epsilon)

        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 108, accuracy: epsilon)
        XCTAssertEqual(lineLimit(slotHeight: slot), 3)

        // The logo slot lands exactly on its floor, as it did in Wave 10.
        XCTAssertEqual(Theme.Size.heroLogoSlotHeightPinned - split.logo,
                       Theme.Size.heroLogoSlotHeightPinnedFloor, accuracy: epsilon)
    }

    /// Tier 3 opens only past tiers 1+2 plus the frame slack, and then it is the panel's own extra.
    ///
    ///     compression 111.83  (Large + captions + panel)
    ///     tier 1  36, tier 2  32, tier 3  min(111.83 − 68 − 2, 72) = 41.83
    ///     ⇒ synopsis give 77.83, slot 144 − 77.83 = 66.17  ⇒ 1 line
    ///
    /// One line is what this shape produced before the reordering too (its old compression, 142,
    /// drained the slot to 36), so nothing regresses for it — the panel simply cannot show three
    /// lines and absorb a 43.5pt caption row at Large.
    func testPanelPastTheSlackOpensTheThirdTier() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 111.833,
                                                         showsCTA: false,
                                                         folderHero: false)
        XCTAssertEqual(split.logo, Theme.Size.heroLogoSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 77.833, accuracy: 0.01)
        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 66.167, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: slot), 1)
    }

    /// Tier 1 alone, below the logo's turn: a small compression comes entirely out of the synopsis
    /// in BOTH forms, exactly as it always has.
    func testSmallCompressionsSpendOnlyTheSharedSynopsisGive() {
        for showsCTA in [false, true] {
            let split = PinnedRowGeometry.HeroSlotGive.split(compression: 20,
                                                             showsCTA: showsCTA,
                                                             folderHero: false)
            XCTAssertEqual(split.synopsis, 20, accuracy: epsilon, "showsCTA=\(showsCTA)")
            XCTAssertEqual(split.logo, 0, accuracy: epsilon, "showsCTA=\(showsCTA)")
        }
    }

    /// Zero in, zero out — the non-pinned call sites (`compact == false`) always pass 0.
    func testZeroCompressionSpendsNothing() {
        for showsCTA in [false, true] {
            for folder in [false, true] {
                let split = PinnedRowGeometry.HeroSlotGive.split(compression: 0,
                                                                 showsCTA: showsCTA,
                                                                 folderHero: folder)
                XCTAssertEqual(split.total, 0, accuracy: epsilon)
            }
        }
    }

    // MARK: - What must not have changed

    /// The CAROUSEL form is bit-identical to the shipped two-step split at every compression it can
    /// be handed: its tier-3 ceiling is `72 − 36 − 36 == 0`, so the third tier can never open.
    func testCarouselSplitIsUnchangedAcrossItsWholeRange() {
        var c: CGFloat = 0
        while c <= PinnedRowGeometry.elasticGive(showsCTA: true) + 0.5 {
            let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                             showsCTA: true,
                                                             folderHero: false)
            // The pre-rc2 formula, inlined.
            let legacySynopsis = c > 0
                ? min(c, Theme.Size.heroSynopsisSlotHeightPinned - Theme.Size.heroSynopsisSlotHeightPinnedFloor)
                : 0
            let legacyLogo = c > 0
                ? min(max(c - legacySynopsis, 0), Theme.Size.heroLogoSlotPinnedGive)
                : 0
            XCTAssertEqual(split.synopsis, legacySynopsis, accuracy: epsilon, "compression=\(c)")
            XCTAssertEqual(split.logo, legacyLogo, accuracy: epsilon, "compression=\(c)")
            c += 0.25
        }
    }

    /// FEAT-29's collection-folder rule is untouched: the whole synopsis slot is give (a folder
    /// preview carries no description, so the slot has a genuine 0 floor) and the logo takes an
    /// unbounded remainder. At Large + panel that is synopsis 68.33, logo 0 — the wordmark keeps
    /// its full 110pt slot, which is the regression FEAT-29 closed.
    func testFolderHeroSplitIsUnchanged() {
        for showsCTA in [false, true] {
            let slot = showsCTA ? Theme.Size.heroSynopsisSlotHeightPinned
                                : Theme.Size.heroSynopsisSlotHeightPinnedPanel
            var c: CGFloat = 0
            while c <= PinnedRowGeometry.elasticGive(showsCTA: showsCTA) + 0.5 {
                let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                                 showsCTA: showsCTA,
                                                                 folderHero: true)
                let legacySynopsis = c > 0 ? min(c, slot) : 0
                XCTAssertEqual(split.synopsis, legacySynopsis, accuracy: epsilon,
                               "showsCTA=\(showsCTA) compression=\(c)")
                XCTAssertEqual(split.logo, max(c - legacySynopsis, 0), accuracy: epsilon,
                               "showsCTA=\(showsCTA) compression=\(c)")
                c += 0.25
            }
        }
    }

    // MARK: - Invariants

    /// Nothing hard-clips. The hero's FRAME shrinks by `compression`; its CONTENT shrinks by
    /// `split.total`, and the frame carries `heroPinnedFrameSlack` (2pt) that holds no content — so
    /// the content must give up at least `compression − slack` everywhere up to that form's cap, or
    /// the slots overflow into the rows below. This is the property
    /// `Theme.Size.heroPinnedCompressionCap` exists to protect.
    func testContentGiveAlwaysCoversTheFrameShrinkMinusItsSlack() {
        for showsCTA in [false, true] {
            for folder in [false, true] {
                var c: CGFloat = 0
                while c <= PinnedRowGeometry.elasticGive(showsCTA: showsCTA) + epsilon {
                    let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                                     showsCTA: showsCTA,
                                                                     folderHero: folder)
                    XCTAssertGreaterThanOrEqual(split.total + epsilon,
                                                c - Theme.Size.heroPinnedFrameSlack,
                                                "showsCTA=\(showsCTA) folder=\(folder) compression=\(c)")
                    c += 0.25
                }
            }
        }
    }

    /// Both slot floors hold for a TITLE hero at every compression up to the cap: the logo never
    /// goes below `heroLogoSlotHeightPinnedFloor` (78) and the synopsis never below
    /// `heroSynopsisSlotHeightPinnedFloor` (36), which is one readable line.
    func testTitleHeroSlotFloorsHold() {
        for showsCTA in [false, true] {
            var c: CGFloat = 0
            while c <= PinnedRowGeometry.elasticGive(showsCTA: showsCTA) + epsilon {
                let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                                 showsCTA: showsCTA,
                                                                 folderHero: false)
                let label = "showsCTA=\(showsCTA) compression=\(c)"
                XCTAssertGreaterThanOrEqual(Theme.Size.heroLogoSlotHeightPinned - split.logo + epsilon,
                                            Theme.Size.heroLogoSlotHeightPinnedFloor, label)
                XCTAssertGreaterThanOrEqual(slotHeight(showsCTA: showsCTA, synopsisGive: split.synopsis) + epsilon,
                                            Theme.Size.heroSynopsisSlotHeightPinnedFloor, label)
                XCTAssertGreaterThanOrEqual(split.synopsis, 0, label)
                XCTAssertGreaterThanOrEqual(split.logo, 0, label)
                c += 0.25
            }
        }
    }

    /// Monotone in the compression: a bigger frame shrink never gives a slot MORE room back. A
    /// non-monotone split would make the synopsis line count jump around as the synced Poster Size
    /// changes, which is the class of bug the tiers could plausibly have introduced.
    func testSplitIsMonotoneInCompression() {
        for showsCTA in [false, true] {
            for folder in [false, true] {
                var c: CGFloat = 0
                var previous = PinnedRowGeometry.HeroSlotGive.split(compression: 0,
                                                                    showsCTA: showsCTA,
                                                                    folderHero: folder)
                while c <= PinnedRowGeometry.elasticGive(showsCTA: showsCTA) + epsilon {
                    let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                                     showsCTA: showsCTA,
                                                                     folderHero: folder)
                    let label = "showsCTA=\(showsCTA) folder=\(folder) compression=\(c)"
                    XCTAssertGreaterThanOrEqual(split.synopsis + epsilon, previous.synopsis, label)
                    XCTAssertGreaterThanOrEqual(split.logo + epsilon, previous.logo, label)
                    previous = split
                    c += 0.25
                }
            }
        }
    }
}
