import Foundation
import SharedCore

// Search & Discover batch 2026-10-06 (O3 Stage Discover, plan A1): the pure half of the stage
// Discover page. Discover leaves the bottom of the Search page and becomes a stage-and-strip page
// of its own, built like the folder Rows page (FEAT-43): one strip row per GENRE of the selected
// type + catalog, so the viewer pages "Action · Cinemeta", "Sci-Fi · Cinemeta", … with the stage
// showing the focused title above them.
//
//     DiscoverRowsPlan        selection → row specs → `StripRow`s (all `.loading` at first), a
//                             fetched page → a loaded / empty / failed row, the Grid pill's section,
//                             the band gate's position, the page's "no sources" state
//     DiscoverLoadScheduler   which rows to fetch next: rows the strip mounted (`rowAppeared`), at
//                             most 5 at a time, plus a FORWARD WALK while nothing has loaded
//     DiscoverSelectionCache  the rows of the last 4 selections (LRU), so Type › Movies → Series →
//                             Movies comes back without a refetch
//
// Rows (A1): a catalog with a genre extra gives one row per genre option, key
// `discover|<option.key>|g<i>`; a catalog without one gives one row per catalog OF THE TYPE (the
// selected catalog first), key `discover|<type>|c<i>`. No synthetic "All" row: the Grid pill opens
// the whole catalog. Headings are the genre (or catalog) name with the add-on after it, so the
// strip reads "Sci-Fi · Cinemeta" (`StageCopy.headingAddon`, the rule `CatalogRowView` applies to a
// loaded row under `\.rowHeadingShowsAddon`); a loading or settled-empty row draws the same text.
//
// Everything here is a pure function of its inputs (the shared Kotlin types it reads are values),
// so `DiscoverRowsPlanTests` and `DiscoverLoadSchedulerTests` pin it without a view host.

// MARK: - Row spec

/// What one Discover strip row fetches and how it is titled. One per row of a selection.
nonisolated struct DiscoverRowSpec: Equatable, Sendable {
    /// The strip key AND the section key (`StripRow.id`; see its doc comment for why they match).
    let key: String
    /// The row's place in the selection (`StripRow.order`): the visibility rule and the page's
    /// `deepestFocusedOrder` compare these.
    let order: Int
    /// The section title: the genre ("Sci-Fi"), or the catalog's name on a no-genre catalog.
    let title: String
    /// What a loading or message row draws: `title · add-on` (or `title` when the add-on name is
    /// blank or already in the title), the same text the loaded row's heading reads.
    let heading: String
    /// The section subtitle: the type's label ("Movies").
    let subtitle: String
    let addonName: String
    let manifestUrl: String
    let type: String
    let catalogId: String
    /// nil = the catalog without a genre filter.
    let genre: String?
    let supportsPagination: Bool
}

/// One fetched page, already through the unreleased filter and the custom poster pattern.
nonisolated struct DiscoverRowPage {
    let items: [MetaPreview]
    /// The catalog has another page (`CatalogPage.nextSkip != nil`): the row's See All gate.
    let hasMore: Bool
}

/// Why the page has no rows to show before any selection exists.
nonisolated enum DiscoverSourcesState: Equatable, Sendable {
    /// The add-on list hasn't settled (bootstrap, or an enabled manifest still loading).
    case waiting
    /// At least one Discover-capable catalog: the page has a selection.
    case ready
    /// No enabled add-on.
    case noAddons
    /// Enabled add-ons, none with a browsable catalog.
    case noCatalogs
    /// Enabled add-ons, none with a manifest, and one of them reported an error.
    case manifestFailure(String)

    /// The `discover_rows_state … state=` token while there is no selection.
    var token: String {
        switch self {
        case .waiting: return "waiting"
        case .ready: return "ready"
        case .noAddons: return "noaddons"
        case .noCatalogs: return "nocatalogs"
        case .manifestFailure: return "manifestfailure"
        }
    }
}

// MARK: - Plan

nonisolated enum DiscoverRowsPlan {
    /// Items asked of each genre page (`maxItems`): the strip shows the first 18 plus See All.
    static let pageItems = StripRowsPlan.previewLimit
    /// At most this many genre pages in flight at once (A1).
    static let maxConcurrentFetches = 5
    /// Selections whose rows are kept (A1: LRU of 4).
    static let cachedSelections = 4

    /// The selection's identity: the pager's `.id`, the cache key and the probe's `type=/catalog=`.
    static func selectionKey(type: String, catalogKey: String) -> String {
        "\(type)|\(catalogKey)"
    }

    /// The Type pill's labels, Search's mapping (`SearchView.typeLabel`), with the catalog's own
    /// type capitalised for anything else.
    static func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "movie": return String(localized: "Movies")
        case "series": return String(localized: "Series")
        case "tv": return String(localized: "TV")
        case "anime": return String(localized: "Anime")
        default: return type.capitalized
        }
    }

    /// Every option of `type`, in option order.
    static func catalogs(ofType type: String, in options: [DiscoverCatalogOption]) -> [DiscoverCatalogOption] {
        options.filter { $0.type == type }
    }

    /// The Catalog pill's label for `option`: its name, plus the add-on when another option of the
    /// same type carries the same name ("Popular · Cinemeta" beside "Popular · TMDB").
    static func catalogLabel(_ option: DiscoverCatalogOption, among options: [DiscoverCatalogOption]) -> String {
        let clashes = options.contains { other in
            other.key != option.key
                && other.catalogName.caseInsensitiveCompare(option.catalogName) == .orderedSame
        }
        return clashes ? "\(option.catalogName) \u{00B7} \(option.addonName)" : option.catalogName
    }

    /// The row heading text (`title · add-on`), `StageCopy.headingAddon`'s rule.
    static func heading(title: String, addonName: String) -> String {
        guard let addon = StageCopy.headingAddon(title: title, addonName: addonName) else { return title }
        return "\(title) \u{00B7} \(addon)"
    }

    /// A1's rows for the selected catalog. `catalogs` is every option of the selection's type
    /// (`catalogs(ofType:in:)`), used only by the no-genre fallback.
    static func specs(for option: DiscoverCatalogOption, catalogs: [DiscoverCatalogOption]) -> [DiscoverRowSpec] {
        let subtitle = typeLabel(option.type)
        let genres = option.genreOptions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !genres.isEmpty {
            return genres.enumerated().map { index, genre in
                DiscoverRowSpec(key: "discover|\(option.key)|g\(index)",
                                order: index,
                                title: genre,
                                heading: heading(title: genre, addonName: option.addonName),
                                subtitle: subtitle,
                                addonName: option.addonName,
                                manifestUrl: option.manifestUrl,
                                type: option.type,
                                catalogId: option.catalogId,
                                genre: genre,
                                supportsPagination: option.supportsPagination)
            }
        }
        return fallbackSpecs(selected: option, catalogs: catalogs)
    }

    /// No genre extra on the selected catalog: one row per catalog of the type, the selected one
    /// first, then option order. A catalog in the list that does take a genre is fetched with the
    /// genre it requires (its first option) and none otherwise, the same default Search applies.
    static func fallbackSpecs(selected: DiscoverCatalogOption, catalogs: [DiscoverCatalogOption]) -> [DiscoverRowSpec] {
        var ordered = [selected]
        for option in catalogs where option.key != selected.key && option.type == selected.type {
            ordered.append(option)
        }
        let subtitle = typeLabel(selected.type)
        return ordered.enumerated().map { index, option in
            let genre: String? = option.genreRequired ? option.genreOptions.first : nil
            return DiscoverRowSpec(key: "discover|\(selected.type)|c\(index)",
                                   order: index,
                                   title: option.catalogName,
                                   heading: heading(title: option.catalogName, addonName: option.addonName),
                                   subtitle: subtitle,
                                   addonName: option.addonName,
                                   manifestUrl: option.manifestUrl,
                                   type: option.type,
                                   catalogId: option.catalogId,
                                   genre: genre,
                                   supportsPagination: option.supportsPagination)
        }
    }

    /// Every row before its page arrives.
    static func loadingRows(_ specs: [DiscoverRowSpec]) -> [StripRow] {
        specs.map { spec in
            StripRow(id: spec.key, order: spec.order, heading: spec.heading, status: .loading,
                     section: nil, itemKeys: [], itemCount: 0, hasMore: false)
        }
    }

    /// The row's section. Every Kotlin argument is passed (the ObjC export drops defaults). nil for
    /// an empty page. `addonName` is the catalog's add-on, so the loaded heading reads
    /// "Sci-Fi · Cinemeta" under `\.rowHeadingShowsAddon`.
    static func section(_ spec: DiscoverRowSpec, page: DiscoverRowPage) -> HomeCatalogSection? {
        guard !page.items.isEmpty else { return nil }
        let target = CatalogTargetAddon(manifestUrl: spec.manifestUrl,
                                        contentType: spec.type,
                                        catalogId: spec.catalogId,
                                        genre: spec.genre,
                                        search: nil,
                                        supportsPagination: spec.supportsPagination)
        let shown = Array(page.items.prefix(StripRowsPlan.previewLimit))
        return HomeCatalogSection(key: spec.key,
                                  title: spec.title,
                                  subtitle: spec.subtitle,
                                  addonName: spec.addonName,
                                  target: target,
                                  items: shown,
                                  availableItemCount: Int32(page.items.count),
                                  hasMore: page.hasMore)
    }

    /// A settled page: `.loaded` with posters, `.empty` with none.
    static func settledRow(_ spec: DiscoverRowSpec, page: DiscoverRowPage) -> StripRow {
        guard let section = section(spec, page: page) else {
            return StripRow(id: spec.key, order: spec.order, heading: spec.heading, status: .empty,
                            section: nil, itemKeys: [], itemCount: 0, hasMore: false)
        }
        return StripRow(id: spec.key,
                        order: spec.order,
                        heading: spec.heading,
                        status: .loaded,
                        section: section,
                        itemKeys: section.items.prefix(StripRowsPlan.previewLimit).map(StripRowsPlan.itemKey),
                        itemCount: Int(section.availableItemCount),
                        hasMore: section.hasMore)
    }

    static func failedRow(_ spec: DiscoverRowSpec) -> StripRow {
        StripRow(id: spec.key, order: spec.order, heading: spec.heading, status: .failed,
                 section: nil, itemKeys: [], itemCount: 0, hasMore: false)
    }

    /// The Grid pill's section: the focused row's when it is loaded, else the first loaded row's.
    static func gridSection(focusedRowKey: String?, rows: [StripRow]) -> HomeCatalogSection? {
        if let focusedRowKey, let row = rows.first(where: { $0.id == focusedRowKey }),
           row.status == .loaded, let section = row.section {
            return section
        }
        return StripRowsPlan.firstFocusable(rows)?.section
    }

    /// The band gate's position: the focused row's index among the rows the viewer can land on, which
    /// on this page includes a failed row (its Retry chip takes focus and reports the row). nil when
    /// the row isn't one of them.
    static func focusPosition(of rowId: String, in rows: [StripRow]) -> Int? {
        rows.filter { $0.status == .loaded || $0.status == .failed }.firstIndex { $0.id == rowId }
    }

    /// The page's state while there is no selection, from one add-on snapshot.
    static func sourcesState(isInitialized: Bool,
                             hasEnabledAddons: Bool,
                             manifestsPending: Bool,
                             manifestError: String?,
                             hasEnabledManifest: Bool,
                             optionCount: Int) -> DiscoverSourcesState {
        if optionCount > 0 { return .ready }
        if !isInitialized || manifestsPending { return .waiting }
        if !hasEnabledAddons { return .noAddons }
        if !hasEnabledManifest, let manifestError, !manifestError.isEmpty {
            return .manifestFailure(manifestError)
        }
        return .noCatalogs
    }

    /// The options' identity: a change rebuilds the selection's rows (a genre list, an add-on name,
    /// a catalog added or removed). Equal signatures keep every cached row.
    static func optionsSignature(_ options: [DiscoverCatalogOption]) -> String {
        options.map { option in
            [option.key, option.addonName, option.manifestUrl, option.catalogName,
             option.genreOptions.joined(separator: ","), option.genreRequired ? "r" : "-",
             option.supportsPagination ? "p" : "-"].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }

    /// Search's Discover filters for one page (`SearchRepository`'s `withUnreleasedFilter` and the
    /// SEARCH custom poster pattern), so the stage page shows what Search's Discover showed.
    /// `fetchCatalogPage` applies neither.
    static func displayItems(_ items: [MetaPreview],
                             hideUnreleased: Bool,
                             todayIsoDate: String,
                             nowEpochMs: Int64,
                             posterPattern: String) -> [MetaPreview] {
        let released = hideUnreleased
            ? ReleaseInfoUtilsKt.filterReleasedItems(items, todayIsoDate: todayIsoDate, nowEpochMs: nowEpochMs)
            : items
        guard !posterPattern.isEmpty else { return released }
        return CustomPosterOverlayKt.withCustomPosterUrls(released, pattern: posterPattern)
    }
}

// MARK: - Load scheduler

/// Which rows to fetch next (A1). Rows load lazily: a row is REQUESTED when the strip mounts it
/// (`StripMountWindow`'s radius-2 window, `rowAppeared`), so a 25-genre catalog fetches the rows
/// around the viewer, not all 25. At most `maxConcurrent` pages are in flight.
///
/// The FORWARD WALK: while no row has loaded and every requested row has settled (they were all
/// empty or failed, so the visibility rule hid them and nothing below has mounted yet), the first
/// unrequested row is started too. Without it a selection whose first genres are empty would sit on
/// its loading panel forever. With nothing requested yet it starts row 0, the page's first fetch.
nonisolated enum DiscoverLoadScheduler {
    /// The row keys to start now, in row order. `requested` and `inFlight` are row keys; a row's
    /// settledness is its status (anything but `.loading`).
    static func next(rows: [StripRow],
                     requested: Set<String>,
                     inFlight: Set<String>,
                     maxConcurrent: Int = DiscoverRowsPlan.maxConcurrentFetches) -> [String] {
        let capacity = maxConcurrent - inFlight.count
        guard capacity > 0 else { return [] }
        var start = rows
            .filter { $0.status == .loading && requested.contains($0.id) && !inFlight.contains($0.id) }
            .map(\.id)
        if needsForwardWalk(rows: rows, requested: requested),
           let walk = rows.first(where: { $0.status == .loading && !requested.contains($0.id) && !inFlight.contains($0.id) }) {
            start.append(walk.id)
        }
        return Array(start.prefix(capacity))
    }

    /// Nothing loaded and nothing requested still loading.
    static func needsForwardWalk(rows: [StripRow], requested: Set<String>) -> Bool {
        guard !rows.contains(where: { $0.status == .loaded }) else { return false }
        return !rows.contains { $0.status == .loading && requested.contains($0.id) }
    }

    /// `StripRowsPlan.pageState`'s `allSettled` for a lazily loaded page: every row up to the
    /// deepest requested one has settled. False before anything is requested (the page is loading).
    static func allSettled(rows: [StripRow], requested: Set<String>) -> Bool {
        let deepest = rows.filter { requested.contains($0.id) }.map(\.order).max()
        guard let deepest else { return false }
        return !rows.contains { $0.order <= deepest && $0.status == .loading }
    }
}

// MARK: - Selection cache

/// The rows (and request bookkeeping) of the last `limit` selections, least recently used out
/// first (A1). A plain value; the view model owns one.
nonisolated struct DiscoverSelectionCache<Value> {
    let limit: Int
    private(set) var order: [String] = []
    private var values: [String: Value] = [:]

    init(limit: Int = DiscoverRowsPlan.cachedSelections) {
        self.limit = max(1, limit)
    }

    var keys: [String] { order }

    /// The value, marked most recently used.
    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// The value without changing its recency.
    func peek(_ key: String) -> Value? { values[key] }

    /// Stores `value` as most recently used; evicts the least recently used past `limit`.
    mutating func set(_ value: Value, for key: String) {
        values[key] = value
        touch(key)
        while order.count > limit {
            let evicted = order.removeFirst()
            values[evicted] = nil
        }
    }

    mutating func removeAll() {
        order.removeAll()
        values.removeAll()
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
