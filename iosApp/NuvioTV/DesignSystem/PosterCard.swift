import SwiftUI

/// The standard portrait poster lockup used across catalog rows, search results, and "more like
/// this".
///
/// HIG revamp (see docs/design/hig-hybrid-contract.md): focus motion is the SYSTEM's job now.
/// Use this view as the label of a `Button`/`NavigationLink` with `.buttonStyle(.borderless)` —
/// on tvOS the borderless style gives the artwork the native lockup treatment (lift, real
/// Siri-Remote-tracking parallax, specular highlight, shadow) while the title below rides along
/// unscaled, exactly like the system TV app. No accent rings, no custom scale/tilt.
///
/// ```swift
/// NavigationLink(value: route) { PosterCard(title: item.name, imageURL: item.poster) }
///     .buttonStyle(.borderless)
///     .posterButtonShape()   // BUG-25: without this the system radius overrides Corners
/// ```
/// BUG-25 (beta.8 regression): the borderless button style rounds its label artwork with a
/// SYSTEM corner radius, silently overriding the card's own `clipShape` — which is driven by
/// the user's Poster Style → Corners setting. `buttonBorderShape` is the supported lever for
/// the lockup's radius, so every card button attaches this modifier to make Corners visible
/// again (Square/Rounded/Round all rendered identically without it).
struct PosterButtonShape: ViewModifier {
    @Environment(\.posterStyle) private var style

    func body(content: Content) -> some View {
        content.buttonBorderShape(.roundedRectangle(radius: style.cornerRadius))
    }
}

extension View {
    /// Follow the user's Poster Style corner radius on a borderless card button — see
    /// [PosterButtonShape].
    func posterButtonShape() -> some View { modifier(PosterButtonShape()) }
}

/// FEAT-14 accent focus ring (final architecture — the third and last one, 2026-08-02): the ring
/// is a `.strokeBorder` drawn INSIDE the artwork's own `RoundedRectangle`, identical to the
/// inline-trailer surface's ring in `InlineTrailerCard` — same shape, same color, same 4pt width,
/// same "paints inside my own clipped bounds" contract. What changed in this final pass is the
/// hover treatment around it: when the ring is on, the card no longer uses the system
/// `.hoverEffect(.highlight)` at all. Instead it applies a manual `.scaleEffect` (see
/// `CardFocusTreatment` below) so the ring and the artwork scale up together as one layer, drawn
/// by SwiftUI in a single pass rather than composited by the system lift.
///
/// Why the swap is necessary (framebuffer-verified on tvOS 26 hardware, 2026-08-02): the system
/// `.hoverEffect(.highlight)` composites the artwork into its own lifted/scaled layer, and
/// SwiftUI shape overlays living in the same subtree do NOT get pulled into that layer — they
/// stay at base geometry. So no matter where the ring overlay sits relative to `.hoverEffect`,
/// the artwork's lifted/scaled copy ends up covering it, and device photos showed red corner arcs
/// of the ring peeking out from under the lifted artwork — a hardware compositor behavior the
/// Simulator does not reproduce. The inline-trailer ring never hit this because that surface
/// doesn't use `.hoverEffect` in the first place; ring mode now borrows that surface's approach
/// (a manual, SwiftUI-owned lift) instead of trying to make the system lift cooperate.
///
/// Graveyard (do not resurrect):
/// - Outside overpaint — a stroke drawn outside the artwork's own clip bounds: got clipped by the
///   row/lockup's layout bounds, cutting off the outer edge of the ring.
/// - Outside flush ring — `.padding(-ringOffset)` plus a transparent `ringMargin` grown around the
///   label to keep the overpaint inside the button's layout bounds so the hardware lockup
///   wouldn't clip it. Survived the clip problem, but device photos under the hover lift's shadow
///   showed the ring reading as a detached glow/halo behind the poster, not a border on it.
/// - Inside `strokeBorder` under the SYSTEM hover lift — geometrically the cleanest of the three
///   (same shape, same clip, "scales with the card as one unit" on paper), except on hardware the
///   system lift doesn't actually pull the overlay into its lifted layer, so the artwork's scaled
///   copy covers the ring at the corners. This is the failure the manual-scale swap above fixes.
private let ringWidth: CGFloat = 4      // thicker for 10-foot visibility

/// FEAT-14: approximates the magnitude of the system `.hoverEffect(.highlight)` lift, used by
/// `CardFocusTreatment`'s manual scale so ring mode's focused size roughly matches the size a
/// focused card would have under the default (non-ring) hover treatment.
private let cardRingLiftScale: CGFloat = 1.06

/// FEAT-14: swaps the whole-card hover treatment between the system lift (default, ring OFF) and
/// a manual scale (ring ON) — see the file-level comment above for why the swap exists. Shared by
/// both `PosterCard` and `LandscapeCard` so the branch isn't duplicated at each call site.
///
/// - `ringMode == false`: today's exact chain, byte-identical to pre-FEAT-14 —
///   `.contentShape(.hoverEffect, …)` + `.hoverEffect(.highlight)`.
/// - `ringMode == true`: no `.hoverEffect` at all; a `.scaleEffect` keyed to `isFocused` stands in
///   for it, animated on focus change. Reduce Motion is honored explicitly here (the system lift
///   respects it automatically, but a manual `.scaleEffect` does not) by skipping the animation
///   and snapping straight to the focused/unfocused scale — the ring still needs to reach its
///   scaled geometry so it stays aligned with the artwork, so scale itself is kept, not skipped.
struct CardFocusTreatment: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ringMode: Bool
    let isFocused: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if ringMode {
            content
                .scaleEffect(isFocused ? cardRingLiftScale : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        } else {
            content
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius))
                .hoverEffect(.highlight)
        }
    }
}

/// FEAT-14: the ring's draw color, factored out of the two call sites below so they can't drift
/// apart — and so `InlineTrailerCard`'s inline-trailer surface can draw the identical color.
/// Device finding (2026-08-02): when a focused poster dwell-morphs into the inline trailer, the
/// landscape surface had no ring of its own, so the accent ring visibly vanished the instant the
/// morph fired. Pure extraction of the pre-existing `hex → focusRingHex → Color` derivation —
/// same fallback to `accentFocus` on a bad/empty hex — so this refactor changes no on-screen
/// behavior at either PosterCard call site.
extension Theme.Palette {
    static var focusRingColor: Color {
        Color(hexString: focusRingHex(accentFocusHex: accentFocusHex)) ?? accentFocus
    }
}

struct PosterCard: View {
    let title: String
    let imageURL: String?
    /// Explicit sizes override the environment style (used by the small "more like this" / credit
    /// rails); leave nil to follow the user's Poster Style setting.
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var showTitle: Bool? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    /// FEAT-14: opt-in accent focus ring, default OFF. Read independently (same UserDefaults key
    /// as `AppearanceSettingsPane`'s toggle) rather than threaded through props, so every card
    /// picks up the setting without a prop-drilling pass through every call site. When OFF the
    /// `if` below emits no overlay at all — no extra view/layer exists in the tree, keeping the
    /// OFF render byte-identical to pre-FEAT-14.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false

    private var resolvedWidth: CGFloat { width ?? style.width }
    private var resolvedHeight: CGFloat { height ?? style.height }
    private var titleVisible: Bool { showTitle ?? style.showTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match LandscapeCard and expandedTile
            CachedAsyncImage(string: imageURL)
                .frame(width: resolvedWidth, height: resolvedHeight)
                // BUG-31: CachedAsyncImage is `.fill` with no clip of its own, and this frame is
                // always exactly 2:3 — so off-ratio artwork overflows it and the hover lift copies
                // the overflow too, drawing a ghost-doubled subject. Clip inside the frame first.
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
                // FEAT-14 (final): the ring overlay sits BEFORE the hover/lift chain below, so it's
                // part of the content the hover/lift treatment scales with the artwork — same
                // ordering, and same inside-strokeBorder treatment, as the trailer surface's ring in
                // `InlineTrailerCard`. See the file-level comment above for why this replaced the
                // earlier outside-flush-ring geometry, and for why ring mode's hover treatment below
                // is no longer the system `.hoverEffect`.
                .overlay {
                    if accentFocusRing && isFocused {
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .strokeBorder(Theme.Palette.focusRingColor, lineWidth: ringWidth)
                    }
                }
                // Whole-card lift: without this the hover/lift treatment lands on the inner Image,
                // so the artwork parallaxes INSIDE a static clipped edge (device feedback). Tagging
                // the clipped container makes the entire card — edge included — lift and track the
                // remote (or, in ring mode, the manual scale) as one object.
                // BUG-31/BUG-25: pin the highlight's geometry to the card's own Corners radius so the
                // lift can't fall back to a system rect that extends past the artwork.
                .modifier(CardFocusTreatment(ringMode: accentFocusRing, isFocused: isFocused, cornerRadius: style.cornerRadius))

            if titleVisible {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: resolvedWidth, alignment: .leading)
            }
        }
        // FEAT-14: ring mode's manual scale (see `CardFocusTreatment`) isn't lifted into a
        // separate compositor layer the way the system hover effect is, so without an explicit
        // zIndex a focused card can render underneath its unfocused row neighbors instead of
        // above them. The system lift raised the focused card above its siblings implicitly;
        // this is the explicit equivalent, scoped to ring mode only so the default (system-lift)
        // path's stacking is completely untouched.
        .zIndex(accentFocusRing && isFocused ? 1 : 0)
    }
}

/// Landscape (16:9) lockup used for the Continue Watching row: artwork with a progress bar and a
/// title that brightens on focus. Same system focus language as `PosterCard` — use with
/// `.buttonStyle(.borderless)`.
struct LandscapeCard: View {
    let title: String
    let imageURL: String?
    /// 0...1 watched fraction; pass nil to hide the progress bar.
    var progress: Double? = nil
    var width: CGFloat = Theme.Size.landscapeWidth
    var height: CGFloat = Theme.Size.landscapeHeight
    var showTitle: Bool? = nil
    /// Card-depth surface this landscape card belongs to — Continue Watching by default; catalog rows
    /// rendered in landscape mode pass `.posters` so the depth toggles map to the right setting.
    var depthSurface: CardDepthSurface = .continueWatching

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    /// FEAT-14: opt-in accent focus ring, default OFF — see `PosterCard`'s copy of this property
    /// for the full rationale (same UserDefaults key, same byte-identical-when-OFF guarantee).
    @AppStorage("accent_focus_ring") private var accentFocusRing = false

    private var titleVisible: Bool { showTitle ?? style.showTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match PosterCard and expandedTile
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: imageURL)
                    .frame(width: width, height: height)
                    // BUG-31: same fill-overflow → hover-lift ghosting as PosterCard; artwork whose
                    // ratio isn't 16:9 spills out of this fixed frame unless clipped here.
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                    .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: depthSurface)

                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle()
                                .fill(Theme.Palette.progress)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 6)
                }
            }
            .frame(width: width, height: height)
            // FEAT-14 (final) — see PosterCard's copy of this overlay for the full rationale. The
            // ring overlay sits BEFORE the hover/lift chain below, so it's part of the content the
            // hover/lift treatment scales with the artwork/progress-bar group as one, using the
            // same inside-strokeBorder treatment as the trailer surface's ring in `InlineTrailerCard`.
            .overlay {
                if accentFocusRing && isFocused {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(Theme.Palette.focusRingColor, lineWidth: ringWidth)
                }
            }
            // Whole-card lift — see PosterCard: the progress bar and artwork move as one, whether
            // that's the system lift (default) or the manual scale (ring mode).
            // BUG-31/BUG-25: pin the highlight geometry to the card's own Corners radius.
            .modifier(CardFocusTreatment(ringMode: accentFocusRing, isFocused: isFocused, cornerRadius: style.cornerRadius))

            if titleVisible {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: width, alignment: .leading)
            }
        }
        // FEAT-14: see `PosterCard`'s copy of this zIndex for the full rationale — ring mode's
        // manual scale needs an explicit zIndex to draw above row neighbors the way the system
        // lift did implicitly; scoped to ring mode only, default path's stacking is untouched.
        .zIndex(accentFocusRing && isFocused ? 1 : 0)
    }
}
