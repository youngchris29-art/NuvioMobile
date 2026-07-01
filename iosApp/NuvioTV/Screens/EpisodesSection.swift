import SwiftUI
import SharedCore

/// Season selector + episode list for series titles. Mirrors the shared `SeriesSeasonSupport` rules:
/// specials (season 0 / missing) normalize to 0 and sort last; episodes order by number, then release,
/// then title. Tapping an episode opens the stream picker with that episode's playback videoId.
struct EpisodesSection: View {
    let meta: MetaDetails

    @State private var selectedSeason: Int?
    @State private var episodeForStreams: EpisodeRoute?

    var body: some View {
        let grouped = Self.groupedEpisodes(meta.videos)
        let seasons = grouped.keys.sorted { Self.seasonSortKey($0) < Self.seasonSortKey($1) }
        let current = selectedSeason ?? seasons.first
        let episodes = current.flatMap { grouped[$0] } ?? []

        return VStack(alignment: .leading, spacing: 20) {
            Text("Episodes").font(.title2).bold()

            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(seasons, id: \.self) { season in
                            Button {
                                selectedSeason = season
                            } label: {
                                Text(Self.seasonLabel(season))
                                    .padding(.horizontal, 20).padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .tint(season == current ? .accentColor : nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            LazyVStack(spacing: 16) {
                ForEach(Array(episodes.enumerated()), id: \.offset) { _, episode in
                    Button {
                        episodeForStreams = EpisodeRoute(meta: meta, episode: episode)
                    } label: {
                        EpisodeCard(episode: episode, fallbackImage: meta.background ?? meta.poster)
                    }
                    .buttonStyle(.card)
                }
            }
        }
        .fullScreenCover(item: $episodeForStreams) { route in
            StreamPickerView(
                type: route.meta.type,
                videoId: Self.episodeVideoId(metaId: route.meta.id, episode: route.episode),
                title: Self.episodeTitle(route.episode),
                parentMetaId: route.meta.id,
                season: route.episode.season?.value,
                episode: route.episode.episode?.value
            )
        }
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
        season <= 0 ? "Specials" : "Season \(season)"
    }

    private static func episodeVideoId(metaId: String, episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "\(metaId):\(s):\(e)"
        }
        return episode.id
    }

    private static func episodeTitle(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "S\(s)E\(e) \u{00B7} \(episode.title)"
        }
        return episode.title
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
}

private struct EpisodeCard: View {
    let episode: MetaVideo
    let fallbackImage: String?

    var body: some View {
        // Widen the Kotlin String to an explicit optional (it surfaces as non-optional in Swift).
        let overview: String? = episode.overview
        return HStack(alignment: .top, spacing: 20) {
            AsyncImage(url: URL(string: thumbnailURL)) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.gray.opacity(0.2)
                        Image(systemName: "play.tv").font(.title).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 300, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text(heading).font(.headline).lineLimit(2)
                if let text = overview, !text.isEmpty {
                    Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var thumbnailURL: String {
        let thumb: String? = episode.thumbnail
        if let thumb, !thumb.isEmpty { return thumb }
        return fallbackImage ?? ""
    }

    private var heading: String {
        if let e = episode.episode?.value {
            return "\(e). \(episode.title)"
        }
        return episode.title
    }
}
