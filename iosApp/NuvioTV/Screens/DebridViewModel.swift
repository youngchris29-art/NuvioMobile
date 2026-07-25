import Combine
import Foundation
import SharedCore

/// Native debrid settings for tvOS, backed entirely by the shared debrid stack (Batch 4d):
/// `DebridSettingsRepository` (per-profile settings, synced via the "tv" settings blob),
/// `DebridProviders` (Torbox / Premiumize visible; both device-code capable) and
/// `DebridProviderApis` (device-authorization start/redeem + key validation).
///
/// Once a key is saved and `enabled` is on, the shared `StreamsRepository` resolves cached
/// torrent results into direct links by itself — no player/stream-picker changes needed.
///
/// Device flow (mirrors mobile's `DebridSettingsPage`): `startDeviceAuthorization("Nuvio")`
/// → show user code + verification URL → poll `redeemDeviceAuthorization(deviceCode:)` every
/// `intervalSeconds` → Authorized(token) saved as the provider's API key. Thrown redeems are
/// treated as Pending (transient network) with a hard deadline bounding the loop.
@MainActor
final class DebridViewModel: ObservableObject {
    enum AuthPhase: Equatable {
        case idle
        case starting
        case waiting
        case failed(String)
    }

    @Published private(set) var settings: DebridSettings?
    /// Provider currently running a device-auth flow (nil = none).
    @Published private(set) var authProviderId: String?
    @Published private(set) var authPhase: AuthPhase = .idle
    @Published private(set) var activeSession: DebridDeviceAuthorization?

    /// UI-visible providers (Torbox, Premiumize — Real-Debrid is `visibleInUi = false` upstream).
    let providers: [DebridProvider] = DebridProviders.shared.visible()

    private var settingsWatcher: FlowWatcher?
    private var pollTask: Task<Void, Never>?

    /// Bounds the redeem-poll loop when errors are persistent rather than transient.
    private static let pollDeadlineSeconds: TimeInterval = 10 * 60

    func start() {
        guard settingsWatcher == nil else { return }
        DebridSettingsRepository.shared.ensureLoaded()
        settingsWatcher = FlowWatcherKt.watch(DebridSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? DebridSettings else { return }
            self.settings = value
        }
    }

    func stop() {
        settingsWatcher?.cancel()
        settingsWatcher = nil
        cancelActivation()
    }

    // MARK: - Derived state

    func isConnected(_ providerId: String) -> Bool {
        guard let settings else { return false }
        return !settings.apiKeyFor(providerId: providerId)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAnyKey: Bool { settings?.hasAnyApiKey ?? false }
    var resolverEnabled: Bool { settings?.enabled ?? false }

    var activeResolverId: String? {
        guard let settings else { return nil }
        let id: String? = settings.activeResolverProviderId
        return id
    }

    /// Providers currently able to act as the link resolver (connected + resolve-capable).
    var resolverProviders: [DebridProvider] {
        settings?.resolverServices.map { $0.provider } ?? []
    }

    // MARK: - Settings actions

    func setResolverEnabled(_ value: Bool) {
        DebridSettingsRepository.shared.setEnabled(value: value)
    }

    func setPreferredResolver(_ providerId: String) {
        DebridSettingsRepository.shared.setPreferredResolverProviderId(providerId: providerId)
    }

    func saveManualKey(_ providerId: String, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DebridSettingsRepository.shared.setProviderApiKey(providerId: providerId, value: trimmed)
        DebridSettingsRepository.shared.setEnabled(value: true)
    }

    func disconnect(_ providerId: String) {
        DebridSettingsRepository.shared.setProviderApiKey(providerId: providerId, value: "")
    }

    // MARK: - Device-code authorization

    func connect(_ provider: DebridProvider) {
        guard authProviderId == nil else { return }
        guard let api = DebridProviderApis.shared.apiFor(providerId: provider.id) else {
            authProviderId = provider.id
            authPhase = .failed(String(localized: "Device sign-in isn't available for \(provider.displayName). Use manual API key entry below."))
            return
        }
        authProviderId = provider.id
        authPhase = .starting
        activeSession = nil

        api.startDeviceAuthorization(appName: "Nuvio") { [weak self] session, error in
            DispatchQueue.main.async {
                guard let self, self.authProviderId == provider.id else { return }
                guard let session else {
                    let message = error?.localizedDescription ?? ""
                    self.authPhase = .failed(
                        message.contains("PREMIUMIZE_CLIENT_ID")
                            ? String(localized: "Device sign-in isn't configured in this build (missing PREMIUMIZE_CLIENT_ID). Paste an API key from your Premiumize account instead.")
                            : String(localized: "Couldn't start device sign-in. Try again, or paste an API key manually below.")
                    )
                    return
                }
                self.activeSession = session
                self.authPhase = .waiting
                self.beginPolling(session: session, providerId: provider.id)
            }
        }
    }

    func cancelActivation() {
        pollTask?.cancel()
        pollTask = nil
        authProviderId = nil
        authPhase = .idle
        activeSession = nil
    }

    private enum RedeemOutcome {
        case authorized(String)
        case pending
        case expired
        case failed(String?)
    }

    private func beginPolling(session: DebridDeviceAuthorization, providerId: String) {
        pollTask?.cancel()
        let intervalSeconds = max(Int(session.intervalSeconds), 1)
        pollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.pollDeadlineSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let outcome = await self.redeem(providerId: providerId, deviceCode: session.deviceCode)
                guard !Task.isCancelled else { return }

                switch outcome {
                case .authorized(let token):
                    DebridSettingsRepository.shared.setProviderApiKey(providerId: providerId, value: token)
                    DebridSettingsRepository.shared.setEnabled(value: true)
                    self.cancelActivation()
                    return
                case .pending:
                    if Date() > deadline {
                        self.authPhase = .failed(String(localized: "Timed out waiting for approval. Try again."))
                        self.activeSession = nil
                        return
                    }
                case .expired:
                    self.authPhase = .failed(String(localized: "The code expired before it was approved. Try again."))
                    self.activeSession = nil
                    return
                case .failed(let message):
                    self.authPhase = .failed(message ?? String(localized: "Sign-in failed. Try again, or paste an API key manually below."))
                    self.activeSession = nil
                    return
                }
            }
        }
    }

    /// One redeem attempt. A completion error (thrown Kotlin exception → NSError) is treated as
    /// Pending — mobile-parity: transient connectivity mid-approval shouldn't kill the flow; the
    /// poll deadline bounds persistent failure.
    private func redeem(providerId: String, deviceCode: String) async -> RedeemOutcome {
        guard let api = DebridProviderApis.shared.apiFor(providerId: providerId) else {
            return .failed(nil)
        }
        return await withCheckedContinuation { continuation in
            api.redeemDeviceAuthorization(deviceCode: deviceCode) { result, _ in
                let outcome: RedeemOutcome
                if let authorized = result as? DebridDeviceAuthorizationTokenResultAuthorized {
                    outcome = .authorized(authorized.accessToken)
                } else if result is DebridDeviceAuthorizationTokenResultExpired {
                    outcome = .expired
                } else if let failed = result as? DebridDeviceAuthorizationTokenResultFailed {
                    let message: String? = failed.message
                    outcome = .failed(message)
                } else if result is DebridDeviceAuthorizationTokenResultUnsupported {
                    outcome = .failed(String(localized: "Device sign-in isn't supported for this provider."))
                } else {
                    outcome = .pending
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    deinit {
        settingsWatcher?.cancel()
        pollTask?.cancel()
    }
}
