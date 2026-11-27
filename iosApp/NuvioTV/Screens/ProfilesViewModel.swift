import Combine
import Foundation
import SharedCore

/// Observes the shared `ProfileRepository` and exposes local (guest-mode) profile management to the
/// tvOS UI. All operations persist locally via `ProfileStorage` (NSUserDefaults) because the app runs
/// in anonymous mode — no sign-in, no cloud. Selecting a profile drives `ActiveProfileProvider`
/// (wired in Phase 0), so downstream data (watch progress, library, …) is scoped per profile.
@MainActor
final class ProfilesViewModel: ObservableObject {
    /// Review r6: the one displayed snapshot (list + its account token), produced by Kotlin. Rows are
    /// derived from it, so a row never exists without the token of the list it came from; every row
    /// action takes a row.
    @Published private(set) var snapshot: ProfileState?
    var rows: [DisplayedProfile] { snapshot?.displayed ?? [] }
    /// Display only (counts, focus seeding); actions never take a bare profile.
    var profiles: [NuvioProfile] { rows.map(\.profile) }
    @Published private(set) var activeProfile: NuvioProfile?
    @Published private(set) var isBusy = false
    /// Cloud avatar catalog (empty in guest mode / offline — pickers hide themselves).
    @Published private(set) var avatars: [AvatarCatalogItem] = []

    /// Max profiles supported by the shared repository (`MAX_PROFILES`).
    let maxProfiles = 6

    /// True when signed in with a real Nuvio account (PIN + avatar catalog need the cloud).
    /// Fed by a watcher on `AuthRepository.state` (the exported StateFlow has no sync `.value`).
    @Published private(set) var isCloudAccount = false
    /// FEAT-65: the shared `rememberLastProfileEnabled` flag ("Open Last Profile at Launch"),
    /// mirrored from the same `ProfileRepository.state` watcher as the profiles.
    @Published private(set) var rememberLastProfile = false

    private var watcher: FlowWatcher?
    private var avatarsWatcher: FlowWatcher?
    private var authWatcher: FlowWatcher?

    /// Scope identity W2: true for the whole select (`IdentityModel.localSelectInFlight`, owned by
    /// `selectAndEnter`); the picker's tiles ignore taps meanwhile.
    var isSwitching: Bool { IdentityModel.shared.localSelectInFlight }

    /// What `selectAndEnter` calls (real by default; `SelectAndEnterSequenceTests` installs fakes).
    var selectPorts: ProfileSelectPorts = LiveProfileSelectPorts()

    func start() {
        guard watcher == nil else { return }
        // Scope identity W2: the cached payload is restored at launch only for its own trusted owner
        // (TvOsProviderInstaller's boot decision) and by the account's publish; never here (P6).
        watcher = FlowWatcherKt.watch(ProfileRepository.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? ProfileState else { return }
            // Written only on change: ContentView observes this model at the app root, and the
            // periodic sync re-emits unchanged state. NuvioProfile is a Kotlin data class
            // (`isEqual` = structural), so `!=` compares contents.
            if !IdentityValues.same(self.snapshot, state) { self.snapshot = state }
            if self.activeProfile != state.activeProfile { self.activeProfile = state.activeProfile }
            if self.rememberLastProfile != state.rememberLastProfileEnabled {
                self.rememberLastProfile = state.rememberLastProfileEnabled
            }
        }
        avatarsWatcher = FlowWatcherKt.watch(AvatarRepository.shared.avatars) { [weak self] emitted in
            guard let self, let items = emitted as? [AvatarCatalogItem] else { return }
            if self.avatars != items { self.avatars = items }
        }
        authWatcher = FlowWatcherKt.watch(AuthRepository.shared.state) { [weak self] emitted in
            guard let self else { return }
            let cloud = (emitted as? AuthStateAuthenticated)?.isAnonymous == false
            if self.isCloudAccount != cloud { self.isCloudAccount = cloud }
        }
        // Hydrates from cache, then fetches the catalog RPC (no-ops without a cloud session).
        AvatarRepository.shared.fetchAvatars { _ in }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        avatarsWatcher?.cancel()
        avatarsWatcher = nil
        authWatcher?.cancel()
        authWatcher = nil
    }

    // MARK: - Actions

    /// Scope identity W2 (spec 8.0.3): the one select sequence (picker tap and auto-enter). It owns
    /// `IdentityModel.localSelectInFlight` for the whole operation (the cover shows at once) and
    /// clears it in one `defer`, its last statement, after `enter` ran or the picker was chosen.
    /// Breadcrumbs bracket every Kotlin call (kept out of `#if DEBUG`: testers' console logs are
    /// the only diagnostic for a crash we cannot reproduce).
    /// Review r6: the displayed row builds its own request (its list's token and the full row).
    @discardableResult
    func selectAndEnter(_ row: DisplayedProfile, origin: SelectOrigin, enter: @escaping (IdentityState) -> Void) async -> Bool {
        print("[ProfileSelect] selecting profile \(row.profile.profileIndex)")
        let entered = await Self.selectAndEnter(request: row.selectRequest(origin: origin),
                                                identity: IdentityModel.shared, ports: selectPorts, enter: enter)
        print("[ProfileSelect] select finished — entered=\(entered)")
        return entered
    }

    /// Audit #1: after a select that was not entered, the row now on screen for the same slot of
    /// the same list when it turned PIN-locked since the tap (the picker re-asks for the PIN).
    func newlyLockedRow(after tapped: DisplayedProfile) -> DisplayedProfile? {
        guard !tapped.profile.pinEnabled,
              let current = snapshot?.displayedRow(slot: tapped.profile.profileIndex),
              current.listToken == tapped.listToken,
              current.profile.id == tapped.profile.id,
              current.profile.pinEnabled else { return nil }
        return current
    }

    /// The sequence itself, testable with a fake barrier. Returns whether the profile was entered.
    @discardableResult
    static func selectAndEnter(request: SelectRequest?,
                               identity: IdentityModel,
                               ports: ProfileSelectPorts,
                               enter: (IdentityState) -> Void) async -> Bool {
        // 1. Tap (Main). The cover goes up first. Review r1 #4: the tap belongs to the identity it
        // was made under (TapBindingRule); while a window holds, wait (bounded 2 s) and decide
        // again; an identity that moved to another account sends the user back to the picker.
        identity.localSelectInFlight = true
        defer { identity.localSelectInFlight = false } // 4: the last statement, whatever happened
        // The tap binds to the account of the list the row was displayed from (nil: never enter).
        let boundAccount = request.map { $0.displayedUnder.account.storageKey() ?? "none" }
        var binding = TapBindingRule.decide(bound: boundAccount, current: ports.currentState())
        for _ in 0..<40 where binding == .wait {
            try? await Task.sleep(nanoseconds: 50_000_000)
            binding = TapBindingRule.decide(bound: boundAccount, current: ports.currentState())
        }
        guard binding == .proceed, let accountAtTap = ports.currentState()?.scope.account, let request else {
            print("[ProfileSelect] not entered: the tap's identity is not the open one (\(binding))")
            return false
        }
        // 2. The barrier (Main suspended; nothing on screen changes).
        let result: TransitionResult?
        if ports.failBeforeBegin {
            print("[ProfileSelect] debug: failing the select before Begin")
            result = nil
        } else {
            // Rule G: the barrier admits it against the current token and list (the guarantee).
            result = try? await ports.select(request: request)
        }
        // 3. Branch on the result.
        guard let done = result as? TransitionResultDone else {
            if result is TransitionResultRequested {
                // Swift tasks carry neither the job nor the lane element (rule A): impossible here.
                ports.reportImpossible("selectProfile returned Requested to Swift")
            }
            print("[ProfileSelect] not entered: \(result.map { String(describing: $0) } ?? "no result")")
            return false // 4b: the cover hides while not entered → recoverToRoot
        }
        let final = done.final
        guard final.phase is IdentityPhaseOpen,
              final.scope.slot == request.slot,
              IdentityValues.same(final.scope.account, accountAtTap),
              IdentityValues.same(final, ports.currentState()) else {
            print("[ProfileSelect] not entered: the identity moved on (\(final))")
            return false
        }
        // Full cloud pull and periodic polling for the selected profile (self-guarding: no-ops for
        // guests and signed-out sessions).
        ports.startSync(slot: final.scope.slot)
        guard IdentityValues.same(final, ports.currentState()) else {
            print("[ProfileSelect] not entered: a transition completed during the sync start")
            return false
        }
        identity.isEntered = true
        enter(final) // 4a: ContentView's closure, synchronous on Main
        return true
    }

    /// FEAT-65: the profile to enter without the picker at cold launch, or nil to show the picker.
    /// Reads the repository's state SYNCHRONOUSLY (call `start()` first so a guest's cached
    /// payload is loaded; a real account's cache is keyed to its user by `AuthViewModel`'s
    /// `ensureLoaded` before the gate turns `.main`). The rule is `ProfileAutoEnter.decision`.
    /// Review r6: the remembered row and its token come from ONE snapshot (a DisplayedProfile).
    func rememberedStartupProfile(alreadyFiredThisLaunch: Bool) -> DisplayedProfile? {
        guard let state = ProfileRepository.shared.state.value_ as? ProfileState else { return nil }
        let enabled = ProfileAutoEnter.debugEnabledOverride() ?? state.rememberLastProfileEnabled
        let row = state.displayedRow(slot: ProfileRepository.shared.activeProfileId)
        let active = row?.profile
        guard ProfileAutoEnter.decision(enabled: enabled,
                                        everSelected: state.hasEverSelectedProfile,
                                        activeProfileExists: active != nil,
                                        pinEnabled: active?.pinEnabled ?? false,
                                        alreadyFiredThisLaunch: alreadyFiredThisLaunch) else { return nil }
        return row
    }

    func createProfile(
        name: String,
        colorHex: String,
        avatarId: String? = nil,
        avatarUrl: String? = nil,
        completion: @escaping () -> Void
    ) {
        // Review r6: created under the token of the list on screen (nothing displayed: nothing created).
        guard let snapshot else { completion(); return }
        isBusy = true
        ProfileRepository.shared.createProfile(
            list: snapshot,
            name: name,
            avatarColorHex: colorHex,
            avatarId: avatarId,
            avatarUrl: avatarUrl,
            usesPrimaryAddons: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isBusy = false
                completion()
            }
        }
    }

    func updateProfile(
        _ row: DisplayedProfile,
        name: String,
        colorHex: String,
        avatarId: String? = nil,
        avatarUrl: String? = nil,
        completion: @escaping () -> Void
    ) {
        isBusy = true
        ProfileRepository.shared.updateProfile(
            row: row,
            name: name,
            avatarColorHex: colorHex,
            avatarId: avatarId,
            avatarUrl: avatarUrl,
            usesPrimaryAddons: row.profile.usesPrimaryAddons
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isBusy = false
                completion()
            }
        }
    }

    // MARK: - PIN (cloud accounts only; RPCs verify/set/clear server-side)

    /// Verifies a profile PIN. Falls back to the shared local cache when offline.
    /// Audit #1/#2: a refused check (identity moved) is `refused`, never a wrong PIN; an unlocked
    /// check hands back the refreshed row of the same list, which the select then uses.
    func verifyPin(_ row: DisplayedProfile, pin: String, completion: @escaping (PinCheck?) -> Void) {
        ProfileRepository.shared.verifyPin(row: row, pin: pin) { check, _ in
            DispatchQueue.main.async { completion(check) }
        }
    }

    /// Sets (or changes, when `currentPin` is provided) a profile's 4-digit PIN.
    func setPin(_ row: DisplayedProfile, pin: String, currentPin: String?, completion: @escaping (PinVerifyResult?) -> Void) {
        ProfileRepository.shared.setPin(row: row, pin: pin, currentPin: currentPin) { result, _ in
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Removes a profile's PIN lock (requires the current PIN).
    func clearPin(_ row: DisplayedProfile, currentPin: String?, completion: @escaping (PinVerifyResult?) -> Void) {
        ProfileRepository.shared.clearPin(row: row, currentPin: currentPin) { result, _ in
            DispatchQueue.main.async { completion(result) }
        }
    }

    func deleteProfile(_ row: DisplayedProfile, completion: @escaping () -> Void = {}) {
        ProfileRepository.shared.deleteProfile(row: row) { _ in
            DispatchQueue.main.async { completion() }
        }
    }

    deinit {
        watcher?.cancel()
        avatarsWatcher?.cancel()
        authWatcher?.cancel()
    }
}

/// What `ProfilesViewModel.selectAndEnter` needs from Kotlin and the debug knobs.
@MainActor
protocol ProfileSelectPorts {
    func select(request: SelectRequest) async throws -> TransitionResult
    func currentState() -> IdentityState?
    func startSync(slot: Int32)
    var failBeforeBegin: Bool { get }
    func reportImpossible(_ message: String)
}

@MainActor
struct LiveProfileSelectPorts: ProfileSelectPorts {
    func select(request: SelectRequest) async throws -> TransitionResult {
        try await IdentityBarrier.shared.selectProfile(request: request)
    }

    func currentState() -> IdentityState? {
        IdentityGate.shared.state.value_ as? IdentityState
    }

    func startSync(slot: Int32) {
        SyncManager.shared.pullAllForProfile(profileId: slot)
        SyncManager.shared.startPeriodicNuvioSyncPull(profileId: slot)
    }

    var failBeforeBegin: Bool {
        #if DEBUG
        UserDefaults.standard.integer(forKey: "debug.identityFailBeforeBegin") == 1
        #else
        false
        #endif
    }

    func reportImpossible(_ message: String) {
        assertionFailure(message)
    }
}

/// FEAT-65: the Settings row's model for "Open Last Profile at Launch". A watcher on
/// `ProfileRepository.state` only, deliberately NOT a second `ProfilesViewModel`: that one's
/// `start()` reloads the cached payload and fans `onProfilesCached()` out, a side effect a Settings
/// pane must not have. The write goes through the shared setter, which persists the flag in the
/// profile payload (device-local, like upstream).
@MainActor
final class RememberLastProfileModel: ObservableObject {
    @Published private(set) var enabled = false
    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(ProfileRepository.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? ProfileState else { return }
            self.enabled = state.rememberLastProfileEnabled
        }
    }

    func set(_ value: Bool) {
        print("[ProfileSelect] remember last profile -> \(value)")
        ProfileRepository.shared.setRememberLastProfileEnabled(enabled: value)
    }

    deinit {
        watcher?.cancel()
    }
}
