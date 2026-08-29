import SwiftUI
import UIKit
import SharedCore

/// Pinned-hero card reach (UX-7 extension, device round 4 of the pinned pass, 2026-08-03).
///
/// On tvOS there is no free momentum scrolling — Siri Remote swipes drive the FOCUS engine and
/// every vertical rest comes from its scroll-to-reveal, which aligns to the focused CARD's
/// frame. Real hardware rests that reveal systematically short (the BUG-30 residual class), so
/// in Home's pinned-hero mode — where the rows viewport hard-clips at the hero boundary — any
/// content ABOVE the focused card's frame (the row's section title, the top band) can end up
/// cut. Rounds 2–3 proved padding OUTSIDE the card frame can never fix this: the reveal simply
/// doesn't include it.
///
/// The fix: rows extend each focusable card's frame UPWARD by this many transparent points
/// (inside the button label, compensated by the row's paddings so nothing moves visually). The
/// reveal target then physically includes the title band — the engine cannot rest a row with
/// its title or art cut. 0 (the default) everywhere except Home's pinned mode, where HomeView
/// sets `Theme.Size.heroPinnedRowTopPad`; at 0 every consuming expression collapses to the
/// original layout, keeping classic byte-identical.
private struct RowCardTopReachKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Downward twin of `rowCardTopReach` (device round 5): scrolling DOWN, the reveal rests short
/// in the mirror direction — the focused card's frame BOTTOM (caption included) lands below the
/// fold and the art's bottom edge is cut. Extending the frame downward by this many transparent
/// points absorbs that shortfall the same way the top reach absorbs the upward one.
private struct RowCardBottomReachKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Home's "Trailer Location: Hero" mode: the focused title's trailer plays in the PINNED HERO
/// backdrop (which already follows focus), so the focused poster must NOT morph into an inline
/// trailer tile — two surfaces cannot share the single player slot, and the hero is the one the
/// user asked for. Set by `HomeView.rowsScroll` from `heroFocusTrailerMode` — settings plus
/// hero-surface existence, which moves at most once per Home lifetime (see that property's doc
/// for why anything churnier would be the BUG-19 identity class).
///
/// Defaults to false so Search — and any other `CatalogRowView` host — keeps the inline morph
/// exactly as it is today, without opting in to anything.
private struct TrailerPlaysInHeroKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowCardTopReach: CGFloat {
        get { self[RowCardTopReachKey.self] }
        set { self[RowCardTopReachKey.self] = newValue }
    }
    var rowCardBottomReach: CGFloat {
        get { self[RowCardBottomReachKey.self] }
        set { self[RowCardBottomReachKey.self] = newValue }
    }
    var trailerPlaysInHero: Bool {
        get { self[TrailerPlaysInHeroKey.self] }
        set { self[TrailerPlaysInHeroKey.self] = newValue }
    }
}

// MARK: - Home geometry probes (BUG-30 / BUG-37)

/// Runtime knob shared by every Home geometry probe — all of them log with the `[HomeScrollProbe]`
/// prefix, so one device walk produces one greppable stream:
///
///     defaults write com.nuvio.media.NuvioTV debug.homeScrollProbe -bool YES
///
/// Read ONCE at launch: a disabled probe costs a single Bool for the whole session, because every
/// probe is a modifier that simply isn't attached when this is false (see `pinnedRowTitleTracking`
/// here and `HomeScrollProbeModifier` in HomeView).
///
/// Deliberately NOT `#if DEBUG`, matching the existing BUG-30 probe it now backs: there is no
/// automated input path to the physical Apple TV, so every device pass is a manual walk that may
/// well be a release-configuration sideload, and the console is the only diagnostic that comes
/// back (same precedent as `ProfilesViewModel.select(_:)`).
enum HomeGeometryProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.homeScrollProbe")
}

// MARK: - Pinned row title tracking (BUG-37)

/// Keeps a PINNED row's overlaid section title inside the rows viewport at every rest position the
/// DEVICE produces, not just the exact ones the simulator produces.
///
/// Why round 8's compromise wasn't enough. The title is overlaid `heroPinnedRowTitleInset` (48)
/// below the SHELF's top; the focusable card frame the engine's scroll-to-reveal aligns starts
/// `Spacing.lg` (24) below that same shelf top, inside the shelf's own padding. So the static
/// margin between "the engine rested the card frame's top at the viewport edge" and "the title's
/// top" is 48 − 24 = 24pt — round 8 read the inset against the shelf and recorded it as ~48. The
/// device's measured rest error is 40–67pt short (`[HomeScrollProbe]`, 1,603 samples, 2026-08-02:
/// rest y=-90 vs true top -157), so the title clears on the sim and is cut on hardware.
///
/// Why NOT card-anchoring the title (moving it inside the button's label), which is the obvious
/// "it moves with the card" fix. It buys nothing here: the shelf never scrolls vertically, so the
/// title and the cards are already rigid with respect to each other — re-anchoring changes which
/// edge the inset is measured from, not the geometry. The band above the art is 96pt whichever
/// anchor you pick, the title is ~40pt, so the best static margin either way is ~32pt, still under
/// the envelope. And it would spend the structural invariants rounds 5–7 paid for: label content
/// has to be compensated by paddings that stay POSITIVE (negative compensation put focusable
/// frames outside their `.focusSection()` and froze directional resolution), a per-card overlay
/// would draw the title once per card, and any extra band means a reach above 72 — the sim
/// bisected 100 as where focus resolution dies.
///
/// What happens instead: the title stays exactly where round 8 put it at a true rest, and slides
/// DOWN by however much the viewport's top edge has eaten into it, clamped to
/// `heroPinnedRowTitleMaxSlide`. BUG-61 (beta.12) changed the HOW, not the WHAT: the slide is now
/// measured via `onGeometryChange` and applied as an eased offset (see `PinnedRowTitleTracking`)
/// instead of a draw-time `visualEffect`, because the draw-time recompute snapped the title in one
/// frame whenever a focus-driven reveal shifted layout discretely. The `@State` this introduces is
/// change-gated and confined to the title's own subtree — rows resting clear of the clip edge
/// measure a constant 0 and write nothing, so the BUG-19 no-identity-churn rule still holds. At
/// 0pt of rest error nothing moves and the look is byte-identical to beta.10; across the whole
/// 0–67pt envelope the title parks against the clip edge instead of disappearing behind it; past
/// the clamp (a row scrolled well above the focused one) it releases and scrolls away like any
/// other content, i.e. it behaves as a sticky header for exactly as long as its row is on screen.
///
/// Contract note for `CollectionRowView` (CollectionsUI.swift, same overlay pattern via the same
/// environment values): the contract is UNCHANGED — the title is still an overlay on the shelf at
/// the same inset — so that row keeps working untouched, it simply keeps the round-8 behavior. The
/// follow-up is one line: add `.pinnedRowTitleTracking(rowKey: collection.id)` to its overlaid
/// `Text` immediately before the existing `.padding(.top, Theme.Size.heroPinnedRowTitleInset)`.
enum PinnedRowTitle {
    /// Name Home attaches to its rows ScrollView (`rowsScroll`) purely as a resolution fallback
    /// for `visibleBounds` below. Also the name `CollectionRowView`'s follow-up inherits for free.
    nonisolated static let rowsScrollSpace = "home_rows_scroll"

    /// The rows viewport's rect, converted into the TITLE's local space — so `minY > 0` reads
    /// directly as "the viewport's top edge is this far BELOW the title's top", i.e. exactly this
    /// much of the title is currently clipped away.
    ///
    /// Primary lookup is the enclosing VERTICAL scroll view (the row's own shelf is horizontal, so
    /// the axis filter skips it). The named fallback covers the case where that filter doesn't
    /// resolve through the nested shelf: a miss on both is fail-safe (no slide = exactly today's
    /// behavior) but silent, so the probe logs nothing for titles — which is itself the signal
    /// that the lookup, not the geometry, is what needs looking at.
    nonisolated static func visibleBounds(_ proxy: GeometryProxy) -> CGRect? {
        proxy.bounds(of: .scrollView(axis: .vertical)) ?? proxy.bounds(of: .named(rowsScrollSpace))
    }

    /// BUG-53/BUG-60 device calibration (beta.12): the whole cluster's remaining dial — how far a
    /// title may ride over its row's artwork — is a function of the DEVICE's rest error, which the
    /// sim cannot reproduce (sim rests park the title clear of the art; the 40–67pt device error
    /// parks it 8–35pt onto it, and under the focused card's system lift). Rather than shipping a
    /// blind constant into the most regression-prone surface, the clamp is overridable at runtime.
    /// Simulator:
    ///
    ///     xcrun simctl spawn <udid> defaults write com.nuvio.media.NuvioTV debug.pinnedTitleMaxSlide -float 40
    ///
    /// Physical Apple TV (Codex gate 1: `defaults write` on the Mac never reaches the device's
    /// sandbox) — pass it as a LAUNCH ARGUMENT; `UserDefaults.standard` consults the argument
    /// domain (`-key value` argv pairs) before every other domain, so this same read picks it up:
    ///
    ///     xcrun devicectl device process launch --terminate-existing --device <udid> \
    ///         com.nuvio.media.NuvioTV -debug.pinnedTitleMaxSlide 40
    ///
    /// so the manual device pass can bisect the visible trade (title clipping at the top vs title
    /// riding over art) live, without rebuild cycles. Unset/0 = the shipped constant. Read once at
    /// launch, same as every other probe knob.
    nonisolated static let maxSlideOverride: CGFloat? = {
        let v = UserDefaults.standard.double(forKey: "debug.pinnedTitleMaxSlide")
        return v > 0 ? CGFloat(v) : nil
    }()

    /// The slide cap resolved for ONE row, in that row's own units.
    ///
    /// Wave 4 item 6 (tester report `docs/steven-batch-plan-2026-08-29.md`, "the section title
    /// slides down over the cards", worst on his Streaming Services collection folder tiles): the
    /// cap used to be the bare `heroPinnedRowTitleMaxSlide` (72) — a fixed number with no knowledge
    /// of the card it rides over. The slide is not what the viewer judges, though; the INTRUSION is
    /// — how far the title's bottom edge ends up past the artwork's top edge:
    ///
    ///     clearance = artworkTop − (titleInset + titleHeight)
    ///               = (Spacing.lg + reach) − (48 + ~38)
    ///               = (24 + 88) − 86  ≈  26pt          // static gap, title bottom → art top
    ///     intrusion = slide − clearance                //  = 46pt at the old fixed 72 cap
    ///
    /// and 46pt is 16.7% of a Small poster's 275pt art, 22.7% of a 203pt landscape card, and 25.1%
    /// of a Small square/landscape FOLDER TILE (183pt — `FolderTile.artworkHeight` takes the height
    /// of those shapes from `style.width`, correctly: they are a true square / true 16:9 of the
    /// row's width, so they are simply SHORTER than a poster). On a folder tile that slice lands on
    /// a centred wordmark rather than a poster's usually-empty top margin. Full arithmetic table in
    /// `Theme.Size.heroPinnedRowTitleArtIntrusionFraction`.
    ///
    /// So the cap becomes proportional to the artwork it rides over:
    ///
    ///     cap = min(heroPinnedRowTitleMaxSlide,
    ///               clearance + artworkHeight × heroPinnedRowTitleArtIntrusionFraction)
    ///
    /// i.e. the intrusion is capped at 9% of the row's art while the proven 72pt absolute still
    /// bounds everything (a very tall row can never buy a bigger slide than the focus band was ever
    /// shown to tolerate). Because the cap is `clearance + budget` it can never fall BELOW the
    /// clearance a settled rest needs — the deterministic beta.12 rest (title bottom exactly at the
    /// art top) is byte-identical at every Poster Size; only deeply-clipped rows give up slide.
    ///
    /// `titleHeight` comes from the title's own proxy rather than a constant, so Bold Text and
    /// larger type shrink the clearance term the same way they shrink the real gap. `artworkHeight`
    /// is nil for a call site that cannot size itself confidently — then only the absolute cap
    /// applies, i.e. exactly the pre-Wave-4 behavior. `cardTopReach` is the row's reach band; the
    /// `Spacing.lg` half of `artworkTop` is the shelf's own vertical padding, which every pinned
    /// row shares (CatalogRowView / UpcomingRow / Continue Watching `.padding(.vertical, .lg)`,
    /// CollectionRowView `.padding(.top, .lg)` in pinned mode).
    ///
    /// `maxSlideOverride` deliberately BYPASSES the proportional term: that knob exists so a manual
    /// device pass can bisect the visible trade live, and a clamp that silently overrode it would
    /// make the knob a no-op at every value above the proportional cap.
    ///
    /// PROBE-ONLY as of Codex 2026-08-29 P1: `slide()` no longer clamps with this value — binding
    /// a sub-absolute cap clips the title at deep rests (visibility beats bounded intrusion). The
    /// probe still reports it as `cap=` so hardware passes can quantify per-row intrusion.
    nonisolated static func maxSlide(titleHeight: CGFloat,
                                     artworkHeight: CGFloat?,
                                     cardTopReach: CGFloat) -> CGFloat {
        if let override = maxSlideOverride { return override }
        let absolute = Theme.Size.heroPinnedRowTitleMaxSlide
        guard let artworkHeight, artworkHeight > 0 else { return absolute }
        let artworkTop = Theme.Spacing.lg + cardTopReach
        let clearance = max(artworkTop - (Theme.Size.heroPinnedRowTitleInset + titleHeight), 0)
        let intrusionBudget = artworkHeight * Theme.Size.heroPinnedRowTitleArtIntrusionFraction
        return min(absolute, clearance + intrusionBudget)
    }

    /// How far the title must ride DOWN to stay fully inside the rows viewport, clamped.
    /// `proxy` must be the TITLE's own geometry (local origin = the title's top-left, `size` = the
    /// title's own rendered size). The defaults reproduce the pre-Wave-4 clamp exactly, so any call
    /// site that cannot state its artwork height keeps today's behavior.
    nonisolated static func slide(_ proxy: GeometryProxy,
                                  artworkHeight: CGFloat? = nil,
                                  cardTopReach: CGFloat = Theme.Size.heroPinnedRowTopPad) -> CGFloat {
        slideMeasurement(proxy, artworkHeight: artworkHeight, cardTopReach: cardTopReach) ?? 0
    }

    /// Optional-returning twin of `slide` (Wave 4 item 6, `docs/steven-batch-plan-2026-08-29.md`):
    /// `slide()` collapses "couldn't measure" (no enclosing scroll view resolved yet — e.g. mid a
    /// mixed-shape row's lazy relayout) and "measured, and the true slide is 0" into the same `0`
    /// return, which is correct for `slide()`'s two callers — the pre-seed draw-time branch (no
    /// prior state to hold, so 0 is the right default) and the probe (a blank measurement is
    /// already dropped by its own `guard`). It is NOT correct for `PinnedRowTitleTracking`'s
    /// `onGeometryChange`: that call site persists whatever it's handed into `@State`, so a
    /// transient nil read there un-parks a title that was correctly slid — a snap-then-flash the
    /// tester's scroll-right-then-up repro would see as the title jumping onto the clip edge and
    /// back. This variant lets that one caller tell the two cases apart and hold the previous
    /// value on nil instead of overwriting it with a false 0.
    nonisolated static func slideMeasurement(_ proxy: GeometryProxy,
                                             artworkHeight: CGFloat? = nil,
                                             cardTopReach: CGFloat = Theme.Size.heroPinnedRowTopPad) -> CGFloat? {
        guard let visible = visibleBounds(proxy) else { return nil }
        // The BINDING cap stays the absolute one (Codex 2026-08-29 P1): any cap below the rest's
        // real minY trades intrusion for CLIPPING — the title parks partially off-screen, the
        // original BUG-37 complaint class — and a settled rest deep enough to intrude is itself
        // the bug (a stale reveal after a mixed-shape row's lazy relayout; see the scroll-repro
        // trace in docs/steven-batch-plan-2026-08-29.md). Visibility wins; the proportional cap
        // below (`maxSlide`) stays PROBE-ONLY so device passes can read how far each rest
        // actually intruded per row and size until the settle-level fix removes the deep rests.
        return min(max(visible.minY, 0), maxSlideOverride ?? Theme.Size.heroPinnedRowTitleMaxSlide)
    }

    /// Signed clearance between the title's top and the viewport's top edge BEFORE sliding —
    /// negative means the rest fell short far enough to cut the title (BUG-37 reproducing).
    /// Probe-only.
    nonisolated static func rawMargin(_ proxy: GeometryProxy) -> CGFloat? {
        visibleBounds(proxy).map { -$0.minY }
    }
}

extension View {
    /// Applies the BUG-37 slide, plus (knob on) the measurement the manual device pass needs.
    /// Attach to the TITLE TEXT ITSELF, BEFORE its `.padding(.top,)` — the modifier reads the
    /// text's own frame, so padding applied first would shift what it measures.
    ///
    /// `artworkHeight` is the row's RESTING artwork height (art only — the caption slot is below
    /// the art and irrelevant to an intrusion measured at its top edge), which is what makes the
    /// slide clamp proportional to the card instead of a fixed 72pt against a scaled one — see
    /// `PinnedRowTitle.maxSlide`. Rows whose cards are a single known shape can state it directly
    /// (`CatalogRowView`); a mixed-shape row states its SHORTEST card (`CollectionRowView`), which
    /// is the tile the clamp must protect. Leaving it nil is the documented opt-out for a call site
    /// that cannot size itself confidently: the absolute cap alone then applies, exactly as before
    /// this parameter existed (`UpcomingRow`, Home's Continue Watching — both fixed-height
    /// `LandscapeCard` shelves whose height the focus-engine regime pins, so sizing them is a
    /// separate, device-gated call).
    func pinnedRowTitleTracking(rowKey: String, artworkHeight: CGFloat? = nil) -> some View {
        modifier(PinnedRowTitleTrackingStyleGate(rowKey: rowKey, artworkHeight: artworkHeight))
    }
}

/// P-3 (beta.15): `PinnedRowTitleTracking`'s `slide`/`hasSeeded` `@State` is seeded from the row's
/// geometry and then only *updates* after the next `onGeometryChange` pass. A Poster Style change
/// (width/height, landscape toggle, caption visibility) re-lays out every row's cards in the same
/// frame the state is still holding the PRE-change offset, so the title renders on top of the
/// artwork for one frame and then heals over 0.22s — the tester-reported flash, prior form
/// BUG-60/61. This thin wrapper reads `PosterStyle` and gives the inner modifier a fresh `.id()`
/// whenever the geometry-relevant fields change, so SwiftUI discards `slide`/`hasSeeded` instead
/// of carrying them across the relayout: the very first frame after a style change then takes
/// `PinnedRowTitleTracking`'s own pre-seed, draw-time branch (see its comment — correct by
/// construction), so there is no stale offset to heal away from and no flash to see.
///
/// `styleKey` deliberately covers only `width`, `height`, `landscapeCatalogRows`, and `showTitle`
/// — the fields that change a row's CARD FRAMES (width/height, landscape aspect) or a card's total
/// height (the caption line `showTitle` adds/removes), all of which move where the row's content —
/// and therefore the clip edge the title tracks — sits. `cornerRadius` is excluded on purpose: it
/// only changes the background shape's corner, never any dimension that affects layout, so keying
/// on it would discard state (losing the eased-slide animation) on changes that don't need it.
private struct PinnedRowTitleTrackingStyleGate: ViewModifier {
    let rowKey: String
    /// The row's resting artwork height, or nil (absolute cap only) — see `pinnedRowTitleTracking`.
    let artworkHeight: CGFloat?
    @Environment(\.posterStyle) private var style

    /// `art…` joins the key because it is what the Wave 4 clamp is computed from: for every call
    /// site today it is DERIVED from the style fields already keyed here (so it adds no remounts in
    /// practice), but a mixed-shape row can also change it on its own — a synced collection edit
    /// that swaps a poster folder for a square one changes the row's shortest tile without touching
    /// Poster Style — and the seeded offset must not outlive the clamp it was measured under.
    /// Wave 4 item 4 (device round, `docs/steven-batch-plan-2026-08-29.md`): `rowKey` joins the
    /// identity too. Every pinned title used to share one gate id (this struct's own type
    /// identity), which is fine inside a `ForEach` scoped by element identity but not between
    /// CONDITIONAL SIBLINGS — `ContinueWatchingRow` and `UpcomingRow` sit as `if`/conditional
    /// branches in Home's `LazyVStack`, and when one appears or disappears SwiftUI can re-match
    /// the surviving branch's subtree onto the other's old identity, migrating one row's seeded
    /// `slide`/`hasSeeded` state onto a title that was never actually mid-slide. Folding `rowKey`
    /// into the id scopes the reset to the row it actually belongs to.
    private var styleKey: String {
        "\(rowKey)-\(style.width)x\(style.height)-land\(style.landscapeCatalogRows)-title\(style.showTitle)-art\(artworkHeight ?? -1)"
    }

    func body(content: Content) -> some View {
        content
            .modifier(PinnedRowTitleTracking(rowKey: rowKey, artworkHeight: artworkHeight))
            .id(styleKey)
    }
}

private struct PinnedRowTitleTracking: ViewModifier {
    let rowKey: String
    /// Wave 4 item 6: the row's resting artwork height, feeding the proportional slide clamp
    /// (`PinnedRowTitle.maxSlide`). nil = absolute cap only, i.e. the pre-Wave-4 behavior.
    let artworkHeight: CGFloat?
    /// The reach band this row's cards extend upward through — the other half of "where the
    /// artwork's top edge is" (art top = `Spacing.lg` shelf padding + reach). Read from the
    /// environment rather than assumed to be `heroPinnedRowTopPad` so the clamp stays correct if a
    /// host ever runs a different reach; the title only renders at all when this is > 0.
    @Environment(\.rowCardTopReach) private var cardTopReach

    /// BUG-61 (beta.12): the original `visualEffect` recomputed the slide at draw time with no
    /// transaction of its own, so a focus-driven reveal — whose layout shift lands in ONE frame —
    /// snapped the title to its new offset while everything around it eased (measured: ~33pt in
    /// 60ms; the probe recorded 10–13 distinct offsets per walk). The slide target is now
    /// measured via `onGeometryChange` into local state and applied through an explicit eased
    /// transaction, so the title moves on the same kind of curve as the content it tracks.
    ///
    /// Cost note (the BUG-19/BUG-41 rule this must not break): `onGeometryChange` fires only when
    /// the measured value CHANGES, and rows resting clear of the clip edge measure a constant 0 —
    /// so per-frame state writes are confined to the one row actually crossing the edge during a
    /// scroll, and the invalidation is this modifier's tiny subtree (the title Text), not the row.
    @State private var slide: CGFloat = 0
    /// First measurement seeds the offset directly — a row that mounts mid-scroll with a nonzero
    /// slide must start there, not visibly settle into it.
    @State private var hasSeeded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Hoisted to locals so the geometry closures below capture two plain CGFloats instead of
        // this (view-isolated) modifier — the same rule the probe already follows for `rowKey`.
        let clampArtworkHeight = artworkHeight
        let clampReach = cardTopReach
        return content
            // ALL offsetting stays inside `visualEffect` (Codex gate 1, round 2): a plain
            // `.offset` participates in the coordinate conversions the geometry observer below
            // uses, so measuring a view shifted by the state it feeds is a feedback loop that
            // settles half-clipped (measured clip = true clip − applied slide). `visualEffect`
            // applies at render time and is invisible to geometry — the original design's whole
            // point — and its effects are animatable, so the eased `slide` state still
            // interpolates inside the `withAnimation` transaction below.
            //
            // Pre-seed branch: `onGeometryChange` only reports AFTER the first geometry pass, so
            // a title mounting already-clipped would render one frame at offset 0 and then snap.
            // Until the first measurement lands, the draw-time computation carries the offset;
            // the seed stores the same value into `slide`, so the handoff renders no change.
            .visualEffect { effect, proxy in
                effect.offset(y: hasSeeded
                    ? slide
                    : PinnedRowTitle.slide(proxy, artworkHeight: clampArtworkHeight, cardTopReach: clampReach))
            }
            .onGeometryChange(for: CGFloat?.self, of: { proxy in
                PinnedRowTitle.slideMeasurement(proxy, artworkHeight: clampArtworkHeight, cardTopReach: clampReach)
            }, action: { newValue in
                // Wave 4 item 6: a nil reading is "couldn't measure" (the enclosing scroll view
                // hasn't resolved this pass — e.g. a mixed-shape row's lazy relayout mid-settle),
                // never "measured 0". Assigning 0 here would un-park a correctly-slid title for a
                // frame and then heal back — the clipped-title flash class. Hold `slide` at
                // whatever it already is and wait for the next real measurement.
                //
                // This must NOT touch `hasSeeded`: if a nil precedes the very first real
                // measurement, that measurement is still the FIRST one this modifier has ever
                // seen and must still take the seed branch below (store directly, no animation) —
                // skipping the whole action on nil, rather than only skipping the assignment,
                // is what keeps that guarantee for free.
                guard let newValue else { return }
                // Seeding must be recorded even when the first measurement equals the initial 0 —
                // otherwise the first REAL change would take the unanimated seed path and snap,
                // which is the exact defect this modifier exists to remove.
                let isFirst = !hasSeeded
                if isFirst || reduceMotion {
                    // Store BEFORE flipping `hasSeeded` so the frame that switches paths already
                    // carries the measured value in `slide`.
                    slide = newValue
                    hasSeeded = true
                } else if slide != newValue {
                    withAnimation(.easeOut(duration: 0.22)) { slide = newValue }
                }
            })
            .modifier(PinnedRowTitleProbe(rowKey: rowKey,
                                          artworkHeight: artworkHeight,
                                          cardTopReach: cardTopReach,
                                          enabled: HomeGeometryProbe.enabled))
    }
}

/// `[HomeScrollProbe] title row=… margin=… slide=… net=… cap=… intr=…`, so a single manual up-walk
/// MEASURES BUG-37 instead of eyeballing it, per row:
///  - `margin` — title top vs the viewport's top edge BEFORE the slide. Negative is round 8's
///    failure reproducing, and its magnitude is that rest's share of the 0–67pt envelope.
///  - `slide`  — how far this fix moved the title (0 at a true rest).
///  - `net`    — what the viewer actually sees. A negative `net` means the rest exceeded the row's
///    resolved cap. Before Wave 4 that read "the clamp needs raising"; now it is also the EXPECTED
///    reading for a deeply-clipped row, because the cap deliberately stops short of covering the
///    whole envelope rather than push the title further onto the art (see `PinnedRowTitle.maxSlide`).
///    What must still hold at a SETTLED rest is `net ≥ 0` — that is the regression to watch.
///  - `cap`    — the row's resolved clamp (Wave 4): `clearance + 9% of the artwork`, absolute-capped.
///  - `intr`   — how far the title's bottom edge is currently past the artwork's top edge, i.e. the
///    number the tester actually complained about. `≤ 0` means it is clear of the art; the design
///    budget is `artworkHeight × heroPinnedRowTitleArtIntrusionFraction`.
/// Not attached at all when the knob is off, so disabled builds evaluate none of it.
private struct PinnedRowTitleProbe: ViewModifier {
    let rowKey: String
    let artworkHeight: CGFloat?
    let cardTopReach: CGFloat
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            // Captured by value so the geometry closure holds a plain String and two CGFloats
            // rather than this (view-isolated) modifier.
            let key = rowKey
            let clampArtworkHeight = artworkHeight
            let clampReach = cardTopReach
            content.onGeometryChange(for: String.self, of: { proxy in
                guard let margin = PinnedRowTitle.rawMargin(proxy) else { return "" }
                let slide = PinnedRowTitle.slide(proxy, artworkHeight: clampArtworkHeight, cardTopReach: clampReach)
                let cap = PinnedRowTitle.maxSlide(titleHeight: proxy.size.height,
                                                  artworkHeight: clampArtworkHeight,
                                                  cardTopReach: clampReach)
                // Title bottom vs artwork top, in the same shelf-relative units the clamp uses.
                let intrusion = (Theme.Size.heroPinnedRowTitleInset + proxy.size.height + slide)
                    - (Theme.Spacing.lg + clampReach)
                return "row=\(key) margin=\(probeBucket(margin)) slide=\(probeBucket(slide)) net=\(probeBucket(margin + slide)) cap=\(probeBucket(cap)) intr=\(probeBucket(intrusion))"
            }, action: { _, value in
                guard !value.isEmpty else { return }
                NSLog("[HomeScrollProbe] title %@", value)
            })
        } else {
            content
        }
    }
}

/// 2pt buckets. `onGeometryChange` only fires when its value CHANGES, so quantizing turns a
/// per-frame scroll animation into a handful of lines per row per hop while staying an order of
/// magnitude finer than the 40–67pt envelope being measured.
private nonisolated func probeBucket(_ value: CGFloat) -> Int {
    Int((value / 2).rounded()) * 2
}

/// Swift-side navigation value. Kotlin data classes don't conform to Swift `Hashable`, so we wrap the
/// `MetaPreview` and hash on its stable identity (type + id) while still carrying all its fields for
/// the destination's initial render. Shared by Home, Search, and detail "more like this".
struct TitleRoute: Hashable {
    let preview: MetaPreview

    static func == (lhs: TitleRoute, rhs: TitleRoute) -> Bool {
        lhs.preview.id == rhs.preview.id && lhs.preview.type == rhs.preview.type
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(preview.id)
        hasher.combine(preview.type)
    }
}

/// Navigation value for the full-grid "See All" screen. `CatalogTarget` is a Kotlin sealed interface
/// and can't be a `NavigationStack` value directly, so we wrap it — hashing on the section's stable
/// `key` while carrying the title + target for the destination (same approach as `TitleRoute`).
struct CatalogRoute: Hashable {
    let key: String
    let title: String
    let target: any CatalogTarget

    init(section: HomeCatalogSection) {
        self.key = section.key
        self.title = section.title
        self.target = section.target
    }

    static func == (lhs: CatalogRoute, rhs: CatalogRoute) -> Bool { lhs.key == rhs.key }

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Navigation value for a cast/crew member's detail page (TMDB person id + name for the initial
/// render). Only produced when a `MetaPerson` has a `tmdbId`. Hashes on the id.
struct PersonRoute: Hashable {
    let id: Int
    let name: String

    static func == (lhs: PersonRoute, rhs: PersonRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Navigation value for a studio/network browse page (TMDB discover-by-company/network). Only
/// produced when a `MetaCompany` has a `tmdbId`. `isNetwork` picks the TMDB entity kind (networks
/// come from `meta.networks`, studios from `meta.productionCompanies`); `sourceType` is the origin
/// title's type ("movie"/"series"), which orders the rails. Hashes on kind + id.
struct EntityRoute: Hashable {
    let id: Int
    let name: String
    let isNetwork: Bool
    let sourceType: String

    static func == (lhs: EntityRoute, rhs: EntityRoute) -> Bool {
        lhs.id == rhs.id && lhs.isNetwork == rhs.isNetwork
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isNetwork)
    }
}

/// One horizontal catalog (e.g. "Popular Movies", or a search-result group) as a focus-scrollable row
/// of poster cards.
///
/// By default each card is a `NavigationLink` to the title's detail screen (used on Home). Pass
/// `onSelect` to instead handle taps manually — Search uses this to dismiss the keyboard before
/// navigating.
struct CatalogRowView: View {
    /// BUG-13: the Home fetch trims each row to `HOME_CATALOG_PREVIEW_FETCH_LIMIT` items
    /// (HomeRepository.kt) while `availableItemCount` keeps the addon's real first-page count. Rows
    /// built that way must pass this limit so the "See All" gate can spot a truncated catalog.
    static let homePreviewLimit = 18

    let section: HomeCatalogSection
    /// Number of items the producing repository kept for this row, or `nil` when the row already
    /// renders everything it fetched (Search) — then only `hasMore` can open the full grid.
    var previewLimit: Int? = nil
    var onSelect: ((MetaPreview) -> Void)? = nil
    /// UX-7: reports the focused card's item (or nil) so Home can drive the hero from it.
    /// Defaulted and appended last — Search's call site (`CatalogRowView(section:)`) and Home's
    /// (`section:previewLimit:`) both compile unchanged. Gating and backdrop prefetch live in
    /// the callback (HomeView.reportRowFocus), not here.
    var onItemFocusChange: ((MetaPreview?) -> Void)? = nil

    /// Inline trailer previews on focus dwell (see `InlineTrailerCard`). Device-local on purpose —
    /// whether a living-room Apple TV should autoplay trailers is a per-device call, not a synced
    /// account preference. Off by default (opt-in); Settings → Home Screen owns the toggle UI.
    @AppStorage("inline_trailers_enabled") private var inlineTrailersEnabled = false

    /// Which card holds focus. Needed here (rather than inside the card) because tvOS delivers
    /// remote commands to the *focused view chain* — the `Button`/`NavigationLink` below, never its
    /// label — so the play/pause mute toggle has to be attached at this level and gated on "this is
    /// the focused item, and it is the one playing".
    @FocusState private var focusedItemId: String?

    /// Which card currently owns the single inline `AVPlayer`, published by the shared coordinator.
    @ObservedObject private var trailerCoordinator = InlineTrailerCoordinator.shared

    /// BUG-29: an inline-trailer expansion widens its card in place without moving focus, so tvOS's
    /// automatic focus-driven scroll never fires — the row has to scroll itself, and Reduce Motion
    /// governs whether that scroll animates (see `expansionChanged(for:expanded:proxy:)`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// tvOS Accessibility ▸ Motion ▸ Auto-Play Video Previews. When the user has turned previews off
    /// system-wide, the row must render exactly as it did before this feature existed.
    /// The third term is Home's "Trailer Location: Hero" mode (`trailerPlaysInHero`): the trailer
    /// still plays, just in the hero backdrop, so this row must leave its posters alone.
    private var inlineTrailersActive: Bool {
        let active = inlineTrailersEnabled && UIAccessibility.isVideoAutoplayEnabled && !trailerPlaysInHero
        // BUG-55: both gates default OFF, and a fresh container silently resets the toggle — a
        // no-trailers session must say WHY in the log, once per state change, not per render.
        // Hero-location suppression is NOT threaded through this probe: its dedupe is one global
        // tuple, and `trailerPlaysInHero` differs per host (Home true, Search false), so routing
        // it through would flip-flop the "once per state change" contract on every Home↔Search
        // render alternation. HomeView logs its own `[TrailerPipeline] trailerLocation` line on
        // mode changes instead, so a log pull still can't mistake BY-DESIGN suppression for a
        // broken gate.
        InlineTrailerGateProbe.report(enabled: inlineTrailersEnabled, autoplay: UIAccessibility.isVideoAutoplayEnabled)
        return active
    }

    /// BUG-13: an addon whose manifest declares no `skip` extra always reports `hasMore == false`,
    /// even when its single response carried far more titles than the row kept — gating on `hasMore`
    /// alone made those catalogs a dead end. Mirrors composeApp's Home gate, which uses the same
    /// shared `canOpenCatalog(previewLimit:)` (HomeModels.kt: availableItemCount > previewLimit || hasMore).
    private var canOpenFullCatalog: Bool {
        guard let previewLimit else { return section.hasMore }
        return section.canOpenCatalog(previewLimit: Int32(previewLimit))
    }

    /// Pinned-hero card reach (UX-7 extension, device rounds 4–5) — see `rowCardTopReach` /
    /// `rowCardBottomReach` for the mechanism. 0 (no-op) everywhere except Home's pinned mode.
    @Environment(\.rowCardTopReach) private var cardTopReach
    @Environment(\.rowCardBottomReach) private var cardBottomReach

    /// Wave 4 item 6: the RESTING artwork height of this row's cards, handed to the pinned title's
    /// slide clamp so the title's intrusion is a fraction of the card rather than a fixed 46pt of
    /// whatever size the user picked (see `PinnedRowTitle.maxSlide`).
    ///
    /// Mirrors `InlineTrailerCard.artworkHeight`, which is the same expression and — deliberately —
    /// CONSTANT across the inline-trailer morph ("the height never changes so the row never
    /// breathes vertically"), so one number describes the row in both states. The caption slot
    /// (`style.showTitle`) is excluded: it sits BELOW the art and cannot be intruded on from above.
    @Environment(\.posterStyle) private var posterStyle
    private var rowArtworkHeight: CGFloat {
        posterStyle.landscapeCatalogRows ? Theme.Size.landscapeHeight : posterStyle.height
    }

    /// Home's "Trailer Location: Hero" mode — see `trailerPlaysInHero`. False (no-op) everywhere
    /// except Home in that mode, so Search and every other host keeps the inline morph.
    @Environment(\.trailerPlaysInHero) private var trailerPlaysInHero

    /// H3 hardening (BUG-47): the previous version fired-and-forgot a detached `Task` per
    /// expansion. A rapid re-focus while one was still mid-flight (the 450ms deferred correction
    /// pass) left it running loose against a `proxy`/row that could already be torn down by a pop —
    /// scrolling into a `ScrollViewReader` whose `ScrollView` no longer exists. Tracking the task
    /// lets a new expansion supersede the old one and lets `.onDisappear` cancel it outright.
    @State private var expansionScrollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Classic keeps the title as a plain sibling above the shelf. PINNED mode instead
            // overlays the title INSIDE the shelf's top reach band (below) so the focused
            // cards' frames — which the focus engine's scroll-to-reveal aligns — physically
            // contain the title's region. Earlier attempts reached the card frames upward
            // with NEGATIVE compensating paddings; once the reach exceeded the row's own
            // bounds the focused item sat outside its .focusSection() geometry and the
            // engine's directional resolution FROZE outright (sim-reproduced, device rounds
            // 5–7). All-positive paddings keep every frame inside the row.
            //
            // The "See All" affordance is a trailing CARD inside the shelf (device round 5,
            // Christian's call): the old header pill was a focusable stop BETWEEN rows, so
            // vertical focus travel could land on it and reveals would align its tiny frame —
            // degenerate rest positions (sliver rows, floating pill, art cut at the fold).
            if cardTopReach == 0 {
                Text(section.title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.rowGap) {
                        ForEach(section.items, id: \.id) { item in
                            Group {
                                if let onSelect {
                                    Button { onSelect(item) } label: {
                                        card(for: item, proxy: proxy)
                                            .padding(.top, cardTopReach)
                                            .padding(.bottom, cardBottomReach)
                                    }
                                        .cardFocusButtonStyle()
                                        .posterButtonShape()
                                } else {
                                    NavigationLink(value: TitleRoute(preview: item)) {
                                        card(for: item, proxy: proxy)
                                            .padding(.top, cardTopReach)
                                            .padding(.bottom, cardBottomReach)
                                    }
                                    .cardFocusButtonStyle()
                                    .posterButtonShape()
                                }
                            }
                            .focused($focusedItemId, equals: item.id)
                            // Mirrors Detail's hero trailer: the card's mute glyph isn't reachable by
                            // the focus engine, so play/pause is the toggle. Nil unless *this* focused
                            // card is the one playing — an unconditional handler would swallow
                            // play/pause from everything else that wants it (Home's hero).
                            .onPlayPauseCommand(perform: muteToggle(for: item))
                            .id(item.id)
                        }

                        // Trailing "See All" card (see the header comment). Same gate as the
                        // pill had; same route.
                        if canOpenFullCatalog {
                            NavigationLink(value: CatalogRoute(section: section)) {
                                SeeAllCard()
                                    .padding(.top, cardTopReach)
                                    .padding(.bottom, cardBottomReach)
                            }
                            .cardFocusButtonStyle()
                            .posterButtonShape()
                        }
                    }
                    // ALWAYS positive — the reach lives inside the buttons' labels, the row's
                    // frame contains it whole, and nothing pokes outside the focus section.
                    .padding(.vertical, Theme.Spacing.lg)
                }
                .scrollClipDisabled()
                // Pinned: the title floats over the (transparent) reach band at the shelf's
                // top-leading corner — visually where it always was, but INSIDE the region
                // the focused cards' frames cover, so every reveal shows it.
                //
                // BUG-37: "inside the region the frames cover" is necessary but not sufficient on
                // hardware — a rest that falls 40–67pt short leaves the top of that region above
                // the viewport's clip edge, title included. `pinnedRowTitleTracking` rides the
                // title down to the clip edge for exactly that shortfall (render-time only; no
                // layout, no state, no identity). See its doc comment for why the band cannot
                // simply be widened and why card-anchoring the title buys nothing.
                .overlay(alignment: .topLeading) {
                    if cardTopReach > 0 {
                        Text(section.title)
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            // Legibility for the slid state only: at a short rest the title parks
                            // against the clip edge and can overlap the top of the artwork. Over
                            // the flat background of a true rest this is invisible.
                            .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                            .pinnedRowTitleTracking(rowKey: section.key, artworkHeight: rowArtworkHeight)
                            .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .focusSection()
        .onChange(of: focusedItemId) { _, newId in
            onItemFocusChange?(newId.flatMap { id in section.items.first { $0.id == id } })
        }
        // H3: the row (and its ScrollViewReader) can disappear mid-flight — a pop while the
        // deferred 450ms correction pass is still pending. Cancel rather than let it fire against
        // a torn-down proxy.
        .onDisappear { expansionScrollTask?.cancel() }
    }

    /// Portrait poster by default; a 16:9 landscape card when the user enables landscape catalog
    /// rows — both rendered by `InlineTrailerCard`, which also grows the muted trailer preview once
    /// focus rests on the card. With inline trailers off it is a straight pass-through to the same
    /// two cards, so the row is unchanged.
    private func card(for item: MetaPreview, proxy: ScrollViewProxy) -> some View {
        InlineTrailerCard(item: item, enabled: inlineTrailersActive) { expanded in
            expansionChanged(itemId: item.id, expanded: expanded, proxy: proxy)
        }
    }

    /// BUG-29: an inline-trailer expansion morphs the focused card wider **to the right** in place —
    /// focus never moves (it's still the same button), so tvOS never issues its usual focus-driven
    /// scroll, and a card near a row's trailing edge grows straight off the visible strip. Ask the
    /// `ScrollView` to bring the card back into view ourselves whenever it expands; a `nil` anchor
    /// asks for the *minimal* scroll needed, so a card that already fits doesn't jump. Collapsing
    /// needs no help — the row only ever overflows while a card is wide, never while it's back to
    /// poster width.
    ///
    /// Deferred by one runloop hop so the scroll targets the tile's *expanded* geometry: `expanded`
    /// flips the instant the morph starts (`InlineTrailerCardModel.setPhase`), not when it finishes,
    /// so scrolling in the same tick would still measure the old, narrower frame. The morph itself
    /// runs 0.35s (`InlineTrailerCardModel.morphAnimation`), so the deferred scroll still lands well
    /// inside it and the two animate together visually.
    private func expansionChanged(itemId: String, expanded: Bool, proxy: ScrollViewProxy) {
        guard expanded else { return }
        // Device finding (BUG-29 round 2): a nil-anchor scrollTo at morph START is a no-op —
        // the tile's pre-growth frame is still fully visible at that moment, so "minimal
        // scroll" resolves to nothing and the tile then grows off the trailing edge anyway.
        // Two-part fix: the LAST item deterministically needs its trailing edge pinned to the
        // viewport (no geometry read needed), and every other item gets a correction pass
        // AFTER the 0.35s morph settles, when scrollTo finally sees the expanded frame.
        let anchor: UnitPoint? = itemId == section.items.last?.id ? .trailing : nil
        // H3: supersede any still-pending correction pass from a previous expansion rather than
        // letting both race the same proxy.
        expansionScrollTask?.cancel()
        if CatalogGridProbe.enabled { CatalogGridProbe.log("expansionChanged fire item=\(itemId)") }
        expansionScrollTask = Task { @MainActor in
            scrollToExpanded(itemId, anchor: anchor, proxy: proxy)
            try? await Task.sleep(nanoseconds: 450_000_000)
            // H3: the row may have disappeared (or a newer expansion may have superseded this
            // task) during the sleep — bail instead of scrolling a proxy that could be gone.
            guard !Task.isCancelled else {
                if CatalogGridProbe.enabled { CatalogGridProbe.log("expansionChanged cancelled skip item=\(itemId)") }
                return
            }
            scrollToExpanded(itemId, anchor: anchor, proxy: proxy)
        }
    }

    private func scrollToExpanded(_ itemId: String, anchor: UnitPoint?, proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(itemId, anchor: anchor)
        } else {
            withAnimation(InlineTrailerCardModel.morphAnimation) {
                proxy.scrollTo(itemId, anchor: anchor)
            }
        }
    }

    /// Play/pause handler for `item`'s focusable button, or `nil` when this card isn't the focused,
    /// currently-playing one — `.onPlayPauseCommand(perform: nil)` leaves the command to whoever
    /// else is listening instead of consuming it.
    private func muteToggle(for item: MetaPreview) -> (() -> Void)? {
        guard focusedItemId == item.id,
              trailerCoordinator.playingKey == TrailerResolutionCache.key(type: item.type, id: item.id)
        else { return nil }
        return { HeroTrailerAudioState.shared.toggleMuted() }
    }
}

/// The trailing "See All" tile at the end of a catalog row (device round 5 of the pinned-hero
/// pass — replaces the focusable header pill; see CatalogRowView's header comment for why).
/// Shaped like the row's RESTING cards — portrait per the user's Poster Style, or 16:9 landscape
/// when landscape catalog rows are on — so the shelf reads as one continuous strip and vertical
/// focus travel always lands on card-sized frames. When captions are visible, an empty caption
/// slot keeps the tile's art aligned with its neighbors' art. Standard system lift via
/// `tileFocusLift` (BUG-31: it goes still with "No Zoom on Focus", which this tile used to
/// ignore — the row's posters froze while See All kept zooming); in FEAT-14 ring mode the tile
/// deliberately keeps the system treatment — the accent ring marks CONTENT cards, and a
/// utility tile reads fine without it.
struct SeeAllCard: View {
    @Environment(\.posterStyle) private var style

    private var tileWidth: CGFloat {
        style.landscapeCatalogRows ? Theme.Size.landscapeWidth : style.width
    }
    private var tileHeight: CGFloat {
        style.landscapeCatalogRows ? Theme.Size.landscapeHeight : style.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("See All")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(width: tileWidth, height: tileHeight)
            .background(
                Theme.Palette.surfaceElevated,
                in: RoundedRectangle(cornerRadius: style.cornerRadius)
            )
            .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
            .tileFocusLift(cornerRadius: style.cornerRadius)

            if style.showTitle {
                // Empty caption slot: neighbors are art + caption, so without this the
                // LazyHStack's center alignment would float the tile relative to their art.
                Text(verbatim: " ")
                    .font(Theme.Font.cardTitle)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }
}

/// A single poster tile, now backed by the shared `PosterCard` design-system component
/// (cached artwork, shimmer, brand focus ring, focus-aware title).
struct PosterCardView: View {
    let item: MetaPreview

    var body: some View {
        PosterCard(title: item.name, imageURL: item.poster)
    }
}
