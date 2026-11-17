import Foundation

/// W5 (review r1, findings 2–4): what the Library filter bar offers and what it selects, as one pure
/// function. `LibraryViewModel` feeds it the chosen list's titles (already de-duplicated and sorted
/// by the shared projection, which is asked for the list only: no type, genre or year) and the
/// viewer's requests; it applies the output and nothing else decides.
///
/// Rules (faceted search over the Type, Genre, Year and Show menus):
/// - Requests resolve in order type → genre → year, each against the titles that pass the Show
///   choice and the facets resolved before it. A request with no title there is unavailable: it is
///   not applied and it is reported in `clear`, so the view model forgets it (it never comes back
///   on its own when the titles change again; the caller applies `clear` only when `mayForget`
///   says the titles are authoritative). A genre matches case-insensitively and resolves to
///   the spelling the menu shows, so a request survives a narrowing that changes the spelling.
/// - Each menu's options and counts are computed over the titles that pass every OTHER active
///   filter, Show included (type counts: Show, genre, year; genres: Show, type, year; years: Show,
///   type, genre; Show choices: type, genre, year). An option with no title is never offered.
/// - A menu shows when it can split its titles (two or more options, or one option that fewer than
///   all of them carry: the rest have no genre or no year), or when it has a selection to undo.
/// - Nothing is cleared while the list has no titles (a provider list still loading).
nonisolated enum LibraryBarResolver {
    typealias SmartFilter = LibraryGridPolicy.SmartFilter
    typealias FacetOption = LibraryGridPolicy.FacetOption

    /// One title as the bar sees it.
    struct Title: Equatable, Sendable {
        /// `mediaCategory ?? type`, trimmed and lower-cased (the shared projection's type key).
        let typeKey: String
        /// Trimmed, non-blank, as the source wrote them.
        let genres: [String]
        /// The first four-digit run of `releaseInfo` ("2018–2021" → "2018"), or nil.
        let year: String?
        let state: LibraryGridPolicy.WatchState

        init(typeKey: String, genres: [String], year: String?, state: LibraryGridPolicy.WatchState) {
            self.typeKey = typeKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.genres = genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            self.year = year
            self.state = state
        }
    }

    /// What the viewer asked for. `type`, `genre`, `year` nil = All; `smartFilters` empty = All Titles.
    struct Request: Equatable, Sendable {
        var type: String?
        var genre: String?
        var year: String?
        var smartFilters: Set<SmartFilter> = []
    }

    /// Requests to forget because they are unavailable in these titles.
    struct Clear: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let type = Clear(rawValue: 1)
        static let genre = Clear(rawValue: 2)
        static let year = Clear(rawValue: 4)
    }

    struct Output: Equatable, Sendable {
        var selectedType: String?
        var selectedGenre: String?
        var selectedYear: String?
        /// Type menu rows in the list's type order, with counts; "All" counts `allTypesCount`.
        var types: [FacetOption]
        var allTypesCount: Int
        /// Genre rows, alphabetical (case-insensitive), one per genre in any spelling.
        var genres: [FacetOption]
        /// Year rows, newest first.
        var years: [FacetOption]
        /// The smart filters the Show menu offers (a choice that would split its titles, or is on).
        var visibleSmartFilters: [SmartFilter]
        var showsType: Bool
        var showsGenre: Bool
        var showsYear: Bool
        var showsShow: Bool
        /// Indices into the input titles to draw, in input order.
        var shown: [Int]
        var clear: Clear
    }

    /// The menu's type order (the shared projection's: movie, series, tv, show, anime, then the rest
    /// alphabetically), used when the caller has no order of its own.
    static let typeOrder = ["movie", "series", "tv", "show", "anime"]

    static func resolve(titles: [Title], request: Request, typeOrder order: [String]? = nil) -> Output {
        let passShow: (Title) -> Bool = { LibraryGridPolicy.passes($0.state, filters: request.smartFilters) }
        let canClear = !titles.isEmpty
        var clear: Clear = []

        // Types the list has, in order.
        let listTypes = orderedTypes(titles.map(\.typeKey), order: order)

        // 1. Type: the list must have it, and some title under Show.
        var type: String?
        if let wanted = request.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !wanted.isEmpty {
            if titles.contains(where: { $0.typeKey == wanted && passShow($0) }) {
                type = wanted
            } else if canClear {
                clear.insert(.type)
            }
        }
        let passType: (Title) -> Bool = { type == nil || $0.typeKey == type }

        // 2. Genre: some title under Show and type carries it (any spelling).
        var genre: String?
        if let wanted = normalized(request.genre) {
            let pool = titles.filter { passShow($0) && passType($0) }
            if let spelling = firstSpelling(of: wanted, in: pool) {
                genre = spelling
            } else if canClear {
                clear.insert(.genre)
            }
        }
        let genreKey = genre.map { $0.lowercased() }
        let passGenre: (Title) -> Bool = { t in genreKey == nil || t.genres.contains { $0.lowercased() == genreKey } }

        // 3. Year: some title under Show, type and genre has it.
        var year: String?
        if let wanted = request.year?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty {
            if titles.contains(where: { passShow($0) && passType($0) && passGenre($0) && $0.year == wanted }) {
                year = wanted
            } else if canClear {
                clear.insert(.year)
            }
        }
        let passYear: (Title) -> Bool = { year == nil || $0.year == year }

        // Options, each over the titles that pass every other filter.
        let typePool = titles.filter { passShow($0) && passGenre($0) && passYear($0) }
        var typeCounts: [String: Int] = [:]
        for t in typePool { typeCounts[t.typeKey, default: 0] += 1 }
        let typeOptions = listTypes.compactMap { key -> FacetOption? in
            let count = typeCounts[key] ?? 0
            return count > 0 || key == type ? FacetOption(key: key, count: count) : nil
        }

        let genrePool = titles.filter { passShow($0) && passType($0) && passYear($0) }
        let genreOptions = genreFacet(genrePool)
        // The selection names the menu row it ticks (that row's spelling).
        if let key = genreKey, let row = genreOptions.first(where: { $0.key.lowercased() == key }) {
            genre = row.key
        }

        let yearPool = titles.filter { passShow($0) && passType($0) && passGenre($0) }
        var yearCounts: [String: Int] = [:]
        for t in yearPool { if let y = t.year { yearCounts[y, default: 0] += 1 } }
        let yearOptions = yearCounts.map { FacetOption(key: $0.key, count: $0.value) }.sorted { $0.key > $1.key }

        let showPool = titles.filter { passType($0) && passGenre($0) && passYear($0) }
        let visibleSmart = LibraryGridPolicy.visibleSmartFilters(states: showPool.map(\.state), active: request.smartFilters)

        let shown = titles.indices.filter { i in
            let t = titles[i]
            return passShow(t) && passType(t) && passGenre(t) && passYear(t)
        }

        return Output(
            selectedType: type,
            selectedGenre: genre,
            selectedYear: year,
            types: typeOptions,
            allTypesCount: typePool.count,
            genres: genreOptions,
            years: yearOptions,
            visibleSmartFilters: visibleSmart,
            showsType: shows(typeOptions, selected: type, eligible: typePool.count),
            showsGenre: shows(genreOptions, selected: genre, eligible: genrePool.count),
            showsYear: shows(yearOptions, selected: year, eligible: yearPool.count),
            showsShow: !visibleSmart.isEmpty || !request.smartFilters.isEmpty,
            shown: shown,
            clear: clear
        )
    }

    // MARK: - When a forget may be applied (review r2)

    /// What the titles handed to `resolve` were cut from, for `mayForget`.
    struct Source: Equatable, Sendable {
        /// The library state has loaded once.
        var isLoaded: Bool
        /// A pull is in flight: a provider publishes partial snapshots meanwhile (Trakt: the
        /// watchlist before the personal lists, a list with no items yet left out of the sections).
        var isLoading: Bool
        /// The last pull failed: the sections are whatever was published before the failure.
        var hasError: Bool
        /// The list the viewer picked (nil = none, the source's first list or the local library).
        var requestedListKey: String?
        /// The list the projection actually cut the titles from (nil = the local library).
        var projectedListKey: String?
        var titleCount: Int
    }

    /// Whether `resolve`'s `clear` may be applied, i.e. the requests forgotten (and the type's
    /// remembered pick overwritten). Only when the titles are the requested list's own complete
    /// titles: loaded, no pull in flight, no failed pull, the requested list is the one projected
    /// (not a fallback while it is missing from a partial snapshot), and at least one title. Until
    /// then a request that has no title here is simply not applied this time; it stays remembered and
    /// applies again when its titles arrive.
    static func mayForget(_ source: Source) -> Bool {
        guard source.isLoaded, !source.isLoading, !source.hasError, source.titleCount > 0 else { return false }
        if let requested = source.requestedListKey { return requested == source.projectedListKey }
        return true
    }

    /// A menu is worth showing when it can split its titles or has a selection to undo. One option
    /// splits when fewer than all eligible titles carry it (the rest have no genre or no year).
    static func shows(_ options: [FacetOption], selected: String?, eligible: Int) -> Bool {
        if selected != nil { return true }
        if options.count >= 2 { return true }
        if let only = options.first { return only.count < eligible }
        return false
    }

    /// The release year the shared projection reads: the first run of four ASCII digits.
    static func releaseYear(_ releaseInfo: String?) -> String? {
        guard let releaseInfo else { return nil }
        var run: [Character] = []
        for ch in releaseInfo {
            if ch.isASCII, ch.isNumber {
                run.append(ch)
                if run.count == 4 { return String(run) }
            } else {
                run.removeAll(keepingCapacity: true)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func normalized(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
        return value
    }

    /// The first spelling of `lower` met in title order (the genre menu's key for it).
    private static func firstSpelling(of lower: String, in titles: [Title]) -> String? {
        for t in titles {
            if let hit = t.genres.first(where: { $0.lowercased() == lower }) { return hit }
        }
        return nil
    }

    /// One option per genre (case-insensitive, keyed by the first spelling met), a title counted
    /// once per genre, sorted case-insensitively.
    private static func genreFacet(_ titles: [Title]) -> [FacetOption] {
        var spelling: [String: String] = [:]
        var order: [String] = []
        var counts: [String: Int] = [:]
        for t in titles {
            var seen = Set<String>()
            for g in t.genres {
                let lower = g.lowercased()
                guard seen.insert(lower).inserted else { continue }
                if spelling[lower] == nil { spelling[lower] = g; order.append(lower) }
                counts[lower, default: 0] += 1
            }
        }
        return order.map { FacetOption(key: spelling[$0]!, count: counts[$0]!) }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
    }

    private static func orderedTypes(_ keys: [String], order: [String]?) -> [String] {
        var seen = Set<String>()
        let distinct = keys.filter { !$0.isEmpty && seen.insert($0).inserted }
        let rank = order ?? typeOrder
        return distinct.sorted { a, b in
            let ia = rank.firstIndex(of: a) ?? rank.count, ib = rank.firstIndex(of: b) ?? rank.count
            return ia != ib ? ia < ib : a < b
        }
    }
}
