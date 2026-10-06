import Combine
import Foundation
import SharedCore

// Search & Discover batch 2026-10-06 (O3 Stage Discover, plan A1): the stage Discover page's view
// model. It owns the selection (type + catalog), the rows of that selection and their genre-page
// fetches, and nothing else: the stage, the strip and the band are the page's.
//
//     AddonRepository.uiState ──watch──► DiscoverSources.options(addons:)  (shared, pure, C5)
//                                          │ signature unchanged → nothing
//                                          ▼
//     selection (persisted through DiscoverSources, the keys Search's Discover uses)
//                                          │
//                                          ▼
//     DiscoverRowsPlan.specs → loading rows ──rowAppeared──► DiscoverLoadScheduler.next (≤ 5)
//                                          │                              │
//                                          │       one Task per row: fetchCatalogPageChecked
//                                          ▼                              ▼
//     stripRows (published)  ◄──────── settled row (loaded / empty / failed)
//
// It never touches `CatalogRepository` or `FolderDetailRepository`: both are singletons with one
// active request, and a page that fetches a row per genre would fight Home and the folder page for
// them. Every genre page goes through `CatalogDataBridgingKt.fetchCatalogPageChecked` (the `@Throws`
// twin of `fetchCatalogPage`: the plain suspend export would abort the process on an HTTP error),
// then through Search's Discover filters (`DiscoverRowsPlan.displayItems`).
//
// A selection change cancels every fetch in flight (`[Discover] cancel` in the Console). That is the
// Swift `Task` only: cancelling it does not cancel the Kotlin request underneath, which runs to its
// end; the generation guard (`finish`) drops its result when it lands. The view model also keeps
// the rows of the last four selections (`DiscoverSelectionCache`), so going back to a type or
// catalog is instant; a row whose fetch was cancelled is still `.loading` there and starts again
// when the scheduler next runs.

/// What the view model fetches and persists through, injectable so the tests run without the
/// network or the profile's stored selection.
struct DiscoverRowsServices {
    /// One genre page, filtered and re-postered. `forceRefresh` is true for a Retry.
    let fetch: @MainActor (_ spec: DiscoverRowSpec, _ forceRefresh: Bool) async throws -> DiscoverRowPage
    /// The persisted catalog key to open on (Search's `discover_catalog_key`), when still offered.
    let restoreCatalogKey: @MainActor (_ options: [DiscoverCatalogOption]) -> String?
    /// Persists a pick. `option` is the catalog chosen; the live store keeps that catalog's
    /// remembered genre, so the stage never clears what Search's Discover remembers.
    let save: @MainActor (_ option: DiscoverCatalogOption) -> Void

    static let live = DiscoverRowsServices(
        fetch: { spec, forceRefresh in
            let page = try await CatalogDataBridgingKt.fetchCatalogPageChecked(
                manifestUrl: spec.manifestUrl,
                type: spec.type,
                catalogId: spec.catalogId,
                genre: spec.genre,
                maxItems: Int32(DiscoverRowsPlan.pageItems),
                forceRefresh: forceRefresh
            )
            CustomPosterUrlRepository.shared.ensureLoaded()
            let pattern = CustomPosterUrlRepository.shared.patternForScreen(screen: .search)
            let items = DiscoverRowsPlan.displayItems(
                page.items,
                hideUnreleased: HomeCatalogSettingsRepository.shared.snapshot().hideUnreleasedContent,
                todayIsoDate: CurrentDateProvider.shared.todayIsoDate(),
                nowEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
                posterPattern: pattern
            )
            return DiscoverRowPage(items: items, hasMore: page.nextSkip != nil)
        },
        restoreCatalogKey: { options in
            DiscoverSources.shared.restoreSelection(options: options)?.catalogKey
        },
        save: { option in
            // The catalog's own remembered genre (C4), resolved the way Search's Discover resolves
            // it, so this write never clears it.
            let genre = DiscoverSources.shared.restoreSelection(options: [option])?.genre
            DiscoverSources.shared.saveSelection(catalogKey: option.key, genre: genre)
        }
    )
}

/// See the file header.
@MainActor
final class DiscoverRowsViewModel: ObservableObject {
    /// One row per genre (or per catalog) of the selection, in order. Settled rows replace their
    /// loading row in place; an unchanged row keeps its instance (`StripRowsPlan.reusing`).
    @Published private(set) var stripRows: [StripRow] = []
    /// `DiscoverLoadScheduler.allSettled` for the current rows (the page state's input).
    @Published private(set) var allSettled = false
    /// `DiscoverRowsPlan.selectionKey`; "" with no selection. The page's pager is `.id`'d on it.
    @Published private(set) var selectionKey = ""
    @Published private(set) var selectedType: String?
    @Published private(set) var selectedCatalogKey: String?
    /// Distinct catalog types, in option order (the Type pill).
    @Published private(set) var typeOptions: [String] = []
    /// Every Discover-capable catalog of the enabled add-ons (C5).
    @Published private(set) var options: [DiscoverCatalogOption] = []
    /// Why there is no selection (`.ready` once there is one).
    @Published private(set) var sourcesState: DiscoverSourcesState = .waiting

    #if DEBUG
    /// The probe's in-flight count, kept off the page's own observation.
    let debug = DiscoverRowsDebugState()
    #endif

    private let services: DiscoverRowsServices
    private var specs: [DiscoverRowSpec] = []
    /// Rows the strip mounted, or the scheduler's forward walk started.
    private var requested = Set<String>()
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Rows whose next fetch bypasses the HTTP cache (Retry).
    private var forceRefresh = Set<String>()
    /// Bumped by every cancel: a fetch that finishes under an older generation is dropped.
    private var generation = 0
    private var cache = DiscoverSelectionCache<CachedSelection>()
    /// The last catalog picked per type, so Type › Series → Movies returns to the Movies catalog.
    private var catalogByType: [String: String] = [:]
    private var optionsSignature: String?

    private var addonWatcher: FlowWatcher?
    private var started = false
    /// H2 hardening (BUG-47), as `SearchViewModel.stopped`: a watcher resume queued before
    /// `stop()` can still deliver one value; this drops it. It also parks the scheduler.
    private var stopped = false

    private struct CachedSelection {
        let specs: [DiscoverRowSpec]
        let rows: [StripRow]
        let requested: Set<String>
    }

    /// nil = `.live` (a default argument would be evaluated off the main actor).
    init(services: DiscoverRowsServices? = nil) {
        self.services = services ?? .live
    }

    // MARK: Lifecycle

    /// Attaches the add-on watcher and resumes any row whose fetch a `stop()` cancelled.
    /// Idempotent; the host calls it on appear.
    func start() {
        guard !started else { return }
        started = true
        stopped = false
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? AddonsUiState else { return }
            self.addonsChanged(state)
        }
        AddonRepository.shared.initialize()
        pump()
    }

    /// Detaches the watcher and cancels the fetches in flight. Rows, selection and cache are kept:
    /// the next `start()` picks up where this left off.
    func stop() {
        stopped = true
        addonWatcher?.cancel()
        addonWatcher = nil
        started = false
        cancelInFlight(reason: "stop")
    }

    // MARK: Sources

    private func addonsChanged(_ state: AddonsUiState) {
        let addons = state.addons
        let enabled = AddonModelsKt.enabledAddons(addons)
        let options = DiscoverSources.shared.options(addons: addons)
        applySources(
            options: options,
            state: DiscoverRowsPlan.sourcesState(
                isInitialized: state.isInitialized,
                hasEnabledAddons: !enabled.isEmpty,
                manifestsPending: AddonModelsKt.hasPendingEnabledManifests(addons),
                manifestError: AddonModelsKt.firstEnabledManifestError(addons),
                hasEnabledManifest: enabled.contains { $0.manifest != nil },
                optionCount: options.count
            )
        )
    }

    /// One add-on snapshot's Discover catalogs. An unchanged option list keeps everything; a changed
    /// one drops the other cached selections and rebuilds the current one only when its rows
    /// changed (a genre added, a catalog renamed). Internal for the tests.
    func applySources(options: [DiscoverCatalogOption], state: DiscoverSourcesState) {
        if sourcesState != state { sourcesState = state }
        let signature = DiscoverRowsPlan.optionsSignature(options)
        guard signature != optionsSignature else { return }
        optionsSignature = signature
        self.options = options
        let types = DiscoverRowsPlan.types(options)
        if typeOptions != types { typeOptions = types }
        cache.removeAll()

        guard !options.isEmpty else {
            clearSelection()
            return
        }
        let keep = selectedCatalogKey.flatMap { key in options.first { $0.key == key } }
        let option = keep
            ?? services.restoreCatalogKey(options).flatMap { key in options.first { $0.key == key } }
            ?? options[0]
        let newSpecs = DiscoverRowsPlan.specs(for: option,
                                              catalogs: DiscoverRowsPlan.catalogs(ofType: option.type, in: options))
        if keep != nil, newSpecs == specs {
            return   // the shown rows are still right; only other selections were dropped
        }
        activate(option, specs: newSpecs, reason: "sources")
    }

    // MARK: Selection

    /// The Catalog pill's choices for `type`.
    func catalogOptions(for type: String) -> [DiscoverCatalogOption] {
        DiscoverRowsPlan.catalogs(ofType: type, in: options)
    }

    var selectedOption: DiscoverCatalogOption? {
        selectedCatalogKey.flatMap { key in options.first { $0.key == key } }
    }

    /// Type pill: the catalog last used for that type this session, else its first.
    func select(type: String) {
        guard type != selectedType else { return }
        let candidates = catalogOptions(for: type)
        guard let option = catalogByType[type].flatMap({ key in candidates.first { $0.key == key } })
            ?? candidates.first else { return }
        choose(option)
    }

    /// Catalog pill.
    func select(catalogKey: String) {
        guard catalogKey != selectedCatalogKey,
              let option = options.first(where: { $0.key == catalogKey }) else { return }
        choose(option)
    }

    private func choose(_ option: DiscoverCatalogOption) {
        services.save(option)
        let newSpecs = DiscoverRowsPlan.specs(for: option,
                                              catalogs: DiscoverRowsPlan.catalogs(ofType: option.type, in: options))
        activate(option, specs: newSpecs, reason: "select")
    }

    /// Makes `option` the selection: parks the current one in the cache (fetches cancelled, rows
    /// kept), then shows the new one's cached rows or fresh loading rows, and runs the scheduler.
    private func activate(_ option: DiscoverCatalogOption, specs newSpecs: [DiscoverRowSpec], reason: String) {
        cancelInFlight(reason: reason)
        if !selectionKey.isEmpty {
            cache.set(CachedSelection(specs: specs, rows: stripRows, requested: requested), for: selectionKey)
        }
        let key = DiscoverRowsPlan.selectionKey(type: option.type, catalogKey: option.key)
        catalogByType[option.type] = option.key
        forceRefresh.removeAll()
        if let cached = cache.value(for: key), cached.specs == newSpecs {
            specs = cached.specs
            requested = cached.requested
            stripRows = cached.rows
        } else {
            specs = newSpecs
            requested = []
            stripRows = DiscoverRowsPlan.loadingRows(newSpecs)
        }
        if selectedType != option.type { selectedType = option.type }
        if selectedCatalogKey != option.key { selectedCatalogKey = option.key }
        if selectionKey != key { selectionKey = key }
        NSLog("[Discover] select type=%@ catalog=%@ rows=%d reason=%@", option.type, option.key, specs.count, reason)
        pump()
    }

    private func clearSelection() {
        cancelInFlight(reason: "nosources")
        specs = []
        requested = []
        forceRefresh.removeAll()
        if !stripRows.isEmpty { stripRows = [] }
        if allSettled { allSettled = false }
        if selectedType != nil { selectedType = nil }
        if selectedCatalogKey != nil { selectedCatalogKey = nil }
        if !selectionKey.isEmpty { selectionKey = "" }
    }

    // MARK: Rows

    /// The strip mounted `key` (its loading row appeared): fetch it, within the cap.
    func rowAppeared(_ key: String) {
        guard specs.contains(where: { $0.key == key }) else { return }
        guard requested.insert(key).inserted else { return }
        pump()
    }

    /// A failed row's Retry chip.
    func retry(_ key: String) {
        guard let index = stripRows.firstIndex(where: { $0.id == key }), stripRows[index].status == .failed,
              let spec = specs.first(where: { $0.key == key }) else { return }
        forceRefresh.insert(key)
        requested.insert(key)
        stripRows[index] = DiscoverRowsPlan.loadingRows([spec])[0]
        pump()
    }

    /// The failed page's Try Again: every failed row loads again. With no selection (the add-ons
    /// themselves failed), the add-on manifests are refreshed instead.
    func retryAll() {
        guard !specs.isEmpty else {
            AddonRepository.shared.refreshAll()
            return
        }
        var rows = stripRows
        for (index, row) in rows.enumerated() where row.status == .failed {
            guard let spec = specs.first(where: { $0.key == row.id }) else { continue }
            forceRefresh.insert(row.id)
            requested.insert(row.id)
            rows[index] = DiscoverRowsPlan.loadingRows([spec])[0]
        }
        stripRows = rows
        pump()
    }

    /// The Grid pill's section (`DiscoverRowsPlan.gridSection`).
    func gridSection(focusedRowKey: String?) -> HomeCatalogSection? {
        DiscoverRowsPlan.gridSection(focusedRowKey: focusedRowKey, rows: stripRows)
    }

    var hasLoadedRow: Bool { stripRows.contains { $0.status == .loaded } }
    var loadedCount: Int { stripRows.filter { $0.status == .loaded }.count }
    var inFlightCount: Int { inFlight.count }

    // MARK: Scheduler

    /// Starts what `DiscoverLoadScheduler.next` names, then republishes `allSettled`.
    private func pump() {
        guard !stopped else { return }
        let start = DiscoverLoadScheduler.next(rows: stripRows,
                                               requested: requested,
                                               inFlight: Set(inFlight.keys))
        for key in start {
            launch(key)
        }
        let settled = DiscoverLoadScheduler.allSettled(rows: stripRows, requested: requested)
        if allSettled != settled { allSettled = settled }
        syncDebug()
    }

    private func launch(_ key: String) {
        guard let spec = specs.first(where: { $0.key == key }) else { return }
        requested.insert(key)
        let force = forceRefresh.remove(key) != nil
        let token = generation
        let fetch = services.fetch
        inFlight[key] = Task { [weak self] in
            let result: Result<DiscoverRowPage, Error>
            do {
                result = .success(try await fetch(spec, force))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finish(key, spec: spec, token: token, result: result)
        }
    }

    private func finish(_ key: String, spec: DiscoverRowSpec, token: Int, result: Result<DiscoverRowPage, Error>) {
        // A cancelled fetch (selection change, stop) never publishes, even if it resolved first.
        guard token == generation, inFlight[key] != nil else { return }
        inFlight[key] = nil
        guard let index = stripRows.firstIndex(where: { $0.id == key }) else {
            pump()
            return
        }
        let row: StripRow
        switch result {
        case .success(let page):
            row = DiscoverRowsPlan.settledRow(spec, page: page)
        case .failure(let error):
            NSLog("[Discover] row failed key=%@ error=%@", key, String(describing: error))
            row = DiscoverRowsPlan.failedRow(spec)
        }
        if stripRows[index] != row {
            var rows = stripRows
            rows[index] = row
            stripRows = StripRowsPlan.reusing(stripRows, for: rows)
        }
        pump()
    }

    /// Cancels the Swift tasks in flight and bumps the generation. The Kotlin request under each task
    /// is not cancelled (the suspend bridge does not propagate it) and runs to its end; `finish`
    /// drops its result because its token is now stale.
    private func cancelInFlight(reason: String) {
        generation &+= 1
        guard !inFlight.isEmpty else { return }
        NSLog("[Discover] cancel n=%d reason=%@", inFlight.count, reason)
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        syncDebug()
    }

    private func syncDebug() {
        #if DEBUG
        debug.setInFlight(inFlight.count)
        #endif
    }
}

extension DiscoverRowsPlan {
    /// Distinct catalog types in option order (`DiscoverSources.types`, restated so the view model
    /// and its tests don't need the shared object).
    static func types(_ options: [DiscoverCatalogOption]) -> [String] {
        var seen = Set<String>()
        return options.compactMap { seen.insert($0.type).inserted ? $0.type : nil }
    }
}

#if DEBUG
/// The `discover_rows_state … inflight=` source, observed only by the probe leaf. Write-on-change.
@MainActor
final class DiscoverRowsDebugState: ObservableObject {
    @Published private(set) var inFlight = 0
    /// The focused row's index among the rows the viewer can land on (0 = the top row).
    @Published private(set) var row: Int?
    /// The focused row's `order`.
    @Published private(set) var order: Int?
    /// A strip row holds focus.
    @Published private(set) var strip = false

    func setInFlight(_ value: Int) {
        if inFlight != value { inFlight = value }
    }

    func set(row: Int?, order: Int?) {
        if self.row != row { self.row = row }
        if self.order != order { self.order = order }
    }

    func setStrip(_ value: Bool) {
        if strip != value { strip = value }
    }
}
#endif
