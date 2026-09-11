import Foundation
import CoreGraphics

/// BUG-87 (beta.18): structural fit for the PINNED rows layout.
///
/// One place that answers "how tall is the thing the focus engine reveals, and does it fit in the
/// viewport it has to rest inside" — and, when it does not, which of the three dials the layout
/// owns should be spent to make it fit.
///
/// ## The defect this closes
///
/// Every tvOS scroll is reveal-driven: the focus engine scrolls so that the focused card's LINK
/// FRAME is on screen. In pinned mode that frame is not the artwork — the reach bands live INSIDE
/// the `Button`/`NavigationLink` label (`BrowseComponents`, `CatalogRowView`'s `.padding(.top,
/// cardTopReach)` / `.padding(.bottom, cardBottomReach)`), so the revealed extent is
///
///     linkFrame = topReach + artwork + captionChrome + bottomReach
///
/// Wave 10's hero compression, however, was sized against a DIFFERENT quantity — `Spacing.lg +
/// topReach + artwork + cushion` — which charges neither the caption nor the downward reach. At
/// Poster Size = Large with Hide Labels ON that is a 535.3pt frame against a 523.3pt viewport: 12pt
/// over, and 55.5pt over with captions. An over-tall frame has TWO legal rests (the simulator
/// top-anchors it, hardware bottom-anchors it ~75pt deeper), the settle corrector chases whichever
/// one it did not get, and the tester sees row titles that "keep trying to move back" (BUG-87), a
/// title glitch during horizontal travel (BUG-88), and a second-to-last row that regresses after a
/// Medium → Large switch until the app is restarted (BUG-89).
///
/// Christian approved the structural fix: make the frame FIT, so the engine has exactly one rest
/// and the corrector has nothing to correct.
///
/// ## What gets spent, and in what order
///
/// Three dials, each a pure `min`. The REACHES are spent first, down to their floors, and the hero
/// compression takes only what is left:
///
///  1. **The downward reach** (`heroPinnedRowBottomReach` 44 → `bottomReachFloor` 24, 20pt of
///     give). It covers the mirror-direction rest error and has no content to protect below it, so
///     it is the cheapest dial in the file.
///  2. **The upward reach** (`heroPinnedRowTopPad` 88 → `topReachFloor(lift:)`, 22pt of give with
///     No Zoom on and 2pt with either zoom mode). It is never RAISED here, only lowered, and never
///     below the floor: `heroPinnedRowTitleInset` (48) + a measured title (~38) − `Spacing.lg` (24)
///     ≈ 62 holds the TITLE, and the floor adds the focus lift and the belt's `fadeIntrusionArm`
///     on top of it — see `topReachFloor(lift:)` and the rc10 note below.
///  3. **Hero compression**, for whatever demand the two reaches could not cover, bounded by what
///     the pinned hero's internals can actually yield
///     (`Theme.Size.heroPinnedCompressionCap(showsCTA:)`).
///
/// ### Why this order (rc2 tester feedback, 2026-09-06)
///
/// The first cut of this file spent compression FIRST, on the reasoning that the hero's elastic
/// slots cost nothing structural while the reaches are the app's most regression-prone dials. At
/// the tester's shape that produced a 112.33pt compression, and the FEAT-15 focus panel spends
/// compression out of its synopsis slot first: 144 − min(112.33, 108) = 36pt of slot (the last
/// 4.33 came out of the logo), one line of description where beta.17 showed three. He filmed it and objected — "one line is not enough". Christian's
/// decision: keep the three lines, spend the two reach cushions instead. Both cushions exist to
/// absorb REST ERROR, and the whole point of this file is that a frame which fits has exactly one
/// rest and therefore no error to absorb; the compression's cost, by contrast, is content the
/// viewer reads. Spending the reaches first drops the tester's compression to 68.33 — Wave 10's own
/// Large number, the one beta.17 shipped and he never complained about — and the panel is back to
/// three lines.
///
/// ### The trade this order makes — rc4's open question, ANSWERED (rc10, BUG-87/89)
///
/// rc4 shipped a flat `topReachFloor` of 64 and this header said so plainly: it sat BELOW the
/// long-proven 72, it left the settled title a **2pt** static clearance rather than BUG-53's 26, and
/// with No Zoom OFF "there is [a lift], and nothing here proves the outcome". The tester's rc8 Row
/// Settle pane proved it, and the outcome was bad: at Large with zoom on, `staticClearance` 2 minus
/// the 20pt lift is **−18** — the focused card's artwork permanently 18pt over the settled title's
/// bottom — and `PinnedRowTitle.Clearances`' `max(…, 0)` reported it as a clean **0**. That single
/// clamp is why the defect read as a scroll problem for a whole release: `PinnedRowSettle`'s
/// `bandLow` became 0, which excluded the hardware's own bottom-anchored rest (≈ −31) by ~30pt, so
/// nearly every visit fired a correction (`UNEXPECTED-WITH-FIT`, nudges −12/−94/+27) that could only
/// swap one out-of-band rest for another; the belt, measuring intrusion against the same 0, faded
/// the titles it could not help (`clearanceLift=0` on every belt line of that pane).
///
/// Christian's decision: **take the clearance.** The floor is now derived and MODE-AWARE —
/// `topReachFloor(lift:)` = title floor 62 + the active lift + the belt's `fadeIntrusionArm` (4) —
/// which is 66 with No Zoom on and **86** with either zoom mode. 86 is back INSIDE the proven 72-88
/// corridor, so rc4's "is 64 safe?" question is retired rather than doubled, and the settled focused
/// title clears the artwork by 4pt (one arm width) in BOTH modes by construction instead of by luck.
///
/// The price is paid in hero compression: at Large + Hide Labels + panel it goes 68.33 → **90.33**
/// with zoom on (70.33 with No Zoom), which takes the panel's synopsis from 3 lines to 2 in both
/// modes. That cost is real and is documented at `topReachFloor(lift:)`; the dial to move if the
/// third line has to come back is `heroPinnedFrameSlack` or `HeroSlotGive`'s tier-3 gate, never this
/// floor. Two things the device pass still owns, both narrower than rc4's: that focus never
/// hesitates at reach 86/66 (both inside the corridor, so this is a sanity check), and that the hero
/// at the deeper compression still reads acceptably.
///
/// ## Unsatisfiable by design
///
/// Large + captions + carousel hero demands ~155.8pt against 44pt of reach give and an elastic give
/// of ~70 — 114 against 156. That case CANNOT be made to fit and is not pretended otherwise: the
/// plan reports `fits == false`, returns TODAY'S numbers verbatim (Wave 10's compression, reach
/// 88/44) so the belt regime is bit-identical to beta.17, and logs once per regime. A too-tall row
/// costs a hidden row title, never a broken hero — the same handoff contract `PinnedRowSettle` and
/// the visibility belt have always had.
///
/// ## Scope gate — Small and Medium are untouched
///
/// The plan spends NOTHING at a Poster Size whose row already fits Wave 10's own extent rule, i.e.
/// wherever `PinnedRowTitle.pinnedHeroCompression` computes 0 today: Small (395), Medium (450) and
/// landscape catalog rows (323), all under the 455 budget, at EVERY flag combination. That is a
/// deliberate scope decision, not an oversight — Medium is the default Poster Size with captions
/// ON, its device/sim band table records zero corrections, and keying its compression to the link
/// frame would silently compress the default configuration's hero by ~82pt to fix a rest nobody has
/// reported. The structural fix applies to the sizes that were ALREADY compressing, which is
/// exactly the population that reports the bug.
///
/// The gate reads through `PinnedRowTitle.pinnedHeroCompression`, so `-debug.pinnedHeroCompressionOff`
/// (test48's historical-geometry knob) keeps working unchanged: with the knob set the legacy
/// compression is 0 everywhere, the gate stays shut, and every plan returns the pre-Wave-10 reaches
/// and viewport.
enum PinnedRowGeometry {

    /// Everything the pinned rows layout needs to agree on for ONE (Poster Size × caption × hero
    /// form × row shape) regime. Every field is derived; nothing here is a literal.
    nonisolated struct Plan: Equatable, Sendable {
        /// How far the pinned hero yields to the rows below it (`HomeHeroForeground.compression`).
        var compression: CGFloat
        /// The upward reach each row card's focusable label carries (`\.rowCardTopReach`).
        var topReach: CGFloat
        /// The downward reach each row card's focusable label carries (`\.rowCardBottomReach`).
        var bottomReach: CGFloat
        /// The pinned rows viewport this plan produces: `budget + compression`.
        var viewport: CGFloat
        /// The extent the focus engine actually reveals for a focused card in this regime.
        var linkFrame: CGFloat
        /// Whether that extent fits inside the viewport — i.e. whether the engine has ONE rest.
        var fits: Bool
        /// How much room the viewport has left over once the link frame is inside it. This is the
        /// width of the set of legal rests: 0 means a single rest, and it is bounded above by
        /// `Spacing.lg + heroPinnedRowsSettledCushion` (32) whenever the full demand was spent.
        var restRange: CGFloat
        /// Short stable identity for this regime, e.g. `L403c0p1r0z1` — Large, no captions, panel
        /// hero, portrait rows, No Zoom on. Used as the `onChange` key that re-reveals the rows
        /// after a Poster Size switch (BUG-89) and as the log-once key below.
        var regimeKey: String
    }

    // MARK: - Floors

    /// Floor for the downward reach. It exists to absorb the mirror-direction rest error, and 24
    /// (`Theme.Spacing.lg`, the shelf's own bottom padding) is the point at which the focused
    /// card's caption still clears the fold without the reach's help.
    ///
    /// Spent FIRST as of the rc2 reordering, so every compressing Poster Size now runs at 24 rather
    /// than only the shapes that could not otherwise fit — see the header's trade note.
    nonisolated static let bottomReachFloor: CGFloat = Theme.Spacing.lg

    /// The band above the artwork must hold the TITLE *and* whatever the focus treatment raises the
    /// focused card's artwork by. If it does not, the settled title lands on the picture by
    /// `lift − staticClearance` at EVERY rest, and no scroll correction can undo it: a scroll moves
    /// title and artwork together, so only `slide` changes their relationship and at a clean rest
    /// `slide` is already 0.
    ///
    /// BUG-87/89 (rc4 → rc10): the flat 64 was derived against the title ALONE
    /// (`titleInset 48 + measuredTitleHeight 38 − Spacing.lg 24 = 62`, plus 2pt of margin) and
    /// treated the lift as somebody else's problem. With zoom on it is 20pt, so at Large — the one
    /// Poster Size that spends this dial — the focused card's artwork ended up 18pt ABOVE the
    /// settled title's bottom, and `PinnedRowTitle.Clearances`' `max(…, 0)` reported that as ZERO.
    /// Everything downstream then misread it: `PinnedRowSettle`'s `bandLow` became 0, excluding the
    /// hardware's own bottom-anchored rest by ~30pt (the tester's repeated `UNEXPECTED-WITH-FIT`
    /// nudges), and the belt measured intrusion against 0 and faded the titles it could not help
    /// (`clearanceLift=0` on every belt line of the rc4 pane).
    ///
    /// So the floor is DERIVED and MODE-AWARE. `lift` is `PinnedRowTitle.focusLiftAllowance`'s own
    /// number for the active Appearance settings — 20 in both zoom-on modes, 0 with No Zoom on — and
    /// `fadeIntrusionArm` (4) is the belt's own arm edge, so a settled focused title sits OUTSIDE
    /// the arm band by construction rather than one rounding error inside it:
    ///
    ///     No Zoom on   62 + 0  + 4 = 66   (22 of the reach's 24pt of give still spent)
    ///     zoom on      62 + 20 + 4 = 86   (2pt of give; the remaining 22 goes to compression)
    ///
    /// ### What this costs the panel's synopsis — read before re-tuning
    ///
    /// The design note for this change claimed the No-Zoom floor kept the rc2 reorder's 3-line
    /// synopsis intact. It does NOT, and the margin is absurd: at Large + Hide Labels + panel the
    /// compression goes 68.33 → 70.33, `HeroSlotGive` tiers 1+2 cover 68, `heroPinnedFrameSlack` is
    /// 2, and the 0.33 left over opens tier 3 — synopsis slot 144 − 36.33 = 107.67, and
    /// `floor(107.67 / 36)` is **2**. That is exactly the boundary
    /// `testPanelAtStevensCompressionKeepsThreeSynopsisLines` was written to guard, crossed by a
    /// third of a point. Zoom on spends 22 more and lands at 2 lines outright (slot 87.67). So both
    /// modes now show a 2-line description where rc4 showed 3. Christian's decision was to take the
    /// clearance knowing the hero pays for it; if the third line has to come back, the dial to move
    /// is `heroPinnedFrameSlack` or the tier-3 gate in `HeroSlotGive`, NOT this floor — lowering the
    /// floor again reinstates the permanent title-on-artwork overlap this whole change removes.
    ///
    /// Capped at `heroPinnedRowTopPad`: this dial only ever moves DOWN (reach 100 kills focus
    /// resolution outright). 86 also lands INSIDE the proven 72-88 corridor, so the rc4 header's
    /// unanswered hardware questions about reach 64 are retired rather than doubled.
    nonisolated static func topReachFloor(lift: CGFloat) -> CGFloat {
        let titleFloor = Theme.Size.heroPinnedRowTitleInset + measuredTitleHeight - Theme.Spacing.lg
        return min(Theme.Size.heroPinnedRowTopPad, titleFloor + lift + PinnedRowTitle.fadeIntrusionArm)
    }

    /// The measured height `topReachFloor` is derived against — `PinnedRowTitle`'s own record for a
    /// `Theme.Font.sectionTitle` line as rendered on the FA87 fixture.
    nonisolated static let measuredTitleHeight: CGFloat = 38

    // MARK: - Give

    /// Everything the pinned hero can yield in the form it is currently rendering.
    ///
    /// Carousel (`showsCTA == true`): logo 32 + synopsis 36 + frame slack 2 = 70, exactly Wave 10's
    /// `heroPinnedCompressionCap`. Focus panel (FEAT-15, `showsCTA == false`): the synopsis slot has
    /// already absorbed the CTA slot and the gap above it (144 against 72 — see
    /// `HomeHeroForeground.synopsisSlotHeight`), so its give against the same one-line floor is 108
    /// and the total is 142.
    nonisolated static func elasticGive(showsCTA: Bool) -> CGFloat {
        Theme.Size.heroPinnedCompressionCap(showsCTA: showsCTA)
    }

    // MARK: - How the hero spends it

    /// How a given `compression` is divided between the pinned hero's two elastic slots.
    ///
    /// Extracted out of `HomeHeroForeground` (whose `synopsisSlotGive` / `logoSlotGive` are now thin
    /// wrappers) purely so the arithmetic is unit-testable: it is a value function over three
    /// booleans-and-a-number with no view, no environment and no measurement in it.
    ///
    /// ## The three tiers (rc2, 2026-09-06)
    ///
    /// FEAT-15's focus panel folds the CTA slot into its synopsis slot — 144pt against the
    /// carousel's 72 (`Theme.Size.heroSynopsisSlotHeightPinnedPanel`) — and
    /// `HomeHeroForeground.synopsisLineLimit` is `floor(slotHeight / 36)`. Spending the panel's
    /// whole 108pt of synopsis give before touching the logo meant the tester's 68.33pt compression
    /// came entirely out of the description: slot 75.67 ⇒ **2 lines**, where beta.17's Wave 10 split
    /// (synopsis 36 + logo 32) left 108 ⇒ **3**. He objected to the one-line version at the old
    /// 112.33 compression, and 2 is still a regression against what he had.
    ///
    /// So the panel spends in three tiers, and the first two are exactly the carousel's:
    ///
    ///  1. `heroSynopsisSlotPinnedGive` (36) — the synopsis give BOTH forms have.
    ///  2. `heroLogoSlotPinnedGive` (32) — the logo, down to its 78pt floor.
    ///  3. Only then the extra the panel absorbed from the CTA (108 − 36 = 72), and only for the
    ///     part of the compression that exceeds tiers 1+2 by more than the hero frame's own
    ///     `heroPinnedFrameSlack` (2pt of frame that holds no content).
    ///
    /// That slack term is what makes the tester's shape land on 3 lines rather than 2: at 68.33 the
    /// first two tiers give 68 and the leftover 0.33 is frame slack, not content, so tier 3 stays
    /// shut and the synopsis slot is a clean 108. Without it, 0.33pt of tier-3 spend would take the
    /// slot to 107.67 and `floor(107.67 / 36)` is 2.
    ///
    /// ## Invariants
    ///
    ///  - **Nothing hard-clips**: `total >= compression - heroPinnedFrameSlack` for every
    ///    compression up to that form's `elasticGive`. Tier 3 is defined as the excess PAST the
    ///    slack, so in the region where it is open the total is exactly `compression - slack`.
    ///  - **Floors hold**: synopsis give ≤ `slot - heroSynopsisSlotHeightPinnedFloor`, logo give ≤
    ///    `heroLogoSlotPinnedGive`, for title heroes.
    ///  - **The carousel is bit-identical** to what shipped: its tier-3 ceiling is
    ///    `72 - 36 - 36 == 0`, so the function reduces to the old two-step `min`.
    ///  - **Folder heroes are bit-identical** to FEAT-29: `folderHero` keeps its own rule (the whole
    ///    synopsis slot has a genuine 0 floor because a folder preview carries no description, and
    ///    the logo takes an unbounded remainder), untouched by the tiers above.
    nonisolated enum HeroSlotGive {

        /// What each slot yields. Both are subtracted from the slot's pinned height by the view.
        struct Split: Equatable, Sendable {
            var synopsis: CGFloat
            var logo: CGFloat
            /// What the CONTENT gave up, against which the frame shrank by `compression`.
            var total: CGFloat { synopsis + logo }
        }

        /// - Parameters:
        ///   - compression: `PinnedRowGeometry.Plan.compression`, i.e. how much shorter the hero's
        ///     frame is being made. 0 outside pinned mode.
        ///   - showsCTA: the carousel form (true) or FEAT-15's focus panel (false).
        ///   - folderHero: `HomeView.isCollectionHero(item)` — a collection folder's preview, which
        ///     has no description and no meta line to protect (FEAT-29).
        static func split(compression: CGFloat,
                          showsCTA: Bool,
                          folderHero: Bool) -> Split {
            guard compression > 0 else { return Split(synopsis: 0, logo: 0) }
            let slot = showsCTA ? Theme.Size.heroSynopsisSlotHeightPinned
                                : Theme.Size.heroSynopsisSlotHeightPinnedPanel

            // FEAT-29, unchanged: a folder hero's synopsis slot is empty, so all of it is give and
            // the logo takes whatever is left over with no ceiling of its own.
            guard !folderHero else {
                let synopsis = min(compression, slot)
                return Split(synopsis: synopsis, logo: max(compression - synopsis, 0))
            }

            // Tier 1 — the synopsis give both hero forms have.
            let firstSynopsis = min(compression, Theme.Size.heroSynopsisSlotPinnedGive)
            // Tier 2 — the logo, down to its floor.
            let logo = min(max(compression - firstSynopsis, 0), Theme.Size.heroLogoSlotPinnedGive)
            // Tier 3 — the CTA slot the panel absorbed, past the frame's own slack. 0 for the
            // carousel, whose synopsis give IS its whole give above the floor.
            let panelExtra = max(slot
                                 - Theme.Size.heroSynopsisSlotHeightPinnedFloor
                                 - Theme.Size.heroSynopsisSlotPinnedGive, 0)
            let beyond = max(compression - firstSynopsis - logo - Theme.Size.heroPinnedFrameSlack, 0)
            return Split(synopsis: firstSynopsis + min(beyond, panelExtra), logo: logo)
        }
    }

    // MARK: - The plan

    /// Resolves one regime. Pure: the same inputs always produce an equal `Plan` (the probe log
    /// below is fire-once-per-regime and has no effect on the value).
    ///
    /// - Parameters:
    ///   - posterHeight: `PosterStyle.height` — the tallest artwork a PORTRAIT pinned row presents.
    ///   - captionVisible: `PosterStyle.showTitle` (Hide Labels OFF).
    ///   - showsCTA: whether the pinned hero renders its CTA, i.e. the carousel form. False is
    ///     FEAT-15's focus panel, which has a larger synopsis slot and therefore more give.
    ///   - landscapeRows: `PosterStyle.landscapeCatalogRows`. Landscape catalog rows are 203pt tall,
    ///     so nothing needs to be spent for them. NOTE: a collection row whose folders keep the
    ///     portrait shape still presents `posterHeight`-tall tiles in this mode
    ///     (`FolderTile.artworkHeight`), and such a row is over-tall here exactly as it is at Medium
    ///     today — the belt owns it. Compressing a hero by ~112pt for a page whose catalog rows are
    ///     203pt tall would be the worse trade.
    ///   - mode: the two Appearance flags `PinnedRowTitle.focusLiftAllowance` branches on. The plan
    ///     is MODE-DEPENDENT as of BUG-87/89 rc10 — the top reach's floor has to hold the focus lift
    ///     — so a caller inside SwiftUI must pass `@AppStorage`-backed flags rather than let the
    ///     `.current` default latch whatever the defaults said last (the Codex r10 P2 staleness
    ///     class, closed for `PinnedRowTitleTracking` and closed here the same way).
    nonisolated static func plan(posterHeight: CGFloat,
                                 captionVisible: Bool,
                                 showsCTA: Bool,
                                 landscapeRows: Bool,
                                 mode: PinnedRowTitle.FocusModeFlags = .current) -> Plan {
        let artwork = landscapeRows ? Theme.Size.landscapeHeight : posterHeight
        let captionChrome = captionVisible ? PinnedRowTitle.cardLockupCaptionChrome : 0
        let baseTopReach = Theme.Size.heroPinnedRowTopPad
        let baseBottomReach = Theme.Size.heroPinnedRowBottomReach
        let budget = Theme.Size.heroPinnedRowsViewportBudget
        let key = regimeKey(posterHeight: posterHeight,
                            captionVisible: captionVisible,
                            showsCTA: showsCTA,
                            landscapeRows: landscapeRows,
                            mode: mode)

        // BUG-87/89: the top reach's floor depends on the lift the band has to hold, read from the
        // same flags `PinnedRowTitle.focusLiftAllowance` reads. `.cardTreatment` because every
        // pinned row's cards go through `CardFocusTreatment`/`CardArtworkFocusLift` (BUG-108 brought
        // the collection folder row in too).
        let lift = PinnedRowTitle.focusLiftAllowance(artworkHeight: artwork,
                                                    captionVisible: captionVisible,
                                                    treatment: .cardTreatment,
                                                    mode: mode)
        let topFloor = topReachFloor(lift: lift)

        // Wave 10's number for this artwork, and the scope gate in one read: it is 0 at exactly the
        // Poster Sizes whose rows already fit the pre-BUG-87 extent rule, and 0 everywhere when
        // `debug.pinnedHeroCompressionOff` is set.
        let legacyCompression = PinnedRowTitle.pinnedHeroCompression(rowArtworkHeight: artwork)

        func settled(compression: CGFloat, topReach: CGFloat, bottomReach: CGFloat) -> Plan {
            let viewport = budget + compression
            let linkFrame = topReach + artwork + captionChrome + bottomReach
            return Plan(compression: compression,
                        topReach: topReach,
                        bottomReach: bottomReach,
                        viewport: viewport,
                        linkFrame: linkFrame,
                        fits: linkFrame <= viewport,
                        restRange: max(viewport - linkFrame, 0),
                        regimeKey: key)
        }

        // Today's geometry, unchanged — the `!fits` contract and the closed-gate answer.
        let unchanged = settled(compression: legacyCompression,
                                topReach: baseTopReach,
                                bottomReach: baseBottomReach)

        guard legacyCompression > 0 else {
            noteIfShort(unchanged)
            return unchanged
        }

        // The demand, keyed to the LINK frame — the extent the engine actually reveals — plus the
        // shelf's own top padding above it and the settled cushion below, which together are what
        // make a canonical rest sit fully inside the viewport rather than flush to its edges. The
        // formula is unchanged by the rc2 reordering; only the order the three dials pay it in is.
        // Each step below is a pure `min` against a real give; none can raise a dial.
        let demand = Theme.Spacing.lg
            + baseTopReach
            + artwork
            + captionChrome
            + baseBottomReach
            + Theme.Size.heroPinnedRowsSettledCushion
            - budget
        var short = max(demand, 0)

        // (a) The downward reach first — the cheapest dial, 20pt of give.
        let bottomSpend = min(short, baseBottomReach - bottomReachFloor)
        let bottomReach = baseBottomReach - bottomSpend
        short -= bottomSpend

        // (b) The upward reach next, down to its derived, LIFT-AWARE floor — 22pt of give with No
        //     Zoom on, 2pt with either zoom mode, because the band it leaves behind has to hold the
        //     title AND the focus lift (BUG-87/89).
        let topSpend = min(short, baseTopReach - topFloor)
        let topReach = baseTopReach - topSpend
        short -= topSpend

        // (c) Hero compression LAST, for the remainder — every point of it is description the
        //     viewer loses (the panel's synopsis slot is where it comes from), which is exactly the
        //     rc2 complaint this order answers.
        let compression = min(short, elasticGive(showsCTA: showsCTA))

        let plan = settled(compression: compression, topReach: topReach, bottomReach: bottomReach)
        guard plan.fits else {
            // Unsatisfiable: hand back today's numbers so the belt regime is exactly what shipped,
            // and say so once.
            noteIfShort(unchanged)
            return unchanged
        }
        return plan
    }

    /// `L403c0p1r0z1` — size tag + rounded artwork height, captions, panel (i.e. `!showsCTA`),
    /// landscape rows, and (BUG-87/89 rc10) the zoom mode. Stable across renders for one regime and
    /// different for every other, which is all `onChange` and the log-once key need it to be.
    ///
    /// `z` is the new trailing component and it is not cosmetic: the plan is MODE-DEPENDENT now
    /// (`topReachFloor(lift:)` holds the focus lift, so the two zoom modes produce different reaches
    /// and a different compression at the same Poster Size), so two modes must not share a regime
    /// key. `PinnedRowSettle.regimeFits` and its log-once sets are keyed on this string — letting a
    /// No-Zoom key describe a zoom-on plan would hand the corrector the wrong `fits` and suppress
    /// the first line of the mode it actually switched into.
    ///
    /// Only `noZoom` is encoded, not `accentRing`: since BUG-93 both zoom-on treatments raise the
    /// artwork by the same `heroPinnedRowFocusLiftAllowance`, so a ring flip produces an IDENTICAL
    /// plan and keying on it would churn the `onChange` re-reveal for nothing. If a future treatment
    /// makes the ring's rise differ again, this key gains an `a` component in the same breath.
    nonisolated static func regimeKey(posterHeight: CGFloat,
                                      captionVisible: Bool,
                                      showsCTA: Bool,
                                      landscapeRows: Bool,
                                      mode: PinnedRowTitle.FocusModeFlags = .current) -> String {
        let rounded = Int(posterHeight.rounded())
        let small = Int((Theme.Size.posterHeight * PosterSizePreset.smallScale).rounded())
        let medium = Int(Theme.Size.posterHeight.rounded())
        let large = Int((Theme.Size.posterHeight * PosterSizePreset.largeScale).rounded())
        let tag: String
        if rounded == small {
            tag = "S"
        } else if rounded == medium {
            tag = "M"
        } else if rounded == large {
            tag = "L"
        } else {
            tag = "X"
        }
        return "\(tag)\(rounded)c\(captionVisible ? 1 : 0)p\(showsCTA ? 0 : 1)r\(landscapeRows ? 1 : 0)"
            + "z\(mode.noZoom ? 1 : 0)"
    }

    /// The three synced Poster Size presets, as RATIOS of the Medium default rather than as pixel
    /// literals — `PosterStyle.init(from:)` scales `widthDp` by `Theme.Size.posterWidth / 126`, so
    /// Small (105dp) and Large (154dp) are exactly these fractions of `Theme.Size.posterHeight`
    /// whatever that constant becomes. Only the regime key's cosmetic size tag reads them; no
    /// geometry is derived from them (a synced width outside the presets is an ordinary payload
    /// here and simply tags as `X`).
    nonisolated enum PosterSizePreset {
        static let smallScale: CGFloat = 105.0 / 126.0
        static let largeScale: CGFloat = 154.0 / 126.0
    }

    // MARK: - Probe

    /// Fires once per regime when the link frame cannot be made to fit — the belt is back in play
    /// and a device pass needs to know it is looking at that state. Wording mirrors
    /// `PinnedRowTitle.pinnedHeroCompression`'s `compression CAPPED` line.
    nonisolated private static func noteIfShort(_ plan: Plan) {
        guard HomeGeometryProbe.enabled, !plan.fits else { return }
        guard !shortRegimesLogged.contains(plan.regimeKey) else { return }
        shortRegimesLogged.insert(plan.regimeKey)
        NSLog("[HomeScrollProbe] plan %@",
              "regime=\(plan.regimeKey) linkFrame=\(Int(plan.linkFrame.rounded()))"
                + " viewport=\(Int(plan.viewport.rounded())) fits=0 CAPPED"
                + " — rows still short, belt remains in play")
    }

    /// Same `nonisolated(unsafe)` log-once precedent as `PinnedRowTitle.cappedCompressionLogged`:
    /// probe-only bookkeeping, written from the layout pass that produced the line.
    nonisolated(unsafe) private static var shortRegimesLogged: Set<String> = []
}
