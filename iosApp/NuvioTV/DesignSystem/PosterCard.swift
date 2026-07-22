import SwiftUI

/// Platter-free replacement for the system `.card` button style: no background platter, no grey
/// border around the label. Focus motion (scale + tilt/parallax + shadow/glow) is added by the tile
/// views themselves via `@Environment(\.isFocused)` — the `Button` stays the focusable element, so
/// that environment keeps working exactly as it did under `.card`.
struct PosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PosterButtonStyle {
    /// Platter-free tile style for poster/landscape/profile tiles.
    static var poster: PosterButtonStyle { .init() }
}

extension View {
    /// The parallax half of the focus lift: the system `.card` style tilts artwork toward the Siri
    /// Remote's touch point as your thumb moves; SwiftUI on tvOS has no API to read that touch-surface
    /// delta directly, so this is a focus-driven approximation — a fixed micro-tilt + slight upward
    /// nudge that animates in with the existing scale/shadow instead of tracking touch position live.
    /// Kept to a couple of degrees so it reads as "lean toward the viewer", not a wobble, and gated on
    /// Reduce Motion since it's a 3D rotation rather than a plain size/opacity change.
    ///
    /// Purely a visual transform (`rotation3DEffect`/`offset` don't affect layout), so it composes with
    /// the existing `scaleEffect`/`shadow` focus chain and never reflows the row it sits in.
    func posterFocusTilt(isFocused: Bool, reduceMotion: Bool) -> some View {
        let active = isFocused && !reduceMotion
        return self
            .rotation3DEffect(
                .degrees(active ? 5 : 0),
                axis: (x: 1, y: -0.35, z: 0),
                anchor: .center,
                anchorZ: 0,
                perspective: 0.35
            )
            .offset(y: active ? -4 : 0)
    }
}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resolvedWidth: CGFloat { width ?? style.width }
    private var resolvedHeight: CGFloat { height ?? style.height }
    private var titleVisible: Bool { showTitle ?? style.showTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            CachedAsyncImage(string: imageURL)
                .frame(width: resolvedWidth, height: resolvedHeight)
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
                .overlay(
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(Theme.Palette.accentFocus, lineWidth: isFocused ? 4 : 0)
                )
                // Tester feedback asked to "enlarge the selected poster" — bumped from 1.07 to
                // 1.12 for a more noticeable focus lift. Pure scaleEffect (not layout), so rows
                // don't need extra spacing to accommodate it.
                .scaleEffect(isFocused ? 1.12 : 1)
                .posterFocusTilt(isFocused: isFocused, reduceMotion: reduceMotion)
                .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 22, y: 10)

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
    /// Card-depth surface this landscape card belongs to — Continue Watching by default; catalog rows
    /// rendered in landscape mode pass `.posters` so the depth toggles map to the right setting.
    var depthSurface: CardDepthSurface = .continueWatching

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var titleVisible: Bool { showTitle ?? style.showTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: imageURL)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                    .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: depthSurface)
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
            // Same 1.12 focus scale as PosterCard — see comment there.
            .scaleEffect(isFocused ? 1.12 : 1)
            .posterFocusTilt(isFocused: isFocused, reduceMotion: reduceMotion)
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 22, y: 10)

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
