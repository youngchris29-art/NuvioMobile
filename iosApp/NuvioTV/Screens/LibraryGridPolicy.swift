import Foundation

/// Library L1 (2026-10-04, `docs/library-l1-grid-plan-2026-10-04.md` in the outer repo): the pure
/// rules behind the Library grid's header, pills, smart filters, badges and empty states.
///
/// `LibraryViewModel` feeds it plain values (no SharedCore types), so `LibraryGridPolicyTests`
/// can pin every decision without a Kotlin runtime. The view only renders what this says.
enum LibraryGridPolicy {
    // MARK: - Watch state

    /// A title's watch state as the grid sees it.
    struct WatchState: Equatable {
        /// A movie's own marker, or a series that is fully watched (or marked at title level):
        /// the same test the hold menu's "Mark as Unwatched" label uses.
        var isWatched: Bool
        /// 0...1 when an unfinished playback position is worth drawing, else nil. See
        /// `visibleProgress(fraction:isCompleted:)`.
        var progress: Double?

        /// In progress = a drawable position on a title that isn't watched. A finished series
        /// with a stray half-watched episode reads as watched, not in progress.
        var isInProgress: Bool { progress != nil && !isWatched }
    }

    /// Below this a position is a misclick or a probe; at or above `progressCeiling` it reads as
    /// done. Either way no bar is drawn and the title isn't "In Progress".
    static let progressFloor = 0.02
    static let progressCeiling = 0.97

    /// The bar a card draws for a raw progress fraction, or nil for none.
    static func visibleProgress(fraction: Double, isCompleted: Bool) -> Double? {
        guard !isCompleted, fraction.isFinite else { return nil }
        guard fraction >= progressFloor, fraction < progressCeiling else { return nil }
        return fraction
    }

    // MARK: - Smart filters

    /// VortX's smart filters (Short is left out: library items carry no runtime).
    enum SmartFilter: String, CaseIterable, Hashable {
        case unwatched
        case inProgress
        case watched

        var title: String {
            switch self {
            case .unwatched: return String(localized: "Unwatched")
            case .inProgress: return String(localized: "In Progress")
            case .watched: return String(localized: "Watched")
            }
        }
    }

    /// Whether a title passes every active filter. Active filters combine with AND.
    static func passes(_ state: WatchState, filters: Set<SmartFilter>) -> Bool {
        for filter in filters {
            switch filter {
            case .unwatched: if state.isWatched { return false }
            case .inProgress: if !state.isInProgress { return false }
            case .watched: if !state.isWatched { return false }
            }
        }
        return true
    }

    /// The active set after a chip press. A pressed chip that is on turns off. One that is off
    /// turns on and drops the chips it can never combine with: Watched excludes both Unwatched and
    /// In Progress (an in-progress title is never watched), so those pairs would always be empty.
    static func toggling(_ filter: SmartFilter, in active: Set<SmartFilter>) -> Set<SmartFilter> {
        var next = active
        if next.contains(filter) {
            next.remove(filter)
            return next
        }
        next.insert(filter)
        switch filter {
        case .unwatched, .inProgress:
            next.remove(.watched)
        case .watched:
            next.remove(.unwatched)
            next.remove(.inProgress)
        }
        return next
    }

    /// The chips worth showing for `states` (the titles left after the list and type choices,
    /// before any smart filter). A chip shows only when it would split the set, i.e. some titles
    /// pass and some don't, or when it is already on, so it can always be turned off again.
    /// Keeps `SmartFilter.allCases` order.
    static func visibleSmartFilters(states: [WatchState], active: Set<SmartFilter>) -> [SmartFilter] {
        SmartFilter.allCases.filter { filter in
            if active.contains(filter) { return true }
            let passing = states.reduce(0) { $0 + (passes($1, filters: [filter]) ? 1 : 0) }
            return passing > 0 && passing < states.count
        }
    }

    // MARK: - Header

    /// The count line under the title, e.g. "31 movies · 17 series". `kinds` are the shared
    /// projection's type keys (`mediaCategory ?? type`, lowercased), one per visible title.
    /// Empty when there is nothing to count.
    static func countLine(kinds: [String]) -> String {
        var movies = 0
        var series = 0
        var anime = 0
        var other = 0
        for kind in kinds {
            switch normalizedKind(kind) {
            case "movie": movies += 1
            case "series": series += 1
            case "anime": anime += 1
            default: other += 1
            }
        }
        var parts: [String] = []
        if movies > 0 {
            parts.append(movies == 1 ? String(localized: "1 movie") : String(localized: "\(movies) movies"))
        }
        if series > 0 {
            parts.append(series == 1 ? String(localized: "1 series") : String(localized: "\(series) series"))
        }
        if anime > 0 {
            parts.append(String(localized: "\(anime) anime"))
        }
        if other > 0 {
            parts.append(other == 1 ? String(localized: "1 other title") : String(localized: "\(other) other titles"))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Folds the type spellings add-ons and trackers use onto the four count buckets.
    static func normalizedKind(_ kind: String) -> String {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "movie", "movies", "film": return "movie"
        case "series", "show", "shows", "tv", "tvshow": return "series"
        case "anime": return "anime"
        default: return "other"
        }
    }

    /// Label for a type segment (the projection's type keys).
    static func typeLabel(_ kind: String) -> String {
        switch normalizedKind(kind) {
        case "movie": return String(localized: "Movies")
        case "series": return String(localized: "Series")
        case "anime": return String(localized: "Anime")
        default: return kind.capitalized
        }
    }

    // MARK: - Source

    /// The provider behind the library, from the shared `LibrarySourceMode` case name
    /// (`TRAKT` / `SIMKL` / `MDBLIST`). Nil for the local Nuvio library.
    static func providerName(sourceModeName: String) -> String? {
        switch sourceModeName.uppercased() {
        case "TRAKT": return "Trakt"
        case "SIMKL": return "Simkl"
        case "MDBLIST": return "MDBList"
        default: return nil
        }
    }

    /// The small spaced badge beside the title (official NuvioTV's LOCAL / TRAKT / …). Nil for
    /// the local library, which needs no badge.
    static func sourceBadge(sourceModeName: String) -> String? {
        providerName(sourceModeName: sourceModeName)?.uppercased()
    }

    // MARK: - Sort

    /// Label for a shared `LibrarySortOption`, by its Kotlin case name. DEFAULT is the provider's
    /// own order: Trakt's rank for Trakt, newest-added-then-rank for MDBList, the list order for
    /// Simkl; only Trakt's is named after the provider (the old "Trakt Order" label was shown for
    /// all three).
    static func sortLabel(optionName: String, sourceModeName: String) -> String {
        switch optionName {
        case "DEFAULT":
            return sourceModeName.uppercased() == "TRAKT"
                ? String(localized: "Trakt Order")
                : String(localized: "List Order")
        case "ADDED_DESC": return String(localized: "Recently Added")
        case "ADDED_ASC": return String(localized: "Oldest First")
        case "TITLE_ASC": return String(localized: "A\u{2013}Z")
        case "TITLE_DESC": return String(localized: "Z\u{2013}A")
        default: return optionName
        }
    }

    // MARK: - What the screen shows

    enum Content: Equatable {
        /// First load, or a load still running with nothing to show yet.
        case loading
        /// A load failed and there is nothing cached to show. Offers Retry.
        case failed(message: String)
        /// Nothing saved at all (in this provider, for a provider library).
        case empty
        /// Titles exist, but the smart filters leave none. Offers Clear Filters.
        case noMatches
        case grid
    }

    /// Mirrors mobile's `LibraryScreen` order: loading, then failure, then empty. A failure WITH
    /// cached sections still shows the grid (stale beats blank).
    static func content(
        isLoaded: Bool,
        isLoading: Bool,
        errorMessage: String?,
        hasAnySection: Bool,
        visibleCount: Int,
        smartFiltersActive: Bool
    ) -> Content {
        if !isLoaded || (isLoading && !hasAnySection) { return .loading }
        let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !message.isEmpty, !hasAnySection { return .failed(message: message) }
        if !hasAnySection { return .empty }
        if visibleCount == 0 { return smartFiltersActive ? .noMatches : .empty }
        return .grid
    }

    static func emptyTitle(providerName: String?) -> String {
        guard let providerName else { return String(localized: "Your library is empty") }
        return String(localized: "Your \(providerName) library is empty")
    }

    static func emptyMessage(providerName: String?) -> String {
        guard let providerName else {
            return String(localized: "Add movies and shows with the + button on a title\u{2019}s page.")
        }
        return String(localized: "Titles you add to your \(providerName) watchlist or lists show up here.")
    }

    /// A provider list that is empty while the provider has other lists.
    static func emptyListTitle(listTitle: String) -> String {
        let trimmed = listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Nothing in this list yet") }
        return String(localized: "Nothing in \(trimmed) yet")
    }

    static var noMatchesTitle: String {
        String(localized: "No titles match these filters")
    }

    static func failedTitle(providerName: String?) -> String {
        guard let providerName else { return String(localized: "Couldn\u{2019}t load your library") }
        return String(localized: "Couldn\u{2019}t load your \(providerName) library")
    }

    // MARK: - Hold menu

    /// The remove action's label. A provider list names the list; the local library (or a
    /// provider library with no list picked) keeps "Remove from Library".
    static func removeLabel(listTitle: String?) -> String {
        guard let listTitle, !listTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Remove from Library")
        }
        return String(localized: "Remove from \(listTitle)")
    }
}
