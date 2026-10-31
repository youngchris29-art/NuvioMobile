import SwiftUI

/// BUG-92 (beta.18 follow-up): the tester's original report ("inline trailer on the GIGN card sits
/// offset — dark band between the [ring] and the video") was fixed by `InlineTrailerTileGeometry`
/// concentering the video inside the reserved ring band. A second report on the SAME bug number
/// followed: with **No Zoom ON** (`CardFocusButtonStyle` swaps to `StillCardButtonStyle` +
/// `.focusEffectDisabled(true)` — zero system lift, see `PosterCard.swift`), accent ring OFF, Card
/// Depth ON, the inline trailer spills past the poster's edge — but *only on the FIRST (left-most)
/// card of a row*.
///
/// Root cause: every catalog row's horizontal `ScrollView` carries `.scrollClipDisabled()`
/// (`BrowseComponents.swift` ~L3107) so a focused card's own lift/reach/ring bleed is never
/// clipped — by design: that bleed is meant to land OVER the focused card's left neighbour, which
/// is invisible because the neighbour is already there, drawn on top. The first card in a row has
/// no left neighbour. Its bleed lands on the empty overscan margin outside the row's own content
/// instead — nothing hides it there, which is exactly the "spills past the edge" the tester saw.
/// (`.shadow(...)` outside the tile's `.clipShape`, sub-pixel rounding in
/// `InlineTrailerTileGeometry.inner`, and the expanding tile's rightward growth were all
/// investigated as the source of the bleed itself; none of them are what makes it VISIBLE only on
/// card #1 — `.scrollClipDisabled()` is.)
///
/// `RowLeadingEdgeClip` clips ONLY the row's leading edge. Every other side is left ~2000pt open so
/// this can never accidentally reach into something BUG-92 was never about: a card's vertical lift,
/// the row's own top/bottom reach-band padding, or the inline-trailer morph's RIGHTWARD tile growth
/// (UX-4a). It composes with `.scrollClipDisabled()` as a single `.clipShape` on the row's
/// CONTENT — never on the `ScrollView` itself, which would silently undo
/// `.scrollClipDisabled()`'s whole effect for every other card in the row.
///
/// ## How BrowseComponents should attach this (NOT done here — a different wave owns that file)
///
/// (Historical. BUG-164 moved the allowance rule into `rowAllowance` below; `CatalogRowView` calls it.)
///
/// Attach the clip to the `LazyHStack` — the `ScrollView`'s CONTENT — right where
/// `.scrollClipDisabled()` already lives, in `CatalogRowView.body` (`BrowseComponents.swift`
/// ~L3044-3107):
///
/// ```swift
/// LazyHStack(spacing: Theme.Spacing.rowGap) {
///     // ... ForEach(section.items) { ... }, the trailing "See All" card ...
/// }
/// .padding(.vertical, Theme.Spacing.lg)          // unchanged, already there
/// .clipShape(RowLeadingEdgeClip(allowance: leadingEdgeAllowance))   // NEW — attach here
/// .scrollClipDisabled()                          // unchanged, already there
/// ```
///
/// `leadingEdgeAllowance` needs two AppStorage reads `CatalogRowView` doesn't have yet
/// (`PosterCard.swift`'s own copies, same keys):
///
/// ```swift
/// @AppStorage("accent_focus_ring") private var accentFocusRing = false
/// @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
///
/// private var leadingEdgeAllowance: CGFloat {
///     let posterWidth = posterStyle.cardWidth   // BUG-162: the row's real resting card width
///     // No lift at all in No Zoom mode (`CardFocusMode.still`) — only the ring can bleed there.
///     // Otherwise this is `PosterCard.swift`'s own `cardLiftScale(artworkHeight:)` formula
///     // inlined — that function is `private` to PosterCard.swift, so this recomputes it from the
///     // SAME public constant (`Theme.Size.heroPinnedRowFocusLiftAllowance`) rather than exposing
///     // a new cross-file symbol for one call site. If `cardLiftScale` is ever made internal,
///     // prefer calling it directly instead of keeping two copies of this formula in sync by hand.
///     let liftScale = noZoomOnFocus ? 1 : 1 + 2 * Theme.Size.heroPinnedRowFocusLiftAllowance / rowArtworkHeight
///     // Mirrors PosterCard.swift's `ringInset(accentFocusRing:noZoomOnFocus:)` — either ring
///     // reserves the same band.
///     let ring: CGFloat = (accentFocusRing || noZoomOnFocus) ? ringWidth : 0
///     return RowLeadingEdgeClip.allowance(posterWidth: posterWidth, liftScale: liftScale, ringWidth: ring)
/// }
/// ```
///
/// (`rowArtworkHeight` and `posterStyle` are both already properties of `CatalogRowView`;
/// `ringWidth` is `PosterCard.swift`'s top-level constant, already visible module-wide.)
struct RowLeadingEdgeClip: Shape {
    /// How far past the row's leading (left) edge a focused first card may bleed before being cut
    /// off. 0 clips flush to the row's own leading edge — the right answer for a row with no lift
    /// and no ring (nothing ever bleeds).
    var allowance: CGFloat

    func path(in rect: CGRect) -> Path {
        // Wide open on every side except leading. 2000pt is comfortably past anything a focus
        // lift, a ring, a reach band, or the inline-trailer morph's rightward growth could ever
        // bleed by — it exists purely so this shape can never accidentally clip a direction
        // BUG-92 was never about, not because any of those bleeds are expected to approach it.
        let overscan: CGFloat = 2000
        let clipped = CGRect(
            x: rect.minX - allowance,
            y: rect.minY - overscan,
            width: rect.width + allowance + overscan * 2,
            height: rect.height + overscan * 2
        )
        return Path(clipped)
    }

    /// The bleed a focused card's lift + ring can put outside its own layout frame, in points —
    /// what `allowance` above should be set to for a given row.
    ///
    /// - `posterWidth`: the row's card width at rest (`PosterStyle.width`, or
    ///   `PosterStyle.cardWidth` for landscape rows) — what the lift scales ABOUT THE CENTRE
    ///   of, so half of the width growth bleeds left and half right.
    /// - `liftScale`: the scale factor a focused card's artwork is drawn at. `1.0` means no lift
    ///   bleed at all — only `ringWidth` and the shadow then contribute. (BUG-164: No Zoom no longer
    ///   comes through here; `rowAllowance` gives it `shadowReach()`.) A zoom-on row should pass the same per-artwork-height scale
    ///   `PosterCard.swift`'s `cardLiftScale(artworkHeight:)` computes (both `.systemLift` and
    ///   `.manualScale` are calibrated to the identical `Theme.Size.heroPinnedRowFocusLiftAllowance`
    ///   rise, so one formula covers both — see the attachment snippet above for why this file
    ///   recomputes it instead of calling that `private` function directly).
    /// - `ringWidth`: the reserved ring band in points, `0` when neither focus ring is active —
    ///   pass `PosterCard.swift`'s top-level `ringWidth` constant (4pt) when `accent_focus_ring` or
    ///   `no_zoom_on_focus`'s still ring is on, mirroring that file's own `ringInset(...)`.
    ///
    /// `ceil`, not a bare half-width: a fractional point of uncovered bleed is exactly the "thin
    /// dark sliver" shape BUG-92 is about, and over-provisioning the clip by rounding UP costs
    /// nothing a 10-foot viewer would ever notice.
    /// The focused card's drop shadow (`PosterCard` `.shadow(radius: 22, y: 10)` in every style,
    /// including the No Zoom `.still` style; `InlineTrailerCard`'s tile shadow is the same 22 when
    /// no ring band is active). Codex beta.18 r2 (P2): the allowance used to cover only the lift
    /// bleed and the ring, so the first card's shadow was sliced into a hard vertical edge on
    /// every row. The shadow is a blur, so its visible extent is its radius.
    static let cardShadowRadius: CGFloat = 22

    /// beta.18 verdict (BUG-118, R3): in Row Edge Fade Soft the app-drawn `RowSoftEdgeMask` owns
    /// the leading edge (it reproduces BUG-92's rest-state cut itself), so the clip is pushed far
    /// enough out (400 pt) that it never cuts anything the mask has not already handled.
    /// beta.19-rc1 verdict (F, FEAT-54): Soft is an option of the Appearance setting `row_edge_fade`
    /// now (Off is the default since the F.5 frame-time gate) — `CatalogRowView` picks this allowance
    /// when `RowEdgeFadeSetting` resolves to `.soft`. 400 still clears the mask's leading margin (≤ 140 pt standard) with room to spare.
    nonisolated static let softModeAllowance: CGFloat = 400

    static func allowance(posterWidth: CGFloat, liftScale: CGFloat, ringWidth: CGFloat,
                          shadowRadius: CGFloat = cardShadowRadius) -> CGFloat {
        ceil(posterWidth * (liftScale - 1) / 2) + ringWidth + shadowRadius
    }

    // ── BUG-164 (Steven, beta.19-rc4 verdict 2026-10-16) ──────────────────────────────────────────
    //
    // "The poster on the far left was partially cut off along its left edge … the bug occurs when I
    // enable No Zoom on Focus", plus "a visual glitch on the left side of the screen when the trailer
    // for the poster on the far left is playing". With No Zoom ON the old allowance collapsed to
    // ring (4) + shadow radius (22) = 26 pt, because `liftScale` was 1. What the first card really
    // draws past its leading edge in No Zoom:
    //
    // - the still ring: nothing. It is a `strokeBorder` INSIDE the card frame (PosterCard's
    //   `CardFocusTreatment.still`, the inline tile's `.strokeBorder`), and the artwork is inset by
    //   the reserved 4 pt band.
    // - the still focus shadow (`CardFocusTreatment.still`: a black fill at the card's frame,
    //   `.shadow(color: .black.opacity(0.6), radius: 22, y: 10)`): measured with `ImageRenderer`,
    //   it darkens the background 29 % at the edge, 7.1 % at 26 pt (where the clip cut it: a hard
    //   vertical line on the Stage's bright wash), 1.2 % at 42, 0.8 % at 44, one 8-bit step from 46
    //   and 0 by 50. The visible reach of a SwiftUI shadow is about TWICE its radius, not its radius.
    // - the inline trailer tile: nothing. It grows out of the poster's top-LEADING corner
    //   (`InlineTrailerCard.expandingCard`, rightward only, UX-4a), its shadow is 0 whenever a ring
    //   band is reserved (No Zoom reserves one), and since BUG-164 it no longer draws Batch A's
    //   BUG-158 manual lift in No Zoom (`CardSystemLiftStyle.resolve`). Before that fix the tile
    //   scaled about its centre by `1 + 2 × 20 / h`, i.e. 16/9·h × 20/h = 35.6 pt to the left at
    //   EVERY poster size, plus a radius-22 shadow, against the 26 pt opening: the "glitch" while
    //   the far-left trailer plays.
    //
    // So the No Zoom branch opens for the shadow's visible reach (44 pt) and nothing else. The
    // zoom-on branch is the formula above, unchanged and byte-identical (its lift bleed already
    // carries the 16:9 tile width; `RowLeadingEdgeClipTests` pins both).

    /// BUG-164: how far past the casting edge a drop shadow stays visible, per point of radius
    /// (measured, see above: ≤ 0.8 % darkness from 2 × radius out).
    static let shadowReachPerRadius: CGFloat = 2

    /// BUG-164: the visible reach of a `.shadow(radius:)` past the view that casts it.
    static func shadowReach(radius: CGFloat = cardShadowRadius) -> CGFloat {
        ceil(radius * shadowReachPerRadius)
    }

    /// The leading-edge allowance a catalog row opens for its first card (`CatalogRowView`), as a
    /// pure function of the two Appearance settings and the row's card geometry.
    ///
    /// - `noZoomOnFocus`: No Zoom on Focus. Nothing scales and every ring draws inside the card, so
    ///   only the still focus shadow bleeds: `shadowReach()` (BUG-164).
    /// - `accentFocusRing`: adds `ringWidth` to the zoom-on branch, as before (`ringInset`'s rule).
    /// - `restingWidth`: the row's card width at rest (portrait poster or landscape card).
    /// - `artworkHeight`: the row's artwork height (the lift scale and the 16:9 tile derive from it).
    /// - `liftRise`: the zoom-on lift's rise (`Theme.Size.heroPinnedRowFocusLiftAllowance`).
    ///
    /// Zoom-on: Codex beta.18 r4 (P2): the widest thing the first card can be is the EXPANDED inline
    /// trailer tile (`artworkHeight × 16/9`), and the lift scales that whole label, so the bleed is
    /// sized off the maximum, not the resting width. The scale is `PosterCard.swift`'s
    /// `cardLiftScale(artworkHeight:)` formula, inlined here from the same constant so this stays a
    /// pure, parameter-driven function (`liftRise` is passed in, not read from a global).
    static func rowAllowance(noZoomOnFocus: Bool, accentFocusRing: Bool, restingWidth: CGFloat,
                             artworkHeight: CGFloat, liftRise: CGFloat) -> CGFloat {
        if noZoomOnFocus { return shadowReach() }
        let posterWidth = max(restingWidth, artworkHeight * 16 / 9)
        let liftScale = 1 + 2 * liftRise / artworkHeight
        return allowance(posterWidth: posterWidth,
                         liftScale: liftScale,
                         ringWidth: accentFocusRing ? ringWidth : 0)
    }
}
