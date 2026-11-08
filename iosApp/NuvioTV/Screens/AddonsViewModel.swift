import Combine
import Foundation
import SharedCore

/// Manages installed addons: lists them, installs a new one by manifest URL, removes, and toggles
/// enabled. Backed by the shared `AddonRepository` (NSUserDefaults-persisted on tvOS).
@MainActor
final class AddonsViewModel: ObservableObject {

    /// Add-ons hub C, H1: the header counts: installed and active (enabled, whether or not its
    /// manifest has loaded, so the count does not dip while a manifest reloads). There is deliberately no catalog count here: `AddonOverview.totalCatalogs`
    /// counts every catalog of every enabled add-on including search-only ones, which is not what
    /// the hub shows; the Catalogs card reads `HubSummary.catalogsOn / catalogsTotal` (the Home items).
    nonisolated struct HubOverview: Equatable {
        var total: Int
        var active: Int
        static let empty = HubOverview(total: 0, active: 0)
    }

    /// Add-ons hub C, H1: the hub's summary line, composed from the five stores the hub draws on.
    /// `addonsOn` counts enabled add-ons, with or without a loaded manifest.
    nonisolated struct HubSummary: Equatable {
        let addonsInstalled: Int
        let addonsOn: Int
        let catalogsOn: Int
        let catalogsTotal: Int
        /// Display names of the connected debrid providers.
        let debridConnected: [String]
        /// nil = plugins are disabled or unavailable.
        let plugins: PluginSummary?
    }

    nonisolated struct PluginSummary: Equatable {
        let repositories: Int
        let providers: Int
    }

    /// What a finished refresh did: add-ons that loaded versus failed (error set, or gone).
    nonisolated struct RefreshOutcome: Equatable {
        let succeeded: Int
        let failed: Int
    }

    /// Review r1: a typed install result. The serial increments per outcome, so two identical
    /// outcomes in a row (the same failure twice) still compare unequal and fire `onChange`; the UI
    /// never has to read the localized `statusMessage` to know what happened.
    nonisolated enum InstallOutcome: Equatable {
        case installed(name: String, serial: Int)
        case failed(message: String, serial: Int)
    }

    /// Card state, in priority order: stalled, refreshing, unavailable, disabled, active.
    nonisolated enum AddonStatus: Equatable {
        case active, disabled, refreshing, unavailable
        /// A refresh that has run past `refreshStallSeconds` and is still going.
        case stalled
    }

    /// Add-ons hub v2 (A1): how long a refresh may run before its add-on reads as stalled.
    nonisolated static let refreshStallSeconds: TimeInterval = 30

    @Published private(set) var addons: [ManagedAddon] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var overview = HubOverview.empty
    @Published private(set) var isRefreshingAny = false
    /// When a refresh this model started last loaded at least one add-on. Persisted per profile
    /// (`refreshStampKey`) and reloaded by `start()`; a refresh the repository ran by itself never
    /// sets it.
    @Published private(set) var lastRefreshedAt: Date?
    /// Add-ons still refreshing after `refreshStallSeconds`; the hub offers a retry for these.
    /// Kept after `stop()`; entries leave when the add-on stops refreshing.
    @Published private(set) var stalledUrls: Set<String> = []
    @Published private(set) var lastRefreshOutcome: RefreshOutcome?
    /// Increments each time `lastRefreshOutcome` is published, so an identical outcome twice in a
    /// row still changes something the hub can observe.
    @Published private(set) var refreshOutcomeSerial = 0
    @Published private(set) var installOutcome: InstallOutcome?
    /// The normalized manifest URL of the last successful install, so the hub can focus that card.
    /// Cleared by `start()`.
    @Published private(set) var lastInstalledManifestUrl: String?
    private var installSerial = 0
    @Published private(set) var isInitialized = false
    @Published private(set) var isReadOnly = false

    private var watcher: FlowWatcher?
    private var refreshWait: Task<Void, Never>?
    /// One refresh request's age: its generation (`AddonsUiState.refreshGenerations`) and when this
    /// model first saw it refreshing.
    nonisolated struct RefreshAge: Equatable {
        let generation: Int64
        let startedAt: Date
    }

    /// The age of each add-on's current refresh request (review r2: repository-started refreshes
    /// too). Kept across `stop()`/`start()`; keyed by generation (review r5), so a NEW request for
    /// the same add-on starts its own age instead of inheriting an earlier one's.
    private var refreshStartedAt: [String: RefreshAge] = [:]
    /// Re-evaluates `stalledUrls` once a second while anything is refreshing.
    private var stallTicker: Task<Void, Never>?
    /// Between `start()` and `stop()`; the ticker only runs while started. (The watcher's first
    /// emission can arrive before `watcher` is assigned, so that cannot be the signal.)
    private var isStarted = false
    /// Who `lastRefreshedAt` belongs to: a profile slot plus that profile's stable id.
    nonisolated struct StampOwner: Equatable {
        let slot: Int32
        let identity: String
    }

    /// The owner of `lastRefreshedAt` (review r12/r13: a session-only stamp survives a stop/start of
    /// the SAME profile, matched by slot and stable id).
    private var stampOwner: StampOwner?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// UserDefaults key of the refresh stamp for `profileId`.
    nonisolated static func refreshStampKey(profileId: Int32) -> String {
        "addons.lastRefreshedAt.\(profileId)"
    }

    /// The stored refresh stamp for the profile in slot `profileId`, or nil when absent or written
    /// by ANOTHER profile that held the slot (review r10: slots are reused after a delete, here or
    /// on another device, so the stamp carries the profile's stable `id` and is ignored on a
    /// mismatch). Stored as `["at": seconds since 1970, "profile": id]`.
    nonisolated static func loadRefreshStamp(defaults: UserDefaults, profileId: Int32, profileIdentity: String) -> Date? {
        // Review r11: an empty id (guest and locally applied profiles) identifies nobody, so a
        // stamp is never trusted for it.
        guard !profileIdentity.isEmpty,
              let stored = defaults.dictionary(forKey: refreshStampKey(profileId: profileId)),
              let seconds = stored["at"] as? Double,
              (stored["profile"] as? String) == profileIdentity else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Stores `date` as the refresh stamp for slot `profileId`, tagged with the profile's `id`.
    /// Without a stable id (empty) nothing is persisted: the stamp then lives for the session only.
    nonisolated static func saveRefreshStamp(_ date: Date, defaults: UserDefaults, profileId: Int32, profileIdentity: String) {
        guard !profileIdentity.isEmpty else { return }
        defaults.set(["at": date.timeIntervalSince1970, "profile": profileIdentity],
                     forKey: refreshStampKey(profileId: profileId))
    }

    /// The stamp `start()` shows: the stored one when there is one; otherwise, for the SAME profile
    /// (slot AND stable id, review r13: a profile pulled into the slot is another profile), the
    /// in-memory stamp (review r12: a profile without a stable id keeps its session-only stamp
    /// across a stop/start); for anyone else, nothing.
    nonisolated static func stampOnStart(current: Date?, currentOwner: StampOwner?, owner: StampOwner, loaded: Date?) -> Date? {
        if let loaded { return loaded }
        return currentOwner == owner ? current : nil
    }

    /// The active profile's stable id (empty when there is none, e.g. before a profile is picked).
    private static var activeProfileIdentity: String {
        (ProfileRepository.shared.state.value_ as? ProfileState)?.activeProfile?.id ?? ""
    }

    /// The add-ons whose refresh started at least `ceiling` seconds before `now`.
    nonisolated static func stalledUrls(
        startedAt: [String: Date], now: Date, ceiling: TimeInterval = refreshStallSeconds
    ) -> Set<String> {
        Set(startedAt.filter { now.timeIntervalSince($0.value) >= ceiling }.keys)
    }

    /// Starts/forgets refresh ages from the live list (`refreshing`: URL → its refresh generation):
    /// a URL newly refreshing, or refreshing under a new generation, gets `now`; a URL no longer
    /// refreshing is dropped. Pure, so the bookkeeping is unit-tested.
    nonisolated static func updatedRefreshAges(
        _ ages: [String: RefreshAge], refreshing: [String: Int64], now: Date
    ) -> [String: RefreshAge] {
        var next: [String: RefreshAge] = [:]
        for (url, generation) in refreshing {
            if let age = ages[url], age.generation == generation {
                next[url] = age
            } else {
                next[url] = RefreshAge(generation: generation, startedAt: now)
            }
        }
        return next
    }

    /// URL → refresh generation for every add-on refreshing in `state`.
    private static func refreshingGenerations(_ state: AddonsUiState) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for addon in state.addons where addon.isRefreshing {
            result[addon.manifestUrl] = state.refreshGenerations[addon.manifestUrl]?.int64Value ?? 0
        }
        return result
    }

    private func reevaluateStalled() {
        let next = Self.stalledUrls(startedAt: refreshStartedAt.mapValues(\.startedAt), now: now())
        if next != stalledUrls { stalledUrls = next }
        if refreshStartedAt.isEmpty {
            stallTicker?.cancel()
            stallTicker = nil
        } else if stallTicker == nil, isStarted {
            stallTicker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.reevaluateStalled()
                    if self.stallTicker == nil { return }
                }
            }
        }
    }

    func start() {
        guard watcher == nil else { return }
        isStarted = true
        let owner = StampOwner(slot: ProfileRepository.shared.activeProfileId, identity: Self.activeProfileIdentity)
        lastRefreshedAt = Self.stampOnStart(
            current: lastRefreshedAt, currentOwner: stampOwner, owner: owner,
            loaded: Self.loadRefreshStamp(defaults: defaults, profileId: owner.slot, profileIdentity: owner.identity)
        )
        stampOwner = owner
        lastInstalledManifestUrl = nil
        let readOnly = AddonRepository.shared.isReadOnly()
        if isReadOnly != readOnly { isReadOnly = readOnly }
        watcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            if state.addons != self.addons { self.addons = state.addons }
            let overview = HubOverview(total: state.addons.count, active: state.addons.filter { $0.enabled }.count)
            if overview != self.overview { self.overview = overview }
            let refreshing = Self.refreshingGenerations(state)
            let ages = Self.updatedRefreshAges(self.refreshStartedAt, refreshing: refreshing, now: self.now())
            if ages != self.refreshStartedAt || !self.stalledUrls.isSubset(of: Set(refreshing.keys)) {
                self.refreshStartedAt = ages
                self.reevaluateStalled()
            }
            if self.isInitialized != state.isInitialized { self.isInitialized = state.isInitialized }
            let readOnly = AddonRepository.shared.isReadOnly()
            if self.isReadOnly != readOnly { self.isReadOnly = readOnly }
            // Spinner only; the "Updated" stamp comes from `refreshWait`, never from here.
            let anyRefreshing = state.addons.contains { $0.isRefreshing }
            // Review r2: while this model's own refresh wait runs, only IT clears the spinner (the
            // watcher can see the settled state up to 250 ms before the outcome is published).
            if anyRefreshing, !self.isRefreshingAny {
                self.isRefreshingAny = true
            } else if !anyRefreshing, self.isRefreshingAny, self.refreshWait == nil {
                self.isRefreshingAny = false
            }
        }
        AddonRepository.shared.initialize()
        // Resume ageing refreshes seen before a stop.
        reevaluateStalled()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        refreshWait?.cancel()
        refreshWait = nil
        stallTicker?.cancel()
        stallTicker = nil
        isStarted = false
        isRefreshingAny = false
    }

    func install(_ rawUrl: String) {
        let url: String
        do {
            url = try AddonManifestURL.normalize(rawUrl)
        } catch let failure as AddonManifestURL.Failure {
            // The typed throw is not inferred through a bare `catch` on this toolchain.
            switch failure {
            case .empty:
                return
            case .unsupportedScheme:
                publishInstallFailure(reason: String(localized: "Enter a valid addon URL (http or https)."))
                return
            }
        } catch {
            publishInstallFailure(reason: String(localized: "Enter a valid addon URL (http or https)."))
            return
        }
        if addons.contains(where: { AddonManifestURL.isSameManifest($0.manifestUrl, url) }) {
            publishInstallFailure(reason: String(localized: "That addon is already installed."))
            return
        }
        isInstalling = true
        statusMessage = nil

        AddonRepository.shared.addAddon(rawUrl: url) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.isInstalling = false
                if let error {
                    self.publishInstallFailure(reason: error.localizedDescription, status: String(localized: "Couldn't install: \(error.localizedDescription)"))
                } else if let failure = result as? AddAddonResultError {
                    self.publishInstallFailure(reason: failure.message, status: String(localized: "Couldn't install: \(failure.message)"))
                } else if let success = result as? AddAddonResultSuccess {
                    self.installSerial += 1
                    self.lastInstalledManifestUrl = url
                    self.statusMessage = String(localized: "Installed \(success.manifest.name).")
                    self.installOutcome = .installed(name: success.manifest.name, serial: self.installSerial)
                } else {
                    self.publishInstallFailure(reason: String(localized: "That URL did not answer with an add-on manifest."), status: String(localized: "Couldn't install that URL."))
                }
            }
        }
    }

    /// Sets the status line and the typed outcome together; the serial makes a repeat observable.
    /// The outcome carries the bare `reason` (the install sheet's modal titles it "Couldn't install
    /// that add-on." itself, in every language); the status line keeps its own prefixed wording.
    private func publishInstallFailure(reason: String, status: String? = nil) {
        installSerial += 1
        statusMessage = status ?? reason
        installOutcome = .failed(message: reason, serial: installSerial)
    }

    func remove(_ addon: ManagedAddon) {
        AddonRepository.shared.removeAddon(manifestUrl: addon.manifestUrl)
    }

    func setEnabled(_ addon: ManagedAddon, _ enabled: Bool) {
        AddonRepository.shared.setAddonEnabled(manifestUrl: addon.manifestUrl, enabled: enabled)
    }

    /// Hub C, H1: moves the add-on with `manifestUrl` up (`delta < 0`) or down; a move off either
    /// end is a no-op the UI disables rather than clamps. The index comes from the repository's
    /// CURRENT list, not this model's snapshot, so two quick presses never act on a stale index.
    func move(manifestUrl: String, by delta: Int) {
        let current = (AddonRepository.shared.uiState.value_ as? AddonsUiState)?.addons ?? []
        guard let index = current.firstIndex(where: { $0.manifestUrl == manifestUrl }),
              let target = Self.moveTarget(index: index, by: delta, count: current.count) else { return }
        AddonRepository.shared.moveAddon(fromIndex: Int32(index), toIndex: Int32(target))
    }

    /// A4 review r2: the repository's CURRENT order (manifest URLs), not this model's snapshot,
    /// which can lag a sync update still waiting for the main-thread watcher.
    func liveOrder() -> [String] {
        ((AddonRepository.shared.uiState.value_ as? AddonsUiState)?.addons ?? []).map(\.manifestUrl)
    }

    /// A4 review r3: one place up or down, resolved by URL inside the repository's state update.
    @discardableResult
    func moveStep(manifestUrl: String, by delta: Int) -> Bool {
        AddonRepository.shared.moveAddonStep(manifestUrl: manifestUrl, delta: Int32(delta))
    }

    /// A4 review r3: back right after the surviving `predecessors`, resolved inside the
    /// repository's state update (Move mode's cancel).
    func restore(manifestUrl: String, after predecessors: Set<String>) {
        AddonRepository.shared.moveAddonAfter(manifestUrl: manifestUrl, predecessors: predecessors)
    }

    /// Re-fetches every enabled add-on's manifest.
    /// C4: the Installed pane's Check now (restarts every enabled add-on's refresh).
    func checkAll() {
        AddonRepository.shared.checkAll()
    }

    func refreshAll() {
        AddonRepository.shared.refreshAll()
        trackRefresh()
    }

    /// Re-fetches one add-on's manifest, bypassing the cache.
    func refresh(manifestUrl: String) {
        AddonRepository.shared.refreshAddon(manifestUrl: manifestUrl, forceRefresh: true)
        trackRefresh()
    }

    /// Retries a stalled add-on: clears its stalled flag, cancels the request still running for
    /// it (a plain `refresh` is a no-op while the old job is active) and starts a fresh one.
    func retryRefresh(manifestUrl: String) {
        stalledUrls.remove(manifestUrl)
        AddonRepository.shared.restartRefresh(manifestUrl: manifestUrl)
        // Review r3/r5: the replacement request's age starts now, under the generation the restart
        // just bumped (read straight back, so it does not wait for the next emission).
        if let state = AddonRepository.shared.uiState.value_ as? AddonsUiState,
           let generation = Self.refreshingGenerations(state)[manifestUrl] {
            refreshStartedAt[manifestUrl] = RefreshAge(generation: generation, startedAt: now())
        }
        reevaluateStalled()
        trackRefresh()
    }

    /// The repository marks `isRefreshing` synchronously before it launches each fetch, so the
    /// add-ons refreshing right after the call are exactly the ones it started. (Watching the flow
    /// instead can miss a fast refresh: the StateFlow conflates and skips values equal to the last
    /// one a collector saw.) None refreshing means nothing started, so there is no stamp. Otherwise
    /// one task polls the live list every 250 ms, up to 60 s, until they all settle.
    private func trackRefresh() {
        let started = (AddonRepository.shared.uiState.value_ as? AddonsUiState)?.addons ?? []
        let refreshedUrls = Set(started.filter { $0.isRefreshing }.map { $0.manifestUrl })
        guard !refreshedUrls.isEmpty else { return }
        isRefreshingAny = true
        refreshWait?.cancel()
        refreshWait = Task { @MainActor [weak self] in
            var latest = started
            for _ in 0..<240 {
                latest = (AddonRepository.shared.uiState.value_ as? AddonsUiState)?.addons ?? []
                if !latest.contains(where: { refreshedUrls.contains($0.manifestUrl) && $0.isRefreshing }) { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let self else { return }
            // Review r3: a finished wait clears itself, so the watcher owns the spinner again.
            self.refreshWait = nil
            let outcome = Self.refreshOutcome(addons: latest, refreshedUrls: refreshedUrls)
            self.lastRefreshOutcome = outcome
            self.refreshOutcomeSerial += 1
            if outcome.succeeded > 0 {
                let stamp = self.now()
                self.lastRefreshedAt = stamp
                Self.saveRefreshStamp(stamp, defaults: self.defaults, profileId: ProfileRepository.shared.activeProfileId,
                                      profileIdentity: Self.activeProfileIdentity)
            }
            // The 60 s cap can end the wait with a request still running: keep the spinner then.
            let live = (AddonRepository.shared.uiState.value_ as? AddonsUiState)?.addons ?? latest
            self.isRefreshingAny = live.contains { $0.isRefreshing }
        }
    }

    /// Display name: manifest name once loaded, otherwise the URL.
    func displayName(_ addon: ManagedAddon) -> String {
        Self.displayTitle(addon)
    }

    /// Hub C, H1: the shared `displayTitle` (user-set name, else manifest name). With neither, the
    /// host: the shared fallback is the URL's last path segment, which can be a key.
    nonisolated static func displayTitle(_ addon: ManagedAddon) -> String {
        let userSet = addon.userSetName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if addon.manifest == nil && userSet.isEmpty { return host(of: addon.manifestUrl) }
        return addon.displayTitle
    }

    /// Hub C, H1: the destination index for moving the card at `index` by `delta`, or nil when
    /// `index` is out of range, `delta` is 0, or the target would leave `0..<count`.
    nonisolated static func moveTarget(index: Int, by delta: Int, count: Int) -> Int? {
        guard index >= 0, index < count, delta != 0 else { return nil }
        let target = index + delta
        guard target >= 0, target < count else { return nil }
        return target
    }

    /// Hub C, H1: pure composition of the hub's summary line. Collections are not catalogs, so
    /// only `!isCollection` items count; `addonsOn` counts enabled add-ons (with or without a loaded
    /// manifest), so it does not dip while a manifest reloads.
    nonisolated static func summary(
        addons: [ManagedAddon],
        catalogs: [HomeCatalogSettingsItem],
        debridConnectedNames: [String],
        pluginsEnabled: Bool,
        pluginRepositories: Int,
        pluginProviders: Int
    ) -> HubSummary {
        let plain = catalogs.filter { !$0.isCollection }
        return HubSummary(
            addonsInstalled: addons.count,
            addonsOn: addons.filter { $0.enabled }.count,
            catalogsOn: plain.filter { $0.enabled }.count,
            catalogsTotal: plain.count,
            debridConnected: debridConnectedNames,
            plugins: pluginsEnabled
                ? PluginSummary(repositories: pluginRepositories, providers: pluginProviders)
                : nil
        )
    }

    /// Hub C, H1: per refreshed URL, failed when it has an `errorMessage` or left the list,
    /// succeeded otherwise.
    nonisolated static func refreshOutcome(addons: [ManagedAddon], refreshedUrls: Set<String>) -> RefreshOutcome {
        var succeeded = 0
        var failed = 0
        for url in refreshedUrls {
            // Still refreshing when the wait gave up (the 60 s cap) is not a success either.
            if let addon = addons.first(where: { $0.manifestUrl == url }), addon.errorMessage == nil, !addon.isRefreshing {
                succeeded += 1
            } else {
                failed += 1
            }
        }
        return RefreshOutcome(succeeded: succeeded, failed: failed)
    }

    /// Hub C, H2: card state. Order matters: refreshing (stalled when its URL is in `stalled`),
    /// then unavailable (error and no manifest), then disabled, else active.
    nonisolated static func status(of addon: ManagedAddon, stalled: Set<String> = []) -> AddonStatus {
        if addon.isRefreshing { return stalled.contains(addon.manifestUrl) ? .stalled : .refreshing }
        if addon.errorMessage != nil && addon.manifest == nil { return .unavailable }
        if !addon.enabled { return .disabled }
        return .active
    }

    /// Hub C, H2: the host only (no scheme, userinfo, port, path or query), so a keyed URL never
    /// reaches a card.
    nonisolated static func host(of manifestUrl: String) -> String {
        var rest = Substring(manifestUrl)
        // Review r2: only a `://` whose colon comes before the first `/`, `?` or `#` is the scheme
        // separator (`x.y/a?u=http://z` has none).
        let firstBreak = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        if let sep = rest.range(of: "://"), sep.lowerBound < firstBreak { rest = rest[sep.upperBound...] }
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = rest[..<end]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            // Review r2: an IPv6 literal keeps its brackets and drops its port.
            authority = authority[...close]
        } else if let colon = authority.firstIndex(of: ":") {
            authority = authority[..<colon]
        }
        return String(authority)
    }

    /// Hub C, H2: resource names as card labels, in manifest order, deduplicated.
    nonisolated static func resourceLabels(of manifest: AddonManifest) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for resource in manifest.resources {
            let label: String
            switch resource.name {
            case "stream": label = String(localized: "Streams")
            case "catalog": label = String(localized: "Catalogs")
            case "subtitles": label = String(localized: "Subtitles")
            case "meta": label = String(localized: "Metadata")
            default:
                // Review r2: an unknown resource name reads as words, not as an identifier.
                let words = resource.name.replacingOccurrences(of: "_", with: " ")
                label = words.prefix(1).uppercased() + words.dropFirst()
            }
            if seen.insert(label).inserted { labels.append(label) }
        }
        return labels
    }

    /// Hub C, H2: logo URLs of enabled add-ons (non-empty only), first `limit`.
    nonisolated static func logoUrls(of addons: [ManagedAddon], limit: Int) -> [String] {
        let urls = addons.compactMap { addon -> String? in
            guard addon.enabled, let logo = addon.manifest?.logoUrl, !logo.isEmpty else { return nil }
            return logo
        }
        return Array(urls.prefix(max(0, limit)))
    }

    deinit {
        watcher?.cancel()
        refreshWait?.cancel()
        stallTicker?.cancel()
    }
}
