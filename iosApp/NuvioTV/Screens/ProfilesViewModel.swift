import Combine
import Foundation
import SharedCore

/// Observes the shared `ProfileRepository` and exposes local (guest-mode) profile management to the
/// tvOS UI. All operations persist locally via `ProfileStorage` (NSUserDefaults) because the app runs
/// in anonymous mode — no sign-in, no cloud. Selecting a profile drives `ActiveProfileProvider`
/// (wired in Phase 0), so downstream data (watch progress, library, …) is scoped per profile.
@MainActor
final class ProfilesViewModel: ObservableObject {
    @Published private(set) var profiles: [NuvioProfile] = []
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

    func start() {
        guard watcher == nil else { return }
        ProfileRepository.shared.loadCachedProfiles()
        watcher = FlowWatcherKt.watch(ProfileRepository.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? ProfileState else { return }
            // Written only on change: ContentView observes this model at the app root, and the
            // periodic sync re-emits unchanged state. NuvioProfile is a Kotlin data class
            // (`isEqual` = structural), so `!=` compares contents.
            if self.profiles != state.profiles { self.profiles = state.profiles }
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

    /// Breadcrumbs bracket every Kotlin call: a throw crossing back into Swift here aborts the
    /// process rather than surfacing as a catchable error, so the last line printed names the stage
    /// that took the app down. Kept out of `#if DEBUG` on purpose — testers run release builds, and
    /// their console log is the only diagnostic we get for a crash we cannot reproduce locally.
    func select(_ profile: NuvioProfile) {
        print("[ProfileSelect] selecting profile \(profile.profileIndex)")
        ProfileRepository.shared.selectProfile(profileIndex: profile.profileIndex)
        print("[ProfileSelect] selectProfile returned — requesting full pull")
        // Full cloud pull for the selected profile (addons first, then the rest in parallel).
        // Self-guarding: no-op in guest mode / signed out, so the local-only flow is unchanged.
        SyncManager.shared.pullAllForProfile(profileId: profile.profileIndex)
        // Periodic activity polling (library + watch progress) for the session. Self-guarding the
        // same way; a profile switch re-targets the loop, sign-out cancels it via cancelAccountSync.
        SyncManager.shared.startPeriodicNuvioSyncPull(profileId: profile.profileIndex)
        print("[ProfileSelect] full pull requested — tap complete")
    }

    /// FEAT-65: the profile to enter without the picker at cold launch, or nil to show the picker.
    /// Reads the repository's state SYNCHRONOUSLY (call `start()` first so a guest's cached
    /// payload is loaded; a real account's cache is keyed to its user by `AuthViewModel`'s
    /// `ensureLoaded` before the gate turns `.main`). The rule is `ProfileAutoEnter.decision`.
    func rememberedStartupProfile(alreadyFiredThisLaunch: Bool) -> NuvioProfile? {
        guard let state = ProfileRepository.shared.state.value_ as? ProfileState else { return nil }
        let enabled = ProfileAutoEnter.debugEnabledOverride() ?? state.rememberLastProfileEnabled
        let activeId = ProfileRepository.shared.activeProfileId
        let active = state.profiles.first { $0.profileIndex == activeId }
        guard ProfileAutoEnter.decision(enabled: enabled,
                                        everSelected: state.hasEverSelectedProfile,
                                        activeProfileExists: active != nil,
                                        pinEnabled: active?.pinEnabled ?? false,
                                        alreadyFiredThisLaunch: alreadyFiredThisLaunch) else { return nil }
        return active
    }

    func createProfile(
        name: String,
        colorHex: String,
        avatarId: String? = nil,
        avatarUrl: String? = nil,
        completion: @escaping () -> Void
    ) {
        isBusy = true
        ProfileRepository.shared.createProfile(
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
        _ profile: NuvioProfile,
        name: String,
        colorHex: String,
        avatarId: String? = nil,
        avatarUrl: String? = nil,
        completion: @escaping () -> Void
    ) {
        isBusy = true
        ProfileRepository.shared.updateProfile(
            profileIndex: profile.profileIndex,
            name: name,
            avatarColorHex: colorHex,
            avatarId: avatarId,
            avatarUrl: avatarUrl,
            usesPrimaryAddons: profile.usesPrimaryAddons
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isBusy = false
                completion()
            }
        }
    }

    // MARK: - PIN (cloud accounts only; RPCs verify/set/clear server-side)

    /// Verifies a profile PIN. Falls back to the shared local cache when offline.
    func verifyPin(_ profile: NuvioProfile, pin: String, completion: @escaping (PinVerifyResult?) -> Void) {
        ProfileRepository.shared.verifyPin(profileIndex: profile.profileIndex, pin: pin) { result, _ in
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Sets (or changes, when `currentPin` is provided) a profile's 4-digit PIN.
    func setPin(profileIndex: Int32, pin: String, currentPin: String?, completion: @escaping (PinVerifyResult?) -> Void) {
        ProfileRepository.shared.setPin(profileIndex: profileIndex, pin: pin, currentPin: currentPin) { result, _ in
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Removes a profile's PIN lock (requires the current PIN).
    func clearPin(profileIndex: Int32, currentPin: String?, completion: @escaping (PinVerifyResult?) -> Void) {
        ProfileRepository.shared.clearPin(profileIndex: profileIndex, currentPin: currentPin) { result, _ in
            DispatchQueue.main.async { completion(result) }
        }
    }

    func deleteProfile(_ profile: NuvioProfile, completion: @escaping () -> Void = {}) {
        ProfileRepository.shared.deleteProfile(profileIndex: profile.profileIndex) { _ in
            DispatchQueue.main.async { completion() }
        }
    }

    deinit {
        watcher?.cancel()
        avatarsWatcher?.cancel()
        authWatcher?.cancel()
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
