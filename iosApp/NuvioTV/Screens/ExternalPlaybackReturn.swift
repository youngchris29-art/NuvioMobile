import Foundation
import SharedCore

/// The URL scheme an external player (Infuse) must call back on to reach THIS install.
///
/// `nuviotv` is registered by every build of this app that has ever been sideloaded onto a box
/// (the dev `com.youngchris29.NuvioTV` install and an older `com.nuvio.media.NuvioTV` one both
/// sit on Christian's Apple TV), and tvOS resolves a shared scheme to whichever app it likes — so an
/// Infuse `x-success` on `nuviotv://` could land in the wrong install. `Info.plist` therefore also
/// registers `$(PRODUCT_BUNDLE_IDENTIFIER)` as a second scheme, unique per install. It is read back
/// from the plist rather than from `Bundle.main.bundleIdentifier`: a re-signing tool can rewrite the
/// bundle id while the SYSTEM registers whatever the plist's `CFBundleURLSchemes` says, and that is
/// the string that actually routes. Top Shelf keeps `nuviotv`.
enum AppCallbackScheme {
    static let topShelfScheme = "nuviotv"

    static let value: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return pick(from: types ?? [])
    }()

    /// The first registered scheme that is not the shared Top Shelf one, or `nuviotv` when the
    /// plist carries nothing else. Pure, so it is unit-testable without a bundle.
    static func pick(from urlTypes: [[String: Any]]) -> String {
        let schemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        return schemes.first { $0.caseInsensitiveCompare(topShelfScheme) != .orderedSame } ?? topShelfScheme
    }
}

/// Routes the x-callback return an external player (Infuse) opens on this install's own scheme to
/// the shared `ExternalPlaybackReturn`, which matches it to the session `StreamPickerView`
/// prepared, records the reported position, and clears the session.
///
///   `<scheme>://external-player/infuse/<sessionId>/success?lastPlayedUrl=…&position=<seconds>`
///   `<scheme>://external-player/infuse/<sessionId>/error?…`
///
/// `ContentView.handleDeepLink` asks `isCallback` before it ever calls `DeepLink.parse`, so a
/// callback is consumed here and never assigns `deepLink` (an unrecognised URL used to nil it and
/// close an open Top Shelf cover).
enum ExternalPlaybackReturnRouter {
    /// The host every external-player callback carries (`ExternalPlaybackCallbacks.HOST`).
    static let callbackHost = "external-player"

    enum Outcome: Equatable {
        case success
        case error
    }

    /// True for an external-player callback on this install's scheme, or on the shared Top Shelf
    /// scheme (a stale or other-install callback must still be swallowed here rather than reach
    /// `DeepLink`; the shared handler then rejects it, because it only claims the scheme the
    /// pending session was launched with).
    static func isCallback(_ url: URL) -> Bool {
        isCallback(url, callbackScheme: AppCallbackScheme.value)
    }

    /// Pure core of `isCallback`, so tests do not depend on the host bundle's plist.
    static func isCallback(_ url: URL, callbackScheme: String) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.lowercased() == callbackHost else { return false }
        return scheme == callbackScheme.lowercased() || scheme == AppCallbackScheme.topShelfScheme
    }

    /// `success` / `error` from the callback's last path segment, nil for any other shape
    /// (`/<playerId>/<sessionId>/<outcome>` is exactly three segments).
    static func outcome(of url: URL) -> Outcome? {
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 3 else { return nil }
        switch segments[2].lowercased() {
        case "success": return .success
        case "error": return .error
        default: return nil
        }
    }

    /// Hands `url` to the shared handler (non-suspend and non-throwing, so called directly; it
    /// writes the watch progress itself with `syncRemote = true`, which also pushes it). Returns
    /// whether the shared handler consumed it.
    ///
    /// After a consumed `success` it requests an activity pull through
    /// `SyncManager.requestForegroundPull` (non-forced, so its freshness gate and 2.5 s delay
    /// apply, the same call the `.active` scene-phase path makes): `SyncManager` has no separate
    /// push entry point, and that call refreshes the active watch source so Continue Watching
    /// shows the position just recorded. The lastPlayedUrl is never logged (it can carry a
    /// debrid link).
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        let consumed = ExternalPlaybackReturn.shared.handleUrl(url: url.absoluteString, scheme: AppCallbackScheme.value)
        guard consumed else {
            NSLog("[ExtReturn] ignored %@ (not the pending session's callback)", url.path)
            return false
        }
        NSLog("[ExtReturn] consumed %@", url.path)
        if Self.outcome(of: url) == .success {
            SyncManager.shared.requestForegroundPull(
                profileId: ProfileRepository.shared.activeProfileId,
                force: false
            )
        }
        return true
    }
}
