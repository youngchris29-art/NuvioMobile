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

/// FEAT-14 accent focus ring geometry (device-verified geometry fix): the ring must float just
/// OUTSIDE the poster's edge, not overlap the artwork. `strokeBorder` on the artwork's own
/// `RoundedRectangle` draws fully inside the shape bounds — since that shape equals the artwork
/// frame, the ring rendered on top of the image (the bug). Both ring sites below instead draw an
/// outward-offset ring using these two constants; see the arithmetic comment at each call site.
private let ringWidth: CGFloat = 3
/// Gap between the artwork's outer edge and the ring's inner edge.
private let ringGap: CGFloat = 2

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
                // Whole-card system lift: without this the borderless hover effect lands on the
                // inner Image, so the artwork parallaxes INSIDE a static clipped edge (device
                // feedback). Tagging the clipped container makes the entire card — edge included —
                // lift and track the remote as one object.
                // BUG-31/BUG-25: pin the highlight's geometry to the card's own Corners radius so the
                // lift can't fall back to a system rect that extends past the artwork.
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: style.cornerRadius))
                .hoverEffect(.highlight)
                // FEAT-14: opt-in accent focus ring — layered after the hover/lift chain so it
                // rides along with the system lift rather than sitting on a static base. Aligned
                // to the same Corners radius as the clip/hover geometry above.
                .overlay {
                    if accentFocusRing && isFocused {
                        // BUG (device-verified): `strokeBorder` insets its stroke fully inside the
                        // shape it strokes, and that shape was the artwork's own bounds — so the
                        // ring rendered ON TOP of the poster instead of around it. Fix: draw the
                        // ring on a RoundedRectangle whose path is offset outward from the artwork
                        // edge by `ringOffset = ringGap + ringWidth / 2`, then pull its layout frame
                        // back in by the same `ringOffset` via negative padding (this is the
                        // standard "ring drawn outside my own frame" trick — the shape still paints
                        // at its true, larger geometry; only the reported layout size shrinks back
                        // to the artwork's frame, and nothing here clips the overpaint).
                        // `.stroke` centers its line ON the path, so the painted ring spans from
                        // (ringOffset - ringWidth/2) = ringGap outside the artwork, to
                        // (ringOffset + ringWidth/2) = ringGap + ringWidth outside — i.e. exactly a
                        // ringGap-wide gap followed by a ringWidth-wide ring, as required.
                        // Offsetting a rounded rect's boundary uniformly outward by `ringOffset`
                        // keeps the corners concentric by growing the radius by that same amount,
                        // which is why `cornerRadius: style.cornerRadius + ringOffset` below must
                        // use the identical `ringOffset` as the `.padding(-ringOffset)` call. When
                        // style.cornerRadius is 0 (Square corners) the shape's radius is still
                        // `ringOffset` (> 0), so the ring's corners are gently rounded rather than
                        // sharp-clipped, and since ringGap/ringWidth are fixed positive constants
                        // the radius can never go negative.
                        let ringOffset = ringGap + ringWidth / 2
                        RoundedRectangle(cornerRadius: style.cornerRadius + ringOffset)
                            .stroke(Color(hexString: Theme.Palette.focusRingHex(accentFocusHex: Theme.Palette.accentFocusHex)) ?? Theme.Palette.accentFocus, lineWidth: ringWidth)
                            .padding(-ringOffset)
                    }
                }

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
            // Whole-card system lift — see PosterCard: the progress bar and artwork move as one.
            // BUG-31/BUG-25: pin the highlight geometry to the card's own Corners radius.
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: style.cornerRadius))
            .hoverEffect(.highlight)
            // FEAT-14: opt-in accent focus ring — see PosterCard for the rationale. Aligned to the
            // same Corners radius as the clip/hover geometry above.
            .overlay {
                if accentFocusRing && isFocused {
                    // See PosterCard's copy of this overlay for the full arithmetic: `ringOffset`
                    // both grows the stroked shape's corner radius and shrinks its padding by the
                    // same amount, which offsets the ring's path `ringOffset` outside the artwork
                    // edge while keeping corners concentric; `.stroke` then centers a `ringWidth`
                    // line on that path, landing its inner edge exactly `ringGap` outside the
                    // artwork.
                    let ringOffset = ringGap + ringWidth / 2
                    RoundedRectangle(cornerRadius: style.cornerRadius + ringOffset)
                        .stroke(Color(hexString: Theme.Palette.focusRingHex(accentFocusHex: Theme.Palette.accentFocusHex)) ?? Theme.Palette.accentFocus, lineWidth: ringWidth)
                        .padding(-ringOffset)
                }
            }

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
    }
}
