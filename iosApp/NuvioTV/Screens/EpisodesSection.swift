import SwiftUI
import SharedCore

/// Season selector + horizontal episode thumbnail shelf for series titles. Mirrors the shared
/// `SeriesSeasonSupport` rules: specials (season 0 / missing) normalize to 0 and sort last;
/// episodes order by number, then release, then title. Tapping an episode opens the stream picker
/// with that episode's playback videoId. A fixed-height panel under the shelf shows the focused
/// episode's synopsis, so browsing left/right never reflows the sections below.
struct EpisodesSection: View {
    let meta: MetaDetails
    /// IMDb ratings keyed "season:episode" (from `DetailViewModel.episodeRatings`); empty = no badges.
    var episodeRatings: [String: Double] = [:]
    /// Episodes to badge as watched, keyed "season:episode" (from `DetailViewModel.watchedEpisodeKeys`).
    var watchedEpisodeKeys: Set<String> = []

    @State private var selectedSeason: Int?
    @State private var episodeForStreams: EpisodeRoute?
    @FocusState private var focusedEpisodeId: String?

    var body: some View {
        let grouped = Self.groupedEpisodes(meta.videos)
        let seasons = grouped.keys.sorted { Self.seasonSortKey($0) < Self.seasonSortKey($1) }
        let current = selectedSeason ?? seasons.first
        let episodes = current.flatMap { grouped[$0] } ?? []

        return VStack(alignment: .leading, spacing: 20) {
            Text("Episodes").font(.title2).bold()

            if seasons.count > 1 {
                // FEAT-24 (u/mrStevenx3, p4afwfo): season POSTERS instead of "Season 1 / Season 2"
                // text, "comme le fait l'application mobile Nuvio". The data was already here —
                // `MetaVideo.seasonPoster` is filled by the TMDB season fetch (`useSeasonPosters`,
                // default ON) — tvOS just never drew it. Mobile's rule (DetailSeriesContent.kt):
                // posters when any season has one, text chips otherwise; the poster's fallback is
                // the show poster. No new setting this cycle (mobile's Posters/Text toggle stays
                // out until someone asks), so no new strings either.
                let posterBySeason = Self.seasonPosters(grouped)
                if posterBySeason.values.contains(where: { $0 != nil }) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Theme.Spacing.rowGap) {
                            ForEach(seasons, id: \.self) { season in
                                Button {
                                    selectedSeason = season
                                } label: {
                                    SeasonPosterCard(
                                        label: Self.seasonLabel(season),
                                        imageURL: posterBySeason[season] ?? nil ?? meta.poster ?? meta.background,
                                        isSelected: season == current
                                    )
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("season_poster_\(season)")
                            }
                        }
                        .padding(.vertical, Theme.Spacing.md)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(seasons, id: \.self) { season in
                                Button {
                                    selectedSeason = season
                                } label: {
                                    Text(Self.seasonLabel(season))
                                        .padding(.horizontal, 20).padding(.vertical, 8)
                                }
                                .buttonStyle(.chip(selected: season == current))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .focusSection()
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Spacing.rowGap) {
                        ForEach(episodes, id: \.id) { episode in
                            Button {
                                episodeForStreams = EpisodeRoute(meta: meta, episode: episode)
                            } label: {
                                EpisodeThumbCard(
                                    episode: episode,
                                    fallbackImage: meta.background ?? meta.poster,
                                    rating: rating(for: episode),
                                    isWatched: isWatched(episode)
                                )
                            }
                            .buttonStyle(.borderless)
                            .focused($focusedEpisodeId, equals: episode.id)
                            .id(episode.id)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
                .onChange(of: current) { _, _ in
                    // A new season can be shorter than the old scroll offset; snap back to the
                    // first episode without animating through the intermediate layout.
                    guard let first = episodes.first?.id else { return }
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { proxy.scrollTo(first, anchor: .leading) }
                }
            }
            .focusSection()

            focusedOverviewPanel(episodes: episodes)
        }
        .fullScreenCover(item: $episodeForStreams) { route in
            StreamPickerView(
                type: route.meta.type,
                videoId: Self.episodeVideoId(metaId: route.meta.id, episode: route.episode),
                title: Self.episodeTitle(route.episode),
                parentMetaId: route.meta.id,
                season: route.episode.season?.value,
                episode: route.episode.episode?.value,
                episodes: route.meta.videos,
                poster: route.meta.poster,
                episodeStill: route.episodeStill,
                synopsis: route.synopsis,
                meta: PlaybackMeta(details: route.meta)
            )
        }
    }

    /// Fixed-height synopsis for the focused episode (falls back to the season's first episode so
    /// the panel is never blank). Fixed frame keeps the cast row below from reflowing as focus
    /// moves along the shelf.
    @ViewBuilder
    private func focusedOverviewPanel(episodes: [MetaVideo]) -> some View {
        let episode = episodes.first { $0.id == focusedEpisodeId } ?? episodes.first
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let episode {
                if let caption = Self.episodeCaption(episode) {
                    Text(caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                let overview: String? = episode.overview
                if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .lineLimit(3)
                }
            }
        }
        .frame(maxWidth: 1100, minHeight: 96, maxHeight: 96, alignment: .topLeading)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.15), value: focusedEpisodeId)
    }

    /// "S1E4 · Apr 12, 2024 · 52 min"-style caption line; nil when nothing is known.
    private static func episodeCaption(_ episode: MetaVideo) -> String? {
        var parts: [String] = []
        if let s = episode.season?.value, let e = episode.episode?.value {
            parts.append("S\(s)E\(e)")
        }
        let released: String? = episode.released
        if let released, released.count >= 10 {
            parts.append(String(released.prefix(10)))
        }
        if let runtime = episode.runtime?.value, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Grouping / sorting (mirrors shared SeriesSeasonSupport.kt)

    /// True if this title should show an episode list at all.
    static func isSeriesLike(_ meta: MetaDetails) -> Bool {
        meta.type == "series" || meta.videos.contains { $0.season != nil || $0.episode != nil }
    }

    nonisolated static func normalizeSeasonNumber(_ season: KotlinInt?) -> Int {
        guard let s = season?.value, s > 0 else { return 0 }
        return s
    }

    nonisolated static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    nonisolated private static func groupedEpisodes(_ videos: [MetaVideo]) -> [Int: [MetaVideo]] {
        let withNumbers = videos.filter { $0.season != nil || $0.episode != nil }
        var groups: [Int: [MetaVideo]] = [:]
        for video in withNumbers {
            groups[normalizeSeasonNumber(video.season), default: []].append(video)
        }
        for (key, value) in groups {
            groups[key] = value.sorted(by: episodeOrder)
        }
        return groups
    }

    nonisolated private static func episodeOrder(_ a: MetaVideo, _ b: MetaVideo) -> Bool {
        let ea = a.episode?.value ?? Int.max
        let eb = b.episode?.value ?? Int.max
        if ea != eb { return ea < eb }
        let ra: String = a.released ?? ""
        let rb: String = b.released ?? ""
        if ra != rb { return ra < rb }
        return a.title < b.title
    }

    private static func seasonLabel(_ season: Int) -> String {
        season <= 0 ? String(localized: "Specials") : String(localized: "Season \(season)")
    }

    /// FEAT-24: first non-blank `seasonPoster` among each season's episodes (mobile's rule).
    nonisolated private static func seasonPosters(_ grouped: [Int: [MetaVideo]]) -> [Int: String?] {
        var result: [Int: String?] = [:]
        for (season, episodes) in grouped {
            let poster = episodes.lazy
                .compactMap { $0.seasonPoster?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            result[season] = poster
        }
        return result
    }

    private static func episodeVideoId(metaId: String, episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "\(metaId):\(s):\(e)"
        }
        return episode.id
    }

    private static func episodeTitle(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return String(localized: "S\(s)E\(e) \u{00B7} \(episode.title)")
        }
        return episode.title
    }

    private func rating(for episode: MetaVideo) -> Double? {
        guard let s = episode.season?.value, let e = episode.episode?.value else { return nil }
        return episodeRatings["\(s):\(e)"]
    }

    private func isWatched(_ episode: MetaVideo) -> Bool {
        guard let s = episode.season?.value, let e = episode.episode?.value else { return false }
        return watchedEpisodeKeys.contains("\(s):\(e)")
    }
}

/// `KotlinInt` is an `NSNumber` subclass, whose `.intValue` Swift accessor is `Int32`. This converts
/// to a plain Swift `Int` to avoid Int/Int32 mismatches throughout.
extension KotlinInt {
    nonisolated var value: Int { Int(truncating: self) }
}

/// Identifiable wrapper so an episode can drive `.fullScreenCover(item:)`.
private struct EpisodeRoute: Identifiable {
    let meta: MetaDetails
    let episode: MetaVideo
    var id: String { episode.id }

    /// Episode still for the player's Info header — blank addon values count as missing.
    var episodeStill: String? {
        let t: String? = episode.thumbnail
        return (t ?? "").isEmpty ? nil : t
    }
    /// Episode overview, else the series synopsis (never an empty header for a blank overview).
    var synopsis: String? {
        let o: String? = episode.overview
        if let o, !o.isEmpty { return o }
        let d: String? = meta.description_
        return d
    }
}

/// One 16:9 episode thumbnail in the horizontal shelf: still + watched/rating badges over a bottom
/// scrim, title below. Platter-free — used inside a `.poster` Button, so it carries the same focus
/// ring/scale/shadow language as `LandscapeCard`.
private struct EpisodeThumbCard: View {
    let episode: MetaVideo
    let fallbackImage: String?
    /// IMDb rating for this episode (badge hidden when nil).
    var rating: Double? = nil
    /// Shows the green watched checkmark on the thumbnail (mirrors mobile's watched badge).
    var isWatched: Bool = false

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: thumbnailURL)
                    .frame(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight)
                    // BUG-31: episode stills are not all 16:9 (and the poster fallback never is), so
                    // the `.fill` image overflows this fixed frame and the hover lift copies the
                    // overflow as a ghost-doubled subject. Clip inside the frame first.
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .nuvioCardDepth(RoundedRectangle(cornerRadius: Theme.Radius.card), surface: .episodeCards)

                // Soft scrim so the rating badge reads over bright stills.
                if rating != nil {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isWatched { WatchedCheckBadge().padding(10) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let rating { ratingBadge(rating).padding(10) }
            }
            .frame(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight)
            // Whole-card system lift — see PosterCard: still, scrim, and badges move as one.
            // BUG-31/BUG-25: highlight geometry pinned to the card's own corner radius; goes
            // still under "No Zoom on Focus" (which this tile used to ignore).
            .tileFocusLift(cornerRadius: Theme.Radius.card)

            Text(heading)
                .font(Theme.Font.cardTitle)
                .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Theme.Spacing.xs)
                .frame(width: Theme.Size.episodeWidth, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    /// Heatmap-colored IMDb rating chip (green ≥ 8.5, lime ≥ 7, orange ≥ 5.5, red below).
    private func ratingBadge(_ value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
            Text(String(format: "%.1f", value))
        }
        .font(.caption.bold())
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(ratingColor(value), in: Capsule())
    }

    private func ratingColor(_ value: Double) -> Color {
        switch value {
        case 8.5...: return Color(red: 0.22, green: 0.78, blue: 0.36)
        case 7.0..<8.5: return Color(red: 0.68, green: 0.85, blue: 0.25)
        case 5.5..<7.0: return .orange
        default: return Color(red: 0.9, green: 0.3, blue: 0.25)
        }
    }

    private var thumbnailURL: String {
        let thumb: String? = episode.thumbnail
        if let thumb, !thumb.isEmpty { return thumb }
        return fallbackImage ?? ""
    }

    private var heading: String {
        if let e = episode.episode?.value {
            return String(localized: "E\(e) \u{00B7} \(episode.title)")
        }
        return episode.title
    }
}

/// Green circular checkmark marking a watched episode (tvOS take on mobile's watched badge).
struct WatchedCheckBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(7)
            .background(Color(red: 0.22, green: 0.78, blue: 0.36).opacity(0.95), in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

/// FEAT-24: one season in the poster selector — 2:3 artwork with the season label under it, the
/// selected season outlined in the accent (the same "selected vs focused" split the text chips
/// draw with colour). Same idioms as `TrailerThumbCard`: `.borderless` button, `tileFocusLift`
/// (goes still under No Zoom on Focus), `Theme.Font.cardTitle` caption.
private struct SeasonPosterCard: View {
    let label: String
    let imageURL: String?
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    private static let width: CGFloat = 120
    private static let height: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack {
                if let imageURL, !imageURL.isEmpty {
                    CachedAsyncImage(string: imageURL)
                } else {
                    Theme.Palette.surface
                    Text(label)
                        .font(Theme.Font.cardTitle)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(Theme.Spacing.sm)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(isSelected ? Theme.Palette.accent : Color.white.opacity(0.10), lineWidth: isSelected ? 3 : 1)
            }
            .tileFocusLift(cornerRadius: Theme.Radius.card)

            Text(label)
                .font(Theme.Font.cardTitle)
                .foregroundStyle(isFocused || isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(width: Self.width, alignment: .leading)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
