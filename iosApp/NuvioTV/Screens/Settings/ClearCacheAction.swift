import SwiftUI

/// GitHub #34: the Clear Cache confirm action, outside the view so it is unit-testable with an
/// injected clearer. One synchronous main-actor call with no task, callback or in-progress state:
/// the failed-artwork list is empty when it returns, and the system releases both caches' disk
/// storage shortly after (see `ArtworkDiskCacheClearer`).
enum ClearCacheAction {
    static func run(_ clearer: ArtworkDiskCacheClearer) {
        clearer.clear()
        ClearCacheAnnouncer.post(String(localized: "Cache cleared"))
    }
}

/// Where the "Cache cleared" announcement goes: VoiceOver; tests swap it to capture what would be
/// spoken (the same shape as `HubAccessibility.post`).
enum ClearCacheAnnouncer {
    static var post: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
}
