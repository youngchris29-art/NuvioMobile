import Combine
import ImageIO
import os
import SwiftUI
import UIKit

/// A lightweight, dependency-free replacement for SwiftUI's `AsyncImage`.
///
/// `AsyncImage` re-fetches on every scroll and keeps no disk cache, which on a poster-heavy tvOS
/// grid causes constant flicker and network churn. `CachedAsyncImage` adds an in-memory `NSCache`
/// plus a dedicated on-disk `URLCache`, shows a shimmer while loading, a film-icon on failure, and
/// fades the image in. Swap it in anywhere the app currently uses `AsyncImage` for content art.
struct CachedAsyncImage<Failure: View>: View {
    private let url: URL?
    /// Custom-poster-URL feature: the ORIGINAL art tried once when `url` (a user-pattern URL that
    /// may 404 for a title the poster service doesn't know) fails. nil = no fallback.
    private let fallbackURL: URL?
    private let contentMode: ContentMode
    /// beta.19-rc1 verdict (I1, BUG-134): how large the image is decoded (see `ArtworkDecodeSize`).
    /// `.legacy` (the default) is the old 1920 px cap, so every call site that has not opted in
    /// decodes and caches exactly as before.
    private let decodeSize: ArtworkDecodeSize
    /// beta.19-rc1 verdict (I1): the attempt order, computed once at init. With an `upgrade` role
    /// that applies to `url` it is `[upgraded(url), url, fallback]` (deduped, at most three), so a
    /// title whose larger file is missing still shows the original one; without it, today's
    /// `[url, fallback]`.
    private let candidateURLs: [URL]
    /// beta.19-rc1 verdict (I1): when true, `.onDisappear` drops the loaded image and the next
    /// `.onAppear` reloads it (normally a memory hit). Detail's backdrop sets it so a 10-deep Detail
    /// stack does not pin ten 33 MB bitmaps outside the cache (critique #23e).
    private let releasesWhenHidden: Bool
    /// BUG-59 (reveal-gate wave): when true, the loaded image is scanned once for letterbox/
    /// pillarbox bars baked into its pixels (`ArtworkLetterbox` — TMDB backdrops are sometimes
    /// trailer stills, bars and all) and overscaled to crop them. OFF by default so every existing
    /// call site renders byte-identically; the caller that turns it on (the inline trailer tile)
    /// must clip, exactly as it must for the video zoom underneath (`InlineTrailerCard`'s
    /// `.clipShape`).
    private let cropsBakedLetterboxBars: Bool
    /// BUG-41: what to show once `loader.failed` is true. Defaults to `DefaultFailureImage` (the
    /// grey surface + film glyph every call site rendered before this parameter existed) via the
    /// `Failure == DefaultFailureImage` initializers below, so every pre-existing call site keeps
    /// compiling — and rendering — unchanged. Callers with a more meaningful fallback (a title, a
    /// person glyph, a company name) pass their own `failure:` builder instead.
    private let failureContent: () -> Failure
    /// beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): optional hook run once per loaded
    /// image (see `onImageLoaded`). nil = zero cost; every existing call site leaves it nil.
    private var onLoaded: (@MainActor (UIImage) -> Void)?

    @StateObject private var loader = CachedImageLoader()
    /// 1.0 until (and unless) `ArtworkLetterbox` measures real bars in the loaded image.
    @State private var barCropZoom: CGFloat = 1
    /// beta.19-rc1 verdict (I1): the decode request is points × this scale, so a 1080p TV (scale 1)
    /// and a 4K Apple TV (scale 2) each decode what they draw.
    @Environment(\.displayScale) private var displayScale

    init(url: URL?, fallbackURL: URL? = nil, contentMode: ContentMode = .fill,
         decodeSize: ArtworkDecodeSize = .legacy, upgrade: ArtworkURLUpgrade.Role? = nil,
         releasesWhenHidden: Bool = false, cropsBakedLetterboxBars: Bool = false,
         @ViewBuilder failure: @escaping () -> Failure) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.contentMode = contentMode
        self.decodeSize = decodeSize
        self.candidateURLs = Self.makeCandidates(url: url, fallback: fallbackURL, upgrade: upgrade)
        self.releasesWhenHidden = releasesWhenHidden
        self.cropsBakedLetterboxBars = cropsBakedLetterboxBars
        self.failureContent = failure
    }

    /// Convenience for the many Kotlin-bridged `String` URL fields; empty/nil → no image.
    init(string: String?, fallback: String? = nil, contentMode: ContentMode = .fill,
         decodeSize: ArtworkDecodeSize = .legacy, upgrade: ArtworkURLUpgrade.Role? = nil,
         releasesWhenHidden: Bool = false, cropsBakedLetterboxBars: Bool = false,
         @ViewBuilder failure: @escaping () -> Failure) {
        let primary: URL?
        if let string, !string.isEmpty {
            primary = URL(string: string)
        } else {
            primary = nil
        }
        let fallbackURL: URL?
        if let fallback, !fallback.isEmpty {
            fallbackURL = URL(string: fallback)
        } else {
            fallbackURL = nil
        }
        self.url = primary
        self.fallbackURL = fallbackURL
        self.contentMode = contentMode
        self.decodeSize = decodeSize
        self.candidateURLs = Self.makeCandidates(url: primary, fallback: fallbackURL, upgrade: upgrade)
        self.releasesWhenHidden = releasesWhenHidden
        self.cropsBakedLetterboxBars = cropsBakedLetterboxBars
        self.failureContent = failure
    }

    /// `[upgraded(url), url, fallback]` (see `candidateURLs`), computed once per init rather than per
    /// body evaluation.
    private static func makeCandidates(url: URL?, fallback: URL?, upgrade: ArtworkURLUpgrade.Role?) -> [URL] {
        var upgraded: URL?
        if let upgrade, let url {
            upgraded = ArtworkURLUpgrade.upgraded(url, role: upgrade)
        }
        return ImageFallbackPlan.candidates(upgraded: upgraded, primary: url, fallback: fallback)
    }

    /// beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): chained setter for a post-load hook.
    /// `action` runs on the main actor each time a new decoded image lands (the same moment the
    /// letterbox crop task keys on), BEFORE the crop logic. `ArtworkStore` has already put the image
    /// in memory by then, so `ArtworkStore.cachedImage(for:)` hits. Returns a copy; the inits are
    /// untouched.
    func onImageLoaded(_ action: @escaping @MainActor (UIImage) -> Void) -> CachedAsyncImage {
        var copy = self
        copy.onLoaded = action
        return copy
    }

    /// beta.19-rc1 verdict (I1): the candidates plus the decode request. A change of either (a new
    /// URL, a different drawn size, a scale change) resets the load.
    private var chain: ImageURLChain {
        ImageURLChain(
            urls: candidateURLs,
            request: ArtworkDecodeRequest(size: decodeSize, fill: contentMode == .fill, scale: displayScale).normalized
        )
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // `scaleEffect(1)` is the identity for every call site that doesn't opt in.
                    .scaleEffect(barCropZoom)
            } else if loader.failed {
                failureContent()
            } else if url == nil {
                // Nothing to load — flat surface rather than an endless shimmer.
                Theme.Palette.surface
            } else {
                ShimmerView()
            }
        }
        .onAppear { loader.load(chain) }
        .onDisappear {
            // beta.19-rc1 verdict (I1): only the Detail backdrop opts in. The image reloads on the
            // next `.onAppear`, normally from the memory cache.
            if releasesWhenHidden { loader.release() }
        }
        .onChange(of: chain) { _, newChain in
            loader.load(newChain)
        }
        // BUG-59: measure the loaded image's baked bars off-main, once per URL (memoized in
        // `ArtworkLetterbox`). Keyed on the image (NSObject identity) so a URL change that swaps
        // the image re-runs, and a re-render that doesn't, doesn't.
        .task(id: loader.image) {
            if let loaded = loader.image { onLoaded?(loaded) }
            guard cropsBakedLetterboxBars else { return }
            guard let image = loader.image, let key = url?.absoluteString else {
                barCropZoom = 1
                return
            }
            if let hit = ArtworkLetterbox.cachedZoom(forKey: key) {
                barCropZoom = hit
                return
            }
            let measured = await Task.detached(priority: .utility) {
                ArtworkLetterbox.zoom(for: image, cacheKey: key)
            }.value
            guard !Task.isCancelled, loader.image === image else { return }
            withAnimation(.easeOut(duration: 0.25)) { barCropZoom = measured }
        }
    }
}

extension CachedAsyncImage where Failure == DefaultFailureImage {
    /// Every call site that predates BUG-41's `failure:` parameter — unchanged signature, unchanged
    /// grey-surface-plus-film-glyph rendering on a failed load.
    init(url: URL?, fallbackURL: URL? = nil, contentMode: ContentMode = .fill,
         decodeSize: ArtworkDecodeSize = .legacy, upgrade: ArtworkURLUpgrade.Role? = nil,
         releasesWhenHidden: Bool = false, cropsBakedLetterboxBars: Bool = false) {
        self.init(url: url, fallbackURL: fallbackURL, contentMode: contentMode, decodeSize: decodeSize,
                  upgrade: upgrade, releasesWhenHidden: releasesWhenHidden,
                  cropsBakedLetterboxBars: cropsBakedLetterboxBars, failure: { DefaultFailureImage() })
    }

    init(string: String?, fallback: String? = nil, contentMode: ContentMode = .fill,
         decodeSize: ArtworkDecodeSize = .legacy, upgrade: ArtworkURLUpgrade.Role? = nil,
         releasesWhenHidden: Bool = false, cropsBakedLetterboxBars: Bool = false) {
        self.init(string: string, fallback: fallback, contentMode: contentMode, decodeSize: decodeSize,
                  upgrade: upgrade, releasesWhenHidden: releasesWhenHidden,
                  cropsBakedLetterboxBars: cropsBakedLetterboxBars, failure: { DefaultFailureImage() })
    }
}

/// The pre-BUG-41 failure surface (grey `Theme.Palette.surface` + a film glyph) — content art has
/// no more specific fallback to offer, so this stays the default for every caller that doesn't pass
/// its own `failure:` builder.
struct DefaultFailureImage: View {
    var body: some View {
        ZStack {
            Theme.Palette.surface
            Image(systemName: "film")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// Shared artwork pipeline behind `CachedAsyncImage` (and the Home hero's logo/backdrop
/// prefetcher): a process-wide decoded-image memory cache, a dedicated disk-backed session,
/// ImageIO downsampling, and in-flight request coalescing so concurrent views (or a prefetch
/// plus a view) never download the same URL twice.
enum ArtworkFetchError: Error {
    case http(Int)
    case notImage
}

/// beta.19-rc1 verdict (I1, BUG-134): one URL plus the decode it wants, for the typed
/// `ArtworkStore.prefetch(_:)`.
struct ArtworkPrefetchItem {
    let url: URL
    let decode: ArtworkDecodeRequest
}

enum ArtworkStore {
    /// beta.19-rc1 verdict (I1, BUG-134): two byte-sized pools replace the old single
    /// 400-item / 128 MB cache. `small` holds poster-size decodes (under `largePoolThreshold`
    /// decoded bytes), `large` holds full-bleed ones (a 4K RGBA backdrop is ~33 MB decoded). Bounded
    /// by decoded bytes, not just count (HI-006), and the large pool is bounded separately so a
    /// row's worth of 1920 px prefetches cannot evict the carousel (critique #2). Worst case is
    /// the sum of the two, 384 MB against 128 MB before; the device `avail` check decides, and if it
    /// fails halve both constants.
    nonisolated static let smallPoolBytes = 192 * 1024 * 1024
    nonisolated static let largePoolBytes = 192 * 1024 * 1024

    /// Process-wide in-memory decoded-image cache (`ArtworkMemory`). Thread-safe, hence `nonisolated`
    /// for synchronous first-frame lookups from view inits.
    nonisolated private static let memory = ArtworkMemory(smallLimitBytes: smallPoolBytes,
                                                          largeLimitBytes: largePoolBytes)

    /// Pixel size of each URL's source image, recorded by the decode that learned it. Lets a later
    /// lookup compute the bucket a decode was stored under (`ArtworkDecodeMath.storeBucket`). An
    /// `NSCache`, so it evicts entry by entry, never all at once (critique #3).
    nonisolated(unsafe) private static let sourceSizes: NSCache<NSURL, NSValue> = {
        let cache = NSCache<NSURL, NSValue>()
        cache.countLimit = 4000
        return cache
    }()

    /// Largest artwork payload we'll accept from the network (compressed bytes).
    private static let maxDownloadBytes = 20 * 1024 * 1024

    /// Dedicated session with a large disk cache for artwork, isolated from data requests.
    ///
    /// BUG-26: the cache MUST be given its own directory. Constructed without one, this
    /// instance shared the app's default cache directory with `URLCache.shared` (which the
    /// Ktor/Supabase sessions open too) — two `URLCache` instances over one store is
    /// unsupported, and this one silently lost the disk tier: writes appeared in Cache.db but
    /// every lookup missed, so EVERY cold start re-downloaded all artwork over the network
    /// (trace-proven: 50/50 loads `net` on a warm-disk relaunch; the reporter's "takes much
    /// longer to reload all the movies and artwork").
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtworkURLCache", isDirectory: true)
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,   // 32 MB
            // beta.19-rc1 verdict (I1): 256 → 512 MB. The same picture is now decoded at a second
            // bucket from these bytes (no second download), and `original`/`large` files are bigger.
            diskCapacity: 512 * 1024 * 1024,    // 512 MB
            directory: cacheDir
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        // BUG-95 rig finding (2026-09-08): with the default 60 s request timeout, a stalled image
        // host (i.postimg.cc answered 32 KB in 30 s from the fixture) holds one of the six fetch
        // slots for a full minute per request, and every later fetch — the Home hero's own
        // `.head`-admitted backdrop included — queues behind it, so a folder hero can sit blank
        // long after its (healthy, GitHub-hosted) mosaic could have loaded. 20 s is the inactivity
        // window between bytes, not a total budget, so a slow-but-alive download still completes;
        // a dead host now frees its slot three times sooner. The failed URL is not retried by a
        // loader that is still showing it (`CachedAsyncImage`'s unchanged-URL guard); the next
        // fresh `fetch` for that URL — a new tile, a re-presented hero — starts over.
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// One shared task per (bucket, URL) currently downloading, so awaiters coalesce onto it.
    /// beta.19-rc1 verdict (I1): same-bucket requests coalesce; a second bucket of one URL re-decodes
    /// from the URLCache bytes (no second download once the first response is stored).
    @MainActor private static var inflight: [String: Task<UIImage, Error>] = [:]

    /// Caps simultaneous download+decode pipelines. Bounds the *transient* peak of in-flight
    /// decoded bitmaps that the memory cache's limits can't see — dozens of rows appearing at
    /// once (catalog-heavy Home load) would otherwise stack unbounded concurrent decodes
    /// (BUG-11). Slots are held only by the shared work tasks, never by coalesced awaiters,
    /// so the gate cannot deadlock.
    private static let maxConcurrentFetches = 6
    @MainActor private static var activeFetches = 0
    @MainActor private static var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    /// Where a fetch goes when all six slots are busy (Codex r3, P2 on the hero commit).
    ///
    /// `.normal` queues behind everything already waiting, which is what every row poster, card
    /// and prefetch wants. `.head` goes to the FRONT: the Home hero's own backdrop and logo are
    /// the two images `HeroCommitCoordinator.prepare(_:)` blocks the whole first paint on, hero
    /// and rows alike, so a cold Home that queues dozens of poster prefetches must not be able to
    /// push them behind that crowd. Slot accounting is unchanged, so the BUG-11 concurrency bound
    /// and the "slots are held only by the shared work tasks" no-deadlock property both hold.
    enum FetchAdmission {
        case normal
        case head
    }

    @MainActor
    private static func acquireFetchSlot(_ admission: FetchAdmission) async {
        if activeFetches < maxConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { continuation in
            switch admission {
            case .normal: fetchWaiters.append(continuation)
            case .head: fetchWaiters.insert(continuation, at: 0)
            }
        }
    }

    @MainActor
    private static func releaseFetchSlot() {
        if fetchWaiters.isEmpty {
            activeFetches -= 1
        } else {
            // Hand the slot straight to the next waiter; activeFetches stays constant.
            fetchWaiters.removeFirst().resume()
        }
    }

    /// Custom-poster URLs that DEFINITIVELY failed (4xx, non-image body, undecodable), with the
    /// time they failed. Only consulted, and only written, when the load has a fallback, so a
    /// re-mounted card whose custom poster 404'd goes straight to the original art. Entries expire
    /// (a poster-service outage recovers), the set is size-bounded, and it is cleared on profile
    /// change (`clearFailedURLs()`, called from `HomeViewModel.stop()`) because the URLs embed the
    /// user's pattern/keys.
    ///
    /// beta.19-rc1 verdict (I1): the same memo now also covers an upgraded `large`/`original` URL that
    /// 404'd, so a title whose larger file is missing costs one quick 404 and is skipped for ten
    /// minutes after that (see `ImageFallbackPlan.recordFailureIfNeeded`).
    @MainActor private static var failedURLs: [URL: Date] = [:]
    static let failedURLTTL: TimeInterval = 10 * 60

    @MainActor static func hasFailed(_ url: URL, now: Date = Date()) -> Bool {
        guard let at = failedURLs[url] else { return false }
        if now.timeIntervalSince(at) > failedURLTTL {
            failedURLs[url] = nil
            return false
        }
        return true
    }

    @MainActor static func noteFailure(_ url: URL, now: Date = Date()) {
        if failedURLs.count >= 512 { failedURLs.removeAll() }
        failedURLs[url] = now
    }

    @MainActor static func clearFailedURLs() { failedURLs.removeAll() }

    /// Only outcomes that will not change on a retry count: a 4xx answer, a non-image body, an
    /// oversized or undecodable payload. Timeouts, connectivity errors, 5xx/408/429 and
    /// cancellation are transient and never recorded.
    nonisolated static func isDefinitiveFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let e = error as? ArtworkFetchError {
            switch e {
            case .http(let status): return (400...499).contains(status) && status != 408 && status != 429
            case .notImage: return true
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .cannotDecodeContentData, .dataLengthExceedsMaximum, .cannotDecodeRawData: return true
            default: return false
            }
        }
        return false
    }

    // MARK: - Lookup

    /// Synchronous memory-cache lookup. Safe from any context (the pools lock internally); lets
    /// views seed their first frame without an async hop, avoiding a placeholder flash.
    ///
    /// beta.19-rc1 verdict (I1): ANY bucket, ANY family member — the largest decode of any URL in
    /// `ArtworkURLUpgrade.family(url)`. That is exactly today's one-entry-per-URL behaviour widened to
    /// the family: a poster a card decoded at 896 px from its `w780` variant is a hit for a caller
    /// that asks with the original `w500` URL. Same as `cachedLargest`.
    nonisolated static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cachedLargest(url)
    }

    /// The largest decode of any URL in `ArtworkURLUpgrade.family(url)`. Spec A's tile loader uses
    /// this for its poster fallback (the poster a row card drew is in memory under its own bucket).
    nonisolated static func cachedLargest(_ url: URL) -> UIImage? {
        memory.largest(in: ArtworkURLUpgrade.family(url))
    }

    /// rc14 FEAT-46 (Steven rc13 verdict, 2026-09-30): `cached(_:)` for `ArtworkColorStore`, which
    /// samples a focused card's ring colour from the image already decoded here and must never
    /// trigger a download of its own. beta.19-rc1 verdict (I1): returns `cachedLargest`, so ring and rail
    /// colours keep working when a card draws the upgraded URL (the card's `imageURL` is the original).
    nonisolated static func cachedImage(for url: URL) -> UIImage? {
        cachedLargest(url)
    }

    /// Bucket-aware lookup. `.legacy` → `cachedLargest`; `.points` / `.fullBleed` / `.pixels` →
    /// the bucket the request would be stored under (`b`), then `servingOrder(from: b)` over the
    /// family, largest URL first: a larger decode serves a smaller request.
    nonisolated static func cached(_ url: URL?, decode request: ArtworkDecodeRequest) -> UIImage? {
        guard let url else { return nil }
        let normalized = request.normalized
        if normalized.size == .legacy { return cachedLargest(url) }
        return memory.serving(in: ArtworkURLUpgrade.family(url), atLeast: requestBucket(url, normalized))
    }

    nonisolated static func cached(_ url: URL?, _ request: ArtworkDecodeRequest) -> UIImage? {
        cached(url, decode: request)
    }

    /// What to show while the right size loads: any family member, any bucket, adequate sizes first
    /// (the request's bucket and larger), then the largest smaller one.
    nonisolated static func cachedPlaceholder(_ url: URL, decode request: ArtworkDecodeRequest) -> UIImage? {
        let normalized = request.normalized
        if normalized.size == .legacy { return cachedLargest(url) }
        return memory.placeholder(in: ArtworkURLUpgrade.family(url), for: requestBucket(url, normalized))
    }

    nonisolated static func cachedPlaceholder(_ url: URL, _ request: ArtworkDecodeRequest) -> UIImage? {
        cachedPlaceholder(url, decode: request)
    }

    /// The first candidate (in order) that has a placeholder.
    nonisolated static func cachedPlaceholder(for candidates: [URL], decode request: ArtworkDecodeRequest) -> UIImage? {
        for candidate in candidates {
            if let hit = cachedPlaceholder(candidate, decode: request) { return hit }
        }
        return nil
    }

    /// The bucket a decode of `url` for `request` is (or would be) stored under, using the source
    /// size an earlier decode recorded.
    nonisolated private static func requestBucket(_ url: URL, _ request: ArtworkDecodeRequest) -> Int {
        let source = sourceSizes.object(forKey: url as NSURL)?.cgSizeValue
        let needed = ArtworkDecodeMath.neededLongSide(request, source: source)
        return ArtworkDecodeMath.storeBucket(needed: needed, sourceLongSide: source.map { max($0.width, $0.height) })
    }

    /// beta.19-rc1 verdict (I1, BUG-134): the source pixel size an earlier decode of `url` recorded,
    /// nil when none has run (or the entry was evicted). The Home hero's post-commit sharpen reads it
    /// to tell whether decoding the same file again could add pixels (`HeroSharpen.plan`).
    nonisolated static func recordedSourceSize(_ url: URL) -> CGSize? {
        sourceSizes.object(forKey: url as NSURL)?.cgSizeValue
    }

    /// Running pool sizes for the artwork probe.
    nonisolated static func poolTotals() -> (smallBytes: Int, smallCount: Int, largeBytes: Int, largeCount: Int) {
        memory.totals()
    }

    /// A memory warning empties the large pool (the small one rebuilds cheaply from the URLCache).
    nonisolated static func handleMemoryWarning() {
        ArtworkProbe.logPools(warning: true)
        memory.clearLarge()
    }

    @MainActor private static var memoryObserverInstalled = false

    @MainActor
    private static func installMemoryWarningObserverIfNeeded() {
        guard !memoryObserverInstalled else { return }
        memoryObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { _ in
            ArtworkStore.handleMemoryWarning()
        }
    }

    // MARK: - Fetch

    /// Fetch + validate + decode + cache one URL. Concurrent calls for the same URL (and bucket)
    /// share one download. Cancelling an awaiting caller does NOT cancel the shared work — the image
    /// still lands in the cache for whoever wants it next.
    ///
    /// `admission` only matters when the six-slot gate is saturated (see `FetchAdmission`); a call
    /// that coalesces onto an already-running download inherits that download's admission, since
    /// there is nothing left to queue.
    ///
    /// beta.19-rc1 verdict (I1): `decode` is how large the image is decoded (`.legacy`, the default,
    /// is today's 1920 px cap). The memory check uses the lookup contract above, so `.legacy` accepts
    /// any bucket of any family member.
    @MainActor
    static func fetch(_ url: URL, decode: ArtworkDecodeRequest = .legacy, admission: FetchAdmission = .normal,
                      timeout: TimeInterval? = nil) async throws -> UIImage {
        installMemoryWarningObserverIfNeeded()
        let request = decode.normalized
        if let hit = cached(url, decode: request) {
            #if DEBUG
            LaunchTrace.artwork(.memory)  // BUG-26 attribution
            #endif
            return hit
        }
        let neededBucket = ArtworkDecodeMath.bucket(
            for: ArtworkDecodeMath.neededLongSide(request, source: sourceSizes.object(forKey: url as NSURL)?.cgSizeValue))
        let inflightKey = "\(neededBucket)|\(ArtworkMemory.identity(url))"
        if let existing = inflight[inflightKey] { return try await existing.value }

        let work = Task<UIImage, Error> {
            await acquireFetchSlot(admission)
            defer { releaseFetchSlot() }
            #if DEBUG
            // BUG-26: classify where this load's bytes come from — a healthy relaunch should be
            // dominated by disk (URLCache) hits; all-network on every cold start would confirm
            // the "something invalidates the artwork cache" theory.
            var traceSource: LaunchTrace.ArtworkSource =
                session.configuration.urlCache?.cachedResponse(for: URLRequest(url: url)) != nil
                    ? .disk
                    : .network
            #endif
            let data: Data
            if url.scheme == "data" {
                // Inline `data:image/...;base64,...` avatars (custom pictures imported from
                // other Nuvio clients) decode locally — there's no network response to
                // validate, and routing a multi-megabyte URL string through the disk-backed
                // URLCache would waste space on a payload that's already fully in memory.
                // Base64-decoding a ~MB payload is synchronous, so hop off the main actor
                // (this Task inherits @MainActor from `fetch`) like the decode below does.
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                #if DEBUG
                traceSource = .disk  // local bytes, no network involved
                #endif
            } else {
                // `timeout` (only passed for a non-last candidate: a custom-poster primary or an
                // upgraded larger file that HAS something behind it) is the per-request inactivity
                // window; nil keeps the session's 20 s. A black-holed poster service must not hold a
                // fetch slot for 20 s before the fallback can run.
                let result: (Data, URLResponse)
                if let timeout {
                    var urlRequest = URLRequest(url: url)
                    urlRequest.timeoutInterval = timeout
                    result = try await session.data(for: urlRequest)
                } else {
                    result = try await session.data(from: url)
                }
                let (fetchedData, response) = result

                // Reject unsuccessful responses, non-image payloads, and oversized downloads
                // before spending any decode work on them (HI-006).
                if let http = response as? HTTPURLResponse {
                    guard (200...299).contains(http.statusCode) else {
                        throw ArtworkFetchError.http(http.statusCode)
                    }
                    if let mime = http.mimeType?.lowercased(), !mime.hasPrefix("image/") {
                        throw ArtworkFetchError.notImage
                    }
                }
                data = fetchedData
            }
            guard data.count <= maxDownloadBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }

            // Decode off the main actor, downsampled to the size the request draws at (beta.19-rc1
            // verdict, I1: points × displayScale rounded up to a bucket, never above the source) —
            // decoding artwork at source dimensions is what made the old cache balloon, and a fixed
            // 1920 px cap is what made a 4K Apple TV's full-bleed layers soft.
            let decoded = try await Task.detached(priority: .userInitiated) {
                try downsample(data: data, request: request)
            }.value

            let image = decoded.image
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 4 * 1024 * 1024
            if let source = decoded.sourceSize {
                sourceSizes.setObject(NSValue(cgSize: source), forKey: url as NSURL)
            }
            memory.store(image: image, url: url, bucket: decoded.storeBucket, cost: cost)
            ArtworkProbe.logDecode(url: url, requestBucket: decoded.requestBucket, source: decoded.sourceSize,
                                   image: image, isLarge: cost >= ArtworkDecodeMath.largePoolThreshold,
                                   milliseconds: decoded.milliseconds)
            #if DEBUG
            LaunchTrace.artwork(traceSource)  // BUG-26 attribution
            #endif
            return image
        }
        inflight[inflightKey] = work
        defer { inflight[inflightKey] = nil }
        return try await work.value
    }

    /// Fire-and-forget warm-up for a set of URLs (memory + disk). Home calls this the moment the
    /// hero items arrive so carousel paging and the 8s auto-advance never hit a cold cache.
    /// beta.19-rc1 verdict (I1): `decode` is the size to warm (`.legacy` by default); a URL already
    /// resident for that request is skipped.
    @MainActor
    static func prefetch(_ urls: [URL], decode: ArtworkDecodeRequest = .legacy) {
        installMemoryWarningObserverIfNeeded()
        for url in urls where cached(url, decode: decode) == nil {
            Task { _ = try? await fetch(url, decode: decode) }
        }
    }

    /// beta.19-rc1 verdict (I1): the typed form — each item names the decode it wants warmed.
    @MainActor
    static func prefetch(_ items: [ArtworkPrefetchItem]) {
        installMemoryWarningObserverIfNeeded()
        for item in items where cached(item.url, decode: item.decode) == nil {
            Task { _ = try? await fetch(item.url, decode: item.decode) }
        }
    }

    /// beta.19-rc1 verdict (I1): fetch `urls` concurrently and return when all have landed or
    /// `timeout` seconds have passed, whichever is first. It never cancels the fetches: the shared
    /// work in `fetch` is unstructured on purpose, so a late image still lands in the cache for
    /// whoever wants it next. Used by the folder page header (item C) to hold its reveal for the
    /// first poster row.
    @MainActor
    static func prefetchAndWait(_ urls: [URL], decode: ArtworkDecodeRequest = .legacy,
                                timeout: TimeInterval) async {
        installMemoryWarningObserverIfNeeded()
        let pending = urls.filter { cached($0, decode: decode) == nil }
        guard !pending.isEmpty else { return }
        let gate = PrefetchWaitGate(count: pending.count)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.attach(continuation)
            for url in pending {
                Task { @MainActor in
                    _ = try? await fetch(url, decode: decode)
                    gate.landed()
                }
            }
            gate.startTimer(seconds: timeout)
        }
    }

    /// ImageIO downsampling: decodes straight to a bounded thumbnail without ever materializing
    /// the full-size bitmap. The cap is the request's bucket (the drawn size in pixels rounded up),
    /// never above the source's own long side; `.legacy` keeps today's `min(1920, source)`. Absurd
    /// source dimensions are rejected before any real decode work.
    nonisolated fileprivate static func downsample(data: Data, request: ArtworkDecodeRequest) throws -> ArtworkDecodeResult {
        let started = CFAbsoluteTimeGetCurrent()
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        var sourceSize: CGSize?
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Double,
           let height = props[kCGImagePropertyPixelHeight] as? Double {
            guard width > 0, height > 0, width <= 12_000, height <= 12_000 else {
                throw URLError(.cannotDecodeContentData)
            }
            sourceSize = CGSize(width: width, height: height)
        }
        let sourceLong = sourceSize.map { max($0.width, $0.height) }
        let needed = ArtworkDecodeMath.neededLongSide(request, source: sourceSize)
        let requestBucket = ArtworkDecodeMath.bucket(for: needed)
        let storeBucket = ArtworkDecodeMath.storeBucket(needed: needed, sourceLongSide: sourceLong)
        let maxPixel = sourceLong.map { min(requestBucket, Int($0.rounded(.up))) } ?? requestBucket
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        let elapsed = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000).rounded())
        return ArtworkDecodeResult(image: UIImage(cgImage: cgImage), sourceSize: sourceSize,
                                   storeBucket: storeBucket, requestBucket: requestBucket,
                                   milliseconds: elapsed)
    }
}

/// beta.19-rc1 verdict (I1): what one decode produced, handed back from the detached decode task.
nonisolated struct ArtworkDecodeResult: @unchecked Sendable {
    let image: UIImage
    /// The source image's pixel size, nil when ImageIO did not report one.
    let sourceSize: CGSize?
    /// The bucket the image is stored under (never above the source).
    let storeBucket: Int
    /// The bucket the request asked for (the probe's `req=`).
    let requestBucket: Int
    let milliseconds: Int
}

/// Waits for N fetches or a timeout (`ArtworkStore.prefetchAndWait`). Resumes its continuation
/// exactly once; the timer is cancelled when the fetches win.
@MainActor
private final class PrefetchWaitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var remaining: Int
    private var timer: Task<Void, Never>?

    init(count: Int) { remaining = count }

    func attach(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func startTimer(seconds: TimeInterval) {
        let nanoseconds = UInt64(max(0, min(seconds, 3600)) * 1_000_000_000)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.finish()
        }
    }

    func landed() {
        remaining -= 1
        if remaining <= 0 { finish() }
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}

// MARK: - Memory pools

/// beta.19-rc1 verdict (I1): one decoded image in a pool, with what the eviction delegate needs to
/// keep the running totals and the per-URL bucket masks right.
nonisolated final class ArtworkCacheEntry {
    let image: UIImage
    let urlString: String
    let bucket: Int
    let cost: Int
    let isLarge: Bool
    /// Guarded by `ArtworkMemory.lock`. True while the entry is in the running totals; makes every
    /// uncount idempotent (NSCache does not reliably call `willEvictObject` on replacement).
    var counted = false
    /// The pool generation at store time (a memory warning bumps the large pool's).
    var generation = 0

    init(image: UIImage, urlString: String, bucket: Int, cost: Int, isLarge: Bool) {
        self.image = image
        self.urlString = urlString
        self.bucket = bucket
        self.cost = cost
        self.isLarge = isLarge
    }
}

/// beta.19-rc1 verdict (I1, BUG-134): the decoded-image memory — two `NSCache` pools keyed
/// `"<bucket>|<url>"`, chosen by decoded cost (`ArtworkDecodeMath.largePoolThreshold`), plus a
/// per-URL bitmask of the buckets present in each pool so a lookup over a URL family touches
/// `NSCache` only for entries that exist.
///
/// Thread-safe: `NSCache` locks internally; the totals and masks sit behind `lock`, which is never
/// held across a call into `NSCache` (the eviction delegate takes it while `NSCache` is mid-call).
/// The masks are an index, not the truth: a stale bit costs one failed `NSCache` probe, a missing
/// bit costs one re-decode from the URLCache bytes.
nonisolated final class ArtworkMemory: NSObject, NSCacheDelegate, @unchecked Sendable {
    private let small = NSCache<NSString, ArtworkCacheEntry>()
    private let large = NSCache<NSString, ArtworkCacheEntry>()
    private let lock = NSLock()

    private var smallMasks: [String: UInt16] = [:]
    private var largeMasks: [String: UInt16] = [:]
    private var smallBytes = 0
    private var smallCount = 0
    private var largeBytes = 0
    private var largeCount = 0
    private var smallGeneration = 0
    private var largeGeneration = 0

    init(smallLimitBytes: Int, largeLimitBytes: Int) {
        super.init()
        small.totalCostLimit = smallLimitBytes
        small.countLimit = 1000
        small.delegate = self
        large.totalCostLimit = largeLimitBytes
        large.countLimit = 24
        large.delegate = self
    }

    /// The URL's identity in keys and masks. A multi-megabyte `data:` avatar URL would otherwise be
    /// copied into every key; it is replaced by its length and hash (unique within the process).
    static func identity(_ url: URL) -> String {
        let string = url.absoluteString
        if string.hasPrefix("data:"), string.utf8.count > 256 {
            return "data:\(string.utf8.count):\(string.hashValue)"
        }
        return string
    }

    private static func key(_ identity: String, bucket: Int) -> NSString {
        "\(bucket)|\(identity)" as NSString
    }

    private static func bit(forBucket bucket: Int) -> UInt16 {
        UInt16(1) << UInt16(ArtworkDecodeMath.index(of: bucket))
    }

    // MARK: Store

    func store(image: UIImage, url: URL, bucket: Int, cost: Int) {
        let identity = Self.identity(url)
        let isLarge = cost >= ArtworkDecodeMath.largePoolThreshold
        let entry = ArtworkCacheEntry(image: image, urlString: identity, bucket: bucket, cost: cost, isLarge: isLarge)
        let key = Self.key(identity, bucket: bucket)
        let previous = large.object(forKey: key) ?? small.object(forKey: key)
        let bit = Self.bit(forBucket: bucket)

        // Count the new entry BEFORE it goes into the pool: if the pool evicts it straight away,
        // `willEvictObject` then finds it counted and uncounts it.
        lock.lock()
        if let previous, previous.counted { uncountLocked(previous) }
        entry.counted = true
        if isLarge {
            entry.generation = largeGeneration
            largeBytes += cost
            largeCount += 1
            largeMasks[identity, default: 0] |= bit
        } else {
            entry.generation = smallGeneration
            smallBytes += cost
            smallCount += 1
            smallMasks[identity, default: 0] |= bit
        }
        lock.unlock()

        (isLarge ? large : small).setObject(entry, forKey: key, cost: cost)
    }

    /// Caller holds `lock`.
    private func uncountLocked(_ entry: ArtworkCacheEntry) {
        entry.counted = false
        let bit = Self.bit(forBucket: entry.bucket)
        if entry.isLarge {
            guard entry.generation == largeGeneration else { return }   // the pool was cleared since
            largeBytes = max(0, largeBytes - entry.cost)
            largeCount = max(0, largeCount - 1)
            Self.clear(bit, for: entry.urlString, in: &largeMasks)
        } else {
            guard entry.generation == smallGeneration else { return }
            smallBytes = max(0, smallBytes - entry.cost)
            smallCount = max(0, smallCount - 1)
            Self.clear(bit, for: entry.urlString, in: &smallMasks)
        }
    }

    private static func clear(_ bit: UInt16, for identity: String, in masks: inout [String: UInt16]) {
        guard let current = masks[identity] else { return }
        let next = current & ~bit
        masks[identity] = next == 0 ? nil : next
    }

    // MARK: NSCacheDelegate

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let entry = obj as? ArtworkCacheEntry else { return }
        lock.lock()
        defer { lock.unlock() }
        guard entry.counted else { return }
        uncountLocked(entry)
    }

    // MARK: Lookup

    private func presence(for identity: String) -> (small: UInt16, large: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        return (smallMasks[identity] ?? 0, largeMasks[identity] ?? 0)
    }

    private func image(identity: String, bucket: Int, masks: (small: UInt16, large: UInt16)) -> UIImage? {
        let bit = Self.bit(forBucket: bucket)
        guard (masks.small | masks.large) & bit != 0 else { return nil }
        let key = Self.key(identity, bucket: bucket)
        if masks.large & bit != 0, let entry = large.object(forKey: key) { return entry.image }
        if masks.small & bit != 0, let entry = small.object(forKey: key) { return entry.image }
        return nil
    }

    /// The largest decode of any URL in `family`: highest bucket first, ties in family order.
    func largest(in family: [URL]) -> UIImage? {
        let identities = family.map { Self.identity($0) }
        let masks = identities.map { self.presence(for: $0) }
        if masks.allSatisfy({ $0.small == 0 && $0.large == 0 }) { return nil }
        for bucket in ArtworkDecodeMath.buckets.reversed() {
            for (index, identity) in identities.enumerated() {
                if let hit = image(identity: identity, bucket: bucket, masks: masks[index]) { return hit }
            }
        }
        return nil
    }

    /// The first decode at `bucket` or larger: family order (largest URL first), then
    /// `servingOrder(from:)`.
    func serving(in family: [URL], atLeast bucket: Int) -> UIImage? {
        let order = ArtworkDecodeMath.servingOrder(from: bucket)
        for url in family {
            let identity = Self.identity(url)
            let m = presence(for: identity)
            if m.small == 0 && m.large == 0 { continue }
            for b in order {
                if let hit = image(identity: identity, bucket: b, masks: m) { return hit }
            }
        }
        return nil
    }

    /// Any decode of any family member: adequate sizes first (the request's bucket and larger), then
    /// the largest smaller one.
    func placeholder(in family: [URL], for bucket: Int) -> UIImage? {
        let order = ArtworkDecodeMath.servingOrder(from: bucket) + ArtworkDecodeMath.placeholderOrder(below: bucket)
        for url in family {
            let identity = Self.identity(url)
            let m = presence(for: identity)
            if m.small == 0 && m.large == 0 { continue }
            for b in order {
                if let hit = image(identity: identity, bucket: b, masks: m) { return hit }
            }
        }
        return nil
    }

    // MARK: Totals and warnings

    func totals() -> (smallBytes: Int, smallCount: Int, largeBytes: Int, largeCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (smallBytes, smallCount, largeBytes, largeCount)
    }

    /// Empties the large pool (memory warning). The generation bump makes any eviction callback for
    /// an entry that was in the pool a no-op, so the totals cannot go negative or drift.
    func clearLarge() {
        lock.lock()
        largeGeneration += 1
        largeBytes = 0
        largeCount = 0
        largeMasks.removeAll()
        lock.unlock()
        large.removeAllObjects()
    }
}

// MARK: - Probe

/// beta.19-rc1 verdict (I1, BUG-134): the artwork probe. Launch arg `debug.artworkProbe YES`
/// (read ONCE, like every other launch-latched probe knob in this tree; release-safe so the device
/// pass can use the same build as Steven). One line per decode:
///
///     [ArtworkStore] decode host=<host> size=<seg> req=<bucket> src=<w>x<h> out=<w>x<h> pool=<s|l> ms=<n>
///
/// `size=` is the CDN size segment (`w500` / `w780` / `original` for TMDB, `poster/medium` /
/// `poster/large` for metahub, `-` otherwise), `req=` the requested bucket, `src=` the source's pixel
/// size (`-` unknown), `out=` the decoded bitmap, `pool=` small or large. Every 30 s, and on a memory
/// warning, one pools line:
///
///     [ArtworkStore] pools small=<MB>/<n> large=<MB>/<n> avail=<MB>
nonisolated enum ArtworkProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.artworkProbe")

    nonisolated(unsafe) private static var tickerStarted = false

    @MainActor
    static func logDecode(url: URL, requestBucket: Int, source: CGSize?, image: UIImage,
                          isLarge: Bool, milliseconds: Int) {
        guard enabled else { return }
        startTickerIfNeeded()
        let host = url.host ?? "-"
        let src = source.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        let out = image.cgImage.map { "\($0.width)x\($0.height)" } ?? "-"
        let line = "[ArtworkStore] decode host=\(host) size=\(ArtworkURLUpgrade.sizeSegment(url)) req=\(requestBucket) "
            + "src=\(src) out=\(out) pool=\(isLarge ? "l" : "s") ms=\(milliseconds)"
        NSLog("%@", line)
    }

    nonisolated static func poolsLine(warning: Bool = false) -> String {
        let totals = ArtworkStore.poolTotals()
        func megabytes(_ bytes: Int) -> Int { Int((Double(bytes) / 1_048_576).rounded()) }
        let available = os_proc_available_memory() / 1_048_576
        return "[ArtworkStore] pools small=\(megabytes(totals.smallBytes))/\(totals.smallCount) "
            + "large=\(megabytes(totals.largeBytes))/\(totals.largeCount) avail=\(available)"
            + (warning ? " warning=1" : "")
    }

    nonisolated static func logPools(warning: Bool = false) {
        guard enabled else { return }
        NSLog("%@", poolsLine(warning: warning))
    }

    @MainActor
    private static func startTickerIfNeeded() {
        guard enabled, !tickerStarted else { return }
        tickerStarted = true
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                logPools()
            }
        }
    }
}

// MARK: - Loader

/// The inputs of one `CachedAsyncImage` load: the attempt order plus the decode it wants. A change
/// of either resets the load. (Replaces the old `ImageURLPair`; the upgraded URL is now just the
/// first candidate.)
struct ImageURLChain: Hashable {
    let urls: [URL]
    let request: ArtworkDecodeRequest
}

/// Attempt order for a primary URL plus an optional upgraded variant and an optional fallback
/// (upgraded larger file -> original art -> custom-poster fallback). Pure so the "head fails ->
/// next tried once -> failed only after all" rule is testable.
enum ImageFallbackPlan {
    /// Upgraded first, then the primary, then the fallback, each only when it differs from the ones
    /// before it. At most three entries, so it can never loop.
    static func candidates(upgraded: URL?, primary: URL?, fallback: URL?) -> [URL] {
        var out: [URL] = []
        for url in [upgraded, primary, fallback] {
            if let url, !out.contains(url) { out.append(url) }
        }
        return out
    }

    /// Primary first, then the fallback only when it differs. At most two entries.
    static func candidates(primary: URL?, fallback: URL?) -> [URL] {
        candidates(upgraded: nil, primary: primary, fallback: fallback)
    }

    enum InitialRender: Equatable {
        /// The head (first candidate) is in memory at the requested size: show it, done.
        case showHead
        /// A placeholder is in memory AND everything ahead of the last candidate is known-failed (and
        /// the last candidate is in memory at the requested size): show it, done.
        case showFallback
        /// Only a placeholder is in memory (a smaller decode, or another candidate's art): show it (no
        /// shimmer) but still fetch the head and replace it when it loads.
        case showPlaceholderThenFetch
        /// Nothing usable in memory: shimmer and walk the candidates.
        case fetch
    }

    /// Decides what the first frame shows. `hasFallback` is false for a plain single-URL load.
    /// `headCached`: the head at the requested bucket. `placeholderCached`: any family member of any
    /// candidate, any bucket. `primaryFailed` (named for the custom-poster case it was written for):
    /// the whole chain ahead of the last candidate is known-failed and the last candidate is cached
    /// at the requested size.
    static func initialRender(headCached: Bool, placeholderCached: Bool,
                              primaryFailed: Bool, hasFallback: Bool) -> InitialRender {
        if headCached { return .showHead }
        guard placeholderCached else { return .fetch }
        if hasFallback && primaryFailed { return .showFallback }
        return .showPlaceholderThenFetch
    }

    /// The short request window every NON-LAST candidate gets, so one dead host or one missing larger
    /// file never holds a fetch slot for the session's 20 s before the next candidate can run.
    static let nonLastRequestTimeout: TimeInterval = 8

    static func requestTimeout(for url: URL, in candidates: [URL]) -> TimeInterval? {
        url == candidates.last ? nil : nonLastRequestTimeout
    }

    /// Records a definitive failure (4xx, not an image, undecodable) of any non-last candidate, so
    /// the next mount skips it for ten minutes. The last candidate is never recorded: nothing is
    /// behind it, and a remount must still try it.
    @MainActor
    static func recordFailureIfNeeded(_ url: URL, in candidates: [URL], error: Error) {
        guard url != candidates.last, ArtworkStore.isDefinitiveFailure(error) else { return }
        ArtworkStore.noteFailure(url)
    }

    /// Walks `candidates` in order and returns the first image that loads. A candidate for which
    /// `skip` is true (already failed this session) is passed over unless it is the last one, so a
    /// remounted card goes straight to the fallback instead of re-requesting a known 404. Returns
    /// nil only after every attempted candidate failed.
    @MainActor
    static func firstLoaded<T>(
        candidates: [URL],
        skip: (URL) -> Bool = { _ in false },
        fetch: (URL) async throws -> T,
        onFailure: (URL, Error) -> Void = { _, _ in }
    ) async -> T? {
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { return nil }
            if index < candidates.count - 1, skip(candidate) { continue }
            do {
                return try await fetch(candidate)
            } catch {
                if Task.isCancelled { return nil }
                onFailure(candidate, error)
            }
        }
        return nil
    }

    /// The production walk: `firstLoaded` over `ArtworkStore.fetch` at `request`'s decode size, with the
    /// failure memo and the non-last request window wired in. Shared by `CachedAsyncImage` and
    /// `TitleLogoHeader`.
    @MainActor
    static func load(candidates: [URL], request: ArtworkDecodeRequest) async -> UIImage? {
        await firstLoaded(
            candidates: candidates,
            skip: { ArtworkStore.hasFailed($0) },
            fetch: { url in
                try await ArtworkStore.fetch(url, decode: request, timeout: requestTimeout(for: url, in: candidates))
            },
            onFailure: { url, error in
                recordFailureIfNeeded(url, in: candidates, error: error)
            }
        )
    }
}

/// Loads and caches a single image URL for one `CachedAsyncImage`, delegating the shared cache,
/// download, and decode machinery to `ArtworkStore`.
@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var currentChain = ImageURLChain(urls: [], request: .legacy)
    private var task: Task<Void, Never>?

    func load(_ chain: ImageURLChain) {
        guard chain != currentChain else { return }
        currentChain = chain
        task?.cancel()
        failed = false
        image = nil

        let candidates = chain.urls
        guard !candidates.isEmpty else { return }
        let request = chain.request

        let hasFallback = candidates.count > 1
        let headHit = ArtworkStore.cached(candidates[0], decode: request)
        let placeholder = headHit == nil ? ArtworkStore.cachedPlaceholder(for: candidates, decode: request) : nil
        // Everything ahead of the last candidate is known-failed AND the last candidate is in memory
        // at the requested size: the walk would only re-show it.
        var lastHit: UIImage?
        if hasFallback, headHit == nil, candidates.dropLast().allSatisfy({ ArtworkStore.hasFailed($0) }) {
            lastHit = ArtworkStore.cached(candidates[candidates.count - 1], decode: request)
        }
        switch ImageFallbackPlan.initialRender(
            headCached: headHit != nil,
            placeholderCached: placeholder != nil,
            primaryFailed: lastHit != nil,
            hasFallback: hasFallback
        ) {
        case .showHead:
            image = headHit
            return
        case .showFallback:
            image = lastHit ?? placeholder
            return
        case .showPlaceholderThenFetch:
            image = placeholder   // placeholder only; the walk below still fetches the head
        case .fetch:
            break
        }

        task = Task { [weak self] in
            let fetched = await ImageFallbackPlan.load(candidates: candidates, request: request)
            if Task.isCancelled { return }
            guard let self, self.currentChain == chain else { return }
            if let fetched {
                withAnimation(.easeIn(duration: 0.25)) { self.image = fetched }
            } else {
                self.failed = true
            }
        }
    }

    /// beta.19-rc1 verdict (I1, `releasesWhenHidden`): drops the image and forgets the chain, so the
    /// next `load` for the same inputs starts over (normally a memory hit).
    func release() {
        task?.cancel()
        task = nil
        image = nil
        failed = false
        currentChain = ImageURLChain(urls: [], request: .legacy)
    }

    deinit { task?.cancel() }
}

/// Animated shimmer placeholder shown while an image loads.
struct ShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Theme.Palette.surface
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: animate ? geo.size.width : -geo.size.width * 0.6)
                }
            )
            .clipped()
            .onAppear {
                // Reduce Motion: leave the placeholder static instead of an endlessly sweeping
                // gradient — the loading state is still conveyed by the flat surface fill.
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
            // A loading placeholder, never real content — any accessibility label for the
            // artwork itself is applied by the caller (e.g. the poster's title), separately.
            .accessibilityHidden(true)
    }
}
