import Foundation

/// C5 (A1.3, Apple TV detail): the text the Cinematic hero's synopsis teaser shows (and the full
/// synopsis cover opened from it). Apple TV shows the synopsis of the episode the Play/Resume button
/// will play; the show synopsis stays the page's own description.
///
/// Rules:
/// - Movie: the title's overview.
/// - Series: the Play/Resume target episode's overview. Falls back to the show overview when there
///   is no target yet, the episode has no overview (empty or whitespace counts as none), or the
///   "Hide Episode Spoilers" setting would hide that episode's synopsis on the episode shelf
///   (`EpisodeSpoilerRules.hidesSpoilers`): the hero never reveals what the shelf hides.
/// - Series with the About section off (`aboutShowsOverview` false): the show overview. The About
///   section is where the show overview moved; with it hidden the hero keeps it, so the page never
///   loses the show's description (a show with no overview still gets the episode's).
///
/// Pure (no SharedCore, no Theme) so it stays `nonisolated` and unit-testable.
nonisolated enum DetailHeroSynopsis {
    struct Result: Equatable {
        let text: String
        /// True when `text` is the target episode's overview, not the show's.
        let isEpisode: Bool
        /// The target episode's numbers when `isEpisode` (for a future "S2, E3" label; the hero
        /// has no slot for one today).
        let season: Int?
        let episode: Int?
    }

    /// - Parameters:
    ///   - isSeries: the page is a series (or series-like) title.
    ///   - showOverview: the show's / movie's own overview.
    ///   - playTargetEpisodeOverview: the overview of the episode the Play/Resume button targets,
    ///     nil when there is no target yet (or the target is not in the episode list).
    ///   - episodeSpoilerHidden: the episode shelf would hide this episode's synopsis
    ///     (`EpisodeSpoilerRules.hidesSpoilers(settingOn:isWatched:)`).
    ///   - aboutShowsOverview: the About section is on in this layout, so it carries the show
    ///     overview (`DetailAboutSection`). False keeps the show overview in the hero.
    static func resolve(
        isSeries: Bool,
        showOverview: String?,
        playTargetEpisodeOverview: String?,
        episodeSpoilerHidden: Bool,
        aboutShowsOverview: Bool = true,
        season: Int? = nil,
        episode: Int? = nil
    ) -> Result? {
        let showText: String? = nonBlank(showOverview)
        if isSeries, aboutShowsOverview || showText == nil, !episodeSpoilerHidden,
           let episodeText = nonBlank(playTargetEpisodeOverview) {
            return Result(text: episodeText, isEpisode: true, season: season, episode: episode)
        }
        guard let showOverview = showText else { return nil }
        return Result(text: showOverview, isEpisode: false, season: nil, episode: nil)
    }

    /// The hero text alone (nil when there is nothing to show).
    static func text(
        isSeries: Bool,
        showOverview: String?,
        playTargetEpisodeOverview: String?,
        episodeSpoilerHidden: Bool,
        aboutShowsOverview: Bool = true
    ) -> String? {
        resolve(isSeries: isSeries, showOverview: showOverview,
                playTargetEpisodeOverview: playTargetEpisodeOverview,
                episodeSpoilerHidden: episodeSpoilerHidden,
                aboutShowsOverview: aboutShowsOverview)?.text
    }

    /// One episode as the Play-target lookup reads it (`MetaVideo`'s id and numbers).
    struct EpisodeRef: Equatable {
        let id: String
        let season: Int?
        let episode: Int?
    }

    /// The episode the Play/Resume action targets, as the shared `nextUpVideoFor` finds it: by
    /// season and episode when the action has both, else (or when no episode matches) the first
    /// whose own id, or its playback id (`buildPlaybackVideoId`: "content:s:e" with both numbers,
    /// else its own id, else the content id), equals the action's `videoId`.
    static func playTargetIndex(_ episodes: [EpisodeRef], contentId: String, season: Int?, episode: Int?,
                                videoId: String) -> Int? {
        if let season, let episode,
           let index = episodes.firstIndex(where: { $0.season == season && $0.episode == episode }) {
            return index
        }
        return episodes.firstIndex { ref in
            ref.id == videoId || playbackVideoId(contentId: contentId, ref: ref) == videoId
        }
    }

    /// Kotlin's `buildPlaybackVideoId(parentMetaId:seasonNumber:episodeNumber:fallbackVideoId:)`.
    static func playbackVideoId(contentId: String, ref: EpisodeRef) -> String {
        if let season = ref.season, let episode = ref.episode { return "\(contentId):\(season):\(episode)" }
        return ref.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? contentId : ref.id
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
