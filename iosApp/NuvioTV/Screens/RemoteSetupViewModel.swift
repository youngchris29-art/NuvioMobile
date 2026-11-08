import Combine
import CoreImage
import Foundation
import SharedCore
import UIKit

/// Drives the "Remote Setup" section in Settings: runs `RemoteSetupServer`, feeds it a live
/// snapshot of addons / Home rows / key presence, surfaces incoming proposals as a confirm
/// alert, and — on confirm — applies the proposed state through the shared repos.
///
/// Nothing a browser sends is applied without an explicit confirmation on the TV.
@MainActor
final class RemoteSetupViewModel: ObservableObject {
    /// `http://<ip>:<port>` once the server is listening; nil while stopped.
    @Published private(set) var serverURL: String?
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var startFailed = false
    /// C2: a browser has presented this session's token (cleared on every start and stop). The TV
    /// cannot tell when the page closes, so the pane words this in the past tense ("Page opened").
    @Published private(set) var phoneConnected = false
    /// Non-nil while a browser proposal awaits the user's decision (drives the alert).
    @Published var pendingChange: RemoteSetupServer.PendingChange?
    @Published private(set) var pendingSummary: String = ""
    /// C3: the pending proposal, one line per change (the hub's confirm dialog lists these).
    @Published private(set) var pendingLines: [RemoteSetupChangeList.Line] = []
    /// C3 review r1: the lines were recomputed at Confirm because the TV's lists changed while
    /// the dialog was up; the dialog says so and asks again.
    @Published private(set) var pendingLinesRefreshed = false

    var isRunning: Bool { serverURL != nil }

    /// True between `start()` and the server's bind completion. Blocks re-entrant starts so a
    /// Retry tap can't stack a second attempt (and a second set of watchers) on an unresolved
    /// one (ME-002).
    @Published private(set) var isStarting = false
    /// Bumped by `start()` and `stop()`; a bind completion from a superseded attempt is ignored
    /// so it can't republish the URL/QR after the user pressed Stop (HI-002/ME-002).
    private var startAttempt = 0
    /// True only while THIS instance holds the idle-timer override. `stop()` on an instance that
    /// never started (e.g. the Custom Posters screen's own copy) must not re-enable the idle timer
    /// while another instance is still serving a phone.
    private var disabledIdleTimer = false

    private let server = RemoteSetupServer()
    private var addonWatcher: FlowWatcher?
    private var rowWatcher: FlowWatcher?
    private var mdbListWatcher: FlowWatcher?
    private var badgeWatcher: FlowWatcher?
    private var posterPatternWatcher: FlowWatcher?

    /// Stage C (C1): the per-session add-on ids the page sees instead of manifest URLs; a fresh
    /// map on every start, so ids from an earlier session mean nothing.
    private var addonIds = RemoteSetupAddonIds()
    /// Review r12: Home-row keys are built from add-on-authored ids, so the page gets per-session
    /// opaque row ids too, translated back to keys at the proposal boundary.
    private var rowIds = RemoteSetupAddonIds()
    /// Every manifest URL seen this session, kept for redaction after its add-on is removed.
    private var seenUrls = Set<String>()
    /// The pending proposal's add-on list resolved to manifest URLs (nil when it has none).
    private var pendingAddons: [RemoteSetupAddonIds.Resolved]?

    // Cached snapshots (updated by the watchers, read when building state JSON + applying diffs).
    private var addons: [ManagedAddon] = []
    private var rows: [HomeCatalogSettingsItem] = []
    // Upstream 60ee0160: TMDB has no user-facing key any more (bundled at compile time), so
    // there's nothing for the remote-setup page to report or accept here.
    private var mdbListKeySet = false
    /// C3 review r3: setting a key also turns MDBList on, so the dialog needs to know if it is off.
    private var mdbListEnabled = false
    /// Whether a custom poster pattern is saved. Only the flag goes to the web page; the pattern
    /// itself may embed an API key and is never echoed or logged.
    private var posterPatternSet = false
    /// Source URLs of currently imported stream badge packs (shown read-only on the web page).
    private var badgePackUrls: [String] = []

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        startFailed = false
        startAttempt += 1
        let attempt = startAttempt
        addonIds = RemoteSetupAddonIds()
        phoneConnected = false
        server.onAuthorizedRequest = { [weak self] in
            guard let self, self.serverURL != nil else { return }
            if !self.phoneConnected { self.phoneConnected = true }
        }
        rowIds = RemoteSetupAddonIds()
        seenUrls = []

        server.onChangeProposed = { [weak self] change in
            Task { @MainActor in
                guard let self else { return }
                // A callback for a proposal that was itself superseded (callbacks can run late)
                // leaves the alert alone. A current one replaces the alert: the server has
                // already superseded whatever it showed.
                guard self.server.isPending(id: change.id) else { return }
                self.pendingChange = nil
                self.pendingAddons = nil
                guard self.rowIdsKnown(change.proposal) else {
                    self.server.reject(id: change.id, status: .staleRows)
                    return
                }
                // C1: resolve the page's ids back to manifest URLs now; an unknown or stale id
                // (or a bad new URL) refuses the whole proposal, since dropping the entry would
                // remove that add-on.
                switch self.resolveAddons(change.proposal) {
                case .failure(let refusal):
                    self.server.reject(id: change.id, status: Self.status(for: refusal))
                case .success(let resolved):
                    self.pendingAddons = resolved
                    self.pendingSummary = self.summarize(change.proposal)
                    self.pendingLines = self.changeLines(change.proposal, addons: resolved)
                    self.pendingLinesRefreshed = false
                    self.pendingChange = change
                }
            }
        }
        server.start { [weak self] port in
            Task { @MainActor in
                guard let self, attempt == self.startAttempt else { return }
                self.isStarting = false
                guard let port, let ip = DeviceIpAddress.current(),
                      let token = self.server.sessionToken else {
                    // Bind failed or no LAN address: tear the half-started server down so a
                    // Retry begins from a clean slate (ME-002).
                    self.server.stop()
                    self.startFailed = true
                    return
                }
                // Only now that the listener is actually ready: keep the TV awake (if tvOS idles
                // into the screensaver the app suspends and the server dies mid-edit) and start
                // feeding state. On failure the idle timer was never touched (ME-002).
                UIApplication.shared.isIdleTimerDisabled = true
                self.disabledIdleTimer = true
                self.installWatchers()
                // The token is part of the URL — scanning the QR (or typing the short URL) is
                // what authorizes the browser session (HI-001).
                let url = "http://\(ip):\(port)/?t=\(token)"
                self.serverURL = url
                self.qrImage = Self.makeQrImage(from: url)
            }
        }
    }

    func stop() {
        startAttempt += 1
        isStarting = false
        startFailed = false
        if disabledIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = false
            disabledIdleTimer = false
        }
        server.stop()
        serverURL = nil
        qrImage = nil
        phoneConnected = false
        pendingChange = nil
        pendingAddons = nil
        cancelWatchers()
    }

    private func installWatchers() {
        cancelWatchers()
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            self.addons = state.addons
            self.pushState()
        }
        rowWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? HomeCatalogSettingsUiState else { return }
            self.rows = state.items
            self.pushState()
        }
        mdbListWatcher = FlowWatcherKt.watch(MdbListSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MdbListSettings else { return }
            self.mdbListKeySet = state.hasApiKey
            self.mdbListEnabled = state.enabled
            self.pushState()
        }
        badgeWatcher = FlowWatcherKt.watch(StreamBadgeSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? StreamBadgeSettingsUiState else { return }
            self.badgePackUrls = state.rules.imports.map(\.sourceUrl)
            self.pushState()
        }
        posterPatternWatcher = FlowWatcherKt.watch(CustomPosterUrlRepository.shared.pattern) { [weak self] emitted in
            guard let self, let value = emitted as? String else { return }
            self.posterPatternSet = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            self.pushState()
        }
        AddonRepository.shared.initialize()
        CustomPosterUrlRepository.shared.ensureLoaded()
        MdbListSettingsRepository.shared.ensureLoaded()
        StreamBadgeSettingsRepository.shared.ensureLoaded()
    }

    private func cancelWatchers() {
        addonWatcher?.cancel()
        rowWatcher?.cancel()
        mdbListWatcher?.cancel()
        badgeWatcher?.cancel()
        posterPatternWatcher?.cancel()
        posterPatternWatcher = nil
        addonWatcher = nil
        rowWatcher = nil
        mdbListWatcher = nil
        badgeWatcher = nil
    }

    // MARK: - Confirm / reject

    func confirmPending() {
        guard let change = pendingChange else { return }
        // Superseded or refused while the dialog was up: nothing to apply.
        guard server.isPending(id: change.id) else {
            pendingChange = nil
            pendingAddons = nil
            return
        }
        // C3 review r2: judge the change against the repositories as they are now, not the
        // watchers' copies (an update can still be on its way to them).
        refreshFromRepositories()
        // The add-on list can change under the dialog (sync, another screen): resolve the ids
        // again against the list as it is now, and refuse the whole proposal if one went stale.
        switch resolveAddons(change.proposal) {
        case .failure(let refusal):
            pendingChange = nil
            pendingAddons = nil
            server.reject(id: change.id, status: Self.status(for: refusal))
        case .success(let resolved):
            // C3 review r1: what the user approved must still be what applies. If the lists
            // moved under the dialog, show the new lines and ask again instead of applying.
            let fresh = changeLines(change.proposal, addons: resolved)
            guard fresh == pendingLines else {
                pendingAddons = resolved
                pendingLines = fresh
                pendingLinesRefreshed = true
                return
            }
            pendingChange = nil
            pendingAddons = nil
            // Claimed atomically with supersession: a newer proposal that lands after the check
            // above wins, and this one is not applied.
            guard server.claimForConfirm(id: change.id) else { return }
            let status = apply(change.proposal, addons: resolved)
            let installs = status == .confirmed ? (resolved ?? []).filter(\.isNew) : []
            installThenFinish(installs, changeId: change.id, status: status)
        }
    }

    func rejectPending() {
        guard let change = pendingChange else { return }
        server.reject(id: change.id)
        pendingChange = nil
        pendingAddons = nil
    }

    // MARK: - State snapshot → server

    /// C1: an add-on as the page sees it: a per-session id and the host, never the manifest URL.
    private struct StateAddon: Encodable {
        let id: String
        let host: String
        let name: String
        let description: String
        let enabled: Bool
    }
    private struct StateRow: Encodable {
        let key: String
        let title: String
        let enabled: Bool
        let isCollection: Bool
    }
    private struct StateSnapshot: Encodable {
        let deviceName: String
        let addons: [StateAddon]
        let rows: [StateRow]
        let mdblistKeySet: Bool
        let posterPatternSet: Bool
        let badgePacks: [String]
    }

    private func pushState() {
        // Any add-on's text can quote any add-on's key, so every text is checked against every URL
        // seen this session (review r14: a removed add-on's rows can outlive it).
        seenUrls.formUnion(addons.map(\.manifestUrl))
        let allUrls = Array(seenUrls)
        let snapshot = StateSnapshot(
            deviceName: UIDevice.current.name,
            addons: addons.map {
                StateAddon(
                    id: addonIds.id(for: $0.manifestUrl),
                    host: AddonsViewModel.host(of: $0.manifestUrl),
                    name: RemoteSetupAddonIds.pageSafe($0.displayTitle, manifestUrls: allUrls),
                    description: RemoteSetupAddonIds.pageSafe($0.manifest?.description_ ?? "", manifestUrls: allUrls),
                    enabled: $0.enabled
                )
            },
            rows: rows.map {
                StateRow(
                    key: rowIds.id(for: $0.key),
                    title: RemoteSetupAddonIds.pageSafe($0.displayTitle, manifestUrls: allUrls),
                    enabled: $0.enabled,
                    isCollection: $0.isCollection
                )
            },
            mdblistKeySet: mdbListKeySet,
            posterPatternSet: posterPatternSet,
            badgePacks: badgePackUrls
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            server.updateState(data)
        }
    }

    // MARK: - Applying a confirmed proposal

    /// The proposal's add-on list resolved against the current list; nil inside `.success` when
    /// the proposal leaves add-ons alone.
    private func resolveAddons(
        _ proposal: RemoteSetupServer.Proposal
    ) -> Result<[RemoteSetupAddonIds.Resolved]?, RemoteSetupAddonIds.Refusal> {
        guard let entries = proposal.addons else { return .success(nil) }
        return addonIds.resolve(
            entries.map { (id: $0.id, url: $0.url, enabled: $0.enabled) },
            baseline: proposal.addonBaseline,
            currentUrls: addons.map(\.manifestUrl),
            sameManifest: AddonManifestURL.isSameManifest
        ).map { Optional($0) }
    }

    private static func status(for refusal: RemoteSetupAddonIds.Refusal) -> RemoteSetupServer.ChangeStatus {
        switch refusal {
        case .stale: .stale
        case .invalidUrl, .alreadyInstalled: .invalid
        }
    }

    /// Applies a confirmed proposal and returns how it settled. When the repository refuses the
    /// add-on part (the list moved, or it is read-only), nothing of the proposal is applied.
    private func apply(
        _ proposal: RemoteSetupServer.Proposal,
        addons resolved: [RemoteSetupAddonIds.Resolved]?
    ) -> RemoteSetupServer.ChangeStatus {
        if let resolved {
            let expected = (proposal.addonBaseline ?? []).compactMap { addonIds.url(for: $0) }
            let outcome = applyAddons(resolved, expected: expected)
            guard outcome == .confirmed else { return outcome }
        }
        applyRows(proposal)
        if let key = proposal.mdblistKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            MdbListSettingsRepository.shared.setApiKey(value: key)
            MdbListSettingsRepository.shared.setEnabled(value: true)
        }
        // Custom poster pattern: blank clears. Never logged (may contain an API key).
        if let raw = proposal.posterPattern {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if pattern.isEmpty {
                CustomPosterUrlRepository.shared.clearPattern()
            } else if Self.isValidPosterPattern(pattern) {
                CustomPosterUrlRepository.shared.setPattern(pattern: pattern)
            }
        }
        // Badge pack imports (async fetch+parse; the badge watcher refreshes the page state as
        // each one lands). Already-imported URLs are re-fetched/updated by the shared repo.
        for url in proposal.badgeUrls ?? [] {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            StreamBadgeSettingsRepository.shared.importStreamBadgeRulesFromUrl(url: trimmed) { _, _ in }
        }
        return .confirmed
    }

    /// Removals, enabled flips and the order go to the repository as ONE atomic step that checks
    /// the list is still `expected` (the list the page edited) against the repository's own
    /// state, not this screen's watcher copy; installs follow only when it applied.
    private func applyAddons(_ proposed: [RemoteSetupAddonIds.Resolved], expected: [String]) -> RemoteSetupServer.ChangeStatus {
        let repo = AddonRepository.shared
        let existing = proposed.filter { !$0.isNew }
        var enabled: [String: KotlinBoolean] = [:]
        for entry in existing {
            if let flag = entry.enabled { enabled[entry.url] = KotlinBoolean(value: flag) }
        }
        // C3 review r2: the flags the dialog judged must still hold inside the repository's
        // atomic step, or what the user approved is not what applies.
        var expectedEnabled: [String: KotlinBoolean] = [:]
        for entry in existing where entry.enabled != nil {
            if let current = addons.first(where: { $0.manifestUrl == entry.url }) {
                expectedEnabled[entry.url] = KotlinBoolean(value: current.enabled)
            }
        }
        let result = repo.applyEditedListIfUnchanged(
            expectedUrls: expected,
            desiredUrls: existing.map(\.url),
            enabled: enabled,
            addsNew: proposed.contains(where: \.isNew),
            expectedEnabled: expectedEnabled
        )
        switch result {
        case .stale: return .stale
        case .readOnly: return .readOnly
        default: break
        }
        // New add-ons are installed by `installThenFinish` once the rest has applied.
        return .confirmed
    }

    /// Review r15: an install that lost the duplicate race (another page or screen installed the
    /// same manifest first) is satisfied, not failed: the add-on is there.
    nonisolated static func installSatisfied(succeeded: Bool, url: String, installed: [String]) -> Bool {
        succeeded || installed.contains { AddonManifestURL.isSameManifest($0, url) }
    }

    enum InstallOutcome: Equatable { case installed, failed, conflict }

    /// Review r3/r4: one new add-on's result. Installed by this change (with its flag, set in the
    /// same step): installed. Not installed and absent: failed (the phone gets it back to retry).
    /// Lost the race to another change with the same flag: installed. With the other flag: a
    /// conflict. Its flag is left alone and the entry is not sent back (it is installed, so a
    /// resend would only be refused as a duplicate); the phone is told to check its switch.
    nonisolated static func installOutcome(succeeded: Bool, wanted: Bool, landedEnabled: Bool?) -> InstallOutcome {
        if succeeded { return .installed }
        guard let landedEnabled else { return .failed }
        return landedEnabled == wanted ? .installed : .conflict
    }

    /// Installs the proposal's new add-ons (async manifest fetches) and settles the change only
    /// when every one has finished, so the page, which keeps polling while the change is
    /// `applying`, reloads a list that already holds them. A read-only list was refused before
    /// this, so the repository accepts them (a failed fetch simply leaves that one out).
    private func installThenFinish(_ entries: [RemoteSetupAddonIds.Resolved], changeId: String, status: RemoteSetupServer.ChangeStatus) {
        let urls = entries.map(\.url)
        guard !urls.isEmpty else {
            server.finishApplying(id: changeId, status: status)
            return
        }
        var remaining = urls.count
        var failed: [Int] = []
        var conflictIds: [String] = []
        for (index, url) in urls.enumerated() {
            // Review r4: the requested flag is set inside the install's own state update.
            let wanted = entries[index].enabled ?? true
            AddonRepository.shared.addAddon(rawUrl: url, enabled: wanted) { [weak self] result, _ in
                let succeeded = result is AddAddonResultSuccess
                Task { @MainActor in
                    let current = (AddonRepository.shared.uiState.value_ as? AddonsUiState)?.addons ?? []
                    let landed = current.first(where: { AddonManifestURL.isSameManifest($0.manifestUrl, url) })
                    switch Self.installOutcome(succeeded: succeeded, wanted: wanted, landedEnabled: landed?.enabled) {
                    case .installed: break
                    case .failed: failed.append(index)
                    case .conflict:
                        // Review r5: name the installed add-on by its session id, so the page can
                        // mark exactly that row (two variants from one host look alike).
                        if let landed { conflictIds.append(self?.addonIds.id(for: landed.manifestUrl) ?? "") }
                    }
                    remaining -= 1
                    guard remaining == 0 else { return }
                    // Review r14: a failed install is reported, not hidden behind "confirmed".
                    if failed.isEmpty && conflictIds.isEmpty {
                        self?.server.finishApplying(id: changeId, status: status)
                    } else {
                        self?.server.finishApplying(id: changeId, status: .partial, failedNewIndices: failed.sorted(), conflictIds: conflictIds.filter { !$0.isEmpty })
                    }
                }
            }
        }
    }

    /// The page's opaque row ids as Home-row keys (every id is checked by `rowIdsKnown` first).
    private func rowKeys(_ ids: [String]?) -> [String]? {
        ids?.compactMap { rowIds.url(for: $0) }
    }

    /// Review r16: a row id this session never minted means the page holds another session's
    /// list; applying it would drop the row from the disabled set and re-enable it.
    private func rowIdsKnown(_ proposal: RemoteSetupServer.Proposal) -> Bool {
        ((proposal.rowOrder ?? []) + (proposal.disabledRowKeys ?? [])).allSatisfy { rowIds.url(for: $0) != nil }
            && Self.hasNoDuplicates(proposal.rowOrder) && Self.hasNoDuplicates(proposal.disabledRowKeys)
    }

    /// C3 review r2: a repeated row id makes the order simulation insert past the end.
    nonisolated static func hasNoDuplicates(_ ids: [String]?) -> Bool {
        guard let ids else { return true }
        return Set(ids).count == ids.count
    }

    private func applyRows(_ proposal: RemoteSetupServer.Proposal) {
        let repo = HomeCatalogSettingsRepository.shared

        if let disabledKeys = rowKeys(proposal.disabledRowKeys) {
            let disabled = Set(disabledKeys)
            for row in rows {
                let shouldBeEnabled = !disabled.contains(row.key)
                if row.enabled != shouldBeEnabled {
                    repo.setEnabled(key: row.key, enabled: shouldBeEnabled)
                }
            }
        }

        if let order = rowKeys(proposal.rowOrder) {
            var simulated = rows.map(\.key)
            // Each key once (review r2: a repeat made a move target past the end of the list).
            var seen = Set<String>()
            let desired = order.filter { simulated.contains($0) && seen.insert($0).inserted }
            for targetIndex in desired.indices {
                guard let fromIndex = simulated.firstIndex(of: desired[targetIndex]),
                      fromIndex != targetIndex
                else { continue }
                repo.moveByIndex(fromIndex: Int32(fromIndex), toIndex: Int32(targetIndex))
                simulated.remove(at: fromIndex)
                simulated.insert(desired[targetIndex], at: targetIndex)
            }
        }
    }

    /// Accepts a (trimmed, non-empty) poster pattern only when it is at most 2048 characters, has
    /// no whitespace, and parses as an http(s) URL with a host. `{placeholder}` groups are swapped
    /// for a plain token first so `URLComponents` judges the URL shape, not the braces/pipes.
    static func isValidPosterPattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern.count <= 2048,
              pattern.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return false }
        let neutral = pattern.replacingOccurrences(
            of: "\\{[^}]*\\}", with: "x", options: .regularExpression
        )
        guard let comps = URLComponents(string: neutral),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty
        else { return false }
        return true
    }

    // MARK: - Alert summary

    /// C3 review r2: the add-on and Home-row lists straight from the repositories.
    private func refreshFromRepositories() {
        if let state = AddonRepository.shared.uiState.value_ as? AddonsUiState { addons = state.addons }
        if let state = HomeCatalogSettingsRepository.shared.uiState.value_ as? HomeCatalogSettingsUiState { rows = state.items }
        if let state = MdbListSettingsRepository.shared.uiState.value_ as? MdbListSettings { mdbListEnabled = state.enabled }
    }

    /// C3: the proposal's changes against the lists as they are now (names, never URLs).
    private func changeLines(
        _ proposal: RemoteSetupServer.Proposal,
        addons resolved: [RemoteSetupAddonIds.Resolved]?
    ) -> [RemoteSetupChangeList.Line] {
        RemoteSetupChangeList.lines(
            addons: addons.map { .init(id: $0.manifestUrl, title: $0.displayTitle, enabled: $0.enabled) },
            proposedAddons: resolved?.map { entry in
                .init(
                    id: entry.url,
                    title: entry.isNew ? AddonsViewModel.host(of: entry.url) : (addons.first { $0.manifestUrl == entry.url }?.displayTitle ?? AddonsViewModel.host(of: entry.url)),
                    enabled: entry.enabled,
                    isNew: entry.isNew
                )
            },
            rows: rows.map { .init(id: $0.key, title: $0.displayTitle, enabled: $0.enabled) },
            rowOrder: rowKeys(proposal.rowOrder),
            disabledRows: rowKeys(proposal.disabledRowKeys).map(Set.init),
            setsMdbListKey: proposal.mdblistKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            mdbListEnabled: mdbListEnabled,
            posterPattern: proposal.posterPattern,
            posterPatternValid: Self.isValidPosterPattern,
            badgePackUrls: (proposal.badgeUrls ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
    }

    private func summarize(_ proposal: RemoteSetupServer.Proposal) -> String {
        var parts: [String] = []

        if let proposed = pendingAddons {
            let currentUrls = Set(addons.map(\.manifestUrl))
            let proposedUrls = Set(proposed.map(\.url))
            let added = proposedUrls.subtracting(currentUrls).count
            let removed = currentUrls.subtracting(proposedUrls).count
            if added > 0 { parts.append(String(localized: "\(added) add-on\(added == 1 ? "" : "s") installed")) }
            if removed > 0 { parts.append(String(localized: "\(removed) add-on\(removed == 1 ? "" : "s") removed")) }
            let orderChanged = proposed.map(\.url).filter { currentUrls.contains($0) }
                != addons.map(\.manifestUrl).filter { proposedUrls.contains($0) }
            let togglesChanged = proposed.contains { entry in
                guard let enabled = entry.enabled,
                      let existing = addons.first(where: { $0.manifestUrl == entry.url })
                else { return false }
                return existing.enabled != enabled
            }
            if orderChanged || togglesChanged { parts.append(String(localized: "add-on settings changed")) }
        }

        if let order = rowKeys(proposal.rowOrder) {
            let known = rows.map(\.key)
            let disabled = Set(rowKeys(proposal.disabledRowKeys) ?? [])
            let orderChanged = order.filter { known.contains($0) } != known.filter { order.contains($0) }
            let togglesChanged = rows.contains { $0.enabled == disabled.contains($0.key) }
            if orderChanged || togglesChanged { parts.append(String(localized: "Home rows updated")) }
        }

        if proposal.mdblistKey?.isEmpty == false { parts.append(String(localized: "MDBList key set")) }
        if let posterPattern = proposal.posterPattern {
            let trimmed = posterPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                parts.append(String(localized: "Custom poster pattern cleared"))
            } else if Self.isValidPosterPattern(trimmed) {
                parts.append(String(localized: "Custom poster pattern set"))
            } else {
                parts.append(String(localized: "Custom poster pattern rejected: must be an http(s) URL"))
            }
        }
        if let badgeCount = proposal.badgeUrls?.count, badgeCount > 0 {
            parts.append(String(localized: "\(badgeCount) badge pack\(badgeCount == 1 ? "" : "s") imported"))
        }

        return parts.isEmpty ? String(localized: "No changes detected.") : parts.joined(separator: " \u{00B7} ") + "."
    }

    // MARK: - QR

    private static func makeQrImage(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    deinit {
        server.stop()
        addonWatcher?.cancel()
        rowWatcher?.cancel()
        mdbListWatcher?.cancel()
        badgeWatcher?.cancel()
    }
}
