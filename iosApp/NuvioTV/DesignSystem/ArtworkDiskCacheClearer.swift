import Foundation

/// GitHub #34: what Settings › About › Clear Cache does, and the one type the tests exercise.
///
/// It empties the two artwork disk caches (artwork and GIF, each a `URLCache` in its own
/// `Library/Caches` directory) and the failed-artwork list. It deletes no path and never touches
/// `URLCache.shared`, the decoded-image pools (`ArtworkMemory`, `sourceSizes`, the decoded GIFs),
/// payload stores, playback caches, the Top Shelf snapshot, settings or account data. Production
/// builds it only in `ArtworkStore.diskCacheClearer`; tests inject their own caches and memo.
///
/// What is true when `clear()` returns: the failed-artwork list is empty. Each cache's disk storage
/// is released by the system asynchronously, shortly after the call (about 0.1 s on the simulator).
/// `removeAllCachedResponses()` does not purge a `URLCache`'s own in-memory response store, so a
/// recently loaded image may still be answered from memory until that store evicts it or the app
/// relaunches. A request already in flight may also store a response, or record a failure, after
/// `clear()` returns.
struct ArtworkDiskCacheClearer {            // main-actor by default
    let artworkCache: URLCache
    let gifCache: URLCache
    let failures: ArtworkFailureMemo

    /// One synchronous call, made from the alert's confirm action. Nothing outlives it. With
    /// `debug.artworkProbe` on, it logs one `artwork_clear` line (`ArtworkProbe`).
    func clear() {
        let probe = ArtworkProbe.beginClear(artworkCache: artworkCache, gifCache: gifCache, failures: failures)
        failures.removeAll()
        artworkCache.removeAllCachedResponses()
        gifCache.removeAllCachedResponses()
        ArtworkProbe.endClear(probe, artworkCache: artworkCache, gifCache: gifCache)
    }
}
