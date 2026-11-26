import Foundation
import SharedCore

/// Scope identity W2 (spec 4.6): the synchronous revocation the barrier runs before every drain,
/// apply, wipe and account publish. Called from the barrier lane or the auth lane (off main) and,
/// at most, from main; the body always runs on the main thread before this returns. Installed in
/// `NuvioTVApp.init`, before `ContentView` exists and before auth starts.
///
/// Why `main.sync` cannot deadlock (5.11): the caller holds no synchronous identity lock when it
/// revokes, and main never waits for a thread that is revoking.
nonisolated final class IdentityRevokerImpl: NSObject, IdentityRevoker {
    /// The main-thread body; `IdentityModel.shared.revoke` in the app, a fake in tests.
    private let body: @MainActor (IdentityState) -> Bool

    init(body: @escaping @MainActor (IdentityState) -> Bool = { IdentityModel.shared.revoke($0) }) {
        self.body = body
    }

    func revoke(state: IdentityState) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(state) }
        }
        var result = false
        DispatchQueue.main.sync {
            result = MainActor.assumeIsolated { body(state) }
        }
        return result
    }
}
