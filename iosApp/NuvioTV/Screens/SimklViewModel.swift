import Combine
import SharedCore

/// Backs the Settings "Simkl" section. Wraps the shared `SimklAuthRepository` PIN-code flow:
/// `connect()` asks Simkl for a user code — the repo publishes it (plus the verification URL) via
/// its uiState and polls `/oauth/pin/{user_code}` in the background until the user approves the
/// code at simkl.com/pin on another device (or it expires). Once connected, Simkl becomes usable
/// as a Library Source / Watch Progress Source (Content Sources pane) and scrobbles automatically
/// as you play (`SimklAuthRepository` registers the same SCROBBLE capability Trakt does).
///
/// Structurally a clone of `TraktViewModel` — same published shape, same start/stop/connect/
/// cancelActivation/disconnect surface — so the Settings pane can render both with one card layout.
@MainActor
final class SimklViewModel: ObservableObject {
    @Published private(set) var credentialsConfigured = true
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var username: String?
    /// Non-nil while a PIN flow is pending approval — drives the activation card.
    @Published private(set) var deviceUserCode: String?
    @Published private(set) var deviceVerificationUrl: String?
    @Published private(set) var errorMessage: String?

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        SimklAuthRepository.shared.ensureLoaded(profileId: ProfileRepository.shared.activeProfileId)
        watcher = FlowWatcherKt.watch(SimklAuthRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? SimklAuthUiState else { return }
            self.credentialsConfigured = state.credentialsConfigured
            self.isConnected = state.mode == .connected
            self.isLoading = state.isLoading
            self.username = state.username
            self.deviceUserCode = state.deviceUserCode
            self.deviceVerificationUrl = state.deviceVerificationUrl
            let error = state.errorMessage ?? ""
            self.errorMessage = error.isEmpty ? nil : error
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        // Note: an in-flight PIN flow keeps polling inside the shared repo even while
        // unsubscribed, so leaving Settings mid-activation doesn't abort the sign-in.
    }

    func connect() {
        SimklAuthRepository.shared.onStartDeviceFlow(profileId: ProfileRepository.shared.activeProfileId)
    }

    func cancelActivation() {
        SimklAuthRepository.shared.onCancelDeviceFlow(profileId: ProfileRepository.shared.activeProfileId)
    }

    func disconnect() {
        SimklAuthRepository.shared.onDisconnectRequested(profileId: ProfileRepository.shared.activeProfileId)
    }
}
