import Foundation
import SwiftUI
import SharedCore

#if DEBUG
/// Home Watchlist row (FEAT-92), W3: the DEBUG-only seeds and knobs the UI legs and the geometry
/// measurements need. The whole file is inside `#if DEBUG`, like `ContinueWatchingDebugSeed.swift`,
/// so a Release binary carries none of these names or log tags (spec 7.5).
///
/// Both seeds follow the Continue Watching seed's rules: the launch-argument value is the base64
/// of UTF-8 JSON (the launch-argument domain parses a bracket-led value as an old-style plist and
/// drops raw JSON); refused on a signed-in cloud account (`collectionsSeedRefusal`) and while a
/// tracker is the progress source; the latch is set after both refusals pass, so a refusal does not
/// latch and a malformed payload does. They inject at the Swift model and write nothing to a
/// repository, provider, throttle or disk.

// MARK: - Shared refusal rules

@MainActor
private enum HomeRowsSeedRefusal {
    /// True (after logging under `tag`) when the seed must not apply: a real signed-in account or an
    /// auth state still loading, or a tracker (Trakt, Simkl, MDBList) as the progress source.
    static func refused(tag: String) -> Bool {
        if let refusal = HomeViewModel.collectionsSeedRefusal(authState: AuthRepository.shared.state.value_) {
            NSLog("[%@] applied=false refused=%@", tag, refusal)
            return true
        }
        if let source = WatchProgressRepository.shared.activeSourceState.value_ as? WatchProgressSource,
           source.providerId != nil {
            NSLog("[%@] applied=false refused=tracker progress source %@", tag, source.name)
            return true
        }
        return false
    }

    static func decodeArray(_ b64: String) -> [[String: Any]]? {
        guard let data = Data(base64Encoded: b64),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return array
    }
}

// MARK: - Watchlist seed

/// `-debug.homeWatchlistSeedJsonB64 <base64 of a JSON array>`, each element:
///
///     {"type":"movie","id":"tt0111161","name":"The Shawshank Redemption",
///      "poster":"https://images.metahub.space/poster/medium/tt0111161/img",
///      "background":"https://images.metahub.space/background/medium/tt0111161/img",
///      "logo":"https://images.metahub.space/logo/medium/tt0111161/img",
///      "description":"...","releaseInfo":"1994"}
///
/// `type`, `id` and `name` are required; an element missing any of them is skipped and counted.
/// It bypasses only the provider-connection check, so the row shows on a guest with no Trakt or
/// Simkl. It does not bypass the toggle, the 18 cap, the empty-hides rule, the profile-switch clear
/// or `HomeRowOrder`.
@MainActor
enum HomeWatchlistDebugSeed {
    static let argumentKey = "debug.homeWatchlistSeedJsonB64"
    private static var didApply = false
    /// The decoded previews, kept for the launch (in-memory seed: the toggle and a restart reuse it).
    private static var previews: [MetaPreview]?

    /// The seeded section, or nil when no seed is requested, it is refused, or it is empty.
    static func section(title: String) -> HomeCatalogSection? {
        if let previews {
            return previews.isEmpty ? nil : LibraryProviderRowsKt.homeWatchlistRowSectionOf(title: title, previews: previews)
        }
        guard !didApply else { return nil }
        guard let b64 = UserDefaults.standard.string(forKey: argumentKey), !b64.isEmpty else { return nil }
        if HomeRowsSeedRefusal.refused(tag: "HomeWatchlistSeed") { return nil }
        didApply = true
        guard let array = HomeRowsSeedRefusal.decodeArray(b64) else {
            NSLog("[HomeWatchlistSeed] applied=false error=the payload is not base64 of a JSON array")
            return nil
        }
        let built = Array(array.compactMap(preview(from:)).prefix(CatalogRowView.homePreviewLimit))
        previews = built
        NSLog("[HomeWatchlistSeed] applied=true items=%d skipped=%d", built.count, array.count - built.count)
        return built.isEmpty ? nil : LibraryProviderRowsKt.homeWatchlistRowSectionOf(title: title, previews: built)
    }

    /// `MetaPreview` with the full initializer (Kotlin default arguments are not exported), as
    /// `HomeRowPreviews.entry(_:logo:)` does; the fields the seed does not carry are nil or empty.
    private static func preview(from element: [String: Any]) -> MetaPreview? {
        guard let type = element["type"] as? String, !type.isEmpty,
              let id = element["id"] as? String, !id.isEmpty,
              let name = element["name"] as? String, !name.isEmpty else { return nil }
        return MetaPreview(
            id: id,
            type: type,
            name: name,
            poster: element["poster"] as? String,
            banner: element["background"] as? String,
            logo: element["logo"] as? String,
            posterShape: .poster,
            description: element["description"] as? String,
            releaseInfo: element["releaseInfo"] as? String,
            rawReleaseDate: nil,
            popularity: nil,
            voteCount: nil,
            imdbRating: nil,
            genres: [],
            rawPosterUrl: nil,
            landscapePoster: nil,
            rawLandscapePosterUrl: nil,
            customPosterApplied: false
        )
    }
}

// MARK: - Upcoming seed

/// `-debug.homeUpcomingSeedJsonB64 <base64 of a JSON array>`, each element:
///
///     {"showId":"tt0944947","showTitle":"Game of Thrones","season":8,"episode":1,"daysUntilAir":1,
///      "showYear":"2011","poster":"...","background":"...","logo":"...","episodeTitle":"Winterfell",
///      "thumbnail":"..."}
///
/// `showId`, `showTitle`, `season`, `episode` and `daysUntilAir` are required. Hook: the first lines
/// of `HomeViewModel.startUpcoming()`; `UpcomingEpisodesRepository` is then not started.
@MainActor
enum HomeUpcomingDebugSeed {
    static let argumentKey = "debug.homeUpcomingSeedJsonB64"
    private static var didApply = false
    private static var cached: [UpcomingEpisodeItem]?

    /// The seeded items, or nil when no seed is requested, it is refused, or it is empty.
    static func items() -> [UpcomingEpisodeItem]? {
        if let cached { return cached.isEmpty ? nil : cached }
        guard !didApply else { return nil }
        guard let b64 = UserDefaults.standard.string(forKey: argumentKey), !b64.isEmpty else { return nil }
        if HomeRowsSeedRefusal.refused(tag: "HomeUpcomingSeed") { return nil }
        didApply = true
        guard let array = HomeRowsSeedRefusal.decodeArray(b64) else {
            NSLog("[HomeUpcomingSeed] applied=false error=the payload is not base64 of a JSON array")
            return nil
        }
        let built = array.compactMap(item(from:))
        cached = built
        NSLog("[HomeUpcomingSeed] applied=true items=%d skipped=%d", built.count, array.count - built.count)
        return built.isEmpty ? nil : built
    }

    private static func item(from element: [String: Any]) -> UpcomingEpisodeItem? {
        guard let showId = element["showId"] as? String, !showId.isEmpty,
              let showTitle = element["showTitle"] as? String, !showTitle.isEmpty,
              let season = (element["season"] as? NSNumber)?.intValue,
              let episode = (element["episode"] as? NSNumber)?.intValue,
              let days = (element["daysUntilAir"] as? NSNumber)?.intValue else { return nil }
        return UpcomingEpisodeItem(
            showId: showId,
            showType: "series",
            showTitle: showTitle,
            showYear: element["showYear"] as? String,
            showPoster: element["poster"] as? String,
            showBackground: element["background"] as? String,
            showLogo: element["logo"] as? String,
            episodeId: "\(showId):\(season):\(episode)",
            season: Int32(season),
            episode: Int32(episode),
            episodeTitle: element["episodeTitle"] as? String,
            episodeThumbnail: element["thumbnail"] as? String,
            airDateIso: airDateIso(daysFromToday: days),
            daysUntilAir: Int32(days)
        )
    }

    /// Today plus `days` in the local calendar, `yyyy-MM-dd`.
    private static func airDateIso(daysFromToday days: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Knobs

/// DEBUG-only launch knobs that inject no data (so no guest rule). Read once.
enum HomeRowsDebugKnobs {
    /// `-debug.homeNoCatalogRows YES`: `HomeViewModel.rebuildRows()` drops every catalog and
    /// collection row, so Home has none, as on a no-catalog account. The settle then falls to
    /// `loadFinishedEmpty` or the 4 s backstop. Persists nothing.
    nonisolated static let noCatalogRows = UserDefaults.standard.bool(forKey: "debug.homeNoCatalogRows")
}

// MARK: - Readout

/// `debug_homeWatchlist on=<0|1> n=<count> first=<type:id|->`: the row's state as the UI legs read
/// it. Invisible (0.011 opacity) and not hit-testable, like the other `debug_*` readouts.
struct HomeWatchlistDebugLabel: View {
    @ObservedObject var model: HomeViewModel
    let enabled: Bool
    var body: some View {
        Text(verbatim: "debug_homeWatchlist on=\(enabled ? 1 : 0) n=\(model.watchlistSection?.items.count ?? 0) first=\(model.watchlistSection?.items.first.map { "\($0.type):\($0.id)" } ?? "-")")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_homeWatchlist")
            .allowsHitTesting(false)
    }
}
#endif
