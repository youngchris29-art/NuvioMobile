import SwiftUI
import SharedCore

// MARK: - Thumbnail URL resolution

extension MetaTrailer {
    /// A 16:9 YouTube thumbnail for this trailer, or `nil` when the key isn't a recognizable
    /// YouTube video id/URL. Mirrors upstream `DetailTrailersSection`'s
    /// `https://img.youtube.com/vi/{key}/hqdefault.jpg` construction, but — unlike upstream, which
    /// assumes `key` is always a bare video id — this also copes with `key` holding a full YouTube
    /// URL (watch/embed/shorts/youtu.be), the same shape `youtubePlaybackUrl()` in
    /// `HeroTrailerSelector.kt` already has to handle for playback. `nil` degrades gracefully:
    /// `CachedAsyncImage` renders its flat surface/film glyph instead of an endless shimmer.
    var thumbnailURLString: String? {
        guard let id = youtubeVideoId else { return nil }
        return "https://img.youtube.com/vi/\(id)/hqdefault.jpg"
    }

    /// Extracts a bare YouTube video id from `key`, whether `key` already IS a bare id or a full
    /// YouTube URL in any of its common shapes.
    private var youtubeVideoId: String? {
        let key = self.key
        guard !key.isEmpty else { return nil }

        if !key.hasPrefix("http://") && !key.hasPrefix("https://") {
            // A bare key is only a YouTube id if the record SAYS it's YouTube — a bare Vimeo (or
            // other provider) id would synthesize a guaranteed-404 img.youtube.com URL and render
            // the failure glyph instead of the honest no-thumbnail surface. Full URLs below stay
            // site-agnostic: the host check identifies YouTube regardless of a mislabeled `site`.
            guard site.caseInsensitiveCompare("YouTube") == .orderedSame else { return nil }
            // And only plausible if it doesn't look like a stray path/query fragment.
            let disallowed = CharacterSet(charactersIn: "/?& ")
            guard key.rangeOfCharacter(from: disallowed) == nil else { return nil }
            return key
        }

        guard let components = URLComponents(string: key), let host = components.host else { return nil }

        // youtube-nocookie.com is the privacy-enhanced embed host — same ids, same thumbnails.
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
                return v
            }
            let segments = components.path.split(separator: "/").map(String.init)
            for prefix in ["embed", "shorts", "v"] {
                if let idx = segments.firstIndex(of: prefix), segments.count > idx + 1 {
                    return segments[idx + 1]
                }
            }
            return nil
        }

        if host.contains("youtu.be") {
            let segments = components.path.split(separator: "/").map(String.init)
            return segments.first
        }

        return nil
    }
}

// MARK: - Trailer thumbnail card

/// One 16:9 trailer thumbnail in the "Trailers & Extras" shelf: YouTube still + scrim, title and
/// type/year caption below. Same lockup language as `EpisodeThumbCard` — platter-free, used inside
/// a `cardFocusButtonStyle()` Button; the tile draws its own focus treatment (`DetailTileFocusLift`).
struct TrailerThumbCard: View {
    let trailer: MetaTrailer
    /// True while `DetailViewModel` is resolving a playable stream URL for this trailer (shows a
    /// spinner over the still instead of letting the press feel unresponsive).
    let isResolving: Bool
    /// The still's size: `DetailWideCard.metrics` (Apple-style passes 410 wide; the default is
    /// today's 420x236, so Cinematic and Classic are unchanged).
    var cardSize: CGSize = DetailWideCard.metrics(appleStyle: false).size

    @Environment(\.isFocused) private var isFocused
    // BUG-32 (beta.13 review, frame-verified at t=80): shared corner token, not the hardcoded
    // Theme.Radius.card, so the Corners setting reaches trailer thumbnails.
    @Environment(\.posterStyle) private var posterStyle
    /// BUG-177: ring/zoom/poster-colour settings from the root (`ProvidesFocusAppearance`).
    @Environment(\.focusAppearance) private var focusAppearance
    @Environment(\.cardDepthStyle) private var depthStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// BUG-177: the rail colour sampled when the still lands ("Depth Takes Poster Color").
    @State private var depthRailTint: Color?

    private var samplesDepthColor: Bool {
        DetailTileFocus.samplesRailColor(depthTakesPosterColor: focusAppearance.depthTakesPosterColor,
                                         depthEnabled: depthStyle.isEnabled(for: .trailers),
                                         artworkURL: trailer.thumbnailURLString)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: posterStyle.cornerRadius)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack {
                CachedAsyncImage(string: trailer.thumbnailURLString)
                    .onImageLoaded { _ in
                        DetailTileRailTint.imageLoaded(samples: samplesDepthColor,
                                                       source: trailer.thumbnailURLString) { color in
                            if depthRailTint != color { depthRailTint = color }
                        }
                    }
                    .frame(width: cardSize.width, height: cardSize.height)
                    // hqdefault.jpg bakes in 4:3 letterbox bars top/bottom; cropping to our fixed
                    // 16:9 frame trims them the same way upstream's `ContentScale.Crop` does.
                    .clipped()

                // Upstream parity: a flat dark scrim over every still, not just on focus.
                // BUG-177: now UNDER the depth layer (inside the clip, before `nuvioCardDepth`) —
                // it used to sit over the rail and sheen and dim them to near-invisible.
                Color.black.opacity(0.2)
                    .allowsHitTesting(false)
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(shape)
            .nuvioCardDepth(shape, surface: .trailers,
                            railTint: DetailTileRailTint.resolved(samples: samplesDepthColor,
                                                                  source: trailer.thumbnailURLString,
                                                                  sampled: depthRailTint))
            .overlay {
                if isResolving {
                    ZStack {
                        Color.black.opacity(0.45)
                            .clipShape(shape)
                        ProgressView()
                            .tint(.white)
                    }
                    .allowsHitTesting(false)
                }
            }
            // BUG-31: goes still under "No Zoom on Focus" (which this tile used to ignore).
            // BUG-177 (Steven rc7): draws the accent ring and owns its lift in ring mode.
            .detailTileFocusLift(cornerRadius: posterStyle.cornerRadius,
                                 size: CGSize(width: cardSize.width, height: cardSize.height),
                                 tintSource: trailer.thumbnailURLString)

            // UX-15 class: both caption lines drop together under the system lift so the lifted
            // artwork never grows over them (same arithmetic as PosterCard's BUG-54 treatment).
            Group {
                Text(trailer.displayName ?? trailer.name)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: cardSize.width, alignment: .leading)

                Text(metaCaption)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
            .modifier(CardCaptionFocusDrop(
                mode: CardFocusMode.resolve(accentFocusRing: focusAppearance.accentFocusRing,
                                            noZoomOnFocus: focusAppearance.noZoomOnFocus),
                isFocused: isFocused,
                artworkHeight: cardSize.height
            ))
        }
        .frame(width: cardSize.width)
        // BUG-177: gated on Reduce Motion now that this wraps ring mode's manual scale (the
        // `CastCard` BUG-108 rule: a blanket animation here would undo `CardArtworkFocusLift`'s nil).
        // BUG-153 (Batch M): also nil in ring mode under the `debug.detailTileRingNoAnim` knob.
        .animation(DetailTileFocus.tileFocusAnimation(reduceMotion: reduceMotion,
                                                      accentFocusRing: focusAppearance.accentFocusRing),
                   value: isFocused)
    }

    /// "Trailer · 2024", or just the type when there's no publish year.
    private var metaCaption: String {
        guard let year = trailer.publishedAt?.prefix(4), !year.isEmpty else { return trailer.type }
        return "\(trailer.type) \u{2022} \(year)"
    }
}
