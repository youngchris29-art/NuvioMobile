import Foundation

/// W5 (review r1–r3): what the Library filter bar offers and what it selects, as pure functions.
/// `LibraryViewModel` feeds `resolve` the chosen list's titles (already de-duplicated and sorted by
/// the shared projection, which is asked for the list only: no type, genre or year) and the
/// viewer's remembered picks; it applies the output, and `picksToDrop` says which picks to forget.
/// Nothing else decides.
///
/// The rule (review r3): data never forgets a pick; only the viewer does.
/// - A remembered pick with no title in the titles on screen is not applied: the output's
///   selection (the effective value) is All for it, and the drawn titles match that effective
///   value. The pick itself stays remembered and applies again when its titles return (a cached,
///   partial, failed or optimistic provider snapshot can never cost the viewer a pick).
/// - At a viewer action (a pick in any menu, Clear Filters) the session picks that have no title
///   under the new selection (genre, year, Show) are dropped for good (`picksToDrop`), so they do
///   not come back when the viewer switches back. The remembered list and type change only when the
///   viewer picks a list or a type; they are never dropped by data or by another menu.
/// - Picks resolve in order type → Show → genre → year, each against the titles that pass the
///   picks resolved before it. A genre matches case-insensitively and resolves to the spelling the
///   menu shows, so a pick survives a narrowing that changes the spelling.
/// - Each menu's options and counts are computed over the titles that pass every OTHER active
///   filter, Show included (type counts: Show, genre, year; genres: Show, type, year; years: Show,
///   type, genre; Show choices: type, genre, year). An option with no title is never offered.
/// - A menu shows when it can split its titles (two or more options, or one option that fewer than
///   all of them carry: the rest have no genre or no year), or when it has a selection to undo.
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

    /// A set of picks: the ones with no title here (`Output.unavailable`), or the ones to drop.
    struct Picks: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let type = Picks(rawValue: 1)
        static let genre = Picks(rawValue: 2)
        static let year = Picks(rawValue: 4)
        static let show = Picks(rawValue: 8)
        /// The picks the viewer makes for the session (not remembered across launches, decision AO).
        static let session: Picks = [.genre, .year, .show]
    }

    /// What the viewer just did. A library emission (any provider snapshot) is not an action.
    enum ViewerAction: Equatable, Sendable {
        case list, type, show, genre, year, clearFilters
    }

    /// The picks to forget after `action`, given the picks `resolve` found unavailable for the new
    /// selection: the session picks with no title, and only at a viewer action. A snapshot (`nil`)
    /// never drops anything, and the remembered list and type are never dropped here (they change
    /// only through their own menus).
    static func picksToDrop(after action: ViewerAction?, unavailable: Picks) -> Picks {
        guard action != nil else { return [] }
        return unavailable.intersection(.session)
    }

    struct Output: Equatable, Sendable {
        /// The effective selections: what the menus show and the drawn titles follow. Nil (or empty
        /// smart filters) where the remembered pick has no title here.
        var selectedType: String?
        var selectedGenre: String?
        var selectedYear: String?
        var smartFilters: Set<SmartFilter>
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
        /// Remembered picks with no title here (not applied this time).
        var unavailable: Picks
    }

    /// The menu's type order (the shared projection's: movie, series, tv, show, anime, then the rest
    /// alphabetically), used when the caller has no order of its own.
    static let typeOrder = ["movie", "series", "tv", "show", "anime"]

    static func resolve(titles: [Title], request: Request, typeOrder order: [String]? = nil) -> Output {
        var unavailable: Picks = []

        // Types the list has, in order.
        let listTypes = orderedTypes(titles.map(\.typeKey), order: order)

        // 1. Type (remembered): the list must have it.
        var type: String?
        if let wanted = request.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !wanted.isEmpty {
            if titles.contains(where: { $0.typeKey == wanted }) {
                type = wanted
            } else {
                unavailable.insert(.type)
            }
        }
        let passType: (Title) -> Bool = { type == nil || $0.typeKey == type }

        // 2. Show: some title of the type passes it.
        var smart: Set<SmartFilter> = []
        if !request.smartFilters.isEmpty {
            if titles.contains(where: { passType($0) && LibraryGridPolicy.passes($0.state, filters: request.smartFilters) }) {
                smart = request.smartFilters
            } else {
                unavailable.insert(.show)
            }
        }
        let passShow: (Title) -> Bool = { LibraryGridPolicy.passes($0.state, filters: smart) }

        // 3. Genre: some title under type and Show carries it (any spelling).
        var genre: String?
        if let wanted = normalized(request.genre) {
            let pool = titles.filter { passShow($0) && passType($0) }
            if let spelling = firstSpelling(of: wanted, in: pool) {
                genre = spelling
            } else {
                unavailable.insert(.genre)
            }
        }
        let genreKey = genre.map { $0.lowercased() }
        let passGenre: (Title) -> Bool = { t in genreKey == nil || t.genres.contains { $0.lowercased() == genreKey } }

        // 4. Year: some title under type, Show and genre has it.
        var year: String?
        if let wanted = request.year?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty {
            if titles.contains(where: { passShow($0) && passType($0) && passGenre($0) && $0.year == wanted }) {
                year = wanted
            } else {
                unavailable.insert(.year)
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
        let visibleSmart = LibraryGridPolicy.visibleSmartFilters(states: showPool.map(\.state), active: smart)

        let shown = titles.indices.filter { i in
            let t = titles[i]
            return passShow(t) && passType(t) && passGenre(t) && passYear(t)
        }

        return Output(
            selectedType: type,
            selectedGenre: genre,
            selectedYear: year,
            smartFilters: smart,
            types: typeOptions,
            allTypesCount: typePool.count,
            genres: genreOptions,
            years: yearOptions,
            visibleSmartFilters: visibleSmart,
            showsType: shows(typeOptions, selected: type, eligible: typePool.count),
            showsGenre: shows(genreOptions, selected: genre, eligible: genrePool.count),
            showsYear: shows(yearOptions, selected: year, eligible: yearPool.count),
            showsShow: !visibleSmart.isEmpty || !smart.isEmpty,
            shown: shown,
            unavailable: unavailable
        )
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
