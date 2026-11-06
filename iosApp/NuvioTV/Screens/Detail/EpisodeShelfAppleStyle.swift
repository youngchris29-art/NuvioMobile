import CoreGraphics
import Foundation

// A3 (Apple-style Detail layout): pure helpers behind `EpisodesSection(appleStyle: true)`. No
// SharedCore or SwiftUI references, so everything here is `nonisolated` (the target's default
// actor isolation is MainActor) and unit-testable. Cinematic and Classic never call these.

/// A3.1 (C2): the text block under each episode card in the Apple-style shelf: "Episode N", the
/// title, a two-line overview, then air date, runtime and rating. The spoiler rule is the one the
/// shared panel under the shelf applies today (`EpisodeSpoilerRules.hidesSpoilers`): when it hides,
/// the overview is replaced by "Synopsis hidden until watched" and the still is blurred, together.
/// Number, title, date and runtime stay visible (the panel's caption kept them too); the rating
/// follows the separate Episode Ratings setting, which the caller has already applied.
nonisolated enum EpisodeCardText {
    struct Content: Equatable {
        /// "Episode 3"; nil when the episode has no number (the row keeps its slot).
        let numberLabel: String?
        let title: String
        /// The overview to draw; always nil while `overviewHidden`.
        let overview: String?
        /// "Hide Episode Spoilers" is on and the episode is unwatched: draw the placeholder.
        let overviewHidden: Bool
        /// Blur the still. Always equal to `overviewHidden`: text and still hide together.
        let blursStill: Bool
        /// "Apr 12, 2024 · 52 min"; nil when neither is known.
        let metaLine: String?
        /// "8.4" for the star chip at the end of the meta row; nil hides it.
        let ratingText: String?
    }

    static func make(
        episodeNumber: Int?,
        title: String,
        overview: String?,
        airDate: String?,
        runtimeMinutes: Int?,
        rating: Double?,
        hidesSpoiler: Bool
    ) -> Content {
        let trimmedOverview = overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleOverview = (trimmedOverview?.isEmpty == false) ? trimmedOverview : nil
        return Content(
            numberLabel: numberLabel(episodeNumber),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            overview: hidesSpoiler ? nil : visibleOverview,
            overviewHidden: hidesSpoiler,
            blursStill: hidesSpoiler,
            metaLine: metaLine(airDate: airDate, runtimeMinutes: runtimeMinutes),
            ratingText: ratingText(rating)
        )
    }

    static func numberLabel(_ episodeNumber: Int?) -> String? {
        guard let episodeNumber else { return nil }
        return String(localized: "Episode \(episodeNumber)")
    }

    static func metaLine(airDate: String?, runtimeMinutes: Int?) -> String? {
        var parts: [String] = []
        if let airDate, !airDate.isEmpty { parts.append(airDate) }
        if let runtimeMinutes, runtimeMinutes > 0 { parts.append(String(localized: "\(runtimeMinutes) min")) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// `episode_card_<season>_<episode>` (specials are season 0), else `episode_card_<video id>`.
    static func cardIdentifier(season: Int?, episode: Int?, fallbackId: String) -> String {
        if let episode {
            let s = (season ?? 0) <= 0 ? 0 : (season ?? 0)
            return "episode_card_\(s)_\(episode)"
        }
        return "episode_card_\(fallbackId)"
    }

    /// Same one-decimal form as the card's rating badge in the other layouts.
    static func ratingText(_ rating: Double?) -> String? {
        guard let rating, rating.isFinite else { return nil }
        return String(format: "%.1f", rating)
    }

    /// The `yyyy-MM-dd` prefix of an addon/TMDB `released` value as a localized medium date
    /// ("Apr 12, 2024" in en_US). The date is read as a calendar day (UTC both ways), so no
    /// time-zone shift can move it to a neighbouring day. nil when absent or malformed.
    static func airDate(released: String?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let released else { return nil }
        let trimmed = released.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let parts = trimmed.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                     calendar: calendar, timeZone: utc)
        return date.formatted(style)
    }
}

/// A3.1: the fixed height of the Apple-style text block, so every card in the shelf ends at the
/// same line whatever data it has (a missing number, overview, date or rating leaves its row
/// empty instead of pulling the rows below up). Four rows: number, title, overview (always
/// `overviewLineLimit` lines tall), meta.
nonisolated enum EpisodeCardTextLayout {
    static let overviewLineLimit = 2
    /// Gap between the four rows.
    static let rowSpacing: CGFloat = Theme.Spacing.xxs

    static func blockHeight(numberLine: CGFloat, titleLine: CGFloat, overviewLine: CGFloat,
                            metaLine: CGFloat, spacing: CGFloat = rowSpacing) -> CGFloat {
        let lines = numberLine + titleLine + overviewLine * CGFloat(overviewLineLimit) + metaLine
        return (lines + spacing * 3).rounded(.up)
    }

    static func overviewHeight(overviewLine: CGFloat) -> CGFloat {
        (overviewLine * CGFloat(overviewLineLimit)).rounded(.up)
    }
}

/// The wide 16:9 cards of the Detail shelves (episodes, trailers, bonus). Apple-style uses the
/// `DetailGeometry` shelf tokens (410 wide, 40 apart, Apple TV's ~410x230 at a ~450 pitch);
/// Cinematic and Classic keep today's 420x236 cards 28 apart.
nonisolated enum DetailWideCard {
    struct Metrics: Equatable {
        let width: CGFloat
        let height: CGFloat
        let gap: CGFloat
        var size: CGSize { CGSize(width: width, height: height) }
    }

    static func metrics(appleStyle: Bool) -> Metrics {
        guard appleStyle else {
            return Metrics(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight,
                           gap: Theme.Spacing.rowGap)
        }
        return Metrics(width: DetailGeometry.wideCardWidth,
                       height: (DetailGeometry.wideCardWidth * 9 / 16).rounded(),
                       gap: DetailGeometry.wideCardGap)
    }
}

/// A3.2 (C1): the compact text season tabs. Same normalization and order as
/// `EpisodesSection.groupedEpisodes`/`seasonSortKey` (specials, season 0 or missing, sort last).
nonisolated enum EpisodeSeasonTabs {
    struct Tab: Equatable {
        let season: Int
        let label: String
        /// `season_tab_<n>`, the `season_poster_<n>` pattern; specials are `season_tab_0`.
        var accessibilityIdentifier: String { "season_tab_\(season)" }
    }

    static func sortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    static func label(_ season: Int) -> String {
        season <= 0 ? String(localized: "Specials") : String(localized: "Season \(season)")
    }

    /// One tab per distinct normalized season, numbered seasons ascending, Specials last.
    static func tabs(for seasons: [Int]) -> [Tab] {
        let normalized = Set(seasons.map { $0 <= 0 ? 0 : $0 })
        return normalized
            .sorted { sortKey($0) < sortKey($1) }
            .map { Tab(season: $0, label: label($0)) }
    }
}

/// A3.2: the season-tab browsing state. "Viewed season" (what the shelf shows) is the only thing a
/// tab changes: `EpisodesSection` writes the settled season into its own `selectedSeason`, which
/// nothing outside the section reads, so the hero and the Play button (driven by
/// `DetailViewModel`'s progress-based play target) never move while browsing.
///
/// Focus landing on a tab switches the shelf after `debounce`, so sweeping Left/Right across the
/// tabs does not rebuild the shelf for every season passed. Leaving the row before the debounce
/// commits the pending season at once (`leave(entry:)`) and arms its entry episode, so the next
/// shelf focus is sent there (`shelfFocus(on:)`) instead of onto a card of the season the viewer
/// just tabbed away from. Each focus change bumps `generation`;
/// a debounce that wakes with an older ticket is stale and does nothing (the caller also cancels
/// its sleeping Task). Episodes for every season are already in memory (`MetaDetails.videos`), so
/// the switch is a filter: there is no per-season fetch to cancel beyond that Task.
///
/// It also remembers the last focused episode per season: a season's first entry lands on its
/// next-up episode, a later return lands on the remembered one.
nonisolated struct SeasonTabBrowse: Equatable {
    static let debounce: Duration = .milliseconds(200)

    private(set) var pending: Int?
    private(set) var generation = 0
    private(set) var remembered: [Int: String] = [:]
    /// The entry episode of a season committed by `leave(entry:)`, waiting for focus to reach the
    /// shelf; consumed by the next `shelfFocus(on:)`.
    private(set) var armedEntry: String?

    /// Focus landed on `season`'s tab while the shelf shows `viewed`. Returns the ticket to pass to
    /// `settle(ticket:)` after the debounce, or nil when there is nothing to switch.
    mutating func focus(on season: Int, viewed: Int?) -> Int? {
        generation += 1
        armedEntry = nil
        guard season != viewed else {
            pending = nil
            return nil
        }
        pending = season
        return generation
    }

    /// The debounce for `ticket` elapsed: the season to show now, or nil if a newer focus change
    /// (or a flush) superseded it.
    mutating func settle(ticket: Int) -> Int? {
        guard ticket == generation, let season = pending else { return nil }
        pending = nil
        return season
    }

    /// Focus left the tab row (Down into the shelf, or anywhere else) before the debounce: the
    /// pending season to show right away, or nil when nothing was pending. `entry` gives that
    /// season's entry episode (the shelf's own rule, `entryEpisode`), armed for `shelfFocus(on:)`.
    /// Any sleeping ticket becomes stale.
    mutating func leave(entry: (Int) -> String?) -> Int? {
        generation += 1
        guard let season = pending else { return nil }
        pending = nil
        armedEntry = entry(season)
        return season
    }

    /// Focus landed on `episodeId` in the shelf. After a `leave(entry:)` commit, the episode focus
    /// must move to instead (the committed season's entry), or nil to keep it. Consumes the armed
    /// entry, so it redirects once.
    mutating func shelfFocus(on episodeId: String) -> String? {
        guard let target = armedEntry else { return nil }
        armedEntry = nil
        return target == episodeId ? nil : target
    }

    /// A tab was selected before the debounce: the pending season to show right away, if any.
    /// Any sleeping ticket becomes stale.
    mutating func flush() -> Int? {
        generation += 1
        armedEntry = nil
        let season = pending
        pending = nil
        return season
    }

    /// Focus moved between tabs (`old` → `new`). When it ENTERS the row from outside (`old` nil)
    /// on a tab other than the viewed season's, the tab it must move to instead (the viewed one);
    /// nil otherwise. Entering never switches the shelf: Apple TV lands on the selected season.
    static func entryTab(from old: Int?, to new: Int?, viewed: Int?) -> Int? {
        guard old == nil, let new, let viewed, new != viewed else { return nil }
        return viewed
    }

    mutating func remember(episodeId: String, season: Int) {
        if remembered[season] != episodeId { remembered[season] = episodeId }
    }

    /// Where focus enters (and the shelf scrolls to) for `season`: the remembered episode when it is
    /// still listed, else `nextUpId` (first entry, or the remembered card is gone).
    func entryEpisode(season: Int?, nextUpId: String?, isListed: (String) -> Bool) -> String? {
        guard let season, let id = remembered[season], isListed(id) else { return nextUpId }
        return id
    }

    func hasRemembered(season: Int?) -> Bool {
        guard let season else { return false }
        return remembered[season] != nil
    }
}

/// A3.2: holds `EpisodesSection`'s `SeasonTabBrowse` in `@State` as a reference, so its writes
/// (a remembered card on every Left/Right, debounce tickets) never invalidate the view. The shelf
/// reads it on the renders a season switch or a focus change already causes.
final class SeasonTabBrowseBox {
    var state = SeasonTabBrowse()
}

/// A3.1: per-visit cache of formatted air dates, keyed by the raw `released` value. The shelf body
/// re-runs on every Left/Right (BUG-153), and the date formatter would otherwise run for every
/// realized card on each press. A reference held in `@State`: filling it never invalidates the view.
final class EpisodeAirDateCache {
    private var cache: [String: String?] = [:]

    func airDate(_ released: String?) -> String? {
        guard let released else { return nil }
        if let hit = cache[released] { return hit }
        let formatted: String? = EpisodeCardText.airDate(released: released)
        cache[released] = formatted
        return formatted
    }
}
