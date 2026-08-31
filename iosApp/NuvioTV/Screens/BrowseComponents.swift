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
        let intrusionBudget = artworkHeight * Theme.Size.heroPinnedRowTitleArtIntrusionFraction
        return min(absolute, staticClearance(titleHeight: titleHeight, cardTopReach: cardTopReach) + intrusionBudget)
    }

    /// How far the title's BOTTOM edge sits above the artwork's TOP edge at a true rest (slide 0)
    /// — the free travel a slide has before it starts painting on the card:
    ///
    ///     clearance = artworkTop − titleBottom
    ///               = (Spacing.lg + reach) − (titleInset + titleHeight)
    ///               = (24 + 88) − (48 + ~38)  ≈  26pt
    ///
    /// and therefore `intrusion = slide − clearance` exactly. Factored out of `maxSlide` (which has
    /// computed it inline since Wave 4) so the settle re-reveal targets the SAME number rather than
    /// a second, drifting copy of the arithmetic — Codex r1 P1: gating the correction on raw
    /// `margin < 0` fired on a `margin=-25 net=0` rest whose title was still fully clear of the
    /// art, and would have nudged ordinary Medium/Small rests (`margin=-40 slide=40 net=0`).
    ///
    /// `titleHeight` is the title's own MEASURED height, not a constant, so Bold Text and larger
    /// type shrink this the same way they shrink the real gap.
    ///
    /// This is the AT-REST number. What the viewer judges is the FOCUSED card's clearance — see
    /// `Clearances` — because the card the title rides over is the one the system lift has raised.
    nonisolated static func staticClearance(titleHeight: CGFloat, cardTopReach: CGFloat) -> CGFloat {
        let artworkTop = Theme.Spacing.lg + cardTopReach
        return max(artworkTop - (Theme.Size.heroPinnedRowTitleInset + titleHeight), 0)
    }

    /// One row's two clearances. Both are "title bottom → artwork top at slide 0"; they differ by
    /// which card is being measured against (Codex r4 P1).
    ///
    ///     atRest  = (Spacing.lg + reach) − (titleInset + titleHeight)      ≈ 26pt
    ///     focused = max(atRest − lift, 0)
    ///
    /// The focus treatment raises the FOCUSED card's artwork while the title stays put, so the
    /// card the title actually rides over has that much less room than the row's resting geometry
    /// suggests. Every version before r4 targeted `atRest`, which meant the corrected fixpoint
    /// still left the focused card's artwork under the title — a passing gate alongside the
    /// tester's reported overlap. The correction budget and the visibility belt both work in
    /// `focused` now; `atRest` survives as the probe's pre-lift reading, as the clearance an
    /// UNFOCUSED row is judged by (nothing has raised its cards — Codex r7 P2), and as the term
    /// `maxSlide`'s (probe-only) proportional cap has always used.
    // `nonisolated`: same @Sendable-transform requirement as `Reading` below.
    nonisolated struct Clearances: Equatable, Sendable {
        var atRest: CGFloat
        var focused: CGFloat
        /// What was subtracted — `focusLiftAllowance` for the ACTIVE focus mode. Carried so the
        /// settle log can name it: `focused` alone hides the magnitude once the clamp bites.
        var lift: CGFloat
    }

    /// Which focus treatment a ROW's cards actually wear — not every pinned row's cards resolve
    /// through `CardFocusMode` (Codex r9 P2).
    // `nonisolated`: same @Sendable-transform requirement as `Reading` below.
    nonisolated enum RowCardTreatment: Equatable, Sendable {
        /// Cards that go through `CardFocusTreatment`, so their lift follows
        /// `CardFocusMode.resolve` in all three modes: `PosterCard` (catalog rows, PosterCard.swift
        /// ~L604) and `LandscapeCard` (Continue Watching, Upcoming — PosterCard.swift ~L766).
        case cardTreatment
        /// Cards whose zoom-on branch is a bare `.borderless` button and nothing else, so they get
        /// the NATIVE system lift whatever the accent-ring setting says.
        ///
        /// This is the collection folder-tile row (`CollectionsUI.swift` ~L169-184). `FolderTile`
        /// draws its own still-mode shrink-and-ring and never adopts `CardFocusTreatment`, so
        /// `.manualScale` simply does not exist for it — `cardFocusButtonStyle`'s zoom-on branch is
        /// "exactly the bare `.borderless` it always was" (PosterCard.swift ~L87-98). Treating it
        /// as `.manualScale` computed a scale-derived lift off the row's SHORTEST tile, which is
        /// smaller than the ~20pt native lift the focused folder actually gets — an
        /// under-correction that left the title on the focused folder's artwork with the ring on.
        case plainBorderless
    }

    /// The two Appearance settings `CardFocusMode.resolve` branches on, carried as a value so the
    /// lift computation can be driven by a REACTIVE read rather than by whatever the defaults
    /// happened to say the last time geometry moved (Codex r10 P2).
    ///
    /// The staleness this closes: flipping "No Zoom on Focus" or the accent ring in Settings and
    /// coming back to Home changes no geometry — Home is alive in the tab view and its rows have
    /// not moved — so the title's `onGeometryChange` transform need never run again, and the
    /// clearance published to `PinnedRowSettle` would keep describing the PREVIOUS mode
    /// indefinitely: wrong correction target, wrong fade threshold, until something happened to
    /// scroll. `PinnedRowTitleTracking` reads both keys as `@AppStorage` and republishes on change;
    /// see `current` for what the remaining bare reads are for.
    // `nonisolated`: same @Sendable-transform requirement as `Reading` below.
    nonisolated struct FocusModeFlags: Equatable, Sendable {
        var noZoom: Bool
        var accentRing: Bool

        /// Live snapshot for call sites with no SwiftUI context to observe from. This is the
        /// DEFAULT, not the primary path: every call that matters — `reading` from the tracking
        /// modifier, and the probe — is handed explicit `@AppStorage`-backed flags, and it is the
        /// modifier-side republish that keeps `PinnedRowSettle.clearances` coherent with them.
        nonisolated static var current: FocusModeFlags {
            FocusModeFlags(noZoom: UserDefaults.standard.bool(forKey: "no_zoom_on_focus"),
                           accentRing: UserDefaults.standard.bool(forKey: "accent_focus_ring"))
        }
    }

    /// How far the ACTIVE focus treatment raises a focused card's artwork (Codex r7 P1).
    ///
    /// This used to be the flat `heroPinnedRowFocusLiftAllowance` for everyone, which is only
    /// right in one of the three modes — and wrong in the worst direction for the mode the
    /// reporting tester actually runs. `CardFocusMode.resolve` (PosterCard.swift ~L237) branches on
    /// the same two Appearance settings, so this mirrors that resolution exactly:
    ///
    ///  - **still** (`no_zoom_on_focus` on, either ring state) — Wave 7 made this genuinely zero
    ///    lift: a custom `ButtonStyle` that never receives the system hover effect, and a treatment
    ///    that draws a border and a shadow and scales nothing. Charging 20pt here fabricated 20pt
    ///    of intrusion out of nothing: every rest was over-corrected by 20pt and titles that were
    ///    perfectly clear could be faded out by the belt.
    ///  - **manualScale** (ring on, zoom on) — a `.scaleEffect(cardSystemLiftScale)` on the WHOLE
    ///    LOCKUP, centred, so the top edge rises by half the scale delta over the lockup's height
    ///    (`CardFocusTreatment.manualScale`). Lockup = artwork + the chrome below it, hence
    ///    `cardLockupCaptionChrome`.
    ///  - **systemLift** (both off) — the native hover effect on the artwork container, measured at
    ///    `heroPinnedRowFocusLiftAllowance` (test44, 2026-08-25).
    ///
    /// Read at MEASUREMENT time from the two plain `UserDefaults` keys the treatments use as
    /// `@AppStorage`, not latched at launch: both are live Appearance toggles. A settings change
    /// therefore takes effect on the row's next reading pass rather than instantly — which is the
    /// same frame the cards themselves re-render in, so nothing can be seen mid-flip. Two
    /// `UserDefaults.standard.bool` reads per measured title per layout pass is a dictionary
    /// lookup in an in-process cache; at the handful of pinned titles on screen it does not
    /// register against the frame budget.
    ///
    /// `artworkHeight` nil (a call site that cannot size itself) falls back to the systemLift
    /// constant in ring mode — the same documented opt-out `maxSlide` already uses.
    nonisolated static func focusLiftAllowance(artworkHeight: CGFloat?,
                                               captionVisible: Bool,
                                               treatment: RowCardTreatment,
                                               mode: FocusModeFlags = .current) -> CGFloat {
        // Zero lift under "No Zoom on Focus" for BOTH treatments, and checked first exactly as
        // `CardFocusMode.resolve` does — no-zoom wins over the ring everywhere. Card treatments get
        // `.still` (nothing scales); folder tiles get `cardFocusButtonStyle`'s `StillCardButtonStyle`
        // + `focusEffectDisabled`, which likewise cannot lift.
        if mode.noZoom { return 0 }
        // A bare `.borderless` card wears the native system lift and has no ring-mode branch at
        // all, so the accent-ring setting is irrelevant to it — see `RowCardTreatment`.
        guard treatment == .cardTreatment else {
            return Theme.Size.heroPinnedRowFocusLiftAllowance
        }
        guard mode.accentRing else {
            return Theme.Size.heroPinnedRowFocusLiftAllowance      // .systemLift
        }
        // .manualScale
        guard let artworkHeight, artworkHeight > 0 else {
            return Theme.Size.heroPinnedRowFocusLiftAllowance
        }
        let lockupHeight = artworkHeight + (captionVisible ? cardLockupCaptionChrome : 0)
        return (cardManualLiftScale - 1) / 2 * lockupHeight
    }

    /// Mirror of `cardSystemLiftScale` (PosterCard.swift ~L190), which is a file-private `let`
    /// there and cannot be referenced from here. **Keep the two in step** — if that measurement
    /// moves, move this. Drift is not silent: test44 measures the real constant against the system
    /// lift, so a change shows up there first.
    nonisolated static let cardManualLiftScale: CGFloat = 1.12

    /// Vertical chrome a poster lockup carries BELOW its artwork, which `manualScale` scales along
    /// with it: `Theme.Spacing.md` (16, `PosterCard`'s artwork↔caption gap) plus one
    /// `Theme.Font.cardTitle` caption line (≈27.5 as rendered). ≈43.5pt, which is exactly the
    /// residue in the 2026-08-30 measurement of the focusable link frame — `artworkHeight + 175.5`
    /// = topReach (88) + lockup + bottomReach (44) ⇒ lockup = artworkHeight + 43.5.
    ///
    /// A constant rather than a live type metric because it only feeds a lift ALLOWANCE, never
    /// layout: at `cardManualLiftScale` it is worth 2.6pt of lift, below the belt's own 4pt arm
    /// threshold. Mixed-shape collection rows (whose tiles use `Spacing.sm` and a per-folder
    /// `hideTitle`) are approximated by the same number for the same reason.
    nonisolated static let cardLockupCaptionChrome: CGFloat = 43.5

    nonisolated static func clearances(titleHeight: CGFloat,
                                       cardTopReach: CGFloat,
                                       artworkHeight: CGFloat?,
                                       captionVisible: Bool,
                                       treatment: RowCardTreatment,
                                       mode: FocusModeFlags = .current) -> Clearances {
        let atRest = staticClearance(titleHeight: titleHeight, cardTopReach: cardTopReach)
        let lift = focusLiftAllowance(artworkHeight: artworkHeight,
                                      captionVisible: captionVisible,
                                      treatment: treatment,
                                      mode: mode)
        return Clearances(atRest: atRest, focused: max(atRest - lift, 0), lift: lift)
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
    /// The `captionVisible`/`rowIsFocused` defaults are deliberately not threaded here: `slide`
    /// depends on neither (it is `min(max(visible.minY, 0), cap)`), and those two only steer the
    /// belt's clearance choice. This wrapper's callers want the offset, nothing else.
    nonisolated static func slideMeasurement(_ proxy: GeometryProxy,
                                             artworkHeight: CGFloat? = nil,
                                             cardTopReach: CGFloat = Theme.Size.heroPinnedRowTopPad) -> CGFloat? {
        reading(proxy, artworkHeight: artworkHeight, cardTopReach: cardTopReach)?.slide
    }

    /// One title's tracked state: the eased slide, this row's static clearance, and the visibility
    /// belt's two hysteresis edges.
    ///
    /// Why the belt's condition is carried as two BOOLs rather than the raw `margin` they are
    /// derived from (load-bearing — `PinnedRowTitleTracking`'s cost note depends on it):
    /// `onGeometryChange` fires whenever its observed value CHANGES, and a row resting clear of the
    /// clip edge measures `slide == 0`, `hideCandidate == false`, `showAgain == true` at EVERY
    /// scroll position. Carrying `margin` itself would instead fire the observer once per frame for
    /// every visible row — exactly the per-frame churn the BUG-19/BUG-41 rule forbids. The settle
    /// re-reveal, which does need the raw numbers, measures the ROW instead
    /// (`pinnedRowSettleTracking`) and only while that row holds focus.
    // `nonisolated`: consumed inside `onGeometryChange`'s @Sendable transform — under the
    // project's default-MainActor isolation the synthesized Equatable conformance would
    // otherwise be actor-isolated and unable to satisfy the Sendable type parameter.
    nonisolated struct Reading: Equatable, Sendable {
        var slide: CGFloat
        /// This row's two clearances (`Clearances`), published onward to the settle re-reveal,
        /// which needs them to target artwork intrusion rather than raw margin but has only the
        /// ROW's frame to measure — the title's rendered height lives here. Constant for a given
        /// row and type size, so carrying them adds no `onGeometryChange` fires.
        var clearances: Clearances
        /// ARM edge of the belt's hysteresis: this title is in a state a viewer would call broken
        /// — clipped past the slide cap (`net < 0`), or riding more than `fadeIntrusionArm` onto
        /// the FOCUSED card's artwork — AND still on screen to be seen doing it.
        var hideCandidate: Bool
        /// RECOVER edge: fully inside the viewport AND clear of the focused card's artwork.
        /// Strictly stronger than `!hideCandidate`; the band between the two is where the belt
        /// holds whatever it has, so a rest sitting exactly at the corrected fixpoint
        /// (`liftedIntrusion == 0`) can never flicker.
        var showAgain: Bool
        /// How far the title's bottom currently sits past THIS row's artwork top, judged against
        /// the clearance its own cards are actually in (lifted while focused, at rest otherwise).
        /// Carried for the belt's probe lines; it is an affine function of `slide`, which is
        /// already here, so it adds no `onGeometryChange` fires of its own.
        var intrusion: CGFloat
    }

    /// The two geometry inputs a `Reading` is computed from, cached by `PinnedRowTitleTracking` so
    /// a mode change can recompute one WITHOUT a new geometry pass (Codex r10 P2).
    // `nonisolated`: same @Sendable-transform requirement as `Reading` above.
    nonisolated struct TitleGeometry: Equatable, Sendable {
        /// The rows viewport's top edge in the title's own space — `+` means that much of the
        /// title is currently clipped away.
        var visibleMinY: CGFloat
        /// The title's own rendered height.
        var titleHeight: CGFloat
    }

    /// `slideMeasurement`'s full form. `nil` means "couldn't measure" (see `slideMeasurement`'s
    /// doc for why that must never be collapsed into a measured 0).
    nonisolated static func reading(_ proxy: GeometryProxy,
                                    artworkHeight: CGFloat? = nil,
                                    cardTopReach: CGFloat = Theme.Size.heroPinnedRowTopPad,
                                    captionVisible: Bool = true,
                                    rowIsFocused: Bool = false,
                                    treatment: RowCardTreatment = .cardTreatment,
                                    mode: FocusModeFlags = .current) -> Reading? {
        guard let visible = visibleBounds(proxy) else { return nil }
        return reading(geometry: TitleGeometry(visibleMinY: visible.minY,
                                               titleHeight: proxy.size.height),
                       artworkHeight: artworkHeight,
                       cardTopReach: cardTopReach,
                       captionVisible: captionVisible,
                       rowIsFocused: rowIsFocused,
                       treatment: treatment,
                       mode: mode)
    }

    /// The pure core, split out of the proxy form so the tracking modifier can re-derive a Reading
    /// from CACHED geometry when only the focus mode changed — a Settings toggle moves nothing, so
    /// there may be no next geometry pass to recompute in (Codex r10 P2).
    nonisolated static func reading(geometry: TitleGeometry,
                                    artworkHeight: CGFloat?,
                                    cardTopReach: CGFloat,
                                    captionVisible: Bool,
                                    rowIsFocused: Bool,
                                    treatment: RowCardTreatment,
                                    mode: FocusModeFlags) -> Reading {
        let visibleMinY = geometry.visibleMinY
        let titleHeight = geometry.titleHeight
        // The BINDING cap stays the absolute one (Codex 2026-08-29 P1): any cap below the rest's
        // real minY trades intrusion for CLIPPING — the title parks partially off-screen, the
        // original BUG-37 complaint class — and a settled rest deep enough to intrude is itself
        // the bug (a stale reveal after a mixed-shape row's lazy relayout; see the scroll-repro
        // trace in docs/steven-batch-plan-2026-08-29.md). Visibility wins; the proportional cap
        // below (`maxSlide`) stays PROBE-ONLY so device passes can read how far each rest
        // actually intruded per row and size until the settle-level fix removes the deep rests.
        let cap = maxSlideOverride ?? Theme.Size.heroPinnedRowTitleMaxSlide
        let slide = min(max(visibleMinY, 0), cap)
        // `net = margin + slide = −visibleMinY + slide`, so `overshoot = −net` and `net < 0` ⇔
        // the rest ate more than the cap can give back.
        let overshoot = visibleMinY - slide
        // Keeps the belt scoped to titles the viewer can still SEE: a row scrolled well above the
        // focused one is also past the cap (and saturated, so its intrusion reads as the full
        // 46pt), but it is simply scrolling away as designed (see this enum's header) and must not
        // arm anything. The title's own rendered band is `[slide, slide + height]` in local units,
        // so it is still on screen exactly while the viewport's top edge is above its bottom.
        let stillOnScreen = visibleMinY < titleHeight + slide
        let clearances = clearances(titleHeight: titleHeight,
                                    cardTopReach: cardTopReach,
                                    artworkHeight: artworkHeight,
                                    captionVisible: captionVisible,
                                    treatment: treatment,
                                    mode: mode)
        // Codex r2 P2-3: `net < 0` alone under-covers the belt. When the corrector is disarmed,
        // exhausted, or bottom-blocked, an INTRUSION-ONLY rest leaves a fully opaque title sitting
        // on the artwork — `net` is fine, the picture is not. The arm edge therefore takes either
        // failure.
        //
        // Codex r4 P1: and the intrusion is measured against the FOCUSED card
        // (`clearances.focused`), not the row's resting geometry. The title rides over the card
        // that has focus, which the focus treatment has raised, so the pre-lift number was
        // systematically optimistic — a belt that recovered at pre-lift zero would happily leave
        // the focused card's artwork under the title.
        //
        // Codex r7 P2: but ONLY the focused row's cards are raised. An unfocused row's artwork
        // sits at its resting top, so judging it by the lifted clearance invents an intrusion that
        // does not exist — an 11pt slide on an unfocused row would read as 5pt intruded when it is
        // actually 15pt CLEAR, and the belt could fade a title nothing was wrong with. Each row is
        // judged by the geometry its own cards are actually in.
        //
        // Hysteresis (arm above `fadeIntrusionArm`, recover only at `intrusion ≤ 0`) is what keeps
        // a rest parked exactly at the corrected fixpoint — where `slide == clearances.focused`,
        // i.e. intrusion 0 for the focused row — from sitting on the boundary and flickering.
        let effectiveClearance = rowIsFocused ? clearances.focused : clearances.atRest
        let intrusion = slide - effectiveClearance
        return Reading(slide: slide,
                       clearances: clearances,
                       hideCandidate: stillOnScreen && (overshoot > 1 || intrusion > fadeIntrusionArm),
                       showAgain: overshoot <= 0 && intrusion <= 0,
                       intrusion: intrusion)
    }

    /// Arm threshold for the visibility belt's intrusion half — how far a title may ride onto its
    /// row's artwork (as that row's own cards are actually sitting: lifted if it holds focus, at
    /// rest otherwise) before "a missing title beats a title on the art" applies. Small, but above
    /// the rounding noise around the corrected fixpoint (intrusion 0), which is the rest the belt
    /// must never fire on.
    nonisolated static let fadeIntrusionArm: CGFloat = 4

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
    ///
    /// `isFocused` is whether one of THIS row's cards holds focus — the same signal
    /// `pinnedRowSettleTracking` takes, and required for the same reason: only a focused row's
    /// cards are raised by the focus treatment, so only a focused row is judged against the lifted
    /// clearance (Codex r7 P2). Deliberately NOT part of the style gate's remount key: focus
    /// changes constantly, and discarding the title's `slide`/`faded` state on every D-pad step
    /// would reintroduce the snap this modifier exists to remove.
    ///
    /// `treatment` is which focus treatment this row's CARDS wear, and it defaults to the case
    /// three of the four pinned rows are in — `PosterCard`/`LandscapeCard`, whose lift genuinely
    /// follows `CardFocusMode.resolve`. The one exception is the collection folder-tile row, which
    /// must pass `.plainBorderless`; see `PinnedRowTitle.RowCardTreatment` for why a folder tile's
    /// lift is not the ring-mode one (Codex r9 P2).
    func pinnedRowTitleTracking(rowKey: String,
                                artworkHeight: CGFloat? = nil,
                                isFocused: Bool,
                                treatment: PinnedRowTitle.RowCardTreatment = .cardTreatment) -> some View {
        modifier(PinnedRowTitleTrackingStyleGate(rowKey: rowKey,
                                                 artworkHeight: artworkHeight,
                                                 isFocused: isFocused,
                                                 treatment: treatment))
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
    /// Whether one of this row's cards holds focus — see `pinnedRowTitleTracking`. Passed straight
    /// through and deliberately kept OUT of `styleKey`: it changes on every D-pad step, and
    /// remounting the title there would discard the slide/fade state this gate exists to protect.
    let isFocused: Bool
    /// Which focus treatment this row's cards wear — see `pinnedRowTitleTracking`. A per-call-site
    /// constant, so it never needs to join the remount key.
    let treatment: PinnedRowTitle.RowCardTreatment
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
            // `captionVisible` comes from the same `PosterStyle` already keyed above, so it can
            // never change without a remount — it feeds the manual-scale lift's lockup height
            // (`PinnedRowTitle.cardLockupCaptionChrome`).
            .modifier(PinnedRowTitleTracking(rowKey: rowKey,
                                             artworkHeight: artworkHeight,
                                             captionVisible: style.showTitle,
                                             isFocused: isFocused,
                                             treatment: treatment))
            .id(styleKey)
    }
}

private struct PinnedRowTitleTracking: ViewModifier {
    let rowKey: String
    /// Wave 4 item 6: the row's resting artwork height, feeding the proportional slide clamp
    /// (`PinnedRowTitle.maxSlide`). nil = absolute cap only, i.e. the pre-Wave-4 behavior.
    let artworkHeight: CGFloat?
    /// Whether this row's cards carry a caption line — the rest of the lockup the manual-scale
    /// focus treatment scales along with the artwork. Style-derived, so constant between remounts.
    let captionVisible: Bool
    /// Whether one of this row's cards holds focus, i.e. whether its artwork is currently RAISED
    /// by the focus treatment. Decides which clearance the belt judges this row against — see
    /// `PinnedRowTitle.reading` (Codex r7 P2).
    let isFocused: Bool
    /// Which focus treatment this row's cards wear, deciding HOW MUCH that raise is — see
    /// `PinnedRowTitle.RowCardTreatment` (Codex r9 P2).
    let treatment: PinnedRowTitle.RowCardTreatment
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

    /// Visibility belt (2026-08-30, rc1 tester report + sim repro `margin=-86..-100 slide=72
    /// net=-14..-28 cap=64 intr=46`): the LAST line of defence, after the settle re-reveal
    /// (`PinnedRowSettle`) has had its go. If a rest still leaves the title CLIPPED (`net < 0`) or
    /// still riding more than `PinnedRowTitle.fadeIntrusionArm` onto the FOCUSED card's artwork, a
    /// missing title beats a title on the art, so it fades out entirely and comes back the moment
    /// the geometry recovers. Both failures count (Codex r2 P2-3): when the corrector is disarmed,
    /// exhausted, or bottom-blocked, an intrusion-only rest is fine by `net` and still has title
    /// painted on the poster. The intrusion is the LIFTED one (Codex r4 P1) — measured against the
    /// card the system focus lift has raised, which is the card the title actually rides over.
    ///
    /// Deliberately NOT a slide/cap change: the binding cap stays 72 and every rest that leaves the
    /// title clear of the artwork renders byte-identically to today (`faded` never leaves `false`
    /// there, and `.opacity(1)` is a no-op) — including the deterministic beta.12 rest, which parks
    /// at `intrusion == 0`, below the arm threshold. This is wired at the shared tracking layer, so
    /// all four pinned rows — catalog, Continue Watching, Upcoming, collections — inherit it from
    /// their existing one-line `pinnedRowTitleTracking` call.
    @State private var faded = false
    /// Cancellation token for the delayed hide (see `updateFade`). Bumped when the belt's arm state
    /// TRANSITIONS and on each re-arm of the deferred check, never once per measurement.
    @State private var fadeToken = 0
    /// When this title last STOPPED being acceptable — set on the transition out of `showAgain`,
    /// cleared on the transition back into it, deliberately NOT reset by re-arming. The ceiling
    /// (`fadeMaxDefer`) therefore measures the whole episode, so a title that keeps flickering in
    /// and out of the arm band while the page churns still fades on schedule.
    @State private var fadeArmedAt: Date?

    /// Longer than `PinnedRowSettle.settleDelay + nudgeDuration` on purpose: this is what gives the
    /// settle re-reveal first refusal at every rest. The corrector decides at 0.25s and its scroll
    /// lands by ~0.5s; the correction is itself motion, which defers this check further; and a
    /// corrected rest then measures `showAgain` and un-fades immediately. The belt therefore only
    /// ever fires on rests the re-reveal could not fix — a bounded correction, a disarmed or
    /// exhausted mechanism, or a row the focus engine keeps pinned.
    private static let fadeDelay: TimeInterval = 0.7
    /// Floor on the deferred check's re-arm interval while the page is still moving, so a long
    /// scroll costs a handful of trivial main-queue hops rather than one per frame.
    private static let fadeRecheckFloor: TimeInterval = 0.1
    /// TERMINAL ceiling on how long the belt may be deferred by motion (Wave 9(a)). Once a title
    /// has been continuously unacceptable for this long it fades whatever the page is doing.
    ///
    /// This is what makes the belt genuinely terminal, and the device pass is why it has to be.
    /// The rest-gate alone is a liveness hazard: the corrector's own correction stamps motion by
    /// design (so it keeps first refusal), and on an unsatisfiable rest it can keep re-firing
    /// against a reveal that pulls the row straight back — motion forever, fade never. The device
    /// log shows exactly that steady state (`net=-27`, `intr=45`, title on the poster for seconds).
    ///
    /// Chosen over the narrower "stop counting the corrector's OWN scrolls as motion": attribution
    /// only covers the half of the loop we issue. The focus engine's counter-reveal is real motion
    /// from anyone's point of view, and it was the other half. A ceiling covers both by
    /// construction and needs no attribution at all.
    ///
    /// 2.5s is comfortably longer than a correction plus its settle (0.25 + 0.25, twice over, plus
    /// the 0.7s gate) so a rest that IS fixable is always fixed first, and short enough that the
    /// tester never sees the "title painted on the poster for many seconds" the device video shows.
    ///
    /// **Worst case, stated honestly (Codex Wave 9 r2): `fadeMaxDefer + fadeRecheckFloor` — 2.6s.**
    /// This is a ceiling on when the next CHECK may run, not a timer that fires on its own, so the
    /// bound is the ceiling plus one wake-up interval. `scheduleFadeCheck` now sleeps the SMALLER
    /// of the motion remainder and the ceiling remainder, which is what keeps that second term at
    /// the floor; before it slept the motion remainder unconditionally and a title armed at 2.4s
    /// still waited another 0.7s, making the real bound 3.2s while this comment claimed 2.5s.
    private static let fadeMaxDefer: TimeInterval = 2.5

    /// The two Appearance settings the lift allowance branches on, as REACTIVE inputs (Codex r10
    /// P2). `@AppStorage` rather than the bare `UserDefaults` reads the computation used to do on
    /// its own: those only ran when a geometry pass happened to run, so toggling either setting
    /// and returning to a Home that had not scrolled left `PinnedRowSettle.clearances` describing
    /// the previous mode indefinitely — a correction aimed at the wrong target and a belt judging
    /// against the wrong threshold, until something moved.
    ///
    /// A change re-evaluates this modifier's body (no remount — deliberately NOT part of the style
    /// gate's `styleKey`, for the same reason `isFocused` is not: a toggle must not discard
    /// `slide`/`faded` and snap the title). `onChange` below then recomputes from cached geometry
    /// and republishes, which is what actually restores coherence — a body re-evaluation alone is
    /// not guaranteed to re-run the geometry transform.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @AppStorage("accent_focus_ring") private var accentFocusRing = false

    /// Last geometry this title measured, so a mode change can re-derive a full `Reading` — belt
    /// verdict included — with no new geometry pass. A reference box, not `@State`: it is written
    /// on every measurement, and a state write there would invalidate per frame.
    @State private var geometryCache = TitleGeometryCache()

    private var focusMode: PinnedRowTitle.FocusModeFlags {
        PinnedRowTitle.FocusModeFlags(noZoom: noZoomOnFocus, accentRing: accentFocusRing)
    }

    func body(content: Content) -> some View {
        // Hoisted to locals so the geometry closures below capture two plain CGFloats instead of
        // this (view-isolated) modifier — the same rule the probe already follows for `rowKey`.
        let clampArtworkHeight = artworkHeight
        let clampReach = cardTopReach
        let clampCaption = captionVisible
        let rowFocused = isFocused
        let rowTreatment = treatment
        let liftMode = focusMode
        return content
            // Belt: render-time only (opacity changes no geometry), so the measurement feeding it
            // cannot be perturbed by it — the same invariant `visualEffect` buys for the slide.
            .opacity(faded ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: faded)
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
            // Codex r10 P2: caches the raw geometry a `Reading` is derived from, so a focus-mode
            // toggle — which moves nothing and so may never produce another geometry pass — can
            // still recompute one. Deliberately a SEPARATE observer: `visibleMinY` changes every
            // frame during a scroll, and folding it into the `Reading` above would make that
            // observer fire per frame for every visible row, which is exactly the churn its own
            // doc forbids. This action only writes two CGFloats into a reference box — no SwiftUI
            // invalidation, no state.
            .onGeometryChange(for: PinnedRowTitle.TitleGeometry?.self, of: { proxy in
                guard let visible = PinnedRowTitle.visibleBounds(proxy) else { return nil }
                return PinnedRowTitle.TitleGeometry(visibleMinY: visible.minY,
                                                    titleHeight: proxy.size.height)
            }, action: { newValue in
                if let newValue { geometryCache.value = newValue }
            })
            .onGeometryChange(for: PinnedRowTitle.Reading?.self, of: { proxy in
                PinnedRowTitle.reading(proxy,
                                       artworkHeight: clampArtworkHeight,
                                       cardTopReach: clampReach,
                                       captionVisible: clampCaption,
                                       rowIsFocused: rowFocused,
                                       treatment: rowTreatment,
                                       mode: liftMode)
            }, action: { oldValue, newValue in
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
                    slide = newValue.slide
                    hasSeeded = true
                } else if slide != newValue.slide {
                    withAnimation(.easeOut(duration: 0.22)) { slide = newValue.slide }
                }
                updateFade(previous: oldValue, current: newValue)
                // Hand this row's measured clearances to the settle re-reveal, which sizes its
                // correction against the FOCUSED card's artwork intrusion (`slide − focused`) and
                // can only measure the row, not the title inside it. Keyed by row, constant per
                // row, and a plain static write — no SwiftUI invalidation. A row that has never
                // published one is never corrected (see `PinnedRowSettle.settlePlan`), which is
                // the fail-safe reading: no measured title means no title to protect.
                PinnedRowSettle.noteClearances(rowKey: rowKey, clearances: newValue.clearances)
            })
            // Codex r10 P2: the settings toggle that moves nothing. A body re-evaluation alone is
            // not enough — it does not guarantee the geometry transform re-runs — so recompute the
            // Reading from cached geometry and push BOTH halves through: the belt's verdict (the
            // fade threshold moved) and the row's clearance (the corrector's target moved).
            .onChange(of: liftMode) { _, newMode in
                republishForModeChange(newMode)
            }
            // Codex Wave 9 r1: this title's belt state dies with the view. A faded title that is
            // evicted (lazy recycling, leaving Home, a theme `.id()` swap) never passes back
            // through `showAgain`, so nothing else would ever drop its key — see
            // `PinnedRowSettle.clearBeltFaded` for what that stranded. Bumping `fadeToken` in the
            // same breath kills any pending deferred fade check: that chain re-arms itself while
            // the page is moving, so without this it could keep waking up for seconds after the
            // row it belongs to has gone.
            .onDisappear {
                fadeToken &+= 1
                PinnedRowSettle.clearBeltFaded(rowKey: rowKey)
                // Codex Wave 9 r3: reset the LOCAL verdict too, not just the shared key. A
                // retained subtree — leaving Home without destruction — comes back with its
                // `@State` intact, so clearing only the shared set left a title still invisible
                // while every settle line reported `beltFaded=0`: an invisible title with a probe
                // swearing it was visible, and no way for the harness or a device log to tell.
                //
                // Hiding is a per-VISIT verdict, not a property of the row. It is only ever
                // justified by a rest that is on screen right now, and this row is leaving; if the
                // same bad geometry is still there when it returns, the first measurement arms the
                // belt again and it re-fires on its own schedule. Recovery is coherent in both
                // directions: the view comes back visible with the set empty, and its next genuine
                // fade computes `changed == true` and republishes `beltFaded=1`.
                faded = false
                fadeArmedAt = nil
            }
            .modifier(PinnedRowTitleProbe(rowKey: rowKey,
                                          artworkHeight: artworkHeight,
                                          cardTopReach: cardTopReach,
                                          captionVisible: captionVisible,
                                          treatment: treatment,
                                          mode: liftMode,
                                          enabled: HomeGeometryProbe.enabled))
    }

    /// Re-derives this title's `Reading` under a new focus mode, from the geometry last measured,
    /// and republishes everything downstream of it.
    ///
    /// `previous: nil` into `updateFade` is correct rather than convenient: a mode change is not a
    /// continuation of the previous arm state, it is a fresh verdict — if the new mode puts the
    /// title in the arm band it should arm now, and if it clears it, it should un-fade now.
    ///
    /// `noteClearances` is the other half, and it does more than store: a clearance that actually
    /// changed re-arms the corrector through the same backstop the late-clearance path uses, so a
    /// mode change that moves the correction target gets acted on instead of waiting for the next
    /// scroll (which, on a Home the user has just come back to, may never come).
    private func republishForModeChange(_ mode: PinnedRowTitle.FocusModeFlags) {
        guard let geometry = geometryCache.value else { return }
        let reading = PinnedRowTitle.reading(geometry: geometry,
                                             artworkHeight: artworkHeight,
                                             cardTopReach: cardTopReach,
                                             captionVisible: captionVisible,
                                             rowIsFocused: isFocused,
                                             treatment: treatment,
                                             mode: mode)
        updateFade(previous: nil, current: reading)
        PinnedRowSettle.noteClearances(rowKey: rowKey, clearances: reading.clearances)
    }

    /// Visibility belt state machine. Two asymmetric halves, on purpose:
    ///
    ///  - RECOVERY is immediate and unconditional. The instant a measurement says the title is back
    ///    inside its budget (`showAgain`) the fade is cancelled and the title returns — a title
    ///    that had to wait to come back would read as a bug of its own.
    ///  - HIDING is deferred until the page is genuinely at REST in the bad state, and the settle
    ///    re-reveal always gets first refusal at that rest (see `fadeDelay`).
    ///
    /// Codex r2 P2-1: rest here means the SCROLL is still, not "no new measurement arrived". Those
    /// came apart once the slide saturates at the cap — `Reading` then goes byte-identical frame to
    /// frame, `onGeometryChange` stops firing, and a slow swipe that stayed in the belt's band for
    /// longer than `fadeDelay` would fade a title while the page was visibly moving. The deferred
    /// check therefore consults `PinnedRowSettle.secondsSinceMotion()` — the scroll's own
    /// last-move stamp — and re-arms instead of firing whenever the page has moved recently.
    ///
    /// Cost: arming is TRANSITION-driven (`previous` vs `current`), so a title crossing the clip
    /// edge schedules one deferred check, not one per frame, and `fadeToken` is written only on
    /// those transitions. The `stillOnScreen` term in `PinnedRowTitle.reading` confines the whole
    /// mechanism to titles still on screen — at most the one or two rows straddling the clip edge,
    /// never the whole stack above it.
    private func updateFade(previous: PinnedRowTitle.Reading?, current: PinnedRowTitle.Reading) {
        if current.showAgain {
            fadeArmedAt = nil
            if faded {
                fadeToken &+= 1          // cancels any pending hide
                faded = false
                beltLog("recover", current)
                PinnedRowSettle.noteBeltFaded(rowKey: rowKey, faded: false)
            } else if previous?.hideCandidate == true {
                fadeToken &+= 1
            }
            return
        }
        // Not acceptable any more. Stamp WHEN that started, once per episode — the terminal ceiling
        // is measured from here, not from the latest arm, so a title flickering between the arm
        // band and the hysteresis band cannot defer itself indefinitely.
        if fadeArmedAt == nil { fadeArmedAt = Date() }
        guard current.hideCandidate else {
            // The hysteresis band between the two edges: hold whatever state we have, but drop a
            // pending hide — this title is no longer in a state worth hiding for.
            if previous?.hideCandidate == true { fadeToken &+= 1 }
            return
        }
        // Already armed by an earlier transition (or already hidden) — the standing deferred check
        // owns it from here. Note `previous == nil` (this title's FIRST measurement) takes the arm
        // path, so a title that publishes already inside the arm band is armed immediately rather
        // than waiting for a transition that already happened.
        guard previous?.hideCandidate != true, !faded else { return }
        beltLog("arm", current)
        scheduleFadeCheck(after: Self.fadeDelay)
    }

    /// Fires the hide once the scroll has been still for `fadeDelay` — or once the title has been
    /// unacceptable for `fadeMaxDefer` regardless of motion, whichever comes first.
    ///
    /// Terminates three ways over: every re-arm waits at least `fadeRecheckFloor`, the chain dies
    /// the moment the title leaves the arm band (`updateFade` bumps `fadeToken`) or the hide lands,
    /// and the ceiling bounds the whole episode even if the page never goes still. That last one is
    /// Wave 9(a): without it the corrector and the belt could livelock, and on hardware they did.
    ///
    /// The re-arm delay is bounded by BOTH remainders (Codex Wave 9 r2) so the ceiling is not
    /// overshot by a whole `fadeDelay` — see `fadeMaxDefer` for the arithmetic and the honest
    /// `fadeMaxDefer + fadeRecheckFloor` worst case.
    private func scheduleFadeCheck(after delay: TimeInterval) {
        fadeToken &+= 1
        let token = fadeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Superseded by a newer transition, or something already faded this title — either way
            // this scheduled check is stale.
            guard token == fadeToken, !faded else { return }
            let sinceMotion = PinnedRowSettle.secondsSinceMotion()
            let armedFor = fadeArmedAt.map { Date().timeIntervalSince($0) } ?? 0
            if sinceMotion < Self.fadeDelay, armedFor < Self.fadeMaxDefer {
                if HomeGeometryProbe.enabled {
                    NSLog("[HomeScrollProbe] belt %@",
                          "defer row=\(rowKey) sinceMotion=\(Int(sinceMotion * 1000))ms armedFor=\(Int(armedFor * 1000))ms")
                }
                // Codex Wave 9 r2: the next wake-up is bounded by BOTH remainders. Sleeping the
                // full motion remainder alone could overshoot the ceiling by up to `fadeDelay` —
                // at `armedFor = 2.4` the old form still slept 0.7s and fired at ~3.1s, so the
                // "terminal" bound was 3.2s in practice, not 2.5s. Taking the smaller of the two
                // means the chain wakes when the ceiling expires if that comes first; the floor
                // still bounds the wake-up rate, so it terminates exactly as before.
                let motionRemainder = Self.fadeDelay - sinceMotion
                let ceilingRemainder = Self.fadeMaxDefer - armedFor
                scheduleFadeCheck(after: max(min(motionRemainder, ceilingRemainder),
                                             Self.fadeRecheckFloor))
                return
            }
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] belt %@",
                      "fire row=\(rowKey) sinceMotion=\(Int(sinceMotion * 1000))ms armedFor=\(Int(armedFor * 1000))ms"
                        + " ceiling=\(armedFor >= Self.fadeMaxDefer ? 1 : 0)")
            }
            faded = true
            PinnedRowSettle.noteBeltFaded(rowKey: rowKey, faded: true)
        }
    }

    /// One greppable `[HomeScrollProbe] belt …` line per state change. The belt used to log
    /// NOTHING, which is why the device pass could see the title painted on the artwork and not
    /// tell whether the belt had never armed, was deferring forever, or had fired and been undone.
    private func beltLog(_ event: String, _ reading: PinnedRowTitle.Reading) {
        guard HomeGeometryProbe.enabled else { return }
        NSLog("[HomeScrollProbe] belt %@",
              "\(event) row=\(rowKey) slide=\(Int(reading.slide.rounded()))"
                + " intr=\(Int(reading.intrusion.rounded()))"
                + " clearance=\(Int(reading.clearances.atRest.rounded()))"
                + " clearanceLift=\(Int(reading.clearances.focused.rounded()))")
    }
}

/// `[HomeScrollProbe] title row=… margin=… slide=… net=… cap=… intr=… intrLifted=… vh=…`, so a
/// single manual up-walk
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
///    budget is `artworkHeight × heroPinnedRowTitleArtIntrusionFraction`. PRE-LIFT: measured
///    against the card's RESTING artwork top.
///  - `intrLifted` / `lift` (2026-08-30) — the same number for the FOCUSED card, i.e. `intr` plus
///    the ACTIVE focus mode's lift, and that lift itself. The focus treatment raises the focused
///    card's artwork while the title stays where it is, so every device log this probe produced
///    before under-reported the intrusion on the one card the viewer is looking at (the rc1 line
///    `intr=46` was really 66 on the focused card). `lift` is 0 under "No Zoom on Focus", the
///    pixel-measured `heroPinnedRowFocusLiftAllowance` by default, and scale-derived in ring mode
///    — see `PinnedRowTitle.focusLiftAllowance`. Reported alongside so a log can be read without
///    also knowing the tester's Appearance settings.
///  - `vh`     — the rows viewport's height, the denominator every rest position is computed
///    against. Carried so a creep trace can be ATTRIBUTED rather than guessed at: a `margin` that
///    drifts at rest while `vh` holds AND `[HomeScrollProbe] pinned-hero y=…` holds means content
///    ABOVE the row is growing; a drifting `y` means the scroll offset itself never converged; a
///    drifting `vh` means the pinned hero (not the rows) is the mover.
/// Not attached at all when the knob is off, so disabled builds evaluate none of it.
private struct PinnedRowTitleProbe: ViewModifier {
    let rowKey: String
    let artworkHeight: CGFloat?
    let cardTopReach: CGFloat
    let captionVisible: Bool
    let treatment: PinnedRowTitle.RowCardTreatment
    /// Reactive focus-mode flags, so `lift=` reports the mode that is live RIGHT NOW rather than
    /// whatever the defaults said the last time geometry moved (Codex r10 P2).
    let mode: PinnedRowTitle.FocusModeFlags
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            // Captured by value so the geometry closure holds a plain String and two CGFloats
            // rather than this (view-isolated) modifier.
            let key = rowKey
            let clampArtworkHeight = artworkHeight
            let clampReach = cardTopReach
            let clampCaption = captionVisible
            let clampTreatment = treatment
            let clampMode = mode
            content.onGeometryChange(for: String.self, of: { proxy in
                guard let margin = PinnedRowTitle.rawMargin(proxy) else { return "" }
                let slide = PinnedRowTitle.slide(proxy, artworkHeight: clampArtworkHeight, cardTopReach: clampReach)
                let cap = PinnedRowTitle.maxSlide(titleHeight: proxy.size.height,
                                                  artworkHeight: clampArtworkHeight,
                                                  cardTopReach: clampReach)
                // Title bottom vs artwork top, in the same shelf-relative units the clamp uses.
                let intrusion = (Theme.Size.heroPinnedRowTitleInset + proxy.size.height + slide)
                    - (Theme.Spacing.lg + clampReach)
                // …and the same thing on the FOCUSED card, whose artwork the ACTIVE focus
                // treatment has already raised (Codex r7 P1: 0 in still mode, the measured ~20pt
                // system-lift constant by default, half the scale delta over the lockup in ring
                // mode). `lift=` is reported alongside so a device log can tell which mode
                // produced the reading without also having to know the tester's settings.
                let lift = PinnedRowTitle.focusLiftAllowance(artworkHeight: clampArtworkHeight,
                                                             captionVisible: clampCaption,
                                                             treatment: clampTreatment,
                                                             mode: clampMode)
                let intrusionLifted = intrusion + lift
                let viewportHeight = PinnedRowTitle.visibleBounds(proxy)?.height ?? 0
                return "row=\(key) margin=\(probeBucket(margin)) slide=\(probeBucket(slide)) net=\(probeBucket(margin + slide)) cap=\(probeBucket(cap)) intr=\(probeBucket(intrusion)) intrLifted=\(probeBucket(intrusionLifted)) lift=\(probeBucket(lift)) vh=\(probeBucket(viewportHeight))"
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

// MARK: - Pinned row SETTLE RE-REVEAL (rc1 tester report, sim-reproduced 2026-08-30)

/// Corrects the one rest the BUG-37 slide provably cannot cover: a SETTLED pinned rest whose title
/// is still clipped after the slide has saturated.
///
/// The measurement that specified this, on the FA87 sim fixture at Poster Size = **Large**
/// (2026-08-30): a focused poster row at a settled rest logs
/// `[HomeScrollProbe] title row=…recs_series_for_you margin=-86..-100 slide=72 net=-14..-28
/// cap=64 intr=46`. The row's top parks ~90–100pt UNDER the pinned clip edge, the slide saturates
/// at the absolute 72 cap, and `net` goes NEGATIVE — violating the invariant the probe's own doc
/// names as the regression to watch (`net ≥ 0` at a settled rest). At Medium the frame fits and
/// none of it fires, which is exactly the tester's "only at Large".
///
/// Why the fix has to move the SCROLL and not the title. The focusable link frame at Large is
/// `artworkHeight + 175.5` = 578.8pt; the reveal regime documented at `PosterCard.swift` (~L730)
/// parks frames of that class UNDER the clip edge instead of centring them. Once the rest is
/// 90pt short, every render-time dial is already spent: the slide is at its cap, and raising the
/// cap trades a title on the artwork for a title cut off screen (Codex 2026-08-29 P1 settled
/// that trade the other way). The row is simply in the wrong place, so the row is what moves.
/// `954d62a9` deferred exactly this ("settle re-reveal"); this is that deferred work.
///
/// The mechanism, and why it cannot oscillate:
///
///  1. **It only ever runs from a settled rest.** `noteScroll` arms a single debounce; a real
///     scroll (motion beyond `driftTolerance`) re-arms it, so nothing fires while the page moves.
///  2. **It only ever moves content DOWN, and never past the target.** The correction is
///     `d = min(deficit, bottomRoom, cap)` with `deficit = max(−margin − clearances.focused, 0)`,
///     applied as a DECREASE of `contentOffset.y`. Moving content down can only raise `margin`,
///     and `d` stops exactly at `margin = −clearances.focused` — the rest where the title's bottom
///     edge meets the FOCUSED (lifted) card's artwork top — so a correction can never overshoot
///     into needing another. **`liftedIntrusion ≤ 0` is the fixpoint** and the mechanism is
///     monotone toward it; `net = 0` there too, so the title stays fully visible. Gating on the
///     raw `margin` was Codex r1 P1 (it fired on already-clean `margin=-25 net=0` rests); gating on
///     the PRE-LIFT intrusion was Codex r4 P1 (its fixpoint still left the focused card's artwork
///     ~20pt under the title, so the gate could pass while the tester saw the overlap).
///  3. **Bounded by the row's own geometry.** `bottomRoom` keeps the focused card inside the
///     viewport (only the transparent downward reach band is allowed to leave it), and
///     `heroPinnedRowSettleMaxNudge` caps everything absolutely.
///  4. **At most one correction in flight** (`nudgeDeadline`), and at most
///     `maxConsecutiveNudges` in a row without an intervening healthy rest — so even if something
///     external fights back, the loop stops after two attempts and the visibility belt
///     (`PinnedRowTitleTracking.updateFade`) takes over.
///  5. **Focus changes abandon it.** A new focused row replaces the measurement and resets the
///     counter; focus leaving the rows clears it outright, so a correction planned for one row can
///     never land on another. That includes TOKENS already scheduled: `invalidateEpoch` bumps
///     `generation`, so a debounce armed for the old row cannot fire against the new row's
///     not-yet-settled measurement, and re-arms a fresh settle so the new row gets its own full
///     `settleDelay` (Codex r3 P2-2). The tracked focus covers a catalog row's trailing See All
///     tile too, which is part of the row and needs the same correction (Codex r3 P2-1).
/// **The handoff, and why it cannot livelock (Wave 9(a), device pass on the Living Room ATV).**
/// Some rests are simply UNSATISFIABLE: hardware parks rows ~75pt deeper than the simulator does
/// (tab-bar occlusion, the BUG-66 family — device `margin=-99 rowB=480` against sim `-25 / 404` at
/// the same `vh=455`), and a Large focusable frame taller than the effective viewport cannot be
/// made to show its title band AND its card at once. No amount of correcting fixes that; the
/// visibility belt (`PinnedRowTitleTracking`) is the terminal fallback, and the corrector's job is
/// to get out of its way.
///
/// It did not, at first, and the failure is worth keeping because it was a genuine LIVELOCK rather
/// than a wrong number. The device trace ran `nudge=19 bound=19 n=1`, then `n=2`, then handed its
/// budget straight back and started over — because a transient unmeasurable geometry pass (lazy
/// row realization, `contentH` climbing 17449→20650 across the walk) used to `clear` the focused
/// row, which ends the epoch and resets `consecutiveNudges`. Each re-fired correction animated for
/// 0.25s and stamped `lastMotionAt`; the reveal pulled the rest back to the same `margin=-99`; and
/// the belt's rest-gate never saw its 0.7s of stillness, so a title sat on the artwork for as long
/// as the tester watched. The disarm that should have noticed corrections weren't landing was
/// itself neutralized — the same content growth VOIDed every verification, so no MISS was counted.
///
/// Three changes close it, and each is sufficient on its own for a different reason:
///   - `MeasurementReport.unmeasured` HOLDS instead of clearing, so the stand-down sticks. This is
///     the root cause; the rest are belt and braces.
///   - `standDown` records the handoff in the log, so the trace shows the corrector yielding.
///   - `PinnedRowTitleTracking.fadeMaxDefer` bounds the belt's motion deferral absolutely. This is
///     the liveness guarantee: the belt fires within `fadeMaxDefer + fadeRecheckFloor` (2.6s) of
///     the title becoming unacceptable NO MATTER what the corrector, the focus engine, or lazy
///     layout are doing, so no future interaction between them can starve it again. The extra
///     `fadeRecheckFloor` is real and deliberate — the ceiling gates a scheduled CHECK rather than
///     firing a timer of its own, so the bound is the ceiling plus one wake-up interval.
///
///  6. **It self-disarms if it is ever wrong.** Each correction records where it asked the scroll
///     view to land; the next settle checks. Two misses and the whole mechanism switches off for
///     the session with a loud log line, leaving beta.15 behavior plus the belt. Only a correction
///     whose own epoch is still current can testify: a focus change voids the outstanding
///     verification (`invalidateEpoch`), and a content reflow between fire and check voids it too
///     — otherwise a D-pad move or a lazy row realization would be counted as evidence against the
///     scroll API and two of them would disarm the session (Codex r1 P2, both seen in a sim run).
///
/// The creep this also disposes of. The same sim trace shows `margin` drifting ~2pt per probe
/// tick at "rest" (−86 → −100 over ~600ms with no input), i.e. the rest never actually settles.
/// That drift is NOT produced by anything in this file: the slide is saturated at the cap, so
/// `PinnedRowTitleTracking` writes no state and its `visualEffect` is invisible to geometry by
/// construction (Codex gate 1, round 2) — there is no title-side feedback loop left to break. What
/// remains are three EXTERNAL movers, and the probe now carries the fields that tell them apart
/// (`vh=` here, `y=` on the `[HomeScrollProbe] pinned-hero` line): a scroll animation that never
/// converged (`y` drifts), content above the row still relaying out (`y` and `vh` hold, `margin`
/// drifts), or the pinned hero itself resizing (`vh` drifts — ruled out by reading, the header is
/// a fixed `heroCarouselHeightPinned` frame). Whichever it is, the drift is made HARMLESS here
/// rather than chased: `noteScroll` treats a sub-`driftTolerance` STEP as stillness, so a crawl
/// still produces exactly one settle instead of re-arming the debounce forever, and the correction
/// is computed from the LIVE measurement at fire time, not from the stale one that armed it. That
/// tolerance is load-bearing — a naive "no geometry change for 250ms" settle detector would never
/// fire at all against a creeping rest, and this fix would silently never run. A creep that
/// outlives the correction is then bounded twice over: the corrected rest is `margin ≈ 0`, so it
/// has the full 72pt slide plus ~26pt of static clearance to drift through before the title
/// touches artwork again, and if it ever does, the next settle corrects it again (that is not
/// oscillation — each correction is a response to fresh external motion, not to its own output).
///
/// Storage is plain static rather than `@State` for the same reason `HomeScrollProbeRest`'s is:
/// every writer is a SwiftUI geometry callback on the main thread, and a state write here would
/// invalidate Home on every scroll frame — the corrector must not perturb the geometry it reads.
enum PinnedRowSettle {
    /// The focused pinned row's frame, in the rows viewport's own coordinates.
    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated struct Measurement: Equatable, Sendable {
        /// Which row's cards hold focus. Doubles as the epoch key for the oscillation guard.
        var rowKey: String
        /// The row's top edge relative to the viewport's top edge (negative = above the clip edge).
        var rowTop: CGFloat
        var rowHeight: CGFloat
        var viewportHeight: CGFloat
        /// Distance from the row's TOP edge to the FOCUSED card's lockup BOTTOM, for rows that can
        /// state it more precisely than their own frame does (Codex r11 P2-2).
        ///
        /// nil — every uniform-card row (catalog, Continue Watching, Upcoming) — means the row's
        /// own bottom already IS the focused card's lockup bottom plus the transparent chrome, so
        /// `protectedBottom` derives it exactly as before.
        ///
        /// The one row that needs this is the MIXED-SHAPE collection row. Its height comes from
        /// `shelfMinHeight`, i.e. the TALLEST folder tile, while its `LazyHStack` is top-aligned in
        /// pinned mode — so a focused square or landscape tile ends far above the row's bottom
        /// edge. Bounding that correction by the row's bottom reported no room at all and refused a
        /// correction the focused tile could have absorbed completely, leaving the belt to hide a
        /// title that never needed hiding. Note the approximation runs the WRONG way if inverted:
        /// bounding a tall focused tile by a short one's extent would push real artwork off the
        /// fold, which is why this is the focused tile's own extent and not the row's shortest.
        var focusedLockupExtent: CGFloat?

        /// The title's top vs the viewport's top edge — the probe's `margin`, reproduced from the
        /// ROW's frame. The pinned title is an overlay at the shelf's top-leading corner inset by
        /// `heroPinnedRowTitleInset` (see `CatalogRowView`'s overlay and its three twins), and the
        /// row's VStack has no other child in pinned mode, so row top + inset IS title top.
        var margin: CGFloat { rowTop + Theme.Size.heroPinnedRowTitleInset }
        var rowBottom: CGFloat { rowTop + rowHeight }

        /// The lowest point that must stay inside the viewport for a correction to be safe: the
        /// focused card's lockup bottom. Everything below it in the row's frame is transparent —
        /// the downward reach band, and (for the row's own bottom padding) shelf chrome — and may
        /// leave the viewport without hiding any artwork.
        var protectedBottom: CGFloat {
            if let focusedLockupExtent { return rowTop + focusedLockupExtent }
            return rowBottom - Theme.Size.heroPinnedRowBottomReach
        }
    }

    /// What one pinned row's settle tracker saw this geometry pass (Wave 9(a)).
    ///
    /// `unmeasured` exists because collapsing it into `inactive` cost the belt its whole reason to
    /// exist on hardware: a device walk realizes lazy rows continuously (`contentH` 17449→20650
    /// across one walk), every such pass can leave the enclosing scroll view unresolved for a
    /// frame, and each of those frames used to `clear` the focused row — which ends the correction
    /// epoch and hands the corrector a FRESH nudge budget on the very next measurement. The
    /// corrector then re-fired a bound-clamped nudge forever, and each 0.25s animation stamped
    /// motion, so the belt's rest-gate never saw its `fadeDelay` of stillness. Holding on
    /// `unmeasured` is what lets the stand-down actually stick.
    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated enum MeasurementReport: Equatable, Sendable {
        case measured(Measurement)
        /// Focused, but this pass could not resolve the enclosing scroll view — hold.
        case unmeasured
        /// Nothing in this row holds focus (or it is a classic-mode row) — clear.
        case inactive
    }

    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated struct ScrollSample: Equatable, Sendable {
        var offsetY: CGFloat
        var insetTop: CGFloat
        /// Carried so a correction's verification can be VOIDED (rather than counted as a miss)
        /// when the content itself reflowed between firing and checking — see `settlePlan`.
        var contentHeight: CGFloat
    }

    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated struct Plan {
        /// One greppable line for the probe / the harness oracle. Always produced, correction or
        /// not — "settled clean" is as diagnostic as "settled short".
        var report: String
        /// The scroll offset to animate to, or nil when this rest needs no correction.
        var targetY: CGFloat?
        /// Set when this settle could not be resolved and must be re-checked after this many
        /// seconds instead of dropped: a still-animating correction SWALLOWED it (Codex r2 P2-2),
        /// a focus change re-armed a fresh epoch under it (Codex r3 P2-2), or the row's title had
        /// not published its clearance yet (Codex r5 P2-1). All three are otherwise lost forever:
        /// the page is stationary by then, so no further scroll geometry event will ever arm
        /// another one. Bounded by the caller's hop budget
        /// (`PinnedRowSettleRevealModifier.maxSettleHops`).
        var retryAfter: TimeInterval? = nil
    }

    /// What one fired correction promised, so the next settle can check it landed.
    // `nonisolated`: same @Sendable-transform requirement as PinnedRowTitle.Reading above.
    nonisolated struct Verification: Sendable {
        var expectedY: CGFloat
        /// Content height at fire time. A reflow between fire and check moves every row under the
        /// scroll view, so the landed offset is no longer evidence about the SCROLL API — void
        /// rather than blame it (Codex r1 P2: a sim run logged exactly this, expected=909
        /// landed=941, as row realization reflowed content).
        var contentHeight: CGFloat
    }

    // `nonisolated` on every constant below, for the same reason the types above carry it: they
    // are read from this enum's `nonisolated` measurement/plan methods, which under the project's
    // default-MainActor isolation cannot see MainActor-isolated statics.
    /// How long the geometry must hold still before a rest counts as settled. Short enough that
    /// the correction reads as part of the settle rather than a delayed jump.
    nonisolated static let settleDelay: TimeInterval = 0.25
    nonisolated static let nudgeDuration: TimeInterval = 0.25
    /// A per-sample STEP at or below this is treated as stillness — see the creep paragraph in the
    /// header and `noteScroll`. 4pt sits an order of magnitude above the measured crawl
    /// (~0.4pt/frame) and an order of magnitude below a real reveal's per-frame travel, so it can
    /// neither swallow a real scroll nor be fooled by the drift.
    nonisolated static let driftTolerance: CGFloat = 4
    /// Sliding window for the CUMULATIVE motion test, and the path length within it that counts as
    /// motion — see the two-test explanation in `noteScroll` for the arithmetic that places 18pt
    /// (≈60pt/s) between the measured creep and a slow swipe's deceleration tail.
    nonisolated static let motionWindowSeconds: TimeInterval = 0.3
    nonisolated static let motionWindowDisplacement: CGFloat = 18
    nonisolated static let maxConsecutiveNudges = 2
    /// How far a landed correction may miss its requested offset before it counts as a miss. Wide
    /// enough to absorb a concurrent focus-driven adjustment, narrow enough to catch a scroll API
    /// that turned out to interpret the target in a different coordinate space than assumed.
    nonisolated private static let verifyTolerance: CGFloat = 24
    nonisolated private static let maxVerifyFailures = 2

    nonisolated(unsafe) private static var latest: Measurement?
    nonisolated(unsafe) private static var sample: ScrollSample?
    nonisolated(unsafe) private static var generation = 0
    nonisolated(unsafe) private static var armed = false
    nonisolated(unsafe) private static var consecutiveNudges = 0
    nonisolated(unsafe) private static var nudgeDeadline: Date?
    /// When the rows scroll view last actually MOVED. Read by the visibility belt — see
    /// `secondsSinceMotion`.
    nonisolated(unsafe) private static var lastMotionAt: Date?
    /// Per-callback displacements inside the last `motionWindowSeconds`, for the cumulative motion
    /// test in `noteScroll`. Bounded by the callback rate times the window — ~20 entries at 60Hz.
    nonisolated(unsafe) private static var motionWindow: [(at: Date, delta: CGFloat)] = []
    nonisolated(unsafe) private static var pendingVerification: Verification?
    nonisolated(unsafe) private static var verifyFailures = 0
    nonisolated(unsafe) private static var disarmed = false
    /// Set by `invalidateEpoch`, consumed by the first superseded `settlePlan` call: "a fresh
    /// settle is armed for a new row and nothing is scheduled to resolve it — please re-check".
    nonisolated(unsafe) private static var epochRearmPending = false
    /// The row whose last settle had to decline for a missing clearance (Codex r5 P2-1). Cleared
    /// the moment that row's clearance lands or its epoch ends; while set, `noteClearances` knows
    /// there is a rest waiting on it.
    nonisolated(unsafe) private static var clearanceLatePending: String?
    /// The row the corrector has most recently declared unsatisfiable — see `standDown`. Deduping
    /// key for that log line only; nothing branches on it.
    nonisolated(unsafe) private static var standDownRow: String?
    /// Rows whose title the visibility belt currently has hidden — see `noteBeltFaded`. Bounded by
    /// the number of pinned rows; membership is published by each title's own belt state.
    nonisolated(unsafe) private static var beltFadedRows: Set<String> = []

    /// The reveal modifier's deferred-settle scheduler, installed by whichever pinned rows
    /// ScrollView is mounted (Codex r6).
    ///
    /// Why this exists at all: `rearm()` only arms a settle — something still has to RESOLVE it,
    /// and resolving means applying a scroll correction, which only the modifier can do (it owns
    /// the `ScrollPosition`). Every other re-arm in this file happens inside a block the modifier
    /// itself scheduled, so it can re-schedule from there. The late-clearance backstop cannot: it
    /// runs in a TITLE's geometry callback, with the page stationary and the hop chain already
    /// spent, so without this hook its `rearm()` armed a settle that nothing would ever run and
    /// the row stayed uncorrected.
    ///
    /// One slot is correct because there is exactly one pinned-mode rows ScrollView: pinned mode
    /// is a single container in `HomeView.body`, and Search/other `CatalogRowView` hosts never arm
    /// the corrector (`settleReveal` is false, and their rows carry `rowCardTopReach == 0`). The
    /// one moment two can be alive at once is a theme `.id()` swap, where SwiftUI inserts the
    /// incoming subtree before removing the outgoing one — hence the generation-scoped
    /// unregistration below, so the outgoing view's teardown cannot clear the incoming view's
    /// registration, and the probe-logged warning on overwrite so a genuinely unexpected second
    /// host shows up in a device log instead of silently double-firing.
    nonisolated(unsafe) private static var scheduler: (@MainActor (Int) -> Void)?
    nonisolated(unsafe) private static var schedulerGeneration = 0
    /// Per-row clearances, published by that row's title (`PinnedRowTitle.Reading`). Bounded by
    /// the number of pinned rows Home has ever mounted — a handful of entries, each written only
    /// when the title's measured height actually changes.
    nonisolated(unsafe) private static var clearances: [String: PinnedRowTitle.Clearances] = [:]

    /// Publishes the FOCUSED row's geometry. Called from `pinnedRowSettleTracking`, main thread.
    nonisolated static func report(_ measurement: Measurement) {
        // A different row taking focus is a fresh epoch: the oscillation guard counts CONSECUTIVE
        // failed corrections on one row, never a session total.
        // Note the ordering: `invalidateEpoch` may schedule a settle, but that settle resolves a
        // full `settleDelay` later — long after the assignment below — so it always sees the NEW
        // row's measurement, which is the one it is meant to judge.
        if latest?.rowKey != measurement.rowKey { invalidateEpoch(rowGainedFocus: true) }
        latest = measurement
    }

    /// Focus left this row (or the row left pinned mode). Scoped by key so a stale clear from a
    /// row that lost focus AFTER another gained it can't wipe the live measurement.
    nonisolated static func clear(rowKey: String) {
        guard latest?.rowKey == rowKey else { return }
        latest = nil
        invalidateEpoch(rowGainedFocus: false)
    }

    /// Publishes whether a row's title is currently hidden by the visibility belt (Wave 9(a)).
    ///
    /// Two jobs, both diagnostic. It puts `beltFaded=` on the settle line, which is what makes the
    /// handoff observable at all — from a device log or from the harness's `debug_pinned` oracle,
    /// neither of which can see an `NSLog` or a zero-opacity view. And because the belt fires long
    /// after the settle that gave up on the rest, it re-arms one settle so a fresh line actually
    /// carries the new state; without that the last report would forever predate the fade.
    ///
    /// Same guards as the other backstops: only on a real change, only when nothing else is armed
    /// (so the paths cannot stale each other's tokens), and a clean stand-down with no scheduler.
    /// The re-armed settle cannot restart the corrector — a belt fire means the rest was already
    /// declared unsatisfiable, so `deficit` is 0 or the bound is spent and it declines again.
    nonisolated static func noteBeltFaded(rowKey: String, faded: Bool) {
        let changed = faded ? beltFadedRows.insert(rowKey).inserted : (beltFadedRows.remove(rowKey) != nil)
        guard changed, !armed, let scheduler else { return }
        let token = rearm()
        MainActor.assumeIsolated { scheduler(token) }
    }

    /// Drops a row's belt state because its title VIEW is going away — lazy eviction, leaving Home,
    /// a theme `.id()` swap (Codex Wave 9 r1).
    ///
    /// Separate from `noteBeltFaded(rowKey:faded: false)` on purpose, in both directions. It must
    /// not re-arm a settle: the row is being torn down, so there is nothing left to correct and
    /// nothing that should schedule work against it. And it must not be skipped: a faded title
    /// that disappears never passes back through `showAgain`, so without this its key outlived it.
    /// A recreated title then starts `faded == false` while every settle line still reported
    /// `beltFaded=1`, AND its next genuine fade computed `changed == false` — so the diagnostic
    /// settle was never re-armed and the stale `1` was the last word. test48 could have passed on
    /// state from a view that no longer existed. Removing the key here restores the invariant that
    /// `changed` tracks a live title, so the re-arm fires again after recreation.
    nonisolated static func clearBeltFaded(rowKey: String) {
        beltFadedRows.remove(rowKey)
    }

    /// Publishes one row's clearances — see `PinnedRowTitle.Clearances`.
    ///
    /// Codex r5 P2-1, second half: if a settle already declined for this row because the
    /// measurement had not arrived, the arrival itself has to be able to restart the mechanism —
    /// the page may be perfectly stationary by now, so no scroll event is coming. The re-check
    /// scheduled by that declining plan normally gets there first (the title publishes on its
    /// first geometry pass, well inside `settleDelay`); this covers the case where it did not, or
    /// where the caller's hop budget ran out. Re-arming only while nothing is `armed` keeps the
    /// two paths from staling each other's tokens and burning a hop for nothing.
    ///
    /// Codex r6: and the re-arm must be SCHEDULED, not just armed. `rearm()` alone left a settle
    /// nobody would ever run — the hop chain is spent and no scroll event is coming — so the row
    /// stayed uncorrected anyway. The token goes to the reveal modifier's own scheduler (see
    /// `scheduler`), which resolves it exactly the way every other deferred settle is resolved.
    ///
    /// `MainActor.assumeIsolated`: every writer in this enum is a SwiftUI geometry callback on the
    /// main thread — the same premise `nonisolated(unsafe)` already rests on throughout — and the
    /// scheduler closure touches the modifier's `@State`, so it is MainActor-isolated. This
    /// asserts that premise rather than hiding it behind a hop that would break the "one settle in
    /// flight" bookkeeping.
    nonisolated static func noteClearances(rowKey: String, clearances newValue: PinnedRowTitle.Clearances) {
        let wasLate = clearanceLatePending == rowKey && clearances[rowKey] == nil
        // Codex r10 P2: a clearance that actually CHANGED is the other reason to restart. The one
        // way it moves without geometry moving is a focus-mode toggle in Settings, which shifts
        // the correction target under a Home that may never scroll again on its own. Cheap to test
        // for: during a scroll this value is constant, so the comparison is false on every frame
        // and only a real mode/type/style change reaches the re-arm below.
        let changed = clearances[rowKey] != newValue
        clearances[rowKey] = newValue
        guard wasLate || changed else { return }
        if wasLate { clearanceLatePending = nil }
        guard !armed else { return }
        guard let scheduler else {
            // No pinned rows ScrollView has registered one — the corrector is not running in this
            // configuration at all, so there is nothing to resolve. Left un-armed deliberately.
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "clearance no-scheduler row=\(rowKey)")
            }
            return
        }
        let token = rearm()
        if HomeGeometryProbe.enabled {
            NSLog("[HomeScrollProbe] settle %@",
                  "\(wasLate ? "clearance-late" : "clearance-changed") rearm row=\(rowKey)")
        }
        MainActor.assumeIsolated { scheduler(token) }
    }

    /// Ends the current correction epoch: a different row has focus, so neither the oscillation
    /// counter nor an outstanding verification belongs to the situation any more.
    ///
    /// Codex r1 P2: `pendingVerification` used to survive a focus change, so a D-pad move issued
    /// between a correction firing and the next settle was measured against an offset the focus
    /// engine had legitimately moved away from — counted as a MISS. Two quick moves could then
    /// disarm the whole mechanism for the session. Only a correction whose own rest is still the
    /// one being looked at can testify about whether the scroll API landed where it was asked to.
    /// `rowGainedFocus` distinguishes the two callers, which want opposite things from the fresh
    /// settle this arms: `report` is a NEW row taking focus and is about to store its measurement,
    /// so the settle has something to judge; `clear` is focus leaving the rows, where there is
    /// nothing to correct and an armed settle would just be a phantom.
    nonisolated private static func invalidateEpoch(rowGainedFocus: Bool) {
        consecutiveNudges = 0
        pendingVerification = nil
        // Codex r2 P2-2: the in-flight window belonged to the OLD row's correction. Left standing,
        // it swallows the new row's very first settle — which is the one settle that matters,
        // because by then the scroll is stationary and no further geometry event will arm another.
        nudgeDeadline = nil
        // The waiting rest belonged to the OLD row; the new row will raise its own if it needs to.
        clearanceLatePending = nil
        // Codex r3 P2-2: stale every token scheduled for the OLD row. Resetting the correction
        // state alone left `generation` untouched, so a token armed before the focus change could
        // fire inside the NEW row's debounce window and compute a correction from a measurement
        // that has not settled yet — the new row must get its own full `settleDelay`, not inherit
        // the tail of the old row's. `rearm()` both stales the old tokens and arms that fresh
        // settle.
        let hadPendingBlock = armed
        let token = rearm()
        guard !hadPendingBlock else {
            // A deferred block is still out there. It will find its token stale and pick the fresh
            // epoch up itself (`settlePlan`'s superseded branch) — routing this through the
            // scheduler as well would only stale the token it is about to be handed.
            epochRearmPending = true
            return
        }
        // Codex r8 P2-2: nothing is pending, so nobody would ever run the settle we just armed.
        // That is the focus change that does not move the scroll — a horizontal hop onto a row
        // whose rest is already wrong — which used to go completely unevaluated. Same routing, and
        // the same stand-down, as the late-clearance backstop: the epoch change happens inside a
        // ROW's geometry callback, which has no scroll position and so cannot resolve anything.
        guard rowGainedFocus else {
            // Focus left the rows entirely; there is no measurement to judge and no correction to
            // make. Don't leave a phantom armed settle behind.
            armed = false
            return
        }
        guard let scheduler else {
            armed = false
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "epoch no-scheduler")
            }
            return
        }
        MainActor.assumeIsolated { scheduler(token) }
    }

    /// Records a scroll sample and returns a settle token to schedule against — or nil when a
    /// debounce is already armed and the motion since arming is within `driftTolerance` (the creep
    /// case), so a crawling rest arms exactly ONE timer instead of one per frame.
    nonisolated static func noteScroll(_ newSample: ScrollSample) -> Int? {
        let previous = sample?.offsetY
        sample = newSample
        let now = Date()
        let step: CGFloat? = previous.map { abs(newSample.offsetY - $0) }

        // Motion is classified by TWO independent tests, OR'd — deliberately not merged, because
        // they discriminate different things and a single threshold cannot do both jobs.
        //
        //  1. PER-SAMPLE step (`driftTolerance`, 4pt). The fast path: one big jump is obviously
        //     motion and must re-arm on the spot without waiting for a window to fill. This is
        //     also the test that keeps the LAZY-REALIZATION CREEP reading as stillness — measured
        //     at ~0.4pt/frame (14pt over 600ms), an order of magnitude under the threshold. If the
        //     creep ever re-armed the debounce, the settle would never fire at all and this whole
        //     mechanism would silently stop existing.
        //
        //  2. CUMULATIVE displacement over `motionWindowSeconds` (Codex r11 P2-1). A deceleration
        //     tail moving 2–4pt per callback passes test 1 (4 is not > 4) yet is unmistakably
        //     motion: at 60Hz that is 120–240pt/s. Sustained slow motion could therefore hold
        //     below the per-sample threshold for longer than `settleDelay`, letting a correction
        //     fire at 250ms and the belt fade at 700ms while the page was visibly moving. Path
        //     length over a short window is a velocity, which is the quantity that actually
        //     separates the two regimes:
        //
        //         creep          ~23pt/s  →   ~7pt per 300ms window   (still)
        //         slow-swipe tail 120pt/s →  ~36pt per 300ms window   (motion)
        //
        //     `motionWindowDisplacement` (18pt ≈ 60pt/s) sits between them with ~2.5x of margin on
        //     each side. Erring HIGH is the safe direction: too high merely lets a very slow tail
        //     read as a rest (cosmetic — the plan is computed from the live sample, and the next
        //     real move re-arms), while too low resurrects the never-fires bug.
        motionWindow.removeAll { now.timeIntervalSince($0.at) > motionWindowSeconds }
        if let step { motionWindow.append((at: now, delta: step)) }
        let windowed = motionWindow.reduce(CGFloat(0)) { $0 + $1.delta }
        let isMove = step.map { $0 > driftTolerance || windowed > motionWindowDisplacement } ?? true

        // Stamped on every real move, including the corrector's OWN animated scroll — which is how
        // the visibility belt gets its "is the page actually still?" signal, and how the corrector
        // keeps first refusal at every rest (Codex r2 P2-1; see `secondsSinceMotion`).
        if isMove { lastMotionAt = now }
        if armed, !isMove { return nil }
        generation &+= 1
        armed = true
        return generation
    }

    /// Installs the deferred-settle scheduler — see `scheduler`. Returns a generation id the
    /// caller passes back to `hostDidDisappear` so a teardown can only ever clear its OWN
    /// registration, never a newer one that has already replaced it.
    nonisolated static func registerScheduler(replacing previousID: Int,
                                              _ schedule: @escaping @MainActor (Int) -> Void) -> Int {
        // "A DIFFERENT host is taking over", not merely "a registration exists": a host whose
        // `onAppear` runs again without an intervening teardown passes its own live id back and is
        // a continuation, whose measurements are still its own.
        if scheduler != nil, previousID != schedulerGeneration {
            // Not fatal — a theme `.id()` swap legitimately overlaps two hosts for one update, and
            // the newer one is the right winner. Logged so a genuinely unexpected second pinned
            // rows ScrollView shows up in a device log instead of silently taking over.
            NSLog("[HomeScrollProbe] settle %@",
                  "scheduler REREGISTERED — a second pinned rows ScrollView installed one; the newer host wins")
            // Codex r11 round 2: the measurement cleanup has to happen HERE, not only in
            // `hostDidDisappear`. In the swap ordering this file already guards against elsewhere,
            // the INCOMING host registers first — bumping `schedulerGeneration` — so the outgoing
            // host's later `hostDidDisappear` fails its generation guard and returns without
            // clearing anything. The new host would then pair its first scroll sample with the old
            // host's `latest` row frame and could correct a row nothing has focused. The
            // replacement point is the unambiguous boundary: state from a host that is being
            // replaced can never be valid for the one replacing it.
            resetHostScopedState()
        }
        schedulerGeneration &+= 1
        scheduler = schedule
        return schedulerGeneration
    }

    /// Everything the corrector holds that belongs to ONE pinned rows ScrollView. Shared by the
    /// teardown path (`hostDidDisappear`) and the takeover path (`registerScheduler`), because a
    /// swap can deliver either one and only one of them.
    ///
    /// `clearances` deliberately survives: it is keyed by rowKey, not by host, and each row
    /// republishes on its first measurement anyway. Dropping it would only manufacture
    /// `clearance=?` declines on the way back in.
    nonisolated private static func resetHostScopedState() {
        pendingVerification = nil
        nudgeDeadline = nil
        armed = false
        epochRearmPending = false
        clearanceLatePending = nil
        consecutiveNudges = 0
        latest = nil
        sample = nil
        lastMotionAt = nil
        motionWindow.removeAll()
        standDownRow = nil
        // Belt state is host-scoped diagnostic state like everything else here: it describes titles
        // that belonged to the OUTGOING host's rows, and every one of them is being torn down with
        // it. A surviving key would make the incoming host's settle lines report `beltFaded=1` for
        // a freshly-mounted, un-faded title — and, worse, suppress the re-arm on its next real fade
        // (see `clearBeltFaded`). Each row republishes its own state on its first measurement.
        beltFadedRows.removeAll()
        // Stale every token handed out under the previous host, so nothing scheduled before the
        // handover can resolve against the new one's state.
        generation &+= 1
    }

    /// Tears the corrector's shared state down when its host goes away — but only if `id` is still
    /// the live registration. During a theme `.id()` swap SwiftUI inserts the incoming subtree
    /// BEFORE removing the outgoing one, so the outgoing view's `onDisappear` runs after the
    /// incoming view's `onAppear`; an unscoped teardown there would disable the corrector for the
    /// rest of the session and void a verification the INCOMING host is legitimately waiting on.
    ///
    /// Codex r8 P2-1: `pendingVerification` in particular must go. A correction whose host is
    /// leaving will never be judged fairly — whatever offset the view holds when it comes back is
    /// the product of focus restoration, not of the scroll API — and two false MISSes disarm the
    /// mechanism for the whole session. Everything else here is hygiene: no host means nothing can
    /// resolve an armed settle, so leaving one armed would be a phantom.
    /// Codex r11 P2-3: the MEASUREMENTS are host-scoped and must go too. A recreated pinned host
    /// publishes its first scroll sample before anything in it has taken focus, and `settlePlan`
    /// pairs whatever `sample` it is given with whatever `latest` it still holds — so a surviving
    /// row frame from the previous host would be combined with the new host's offset and could fire
    /// a correction for a row that is not even focused. `sample` goes with it so the first sample
    /// after recreation is treated as a first sample (motion, no step to compare), and the motion
    /// window with it so a stale path length cannot make a fresh page look busy. All of that lives
    /// in `resetHostScopedState`, which the takeover path calls too — this generation guard means
    /// this function alone cannot be relied on to run.
    nonisolated static func hostDidDisappear(_ id: Int) {
        guard id == schedulerGeneration else { return }
        scheduler = nil
        resetHostScopedState()
    }

    /// Re-arms a settle without a scroll event, returning a token to schedule against, and stales
    /// every token already scheduled. Callers: the in-flight retry (Codex r2 P2-2), the epoch
    /// re-check (Codex r3 P2-2), and `invalidateEpoch` itself. All three exist because the page is
    /// already stationary at those moments, so no further geometry event will ever arm another.
    nonisolated static func rearm() -> Int {
        generation &+= 1
        armed = true
        return generation
    }

    /// How long the rows scroll view has been still, in seconds — `.greatestFiniteMagnitude` when
    /// it has never moved this session (a title clipped at mount with no scrolling is at rest by
    /// any reading, and must still be allowed to fade).
    ///
    /// Exists for the visibility belt. The belt's own `onGeometryChange` cannot answer this: once
    /// a title saturates at the slide cap its `Reading` is byte-identical frame to frame, the
    /// observer stops firing, and a slow swipe that stays in the belt's band for longer than
    /// `fadeDelay` would let the hide timer expire MID-SCROLL — hiding a title while the page is
    /// visibly moving, which is not what "a settled rest still leaves it on the artwork" means.
    /// Motion is a property of the SCROLL, so it is measured here where the scroll is observed.
    nonisolated static func secondsSinceMotion() -> TimeInterval {
        guard let lastMotionAt else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(lastMotionAt)
    }

    /// Resolves a settle. Returns nil when this token was superseded (the page moved again), which
    /// is the "abandon the nudge if a new focus change or scroll starts" rule.
    nonisolated static func settlePlan(token: Int) -> Plan? {
        guard armed, let sample else { return nil }
        guard token == generation else {
            // Superseded. A supersede from a scroll event needs nothing — that event scheduled its
            // own resolution. A supersede from an EPOCH change does: it happened inside a row's
            // geometry callback, which cannot schedule anything (Codex r3 P2-2). Hand the caller
            // one re-check, a full debounce out, so the new row settles on its own interval.
            guard epochRearmPending else { return nil }
            epochRearmPending = false
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "epoch-rearm row=\(latest?.rowKey ?? "-")")
            }
            // Empty report: this is control flow, not a measured rest. Reporting it would put a
            // line with no `margin=` into the harness oracle (`debug_pinned`) between two real
            // ones — see the caller's `report.isEmpty` skip.
            return Plan(report: "", targetY: nil, retryAfter: settleDelay)
        }
        armed = false

        // Verify the PREVIOUS correction before planning another one.
        if let verification = pendingVerification {
            pendingVerification = nil
            let expected = verification.expectedY
            let error = sample.offsetY - expected
            // A reflow between fire and check (lazy row realization, an image landing, a row's
            // shelf regrowing) moves the content under the scroll view, so the landed offset says
            // nothing about the scroll API. Void rather than count it — Codex r1 P2.
            if abs(sample.contentHeight - verification.contentHeight) > 1 {
                NSLog("[HomeScrollProbe] settle %@",
                      "VOID expected=\(Int(expected.rounded())) landed=\(Int(sample.offsetY.rounded()))"
                        + " contentH=\(Int(verification.contentHeight.rounded()))→\(Int(sample.contentHeight.rounded()))")
            } else if abs(error) > verifyTolerance {
                verifyFailures += 1
                // %@ with an interpolated Swift String rather than %d varargs — the house NSLog
                // convention everywhere in this tree.
                NSLog("[HomeScrollProbe] settle %@",
                      "MISS expected=\(Int(expected.rounded())) landed=\(Int(sample.offsetY.rounded()))"
                        + " error=\(Int(error.rounded())) failures=\(verifyFailures)")
                if verifyFailures >= maxVerifyFailures {
                    disarmed = true
                    NSLog("[HomeScrollProbe] settle DISARMED — corrections are not landing where they were asked to; falling back to slide + fade only")
                }
            } else {
                verifyFailures = 0
            }
        }

        guard let m = latest else {
            return Plan(report: "row=- state=nofocus y=\(Int(sample.offsetY.rounded()))", targetY: nil)
        }

        let cap = maxSlideCapForReport
        let slide = min(max(-m.margin, 0), cap)
        let net = m.margin + slide
        var line = "row=\(m.rowKey) margin=\(Int(m.margin.rounded())) net=\(Int(net.rounded()))"
            // `protB` is what the correction is actually bounded by; on a mixed-shape row it sits
            // well above `rowB` (Codex r11 P2-2), and the gap between them is the room the old
            // row-bottom bound was throwing away.
            + " vh=\(Int(m.viewportHeight.rounded())) rowB=\(Int(m.rowBottom.rounded()))"
            + " protB=\(Int(m.protectedBottom.rounded()))"
            + " y=\(Int(sample.offsetY.rounded())) inset=\(Int(sample.insetTop.rounded()))"
            // Wave 9(a): the handoff, observable. `beltFaded=1` on a `nudge=0` line is the whole
            // contract working — the corrector gave the rest up and the belt took it.
            + " beltFaded=\(beltFadedRows.contains(m.rowKey) ? 1 : 0)"

        // The correction targets ARTWORK INTRUSION, not raw margin (Codex r1 P1) — and it measures
        // that intrusion against the FOCUSED card, not the row's resting geometry (Codex r4 P1).
        // The title rides over whichever card has focus, and the system focus lift has raised that
        // card's artwork by `heroPinnedRowFocusLiftAllowance` (~20pt measured, size-independent),
        // so the budget is the LIFTED clearance:
        //
        //     clearances.focused = clearances.atRest − liftAllowance      ≈ 26 − 20 = 6pt
        //     liftedIntrusion    = slide − clearances.focused             // what the viewer sees
        //     deficit            = −margin − clearances.focused           // how far the row must
        //                                                                 //   come DOWN to end it
        //
        // Gating on `margin < 0` instead fired on rests that were already clean (the sim run logged
        // `margin=-25 net=0 nudge=25`); a `net`-based gate has the opposite failure and misses a
        // rest that really does paint on the poster; and the PRE-LIFT intrusion — the metric every
        // earlier round used — was systematically 20pt optimistic, so its fixpoint still left the
        // focused card's artwork under the title. That was the blind spot the rc1 device log had:
        // `intr=46` was really 66 on the card being looked at.
        //
        // A corrected rest lands at `margin = −clearances.focused`, hence `slide =
        // clearances.focused` (6 ≪ the 72 cap, so the clamp is inactive) and therefore:
        //
        //     liftedIntrusion = 6 − 6 = 0     → nothing on the focused card's artwork
        //     net = margin + slide = −6 + 6 = 0 ≥ 0   → the title is still FULLY visible
        //
        // The two goals do not fight: the correction consumes exactly the clearance and no more.
        // (The ideal top rest, slide 0, sits at `liftedIntrusion = −6` — 6pt of daylight under the
        // title even with the card lifted, which is why that rest never drew a complaint.)
        //
        // No published clearances means this row's title has never measured itself (it isn't
        // mounted, or pinned mode isn't on) — fail safe and correct nothing.
        guard let clearance = clearances[m.rowKey] else {
            // Codex r5 P2-1: this is NOT a clean rest — it is a rest we could not judge yet,
            // because the row's title has not published its measurement. Treating it as closed
            // lost the rest entirely: `armed` was already false, and if `noteClearances` then
            // landed with the scroll stationary, nothing would ever re-schedule and the row stayed
            // uncorrected (with the belt free to hide its title instead). Ask for a re-check
            // instead — the title publishes on its first geometry pass, so a `settleDelay` of
            // grace is generous — and record the row so a clearance arriving after the hop budget
            // runs out can still re-arm (see `noteClearances`).
            consecutiveNudges = 0
            clearanceLatePending = m.rowKey
            if HomeGeometryProbe.enabled {
                NSLog("[HomeScrollProbe] settle %@", "clearance-late row=\(m.rowKey)")
            }
            return Plan(report: line + " nudge=0 clearance=?",
                        targetY: nil,
                        retryAfter: settleDelay)
        }
        clearanceLatePending = nil
        let liftedIntrusion = slide - clearance.focused
        let deficit = max(-m.margin - clearance.focused, 0)
        // `lift=` is reported separately from the two clearances because `focused` clamps at 0:
        // once the active treatment's lift exceeds the static clearance (ring mode at Large does,
        // ~27 vs 26), the difference between the two clearances stops telling you the magnitude.
        // In still mode this reads `lift=0 clearanceLift=26` — the whole point of Codex r7 P1.
        line += " clearance=\(Int(clearance.atRest.rounded()))"
            + " clearanceLift=\(Int(clearance.focused.rounded()))"
            + " lift=\(Int(clearance.lift.rounded()))"
            + " intr=\(Int((slide - clearance.atRest).rounded()))"
            + " intrLifted=\(Int(liftedIntrusion.rounded()))"
            + " deficit=\(Int(deficit.rounded()))"

        // A healthy rest closes the epoch: the guard counts consecutive FAILURES, so a row that
        // settles correctly gets its full budget back next time it needs one.
        guard deficit > 1 else {
            consecutiveNudges = 0
            return Plan(report: line + " nudge=0", targetY: nil)
        }
        guard !disarmed else { return Plan(report: line + " nudge=0 disarmed=1", targetY: nil) }
        // A correction is still animating — never stack a second one on top of it. Ask for one
        // re-check just past the deadline rather than dropping this rest (Codex r2 P2-2).
        if let deadline = nudgeDeadline, Date() < deadline {
            return Plan(report: line + " nudge=0 inflight=1",
                        targetY: nil,
                        retryAfter: max(deadline.timeIntervalSinceNow, 0) + 0.05)
        }
        guard consecutiveNudges < maxConsecutiveNudges else {
            standDown(rowKey: m.rowKey, reason: "exhausted")
            return Plan(report: line + " nudge=0 exhausted=1", targetY: nil)
        }

        // How far the content may move DOWN before the FOCUSED card's own lockup starts leaving
        // the viewport — see `Measurement.protectedBottom`, which is the row's bottom minus its
        // transparent chrome for a uniform-card row, and the focused tile's own extent for the
        // mixed-shape collection row (Codex r11 P2-2).
        let bottomRoom = m.viewportHeight - m.protectedBottom
        let correction = min(deficit, max(bottomRoom, 0), Theme.Size.heroPinnedRowSettleMaxNudge)
        guard correction >= 2 else {
            // Nothing useful left to give — the row is too tall for this viewport to show both its
            // title band and its card. The visibility belt handles the title from here.
            standDown(rowKey: m.rowKey, reason: "bound")
            return Plan(report: line + " nudge=0 bound=\(Int(bottomRoom.rounded()))", targetY: nil)
        }

        // Content-space vs offset-space: in Home's PINNED mode the rows ScrollView sits inside the
        // VStack under the hero header and carries `contentInsets.top == 0` (BUG-66 rig, 2026-08-27
        // — "pinned inset=0 vs classic 157"), so `contentOffset.y` and the probe's inset-corrected
        // `residual` are the same number and a relative correction is exact under either reading
        // of `ScrollPosition.scrollTo(y:)`. `inset=` is logged on every line, and the verification
        // above disarms the mechanism if that ever stops being true on hardware.
        let target = max(sample.offsetY - correction, -sample.insetTop)
        consecutiveNudges += 1
        nudgeDeadline = Date().addingTimeInterval(nudgeDuration + 0.2)
        pendingVerification = Verification(expectedY: target, contentHeight: sample.contentHeight)
        line += " nudge=\(Int((sample.offsetY - target).rounded())) bound=\(Int(bottomRoom.rounded())) n=\(consecutiveNudges)"
        if HomeGeometryProbe.enabled { NSLog("[HomeScrollProbe] settle %@", line) }
        return Plan(report: line, targetY: target)
    }

    /// Records — once per row, so a stationary rest logs one line and not one per settle — that
    /// the corrector has given this rest up and the visibility belt now owns it (Wave 9(a)). Purely
    /// diagnostic: the stand-down itself is the `guard`s above declining to nudge. Having it in the
    /// log is what lets a device pass distinguish "the corrector never tried" from "the corrector
    /// tried, could not, and handed over" — the exact question the hardware trace could not answer.
    nonisolated private static func standDown(rowKey: String, reason: String) {
        guard standDownRow != rowKey else { return }
        standDownRow = rowKey
        if HomeGeometryProbe.enabled {
            NSLog("[HomeScrollProbe] settle %@", "standdown row=\(rowKey) reason=\(reason) — belt owns this rest")
        }
    }

    /// The cap `net` is reported against — the same one `PinnedRowTitle.reading` binds with, so
    /// the settle line and the title line can never disagree about what "net" means.
    nonisolated private static var maxSlideCapForReport: CGFloat {
        PinnedRowTitle.maxSlideOverride ?? Theme.Size.heroPinnedRowTitleMaxSlide
    }
}

extension View {
    /// Publishes a PINNED row's own frame to the settle re-reveal while (and only while) one of
    /// its cards holds focus. Attach to the row's outer view, after `.focusSection()`.
    ///
    /// Attached unconditionally by all four pinned rows and gated INSIDE the geometry closure
    /// rather than by an `if` around the modifier: a conditional modifier around a whole row would
    /// re-identify that row's subtree every time focus entered or left it — poster pipelines torn
    /// down and rebuilt per D-pad step, the BUG-19 class. When the row is unfocused (or classic
    /// mode, where `rowCardTopReach` is 0) the closure returns nil constantly and nothing fires.
    ///
    /// `focusedLockupExtent` is for MIXED-SHAPE rows only — the distance from the row's top edge to
    /// the focused card's lockup bottom, when the row's own frame overstates it. Uniform-card rows
    /// leave it nil and keep exactly today's bound; see `PinnedRowSettle.Measurement`.
    func pinnedRowSettleTracking(rowKey: String,
                                 isFocused: Bool,
                                 focusedLockupExtent: CGFloat? = nil) -> some View {
        modifier(PinnedRowSettleTracking(rowKey: rowKey,
                                         isFocused: isFocused,
                                         focusedLockupExtent: focusedLockupExtent))
    }
}

private struct PinnedRowSettleTracking: ViewModifier {
    let rowKey: String
    let isFocused: Bool
    /// See `pinnedRowSettleTracking`. Constant per focused card, so it adds no observer fires.
    let focusedLockupExtent: CGFloat?
    /// Pinned mode is the only mode with an overlaid title to protect; 0 = classic, inert.
    @Environment(\.rowCardTopReach) private var cardTopReach

    func body(content: Content) -> some View {
        // Captured by value so the geometry closure holds a plain String and a Bool rather than
        // this (view-isolated) modifier — the same rule the title probe already follows.
        let key = rowKey
        let active = isFocused && cardTopReach > 0
        let lockupExtent = focusedLockupExtent
        // Wave 9(a): THREE states, not two. Collapsing "this row is not focused" and "the enclosing
        // scroll view didn't resolve this pass" into one `nil` is what livelocked the corrector
        // against the belt on hardware — see `PinnedRowSettle.clear` and the device trace in the
        // header. It is the same distinction Wave 4 item 6 already had to draw for the TITLE's own
        // measurement (`slideMeasurement` vs `slide`): an unmeasurable pass must HOLD, never clear.
        return content.onGeometryChange(for: PinnedRowSettle.MeasurementReport.self, of: { proxy in
            guard active else { return .inactive }
            guard let visible = PinnedRowTitle.visibleBounds(proxy) else { return .unmeasured }
            // `visible` is the rows viewport expressed in THIS ROW's local space, so `-minY` is
            // the row's top edge measured from the viewport's top edge — the same quantity, and
            // the same sign convention, as `PinnedRowTitle.rawMargin`.
            return .measured(PinnedRowSettle.Measurement(rowKey: key,
                                                         rowTop: -visible.minY,
                                                         rowHeight: proxy.size.height,
                                                         viewportHeight: visible.height,
                                                         focusedLockupExtent: lockupExtent))
        }, action: { newValue in
            switch newValue {
            case .measured(let measurement):
                PinnedRowSettle.report(measurement)
            case .unmeasured:
                // Hold. This row still holds focus and its last measurement is still the best
                // description of it; clearing here would end the correction epoch and hand the
                // corrector a fresh nudge budget for a rest it has already given up on.
                break
            case .inactive:
                PinnedRowSettle.clear(rowKey: key)
            }
        })
    }
}

/// Home's half of the settle re-reveal: watches the rows ScrollView's geometry, and when a rest
/// settles with the focused row's title clipped, animates the scroll down by exactly the shortfall
/// `PinnedRowSettle` computed. Only the rows ScrollView moves — the pinned hero is a sibling above
/// it in the VStack split and is untouched, by construction.
///
/// `enabled` is a per-call-site CONSTANT (see `HomeView.rowsScroll(pinned:settleReveal:)`), which
/// is what makes the `if` here safe: it resolves once per hero-container mode, never per scroll
/// frame and never at the `heroItems` empty→loaded boundary, so it can't re-identify the rows.
struct PinnedRowSettleRevealModifier: ViewModifier {
    let enabled: Bool
    /// DEBUG-only sink for the harness oracle (`debug_pinned`); nil in release, where nothing is
    /// written anywhere and the whole path is a static-storage update plus one scroll request.
    var onSettle: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition()
    /// Generation id of this host's scheduler registration, so teardown clears only its own —
    /// see `PinnedRowSettle.hostDidDisappear`. Written once on appear.
    @State private var schedulerID = 0
    /// The one deferred settle currently in flight (Codex r8 P2-1). Held in a reference box rather
    /// than as a `@State` value on purpose: `scheduleSettle` runs once per scroll frame during a
    /// reveal, and a `@State` write there would invalidate this modifier every frame — the exact
    /// churn `PinnedRowSettle`'s static storage exists to avoid. The box's identity is stable
    /// across body re-evaluations, so mutating `item` reaches the live work item either way.
    @State private var settleWork = SettleWorkBox()

    func body(content: Content) -> some View {
        if enabled {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: PinnedRowSettle.ScrollSample.self, of: { geo in
                    PinnedRowSettle.ScrollSample(offsetY: geo.contentOffset.y,
                                                 insetTop: geo.contentInsets.top,
                                                 contentHeight: geo.contentSize.height)
                }, action: { _, sample in
                    // nil = a debounce is already armed and this sample is within the creep
                    // tolerance of it, so there is nothing to schedule (see `noteScroll`).
                    guard let token = PinnedRowSettle.noteScroll(sample) else { return }
                    scheduleSettle(token: token,
                                   after: PinnedRowSettle.settleDelay,
                                   hops: Self.maxSettleHops)
                })
                // Codex r6: the late-clearance backstop arms a settle from a TITLE's geometry
                // callback, which has no scroll position and so cannot resolve it. Hand the
                // coordinator this host's scheduler so that path lands in exactly the same
                // deferred resolution every other settle uses — a fresh hop budget, since it
                // starts a new chain rather than continuing a spent one.
                .onAppear {
                    // `replacing:` is this host's own live id (0 before it has ever registered), so
                    // the coordinator can tell a re-`onAppear` from the SAME host apart from a
                    // different host taking over — only the latter invalidates the measurements.
                    schedulerID = PinnedRowSettle.registerScheduler(replacing: schedulerID) { token in
                        scheduleSettle(token: token,
                                       after: PinnedRowSettle.settleDelay,
                                       hops: Self.maxSettleHops)
                    }
                }
                // Codex r8 P2-1: a settle scheduled just before Home goes away would otherwise run
                // against a hidden view — `position.scrollTo(y:)` shifting the position the user
                // comes back to, and a verification nothing can land counting a false MISS toward
                // the session disarm. Cancelling the work item is unconditional (it is this
                // instance's own state, so it can never reach another host's); the SHARED teardown
                // is generation-scoped, because during a theme `.id()` swap this runs after the
                // incoming host's `onAppear`.
                //
                // Known limit, stated rather than implied: Home's own doc records that neither a
                // Detail push nor a tab switch fires `onDisappear` on its root, so this covers
                // teardown rather than every way the rows can stop being visible. A correction
                // that lands during a push is bounded anyway — the pop re-reveals the focused card
                // through the focus engine, and the returning focus change invalidates the epoch,
                // which voids the verification it would otherwise have failed.
                .onDisappear {
                    settleWork.item?.cancel()
                    settleWork.item = nil
                    PinnedRowSettle.hostDidDisappear(schedulerID)
                }
        } else {
            content
        }
    }

    /// Chain budget for `scheduleSettle`. Three hops covers the three ways a settle asks to be
    /// re-checked instead of resolved — an in-flight correction swallowing it (Codex r2 P2-2), a
    /// focus change re-arming a fresh epoch under it (Codex r3 P2-2), and a clearance that has not
    /// been published yet (Codex r5 P2-1) — while making the recursion terminate by construction
    /// rather than by argument. Each re-check is a `Plan` with no correction attached, so the
    /// worst case is three trivial main-queue hops before the mechanism gives up on one rest and
    /// waits for the next geometry event (or, for the clearance case, for `noteClearances` to
    /// re-arm it).
    private static let maxSettleHops = 3

    /// Resolves one settle after `delay`, applies whatever it decided, and re-arms once for the
    /// plans that ask for a re-check. Each re-check spends one hop, so the chain is bounded at
    /// `maxSettleHops` regardless of what the coordinator returns.
    ///
    /// Exactly ONE deferred block is ever pending: scheduling cancels whatever was already out
    /// there. That is not just bookkeeping for `onDisappear` — during a reveal `noteScroll` hands
    /// out a token per frame, and every earlier block is stale by construction (its token no longer
    /// matches `generation`), so cancelling them replaces a burst of no-op main-queue wakeups with
    /// a single live one. The retry path re-enters here from inside the running item; cancelling an
    /// already-executing `DispatchWorkItem` is a no-op, so the new item simply takes its place.
    private func scheduleSettle(token: Int, after delay: TimeInterval, hops: Int) {
        settleWork.item?.cancel()
        let work = DispatchWorkItem {
            guard let plan = PinnedRowSettle.settlePlan(token: token) else { return }
            // Control-flow plans carry no measurement and must not reach the harness oracle.
            if !plan.report.isEmpty { onSettle?(plan.report) }
            if let target = plan.targetY {
                if reduceMotion {
                    position.scrollTo(y: target)
                } else {
                    withAnimation(.easeOut(duration: PinnedRowSettle.nudgeDuration)) {
                        position.scrollTo(y: target)
                    }
                }
                return
            }
            if hops > 0, let retry = plan.retryAfter {
                scheduleSettle(token: PinnedRowSettle.rearm(), after: retry, hops: hops - 1)
            }
        }
        settleWork.item = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Reference box for the reveal modifier's single in-flight deferred settle — see
/// `PinnedRowSettleRevealModifier.settleWork` for why this is a class rather than a plain `@State`
/// value.
private final class SettleWorkBox {
    var item: DispatchWorkItem?
}

/// Reference box for a pinned title's last measured geometry — see
/// `PinnedRowTitleTracking.geometryCache` for why this is a class rather than a plain `@State`
/// value (written on every measurement; a state write there would invalidate per frame).
private final class TitleGeometryCache {
    var value: PinnedRowTitle.TitleGeometry?
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

    /// Sentinel `focusedItemId` value for the trailing See All tile (Codex r3 P2-1). A leading NUL
    /// makes it unrepresentable as an addon/TMDB catalog id, so it can never collide with a real
    /// item and none of the binding's other consumers can accidentally match it.
    private static let seeAllFocusKey = "\u{0}see-all"

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
                            // Codex r3 P2-1: the See All tile is part of THIS row, so the settle
                            // re-reveal has to count it as the row holding focus — otherwise
                            // focusing it cleared `focusedItemId`, the row stopped publishing its
                            // frame, and a Large rest reached with See All focused got no
                            // correction (title left on the artwork, or belt-hidden).
                            //
                            // Bound into the row's EXISTING `focusedItemId` under a sentinel rather
                            // than added as a second `@FocusState`: the sentinel can never equal a
                            // catalog item's id, so every other consumer of this binding is
                            // byte-identical. `onChange` still resolves it to no item and reports
                            // `nil` to the hero (exactly what focusing See All did before), and
                            // `muteToggle(for:)` still never matches it. Only the settle
                            // tracker's `focusedItemId != nil` test changes meaning.
                            .focused($focusedItemId, equals: Self.seeAllFocusKey)
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
                            .pinnedRowTitleTracking(rowKey: section.key,
                                                    artworkHeight: rowArtworkHeight,
                                                    isFocused: focusedItemId != nil)
                            .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .focusSection()
        // Settle re-reveal (2026-08-30): publishes this row's frame while it holds focus, so a
        // rest that parks its title under the pinned clip edge can be corrected once the scroll
        // settles. Inert in classic mode and while unfocused — see `pinnedRowSettleTracking`.
        // `focusedItemId != nil` covers the trailing See All tile too, via `seeAllFocusKey` —
        // that tile is part of this row and its rests need the same correction (Codex r3 P2-1).
        .pinnedRowSettleTracking(rowKey: section.key, isFocused: focusedItemId != nil)
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
