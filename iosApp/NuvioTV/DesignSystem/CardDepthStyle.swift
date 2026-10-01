import Combine
import SwiftUI
import SharedCore

/// Which on-screen card family a depth treatment applies to. Mirrors the shared
/// `NuvioCardDepthSurface` enum, but kept as a Swift enum so call sites and the resolver can `switch`
/// cleanly instead of bridging a Kotlin enum across the ObjC boundary.
enum CardDepthSurface {
    case posters
    case continueWatching
    case episodeCards
    case cast
    case trailers
}

/// Resolved card-depth styling for the tvOS UI, derived from the shared `CardDepthStyleRepository`
/// (which stores the preference profile-scoped and syncs it across devices). The look is an inset
/// edge highlight plus a top sheen — a direct port of the Compose `cardDepthVisual`. Disabled by
/// default; the master toggle and each surface can be switched independently.
struct CardDepthStyle: Equatable {
    /// BUG-57: top-stop opacity for the partial-coverage (Top/Half) rail — the configured edge
    /// strength (0…1) lifted ×1.5, capped so Bold doesn't blow out. Pure so it is unit-testable;
    /// Full never calls it (its closed 1 pt stroke is unchanged).
    ///
    /// BUG-110 (rc12): superseded by `railTopAlpha(edge:)`, which now supplies the top stop at
    /// EVERY coverage (Full included) so the three strength presets are visibly distinct there too.
    /// Kept only as a historical marker in this comment — see `railTopAlpha` below.

    /// Tester (u/mrStevenx3-class report, beta.15): "Card Depth appears thick even when I select
    /// Subtle." Root cause: the partial-coverage rail's `lineWidth` used to be keyed on COVERAGE
    /// (Top/Half vs Full), not on the user's STRENGTH choice — every partial-coverage rail drew at
    /// 2pt regardless of Subtle/Balanced/Bold. Since Subtle+Top is the *default* combination, that
    /// made the out-of-the-box look thicker and brighter than even Bold+Full's 1pt closed stroke —
    /// exactly backwards from what "Subtle" should mean.
    ///
    /// BUG-110 (rc12) superseded this too: `railWidth(edgeStrength:)` below now gives every strength
    /// its own width at EVERY coverage, Full included — see that function's doc for why Full also
    /// needed to change.
    var enabled = false
    /// 0…100. Opacity of the inset edge highlight at the top of the card. Default mirrors the shared
    /// `DefaultCardDepthEdgeStrength` (28).
    var edgeStrength = 28
    /// 0…100. Opacity of the top sheen. Default mirrors the shared `DefaultCardDepthSheenStrength` (10).
    var sheenStrength = 10
    /// 0…100. How far the edge highlight carries toward the bottom edge. Default mirrors the shared
    /// `DefaultCardDepthEdgeCoverage` (0 — highlight fades out before the bottom).
    var edgeCoverage = 0
    var postersEnabled = true
    var continueWatchingEnabled = true
    var episodeCardsEnabled = true
    var castEnabled = true
    var trailersEnabled = true

    static let `default` = CardDepthStyle()

    init() {}

    init(from state: CardDepthStyleUiState) {
        enabled = state.enabled
        edgeStrength = Int(state.edgeStrength)
        sheenStrength = Int(state.sheenStrength)
        edgeCoverage = Int(state.edgeCoverage)
        postersEnabled = state.postersEnabled
        continueWatchingEnabled = state.continueWatchingEnabled
        episodeCardsEnabled = state.episodeCardsEnabled
        castEnabled = state.castEnabled
        trailersEnabled = state.trailersEnabled
    }

    /// Whether the depth treatment should render for `surface` — the master toggle AND the per-surface
    /// flag both have to be on.
    func isEnabled(for surface: CardDepthSurface) -> Bool {
        guard enabled else { return false }
        switch surface {
        case .posters: return postersEnabled
        case .continueWatching: return continueWatchingEnabled
        case .episodeCards: return episodeCardsEnabled
        case .cast: return castEnabled
        case .trailers: return trailersEnabled
        }
    }

    // MARK: - BUG-110: strength-preset rail geometry (rc12)
    //
    // Tester report (rc11): "the three strength levels look identical on my TV." Root cause, found by
    // reading this file rather than trusting the tester's word for it: at FULL coverage the three
    // presets (Subtle/Balanced/Bold = edge strength 28/42/56) differed ONLY by the opacity of a
    // single 1pt closed stroke — 0.14-0.21 alpha steps on a hairline, from a couch. At Top/Half
    // coverage the old `partialCoverageRailWidth(edgeStrength:)` gave Balanced and Bold the identical
    // 2pt width (BUG-83's `edgeStrength <= 28 ? 1 : 2`), so two of the three presets were the SAME
    // width everywhere and the third differed only at partial coverage. The functions below replace
    // `partialCoverageRailWidth`/`partialCoverageRailBoost` with a unified width + top-alpha + halo
    // scheme applied at EVERY coverage (Full included, for the first time since BUG-31), plus a new
    // Edge "Off" preset (0) so the effect can be switched off from the Edge picker alone. Full
    // strength-preset table (edge strength → rail width, top α, halo width, halo α):
    //
    //     Off (0)       → 0pt,  —,    0pt,  —
    //     Subtle (28)   → 1pt,  0.35, 0pt,  —
    //     Balanced (42) → 2pt,  0.60, 0pt,  —      (rc14: halo removed, was 8pt / 0.108)
    //     Bold (56)     → 3pt,  0.80, 0pt,  —      (rc14: top α 0.90 → 0.80, halo removed, was 13pt / 0.162)
    //     Placeholder tiles (rc13, any level) → clamped to Subtle (28) → 1pt, 0.35, 0pt, —
    //
    // (halo width = `railWidth` + 2 × `railHaloSpread`; halo α = `railTopAlpha` × 0.18 — both inert
    // since rc14, `railHaloSpread` is 0 at every strength.)
    //
    // BUG-110 (rc14, Steven rc13 verdict, 2026-09-30; Bold/Balanced depth: "a thick border appears on
    // the poster, in addition to the border already around the poster"): two mechanisms, both
    // confirmed by reading this file. (1) On a FOCUSED ring-mode card the rail was stroked directly
    // inside the 4pt accent ring, so the focused card showed two borders — the rail now draws on
    // UNFOCUSED cards only (`CardDepthModifier` skips the rail layer while `\.isFocused`; the sheen
    // stays) and the focus treatment (ring / lift / still highlight) owns the focused card's edge.
    // (2) The inward halo band (3/5pt spread → 8/13pt stroke) read as a thick white frame on every
    // unfocused Balanced/Bold poster on a real TV — `railHaloSpread` now returns 0 everywhere, so the
    // halo stroke in `edgeHighlight` never draws. Bold's top stop also drops 0.90 → 0.80 so the
    // 3pt rail alone is not a hard white outline. An unfocused→focused transition drops the rail
    // with no animation of its own (acceptable: the ring/lift/highlight animate in over it).
    //
    // BUG-110 (rc13, u/mrStevenx3: "depth rail reads as a glitch on solid Genres tiles"): the table
    // above assumed every rail traces a picture. A tile with no artwork cover — the gradient +
    // initial/emoji placeholder every TMDB Discover genre folder falls back to (`FolderTile`'s
    // `else` branch) — draws the SAME rail over a flat solid fill, where Balanced/Bold's brighter
    // top stop and halo read as a stray bright line rather than "an edge catching light on a
    // picture". `effectiveEdgeStrength(_:artworkPresent:)` below clamps the strength actually fed
    // to `railWidth`/`railTopAlpha`/`railHaloSpread` to the Subtle ceiling whenever the caller says
    // there is no artwork, regardless of the user's chosen level. Tiles that DO have artwork are
    // completely unaffected — `artworkPresent` defaults to `true`, so every existing call site
    // (`PosterCard`, `LandscapeCard`, `SagaCard`, `CastCard`) renders exactly as before.

    /// How wide the crisp rail draws, in points, at every coverage (Top/Half/Full alike) — replaces
    /// `partialCoverageRailWidth`, which only ever fired in the partial-coverage branch and left Full
    /// hardcoded at a flat 1pt regardless of strength (part of why Full's three presets read alike).
    /// Bands mirror `AppearanceSettingsPane`'s Subtle/Balanced/Bold preset mapping (28/42/56 out of
    /// 0…100 — UI-layer and not shared with this design-system file, so the thresholds are duplicated
    /// here by hand, same as before): `≤0` → 0 (the new Edge "Off" preset), `≤28` → 1pt, `≤42` → 2pt,
    /// else → 3pt. A finer strength synced from mobile's slider (FEAT-41, parked) falls into whichever
    /// band it's closest to — e.g. 30 → 2pt.
    static func railWidth(edgeStrength: Int) -> CGFloat {
        if edgeStrength <= 0 { return 0 }
        if edgeStrength <= 28 { return 1 }
        if edgeStrength <= 42 { return 2 }
        return 3
    }

    /// The rail's TOP stop opacity, now anchored directly to the Subtle/Balanced/Bold presets so each
    /// one reads as a visibly different brightness, not just a (possibly identical) width. Piecewise
    /// linear through `(0, 0)`, `(0.28, 0.35)`, `(0.42, 0.60)`, `(0.56, 0.80)`, `(1.0, 0.95)` — the
    /// preset points name the alpha each preset renders at (Subtle 0.35, Balanced 0.60, Bold 0.80;
    /// Bold was 0.90 until rc14, BUG-110 — a 3pt rail at 0.90 white read as a hard outline on a TV),
    /// `1.0` (100 strength, the ceiling any stronger mobile-synced value can reach) capped at 0.95 so
    /// the rail never quite reads as opaque white. `edge` is the same 0…1 unit value used throughout
    /// this file (`edgeStrength / 100`), matching `partialCoverageRailBoost`'s old parameter space.
    ///
    /// Replaces `partialCoverageRailBoost`, which only fired in the partial-coverage branch — Full's
    /// top stop used to be hardcoded equal to `edge` (identical to mid/bottom), which is a large part
    /// of why Full read flat. BUG-57's invariant survives unchanged: the boosted top stays ≥ the raw
    /// edge strength for every strength up to 0.9 (0.35 ≥ 0.28, 0.60 ≥ 0.42, 0.80 ≥ 0.56) — a thin
    /// rail still needs the lift more than a thick one, not less.
    static func railTopAlpha(edge: Double) -> Double {
        let anchors: [(x: Double, y: Double)] = [(0, 0), (0.28, 0.35), (0.42, 0.60), (0.56, 0.80), (1.0, 0.95)]
        let clamped = min(max(edge, 0), 1)
        guard clamped > 0 else { return 0 }
        for index in 1..<anchors.count {
            let (x0, y0) = anchors[index - 1]
            let (x1, y1) = anchors[index]
            guard clamped <= x1 else { continue }
            guard x1 > x0 else { return min(y1, 0.95) }
            let t = (clamped - x0) / (x1 - x0)
            return min(y0 + t * (y1 - y0), 0.95)
        }
        return 0.95
    }

    /// The rail's three-stop gradient (top/mid/bottom), unified across Full and partial coverage for
    /// the first time since BUG-31. Full now takes the SAME boosted top as partial coverage — the top
    /// stop used to be hardcoded equal to `edge` at Full (no boost at all, matching mid/bottom); mid
    /// and bottom stay `edge` at Full, the same flat look the closed stroke has always had below its
    /// top edge. Partial coverage keeps today's mid/bottom formula unchanged (the geometric coverage
    /// cut itself is applied by `coverageMask` at the call site, not here).
    static func railStops(edge: Double, coverage: Double) -> (top: Double, mid: Double, bottom: Double) {
        let top = railTopAlpha(edge: edge)
        guard coverage < 1 else { return (top, edge, edge) }
        let mid = edge * (0.33 + 0.67 * coverage)
        let bottom = edge * coverage
        return (top, mid, bottom)
    }

    /// How far a soft halo stroke spreads beyond the crisp rail, in points, ADDED to `railWidth` on
    /// each side (`width + 2 × halo` is the halo stroke's own `lineWidth` — see `edgeHighlight`).
    /// Same three-strength banding as `railWidth`, which rc12-rc13 used to give Balanced/Bold 3pt/5pt
    /// of spread (a total halo stroke of 8pt/13pt).
    ///
    /// BUG-110 (rc14, Steven rc13 verdict, 2026-09-30): the halo is REMOVED — this returns 0 for every
    /// strength, so the `haloSpread > 0` stroke in `edgeHighlight` never draws. On a real TV the
    /// inward band read as a thick white frame around every unfocused Balanced/Bold poster ("a thick
    /// border appears on the poster"). The function and its callers stay so the preset-table
    /// arithmetic (and `railHaloAlpha`) keep compiling; restoring a halo later is a one-function
    /// change here, not a re-plumb.
    static func railHaloSpread(edgeStrength: Int) -> CGFloat {
        return 0
    }

    /// The halo stroke's opacity — always a fixed 18% of the crisp rail's own top stop, so the halo
    /// reads as a soft glow trailing the rail rather than an independent setting to tune by hand.
    /// Inert since rc14 (BUG-110): `railHaloSpread` is 0 at every strength, so `edgeHighlight` never
    /// draws the halo stroke this alpha would colour.
    static func railHaloAlpha(edge: Double) -> Double {
        railTopAlpha(edge: edge) * 0.18
    }

    /// BUG-110 (rc13): the edge strength actually rendered — clamped to the Subtle ceiling (28)
    /// whenever `artworkPresent` is `false`, unchanged otherwise. Pure and static, like every other
    /// function in this section, so the clamp is unit-testable without mounting a live
    /// `CardDepthOverlay`. Every reader of `style.edgeStrength` inside `CardDepthOverlay` goes
    /// through this first — `railWidth`, `railTopAlpha` (via `railStops`), and `railHaloSpread` all
    /// end up clamped together, so a placeholder tile can never end up with (say) a Bold width but a
    /// Subtle alpha.
    static func effectiveEdgeStrength(_ edgeStrength: Int, artworkPresent: Bool) -> Int {
        guard !artworkPresent else { return edgeStrength }
        return min(edgeStrength, 28)
    }

    /// Whether the halo should be withheld this frame. rc14 (BUG-110): no longer consulted by the
    /// renderer — the halo is gone entirely (`railHaloSpread` is 0) and a focused card draws no rail
    /// at all (`CardDepthModifier`) — kept so the truth-table unit test and any future halo revival
    /// still compile. Original rationale: on a FOCUSED card in either mode that reserves
    /// the plain-label ring band (`PlainLabelRing.reservesBand`), a 4pt accent ring or still-mode
    /// stroke already sits just outside the rail; the halo's soft spread would bleed straight into
    /// that ring, pixel for pixel, and read as a fuzzy double outline rather than two distinct
    /// treatments. The crisp rail itself is untouched at every focus state — it stays the
    /// focus-independent, at-rest treatment `test50DepthRailHugsArtworkInStillMode` measures; only the
    /// halo is ever suppressed, and only while both conditions hold.
    static func haloSuppressed(focused: Bool, ringBandReserved: Bool) -> Bool {
        focused && ringBandReserved
    }

    #if DEBUG
    /// Debug-only launch/default overrides so a UI test can force an exact strength triptych
    /// (Subtle/Balanced/Bold, or the new Off) without depending on whatever per-surface state the
    /// synced fixture profile happens to carry. All four keys are read with `object(forKey:)`, not
    /// `bool(forKey:)`/`integer(forKey:)`: `0` is now a legal value for Edge (the new "Off" preset),
    /// Coverage ("Top") and Sheen ("Off"), and the typed accessors cannot tell "explicitly set to 0"
    /// from "key absent" — both answer 0 either way. `object(forKey:)` answers nil only when the key
    /// is genuinely unset; the argument-domain value always lands as a string
    /// (`-debug.cardDepthEdge 42`), so it is decoded by hand (`Int("\(raw)")`) rather than force-cast
    /// to `NSNumber`, and the "On" flag is decoded via `NSString.boolValue` (`"YES"`/`"1"`/`"true"` →
    /// true), the same coercion `bool(forKey:)` would give a present key, applied uniformly with the
    /// other three so all four knobs share one code path.
    ///
    /// `-debug.cardDepthOn YES` forces the master toggle AND every one of the five per-surface flags
    /// on — the BUG-110 triptych test (`test60DepthEdgeLevelsAreDistinguishable`) wants ONE card
    /// family lit deterministically, not whatever surfaces the fixture profile happens to have
    /// enabled.
    func applyingDebugOverrides() -> CardDepthStyle {
        let defaults = UserDefaults.standard
        func overrideInt(_ key: String) -> Int? {
            guard let raw = defaults.object(forKey: key) else { return nil }
            return Int("\(raw)")
        }
        var style = self
        if let onRaw = defaults.object(forKey: "debug.cardDepthOn"), (onRaw as? NSString)?.boolValue == true {
            style.enabled = true
            style.postersEnabled = true
            style.continueWatchingEnabled = true
            style.episodeCardsEnabled = true
            style.castEnabled = true
            style.trailersEnabled = true
        }
        if let edge = overrideInt("debug.cardDepthEdge") { style.edgeStrength = edge }
        if let coverage = overrideInt("debug.cardDepthCoverage") { style.edgeCoverage = coverage }
        if let sheen = overrideInt("debug.cardDepthSheen") { style.sheenStrength = sheen }
        return style
    }
    #endif
}

private struct CardDepthStyleKey: EnvironmentKey {
    static let defaultValue = CardDepthStyle.default
}

extension EnvironmentValues {
    var cardDepthStyle: CardDepthStyle {
        get { self[CardDepthStyleKey.self] }
        set { self[CardDepthStyleKey.self] = newValue }
    }
}

/// Observes the shared `CardDepthStyleRepository` and republishes a resolved `CardDepthStyle` for the
/// environment. Owned at the app root and injected via `.environment(\.cardDepthStyle,)`; profile-scoped
/// (the repo reloads on profile switch through the lifecycle coordinator). Mirrors `PosterStyleModel`.
@MainActor
final class CardDepthStyleModel: ObservableObject {
    @Published private(set) var style = CardDepthStyle.default

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        #if DEBUG
        // BUG-110: apply the debug overrides immediately, before the repository's first emission
        // lands, so a UI test's `-debug.cardDepthOn YES` triptych is visible from Home's first frame
        // rather than flashing the synced fixture's default for one beat.
        style = CardDepthStyle.default.applyingDebugOverrides()
        #endif
        CardDepthStyleRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(CardDepthStyleRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? CardDepthStyleUiState else { return }
            var resolved = CardDepthStyle(from: state)
            #if DEBUG
            resolved = resolved.applyingDebugOverrides()
            #endif
            self.style = resolved
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}

extension View {
    /// Applies the shared card-depth treatment (inset edge highlight + top sheen) for `surface`,
    /// reading the resolved style from the environment. A no-op when the user has the effect — or this
    /// surface — turned off, so callers can attach it unconditionally right after the card's `clipShape`.
    ///
    /// **Attach it to the ARTWORK, never to the card lockup.** Both gradients here — the sheen's top
    /// 22% and the edge highlight's coverage mask — measure 0…1 down *this view's* own height, so the
    /// box this modifier lands on defines what "Top" means. On the artwork frame that is the artwork's
    /// top edge (correct); hoisted onto a caption-bearing lockup it would silently stretch the same
    /// band across artwork + title. BUG-36 moved the cards' focus treatment up to the lockup and
    /// deliberately left this modifier down on the artwork for exactly that reason — the coverage
    /// geometry below is unchanged and stays anchored where it always was.
    ///
    /// BUG-91 sharpens "the artwork" into **the INSET artwork frame, with the inset radius**.
    /// `PosterCard`/`LandscapeCard` reserve a `ringWidth` band around the picture whenever either
    /// focus ring can draw (`ringInset`), and they used to attach this modifier after re-framing
    /// back up to the card's outer size - so the rail traced the OUTER rect and stood 4pt off the
    /// picture on every edge of every card, at rest, which is what the beta.17 report calls "an
    /// empty band between the artwork and the card frame". Both cards now attach it to the smaller,
    /// clipped artwork box and pass `max(0, cornerRadius - inset)` - the same radius the artwork's
    /// own `clipShape` uses, so the rail is concentric with the picture's corner rather than with
    /// the ring's. Nothing about the geometry below changes: every fraction is relative to whatever
    /// box this lands on, so a 4pt-shorter box moves the bands by the same 4pt the picture moved.
    /// With no band reserved (ring off, zoom on) the two attachment points are the same rect and
    /// the render is unchanged.
    ///
    /// BUG-110 (rc14, Steven rc13 verdict, 2026-09-30): the modifier reads `\.isFocused` and draws NO
    /// rail on a focused card (the top sheen still draws) — the focus treatment (accent ring / lift /
    /// still highlight) owns a focused card's edge, so the rail no longer sits inside the 4pt ring as
    /// a second border. The halo layer that rc12-rc13 added was removed the same release
    /// (`CardDepthStyle.railHaloSpread` is 0). An unfocused→focused transition drops the rail with
    /// no animation of its own.
    ///
    /// BUG-110 (rc13): `artworkPresent` defaults to `true` — pass `false` from a tile that is about
    /// to draw its no-cover gradient+initial/emoji placeholder instead of a picture, so the rendered
    /// rail clamps to the Subtle preset (`CardDepthStyle.effectiveEdgeStrength`) regardless of the
    /// user's chosen level. Every existing call site is byte-identical (the default keeps it on).
    func nuvioCardDepth<S: InsettableShape>(_ shape: S, surface: CardDepthSurface, artworkPresent: Bool = true) -> some View {
        modifier(CardDepthModifier(shape: shape, surface: surface, artworkPresent: artworkPresent))
    }
}

private struct CardDepthModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let surface: CardDepthSurface
    /// BUG-110 (rc13): see `nuvioCardDepth`'s doc — forwarded to `CardDepthOverlay` unchanged.
    var artworkPresent: Bool = true
    @Environment(\.cardDepthStyle) private var style
    /// BUG-110: reflects the nearest focusable ancestor's focus state (the same pattern `PosterCard`,
    /// `SagaCard` and others already use to read a Button's focus from a nested modifier). rc14
    /// (Steven rc13 verdict, 2026-09-30): a focused card draws NO rail — the focus treatment owns its
    /// edge — so this is forwarded to `CardDepthOverlay` as `railSuppressed`. It replaces rc12-rc13's
    /// halo-only suppression (and the two ring `@AppStorage` reads that fed it: nothing here depends
    /// on the ring/zoom mode any more, so a ring-mode flip no longer re-evaluates every card).
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        if style.isEnabled(for: surface) {
            content.overlay { CardDepthOverlay(shape: shape, style: style, railSuppressed: isFocused, artworkPresent: artworkPresent) }
        } else {
            content
        }
    }
}

/// Port of Compose `Modifier.cardDepthVisual`: an inset edge (1-3pt by strength, since BUG-110) whose
/// white highlight fades top→bottom (governed by edge strength + coverage), plus a sheen gradient
/// over the top 22% of the card. Both are clipped to the card's own `shape` so rounded corners and
/// circles stay clean.
private struct CardDepthOverlay<S: InsettableShape>: View {
    let shape: S
    let style: CardDepthStyle
    /// BUG-110 (rc14, Steven rc13 verdict, 2026-09-30): true while the card is focused. The edge rail
    /// (and the removed-in-rc14 halo) is skipped entirely so the focus ring / lift / still highlight
    /// is the only border on a focused card; the top sheen is unaffected. Replaces rc12-rc13's
    /// halo-only `haloSuppressed`.
    let railSuppressed: Bool
    /// BUG-110 (rc13): `false` on a tile currently drawing its no-cover gradient+initial/emoji
    /// placeholder. Only the RAIL clamps on this — the sheen above (a flat top-of-card gradient)
    /// reads fine over a placeholder and is left alone.
    var artworkPresent: Bool = true

    var body: some View {
        let effectiveEdgeStrength = CardDepthStyle.effectiveEdgeStrength(style.edgeStrength, artworkPresent: artworkPresent)
        let edge = unit(effectiveEdgeStrength)
        let sheen = unit(style.sheenStrength)
        let coverage = unit(style.edgeCoverage)

        ZStack {
            if sheen > 0 {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(sheen), location: 0),
                        .init(color: .clear, location: 0.22),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            }
            if edge > 0 && !railSuppressed {
                edgeHighlight(edge: edge, coverage: coverage, effectiveEdgeStrength: effectiveEdgeStrength)
            }
        }
        .allowsHitTesting(false)
        // BUG-91 gate (test50): this ZStack fills whatever box `nuvioCardDepth` was attached to, so
        // its frame IS the rail's rect. Publishing it lets the harness assert "the rail hugs the
        // picture" against real geometry instead of hunting a 1-3pt hairline in a screenshot.
        // DEBUG-only, identifier-only - see `DebugAXIdentifier` (PosterCard.swift).
        .modifier(DebugAXIdentifier("card_depth_rail"))
    }

    /// The inset edge highlight, cut down to `coverage`.
    ///
    /// BUG-31: this used to be nothing but the closed `strokeBorder` below, with coverage ramping only
    /// the gradient's ALPHA down the Y axis. A closed stroke can never be "top only" that way — at
    /// coverage 0 ("Top") the top still painted at full edge opacity, the SIDES still painted at ~1/3
    /// opacity through mid-height, and only the bottom reached zero, so the card read as a gray
    /// hairline around all four edges. The stops are unchanged; the coverage cut is now GEOMETRIC.
    ///
    /// BUG-57 (u/mrStevenx3, the same reporter, on beta.11's arc): "Top is still not correct … Full
    /// works well." Sim A/B at 1:1 (2026-08-16, Bold edge): what Top left on screen was a 1 pt
    /// hairline at ≤56 % white over the top edge and corner shoulders — from a couch that reads as
    /// NOTHING, while Full's closed hairline still reads as an outline because a closed shape
    /// registers where a short arc does not. The partial modes therefore draw a heavier rail at low
    /// strength, with the top stop lifted so a "lit from above" edge is actually visible at the same
    /// setting; the geometric mask is unchanged (still no side rails, no bottom).
    ///
    /// Tester follow-up ("Card Depth appears thick even when I select Subtle"): the line width used
    /// to be fixed at 2 pt for every partial-coverage rail, keyed only on coverage — so the default
    /// Subtle+Top combination drew thicker than Bold+Full.
    ///
    /// BUG-110 (rc12, "the three strength levels look identical on my TV"): Full's rail is no longer
    /// a special case. `CardDepthStyle.railWidth`/`railStops` now supply the width and the three-stop
    /// gradient at EVERY coverage, so Full finally differs across Subtle/Balanced/Bold by width AND
    /// top-stop brightness, the same as Top/Half always did — see the BUG-110 preset table on
    /// `CardDepthStyle`. A soft halo (`railHaloSpread`/`railHaloAlpha`) trailed the crisp rail at
    /// Balanced/Bold in rc12-rc13; BUG-110 (rc14, Steven rc13 verdict, 2026-09-30) removed it
    /// (`railHaloSpread` is 0, so the `haloSpread > 0` stroke below never draws) and the whole rail is
    /// now skipped on a focused card (`railSuppressed`, see `CardDepthModifier`) so it never doubles
    /// the focus ring. `strokeBorder` insets inward on both layers, so nothing paints
    /// outside `shape` — no `shadow`/`blur` is used here (the FEAT-14 graveyard: outside paint clips
    /// against the artwork frame and lands as a stray sliver in the ring band).
    @ViewBuilder
    private func edgeHighlight(edge: Double, coverage: Double, effectiveEdgeStrength: Int) -> some View {
        let width = CardDepthStyle.railWidth(edgeStrength: effectiveEdgeStrength)
        let stops = CardDepthStyle.railStops(edge: edge, coverage: coverage)
        let haloSpread = CardDepthStyle.railHaloSpread(edgeStrength: effectiveEdgeStrength)

        let rail = ZStack {
            if haloSpread > 0 {
                shape.strokeBorder(
                    Color.white.opacity(CardDepthStyle.railHaloAlpha(edge: edge)),
                    lineWidth: width + 2 * haloSpread
                )
            }
            edgeStroke(top: stops.top, mid: stops.mid, bottom: stops.bottom, lineWidth: width)
        }

        if coverage >= 1 {
            // Full: no mask at all, so the full-perimeter look stays a closed stroke exactly as it
            // has since pre-BUG-31 - only its width and stop values now vary by strength (BUG-110).
            rail
        } else {
            rail.mask { coverageMask(coverage) }
        }
    }

    private func edgeStroke(top: Double, mid: Double, bottom: Double, lineWidth: CGFloat) -> some View {
        shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(top), location: 0),
                    .init(color: .white.opacity(mid), location: 0.5),
                    .init(color: .white.opacity(bottom), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: lineWidth
        )
    }

    /// Vertical mask that makes the edge honor `coverage` geometrically: opaque through a short top
    /// band, fading to clear, and erased outright below — so at Top the highlight arcs over the upper
    /// corners and dies on their shoulders (no side rails, no bottom).
    ///
    ///     fadeEnd(c)   = 0.28 + 0.44·c + 0.28·c²      → 0.28 @ Top, 0.57 @ Half, 1.00 @ Full
    ///     fadeStart(c) = fadeEnd(c) · (0.35 + 0.65·c) → 0.10 @ Top, 0.39 @ Half, 1.00 @ Full
    ///
    /// Both are continuous and monotonic in `c` — the setting is 0…100 and the chips are only presets,
    /// so every intermediate value gets a sensible band. Both converge on 1.0 as c → 1, i.e. the mask
    /// degenerates to "opaque everywhere"; `edgeHighlight` takes that limit exactly by dropping the
    /// mask at Full rather than emitting coincident stops at location 1.
    ///
    /// The fractions are relative to the masked view's own height, and this overlay is sized to the
    /// card's artwork frame (see `nuvioCardDepth`), so the band is measured against the artwork —
    /// which is also why a uniform focus scale on the card can't disturb it: a scale multiplies both
    /// the stroke and its mask by the same factor, leaving every fraction where it was.
    private func coverageMask(_ coverage: Double) -> some View {
        let fadeEnd = min(0.28 + 0.44 * coverage + 0.28 * coverage * coverage, 1)
        let fadeStart = min(fadeEnd * (0.35 + 0.65 * coverage), fadeEnd)
        return LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: fadeStart),
                .init(color: .clear, location: fadeEnd),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Shared strengths are stored 0…100; the Compose port works in 0…1.
    private func unit(_ value: Int) -> Double {
        min(max(Double(value), 0), 100) / 100
    }
}
