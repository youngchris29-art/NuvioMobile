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
    var width: CGFloat = Theme.Size.posterWidth
    var height: CGFloat = Theme.Size.posterHeight
    var showTitle: Bool = true

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            CachedAsyncImage(string: imageURL)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Palette.accentFocus, lineWidth: isFocused ? 4 : 0)
                )

            if showTitle {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
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

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: imageURL)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
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

            Text(title)
                .font(Theme.Font.cardTitle)
                .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
