import SwiftUI

/// The standard portrait poster tile used across catalog rows, search results, and "more like this".
///
/// Designed to be used as the label of a `Button` / `NavigationLink` with `.buttonStyle(.card)` —
/// the system `.card` style provides tvOS's focus lift/parallax, and this view adds the brand focus
/// ring plus a title that brightens on focus, so every poster in the app focuses the same way.
///
/// ```swift
/// NavigationLink(value: route) { PosterCard(title: item.name, imageURL: item.poster) }
///     .buttonStyle(.card)
/// ```
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
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            CachedAsyncImage(string: imageURL)
                .frame(width: resolvedWidth, height: resolvedHeight)
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(Theme.Palette.accentFocus, lineWidth: isFocused ? 4 : 0)
                )

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
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Landscape (16:9) card used for the Continue Watching row: artwork with a progress bar and a
/// title that brightens on focus. Same focus language as `PosterCard`.
struct LandscapeCard: View {
    let title: String
    let imageURL: String?
    /// 0...1 watched fraction; pass nil to hide the progress bar.
    var progress: Double? = nil
    var width: CGFloat = Theme.Size.landscapeWidth
    var height: CGFloat = Theme.Size.landscapeHeight
    var showTitle: Bool? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style

    private var titleVisible: Bool { showTitle ?? style.showTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: imageURL)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .strokeBorder(Theme.Palette.accentFocus, lineWidth: isFocused ? 4 : 0)
                    )

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
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
