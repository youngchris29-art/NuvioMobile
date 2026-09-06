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
/// Three dials, each a pure `min`, spent in a fixed order — cheapest and least regression-prone
/// first:
///
///  1. **Hero compression**, bounded by what the pinned hero's internals can actually yield
///     (`Theme.Size.heroPinnedCompressionCap(showsCTA:)`). Costs nothing structural: the hero's own
///     elastic slots absorb it.
///  2. **The downward reach** (`heroPinnedRowBottomReach` 44 → `bottomReachFloor` 24), only if the
///     demand still exceeds the cap. It covers the mirror-direction rest error and has no content
///     to protect below it, so it is the cheaper of the two reaches.
///  3. **The upward reach** (`heroPinnedRowTopPad` 88 → `topReachFloor` 64), last and only if still
///     short. This is the most regression-prone dial in the app — the band above the artwork is
///     what makes the reveal include the section title, and the sim bisected reach 100 as the value
///     where focus resolution dies outright. It is never RAISED here, only lowered, and never below
///     `topReachFloor`: `heroPinnedRowTitleInset` (48) + a measured title (~38) − `Spacing.lg` (24)
///     ≈ 62 is the arithmetic floor at which the title still renders inside the band at all.
///
/// ## Unsatisfiable by design
///
/// Large + captions + carousel hero demands ~155.8pt against an elastic give of ~70 and 44pt of
/// reach give — 114 against 156. That case CANNOT be made to fit and is not pretended otherwise:
/// the plan reports `fits == false`, returns TODAY'S numbers verbatim (Wave 10's compression, reach
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
        /// Short stable identity for this regime, e.g. `L403c0p1r0` — Large, no captions, panel
        /// hero, portrait rows. Used as the `onChange` key that re-reveals the rows after a Poster
        /// Size switch (BUG-89) and as the log-once key below.
        var regimeKey: String
    }

    // MARK: - Floors

    /// Floor for the downward reach. It exists to absorb the mirror-direction rest error, and 24
    /// (`Theme.Spacing.lg`, the shelf's own bottom padding) is the point at which the focused
    /// card's caption still clears the fold without the reach's help.
    nonisolated static let bottomReachFloor: CGFloat = Theme.Spacing.lg

    /// Floor for the upward reach. DERIVED, and the hardest bound in this file: the overlaid title
    /// sits `heroPinnedRowTitleInset` below the shelf top and the card frame starts `Spacing.lg`
    /// below that same top, so the band above the artwork must still hold
    /// `heroPinnedRowTitleInset + titleHeight − Spacing.lg` for the title to render inside the reach
    /// at all. With the ~38pt measured title `PinnedRowTitle` records that is ≈62; 64 keeps 2pt of
    /// margin. NEVER raise this above `heroPinnedRowTopPad` — reach 100 kills focus resolution
    /// outright (Theme.swift ~L310-315), and this dial only ever moves DOWN.
    nonisolated static let topReachFloor: CGFloat = 64

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
    nonisolated static func plan(posterHeight: CGFloat,
                                 captionVisible: Bool,
                                 showsCTA: Bool,
                                 landscapeRows: Bool) -> Plan {
        let artwork = landscapeRows ? Theme.Size.landscapeHeight : posterHeight
        let captionChrome = captionVisible ? PinnedRowTitle.cardLockupCaptionChrome : 0
        let baseTopReach = Theme.Size.heroPinnedRowTopPad
        let baseBottomReach = Theme.Size.heroPinnedRowBottomReach
        let budget = Theme.Size.heroPinnedRowsViewportBudget
        let key = regimeKey(posterHeight: posterHeight,
                            captionVisible: captionVisible,
                            showsCTA: showsCTA,
                            landscapeRows: landscapeRows)

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

        // (a) Compression, keyed to the LINK frame — the extent the engine actually reveals — plus
        //     the shelf's own top padding above it and the settled cushion below, which together
        //     are what make a canonical rest sit fully inside the viewport rather than flush to its
        //     edges. Each step below is a pure `min` against a real give; none can raise a dial.
        let demand = Theme.Spacing.lg
            + baseTopReach
            + artwork
            + captionChrome
            + baseBottomReach
            + Theme.Size.heroPinnedRowsSettledCushion
            - budget
        let compression = min(max(demand, 0), elasticGive(showsCTA: showsCTA))
        var short = max(demand - compression, 0)

        // (b) The downward reach, only past the cap.
        let bottomSpend = min(short, baseBottomReach - bottomReachFloor)
        let bottomReach = baseBottomReach - bottomSpend
        short -= bottomSpend

        // (c) The upward reach, last.
        let topSpend = min(short, baseTopReach - topReachFloor)
        let topReach = baseTopReach - topSpend

        let plan = settled(compression: compression, topReach: topReach, bottomReach: bottomReach)
        guard plan.fits else {
            // Unsatisfiable: hand back today's numbers so the belt regime is exactly what shipped,
            // and say so once.
            noteIfShort(unchanged)
            return unchanged
        }
        return plan
    }

    /// `L403c0p1r0` — size tag + rounded artwork height, captions, panel (i.e. `!showsCTA`),
    /// landscape rows. Stable across renders for one regime and different for every other, which is
    /// all `onChange` and the log-once key need it to be.
    nonisolated static func regimeKey(posterHeight: CGFloat,
                                      captionVisible: Bool,
                                      showsCTA: Bool,
                                      landscapeRows: Bool) -> String {
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
