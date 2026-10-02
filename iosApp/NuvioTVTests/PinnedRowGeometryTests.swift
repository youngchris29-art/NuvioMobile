import XCTest
import CoreGraphics
import UIKit
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
    /// FEAT-39: 134dp, above the 335pt hero-compression gate, so it takes the Large dial.
    private static let mediumPlus = posterHeight(dp: 134) // 350.95…
    private static let large = posterHeight(dp: 154)    // 403.33…

    private static let allSizes: [(name: String, height: CGFloat)] = [
        ("Small", small), ("Medium", medium), ("Medium+", mediumPlus), ("Large", large),
    ]

    // MARK: - Focus modes

    /// BUG-87/89 (rc10): `plan` is MODE-DEPENDENT — `topReachFloor(lift:)` has to hold the focus
    /// lift, so the top reach and the compression differ between the zoom modes. Every call below
    /// therefore passes an EXPLICIT mode: the `FocusModeFlags.current` default reads
    /// `UserDefaults`, which would make this suite depend on whatever the last test (or the
    /// developer's simulator) left in the two Appearance keys.
    ///
    /// `noZoom` is the mode every pre-rc10 expectation in this file was written against (lift 0), so
    /// it is what the shared helpers use; the numbers moved anyway, because the floor gained the
    /// belt's `fadeIntrusionArm` (64 → 66).
    private static let noZoom = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false)
    /// The DEFAULT Appearance state, and the one the defect was filmed in: lift 20 ⇒ floor 86.
    private static let zoomOn = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false)
    /// rc12 BUG-87 follow-up: No Zoom with the default-OFF reach-hold A/B switched ON
    /// (`AboutSettingsPane`'s "No Zoom Row Reach (A/B)" row). `reachHoldsLiftEffective` is true here
    /// (both `reachHoldsLift` and `noZoom` are true), so `plan`'s `floorLift` spends the SAME 86
    /// floor `zoomOn` does — see `testNoZoomWithTheReachHoldTakesTheZoomOnFloor`.
    private static let noZoomHolding = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false,
                                                                     reachHoldsLift: true)
    /// 2026-09-30 zoom-on reach hold (`PinnedRowZoomReachHoldTests` below): the shipping default,
    /// whose held plan takes the rest target and so keeps a SMALL `restRange` (4). Used by the
    /// last-row floor test, which needs a carousel regime whose own link frame binds the floor.
    private static let zoomOnHeld = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false,
                                                                  zoomReachHold: true)

    // MARK: - Title metrics

    /// rc10 (Codex P2): `plan` is FONT-dependent as well as mode-dependent — the top reach's floor
    /// reserves room for one `Theme.Font.sectionTitle` line, and its default is the ACTIVE family's
    /// measured metric. Every call below therefore passes an EXPLICIT `titleHeight`, for the same
    /// reason every call passes an explicit `mode`: otherwise this suite's arithmetic would follow
    /// whatever font family the host simulator last applied.
    ///
    /// The SYSTEM font's number, which every expectation in this file was written against.
    private static let systemTitle = PinnedRowGeometry.measuredTitleHeight   // 38
    /// FEAT-31's Open Sans at the same text style, from the bundled faces' own vertical metrics:
    /// `(ascender 2189 + |descender| 600) / 2048 upem = 1.3618 em` × the 31pt `.callout` base
    /// ⇒ ≈42.2. All three bundled faces share those metrics, so the weight does not move it.
    private static let openSansTitle: CGFloat = 42.2

    /// Every flag combination, as the app can actually produce them, in No Zoom.
    ///
    /// `mode` defaults to plain `noZoom` so every pre-rc12 call site is unchanged; rc12 callers pass
    /// `noZoomHolding` to run the identical cross product through the reach-hold A/B. The label gets
    /// an appended `" hold=1"` only when the mode is holding, so a failure message says which of the
    /// two regimes it came from without changing any pre-existing label string.
    private static func crossProduct(mode: PinnedRowTitle.FocusModeFlags = noZoom) -> [(name: String, plan: PinnedRowGeometry.Plan)] {
        var out: [(name: String, plan: PinnedRowGeometry.Plan)] = []
        for (name, height) in allSizes {
            for captions in [false, true] {
                for cta in [false, true] {
                    for landscape in [false, true] {
                        let label = "\(name) captions=\(captions) showsCTA=\(cta) landscape=\(landscape)"
                            + (mode.reachHoldsLift ? " hold=1" : "")
                        let plan = PinnedRowGeometry.plan(posterHeight: height,
                                                          captionVisible: captions,
                                                          showsCTA: cta,
                                                          landscapeRows: landscape,
                                                          mode: mode,
                                                          titleHeight: systemTitle)
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
    /// rc12: run against both No Zoom regimes (`noZoom` and the reach-hold A/B's `noZoomHolding`) —
    /// Small/Medium never spend a compression at all (`legacyCompression` gates before the floor is
    /// ever read), so the hold changes nothing here and the loop is a parity check, not new
    /// coverage.
    func testSmallAndMediumSpendNothingAtEveryFlagCombination() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            // FEAT-39: "Medium " (with the trailing space from the label's own " captions=..."
            // suffix) deliberately excludes "Medium+" — that size is above the hero-compression gate
            // and takes the Large dial, so it is NOT bit-identical to what shipped.
            for (label, plan) in Self.crossProduct(mode: mode) where label.hasPrefix("Small") || label.hasPrefix("Medium ") {
                XCTAssertEqual(plan.compression, 0, accuracy: epsilon, label)
                XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon, label)
                XCTAssertEqual(plan.viewport,
                               Theme.Size.heroPinnedRowsViewportBudget(showsCTA: label.contains("showsCTA=true")),
                               accuracy: epsilon, label)
            }
        }
    }

    /// Landscape catalog rows are 203pt tall (`Theme.Size.landscapeHeight`) — 323 against the 455
    /// budget with the band and cushion — so nothing is ever spent for them, at any Poster Size, in
    /// either No Zoom regime (rc12).
    func testLandscapeRowsSpendNothingAtEverySize() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            for (label, plan) in Self.crossProduct(mode: mode) where label.contains("landscape=true") {
                XCTAssertEqual(plan.compression, 0, accuracy: epsilon, label)
                XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon, label)
                XCTAssertTrue(plan.fits, label)
            }
        }
    }

    // MARK: - Floors and bounds

    /// No dial may leave its legal range, ever — including for a synced `widthDp` past Large, which
    /// `PosterStyle.init(from:)` accepts without clamping and is therefore an ordinary payload here.
    /// The top reach in particular is only ever LOWERED (reach 100 kills focus resolution outright).
    /// rc12: run against both No Zoom regimes — the reach-hold A/B only ever RAISES the floor, so the
    /// `topReachFloor(lift: 0, …)` lower bound below stays a valid (looser) bound for `noZoomHolding`
    /// too; it is not re-derived per mode.
    func testFloorsAreNeverBreached() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            var cases = Self.crossProduct(mode: mode)
            for captions in [false, true] {
                for cta in [false, true] {
                    let oversized = PinnedRowGeometry.plan(posterHeight: Self.posterHeight(dp: 200),
                                                           captionVisible: captions,
                                                           showsCTA: cta,
                                                           landscapeRows: false,
                                                           mode: mode,
                                                           titleHeight: Self.systemTitle)
                    cases.append((name: "Oversized captions=\(captions) showsCTA=\(cta)", plan: oversized))
                }
            }
            for (label, plan) in cases {
                XCTAssertLessThanOrEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad + epsilon, label)
                XCTAssertGreaterThanOrEqual(plan.topReach,
                                            PinnedRowGeometry.topReachFloor(lift: 0,
                                                                            titleHeight: Self.systemTitle)
                                                - epsilon, label)
                XCTAssertLessThanOrEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach + epsilon, label)
                XCTAssertGreaterThanOrEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor - epsilon, label)
                XCTAssertGreaterThanOrEqual(plan.compression, 0, label)
                XCTAssertLessThanOrEqual(plan.compression,
                                         PinnedRowGeometry.elasticGive(showsCTA: label.contains("showsCTA=true")) + epsilon,
                                         label)
            }
        }
    }

    /// The invariant the whole fix exists for: wherever the plan claims a fit, the frame the focus
    /// engine reveals really is inside the viewport it has to rest in — and `restRange` is exactly
    /// the room left over, i.e. the width of the set of legal rests. rc12: both No Zoom regimes.
    func testFitsMeansTheLinkFrameIsInsideTheViewport() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            for (label, plan) in Self.crossProduct(mode: mode) {
                XCTAssertEqual(plan.viewport,
                               Theme.Size.heroPinnedRowsViewportBudget(showsCTA: label.contains("showsCTA=true"))
                                   + plan.compression,
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
    }

    // MARK: - The tester's shape

    /// Large + Hide Labels ON + FEAT-15 focus panel — the configuration BUG-87/88/89 were filmed
    /// in — in **No Zoom**. It must FIT, and it must fit with both reaches on their floors.
    ///
    /// rc2 (2026-09-06) reordered the dials so the reach CUSHIONS are spent before the hero
    /// compression: they exist to absorb rest error, and a frame that fits has no rest error, while
    /// every point of compression is description the viewer loses.
    ///
    ///     demand      24 + 88 + 403.33 + 0 + 44 + 8 − 455      = 112.33   (formula unchanged)
    ///     (a) bottom  44 → 24 (bottomReachFloor)                 −20  ⇒ 92.33 left
    ///     (b) top     88 → 66 (topReachFloor(lift: 0))           −22  ⇒ 70.33 left
    ///     (c) hero    min(70.33, panel give 160)                = 70.33  ⇒ 0 left
    ///     viewport    455 + 70.33                              = 525.33
    ///     linkFrame   66 + 403.33 + 0 + 24                      = 493.33
    ///     restRange                                            = 32  (Spacing.lg + cushion)
    ///
    /// ## Why this no longer equals Wave 10's own compression (rc10, BUG-87/89)
    ///
    /// rc4's version of this test asserted `compression == PinnedRowTitle.pinnedHeroCompression`
    /// (68.33) — "it fits at the number beta.17 already shipped" — which held only because the top
    /// reach floored at a flat 64. That flat floor was derived against the TITLE alone and ignored
    /// the focus lift, which is the whole of BUG-87/89: with zoom on, `staticClearance` 2 minus the
    /// 20pt lift is −18, and `Clearances`' `max(…, 0)` reported that permanent overlap as 0. The
    /// floor is derived and lift-aware now (`title floor 62 + lift + fadeIntrusionArm 4`), so it is
    /// 66 here and 2pt of the reach's give goes unspent — the compression takes 70.33 instead, which
    /// cost the panel's synopsis a line at the time (2 lines rather than 3). That is the documented
    /// price of the clearance (see `PinnedRowGeometry.topReachFloor(lift:)`), not a drift to be
    /// tuned away here. (rc14's `HeroSlotGive` order — free slack, then logo, then synopsis — gives
    /// the line back: see `testPanelAtRc10NoZoomCompressionHasFourLinesUnderTheSystemSynopsisFont`.)
    ///
    /// 2026-09-30: the panel's viewport budget is 493, not 455 (it has no page-dots row), so the
    /// demand is 38 lower and the compression is 32.33 rather than 70.33. The viewport, link frame
    /// and restRange are unchanged — the 38 moved from compression into the budget.
    func testStevensShapeFitsOnTheReachCushionsWithNoZoom() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 32.333, accuracy: 0.01)
        // 2pt MORE than Wave 10's own Large number, and exactly the 2pt the lift-aware floor keeps.
        XCTAssertEqual(plan.compression
                        - PinnedRowTitle.pinnedHeroCompression(rowArtworkHeight: Self.large, showsCTA: false),
                       2, accuracy: 0.01)
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: 0, titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.topReach, 66, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 525.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 493.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
        XCTAssertEqual(plan.regimeKey, "L403c0p1r0z1t38")
    }

    /// The same shape in the DEFAULT Appearance state (zoom on), which is where BUG-87/89 actually
    /// lived. The floor holds the 20pt lift, so only 2pt of the top reach's give is spendable and
    /// the compression takes the other 22.
    ///
    ///     (b) top     88 → 86 (topReachFloor(lift: 20))          −2   ⇒ 90.33 left
    ///     (c) hero    min(90.33, panel give 160)                = 90.33
    ///     viewport    455 + 90.33                              = 545.33
    ///     linkFrame   86 + 403.33 + 0 + 24                      = 513.33
    ///
    /// Reach 86 is back inside the proven 72-88 corridor, which is what retires rc4's unanswered
    /// "is 64 safe on hardware?" question rather than doubling it.
    func testStevensShapeWithZoomOnPaysTheLiftOutOfCompression() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.zoomOn,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: Theme.Size.heroPinnedRowFocusLiftAllowance,
                                                       titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.topReach, 86, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.compression, 52.333, accuracy: 0.01)  // 90.333 − 38 (panel budget 493, 2026-09-30)
        XCTAssertEqual(plan.viewport, 545.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 513.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
        XCTAssertEqual(plan.regimeKey, "L403c0p1r0z0t38")
    }

    /// FEAT-39: Medium+ (134dp → 350.952… pt) sits above the 335pt hero-compression gate, so it
    /// takes the Large dial exactly the way Large does — `topReachFloor` and `bottomReachFloor` are
    /// artwork-height-independent (lift + title only), so both reaches land on the SAME 86/66/24
    /// numbers as Large. Only the compression differs, because Medium+'s artwork demands
    /// ~52.4pt less than Large's:
    ///
    ///     demand         350.952380952 − 291                          = 59.952380952
    ///     (a) bottom     44 → 24 (bottomReachFloor)            −20    ⇒ 39.952380952 left
    ///     (b) top        88 → 86 (topReachFloor(lift: 20))     −2     ⇒ 37.952380952 left   (zoom on)
    ///                     88 → 66 (topReachFloor(lift: 0))     −22    ⇒ 17.952380952 left   (no zoom)
    ///     (c) hero       min(left, panel give 160)             = left (unclamped either way)
    ///
    /// The rough numbers in the FEAT-39 spec (compression 38/18, viewport 493, linkFrame 461) were
    /// hand-rounded; the exact arithmetic above is what `plan(...)` actually returns, asserted here
    /// to three decimals. `restRange` still nets to exactly 32 (`Spacing.lg + settledCushion`) by the
    /// same construction that gives Large's Stevens shape 32 — the repeating decimals in viewport
    /// and linkFrame cancel.
    ///
    /// rc14 (Steven rc13 verdict, 2026-09-30): the panel's compression is 0 here, so the hero keeps
    /// its whole 140pt synopsis slot (144 before the chrome shave) — four lines of
    /// `Theme.Font.synopsis` on the system face, not the three body lines the old name counted.
    func testMediumPlusTakesTheLargeDialWithFourSystemLines() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                          showsCTA: false, landscapeRows: false,
                                          mode: Self.zoomOn, titleHeight: 38)
        // 2026-09-30: with the panel's 493 budget the demand is 59.952 − 38 = 21.952, so the
        // bottom reach pays 20 and the top reach only the remaining 1.952 (88 → 86.048) — in BOTH
        // zoom modes, since neither floor is reached — and nothing is left for the hero.
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.topReach, 86.048, accuracy: 0.01)
        XCTAssertEqual(plan.bottomReach, 24, accuracy: epsilon)
        XCTAssertEqual(plan.compression, 0, accuracy: 0.01)
        XCTAssertEqual(plan.viewport, 493, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 461, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, 32, accuracy: 0.01)
        XCTAssertEqual(plan.regimeKey, "P351c0p1r0z0t38")

        // rc14: nothing is spent, so the synopsis slot is the full 140 and holds four system lines
        // (`HomeHeroForeground.synopsisLineLimit`'s own arithmetic, 1pt tolerance, mirrored inline).
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: plan.compression,
                                                         showsCTA: false, folderHero: false)
        XCTAssertEqual(split.total, 0, accuracy: epsilon)
        let slot = Theme.Size.heroSynopsisSlotHeightPinnedPanel - split.synopsis
        XCTAssertEqual(slot, 140, accuracy: epsilon)
        let synopsisLine = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        XCTAssertEqual(Int(((slot + 1) / synopsisLine).rounded(.down)), 4)

        let noZoom = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                            showsCTA: false, landscapeRows: false,
                                            mode: Self.noZoom, titleHeight: 38)
        XCTAssertEqual(noZoom.topReach, 86.048, accuracy: 0.01)
        XCTAssertEqual(noZoom.compression, 0, accuracy: 0.01)
    }

    /// The set of legal rests must be narrower than the legibility band `PinnedRowSettle` corrects
    /// into, or the engine could still park somewhere the corrector wants to move — which is the
    /// bouncing the tester reported.
    ///
    /// The band, from `PinnedRowSettle`'s `bandLow`/`bandHigh` in BrowseComponents (~L2674-2677 at the
    /// time of writing; grep the symbols, the line numbers drift) with the row's own geometry,
    /// at the rc10 No-Zoom reach of 66 (the plan spends both reaches to their floors here):
    ///
    ///     clearance = max((Spacing.lg 24 + reach 66) − (titleInset 48 + title 38), 0) = 4
    ///     bandLow   = −clearance.focused = −4        (No Zoom ⇒ zero lift ⇒ focused == atRest)
    ///     lockup    = 24 + 66 + 403.33               = 493.33
    ///     bandHigh  = min(48, 48 + 525.33 − 493.33 − 8) = min(48, 72) = 48
    ///     width     = 52
    ///
    /// against `restRange` = 32, so the invariant still holds. The band is still much narrower than
    /// the pre-rc2 74 (it narrowed at the clearance end when the reach floor was first spent), but
    /// the 4pt it now keeps is `PinnedRowTitle.fadeIntrusionArm` by construction rather than the 2pt
    /// of arithmetic margin rc4 left — see `PinnedRowGeometry.topReachFloor(lift:)`.
    func testStevensShapeRestRangeIsNarrowerThanTheLegibilityBand() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        // No Zoom on Focus ⇒ `focusLiftAllowance` is 0, so the focused clearance is the static one.
        let clearance = PinnedRowTitle.staticClearance(titleHeight: PinnedRowGeometry.measuredTitleHeight,
                                                       cardTopReach: plan.topReach)
        let lockupExtent = Theme.Spacing.lg + plan.topReach + Self.large  // Hide Labels ⇒ no caption
        let bandLow = -clearance
        let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                           Theme.Size.heroPinnedRowTitleInset + plan.viewport - lockupExtent
                               - Theme.Size.heroPinnedRowsSettledCushion)
        let bandWidth = bandHigh - bandLow
        XCTAssertEqual(clearance, 4, accuracy: epsilon)
        XCTAssertEqual(bandWidth, 52, accuracy: epsilon)
        XCTAssertLessThanOrEqual(plan.restRange, bandWidth)
    }

    /// BUG-87/89: the same shape as the test above, in BOTH zoom modes.
    ///
    /// The test above only ever asked the No-Zoom question, where the lift is 0 — so the rc4 reach
    /// floor passed it with a 2pt clearance while the DEFAULT Appearance state (zoom on) had a
    /// NEGATIVE one: `focused = max(2 − 20, 0)` clamped an 18pt permanent overlap to zero, the
    /// corrector's `bandLow` became 0, and the engine's own 32pt of rest freedom sat almost entirely
    /// outside the band. The three things this asserts are the three that broke:
    ///   1. the reach holds the title AND the lift, with the belt's arm edge to spare;
    ///   2. the clamp is therefore inert (`focused == focusedRaw`), i.e. nothing is being hidden;
    ///   3. the band is wider than the set of rests the engine may choose — the premise
    ///      `PinnedRowSettle`'s `UNEXPECTED-WITH-FIT` line asserts and could not rely on.
    func testLargeTopReachHoldsTheFocusLiftInBothZoomModes() {
        for noZoom in [false, true] {
            let label = "noZoom=\(noZoom)"
            let mode = PinnedRowTitle.FocusModeFlags(noZoom: noZoom, accentRing: false)
            let expectedLift: CGFloat = noZoom ? 0 : Theme.Size.heroPinnedRowFocusLiftAllowance
            let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                              captionVisible: false,
                                              showsCTA: false,
                                              landscapeRows: false,
                                              mode: mode,
                                              titleHeight: Self.systemTitle)
            XCTAssertTrue(plan.fits, label)
            XCTAssertEqual(plan.topReach,
                           PinnedRowGeometry.topReachFloor(lift: expectedLift,
                                                           titleHeight: Self.systemTitle),
                           accuracy: epsilon, label)

            let clearance = PinnedRowTitle.clearances(titleHeight: PinnedRowGeometry.measuredTitleHeight,
                                                      cardTopReach: plan.topReach,
                                                      artworkHeight: Self.large,
                                                      captionVisible: false,
                                                      treatment: .cardTreatment,
                                                      mode: mode)
            XCTAssertEqual(clearance.lift, expectedLift, accuracy: epsilon, label)
            // (1) and (2): the band holds title + lift with the belt's arm to spare, so the clamp
            // never bites and `focusedRaw` is not hiding a deficit behind a clean 0.
            XCTAssertGreaterThanOrEqual(clearance.focusedRaw,
                                        PinnedRowTitle.fadeIntrusionArm - epsilon, label)
            XCTAssertEqual(clearance.focused, clearance.focusedRaw, accuracy: epsilon, label)

            // (3) mirrors `PinnedRowSettle.settlePlan`'s band math — grep `bandLow`/`bandHigh` there.
            let lockupExtent = Theme.Spacing.lg + plan.topReach + Self.large  // Hide Labels ⇒ no caption
            let bandLow = -clearance.focused
            let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                               Theme.Size.heroPinnedRowTitleInset + plan.viewport - lockupExtent
                                   - Theme.Size.heroPinnedRowsSettledCushion)
            XCTAssertLessThanOrEqual(plan.restRange, bandHigh - bandLow, label)
        }
    }

    /// The floor's contract as a function, independent of any one Poster Size: whatever lift it is
    /// handed, the reach it returns leaves the settled title clear of the FOCUSED card's artwork by
    /// at least the belt's arm — at the SYSTEM font's title height, which is the height it is handed
    /// here. Skipped where the cap binds — the floor may never exceed `heroPinnedRowTopPad`, because
    /// reach 100 kills focus resolution outright, so a lift larger than 22 is simply not coverable
    /// and the cap is the right answer rather than a raised reach. The same cap is what a TALLER
    /// title runs into, with the same consequence — see the Open Sans test below.
    func testTopReachFloorNeverLeavesTheLiftUncovered() {
        for lift in [0, 10, Theme.Size.heroPinnedRowFocusLiftAllowance, 30] as [CGFloat] {
            let reach = PinnedRowGeometry.topReachFloor(lift: lift, titleHeight: Self.systemTitle)
            XCTAssertLessThanOrEqual(reach, Theme.Size.heroPinnedRowTopPad + epsilon, "lift=\(lift)")
            guard reach < Theme.Size.heroPinnedRowTopPad else { continue }
            let atRest = PinnedRowTitle.staticClearance(titleHeight: PinnedRowGeometry.measuredTitleHeight,
                                                        cardTopReach: reach)
            XCTAssertGreaterThanOrEqual(atRest - lift,
                                        PinnedRowTitle.fadeIntrusionArm - epsilon, "lift=\(lift)")
        }
    }

    /// FEAT-31's **Open Sans**, at the shape BUG-87/89 was filmed in (Large + Hide Labels + FEAT-15
    /// panel) and in the DEFAULT Appearance state (zoom on) — the rc10 Codex P2 case.
    ///
    /// Open Sans's `sectionTitle` line is ≈42.2pt against the system font's 38, and the floor used to
    /// reserve the 38 while `PinnedRowTitle`'s clearance is measured from what is actually DRAWN. The
    /// 4.2pt gap is more than the entire margin the floor keeps:
    ///
    ///     floor     48 + 42.2 − 24 + 20 + 4 = 90.2  →  CAPPED at heroPinnedRowTopPad 88
    ///     (b) top   88 → 88                          −0   ⇒ 92.33 left for the hero
    ///     viewport  455 + 92.33                     = 547.33
    ///     linkFrame 88 + 403.33 + 0 + 24            = 515.33   ⇒ fits, restRange 32
    ///     atRest    (24 + 88) − (48 + 42.2)         = 21.8
    ///     focused   21.8 − 20                       = 1.8      ⇒ POSITIVE, so no stand-down
    ///
    /// Asserted in the order things broke: with the stale 38 the same shape floors at 86 and
    /// `focusedRaw` is −0.2, which is `PinnedRowSettle`'s `LIFT-DEFICIT` stand-down — for the whole
    /// session, on a font the app ships; with the live metric the CAP binds instead, the clearance is
    /// non-negative, the frame still fits, and the corrector keeps its rest.
    ///
    /// The 1.8 is stated rather than smoothed over: it is under `fadeIntrusionArm`, so at the cap the
    /// belt's arm margin is NOT guaranteed and the belt may fade a title that is technically clear.
    /// Documented at `PinnedRowGeometry.topReachFloor(lift:titleHeight:)` — the only alternative is a
    /// reach past 88, which kills focus resolution outright.
    func testOpenSansTitleTakesTheReachCapWithoutStandingTheCorrectorDown() {
        let lift = Theme.Size.heroPinnedRowFocusLiftAllowance

        // The defect: the system font's 38 leaves an Open Sans title a NEGATIVE focused clearance,
        // which is exactly the geometry the derived floor exists to make impossible.
        let staleFloor = PinnedRowGeometry.topReachFloor(lift: lift, titleHeight: Self.systemTitle)
        XCTAssertEqual(staleFloor, 86, accuracy: epsilon)
        let stale = PinnedRowTitle.clearances(titleHeight: Self.openSansTitle,
                                              cardTopReach: staleFloor,
                                              artworkHeight: Self.large,
                                              captionVisible: false,
                                              treatment: .cardTreatment,
                                              mode: Self.zoomOn)
        XCTAssertLessThan(stale.focusedRaw, 0,
                          "the stale 38pt floor must be shown to reproduce the LIFT-DEFICIT deficit")

        // The fix: the floor wants 90.2 for this title and takes the 88 cap.
        XCTAssertEqual(PinnedRowGeometry.topReachFloor(lift: lift, titleHeight: Self.openSansTitle),
                       Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.zoomOn,
                                          titleHeight: Self.openSansTitle)
        XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.compression, 54.333, accuracy: 0.01)  // 92.333 − 38 (panel budget 493)
        XCTAssertLessThan(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: false))
        XCTAssertEqual(plan.viewport, 547.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 515.333, accuracy: 0.01)
        // The product question this test was asked to answer: the extra 2pt of compression does NOT
        // cost the fit — the panel's give is 160 (rc14; 142 before) and 54.33 of it is enough.
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.restRange,
                       Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)

        let clearance = PinnedRowTitle.clearances(titleHeight: Self.openSansTitle,
                                                  cardTopReach: plan.topReach,
                                                  artworkHeight: Self.large,
                                                  captionVisible: false,
                                                  treatment: .cardTreatment,
                                                  mode: Self.zoomOn)
        XCTAssertEqual(clearance.atRest, 21.8, accuracy: 0.01)
        XCTAssertEqual(clearance.focusedRaw, 1.8, accuracy: 0.01)
        // No stand-down: `settlePlan`'s LIFT-DEFICIT branch is `focusedRaw < 0`, and the clamp is
        // inert, so nothing is hiding a deficit behind a clean 0 either.
        XCTAssertGreaterThanOrEqual(clearance.focusedRaw, 0)
        XCTAssertEqual(clearance.focused, clearance.focusedRaw, accuracy: epsilon)
        // …but short of the belt's arm, which is the documented price of sitting on the cap.
        XCTAssertLessThan(clearance.focusedRaw, PinnedRowTitle.fadeIntrusionArm)

        // And the set of rests the engine may choose is still inside the corrector's band, so the
        // `UNEXPECTED-WITH-FIT` premise holds for this font too.
        let lockupExtent = Theme.Spacing.lg + plan.topReach + Self.large  // Hide Labels ⇒ no caption
        let bandLow = -clearance.focused
        let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                           Theme.Size.heroPinnedRowTitleInset + plan.viewport - lockupExtent
                               - Theme.Size.heroPinnedRowsSettledCushion)
        XCTAssertLessThanOrEqual(plan.restRange, bandHigh - bandLow)
    }

    /// The live metric the shipping floor DEFAULTS to has to describe the token it claims to. A
    /// tolerance rather than an equality on purpose: this runs against whatever font family the test
    /// host currently has applied (`Theme.Font.apply` is process-global — `AppFontResolverTests`
    /// moves it), and a future tvOS could move the system `.callout` line by a point without anything
    /// being wrong. What would be wrong is a metric far from BOTH shipping values, which means the
    /// token mapping or the measurement drifted — and the floor would then reserve the wrong band.
    func testTheDefaultTitleMetricIsOneOfTheShippingTitleHeights() {
        let live = Theme.Font.sectionTitleLineHeight
        XCTAssertGreaterThan(live, 0)
        XCTAssertEqual(live, Self.systemTitle, accuracy: 6,
                       "live sectionTitle metric \(live) is far from both shipping heights"
                        + " (\(Self.systemTitle) system / \(Self.openSansTitle) Open Sans)")
    }

    /// The same Poster Size with the CAROUSEL hero, in No Zoom. The reaches are still spent first;
    /// as of rc10's lift-aware floor the leftover is 70.33.
    ///
    /// rc14 (Steven rc13 verdict, 2026-09-30): the carousel's give grew 70 → 92 (frame slack 2 → 22,
    /// logo give 32 → 34), so the 0.33pt that used to bind the old 70 cap is no longer clipped and
    /// this regime gets the full construction (restRange 32) again:
    ///
    ///     demand 112.33 → bottom 44→24 (−20) → top 88→66 (−22) → compression min(70.33, 92) = 70.33
    ///     viewport  455 + 70.33              = 525.33
    ///     linkFrame 66 + 403.33 + 0 + 24     = 493.33
    ///     restRange                          = 32   (Spacing.lg + cushion, the full construction)
    ///
    /// The pre-rc14 version of this test read 70 / 525 / 493.33 / 31.67 (cap binding, 0.33 short of
    /// the cushion); rc4's read 68.33 / 523.33 / 491.33 / 32 at the flat reach floor of 64.
    func testLargeHideLabelsWithCarouselHeroSpendsBothReachesThenTheRemainder() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: true,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 70.333, accuracy: 0.01)
        // rc14: the leftover demand is what is spent now — the carousel's 92 cap no longer binds.
        XCTAssertLessThan(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: true))
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: 0, titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 525.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 493.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, 32, accuracy: 0.01)
        XCTAssertEqual(plan.restRange,
                       Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
    }

    /// Large + captions + carousel hero in ZOOM ON is still unsatisfiable by design: ~155.8pt of
    /// demand against 44pt of reach give (the zoom-on floor only gives 22 of it: 20 + 2) and 92pt of
    /// elastic give. The reaches floor at 24/86, 133.83 is left over and the carousel can give 92 of
    /// it, so the 556.83 link frame sits 9.83pt past the 547 viewport. The plan must NOT pretend — it
    /// reports `fits == false` and hands back TODAY'S numbers verbatim (compression 68.33, reaches
    /// 88/44), so the visibility belt owns the residue in exactly the regime that shipped in beta.17.
    ///
    /// rc14: this test ran in No Zoom until the carousel's give grew 70 → 92. In No Zoom the reaches
    /// floor at 24/66 and the 92 cap now covers enough that the frame fits — see
    /// `testLargeWithCaptionsAndCarouselHeroNoZoomFitsOnTheWiderCap`.
    func testLargeWithCaptionsAndCarouselHeroFallsBackToTodaysNumbers() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: true,
                                          showsCTA: true,
                                          landscapeRows: false,
                                          mode: Self.zoomOn,
                                          titleHeight: Self.systemTitle)
        XCTAssertFalse(plan.fits)
        XCTAssertEqual(plan.compression,
                       PinnedRowTitle.pinnedHeroCompression(rowArtworkHeight: Self.large, showsCTA: true),
                       accuracy: epsilon)
        XCTAssertEqual(plan.compression, 68.333, accuracy: 0.01)
        XCTAssertEqual(plan.topReach, Theme.Size.heroPinnedRowTopPad, accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, Theme.Size.heroPinnedRowBottomReach, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 523.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 578.833, accuracy: 0.01)
    }

    /// rc14 (Steven rc13 verdict, 2026-09-30): the No Zoom twin of the test above flipped from
    /// unsatisfiable to FITTING when the carousel's give grew 70 → 92. Both reaches floor at 24/66,
    /// the compression takes the whole 92 cap (the 113.83 leftover is more than it can give), and the
    /// frame fits with a thin rest range — the demand's 32pt of rest slack is no longer fully
    /// covered, but the frame itself is inside the viewport, which is what `fits` means:
    ///
    ///     demand    155.83 → bottom −20 → top −22 → 113.83 left → compression min(113.83, 92) = 92
    ///     viewport  455 + 92                = 547
    ///     linkFrame 66 + 403.33 + 43.5 + 24 = 536.83
    ///     restRange                         = 10.17
    func testLargeWithCaptionsAndCarouselHeroNoZoomFitsOnTheWiderCap() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: true,
                                          showsCTA: true,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 92, accuracy: 0.01)
        XCTAssertEqual(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: true), accuracy: epsilon)
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: 0, titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 547, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 536.833, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, 10.167, accuracy: 0.01)
    }

    /// Large + captions in the FEAT-15 panel IS satisfiable, in No Zoom: both reaches go to their
    /// floors and the panel's 160pt of give (rc14; 142 before) covers the 113.83 that is left, short
    /// of its own cap.
    ///
    ///     demand    24 + 88 + 403.33 + 43.5 + 44 + 8 − 455 = 155.83
    ///     (a) bottom 44 → 24                                −20  ⇒ 135.83
    ///     (b) top    88 → 66 (topReachFloor(lift: 0))        −22  ⇒ 113.83
    ///     (c) hero   min(113.83, 160)                      = 113.83, 46.17 of give unspent
    ///     viewport  455 + 113.83                           = 568.83
    ///     linkFrame 66 + 403.33 + 43.5 + 24                = 536.83
    ///     restRange                                        = 32
    ///
    /// (The 493 panel budget lowers the compression to 75.83; the block above is the carousel-budget
    /// derivation the original was written against.) rc4's version of this test read 111.83 /
    /// 566.83 / 534.83 at the flat reach floor of 64. The hero spends its free slack and the logo
    /// before the description (`HeroSlotGive`, rc14: 22 + 34, then 19.83 from the synopsis), so the
    /// synopsis slot is 140 − 19.83 = 120.17 at the 75.83 compression.
    func testLargeWithCaptionsInPanelModeFitsAfterBothReachesFloor() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: true,
                                          showsCTA: false,
                                          landscapeRows: false,
                                          mode: Self.noZoom,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.compression, 75.833, accuracy: 0.01)  // 113.833 − 38 (panel budget 493)
        XCTAssertLessThan(plan.compression, PinnedRowGeometry.elasticGive(showsCTA: false))
        XCTAssertEqual(plan.topReach,
                       PinnedRowGeometry.topReachFloor(lift: 0, titleHeight: Self.systemTitle),
                       accuracy: epsilon)
        XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon)
        XCTAssertEqual(plan.viewport, 568.833, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 536.833, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Spacing.lg + Theme.Size.heroPinnedRowsSettledCushion, accuracy: epsilon)
    }

    // MARK: - The spend order itself

    /// The rc2 order, stated as an invariant rather than as a number: the reaches are spent BEFORE
    /// the compression, so any plan that ends up compressing at all must already have both reaches
    /// on their floors. (The demand always exceeds the 44pt of reach give wherever the scope gate
    /// is open at all: `demand == legacyRawDemand + captionChrome + 44`.)
    ///
    /// The mirror clause covers the paths that spend nothing: the closed gate (Small, Medium,
    /// landscape) hands back the shipped reaches untouched. rc14: the unsatisfiable fallback is no
    /// longer reachable from this No Zoom sweep — Large + captions + carousel fits on the 92 cap — it
    /// survives in zoom on (`testLargeWithCaptionsAndCarouselHeroFallsBackToTodaysNumbers`).
    func testCompressionIsOnlySpentAfterBothReachesAreOnTheirFloors() {
        for (label, plan) in Self.crossProduct() {
            if plan.fits, plan.compression > 0 {
                XCTAssertEqual(plan.topReach,
                               PinnedRowGeometry.topReachFloor(lift: 0,
                                                               titleHeight: Self.systemTitle),
                               accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon, label)
            } else if plan.topReach < Theme.Size.heroPinnedRowTopPad - epsilon {
                // 2026-09-30: with the panel's 493 budget the demand can be smaller than the 44pt of
                // reach give (Medium+ panel: 21.952), so the plan stops part-way down the top reach
                // with nothing left for the hero. The ORDER still holds: bottom first, then top.
                XCTAssertEqual(plan.compression, 0, accuracy: epsilon, label)
                XCTAssertEqual(plan.bottomReach, PinnedRowGeometry.bottomReachFloor, accuracy: epsilon, label)
                XCTAssertGreaterThanOrEqual(plan.topReach,
                                            PinnedRowGeometry.topReachFloor(lift: 0,
                                                                            titleHeight: Self.systemTitle)
                                                - epsilon, label)
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
    ///
    /// rc14 (Steven rc13 verdict, 2026-09-30): 92 / 160 (were 70 / 142) — the frame slack grew 2 →
    /// 22 and the logo give 32 → 34, and the panel's absorbed gap is `heroPinnedSlotGap` (12), not
    /// `Spacing.md` (16), so the form gap is the CTA slot plus 12.
    func testElasticGiveMatchesTheHeroFormOnScreen() {
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: true),
                       Theme.Size.heroPinnedCompressionCap, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: true), 92, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: false), 160, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: false)
                        - PinnedRowGeometry.elasticGive(showsCTA: true),
                       Theme.Size.heroButtonSlotHeight + Theme.Size.heroPinnedSlotGap, accuracy: epsilon)
    }

    /// rc14: the compression cap is the sum of the three things the pinned hero can yield — the
    /// frame's free slack (22, now DERIVED from the chrome: 352 − (2·12 + 110 + 3·12 + 32 + 72 + 56)),
    /// the logo down to its 76 floor (34), and the synopsis down to one 36pt line (36 carousel, 104
    /// panel, whose slot is 140). Each constant is pinned so a change to any one of them moves this
    /// test loudly instead of silently moving the cap.
    func testElasticGiveIsSlackPlusBothGives() {
        XCTAssertEqual(Theme.Size.heroPinnedFrameSlack, 22, accuracy: epsilon)
        XCTAssertEqual(Theme.Size.heroLogoSlotHeightPinnedFloor, 76, accuracy: epsilon)
        XCTAssertEqual(Theme.Size.heroLogoSlotPinnedGive, 34, accuracy: epsilon)
        XCTAssertEqual(Theme.Size.heroSynopsisSlotPinnedGive, 36, accuracy: epsilon)
        XCTAssertEqual(Theme.Size.heroSynopsisSlotHeightPinnedPanel, 140, accuracy: epsilon)
        XCTAssertEqual(Theme.Size.heroSynopsisSlotPanelPinnedGive, 104, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: true), 22 + 34 + 36, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.elasticGive(showsCTA: false), 22 + 34 + 104, accuracy: epsilon)
    }

    /// A pure function: the plan depends on its inputs and on nothing else (no live layout, no
    /// per-row or per-focus state). This is what lets `onChange(of: pinnedPlan.regimeKey)` be the
    /// only re-reveal trigger.
    func testPlanIsPure() {
        for mode in [Self.noZoom, Self.noZoomHolding] {
            for (label, plan) in Self.crossProduct(mode: mode) {
                let again = PinnedRowGeometry.plan(posterHeight: planHeight(for: label),
                                                   captionVisible: label.contains("captions=true"),
                                                   showsCTA: label.contains("showsCTA=true"),
                                                   landscapeRows: label.contains("landscape=true"),
                                                   mode: mode,
                                                   titleHeight: Self.systemTitle)
                XCTAssertEqual(plan, again, label)
            }
        }
    }

    /// One key per regime, and a different key for every other regime — the `onChange` contract.
    ///
    /// rc10 added the trailing `z` component, because the plan is mode-dependent now: the SAME
    /// (size × captions × hero form × row shape) tuple produces different reaches in the two zoom
    /// modes, so they must not share a key (`PinnedRowSettle.regimeFits` and its log-once sets are
    /// keyed on this string). `accentRing` is deliberately NOT encoded — since BUG-93 both zoom-on
    /// treatments lift by the same amount, so a ring flip produces an identical plan.
    /// rc12: the reach-hold A/B's `noZoomHolding` regime must not collide with plain `noZoom`
    /// either — combined, the two 32-entry cross products (`allSizes` × captions × CTA × landscape)
    /// must yield 64 distinct keys, and the holding regime's Medium key must be the plain key with
    /// `h1` appended (see `regimeKey`'s doc for why `h1` is conditional).
    func testRegimeKeysAreDistinctAcrossTheCrossProduct() {
        let keys = Self.crossProduct().map { $0.plan.regimeKey }
            + Self.crossProduct(mode: Self.noZoomHolding).map { $0.plan.regimeKey }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(keys).count, 64)
        XCTAssertEqual(PinnedRowGeometry.plan(posterHeight: Self.medium,
                                              captionVisible: true,
                                              showsCTA: true,
                                              landscapeRows: false,
                                              mode: Self.noZoom,
                                              titleHeight: Self.systemTitle).regimeKey,
                       "M330c1p0r0z1t38")
        XCTAssertEqual(PinnedRowGeometry.plan(posterHeight: Self.medium,
                                              captionVisible: true,
                                              showsCTA: true,
                                              landscapeRows: false,
                                              mode: Self.zoomOn,
                                              titleHeight: Self.systemTitle).regimeKey,
                       "M330c1p0r0z0t38")
        XCTAssertEqual(PinnedRowGeometry.plan(posterHeight: Self.medium,
                                              captionVisible: true,
                                              showsCTA: true,
                                              landscapeRows: false,
                                              mode: Self.noZoomHolding,
                                              titleHeight: Self.systemTitle).regimeKey,
                       "M330c1p0r0z1t38h1rt4")
        // The ring is not part of the key, because it is not part of the plan.
        XCTAssertEqual(PinnedRowGeometry.regimeKey(posterHeight: Self.medium,
                                                   captionVisible: true,
                                                   showsCTA: true,
                                                   landscapeRows: false,
                                                   mode: .init(noZoom: false, accentRing: true),
                                                   titleHeight: Self.systemTitle),
                       "M330c1p0r0z0t38")
        // Two title metrics at the SAME (size × captions × hero form × row shape × mode) tuple must
        // not share a key either (rc10 Codex P2 fix 4) — a font switch (System ↔ Open Sans) must not
        // inherit the previous geometry's disarm/verify-failure state.
        XCTAssertNotEqual(PinnedRowGeometry.regimeKey(posterHeight: Self.medium,
                                                      captionVisible: true,
                                                      showsCTA: true,
                                                      landscapeRows: false,
                                                      mode: Self.noZoom,
                                                      titleHeight: Self.systemTitle),
                          PinnedRowGeometry.regimeKey(posterHeight: Self.medium,
                                                      captionVisible: true,
                                                      showsCTA: true,
                                                      landscapeRows: false,
                                                      mode: Self.noZoom,
                                                      titleHeight: Self.openSansTitle))
    }

    // MARK: - rc12: the No Zoom reach-hold A/B (BUG-87 follow-up)

    /// The headline claim: with the hold ON, No Zoom's Large carousel spends EXACTLY the zoom-on
    /// floor (86, not 66) — compare against
    /// `testLargeHideLabelsWithCarouselHeroSpendsBothReachesThenTheRemainder`'s plain-`noZoom`
    /// numbers (topReach 66, compression 70.33; the hold takes the 2026-09-30 rest target instead,
    /// so its compression is 62.33 and `linkFrame`/`restRange` move with the 20pt the floor gained).
    func testNoZoomWithTheReachHoldTakesTheZoomOnFloor() {
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                          captionVisible: false,
                                          showsCTA: true,
                                          landscapeRows: false,
                                          mode: Self.noZoomHolding,
                                          titleHeight: Self.systemTitle)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.topReach, 86, accuracy: epsilon)
        // 2026-09-30 rest target: a held regime's demand reserves `heroPinnedRowsRestTarget` (4)
        // instead of 32, so demand 84.333 − bottom 20 − top 2 = 62.333, under the 92 cap.
        XCTAssertEqual(plan.compression, 62.333, accuracy: 0.01)
        XCTAssertEqual(plan.viewport, 517.333, accuracy: 0.01)
        XCTAssertEqual(plan.linkFrame, 513.333, accuracy: 0.01)
        XCTAssertEqual(plan.restRange, Theme.Size.heroPinnedRowsRestTarget, accuracy: 0.01)
        XCTAssertEqual(plan.regimeKey, "L403c0p0r0z1t38h1rt4")
    }

    /// THE rationale pin for why the flag is routed through the reach floor and never through
    /// `focusLiftAllowance`: at the same Large carousel shape as the test above, the hold leaves
    /// `PinnedRowTitle.clearances`' `lift` at 0 (nothing scales in No Zoom, hold or not) and instead
    /// widens the band by raising `atRest`/`focused`/`focusedRaw` together — the exact opposite of
    /// charging a lift, which would have moved `focused` DOWN and left `bandLow` unchanged at −4.
    ///
    ///     hold ON   cardTopReach 86 → atRest = focused = focusedRaw = 24 → bandLow = −24
    ///     hold OFF  cardTopReach 66 → atRest = focused = focusedRaw = 4  → bandLow = −4
    ///
    /// Steven's sim reading (`margin=-22`) sits OUTSIDE the OFF band (−22 < −4, the belt's fade
    /// condition, matching the reported bounce) and INSIDE the ON band (−24 ≤ −22 ≤ 48, `bandHigh`
    /// being the title inset, 48, in both regimes).
    func testTheReachHoldWidensTheBandInsteadOfChargingLift() {
        let steadyMargin: CGFloat = -22
        let bandHigh: CGFloat = 48

        for (mode, expectedClearance, expectedBandLow, marginInBand) in [
            (Self.noZoomHolding, CGFloat(24), CGFloat(-24), true),
            (Self.noZoom, CGFloat(4), CGFloat(-4), false),
        ] {
            let plan = PinnedRowGeometry.plan(posterHeight: Self.large,
                                              captionVisible: false,
                                              showsCTA: true,
                                              landscapeRows: false,
                                              mode: mode,
                                              titleHeight: Self.systemTitle)
            let clearance = PinnedRowTitle.clearances(titleHeight: Self.systemTitle,
                                                      cardTopReach: plan.topReach,
                                                      artworkHeight: Self.large,
                                                      captionVisible: false,
                                                      treatment: .cardTreatment,
                                                      mode: mode)
            let label = "hold=\(mode.reachHoldsLift)"
            XCTAssertEqual(clearance.lift, 0, accuracy: epsilon, label)
            XCTAssertEqual(clearance.atRest, expectedClearance, accuracy: epsilon, label)
            XCTAssertEqual(clearance.focused, expectedClearance, accuracy: epsilon, label)
            XCTAssertEqual(clearance.focusedRaw, expectedClearance, accuracy: epsilon, label)

            let bandLow = -clearance.focused
            XCTAssertEqual(bandLow, expectedBandLow, accuracy: epsilon, label)
            let inBand = steadyMargin >= bandLow && steadyMargin <= bandHigh
            XCTAssertEqual(inBand, marginInBand, label)
        }
    }

    /// The hold is inert with zoom on — `reachHoldsLiftEffective` requires `noZoom` too, so a
    /// `FocusModeFlags` that somehow carried both `reachHoldsLift: true` and `noZoom: false` (never
    /// produced by any shipping reader — both `@AppStorage` sites AND `PinnedRowTitle.current` gate
    /// on the same two keys) must plan identically to plain `zoomOn`.
    func testTheReachHoldIsInertWithZoomOn() {
        let zoomOnHolding = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false,
                                                          reachHoldsLift: true)
        XCTAssertFalse(zoomOnHolding.reachHoldsLiftEffective)
        for (name, height) in Self.allSizes {
            for captions in [false, true] {
                for cta in [false, true] {
                    let label = "\(name) captions=\(captions) showsCTA=\(cta)"
                    let plan = PinnedRowGeometry.plan(posterHeight: height, captionVisible: captions,
                                                      showsCTA: cta, landscapeRows: false,
                                                      mode: zoomOnHolding, titleHeight: Self.systemTitle)
                    let plainZoomOn = PinnedRowGeometry.plan(posterHeight: height, captionVisible: captions,
                                                             showsCTA: cta, landscapeRows: false,
                                                             mode: Self.zoomOn, titleHeight: Self.systemTitle)
                    XCTAssertEqual(plan, plainZoomOn, label)
                    XCTAssertEqual(plan.regimeKey, plainZoomOn.regimeKey, label)
                }
            }
        }
    }

    // MARK: - BUG-87/89 (rc11): the last-row link-frame floor

    /// BUG-87/89 (rc11, hardened by Codex r1 on rc11): the last row's label floor is the LARGER of the plan's own
    /// link frame and `viewport − Spacing.lg` — not `linkFrame` alone. The carousel case here is
    /// where the two coincide (its `restRange`, 4, is under `Spacing.lg`), so a uniform row
    /// needs no extra and a short-tile collection row gets exactly the difference, unchanged from
    /// rc11. The panel case below is where they DON'T coincide (`restRange` 32 > `Spacing.lg`), which
    /// is exactly the shape Finding 1 closes: `linkFrame` alone would have permitted a rest above the
    /// band.
    ///
    /// rc14 (Steven rc13 verdict, 2026-09-30): the carousel case moved to the HELD zoom-on regime
    /// (the shipping default). It used to be the unheld one (title 37, restRange 12.67), but the
    /// carousel's give grew 70 → 92, so the unheld plan now spends its whole 89.33 leftover and ends
    /// with `restRange` 32 — a ceiling-bound floor like the panel's, no longer the "linkFrame binds"
    /// shape this case exists to cover.
    func testLastRowLinkFrameFloorTakesTheLargerOfLinkFrameAndTheBandCeiling() {
        let carousel = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                              showsCTA: true, landscapeRows: false,
                                              mode: Self.zoomOnHeld, titleHeight: Self.systemTitle)
        XCTAssertTrue(carousel.fits)
        XCTAssertEqual(carousel.restRange, 4, accuracy: 0.01)
        // `linkFrame` (519.33) already exceeds `viewport − lg` (523.33 − 24 = 499.33): the `max`
        // picks `linkFrame`, exactly rc11's behavior.
        XCTAssertGreaterThan(carousel.linkFrame, carousel.viewport - Theme.Spacing.lg)
        XCTAssertEqual(PinnedRowGeometry.lastRowLinkFrameFloor(plan: carousel), carousel.linkFrame,
                       accuracy: 0.01)
        // A uniform poster row's own label IS the plan's link frame — nothing to add.
        XCTAssertEqual(PinnedRowGeometry.lastRowBottomReachExtra(plan: carousel, labelFrame: carousel.linkFrame),
                       0, accuracy: 0.01)
        // The tester's last row: hidden-title SQUARE folder tiles, whose artwork is `style.width`
        // (FolderTile.artworkHeight), not `style.height`.
        let squareTile = Theme.Size.posterWidth / 126.0 * 154.0          // 268.88…
        let carouselTileLabel = carousel.topReach + squareTile + carousel.bottomReach   // 384.89
        XCTAssertEqual(PinnedRowGeometry.lastRowBottomReachExtra(plan: carousel, labelFrame: carouselTileLabel),
                       134.44, accuracy: 0.5)
        // The point of the number: the shaped label leaves the engine only the rest interval every
        // other row in this regime already settles inside.
        let shelfTopPad = Theme.Spacing.lg
        let deepestRowTop = carousel.viewport - shelfTopPad - carousel.linkFrame
        let deepestMargin = deepestRowTop + Theme.Size.heroPinnedRowTitleInset
        XCTAssertLessThanOrEqual(deepestMargin, Theme.Size.heroPinnedRowTitleInset)   // ≤ bandHigh
        XCTAssertGreaterThanOrEqual(deepestMargin, -4)                                // ≥ bandLow

        // The panel case Finding 1 is about: hero-OFF (FEAT-15, showsCTA: false) at Large, systemTitle
        // (38 ⇒ topReachFloor 86, the canonical zoom-on number). Its `restRange` (32) is bigger than
        // `Spacing.lg` (24), so the ceiling — not `linkFrame` — is the binding term.
        let panel = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                           showsCTA: false, landscapeRows: false,
                                           mode: Self.zoomOn, titleHeight: Self.systemTitle)
        XCTAssertTrue(panel.fits)
        XCTAssertGreaterThan(panel.restRange, Theme.Spacing.lg)
        let panelFloor = PinnedRowGeometry.lastRowLinkFrameFloor(plan: panel)
        // floor == viewport − lg (the ceiling), strictly greater than linkFrame alone.
        XCTAssertEqual(panelFloor, panel.viewport - Theme.Spacing.lg, accuracy: 0.01)
        XCTAssertGreaterThan(panelFloor, panel.linkFrame)
        // …and by construction that ceiling makes the margin range exactly [24, 48]: the band's full
        // width, no more.
        XCTAssertEqual(Theme.Spacing.lg + panel.viewport - panelFloor, 48, accuracy: 0.01)
        // The frame still fits: floor + lg <= viewport.
        XCTAssertLessThanOrEqual(panelFloor + Theme.Spacing.lg, panel.viewport + 0.01)
        // Same square-tile arithmetic as the carousel case above, now against the ceiling-derived
        // floor rather than `linkFrame` — the number is bigger because the floor is.
        let panelTileLabel = panel.topReach + squareTile + panel.bottomReach
        let panelExtra = PinnedRowGeometry.lastRowBottomReachExtra(plan: panel, labelFrame: panelTileLabel)
        XCTAssertEqual(panelExtra, panelFloor - panelTileLabel, accuracy: 0.01)
        XCTAssertEqual(panelExtra, 142.44, accuracy: 0.5)
    }

    /// Finding 1 (P2): the floor confines EVERY fitting regime to the band `[24, 48]` in margin
    /// terms — not just the two cases spelled out above. Sweeps every Poster Size the app can
    /// actually produce, both caption states, both hero forms, both zoom modes and both title
    /// metrics (System vs FEAT-31's Open Sans) — 4 × 2 × 2 × 2 × 2 = 64 regimes.
    func testLastRowFloorConfinesEveryFittingRegimeToTheBand() {
        for (name, height) in Self.allSizes {
            for captionVisible in [false, true] {
                for showsCTA in [false, true] {
                    for mode in [Self.zoomOn, Self.noZoom] {
                        for titleHeight in [Self.systemTitle, Self.openSansTitle] {
                            let label = "\(name) captions=\(captionVisible) showsCTA=\(showsCTA)"
                                + " noZoom=\(mode.noZoom) title=\(titleHeight)"
                            let plan = PinnedRowGeometry.plan(posterHeight: height,
                                                              captionVisible: captionVisible,
                                                              showsCTA: showsCTA,
                                                              landscapeRows: false,
                                                              mode: mode,
                                                              titleHeight: titleHeight)
                            let floor = PinnedRowGeometry.lastRowLinkFrameFloor(plan: plan)
                            guard plan.fits else {
                                XCTAssertEqual(floor, 0, accuracy: epsilon, label)
                                continue
                            }
                            // The floored label must fit the viewport (floor ≤ viewport); it may exceed
                            // viewport − shelfTopPad when the regime's own link frame already does (Small + captions:
                            // 450.5 in 455), in which case the engine's tolerated interval is [−24, viewport − 24 − floor],
                            // non-empty as long as floor ≤ viewport, and its margin ceiling 24 + viewport − floor is
                            // still checked below.
                            XCTAssertLessThanOrEqual(floor, plan.viewport + 0.01, label)
                            // The max margin the floor permits never exceeds the band's own upper
                            // edge (48) — the whole point of taking the ceiling over `linkFrame`
                            // alone.
                            XCTAssertLessThanOrEqual(Theme.Spacing.lg + plan.viewport - floor,
                                                     Theme.Size.heroPinnedRowTitleInset + 0.01, label)
                            // The min margin (24, i.e. rowTop == −shelfTopPad) is trivially inside
                            // the band's lower edge with the corrector's ±2 tolerance to spare.
                            XCTAssertGreaterThanOrEqual(Theme.Spacing.lg, -4, label)
                        }
                    }
                }
            }
        }
    }

    /// The floor never manufactures an over-tall frame: `!fits` regimes opt out.
    func testLastRowLinkFrameFloorIsZeroWhenTheRegimeDoesNotFit() {
        // Large + captions + carousel in zoom on is the documented unsatisfiable regime (fits ==
        // false) — see `testLargeWithCaptionsAndCarouselHeroFallsBackToTodaysNumbers` above. rc14: its
        // No Zoom twin FITS now (the carousel's give grew 70 → 92), so zoom on is the one that opts out.
        let plan = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: true,
                                          showsCTA: true, landscapeRows: false,
                                          mode: Self.zoomOn, titleHeight: 38)
        XCTAssertFalse(plan.fits)
        XCTAssertEqual(PinnedRowGeometry.lastRowLinkFrameFloor(plan: plan), 0, accuracy: epsilon)
    }

    // MARK: - BUG-87/89 (rc11, governance-checked by Codex r2 on rc11): the last-row exemption's own predicate

    /// `PinnedRowSettle.lastRowExemptionApplies` (Codex r2 P2) — a floor that EXISTS is not enough;
    /// it must also GOVERN the focused label, i.e. the label's natural lockup extent must not exceed
    /// the floored frame. Three shapes:
    ///
    ///  (a) no floor at all (every non-last row, and a last row outside pinned mode) — never exempt.
    ///  (b) a uniform SQUARE folder tile inside the carousel regime whose floor is its own
    ///      `linkFrame` — the floor is sized for exactly this tile's shape, so it governs.
    ///  (c) the rc11 Codex-r2 finding: a PORTRAIT folder inside a LANDSCAPE-ROWS regime. The row's floor
    ///      is calibrated to the regime's own (landscape) `linkFrame`, but this doc's own note on
    ///      `PinnedRowGeometry.plan(landscapeRows:)` says a portrait folder in that mode still
    ///      presents `posterHeight`-tall tiles — taller than the floor was ever sized for — so the
    ///      floor does not govern and the exemption must not fire.
    func testLastRowExemptionAppliesOnlyWhenTheFloorGovernsTheLabel() {
        // (a) No floor published (0 — the field's default, and every row but Home's last while
        // pinned mode is even active) — never exempt, whatever the label's own extent is.
        XCTAssertFalse(PinnedRowSettle.lastRowExemptionApplies(lockupExtent: 100, linkFrameFloor: 0))

        // (b) The carousel regime from `testLastRowLinkFrameFloorTakesTheLargerOfLinkFrameAndTheBandCeiling`
        // above: its floor IS `plan.linkFrame` (519.33, rc14: the held carousel), sized for this same
        // Large artwork. A hidden-title SQUARE folder tile's own lockup extent — `lg + topReach +
        // squareTile`, the same `Measurement.lockupExtent`/`CollectionRowView.focusedTileLockupExtent`
        // shape, with no caption term because the title is hidden — sits well under it, so the floor
        // governs.
        let carousel = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                              showsCTA: true, landscapeRows: false,
                                              mode: Self.zoomOnHeld, titleHeight: Self.systemTitle)
        let carouselFloor = PinnedRowGeometry.lastRowLinkFrameFloor(plan: carousel)
        let squareTile = Theme.Size.posterWidth / 126.0 * 154.0   // 268.88…, FolderTile.artworkHeight
        let squareLockupExtent = Theme.Spacing.lg + carousel.topReach + squareTile
        XCTAssertTrue(PinnedRowSettle.lastRowExemptionApplies(lockupExtent: squareLockupExtent,
                                                              linkFrameFloor: carouselFloor))

        // (c) The rc11 Codex-r2 regression: Large + Landscape Rows + No Zoom, hero-off panel shape
        // (`showsCTA: false`), captions off. `landscapeRows: true` sizes the floor off the 203pt
        // landscape artwork (floor 469 — `max(linkFrame 335, viewport-lg 469)`, the panel's 493 budget), but a collection
        // row's folder that keeps its PORTRAIT shape (`FolderTile.artworkHeight`, per `plan`'s own
        // doc comment on `landscapeRows`) still stands `posterHeight` (403.33) tall. That lockup
        // extent — `lg + topReach + posterHeight`, again no caption term (hidden title) — overshoots
        // the floor by far more than rounding, so the exemption must not apply.
        let landscapeRowsPlan = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                                       showsCTA: false, landscapeRows: true,
                                                       mode: Self.noZoom, titleHeight: Self.systemTitle)
        let landscapeFloor = PinnedRowGeometry.lastRowLinkFrameFloor(plan: landscapeRowsPlan)
        let portraitFolderLockupExtent = Theme.Spacing.lg + landscapeRowsPlan.topReach + Self.large
        XCTAssertFalse(PinnedRowSettle.lastRowExemptionApplies(lockupExtent: portraitFolderLockupExtent,
                                                               linkFrameFloor: landscapeFloor))
        // Sanity-check the finding's own numbers rather than trusting the predicate alone: the
        // portrait tile's lockup extent clears the floor by (well) more than a rounding slop.
        XCTAssertGreaterThan(portraitFolderLockupExtent, Theme.Spacing.lg + landscapeFloor + 0.5)
    }

    private func planHeight(for label: String) -> CGFloat {
        if label.hasPrefix("Small") { return Self.small }
        // FEAT-39: "Medium+" must be checked before the "Medium" prefix it itself starts with.
        if label.hasPrefix("Medium+") { return Self.mediumPlus }
        if label.hasPrefix("Medium") { return Self.medium }
        return Self.large
    }
}

/// rc2 (2026-09-06) — `PinnedRowGeometry.HeroSlotGive`, the split of one `compression` across the
/// pinned hero's two elastic slots. Extracted out of `HomeHeroForeground` so this arithmetic is
/// asserted rather than reasoned about; the view's `synopsisSlotGive` / `logoSlotGive` are thin
/// wrappers over it.
///
/// The tester's objection was about LINES OF DESCRIPTION, and the line count is a floor division.
///
/// 2026-09-10: `HomeHeroForeground.synopsisLineLimit` no longer assumes a 36pt line — it measures
/// the actual `UIFont` line height of the resolved face/size, with a 1pt tolerance so a slot that is
/// short of a whole line by less than that still gets it (the text `Text` sits in a fixed-height
/// frame, so a small overhang is clipped, never seen). The helper below mirrors that exactly. So
/// the tests assert the slot height AND the line count it implies — the second is the thing the
/// tester actually sees.
///
/// rc14 (Steven rc13 verdict, 2026-09-30): the split spends in a NEW order — the frame's free slack
/// (`heroPinnedFrameSlack`, 22), then the logo (34, down to its 76 floor), then the synopsis (36
/// carousel / 104 panel, down to one 36pt line) — and Home's synopsis is set in
/// `Theme.Font.synopsis` (caption1: ≈30pt a line on the system face, ≈34 in Open Sans), so every
/// line count below is measured against that synopsis line, not the body line the pre-rc14 tests
/// used. The panel's synopsis slot is 140 (was 144), so a panel that gives nothing holds four lines.
final class PinnedRowGeometryHeroSlotGiveTests: XCTestCase {

    private let epsilon: CGFloat = 0.001

    // MARK: - Synopsis line metrics (Codex P3 fix 4, rc14)
    //
    // `lineLimit(slotHeight:)` used to read the live `Theme.Font.bodyLineHeight`, which follows
    // whatever font family the host has applied (System by default, Open Sans under FEAT-31's
    // `-ui_font openSans` launch argument, persisted across runs). A suite that asserts a fixed
    // line count has to pin the metric it measures against, exactly like `systemTitle`/
    // `openSansTitle` above pin the title metric — so every caller below passes an EXPLICIT
    // `lineHeight` instead of letting the helper read the live value.

    /// System synopsis line height (`UIFont.preferredFont(forTextStyle: .caption1).lineHeight`, the
    /// text style `Theme.Font.synopsis` resolves to, ≈30pt) — the metric
    /// `HomeHeroForeground.synopsisLineLimit` measures when the host renders the System font, and
    /// the one every line count in this file is arithmetic against.
    private static let systemSynopsisLine = UIFont.preferredFont(forTextStyle: .caption1).lineHeight

    /// FEAT-31's Open Sans synopsis line height at the same text style, from the bundled face
    /// itself rather than a derived constant. beta.18 verdict (FEAT-31): measured at the shipping
    /// `openSansPointSize` (25 × 0.92 = 23 pt ⇒ ≈31.32pt; was ≈34.05 unscaled), so it tracks what
    /// `Theme.Font.synopsisLineHeight` reports.
    private static func openSansSynopsisLine() -> CGFloat? {
        UIFont(name: "OpenSans-Regular", size: Theme.Font.openSansPointSize(for: .caption1))?.lineHeight
    }

    /// FEAT-31's Open Sans BODY line height — kept for the historical measurement test below (the
    /// synopsis no longer uses `body`, but the 108pt-slot / 36pt-line assumption it disproved is
    /// still worth pinning).
    /// beta.18 verdict (FEAT-31): shipping scaled size, 29 × 0.92 = 26.68 pt ⇒ ≈36.33pt (was ≈39.49).
    private static func openSansBodyLine() -> CGFloat? {
        UIFont(name: "OpenSans-Regular", size: Theme.Font.openSansPointSize(for: .body))?.lineHeight
    }

    /// Mirror of `HomeHeroForeground.synopsisSlotHeight`'s compact branch.
    private func slotHeight(showsCTA: Bool, synopsisGive: CGFloat) -> CGFloat {
        let slot = showsCTA ? Theme.Size.heroSynopsisSlotHeightPinned
                            : Theme.Size.heroSynopsisSlotHeightPinnedPanel
        return slot - synopsisGive
    }

    /// Mirror of `HomeHeroForeground.synopsisLineLimit`'s compact branch — measured, not assumed.
    /// `lineHeight` is an explicit parameter, not a live read, so a caller controls which font
    /// metric its expectation is arithmetic against (Codex P3 fix 4).
    private func lineLimit(slotHeight: CGFloat, lineHeight: CGFloat) -> Int {
        let lineTolerance: CGFloat = 1
        guard lineHeight > 0 else { return 1 }
        return max(1, Int(((slotHeight + lineTolerance) / lineHeight).rounded(.down)))
    }

    /// rc14: the guard behind every "N lines" assertion below. The expectations are arithmetic
    /// against a ≈30pt system caption1 line (a 59.67pt slot only holds two lines while the line is
    /// ≤ 30.33pt, a 127.67pt one four while it is ≤ 32.17), so a font or text-style change that moves
    /// the metric out of this range has to fail HERE, loudly, rather than flip line counts silently.
    func testTheSystemSynopsisLineIsWithinTheAssumedRange() {
        XCTAssertGreaterThan(Self.systemSynopsisLine, 26)
        XCTAssertLessThan(Self.systemSynopsisLine, 33)
    }

    // MARK: - rc12: fixtures for the moved reach-hold synopsis tests below (private in
    // `PinnedRowGeometryTests`, so restated here rather than reached across the type boundary).

    private static func posterHeight(dp: CGFloat) -> CGFloat {
        dp * (Theme.Size.posterWidth / 126.0) * 1.5
    }
    /// FEAT-39: 134dp, above the 335pt hero-compression gate, so it takes the Large dial.
    private static let mediumPlus = posterHeight(dp: 134) // 350.95…
    private static let large = posterHeight(dp: 154)    // 403.33…

    private static let noZoom = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false)
    private static let zoomOn = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false)
    /// rc12 BUG-87 follow-up: No Zoom with the default-OFF reach-hold A/B switched ON.
    private static let noZoomHolding = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false,
                                                                     reachHoldsLift: true)
    /// 2026-09-30 zoom-on reach hold — the shipping default, and the regime Steven's Large and
    /// Medium+ carousels run in (see `PinnedRowZoomReachHoldTests` below).
    private static let zoomOnHeld = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false,
                                                                  zoomReachHold: true)

    /// The SYSTEM font's number, which every expectation in this file was written against.
    private static let systemTitle = PinnedRowGeometry.measuredTitleHeight   // 38

    // MARK: - rc12: the No Zoom reach-hold A/B synopsis cost (BUG-87 follow-up)

    /// What turning the hold on costs the Large hero-off panel's synopsis. Pre-rc14 it cost a line
    /// (3 → 2, the same cost zoom-on paid); rc14 spends the frame's free slack and the logo BEFORE
    /// the description, and both regimes' compressions sit inside that 22 + 34 = 56 — so the
    /// synopsis gives nothing in either, keeps its whole 140 slot, and the hold costs it no line.
    ///
    /// The 26–33 guard (`testTheSystemSynopsisLineIsWithinTheAssumedRange`) pins the System
    /// synopsis metric's plausible range so a future font change fails loudly instead of silently
    /// flipping which side of a line boundary this shape lands on.
    ///
    /// 2026-09-30: the rest target (`heroPinnedRowsRestTarget`) removed the old cost, and the panel's
    /// own 493 budget lowers it further: demand 88 + 403.333 + 44 + 4 − 493 = 46.333, − 20 − 2 =
    /// 24.333 — 22 free slack plus 2.33 of logo. The OFF twin is 32.333 (70.333 − 38): 22 free plus
    /// 10.33 of logo.
    func testNoZoomReachHoldKeepsTheHeroOffPanelFourSynopsisLines() {
        XCTAssertGreaterThan(Self.systemSynopsisLine, 26)
        XCTAssertLessThan(Self.systemSynopsisLine, 33)

        let holding = PinnedRowGeometry.plan(posterHeight: Self.large,
                                             captionVisible: false,
                                             showsCTA: false,
                                             landscapeRows: false,
                                             mode: Self.noZoomHolding,
                                             titleHeight: Self.systemTitle)
        XCTAssertEqual(holding.compression, 24.333, accuracy: 0.01)
        let holdingSplit = PinnedRowGeometry.HeroSlotGive.split(compression: holding.compression,
                                                                showsCTA: false, folderHero: false)
        XCTAssertEqual(holdingSplit.synopsis, 0, accuracy: epsilon)
        XCTAssertEqual(holdingSplit.logo, 2.333, accuracy: 0.01)
        let holdingSlot = slotHeight(showsCTA: false, synopsisGive: holdingSplit.synopsis)
        XCTAssertEqual(holdingSlot, 140, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: holdingSlot, lineHeight: Self.systemSynopsisLine), 4)

        let off = PinnedRowGeometry.plan(posterHeight: Self.large,
                                         captionVisible: false,
                                         showsCTA: false,
                                         landscapeRows: false,
                                         mode: Self.noZoom,
                                         titleHeight: Self.systemTitle)
        XCTAssertEqual(off.compression, 32.333, accuracy: 0.01)
        let offSplit = PinnedRowGeometry.HeroSlotGive.split(compression: off.compression,
                                                            showsCTA: false, folderHero: false)
        XCTAssertEqual(offSplit.synopsis, 0, accuracy: epsilon)
        XCTAssertEqual(offSplit.logo, 10.333, accuracy: 0.01)
        let offSlot = slotHeight(showsCTA: false, synopsisGive: offSplit.synopsis)
        XCTAssertEqual(offSlot, 140, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: offSlot, lineHeight: Self.systemSynopsisLine), 4)
    }

    /// Medium+ is unaffected by the hold: it already takes the Large dial's floor with zoom on
    /// (`testMediumPlusTakesTheLargeDialWithFourSystemLines`), and the hold converges No Zoom to
    /// EXACTLY that same floor/compression — not merely to the same line count. The panel's synopsis
    /// keeps its whole slot (compression 0), so there is nothing new to cost here.
    func testMediumPlusKeepsFourSynopsisLinesWithTheReachHold() {
        let holding = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                             showsCTA: false, landscapeRows: false,
                                             mode: Self.noZoomHolding, titleHeight: 38)
        // 2026-09-30 rest target + panel budget 493: demand 88 + 350.952 + 44 + 4 − 493 = −6.048,
        // so nothing is spent: both reaches stay at 88/44 (the h1 floor 86 is below 88, so the
        // hold never raises anything), compression 0, viewport 493, link 482.952, restRange 10.048.
        XCTAssertEqual(holding.topReach, 88, accuracy: epsilon)
        XCTAssertEqual(holding.bottomReach, 44, accuracy: epsilon)
        XCTAssertEqual(holding.compression, 0, accuracy: 0.01)
        XCTAssertEqual(holding.restRange, 10.048, accuracy: 0.01)

        let zoomOn = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                            showsCTA: false, landscapeRows: false,
                                            mode: Self.zoomOn, titleHeight: 38)
        XCTAssertEqual(holding.regimeKey,
                       zoomOn.regimeKey.replacingOccurrences(of: "z0", with: "z1") + "h1rt4")

        // rc14: slot 140 (nothing given): four lines on any synopsis line under 35.25pt
        // (`lineLimit` has no cap, so the exact count follows the host's metric — the guard test
        // above bounds it at 33, which leaves 4 up to 5).
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: holding.compression,
                                                         showsCTA: false, folderHero: false)
        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 140, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemSynopsisLine), 4)
    }

    // MARK: - The three steps (rc14 order: free slack, logo, synopsis)

    /// The whole point of the rc14 change, at the tester's Large shape.
    ///
    ///     compression 68.33  (Wave 10's own Large number — the held Large carousel's plan)
    ///     free      min(68.33, heroPinnedFrameSlack 22)                  = 22
    ///     logo      min(46.33, heroLogoSlotPinnedGive 34)                = 34
    ///     synopsis  min(12.33, panel synopsis give 104)                  = 12.33
    ///     ⇒ synopsis slot 140 − 12.33 = 127.67   ⇒ floor(128.67 / ≈30) = 4 lines
    ///
    /// Pre-rc14 the synopsis was spent FIRST (36 of it) and the slot was 108 ⇒ 3 body lines; spending
    /// the free slack and the logo first leaves the description four lines of the smaller synopsis
    /// face.
    func testPanelAtStevensCompressionKeepsFourSynopsisLines() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 68.333,
                                                         showsCTA: false,
                                                         folderHero: false)
        XCTAssertEqual(split.logo, Theme.Size.heroLogoSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.logo, 34, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 12.333, accuracy: 0.01)

        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 127.667, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemSynopsisLine), 4)

        // The logo slot lands exactly on its floor (76; it was 78 before rc14).
        XCTAssertEqual(Theme.Size.heroLogoSlotHeightPinned - split.logo,
                       Theme.Size.heroLogoSlotHeightPinnedFloor, accuracy: epsilon)
    }

    /// FEAT-39: Medium+'s own compression at the tester's zoom-on carousel shape
    /// (`PinnedRowGeometryTests.testMediumPlusTakesTheLargeDialWithFourSystemLines` is its panel
    /// twin, which spends nothing; the unheld carousel's 37.952 is the number used here, and the
    /// spec's hand-rounded "38" lands in the SAME step). 37.952 sits inside free slack 22 plus the
    /// logo's 34, so the synopsis gives NOTHING: the slot stays the full 140pt ⇒ four lines under
    /// the System synopsis face and four under Open Sans (141 / ≈34).
    func testMediumPlusPanelKeepsFourSynopsisLines() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 37.952,
                                                         showsCTA: false,
                                                         folderHero: false)
        XCTAssertEqual(split.logo, 15.952, accuracy: 0.01)
        XCTAssertEqual(split.synopsis, 0, accuracy: epsilon)

        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 140, accuracy: epsilon)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemSynopsisLine), 4)
        if let openSansLine = Self.openSansSynopsisLine() {
            XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: openSansLine), 4)
        }
    }

    /// rc10's No-Zoom Large panel compression (70.33, the lift-aware floor). Under the rc14 order:
    ///
    ///     free 22, logo min(48.33, 34) = 34, synopsis 14.33 ⇒ slot 140 − 14.33 = 125.67
    ///     ⇒ floor(126.67 / ≈30) = 4 lines under the system synopsis face
    ///
    /// (Pre-rc14 the tier-3 gate turned this into a 107.67pt slot and three body lines.)
    func testPanelAtRc10NoZoomCompressionHasFourLinesUnderTheSystemSynopsisFont() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 70.333, showsCTA: false, folderHero: false)
        XCTAssertEqual(split.logo, 34, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 14.333, accuracy: 0.01)
        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 125.667, accuracy: 0.01)
        // The synopsis measurement, not a literal: the guard test pins its plausible range.
        XCTAssertLessThan(Self.systemSynopsisLine, 33)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemSynopsisLine), 4)
    }

    /// The tester's case, historically: Open Sans body rendered taller than the 36 pt the slot math
    /// assumed (≈39.49 unscaled), so the 108 pt slot held two lines, not three. beta.18 verdict
    /// (FEAT-31): with the 0.92 scale the line is ≈36.33, (108 + 1) / 36.33 = 3.0001 ⇒ THREE lines
    /// again — the measurement, not a fix, and a knife-edge one (the 1 pt tolerance is what keeps
    /// it at 3). (Historical: Home's synopsis no longer uses `body`; see the synopsis variant below.)
    func testOpenSansBodyLineIsTallerThanTheAssumedSlotLine() throws {
        guard let openSansLine = Self.openSansBodyLine() else {
            throw XCTSkip("Open Sans is not bundled in the unit-test host")
        }
        XCTAssertGreaterThan(openSansLine, 36)
        XCTAssertEqual(lineLimit(slotHeight: 108, lineHeight: openSansLine), 3)
    }

    /// rc14: the same measurement for the face Home's synopsis is actually set in
    /// (`Theme.Font.synopsis`, caption1). Open Sans's caption1 line is ≈31.32pt (scaled, beta.18
    /// verdict) against the system's ≈30, so the carousel's full 72pt slot (nothing given) still
    /// holds TWO lines in either face: (72 + 1) / 31.32 = 2.33.
    func testOpenSansSynopsisLineIsTallerThanTheSystemLine() throws {
        guard let openSansLine = Self.openSansSynopsisLine() else {
            throw XCTSkip("Open Sans is not bundled in the unit-test host")
        }
        XCTAssertGreaterThan(openSansLine, 30)
        XCTAssertGreaterThan(openSansLine, Self.systemSynopsisLine)
        XCTAssertEqual(lineLimit(slotHeight: 72, lineHeight: openSansLine), 2)
    }

    /// The synopsis starts to give only past the frame's free slack AND the logo's whole 34 — and
    /// then it is the panel's own extra on top of the carousel's 36.
    ///
    ///     compression 111.83
    ///     free 22, logo min(89.83, 34) = 34, synopsis min(55.83, 104) = 55.83
    ///     ⇒ synopsis give 55.83, slot 140 − 55.83 = 84.17  ⇒ floor(85.17 / ≈30) = 2 lines
    ///
    /// (Pre-rc14 this was "the third tier": 77.83 of synopsis give, a 66.17pt slot, one body line.
    /// There is no third tier any more — the three steps are the slack, the logo, the synopsis.)
    func testPanelPastTheLogoFloorSpendsTheSynopsis() {
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: 111.833,
                                                         showsCTA: false,
                                                         folderHero: false)
        XCTAssertEqual(split.logo, Theme.Size.heroLogoSlotPinnedGive, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 55.833, accuracy: 0.01)
        let slot = slotHeight(showsCTA: false, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 84.167, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemSynopsisLine), 2)
    }

    /// The frame's free slack comes first, in BOTH forms: a compression of 20 is entirely slack, so
    /// neither elastic slot gives anything. Past it the logo takes the next 34, and only then does
    /// the synopsis start to give.
    ///
    ///     c = 20   free 20                      ⇒ logo 0,  synopsis 0
    ///     c = 40   free 22, rest 18             ⇒ logo 18, synopsis 0
    ///     c = 60   free 22, rest 38, logo 34    ⇒ logo 34, synopsis 4
    func testSmallCompressionsAreAbsorbedByTheFrameSlack() {
        for showsCTA in [false, true] {
            let label = "showsCTA=\(showsCTA)"
            let slack = PinnedRowGeometry.HeroSlotGive.split(compression: 20,
                                                             showsCTA: showsCTA,
                                                             folderHero: false)
            XCTAssertEqual(slack.synopsis, 0, accuracy: epsilon, label)
            XCTAssertEqual(slack.logo, 0, accuracy: epsilon, label)

            let logoOnly = PinnedRowGeometry.HeroSlotGive.split(compression: 40,
                                                                showsCTA: showsCTA,
                                                                folderHero: false)
            XCTAssertEqual(logoOnly.logo, 18, accuracy: epsilon, label)
            XCTAssertEqual(logoOnly.synopsis, 0, accuracy: epsilon, label)

            let both = PinnedRowGeometry.HeroSlotGive.split(compression: 60,
                                                            showsCTA: showsCTA,
                                                            folderHero: false)
            XCTAssertEqual(both.logo, 34, accuracy: epsilon, label)
            XCTAssertEqual(both.synopsis, 4, accuracy: epsilon, label)
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

    // MARK: - rc14: the carousel's own line counts

    /// The Large carousel's HELD plan (the shipping default: zoom on, reach hold on) compresses by
    /// 68.33. rc14's order spends the 22 of free slack and the whole 34 of logo before the synopsis,
    /// which is left with 12.33 of give:
    ///
    ///     free 22, logo 34, synopsis 12.33 ⇒ slot 72 − 12.33 = 59.67 ⇒ floor(60.67 / ≈30) = 2 lines
    ///
    /// The logo slot ends at its 76 floor. At the old 78 floor the synopsis gave 14.33, the slot was
    /// 57.67 and the count rounded down to ONE line — Steven's "I still only get one line of
    /// description for movies on Home". This is borderline BY DESIGN (the 1pt tolerance is what
    /// carries it): it holds while the system synopsis line is ≤ 30.33pt, which is why the guard
    /// test pins that metric's range.
    func testLargeCarouselHeldGivesTwoSynopsisLines() {
        let held = PinnedRowGeometry.plan(posterHeight: Self.large, captionVisible: false,
                                          showsCTA: true, landscapeRows: false,
                                          mode: Self.zoomOnHeld, titleHeight: Self.systemTitle)
        XCTAssertEqual(held.compression, 68.333, accuracy: 0.01)

        let split = PinnedRowGeometry.HeroSlotGive.split(compression: held.compression,
                                                         showsCTA: true,
                                                         folderHero: false)
        XCTAssertEqual(split.logo, 34, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 12.333, accuracy: 0.01)
        XCTAssertEqual(Theme.Size.heroLogoSlotHeightPinned - split.logo,
                       Theme.Size.heroLogoSlotHeightPinnedFloor, accuracy: epsilon)
        let slot = slotHeight(showsCTA: true, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 59.667, accuracy: 0.01)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemSynopsisLine), 2)
    }

    /// Medium+ carousel (held): compression 15.95 is inside the frame's 22 of free slack, so
    /// NOTHING in the hero gives — the logo keeps its full 110pt slot and the synopsis its full
    /// 72pt slot, which holds two lines in either face (73 / ≈30 and 73 / ≈34). Pre-rc14 the same
    /// compression took 15.95 straight out of the synopsis (a 56.05pt slot, one line) while the logo
    /// stayed full.
    func testMediumPlusCarouselKeepsTheFullLogoAndTwoLines() {
        let held = PinnedRowGeometry.plan(posterHeight: Self.mediumPlus, captionVisible: false,
                                          showsCTA: true, landscapeRows: false,
                                          mode: Self.zoomOnHeld, titleHeight: Self.systemTitle)
        XCTAssertEqual(held.compression, 15.952, accuracy: 0.01)

        let split = PinnedRowGeometry.HeroSlotGive.split(compression: held.compression,
                                                         showsCTA: true,
                                                         folderHero: false)
        XCTAssertEqual(split.logo, 0, accuracy: epsilon)
        XCTAssertEqual(split.synopsis, 0, accuracy: epsilon)
        XCTAssertEqual(Theme.Size.heroLogoSlotHeightPinned - split.logo,
                       Theme.Size.heroLogoSlotHeightPinned, accuracy: epsilon)
        let slot = slotHeight(showsCTA: true, synopsisGive: split.synopsis)
        XCTAssertEqual(slot, 72, accuracy: epsilon)
        XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: Self.systemSynopsisLine), 2)
        if let openSansLine = Self.openSansSynopsisLine() {
            XCTAssertEqual(lineLimit(slotHeight: slot, lineHeight: openSansLine), 2)
        }
    }

    // MARK: - What must not have changed

    /// The CAROUSEL split follows the rc14 order at every compression it can be handed — the free
    /// slack, then the logo, then the synopsis — and never gives more than its 70 of content (the
    /// 92 cap minus the 22 that is slack), so nothing hard-clips past the cap. The sweep runs to
    /// `elasticGive + 0.5` to cover the clamp; a handful of literal anchors pin the formula down
    /// independently of the inlined one.
    func testCarouselSplitFollowsTheRc14Order() {
        var c: CGFloat = 0
        while c <= PinnedRowGeometry.elasticGive(showsCTA: true) + 0.5 {
            let split = PinnedRowGeometry.HeroSlotGive.split(compression: c,
                                                             showsCTA: true,
                                                             folderHero: false)
            // The rc14 formula, inlined.
            let free = min(c, Theme.Size.heroPinnedFrameSlack)
            let rest = max(c - free, 0)
            let expectedLogo = min(rest, Theme.Size.heroLogoSlotPinnedGive)
            let expectedSynopsis = min(max(rest - expectedLogo, 0),
                                       Theme.Size.heroSynopsisSlotHeightPinned
                                           - Theme.Size.heroSynopsisSlotHeightPinnedFloor)
            XCTAssertEqual(split.synopsis, expectedSynopsis, accuracy: epsilon, "compression=\(c)")
            XCTAssertEqual(split.logo, expectedLogo, accuracy: epsilon, "compression=\(c)")
            // Content never gives more than the cap minus the frame's slack.
            XCTAssertLessThanOrEqual(split.total, 70 + epsilon, "compression=\(c)")
            c += 0.25
        }

        // Literal anchors (22 free · 34 logo · 36 synopsis).
        let anchors: [(c: CGFloat, logo: CGFloat, synopsis: CGFloat)] = [
            (0, 0, 0), (15.952, 0, 0), (22, 0, 0), (40, 18, 0), (56, 34, 0),
            (56.5, 34, 0.5), (68.333, 34, 12.333), (92, 34, 36),
        ]
        for (c, logo, synopsis) in anchors {
            let split = PinnedRowGeometry.HeroSlotGive.split(compression: c, showsCTA: true, folderHero: false)
            XCTAssertEqual(split.logo, logo, accuracy: 0.01, "compression=\(c)")
            XCTAssertEqual(split.synopsis, synopsis, accuracy: 0.01, "compression=\(c)")
        }
    }

    /// FEAT-29's collection-folder rule is untouched: the whole synopsis slot is give (a folder
    /// preview carries no description, so the slot has a genuine 0 floor) and the logo takes an
    /// unbounded remainder. At Large + panel that is synopsis 68.33, logo 0 — the wordmark keeps
    /// its full 110pt slot, which is the regression FEAT-29 closed. (The sweep runs to the form's
    /// `elasticGive`, which rc14 grew to 92 / 160.)
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
    /// `split.total`, and the frame carries `heroPinnedFrameSlack` (22 since rc14's chrome shave;
    /// 2 before) that holds no content — so the content must give up at least `compression −
    /// slack` everywhere up to that form's cap, or the slots overflow into the rows below. This is
    /// the property `Theme.Size.heroPinnedCompressionCap` exists to protect. Under the rc14 order
    /// the free slack is spent first, so a title hero's total is exactly `max(c − slack, 0)` up to
    /// the cap; a folder hero gives all of `c`.
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
    /// goes below `heroLogoSlotHeightPinnedFloor` (76 since rc14; 78 before) and the synopsis never
    /// below `heroSynopsisSlotHeightPinnedFloor` (36), which is one readable line.
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

// MARK: - 2026-09-30: the zoom-on reach hold (`zoom-on-title-fix-plan.md`, option A)

/// The zoom-on twin of the rc12 No Zoom reach hold. Device walks on 2026-09-30 rested every middle
/// row at margin −12 with top reach 86 in BOTH zoom modes; with zoom on the band is [−4, 48], so the
/// lifted poster sat 8pt inside the title and the belt faded it. The hold raises the zoom-on floor
/// by `heroPinnedRowZoomReachHold` (6) to 92, capped at `heroPinnedRowTopReachHoldCap` (92).
///
/// Arithmetic (Large 403.333, Hide Titles, system title 38, demand = artwork − 291 = 112.333):
///
///     carousel unheld  top 88→86 (−2) ⇒ 90.333; hero 90.333 (rc14: the 92 cap no longer binds —
///                      it was 70 before, with link 513.333, restRange 11.667); viewport 545.333,
///                      link 513.333, restRange 32
///
/// Plus the 2026-09-30 rest target: a HELD regime's demand reserves `heroPinnedRowsRestTarget` (4)
/// in place of `Spacing.lg + settledCushion` (32), i.e. demand = artwork − 319 at Hide Titles:
///
///     Large carousel held  84.333 ⇒ −20 ⇒ 64.333 ⇒ +4 ⇒ 68.333 (under the 92 cap)
///                          viewport 523.333, link 92 + 403.333 + 24 = 519.333, restRange 4
///     Large panel held     30.333 on the panel's 493 budget ⇒ free slack 22, logo 8.333, no
///                          synopsis give, slot 140, 4 lines (rc14)
///     Medium+ carousel     31.952 ⇒ 11.952 ⇒ 15.952; viewport 470.952, link 466.952, restRange 4
final class PinnedRowZoomReachHoldTests: XCTestCase {

    private let epsilon: CGFloat = 0.001

    private static func posterHeight(dp: CGFloat) -> CGFloat {
        dp * (Theme.Size.posterWidth / 126.0) * 1.5
    }
    private static let mediumPlus = posterHeight(dp: 134) // 350.952…
    private static let large = posterHeight(dp: 154)      // 403.333…

    private static let zoomOn = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false)
    private static let zoomOnHeld = PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false,
                                                                  zoomReachHold: true)
    /// No Zoom with BOTH holds switched on, as the app resolves them by default today.
    private static let noZoomBothHolds = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false,
                                                                       reachHoldsLift: true,
                                                                       zoomReachHold: true)
    private static let noZoomH1 = PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false,
                                                                reachHoldsLift: true)

    private static let systemTitle = PinnedRowGeometry.measuredTitleHeight   // 38
    private static let openSansTitle: CGFloat = 42.2
    /// rc14: the synopsis's text style (`Theme.Font.synopsis`, caption1), ≈30pt — replaces the body
    /// line the line-count assertion in this class used before Home's synopsis moved off `body`.
    private static let systemSynopsisLine = UIFont.preferredFont(forTextStyle: .caption1).lineHeight

    private func plan(_ height: CGFloat, cta: Bool, mode: PinnedRowTitle.FocusModeFlags,
                      title: CGFloat = PinnedRowGeometry.measuredTitleHeight) -> PinnedRowGeometry.Plan {
        PinnedRowGeometry.plan(posterHeight: height, captionVisible: false, showsCTA: cta,
                               landscapeRows: false, mode: mode, titleHeight: title)
    }

    func testTheConstantsMatchThePlan() {
        XCTAssertEqual(Theme.Size.heroPinnedRowZoomReachHold, 6)
        XCTAssertEqual(Theme.Size.heroPinnedRowTopReachHoldCap, 92)
    }

    func testEffectiveOnlyWithZoomOn() {
        XCTAssertTrue(Self.zoomOnHeld.zoomReachHoldEffective)
        XCTAssertFalse(Self.zoomOn.zoomReachHoldEffective)
        XCTAssertFalse(Self.noZoomBothHolds.zoomReachHoldEffective)
    }

    func testLargeCarouselZoomOnWithTheHoldReaches92() {
        let held = plan(Self.large, cta: true, mode: Self.zoomOnHeld)
        XCTAssertTrue(held.fits)
        XCTAssertEqual(held.topReach, 92, accuracy: epsilon)
        XCTAssertEqual(held.bottomReach, 24, accuracy: epsilon)
        XCTAssertEqual(held.compression, 68.333, accuracy: 0.01)
        XCTAssertEqual(held.viewport, 523.333, accuracy: 0.01)
        XCTAssertEqual(held.linkFrame, 519.333, accuracy: 0.01)
        XCTAssertEqual(held.restRange, 4, accuracy: 0.01)
        XCTAssertEqual(held.regimeKey, "L403c0p0r0z0t38hzrt4")
    }

    /// Hold off keeps the pre-hold reach floors (top 86, link frame 513.333). rc14 (Steven rc13
    /// verdict, 2026-09-30): the carousel's give grew 70 → 92, so the 90.33 leftover this regime
    /// demands is no longer clipped to 70 — compression 90.333 (was 70), viewport 545.333, and the
    /// restRange is the full construction, 32 (was 11.667 against the clipped viewport).
    func testHoldOffIsTodaysPlan() {
        let off = plan(Self.large, cta: true, mode: Self.zoomOn)
        XCTAssertTrue(off.fits)
        XCTAssertEqual(off.topReach, 86, accuracy: epsilon)
        XCTAssertEqual(off.compression, 90.333, accuracy: 0.01)
        XCTAssertLessThan(off.compression, PinnedRowGeometry.elasticGive(showsCTA: true))
        XCTAssertEqual(off.viewport, 545.333, accuracy: 0.01)
        XCTAssertEqual(off.linkFrame, 513.333, accuracy: 0.01)
        XCTAssertEqual(off.restRange, 32, accuracy: 0.01)
        XCTAssertEqual(off.regimeKey, "L403c0p0r0z0t38")
        // Explicit `zoomReachHold: false` is the memberwise default.
        XCTAssertEqual(off, plan(Self.large, cta: true,
                                 mode: PinnedRowTitle.FocusModeFlags(noZoom: false, accentRing: false,
                                                                     zoomReachHold: false)))
    }

    func testNoZoomH1IsUnchangedByTheZoomHold() {
        let both = plan(Self.large, cta: true, mode: Self.noZoomBothHolds)
        let h1 = plan(Self.large, cta: true, mode: Self.noZoomH1)
        XCTAssertEqual(both, h1)
        XCTAssertEqual(both.topReach, 86, accuracy: epsilon)
        // h1 is a held regime too, so it takes the rest target: 11.667 → 4 (compression 62.333).
        XCTAssertEqual(both.compression, 62.333, accuracy: 0.01)
        XCTAssertEqual(both.restRange, 4, accuracy: 0.01)
        XCTAssertEqual(both.regimeKey, "L403c0p0r0z1t38h1rt4")
    }

    /// beta.18 verdict (FEAT-31): the shipping (0.92-scaled) Open Sans title line, 38.84, puts the
    /// zoom-on floor at 48 + 38.84 − 24 + 20 + 4 = 86.84 — UNDER the 88 cap, uncapped.
    func testOpenSansScaledTitleClearsTheReachCapAtDefaultSize() {
        let floor = PinnedRowGeometry.topReachFloor(lift: 20, titleHeight: 38.84)
        XCTAssertEqual(floor, 86.84, accuracy: 0.001)
        XCTAssertLessThan(floor, Theme.Size.heroPinnedRowTopPad)
    }

    func testOpenSansIsCappedAt92() {
        XCTAssertEqual(PinnedRowGeometry.topReachFloor(lift: 20, titleHeight: Self.openSansTitle,
                                                       hold: Theme.Size.heroPinnedRowZoomReachHold,
                                                       cap: Theme.Size.heroPinnedRowTopReachHoldCap),
                       92, accuracy: epsilon)
        let held = plan(Self.large, cta: true, mode: Self.zoomOnHeld, title: Self.openSansTitle)
        XCTAssertTrue(held.fits)
        XCTAssertEqual(held.topReach, 92, accuracy: epsilon)
        XCTAssertEqual(held.compression, 68.333, accuracy: 0.01)
        // Unheld Open Sans still takes the 88 cap.
        XCTAssertEqual(plan(Self.large, cta: true, mode: Self.zoomOn, title: Self.openSansTitle).topReach,
                       88, accuracy: epsilon)
    }

    func testTheDefaultFloorArgumentsAreUnchanged() {
        XCTAssertEqual(PinnedRowGeometry.topReachFloor(lift: 20, titleHeight: Self.systemTitle), 86, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.topReachFloor(lift: 0, titleHeight: Self.systemTitle), 66, accuracy: epsilon)
        XCTAssertEqual(PinnedRowGeometry.topReachFloor(lift: 20, titleHeight: Self.openSansTitle), 88, accuracy: epsilon)
    }

    /// 2026-09-30 (walkhf): the panel's budget is 493, so demand = 88 + 403.333 + 44 + 4 − 493 =
    /// 46.333; − 20 bottom, + 4 top ⇒ 30.333; viewport 523.333, link 519.333, restRange 4.
    ///
    /// rc14 (Steven rc13 verdict, 2026-09-30): the 30.33 now sits entirely inside the frame's 22 of
    /// free slack plus 8.33 of logo — the synopsis gives nothing and keeps its whole 140 slot, four
    /// lines of `Theme.Font.synopsis` (it was 30.33 of synopsis give, a 113.67 slot, three body
    /// lines).
    func testLargePanelKeepsFourSynopsisLinesWithTheHold() {
        XCTAssertGreaterThan(Self.systemSynopsisLine, 26)
        XCTAssertLessThan(Self.systemSynopsisLine, 33)
        let held = plan(Self.large, cta: false, mode: Self.zoomOnHeld)
        XCTAssertTrue(held.fits)
        XCTAssertEqual(held.topReach, 92, accuracy: epsilon)
        XCTAssertEqual(held.compression, 30.333, accuracy: 0.01)
        XCTAssertEqual(held.viewport, 523.333, accuracy: 0.01)
        XCTAssertEqual(held.linkFrame, 519.333, accuracy: 0.01)
        XCTAssertEqual(held.restRange, 4, accuracy: 0.01)
        let split = PinnedRowGeometry.HeroSlotGive.split(compression: held.compression,
                                                         showsCTA: false, folderHero: false)
        // rc14: free slack 22 first, then 8.333 of logo; the synopsis gives nothing.
        XCTAssertEqual(split.logo, 8.333, accuracy: 0.01)
        XCTAssertEqual(split.synopsis, 0, accuracy: 0.01)
        let slot = Theme.Size.heroSynopsisSlotHeightPinnedPanel - split.synopsis
        XCTAssertEqual(slot, 140, accuracy: 0.01)
        // Mirror of `HomeHeroForeground.synopsisLineLimit` (1pt tolerance), as in the slot-give suite.
        let lines = max(1, Int(((slot + 1) / Self.systemSynopsisLine).rounded(.down)))
        XCTAssertEqual(lines, 4)
    }

    /// 2026-09-30 (walkhf): the panel (Show Hero OFF) has no page-dots row, so its rows viewport
    /// budget is 455 + Spacing.sm 12 + HeroPageDots.height 26 = 493.
    func testPanelBudgetIncludesTheMissingDotsRow() {
        XCTAssertEqual(HeroPageDots.height, 26, accuracy: epsilon)
        XCTAssertEqual(Theme.Size.heroPinnedRowsViewportBudget(showsCTA: true), 455, accuracy: epsilon)
        XCTAssertEqual(Theme.Size.heroPinnedRowsViewportBudget(showsCTA: false), 493, accuracy: epsilon)
    }

    /// Medium+ panel, held: demand 88 + 350.952 + 44 + 4 − 493 = −6.048, so `short` starts at 0.
    /// The bottom reach spends nothing (stays 44); the held floor 92 > 88 RAISES the top reach by
    /// 4 and that overshoot is the whole compression. viewport 497, link 92 + 350.952 + 44 =
    /// 486.952, restRange 10.048 — predicted rest −10.52 against bandLo −10 (in band through the
    /// corrector's ±2 membership slack).
    func testMediumPlusPanelHeldSpendsOnlyTheHoldOvershoot() {
        let held = plan(Self.mediumPlus, cta: false, mode: Self.zoomOnHeld)
        XCTAssertTrue(held.fits)
        XCTAssertEqual(held.topReach, 92, accuracy: epsilon)
        XCTAssertEqual(held.bottomReach, 44, accuracy: epsilon)
        XCTAssertEqual(held.compression, 4, accuracy: 0.01)
        XCTAssertEqual(held.viewport, 497, accuracy: 0.01)
        XCTAssertEqual(held.linkFrame, 486.952, accuracy: 0.01)
        XCTAssertEqual(held.restRange, 10.048, accuracy: 0.01)
        XCTAssertEqual(held.regimeKey, "P351c0p1r0z0t38hzrt4")
        let predicted = PinnedRowGeometry.predictedRestMargin(restRange: held.restRange)
        XCTAssertEqual(predicted, -10.524, accuracy: 0.01)
        let clearance = PinnedRowTitle.clearances(titleHeight: Self.systemTitle,
                                                  cardTopReach: held.topReach,
                                                  artworkHeight: Self.mediumPlus,
                                                  captionVisible: false,
                                                  treatment: .cardTreatment,
                                                  mode: Self.zoomOnHeld)
        XCTAssertEqual(-clearance.focused, -10, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(predicted, -clearance.focused - 2)
    }

    /// Carousel regimes do not move with the budget change (their budget is still 455).
    ///
    /// rc14: the third line is the unheld zoom-on Large carousel, whose compression is the leftover
    /// demand — zoom-on floor 86: 112.333 − 20 − 2 = 90.333 — and was clipped to the old 70 cap
    /// before the carousel's give grew to 92. The two held regimes were never near a cap.
    func testCarouselRegimesAreUnchangedByThePanelBudget() {
        XCTAssertEqual(plan(Self.large, cta: true, mode: Self.zoomOnHeld).compression, 68.333, accuracy: 0.01)
        XCTAssertEqual(plan(Self.mediumPlus, cta: true, mode: Self.zoomOnHeld).compression, 15.952, accuracy: 0.01)
        XCTAssertEqual(plan(Self.large, cta: true, mode: Self.zoomOn).compression, 90.333, accuracy: 0.01)
    }

    /// The 2026-09-30 Medium+ failure: with only the reach hold the plan paid the full 32 of slack
    /// (restRange 31, device rests −21/−22, outside [−10, 48]). With the rest target: restRange 4.
    func testMediumPlusCarouselTakesTheRestTarget() {
        let held = plan(Self.mediumPlus, cta: true, mode: Self.zoomOnHeld)
        XCTAssertTrue(held.fits)
        XCTAssertEqual(held.topReach, 92, accuracy: epsilon)
        XCTAssertEqual(held.bottomReach, 24, accuracy: epsilon)
        XCTAssertEqual(held.compression, 15.952, accuracy: 0.01)
        XCTAssertEqual(held.viewport, 470.952, accuracy: 0.01)
        XCTAssertEqual(held.linkFrame, 466.952, accuracy: 0.01)
        XCTAssertEqual(held.restRange, 4, accuracy: 0.01)
        XCTAssertEqual(held.regimeKey, "P351c0p0r0z0t38hzrt4")
        // `settlePlan`'s bandHigh for that row: min(48, 48 + vh − lockup − cushion), lockup =
        // Spacing.lg + topReach + artwork (no captions).
        let lockup = Theme.Spacing.lg + held.topReach + Self.mediumPlus
        let bandHigh = min(Theme.Size.heroPinnedRowTitleInset,
                           Theme.Size.heroPinnedRowTitleInset + held.viewport - lockup
                               - Theme.Size.heroPinnedRowsSettledCushion)
        XCTAssertEqual(bandHigh, 44, accuracy: 0.01)
        // Hold off: unchanged (37.952, restRange 32 by construction).
        let off = plan(Self.mediumPlus, cta: true, mode: Self.zoomOn)
        XCTAssertEqual(off.compression, 37.952, accuracy: 0.01)
        XCTAssertEqual(off.restRange, 32, accuracy: 0.01)
        XCTAssertEqual(off.regimeKey, "P351c0p0r0z0t38")
    }

    /// The fitted law against the four device-measured rests (2026-09-30): restRange → margin.
    func testThePredictedRestMatchesTheFourMeasuredRests() {
        let measured: [(restRange: CGFloat, rest: CGFloat)] = [
            (31.7, -22), (11.7, -12), (5.7, -8.5), (31, -21.5),
        ]
        for (range, rest) in measured {
            XCTAssertEqual(PinnedRowGeometry.predictedRestMargin(restRange: range), rest,
                           accuracy: 1.5, "restRange=\(range)")
        }
        // At the target the predicted rest is −7.5: inside the zoom-on held band [−10, 48].
        XCTAssertEqual(PinnedRowGeometry.predictedRestMargin(restRange: Theme.Size.heroPinnedRowsRestTarget),
                       -7.5, accuracy: epsilon)
    }

    func testTheRestTargetAppliesOnlyToHeldRegimes() {
        XCTAssertTrue(PinnedRowGeometry.restTargetApplies(mode: Self.zoomOnHeld))
        XCTAssertTrue(PinnedRowGeometry.restTargetApplies(mode: Self.noZoomH1))
        XCTAssertFalse(PinnedRowGeometry.restTargetApplies(mode: Self.zoomOn))
        XCTAssertFalse(PinnedRowGeometry.restTargetApplies(
            mode: PinnedRowTitle.FocusModeFlags(noZoom: true, accentRing: false)))
        XCTAssertEqual(Theme.Size.heroPinnedRowsRestTarget, 4)
    }

    func testTheHoldNeverTouchesSizesThatSpendNothing() {
        let medium = Theme.Size.posterHeight
        let held = plan(medium, cta: true, mode: Self.zoomOnHeld)
        let off = plan(medium, cta: true, mode: Self.zoomOn)
        XCTAssertEqual(held.topReach, off.topReach, accuracy: epsilon)
        XCTAssertEqual(held.compression, off.compression, accuracy: epsilon)
        XCTAssertEqual(held.regimeKey, off.regimeKey + "hzrt4")
    }

    func testResolveZoomReachHoldDefaultsOn() throws {
        let suite = "PinnedRowZoomReachHoldTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(PinnedRowTitle.resolveZoomReachHold(defaults))
        defaults.set(false, forKey: PinnedRowTitle.zoomReachHoldKey)
        XCTAssertFalse(PinnedRowTitle.resolveZoomReachHold(defaults))
        defaults.set("NO", forKey: PinnedRowTitle.zoomReachHoldKey)
        XCTAssertFalse(PinnedRowTitle.resolveZoomReachHold(defaults))
        defaults.set(true, forKey: PinnedRowTitle.zoomReachHoldKey)
        XCTAssertTrue(PinnedRowTitle.resolveZoomReachHold(defaults))
    }
}
