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

    private var resolvedWidth: CGFloat { width ?? style.width }
    private var resolvedHeight: CGFloat { height ?? style.height }
    private var titleVisible: Bool { showTitle ?? style.showTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match LandscapeCard and expandedTile
            CachedAsyncImage(string: imageURL)
                .frame(width: resolvedWidth, height: resolvedHeight)
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
                // Whole-card system lift: without this the borderless hover effect lands on the
                // inner Image, so the artwork parallaxes INSIDE a static clipped edge (device
                // feedback). Tagging the clipped container makes the entire card — edge included —
                // lift and track the remote as one object.
                .hoverEffect(.highlight)

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

    private var titleVisible: Bool { showTitle ?? style.showTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match PosterCard and expandedTile
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: imageURL)
                    .frame(width: width, height: height)
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
            .hoverEffect(.highlight)

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
