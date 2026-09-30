import Combine
import Foundation
import SharedCore

/// Backs the Settings "MDBList" section. Wraps `MdbListTracker.shared`'s device-authorization
/// account flow: `connect()` starts (or resumes) a device authorization, the shared controller
/// publishes the user code + verification URL through `accountUiState` and polls in the
/// background until the user approves on another device (or the code expires/is denied).
/// Cloned from `SimklViewModel`'s shape (start/stop/connect/cancel/disconnect).
///
/// Uses the throw-safe `*Checked` / `*Safely` bridging twins from `MdbListAccountControllerBridging.kt`
/// — a raw Kotlin exception crossing into Swift would abort the process.
@MainActor
final class MdbListViewModel: ObservableObject {
    @Published private(set) var hasClientId = true
    @Published private(set) var isConnected = false
    @Published private(set) var username: String?
    @Published private(set) var isSupporter = false
    /// Non-nil while a device authorization is pending approval — drives the activation card.
    @Published private(set) var userCode: String?
    @Published private(set) var verificationUrl: String?
    @Published private(set) var isAwaitingApproval = false
    @Published private(set) var isBusy = false
    @Published private(set) var revokeFailed = false
    @Published private(set) var errorMessage: String?

    private var watcher: FlowWatcher?
    /// Failure of our own bridged call (account changed mid-call etc.); shown when the shared
    /// state carries no error of its own. Cleared on the next action.
    private var localError: String?
    private var lastState: MdbListAccountUiState?

    func start() {
        guard watcher == nil else { return }
        MdbListTracker.shared.ensureLoaded(profileId: ProfileRepository.shared.activeProfileId)
        watcher = FlowWatcherKt.watch(MdbListTracker.shared.accountUiState) { [weak self] emitted in
            guard let self, let state = emitted as? MdbListAccountUiState else { return }
            self.lastState = state
            self.publish(state)
        }
        // Card reappeared with a still-valid pending authorization: make sure it is polling.
        _ = MdbListTracker.shared.account.resumePollingSafely()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        // A pending authorization keeps polling inside the shared controller while unsubscribed,
        // so leaving Settings mid-activation does not abort the sign-in.
    }

    func connect() {
        guard !isBusy else { return }
        localError = nil
        republish()
        Task { @MainActor in
            do {
                _ = try await MdbListTracker.shared.account.connectChecked()
            } catch {
                self.localError = String(localized: "Couldn't start MDBList sign-in. Try again.")
                self.republish()
            }
        }
    }

    func cancel() {
        localError = nil
        _ = MdbListTracker.shared.account.cancelSafely()
    }

    func disconnect() {
        guard !isBusy else { return }
        localError = nil
        republish()
        Task { @MainActor in
            do {
                try await MdbListTracker.shared.account.disconnectChecked()
            } catch {
                self.localError = String(localized: "Couldn't disconnect MDBList. Try again.")
                self.republish()
            }
        }
    }

    private func republish() {
        if let lastState { publish(lastState) }
    }

    private func publish(_ state: MdbListAccountUiState) {
        // A connection that just completed is a successful action: drop any error left over from
        // before it (e.g. a failed first connect attempt) so it can't surface under Disconnect.
        if state.isConnected && !isConnected { localError = nil }
        hasClientId = state.hasClientId
        isConnected = state.isConnected
        username = state.username
        isSupporter = state.isSupporter
        userCode = state.userCode
        verificationUrl = state.verificationUrl
        isAwaitingApproval = state.isAwaitingApproval
        isBusy = state.isBusy
        revokeFailed = state.revokeFailed
        // Connected accounts don't show stale shared-state errors (revokeFailed has its own
        // subtitle), but our own failed call — a disconnect that threw — must stay visible; the
        // pane renders it as a caption under the Disconnect row. Cleared by the next action.
        if state.isConnected {
            errorMessage = localError
        } else {
            errorMessage = Self.message(auth: state.authErrorKind, sync: state.errorKind) ?? localError
        }
    }

    private static func message(auth: String?, sync: String?) -> String? {
        for kind in [auth, sync] {
            guard let kind, !kind.isEmpty else { continue }
            switch kind {
            case "MISSING_CLIENT_ID": return String(localized: "MDBList isn't configured in this build.")
            case "CODE_EXPIRED": return String(localized: "The code expired. Try again.")
            case "ACCESS_DENIED": return String(localized: "Access was denied.")
            case "AUTHORIZATION_REVOKED": return String(localized: "MDBList access was revoked. Connect again.")
            case "INSUFFICIENT_SCOPE": return String(localized: "The account didn't grant the needed permissions.")
            case "RATE_LIMIT": return String(localized: "MDBList is rate limiting requests. Try again later.")
            case "UNAVAILABLE": return String(localized: "MDBList is unavailable right now.")
            case "INVALID_RESPONSE": return String(localized: "MDBList returned an unexpected response.")
            default: continue
            }
        }
        return nil
    }
}
