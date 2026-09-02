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
    /// Upstream 085e8dc6 (#1819): every enabled add-on's manifest failed to load and nothing is
    /// still fetching. Distinct from `errorMessage` (HomeRepository's catalog error), which can
    /// never fire here — HomeRepository is only refreshed once a manifest is ready — so without
    /// this Home sat on "Setting up your catalogs…" forever with no error and no retry.
    @Published private(set) var addonManifestError: String?

    /// H-1A (beta.15): a per-instance id from the shared hero probe counter, stamped into every
    /// probe line this view model logs (`vm=<n>`). A profile-scoped sync pull flipping the theme
    /// can `.id(appTheme.themeName)`-remount `ContentView` minutes after cold launch, which spins
    /// up a SECOND `HomeViewModel` while the first is still tearing down — without this stamp the
    /// two instances' publish lines interleave in the probe log under one identity and read as one
    /// view model publishing twice. See `AppThemeModel`'s guarded theme assignment for the actual
    /// fix; this id is purely diagnostic.
    let vmId = HomeHeroProbe.newInstanceId()

    /// Stremio's default community catalog addon — gives the tvOS build real content out of the box.
    private let cinemetaManifestUrl = "https://v3-cinemeta.strem.io/manifest.json"

    private var addonWatcher: FlowWatcher?
    /// Addon-wipe guard (2026-08-28): watches `AddonRepository.serverPullSettled` so a gated seed
    /// (see `maybeSeedDefaultAddon()`) gets retried once the signed-in account's first pull lands.
    private var seedGateWatcher: FlowWatcher?
    private var homeWatcher: FlowWatcher?
    private var progressWatcher: FlowWatcher?
    private var progressSourceWatcher: FlowWatcher?
    private var traktSettingsWatcher: FlowWatcher?
    /// Last Trakt continue-watching days cap the row was built with; `nil` until the settings
    /// watcher's replay lands. Profile-scoped — cleared with the watchers in `teardownPipeline()`.
    private var lastTraktContinueWatchingDaysCap: Int32?
    private var upcomingWatcher: FlowWatcher?
    private var collectionsWatcher: FlowWatcher?
    private var catalogSettingsWatcher: FlowWatcher?
    private var collections: [NuvioCollection] = []
    private var settingsItems: [HomeCatalogSettingsItem] = []
    private var didSeed = false
    /// Guards against redundant `refresh` calls — only re-refresh when the ready-addon set changes.
    private var lastRefreshSignature = ""
    /// True exactly while the watcher pipeline below is live (0→1 acquired … 1→0 released).
    private var started = false
    /// H-1B-ii (beta.15): how many views currently hold this model. See `acquire()`.
    private var retainCount = 0
    /// H-1B-ii: releases still OWED by views that were unmounted out from under a hard `stop()`.
    /// A hard stop discards the whole retain count, but the views that contributed to it still run
    /// their `onDisappear → release()` afterwards; those releases are expected, not underflow, so
    /// they are absorbed here instead of tripping the DEBUG assertion.
    private var hardStopAbsorb = 0
    /// Codex wave-4 r3 (P1): `FlowWatcher.cancel()` is cooperative — a delivery already queued when
    /// the pipeline tears down can still run AFTER `stop()` cleared the profile-scoped state, and
    /// on a model that now outlives the profile that means the PREVIOUS profile's data repopulating
    /// Home (the collections callback would even `syncCollections` the old definitions under the
    /// new profile). Every watcher closure captures the generation current at registration and
    /// bails when it no longer matches; both teardown and each restart bump it, so late deliveries
    /// from an earlier pipeline are inert forever.
    private var pipelineGeneration = 0

    // MARK: - Lifecycle
    //
    // H-1B-ii (beta.15): this model is owned by `ContentView` — ABOVE the `.id(appTheme.themeName)`
    // rebuild boundary — not by `HomeView`. A profile-scoped sync pull that flips the theme minutes
    // after launch re-identifies the whole tree, and when `HomeView` owned the model via
    // `@StateObject` that meant: a brand-new `HomeViewModel`, a replayed StateFlow publish
    // (duplicate hero head), `lastRefreshSignature == ""` → a second forced full
    // `HomeRepository.refresh`, and two hero paint pipelines alive across the swap (the tester's
    // "doubled hero"). The data now outlives view identity, so the swap is invisible to the
    // pipeline — but only if the hand-off is REFCOUNTED:
    //
    //   SwiftUI inserts the incoming subtree BEFORE removing the outgoing one, so the new
    //   `HomeView.onAppear` runs BEFORE the old `HomeView.onDisappear`. A naive hoist that kept
    //   plain start()/stop() would therefore tear the watchers down immediately AFTER the new view
    //   had already started them, leaving Home permanently dead. With a refcount the sequence is
    //   1 → 2 → 1: no teardown, no restart, nothing republished.
    //
    // Normal steady state is 0 or 1: `HomeView.onDisappear` effectively only fires on shell
    // teardown (neither a Detail push nor a tab switch fires it — see `HomeHeroBackdrop`), so the
    // count only ever transiently reaches 2 during a theme `.id()` swap.

    /// Balanced retain. Runs the pipeline exactly once on 0→1; every later holder just bumps the
    /// count. Every `acquire()` MUST be paired with a `release()` (or subsumed by `stop()`).
    func acquire() {
        retainCount += 1
        if HomeHeroProbe.enabled {
            // H-1A's probe intent, adapted: the old unconditional entry log existed so a redundant
            // `start()` — the shape a duplicate-instance bug produced — still left a trace. Under
            // refcounting a second holder is legitimate, so retain traffic gets its OWN line and
            // `vm start`/`vm stop` keep meaning "the pipeline actually started/stopped".
            HomeHeroProbe.log(String(format: "vm acquire id=%d rc=%d sinceLaunch=%dms", vmId, retainCount, HomeHeroProbe.sinceLaunchMs))
        }
        guard retainCount == 1 else { return }
        startPipeline()
    }

    /// Balanced release. Tears the pipeline down only on 1→0. Underflow clamps at zero — and in
    /// DEBUG asserts, unless it is a release owed to a preceding hard `stop()` (see
    /// `hardStopAbsorb`); a release build must never crash on an unbalanced release.
    func release() {
        // Absorbed FIRST, before the count is touched: a hard `stop()` already discarded the
        // retains these releases balance, so they must not decrement anything — the arrival of
        // `onDisappear` is not ordered against a later re-entry. (Profile exit → hard stop →
        // re-enter a profile → the NEW HomeView's `acquire()` can land before the OLD view's
        // `onDisappear`; decrementing there would tear down the pipeline the new view just
        // started, leaving Home permanently empty.) Worst case this leaks a retain, which the
        // next hard stop clears — strictly preferable to a premature teardown.
        if hardStopAbsorb > 0 {
            hardStopAbsorb -= 1
            if HomeHeroProbe.enabled {
                HomeHeroProbe.log(String(format: "vm release id=%d rc=%d (post-hard-stop, absorbed) sinceLaunch=%dms", vmId, retainCount, HomeHeroProbe.sinceLaunchMs))
            }
            return
        }
        guard retainCount > 0 else {
            // Genuine underflow: an unpaired release with no hard stop to explain it. Clamp (a
            // release build must never crash here) and shout in DEBUG.
            #if DEBUG
            assertionFailure("HomeViewModel.release() underflow — an unpaired release() (vm=\(vmId))")
            #endif
            retainCount = 0
            if HomeHeroProbe.enabled {
                HomeHeroProbe.log(String(format: "vm release id=%d rc=0 (underflow clamped) sinceLaunch=%dms", vmId, HomeHeroProbe.sinceLaunchMs))
            }
            return
        }
        retainCount -= 1
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "vm release id=%d rc=%d sinceLaunch=%dms", vmId, retainCount, HomeHeroProbe.sinceLaunchMs))
        }
        guard retainCount == 0 else { return }
        teardownPipeline()
    }

    /// Hard teardown, regardless of who still holds the model. Used on profile switch / sign-out:
    /// everything below is PROFILE-SCOPED (the shared repositories are re-scoped by
    /// `ActiveProfileProvider`), and now that the model outlives `HomeView` the old implicit
    /// "the view went away, so the watchers went away" teardown no longer happens on its own.
    /// The outstanding retains are remembered in `hardStopAbsorb` so the unmounting views'
    /// `release()` calls don't read as underflow.
    func stop() {
        hardStopAbsorb += retainCount
        retainCount = 0
        teardownPipeline()
        // Codex wave-4 (P1): these two guards are PROFILE-SCOPED state on a model that now
        // outlives the profile. Without the reset, switching to a profile whose ready-addon URLs
        // happen to match the previous profile's would hit the `signature != lastRefreshSignature`
        // equality guard and skip the one forced Home refresh that repopulates the cleared
        // `HomeRepository` — leaving Home empty; `didSeed` would likewise block Cinemeta seeding
        // for a newly selected empty profile.
        lastRefreshSignature = ""
        didSeed = false
        // Codex wave-4 r2 (P1): the published content and internal snapshots are profile-scoped
        // too. Left populated, the next profile's `HomeView` renders the PREVIOUS profile's hero,
        // rows, Continue Watching, and Upcoming until the freshly attached watchers replay —
        // profile data crossing the profile boundary. Same cascade rule as the account-data wipe
        // registry: in-memory account/profile-scoped state joins the teardown.
        heroItems = []
        sections = []
        rows = []
        continueWatching = []
        upcoming = []
        isLoading = false
        errorMessage = nil
        addonManifestError = nil
        collections = []
        settingsItems = []
        lastNonEmptyHeroHead = nil
    }

    private func startPipeline() {
        guard !started else { return }
        started = true
        pipelineGeneration += 1
        let gen = pipelineGeneration
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "vm start id=%d sinceLaunch=%dms", vmId, HomeHeroProbe.sinceLaunchMs))
        }

        // Home output → SwiftUI.
        homeWatcher = FlowWatcherKt.watch(HomeRepository.shared.uiState) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, let state = emitted as? HomeUiState else { return }
            self.isLoading = state.isLoading
            // BUG-42 (beta.13): release-safe hero commit probe — one line per hero-bearing publish,
            // naming the head so a device log shows whether it ever moved after first paint.
            if HomeHeroProbe.enabled, state.heroItems.isEmpty, !self.heroItems.isEmpty {
                // An A → empty → B sequence must not hide the A→B change from the probe.
                HomeHeroProbe.log(String(format: "publish vm=%d n=0 (hero emptied) %@ sinceLaunch=%dms", self.vmId, HomeRepository.shared.heroRankingDebug, HomeHeroProbe.sinceLaunchMs))
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
                HomeHeroProbe.log(String(format: "publish vm=%d n=%d head=%@ headChanged=%d inRows=%d sections=%d loading=%d %@ sinceLaunch=%dms ids=%@",
                      self.vmId, state.heroItems.count, head, headChanged ? 1 : 0, inRows ? 1 : 0, state.sections.count,
                      state.isLoading ? 1 : 0, HomeRepository.shared.heroRankingDebug, HomeHeroProbe.sinceLaunchMs, ids))
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
                if HomeHeroProbe.enabled { HomeHeroProbe.log(String(format: "first_hero n=%d sinceLaunch=%dms", state.heroItems.count, HomeHeroProbe.sinceLaunchMs)) }
                #endif
            }
            self.rebuildRows()
        }

        // Collections (synced from the cloud / curated on mobile) → folder-tile rows. Registering
        // them with HomeCatalogSettingsRepository (like mobile's HomeScreen does) lets the Home Rows
        // settings order/enable them alongside addon catalogs.
        collectionsWatcher = FlowWatcherKt.watch(CollectionRepository.shared.collections) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, let collections = emitted as? [NuvioCollection] else { return }
            self.collections = collections.filter { !$0.folders.isEmpty }
            HomeCatalogSettingsRepository.shared.syncCollections(collections: collections)
            self.rebuildRows()
        }
        catalogSettingsWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, let state = emitted as? HomeCatalogSettingsUiState else { return }
            self.settingsItems = state.items
            self.rebuildRows()
        }

        // Installed addons → drive Home refresh.
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen, let state = emitted as? AddonsUiState else { return }
            self.onAddonsChanged(state)
        }

        // Addon-wipe guard (2026-08-28): covers the signed-in fresh-account case. The addon list's
        // own empty-state emission is gated by `maybeSeedDefaultAddon()` while the first server pull
        // hasn't settled yet, so nothing re-evaluates the seed once that emission has already come
        // and gone — this watcher is what retries it: when the pull settles and the current addon
        // state is STILL empty (a genuinely empty account, not one whose addons just arrived), seed.
        seedGateWatcher = FlowWatcherKt.watch(AddonRepository.shared.serverPullSettled) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen else { return }
            let settled = (emitted as? KotlinBoolean)?.boolValue == true
            guard settled else { return }
            guard let state = AddonRepository.shared.uiState.value_ as? AddonsUiState, state.addons.isEmpty else { return }
            self.maybeSeedDefaultAddon()
        }

        // Watch progress → Continue Watching row.
        progressWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.uiState) { [weak self] _ in
            guard let self, self.pipelineGeneration == gen else { return }
            self.refreshContinueWatching()
        }

        // BUG-75: the row's two gates (the active provider's dropped-show filter and its recency
        // window) live OUTSIDE `uiState` — switching progress source or changing the Trakt
        // continue-watching days cap changes what the row should contain without touching a single
        // progress entry. Without these two watchers the row keeps the previous gates until the
        // next unrelated progress emission.
        progressSourceWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.activeSourceState) { [weak self] _ in
            guard let self, self.pipelineGeneration == gen else { return }
            self.refreshContinueWatching()
        }
        // `TraktSettingsUiState` also carries library/more-like-this preferences the row does not
        // read, so recompute only when the days cap actually moved — a republished row otherwise
        // re-renders (and can disturb focus) for a setting it does not depend on.
        traktSettingsWatcher = FlowWatcherKt.watch(TraktSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, self.pipelineGeneration == gen,
                  let state = emitted as? TraktSettingsUiState else { return }
            guard self.lastTraktContinueWatchingDaysCap != state.continueWatchingDaysCap else { return }
            self.lastTraktContinueWatchingDaysCap = state.continueWatchingDaysCap
            self.refreshContinueWatching()
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

    /// Rebuilds the Continue Watching row from the shared provider-aware builder. Called by every
    /// watcher that can change what the row contains: the progress entries themselves, the active
    /// progress source, and the Trakt continue-watching days cap.
    private func refreshContinueWatching() {
        continueWatching = WatchProgressRepository.shared.continueWatchingRow(
            limit: ContinueWatchingRowKt.ContinueWatchingRowScanLimit
        )
    }

    /// The real teardown. Idempotent (`started` gates it) so a hard `stop()` on an already-stopped
    /// model is a no-op and, crucially, does NOT emit a spurious `vm stop` probe line — those two
    /// lines keep meaning "the pipeline actually started/stopped", never "someone asked".
    private func teardownPipeline() {
        guard started else { return }
        // Codex wave-4 r3: bump BEFORE cancelling — `cancel()` is cooperative, and any delivery
        // already queued behind it must find the generation stale and bail (see
        // `pipelineGeneration`'s doc).
        pipelineGeneration += 1
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "vm stop id=%d sinceLaunch=%dms", vmId, HomeHeroProbe.sinceLaunchMs))
        }
        addonWatcher?.cancel()
        seedGateWatcher?.cancel()
        homeWatcher?.cancel()
        progressWatcher?.cancel()
        progressSourceWatcher?.cancel()
        traktSettingsWatcher?.cancel()
        collectionsWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
        addonWatcher = nil
        seedGateWatcher = nil
        homeWatcher = nil
        progressWatcher = nil
        progressSourceWatcher = nil
        traktSettingsWatcher = nil
        lastTraktContinueWatchingDaysCap = nil
        collectionsWatcher = nil
        catalogSettingsWatcher = nil
        stopUpcoming()
        started = false
    }

    /// Upcoming row (gated by the `home_upcoming_row_enabled` toggle, so it is started separately
    /// from the main pipeline — `HomeView.onAppear` calls it right after `acquire()` when the
    /// toggle is on, and it is NOT refcounted: it is idempotent both ways, and the pipeline
    /// teardown below stops it wholesale). Re-entering Home also nudges a cheap refresh so a calendar
    /// rollover while the app sat in the background re-labels TODAY / TOMORROW.
    func startUpcoming() {
        if upcomingWatcher == nil {
            // Same generation guard as the main pipeline's watchers (Codex wave-4 r3): a delivery
            // queued at teardown time must not repopulate `upcoming` after the profile-scoped clear.
            let gen = pipelineGeneration
            upcomingWatcher = FlowWatcherKt.watch(UpcomingEpisodesRepository.shared.uiState) { [weak self] emitted in
                guard let self, self.pipelineGeneration == gen, let state = emitted as? UpcomingEpisodesUiState else { return }
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

    /// Addon-wipe guard (2026-08-28, docs/addon-wipe-investigation-2026-08-28.md): the seed used to
    /// fire on the FIRST empty emission, which on a clean install + sign-in is before the account's
    /// addon list has ever been pulled — and addAddon's debounced full-replace push then overwrote
    /// the account's addons with just Cinemeta. Guests still seed immediately (nothing to pull);
    /// a signed-in account seeds only after the first pull settles (`seedingAllowed()`), with the
    /// `serverPullSettled` watcher below re-attempting once the pull lands on a still-empty list.
    private func maybeSeedDefaultAddon() {
        guard !didSeed else { return }
        guard AddonRepository.shared.seedingAllowed() else { return }
        didSeed = true
        AddonRepository.shared.addAddon(rawUrl: cinemetaManifestUrl) { _, _ in }
    }

    private func onAddonsChanged(_ state: AddonsUiState) {
        // First run with an empty store → seed Cinemeta, then wait for the next emission.
        if state.addons.isEmpty {
            addonManifestError = nil
            maybeSeedDefaultAddon()
            return
        }

        // Only addons whose manifest has actually loaded can contribute catalogs.
        let ready = AddonModelsKt.enabledAddons(state.addons).filter { $0.manifest != nil }
        // Terminal manifest failure with nothing ready and nothing still fetching → surface it.
        // Pending keeps the existing "Setting up your catalogs…" placeholder (already not a false
        // empty state); Retry re-marks the addons refreshing, which clears this again.
        addonManifestError = ready.isEmpty && !AddonModelsKt.hasPendingEnabledManifests(state.addons)
            ? AddonModelsKt.firstEnabledManifestError(state.addons)
            : nil
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
            HomeHeroProbe.log(String(format: "addonsChanged vm=%d ready=%d catalogs=%d sinceLaunch=%dms", vmId, ready.count, catalogs, HomeHeroProbe.sinceLaunchMs))
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
        seedGateWatcher?.cancel()
        homeWatcher?.cancel()
        upcomingWatcher?.cancel()
    }
}
