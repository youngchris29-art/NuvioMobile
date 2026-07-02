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

    /// Max profiles supported by the shared repository (`MAX_PROFILES`).
    let maxProfiles = 6

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        ProfileRepository.shared.loadCachedProfiles()
        watcher = FlowWatcherKt.watch(ProfileRepository.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? ProfileState else { return }
            self.profiles = state.profiles
            self.activeProfile = state.activeProfile
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Actions

    func select(_ profile: NuvioProfile) {
        ProfileRepository.shared.selectProfile(profileIndex: profile.profileIndex)
        // Full cloud pull for the selected profile (addons first, then the rest in parallel).
        // Self-guarding: no-op in guest mode / signed out, so the local-only flow is unchanged.
        SyncManager.shared.pullAllForProfile(profileId: profile.profileIndex)
    }

    func createProfile(name: String, colorHex: String, completion: @escaping () -> Void) {
        isBusy = true
        ProfileRepository.shared.createProfile(
            name: name,
            avatarColorHex: colorHex,
            avatarId: nil,
            avatarUrl: nil,
            usesPrimaryAddons: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isBusy = false
                completion()
            }
        }
    }

    func updateProfile(_ profile: NuvioProfile, name: String, colorHex: String, completion: @escaping () -> Void) {
        isBusy = true
        ProfileRepository.shared.updateProfile(
            profileIndex: profile.profileIndex,
            name: name,
            avatarColorHex: colorHex,
            avatarId: nil,
            avatarUrl: nil,
            usesPrimaryAddons: profile.usesPrimaryAddons
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isBusy = false
                completion()
            }
        }
    }

    func deleteProfile(_ profile: NuvioProfile, completion: @escaping () -> Void = {}) {
        ProfileRepository.shared.deleteProfile(profileIndex: profile.profileIndex) { _ in
            DispatchQueue.main.async { completion() }
        }
    }

    deinit { watcher?.cancel() }
}
