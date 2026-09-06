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
    /// in. It must FIT, on the hero's give alone (the panel can yield 142 where the carousel yields
    /// 70), with both reaches left at their shipped values.
    ///
    ///     demand    24 + 88 + 403.33 + 0 + 44 + 8 − 455  = 112.33
    ///     give      logo 32 + synopsis (144 − 36) + slack 2 = 142   ⇒ nothing else is spent
    ///     viewport  455 + 112.33                          = 567.33
    ///     linkFrame 88 + 403.33 + 0 + 44                  = 535.33
    ///     restRange                                       = 32  (Spacing.lg + cushion)
    func testStevensShapeFitsOnHeroGiveAlone() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 112.333, accuracy: 0.01)
        XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 567.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 535.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
        XCTAssertEqual(plan.regimeKey, "L403c0p1r0")
    }

    /// The set of legal rests must be narrower than the legibility band `PinnedRowSettle` corrects
    /// into, or the engine could still park somewhere the corrector wants to move — which is the
    /// bouncing the tester reported.
    ///
    /// The band, from `PinnedRowSettle` (BrowseComponents ~L2265-2290) with the row's own geometry:
    ///
    ///     bandLow  = −clearance.focused = −26        (No Zoom ⇒ zero lift ⇒ focused == atRest)
    ///     bandHigh = min(titleInset 48, titleInset + viewport − lockupExtent − cushion) = 48
    ///     width    = 74
    ///
    /// against `restRange` = 32.
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
        XCTAssertEqual(clearance, 26, accuracy: epsilon)
        XCTAssertEqual(bandWidth, 74, accuracy: epsilon)
        XCTAssertLessThanOrEqual(plan.restRange, bandWidth)
    }

    /// The same Poster Size with the carousel hero has only 70pt of give, so the plan spends the
    /// reaches too — bottom first (44 → 24, its floor), then the top reach for the remainder, which
    /// stops well above its own floor. It still fits.
    func testLargeHideLabelsWithCarouselHeroSpendsBottomReachBeforeTopReach() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: true,
                                          landscapeRows: false)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: true), accuracy: epsilon)
        XCTAssertEqual(plan.compression, 70, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.topReach, 65.667, accuracy: 0.01)
        XCTAssertGreaterThan(plan.topReach, PinnedRowGeometry.topReachFloor)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
    }

    /// Large + captions + carousel hero is unsatisfiable by design: ~155.8pt of demand against 70pt
    /// of elastic give and 44pt of reach give. The plan must NOT pretend — it reports `fits ==
    /// false` and hands back TODAY'S numbers verbatim, so the visibility belt owns the residue in
    /// exactly the regime that shipped in beta.17.
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

    /// Large + captions in the FEAT-15 panel IS satisfiable — the panel's 142pt of give covers all
    /// but 13.8pt, which the bottom reach absorbs without reaching its floor.
    func testLargeWithCaptionsInPanelModeFitsUsingSomeBottomReach() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: true,
                                          showsCTA: false,
                                          landscapeRows: false)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: false), accuracy: epsilon)
        XCTAssertEqual(plan.compression, 142, accuracy: epsilon)
        XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, 30.167, accuracy: 0.01)
        XCTAssertGreaterThan(plan.bottomReach, PinnedRowGeometry.bottomReachFloor)
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
