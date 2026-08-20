import Combine
import Foundation
import SharedCore

/// Orchestrates the Home/Catalog screen end-to-end on top of SharedCore.
///
/// Pipeline (all shared Kotlin):
///   1. `AddonRepository.initialize()` loads any persisted addons (NSUserDefaults-backed on tvOS).
///   2. If none are installed yet, seed the default Cinemeta catalog addon so the screen has content.
///   3. Whenever the installed-addon set changes, push the enabled addons (those with a loaded
///      manifest) into `HomeRepository.refresh(...)`.
///   4. `HomeRepository.uiState` emits the assembled catalog sections, which we republish for SwiftUI.
///
/// Both flows are observed through the hand-written `FlowWatcher` bridge (no SKIE / kmp-nativecoroutines).
/// One Home row: either an addon catalog section or a collection (folder tiles). Interleaved per
/// the user's Home Rows settings order (`HomeCatalogSettingsItem`, collections keyed
/// `collection_<id>`), mirroring mobile's Home composition.
enum HomeRow: Identifiable {
    case catalog(HomeCatalogSection)
    case collection(NuvioCollection)

    var id: String {
        switch self {
        case .catalog(let section): return section.key
        case .collection(let collection): return "collection_\(collection.id)"
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var heroItems: [MetaPreview] = []
    @Published private(set) var sections: [HomeCatalogSection] = []
    @Published private(set) var rows: [HomeRow] = []
    @Published private(set) var continueWatching: [WatchProgressEntry] = []
    /// Home "Upcoming" row: next airing episode per followed show (shared
    /// `UpcomingEpisodesRepository`). Empty while the row is disabled or nothing is airing.
    @Published private(set) var upcoming: [UpcomingEpisodeItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    /// Stremio's default community catalog addon — gives the tvOS build real content out of the box.
    private let cinemetaManifestUrl = "https://v3-cinemeta.strem.io/manifest.json"

    private var addonWatcher: FlowWatcher?
    private var homeWatcher: FlowWatcher?
    private var progressWatcher: FlowWatcher?
    private var upcomingWatcher: FlowWatcher?
    private var collectionsWatcher: FlowWatcher?
    private var catalogSettingsWatcher: FlowWatcher?
    private var collections: [NuvioCollection] = []
    private var settingsItems: [HomeCatalogSettingsItem] = []
    private var didSeed = false
    /// Guards against redundant `refresh` calls — only re-refresh when the ready-addon set changes.
    private var lastRefreshSignature = ""
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        // Home output → SwiftUI.
        homeWatcher = FlowWatcherKt.watch(HomeRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? HomeUiState else { return }
            self.isLoading = state.isLoading
            // BUG-42 (beta.13): release-safe hero commit probe — one line per hero-bearing publish,
            // naming the head so a device log shows whether it ever moved after first paint.
            if HomeHeroProbe.enabled, state.heroItems.isEmpty, !self.heroItems.isEmpty {
                // An A → empty → B sequence must not hide the A→B change from the probe.
                NSLog("[HomeHero] publish n=0 (hero emptied) %@ sinceLaunch=%dms", HomeRepository.shared.heroRankingDebug, HomeHeroProbe.sinceLaunchMs)
            }
            if HomeHeroProbe.enabled, !state.heroItems.isEmpty {
                let head = state.heroItems.first.map { "\($0.type):\($0.id)" } ?? "-"
                let previousHead = self.lastNonEmptyHeroHead
                let headChanged = previousHead != nil && previousHead != head
                self.lastNonEmptyHeroHead = head
                // `inRows` = the head is one of the published catalog items (catalog hero) vs not
                // (collection-fallback hero) — tells the two hero sources apart in a log pull.
                let headItem = state.heroItems.first
                let inRows = state.sections.contains { section in
                    section.items.contains { $0.type == headItem?.type && $0.id == headItem?.id }
                }
                let ids = state.heroItems.map { "\($0.type):\($0.id)" }.joined(separator: ",")
                NSLog("[HomeHero] publish n=%d head=%@ headChanged=%d inRows=%d sections=%d loading=%d %@ sinceLaunch=%dms ids=%@",
                      state.heroItems.count, head, headChanged ? 1 : 0, inRows ? 1 : 0, state.sections.count,
                      state.isLoading ? 1 : 0, HomeRepository.shared.heroRankingDebug, HomeHeroProbe.sinceLaunchMs, ids)
            }
            self.heroItems = state.heroItems
            self.sections = state.sections
            self.errorMessage = state.errorMessage
            // BUG-42 moved the hero's metadata commit BEHIND TMDB enrichment (held in
            // HomeRepository, capped at HERO_ENRICHMENT_HOLD_TIMEOUT_MS), so hero first paint is no
            // longer implied by `first_rows` — it needs its own milestone to stay measurable
            // against the BUG-26 baseline. Rows are unaffected: they publish on the same pass.
            // beta.13: also emitted on release builds behind `debug.homeHeroProbe`, so the check
            // this row prescribed three times can finally run on the reporter's build class.
            if !self.didTraceFirstHero, !state.heroItems.isEmpty {
                self.didTraceFirstHero = true
                #if DEBUG
                LaunchTrace.mark("first_hero n=\(state.heroItems.count)")
                #else
                if HomeHeroProbe.enabled { NSLog("[HomeHero] first_hero n=%d sinceLaunch=%dms", state.heroItems.count, HomeHeroProbe.sinceLaunchMs) }
                #endif
            }
            self.rebuildRows()
        }

        // Collections (synced from the cloud / curated on mobile) → folder-tile rows. Registering
        // them with HomeCatalogSettingsRepository (like mobile's HomeScreen does) lets the Home Rows
        // settings order/enable them alongside addon catalogs.
        collectionsWatcher = FlowWatcherKt.watch(CollectionRepository.shared.collections) { [weak self] emitted in
            guard let self, let collections = emitted as? [NuvioCollection] else { return }
            self.collections = collections.filter { !$0.folders.isEmpty }
            HomeCatalogSettingsRepository.shared.syncCollections(collections: collections)
            self.rebuildRows()
        }
        catalogSettingsWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? HomeCatalogSettingsUiState else { return }
            self.settingsItems = state.items
            self.rebuildRows()
        }

        // Installed addons → drive Home refresh.
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            self.onAddonsChanged(state)
        }

        // Watch progress → Continue Watching row.
        progressWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.uiState) { [weak self] _ in
            guard let self else { return }
            self.continueWatching = WatchProgressRepository.shared.continueWatching()
        }

        AddonRepository.shared.initialize()
        WatchProgressRepository.shared.ensureLoaded()
        CollectionRepository.shared.initialize()
        #if DEBUG
        applyCollectionsSeedIfRequested()
        #endif
    }

    #if DEBUG
    /// Sim-only knob for headless UI tests of the TMDB filter editor (`TmdbFilterEditorView`):
    /// launch with `-debug.collectionsSeedJsonB64 '<base64 of json>'` (an exported-collections
    /// JSON array, same shape as `CollectionRepository.exportToJson()`; base64 because the
    /// launch-argument domain of NSUserDefaults parses bracket/brace-led values as old-style
    /// plists and drops raw JSON) — `-debug.collectionsSeedJson` with raw JSON is accepted too
    /// for hand use. The payload is imported ONCE per launch, right after
    /// `CollectionRepository.initialize()`, so a folder with a tmdb DISCOVER source exists without
    /// a signed-in account. In a signed-in session the next foreground pull may overwrite it
    /// (remote wins) — use in guest mode. Invalid JSON is rejected by the shared `validateJson`
    /// (logged, nothing imported).
    private static var didApplyCollectionsSeed = false
    private func applyCollectionsSeedIfRequested() {
        guard !Self.didApplyCollectionsSeed else { return }
        let defaults = UserDefaults.standard
        var seed = defaults.string(forKey: "debug.collectionsSeedJson") ?? ""
        if seed.isEmpty, let b64 = defaults.string(forKey: "debug.collectionsSeedJsonB64"), !b64.isEmpty {
            seed = Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if seed.isEmpty { NSLog("[CollectionsSeed] imported=false error=base64 payload did not decode") }
        }
        guard !seed.isEmpty else { return }
        let json = seed
        Self.didApplyCollectionsSeed = true
        let validation = CollectionRepository.shared.validateJson(jsonString: json)
        guard validation.valid else {
            NSLog("[CollectionsSeed] imported=false error=%@", validation.error ?? "invalid JSON")
            return
        }
        // Kotlin `Result<List<Collection>>` crosses the bridge as the unboxed value: the array on
        // success, an opaque failure object otherwise (never throws — runCatching inside).
        let result = CollectionRepository.shared.importFromJson(jsonString: json)
        if let imported = result as? [NuvioCollection] {
            NSLog("[CollectionsSeed] imported=true collections=%d folders=%d", imported.count, imported.reduce(0) { $0 + $1.folders.count })
        } else {
            NSLog("[CollectionsSeed] imported=false result=%@", String(describing: result))
        }
    }
    #endif

    func stop() {
        addonWatcher?.cancel()
        homeWatcher?.cancel()
        progressWatcher?.cancel()
        collectionsWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
        addonWatcher = nil
        homeWatcher = nil
        progressWatcher = nil
        collectionsWatcher = nil
        catalogSettingsWatcher = nil
        stopUpcoming()
        started = false
    }

    /// Upcoming row (gated by the `home_upcoming_row_enabled` toggle, so it is started separately
    /// from `start()`). Idempotent; re-entering Home also nudges a cheap refresh so a calendar
    /// rollover while the app sat in the background re-labels TODAY / TOMORROW.
    func startUpcoming() {
        if upcomingWatcher == nil {
            upcomingWatcher = FlowWatcherKt.watch(UpcomingEpisodesRepository.shared.uiState) { [weak self] emitted in
                guard let self, let state = emitted as? UpcomingEpisodesUiState else { return }
                self.upcoming = state.items
            }
            UpcomingEpisodesRepository.shared.ensureStarted()
        } else {
            UpcomingEpisodesRepository.shared.refresh(force: false)
        }
    }

    /// Tears the sweep down too (not just the Swift watcher) — off means no library/progress
    /// observation and no metadata fetches, which is what the Settings row promises.
    func stopUpcoming() {
        upcomingWatcher?.cancel()
        upcomingWatcher = nil
        UpcomingEpisodesRepository.shared.stop()
        upcoming = []
    }

    /// Interleaves catalog sections and collection rows per the Home Rows settings order (enabled
    /// items only), mirroring mobile's Home composition. Anything the settings don't know about yet
    /// (fresh install, settings sync lag) is appended in its natural order so nothing disappears.
    private func rebuildRows() {
        var built: [HomeRow] = []
        var usedSectionKeys = Set<String>()
        var usedCollectionIds = Set<String>()
        // First-wins dedup instead of `uniqueKeysWithValues`, which TRAPS on duplicates — the
        // shared module tolerates duplicate ids/keys in the wild (see
        // `visibleCollectionsWithUniqueIds` in HomeCatalogSettingsRepository.kt), so tvOS must too.
        let sectionsByKey = Dictionary(sections.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let collectionsById = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for item in settingsItems {
            if item.isCollection {
                guard let id = item.collectionId else { continue }
                usedCollectionIds.insert(id)
                guard item.enabled, let collection = collectionsById[id] else { continue }
                built.append(.collection(collection))
            } else {
                usedSectionKeys.insert(item.key)
                guard item.enabled, let section = sectionsByKey[item.key] else { continue }
                built.append(.catalog(section))
            }
        }

        // Anything settings don't know about yet keeps rendering (disabled items were marked
        // "used" above, so they stay hidden).
        for section in sections where !usedSectionKeys.contains(section.key) {
            built.append(.catalog(section))
        }
        for collection in collections where !usedCollectionIds.contains(collection.id) {
            built.append(.collection(collection))
        }

        rows = built

        #if DEBUG
        // BUG-26: time-to-content milestones. First non-empty rows = the KMP fetch layer has
        // delivered; subsequent count growth shows the fan-out filling in.
        if !built.isEmpty {
            if !didTraceFirstRows {
                didTraceFirstRows = true
                LaunchTrace.mark("first_rows n=\(built.count) hero=\(heroItems.count)")
            } else if built.count != lastTracedRowCount {
                LaunchTrace.mark("rows n=\(built.count)")
            }
            lastTracedRowCount = built.count
        }
        #endif
    }

    /// BUG-42 (beta.13): outside `#if DEBUG` — the first-hero milestone is also emitted on release
    /// builds behind `debug.homeHeroProbe`.
    private var didTraceFirstHero = false
    /// BUG-42 probe: last non-empty head, so a change through an empty intermediate still logs.
    private var lastNonEmptyHeroHead: String?
    #if DEBUG
    private var didTraceFirstRows = false
    private var lastTracedRowCount = 0
    #endif

    private func onAddonsChanged(_ state: AddonsUiState) {
        // First run with an empty store → seed Cinemeta, then wait for the next emission.
        if state.addons.isEmpty {
            if !didSeed {
                didSeed = true
                AddonRepository.shared.addAddon(rawUrl: cinemetaManifestUrl) { _, _ in }
            }
            return
        }

        // Only addons whose manifest has actually loaded can contribute catalogs.
        let ready = AddonModelsKt.enabledAddons(state.addons).filter { $0.manifest != nil }
        guard !ready.isEmpty else { return }

        let signature = ready.map { $0.manifestUrl }.joined(separator: "|")
        guard signature != lastRefreshSignature else { return }
        lastRefreshSignature = signature

        // BUG-12: register the catalog definitions with the Home Rows settings BEFORE refreshing,
        // mirroring mobile (HomeScreen.kt:538-541). Without this, `settingsItems` only ever knows
        // collections on the Home path (tvOS previously synced catalogs solely from Settings'
        // onAppear), so rebuildRows() forced every collection row above every catalog row until
        // the user happened to open Settings — the "collections are scrambled" report.
        if HomeHeroProbe.enabled {
            let catalogs = ready.reduce(0) { $0 + ($1.manifest?.catalogs.count ?? 0) }
            NSLog("[HomeHero] addonsChanged ready=%d catalogs=%d sinceLaunch=%dms", ready.count, catalogs, HomeHeroProbe.sinceLaunchMs)
        }
        HomeCatalogSettingsRepository.shared.syncCatalogs(addons: ready)
        HomeRepository.shared.refresh(addons: ready, force: true)
    }

    /// BUG-35 (beta.12): a catalog row scrolled into view — ask the shared repo to localize its
    /// leading items (bounded, session-deduped; see `HomeRepository.requestRowEnrichment`).
    func rowAppeared(sectionKey: String) {
        HomeRepository.shared.requestRowEnrichment(sectionKey: sectionKey)
    }

    deinit {
        addonWatcher?.cancel()
        homeWatcher?.cancel()
        upcomingWatcher?.cancel()
    }
}
