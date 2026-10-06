import Combine
import Foundation
import SharedCore

/// Drives the Search screen. Observes the installed addons (to pass into `SearchRepository.search`),
/// the shared `SearchRepository.uiState` (results), the per-profile search history
/// (`SearchHistoryRepository`) and where Discover lives (`DiscoverPlacement`).
///
/// Search & Discover batch 2026-10-06 (B2): results arrive grouped (C2): a Top result, one row per
/// media type merged across add-ons ("Found in …" per card), TMDB People (C3), and suggestion
/// chips. `SearchResultsAdapter` turns a state into rows for the active `SearchRowsMode`
/// (grouped by type, or the S1 one-row-per-add-on sections), and `SearchRowsHold` keeps the
/// previous rows up while the next query loads, keyed on `SearchUiState.requestId` (C1). Discover
/// no longer lives here: it is a stage page of its own (`DiscoverPlacement`), so the Discover
/// watcher and its selection calls are gone.
///
/// Queries are debounced (350 ms) so we don't fire a request on every keystroke.
@MainActor
final class SearchViewModel: ObservableObject {
    /// FEAT-10: which search-capable catalogs the user has switched OFF in Settings →
    /// Content Sources → Search Sources. Stored as their stable `manifestId:type:catalogId`
    /// keys. Local to this Apple TV (not synced), like the appearance toggles — keys for
    /// since-uninstalled addons linger harmlessly (they never match) and re-arm if the
    /// addon comes back.
    enum SearchSourceSettings {
        private static let defaultsKey = "search_disabled_catalog_keys"

        static var disabledKeys: Set<String> {
            Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        }

        static func setDisabled(_ disabled: Bool, forKey key: String) {
            var keys = disabledKeys
            if disabled { keys.insert(key) } else { keys.remove(key) }
            UserDefaults.standard.set(Array(keys).sorted(), forKey: defaultsKey)
        }

        /// Persists an entire resolved disabled-keys set in one write. Callers that compute a
        /// whole new set (e.g. the collision-group resolver in `SettingsViewModel.setSearchSource`)
        /// should use this instead of a remove/add diff loop: a single `UserDefaults.set` call is
        /// atomic for this purpose, so app termination mid-update can't land on a torn state where
        /// some sibling keys were persisted and others weren't.
        static func setAll(_ keys: Set<String>) {
            UserDefaults.standard.set(Array(keys).sorted(), forKey: defaultsKey)
        }
    }
    /// B6: grouped by type (default) or one row per add-on. Device-local, re-read on
    /// `UserDefaults.didChangeNotification`; a change re-derives the rows from the last emission
    /// (no network).
    @Published private(set) var rowsMode: SearchRowsMode = SearchRowsMode.current()
    /// The result rows for `rowsMode`, as the hold lets them through: grouped mode has one row per
    /// media type (key `search.group.type:<type>`, title "Movies · 12", no See All); per-add-on
    /// mode has the repository's sections. The Top result is NOT one of these rows.
    @Published private(set) var rows: [HomeCatalogSection] = []
    /// `type:id` (Kotlin `MetaPreview.stableKey()`) → the add-on names that returned that title,
    /// metadata add-ons first. Grouped mode only (empty per add-on). Read via `foundInCaption`.
    @Published private(set) var foundIn: [String: [String]] = [:]
    /// The Top result card's title; nil in per-add-on mode or with nothing found.
    @Published private(set) var topResult: MetaPreview?
    /// TMDB people for the People row (empty when TMDB is off or nothing matched).
    @Published private(set) var people: [MetaPerson] = []
    /// The suggestion chips: the typed query in curly quotes first (`SearchSuggestionPolicy.quoted`,
    /// selecting it records the query to Recent), then up to eight completions (selecting one
    /// sets the query). Empty while the field is empty.
    @Published private(set) var suggestions: [String] = []
    /// What a settled search with nothing to show says (B3 g). Replaces S1's `emptyMessage` and
    /// `searchError`. Nil while loading, while anything is shown, or with an empty field.
    @Published private(set) var emptyState: SearchEmptyState?
    /// True while the add-ons are still answering, or while only the People lookup is outstanding
    /// and nothing is shown yet (so "Searching…" covers the gap instead of an empty page).
    @Published private(set) var isLoading: Bool = false
    /// BUG-33 defect 1 instrumentation: passthrough of `SearchUiState.lastFanOut` — a
    /// human-readable "searched N of M catalogs" line set by the shared repo right after the
    /// last `search()` call. Settings → Content Sources → Search Sources renders the same value
    /// via its own watcher on `SearchRepository.shared.uiState` (this tab and the Settings tab
    /// hold independent view-model instances, so each watches the shared state directly rather
    /// than one passing a value to the other).
    @Published private(set) var lastFanOut: String?
    /// Recent searches for this profile (most recent first).
    @Published private(set) var history: [String] = []
    /// A5: where Discover lives. Search shows its entry row only for `.underSearch`. Re-read on
    /// `UserDefaults.didChangeNotification` and on the synced Hide Discover flag (UX-8, which wins).
    @Published private(set) var discoverPlacement: DiscoverPlacement = DiscoverPlacement.current()

    private var catalogSettingsWatcher: FlowWatcher?
    private var addonWatcher: FlowWatcher?
    private var searchWatcher: FlowWatcher?
    private var historyWatcher: FlowWatcher?
    private var defaultsObserver: AnyCancellable?
    private var enabledAddons: [ManagedAddon] = []
    /// Keys of every search-capable catalog across the enabled add-ons (the Search Sources list),
    /// for the "all sources off" empty state.
    private var searchOptionKeys: [String] = []
    /// Upstream 085e8dc6 (#1819): the trimmed query currently being searched (nil while the field
    /// is empty). `SearchRepository.search` only recomputes its pending-manifest state when it is
    /// called again, and this screen otherwise calls it only from the typing debounce — so an addon
    /// manifest landing or failing mid-query has to re-issue the search itself.
    private var activeQuery: String?
    /// B2: the `SearchUiState.requestId` of the active search: what `search()` returned (a deduped
    /// same-key call returns the live id). Nil while the field is empty. Every emission with
    /// another id is a late write of another search and is dropped (`SearchRowsHold.isStale`).
    private var activeRequestId: Int64?
    /// Read-only for the DEBUG `search_state` probe (review r1 P3-7): the id the active search's
    /// emissions must carry.
    var debugActiveRequestId: Int64? { activeRequestId }
    /// Read-only for the probe: the rows hold's phase (`SearchRowsHold.phaseToken`).
    var debugHoldPhase: String { rowsHold.phaseToken }
    private var lastSearchAddonSignature: String?
    private var debounce: Task<Void, Never>?
    private var started = false

    /// H2 hardening (BUG-47), mirrors `CatalogGridViewModel.stopped`: `FlowWatcher.cancel()`'s
    /// cancellation is cooperative, so a resume already queued on the main run loop can deliver one
    /// more value to a callback AFTER `stop()` returns, driving `@Published` mutations into a view
    /// mid-pop. One flag for all the watchers — they're always started and stopped together.
    private var stopped = false
    /// S1 W1: what to show while the next query loads. See `SearchRowsHold`.
    private var rowsHold = SearchRowsHold()
    /// The repository's last ACCEPTED emission (not stale when it arrived), for the hold's
    /// deadline tick (review r1 P2-1), `holdSearchStarted` and a rows-mode switch. It can be the
    /// previous search's once the next one starts; the tick checks.
    private var lastSearchState: SearchUiState?
    /// The request id and query of the emission whose rows are on screen (set while following).
    private var shownRequestId: Int64?
    private var shownQuery: String?
    /// Completion candidates of the emission on screen (`SearchResultsAdapter.suggestionCandidates`).
    private var suggestionCandidates: [String] = []
    private var holdTickGeneration = 0
    private var scheduledHoldDeadline: TimeInterval?

    func start() {
        guard !started else { return }
        started = true
        stopped = false
        refreshDefaults()

        searchWatcher = FlowWatcherKt.watch(SearchRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? SearchUiState else { return }
            self.accept(state)
        }

        historyWatcher = FlowWatcherKt.watch(SearchHistoryRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let items = emitted as? [String] else { return }
            self.history = items
        }
        SearchHistoryRepository.shared.ensureLoaded()

        // UX-8: the synced Hide Discover flag is the Off value of the placement (`DiscoverPlacement`
        // lets it win), so follow it live.
        catalogSettingsWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard emitted is HomeCatalogSettingsUiState else { return }
            self.refreshPlacement()
        }

        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? AddonsUiState else { return }
            self.enabledAddons = AddonModelsKt.enabledAddons(state.addons)
            self.searchOptionKeys = SearchRepository.shared
                .searchCatalogOptions(addons: self.enabledAddons)
                .map(\.key)
            self.researchIfAddonsChanged()
            self.refreshEmptyState()
        }

        // B6 / A5: the rows mode, the Discover placement and the Search Sources switches are all
        // device-local defaults; any write may be one of them.
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.stopped else { return }
                self.refreshDefaults()
            }

        AddonRepository.shared.initialize()
    }

    func stop() {
        // H2: flip first, before tearing down the watchers — see the `stopped` doc comment.
        stopped = true
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
        historyWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
        defaultsObserver?.cancel()
        addonWatcher = nil
        searchWatcher = nil
        historyWatcher = nil
        catalogSettingsWatcher = nil
        defaultsObserver = nil
        started = false
        // `activeQuery` / `activeRequestId` deliberately survive: the query box (`SearchQueryBox`)
        // outlives a tab switch and `SearchFieldLayer`'s `.onChange` won't refire, so the next addon
        // emission after start() must still be able to re-issue, and the repository's state for it
        // must still read as the active one. The same-key early return keeps that a no-op otherwise.
        lastSearchAddonSignature = nil
        cancelHoldTick()
    }

    // MARK: - Emissions

    /// One repository emission: drop it if it answers another search, else run the rows through
    /// the hold and, when the hold lets this emission's rows through, adopt its extras too.
    private func accept(_ state: SearchUiState) {
        // Review r4 P2-1, now by request id (B2): a cancelled search can write after the next one
        // started (or after the field was cleared); its rows, start state or empty settle are
        // another query's, so the whole emission is dropped rather than shown or held for the tick.
        guard !isStale(state) else {
            // `stop()` cancels the tick but keeps the hold; if this was the first value after
            // `start()`, nothing else would re-arm it (review r6 P3-3). Idempotent.
            scheduleHoldTick()
            return
        }
        lastSearchState = state
        let incoming = SearchResultsAdapter.rows(from: state, mode: rowsMode)
        // S1 W1: keep the previous query's rows while the next one loads (`SearchRowsHold`); the
        // repository starts every search with empty results.
        rows = rowsHold.rows(
            current: rows,
            incoming: incoming,
            isLoading: state.isLoading,
            now: ProcessInfo.processInfo.systemUptime,
            relation: holdRelation(incoming: incoming)
        )
        if rowsHold.isFollowingIncoming { adoptExtras(from: state) }
        scheduleHoldTick()
        isLoading = state.isLoading || (state.peopleLoading && rows.isEmpty)
        refreshEmptyState()
        lastFanOut = state.lastFanOut
    }

    /// Whether an emission answers a search other than the active one. By request id while a
    /// search is active; with an empty field (no active id) by the query it answers, so a late
    /// search write can't refill a cleared page.
    private func isStale(_ state: SearchUiState) -> Bool {
        if activeRequestId != nil {
            return SearchRowsHold.isStale(emissionRequestId: state.requestId, activeRequestId: activeRequestId)
        }
        return SearchRowsHold.isStale(emissionQuery: Self.emissionQuery(of: state), activeQuery: activeQuery)
    }

    /// The query an emission answers: Kotlin's `query` (C1), else the label on its per-add-on rows.
    private static func emissionQuery(of state: SearchUiState) -> String? {
        state.query ?? searchedQuery(of: state.sections)
    }

    /// Take the Top result, "Found in", People and suggestion candidates of the emission whose
    /// rows are now on screen (nil: nothing is, e.g. a hold released to "Searching…"). Writes
    /// only on change, so an unchanged partial emission re-renders nothing.
    private func adoptExtras(from state: SearchUiState?) {
        let newFoundIn = state.map { SearchResultsAdapter.foundIn(from: $0, mode: rowsMode) } ?? [:]
        let newTop = state.flatMap { SearchResultsAdapter.topResult(from: $0, mode: rowsMode) }
        let newPeople = state.map { SearchResultsAdapter.people(from: $0) } ?? []
        if foundIn != newFoundIn { foundIn = newFoundIn }
        if topResult != newTop { topResult = newTop }
        if people != newPeople { people = newPeople }
        suggestionCandidates = state.map { SearchResultsAdapter.suggestionCandidates(from: $0) } ?? []
        shownRequestId = state?.requestId
        shownQuery = state.flatMap { Self.emissionQuery(of: $0) }
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        let chips = SearchSuggestionPolicy.chips(query: activeQuery, candidates: suggestionCandidates)
        if suggestions != chips { suggestions = chips }
    }

    /// B3 g: resolved only for a settled search of the ACTIVE request with nothing on screen (no
    /// rows, no Top result, no people, the People lookup answered).
    private func refreshEmptyState() {
        var resolved: SearchEmptyState?
        if let state = lastSearchState, activeQuery != nil, !isStale(state),
           rowsHold.isFollowingIncoming,
           !state.isLoading, !state.peopleLoading,
           rows.isEmpty, topResult == nil, people.isEmpty {
            let disabled = SearchSourceSettings.disabledKeys
            resolved = SearchEmptyState.resolve(
                reason: state.emptyStateReason,
                hasEnabledAddons: !enabledAddons.isEmpty,
                anyManifestLoaded: enabledAddons.contains { $0.manifest != nil },
                searchOptionCount: searchOptionKeys.count,
                disabledOptionCount: searchOptionKeys.filter { disabled.contains($0) }.count,
                query: state.query ?? activeQuery ?? "",
                errorMessage: state.errorMessage
            )
        }
        if emptyState != resolved { emptyState = resolved }
    }

    // MARK: - Device-local settings

    /// Re-read the rows mode and the Discover placement (both device-local defaults), and the
    /// empty state (Search Sources switches live in defaults too).
    private func refreshDefaults() {
        let mode = SearchRowsMode.current()
        if mode != rowsMode {
            rowsMode = mode
            rederiveRows()
        }
        refreshPlacement()
        refreshEmptyState()
    }

    private func refreshPlacement() {
        let placement = DiscoverPlacement.current()
        if placement != discoverPlacement { discoverPlacement = placement }
    }

    /// B2 mode switch mid-hold: drop the hold and redraw the last accepted emission in the new
    /// mode. No network: both layouts come from the same state.
    private func rederiveRows() {
        rowsHold.reset()
        cancelHoldTick()
        guard let state = lastSearchState, !isStale(state) else {
            rows = []
            adoptExtras(from: nil)
            refreshEmptyState()
            return
        }
        rows = SearchResultsAdapter.rows(from: state, mode: rowsMode)
        adoptExtras(from: state)
        isLoading = state.isLoading || (state.peopleLoading && rows.isEmpty)
        refreshEmptyState()
    }

    // MARK: - "Found in"

    /// B3 f: the caption under a focused grouped-row card, "Found in Cinemeta and Torrentio"
    /// (locale list join). Shown even for a single source; nil when unknown (per-add-on mode).
    func foundInCaption(for item: MetaPreview) -> String? {
        guard let names = foundIn[item.stableKey()], !names.isEmpty else { return nil }
        let joined = ListFormatter.localizedString(byJoining: names)
        return String(localized: "Found in \(joined)")
    }

    // MARK: - Rows hold (S1 W1)

    /// How the rows on screen relate to the search now loading (`SearchRowsHold.relation`): by
    /// request id, with the query labels as the fallback for a re-search of the same query.
    private func holdRelation(incoming: [HomeCatalogSection]) -> SearchRowsHold.Relation {
        SearchRowsHold.relation(
            shownRequestId: rows.isEmpty ? nil : shownRequestId,
            activeRequestId: activeRequestId,
            shownKeys: rows.map(\.key),
            incomingKeys: incoming.map(\.key),
            shownQuery: rows.isEmpty ? nil : shownQuery,
            activeQuery: activeQuery
        )
    }

    /// The query a set of per-add-on result rows was searched with, read off the rows themselves
    /// (review r3 P2-1): every search section's See All target carries the exact query (BUG-48).
    /// Nil when unknown or mixed. B2: the fallback label for an emission without `query`.
    static func searchedQuery(of sections: [HomeCatalogSection]) -> String? {
        var query: String?
        for section in sections {
            guard let searched = (section.target as? CatalogTargetAddon)?.search else { return nil }
            if let query, query != searched { return nil }
            query = searched
        }
        return query
    }

    /// The debounce started a new search: tell the hold now rather than wait for the repository's
    /// start state, which may never be seen (review r3 P3-1, r5 P2-1; `SearchRowsHold.searchStarted`).
    private func holdSearchStarted() {
        let incoming = lastSearchState.map { SearchResultsAdapter.rows(from: $0, mode: rowsMode) } ?? []
        rowsHold.searchStarted(
            relation: holdRelation(incoming: incoming),
            hasRows: !rows.isEmpty,
            now: ProcessInfo.processInfo.systemUptime
        )
        scheduleHoldTick()
    }

    /// A hold must end on time even when the repository emits nothing more (review r1 P2-1): a
    /// catalog with no matches emits nothing, so after the fast add-ons answer, a slow one could
    /// keep the previous query's rows up until its 60 s timeout.
    private func scheduleHoldTick() {
        guard let deadline = rowsHold.holdDeadline else {
            cancelHoldTick()
            return
        }
        guard deadline != scheduledHoldDeadline else { return }
        scheduledHoldDeadline = deadline
        holdTickGeneration &+= 1
        let generation = holdTickGeneration
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.holdTickGeneration, !self.stopped,
                  let state = self.lastSearchState else { return }
            self.scheduledHoldDeadline = nil
            let now = ProcessInfo.processInfo.systemUptime
            // The last accepted emission can predate the active search when its start state was
            // never seen: never release to the previous search's rows (review r4 P2-1), and that
            // search is still loading as far as anything here knows ("Searching…").
            let stale = self.isStale(state)
            let incoming = stale ? [] : SearchResultsAdapter.rows(from: state, mode: self.rowsMode)
            let loading = stale || state.isLoading
            if let released = self.rowsHold.tick(
                lastIncoming: incoming,
                isLoading: loading,
                now: now,
                relation: self.holdRelation(incoming: incoming)
            ) {
                self.rows = released
                self.adoptExtras(from: stale ? nil : state)
                if stale { self.isLoading = true }
                self.refreshEmptyState()
            } else if let pending = self.rowsHold.holdDeadline, now < pending {
                // Fired before its deadline (review r2 P3-4): reschedule while it is still ahead.
                self.scheduleHoldTick()
            }
        }
    }

    private func cancelHoldTick() {
        holdTickGeneration &+= 1
        scheduledHoldDeadline = nil
    }

    /// Called as the search text changes; debounces, then queries (or resets on empty).
    func queryChanged(_ text: String) {
        debounce?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            // `.reset()` is the nuclear account/profile-teardown variant (it also wipes the
            // Discover sources). Use `.clear()`, which only resets search state. (BUG-33(2))
            SearchRepository.shared.clear()
            rowsHold.reset()
            cancelHoldTick()
            activeQuery = nil
            activeRequestId = nil
            rows = []
            adoptExtras(from: nil)
            emptyState = nil
            return
        }

        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.activeQuery = trimmed
            self.lastSearchAddonSignature = self.addonManifestSignature
            self.activeRequestId = SearchRepository.shared.search(
                query: trimmed,
                addons: self.enabledAddons,
                // FEAT-10: sources switched off in Settings → Content Sources → Search
                // Sources. Read fresh per query so a settings change applies immediately.
                disabledCatalogKeys: Self.SearchSourceSettings.disabledKeys,
                forceRefresh: false
            )
            self.holdSearchStarted()
            self.refreshSuggestions()
            self.refreshEmptyState()
        }
    }

    // MARK: - Search history

    /// Record a committed query (keyboard submit), so partial typing doesn't pollute history.
    func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SearchHistoryRepository.shared.recordSearch(query: trimmed)
    }

    func removeHistory(_ query: String) {
        SearchHistoryRepository.shared.removeSearch(query: query)
    }

    // MARK: - Add-on manifests

    /// Per-addon manifest-load state, not just the URL set: a manifest landing or failing changes
    /// nothing about `manifestUrl` (upstream 085e8dc6, #1819). Only flips when
    /// `manifest`/`isRefreshing` change, so a normal launch with cached manifests dedupes.
    private var addonManifestSignature: String {
        enabledAddons
            .map { "\($0.manifestUrl)|\($0.manifest != nil ? 1 : 0)|\($0.isRefreshing ? 1 : 0)" }
            .sorted()
            .joined(separator: ",")
    }

    /// Retry for `SearchEmptyState.manifestFailure`: re-fetch the manifests (the addon watcher
    /// re-issues the active search when they land). With manifests already loaded (every catalog
    /// request failed, review r1 P3-1) the manifests may not change at all, so the query is also
    /// searched again now, past the repository's same-request dedup and the HTTP cache.
    func retrySearch() {
        AddonRepository.shared.refreshAll()
        guard let activeQuery, enabledAddons.contains(where: { $0.manifest != nil }) else { return }
        activeRequestId = SearchRepository.shared.search(
            query: activeQuery,
            addons: enabledAddons,
            disabledCatalogKeys: Self.SearchSourceSettings.disabledKeys,
            forceRefresh: true
        )
        holdSearchStarted()
    }

    /// Re-issue the active search when an enabled addon's manifest state changes. The repository
    /// keys requests on the pending flag + catalog set, so an unchanged fan-out is a no-op there
    /// (and returns the live request id).
    private func researchIfAddonsChanged() {
        guard let activeQuery else { return }
        let signature = addonManifestSignature
        guard signature != lastSearchAddonSignature else { return }
        lastSearchAddonSignature = signature
        activeRequestId = SearchRepository.shared.search(
            query: activeQuery,
            addons: enabledAddons,
            disabledCatalogKeys: Self.SearchSourceSettings.disabledKeys,
            forceRefresh: false
        )
        holdSearchStarted()
    }

    deinit {
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
        historyWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
        defaultsObserver?.cancel()
    }
}
