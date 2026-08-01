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
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    /// Stremio's default community catalog addon — gives the tvOS build real content out of the box.
    private let cinemetaManifestUrl = "https://v3-cinemeta.strem.io/manifest.json"

    private var addonWatcher: FlowWatcher?
    private var homeWatcher: FlowWatcher?
    private var progressWatcher: FlowWatcher?
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
            self.heroItems = state.heroItems
            self.sections = state.sections
            self.errorMessage = state.errorMessage
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
    }

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
        started = false
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
        HomeCatalogSettingsRepository.shared.syncCatalogs(addons: ready)
        HomeRepository.shared.refresh(addons: ready, force: true)
    }

    deinit {
        addonWatcher?.cancel()
        homeWatcher?.cancel()
    }
}
