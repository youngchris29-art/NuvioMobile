import Combine
import ImageIO
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

    init(url: URL?, fallbackURL: URL? = nil, contentMode: ContentMode = .fill, cropsBakedLetterboxBars: Bool = false,
         @ViewBuilder failure: @escaping () -> Failure) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.contentMode = contentMode
        self.cropsBakedLetterboxBars = cropsBakedLetterboxBars
        self.failureContent = failure
    }

    /// Convenience for the many Kotlin-bridged `String` URL fields; empty/nil → no image.
    init(string: String?, fallback: String? = nil, contentMode: ContentMode = .fill, cropsBakedLetterboxBars: Bool = false,
         @ViewBuilder failure: @escaping () -> Failure) {
        if let string, !string.isEmpty {
            self.url = URL(string: string)
        } else {
            self.url = nil
        }
        if let fallback, !fallback.isEmpty {
            self.fallbackURL = URL(string: fallback)
        } else {
            self.fallbackURL = nil
        }
        self.contentMode = contentMode
        self.cropsBakedLetterboxBars = cropsBakedLetterboxBars
        self.failureContent = failure
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
        .onAppear { loader.load(url, fallback: fallbackURL) }
        .onChange(of: ImageURLPair(primary: url, fallback: fallbackURL)) { _, pair in
            loader.load(pair.primary, fallback: pair.fallback)
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
    init(url: URL?, fallbackURL: URL? = nil, contentMode: ContentMode = .fill, cropsBakedLetterboxBars: Bool = false) {
        self.init(url: url, fallbackURL: fallbackURL, contentMode: contentMode, cropsBakedLetterboxBars: cropsBakedLetterboxBars,
                   failure: { DefaultFailureImage() })
    }

    init(string: String?, fallback: String? = nil, contentMode: ContentMode = .fill, cropsBakedLetterboxBars: Bool = false) {
        self.init(string: string, fallback: fallback, contentMode: contentMode, cropsBakedLetterboxBars: cropsBakedLetterboxBars,
                   failure: { DefaultFailureImage() })
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

enum ArtworkStore {
    /// Process-wide in-memory decoded-image cache. Bounded by decoded bytes, not just count —
    /// 400 unbounded images (a 4K RGBA backdrop is ~32 MB decoded) could exceed the Apple TV
    /// process budget during long catalog browsing (HI-006). NSCache is thread-safe, hence the
    /// `nonisolated(unsafe)` escape hatch for synchronous first-frame lookups from view inits.
    nonisolated(unsafe) private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 128 * 1024 * 1024   // decoded bytes
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
            diskCapacity: 256 * 1024 * 1024,    // 256 MB
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

    /// One shared task per URL currently downloading, so awaiters coalesce onto it.
    @MainActor private static var inflight: [URL: Task<UIImage, Error>] = [:]

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

    /// Synchronous memory-cache lookup. Safe from any context (NSCache locks internally); lets
    /// views seed their first frame without an async hop, avoiding a placeholder flash.
    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: url as NSURL)
    }

    /// rc14 FEAT-46 (Steven rc13 verdict, 2026-09-30): `cached(_:)` for `ArtworkColorStore`, which
    /// samples a focused card's ring colour from the image already decoded here and must never
    /// trigger a download of its own. Explicitly `nonisolated` (the target defaults to MainActor):
    /// `memory` is an `NSCache`, which locks internally, so the lookup is safe from any context.
    nonisolated static func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Fetch + validate + decode + cache one URL. Concurrent calls for the same URL share one
    /// download. Cancelling an awaiting caller does NOT cancel the shared work — the image still
    /// lands in the cache for whoever wants it next.
    ///
    /// `admission` only matters when the six-slot gate is saturated (see `FetchAdmission`); a call
    /// that coalesces onto an already-running download inherits that download's admission, since
    /// there is nothing left to queue.
    @MainActor
    static func fetch(_ url: URL, admission: FetchAdmission = .normal,
                      timeout: TimeInterval? = nil) async throws -> UIImage {
        if let hit = cached(url) {
            #if DEBUG
            LaunchTrace.artwork(.memory)  // BUG-26 attribution
            #endif
            return hit
        }
        if let existing = inflight[url] { return try await existing.value }

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
                // `timeout` (only passed for a custom-poster primary that HAS a fallback) is the
                // per-request inactivity window; nil keeps the session's 20 s. A black-holed poster
                // service must not hold a fetch slot for 20 s before the fallback can run.
                let result: (Data, URLResponse)
                if let timeout {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = timeout
                    result = try await session.data(for: request)
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

            // Decode off the main actor, downsampled to at most the panel's own resolution —
            // decoding artwork at source dimensions is what made the old cache balloon.
            let decoded = try await Task.detached(priority: .userInitiated) {
                try downsample(data: data)
            }.value

            let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 4 * 1024 * 1024
            memory.setObject(decoded, forKey: url as NSURL, cost: cost)
            #if DEBUG
            LaunchTrace.artwork(traceSource)  // BUG-26 attribution
            #endif
            return decoded
        }
        inflight[url] = work
        defer { inflight[url] = nil }
        return try await work.value
    }

    /// Fire-and-forget warm-up for a set of URLs (memory + disk). Home calls this the moment the
    /// hero items arrive so carousel paging and the 8s auto-advance never hit a cold cache.
    @MainActor
    static func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil {
            Task { _ = try? await fetch(url) }
        }
    }

    /// ImageIO downsampling: decodes straight to a bounded thumbnail without ever materializing
    /// the full-size bitmap. 1920 px covers a full-screen 1080p-point layer; posters and cards
    /// render far smaller. Absurd source dimensions are rejected before any real decode work.
    nonisolated fileprivate static func downsample(data: Data) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Double,
           let height = props[kCGImagePropertyPixelHeight] as? Double {
            guard width > 0, height > 0, width <= 12_000, height <= 12_000 else {
                throw URLError(.cannotDecodeContentData)
            }
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1920
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: cgImage)
    }
}

/// The (primary, fallback) inputs of one `CachedAsyncImage`; a change of either resets the load.
struct ImageURLPair: Equatable {
    let primary: URL?
    let fallback: URL?
}

/// Attempt order for a primary URL plus an optional fallback (custom poster URL -> original art).
/// Pure so the "primary fails -> fallback tried once -> failed only after both" rule is testable.
enum ImageFallbackPlan {
    /// Primary first, then the fallback only when it differs. At most two entries, so it can never loop.
    static func candidates(primary: URL?, fallback: URL?) -> [URL] {
        var out: [URL] = []
        if let primary { out.append(primary) }
        if let fallback, fallback != primary { out.append(fallback) }
        return out
    }

    enum InitialRender: Equatable {
        /// Primary is in memory: show it, done.
        case showPrimary
        /// Only the fallback is in memory AND the primary is known-failed: show it, done.
        case showFallback
        /// Only the fallback is in memory, primary not known-failed: show it as a placeholder
        /// (no shimmer) but still fetch the primary and replace it when it loads.
        case showFallbackThenFetchPrimary
        /// Nothing usable in memory: shimmer and walk the candidates.
        case fetch
    }

    /// Decides what the first frame shows. `hasFallback` is false for a plain single-URL load.
    static func initialRender(primaryCached: Bool, fallbackCached: Bool,
                              primaryFailed: Bool, hasFallback: Bool) -> InitialRender {
        if primaryCached { return .showPrimary }
        guard hasFallback, fallbackCached else { return .fetch }
        return primaryFailed ? .showFallback : .showFallbackThenFetchPrimary
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
}

/// Loads and caches a single image URL for one `CachedAsyncImage`, delegating the shared cache,
/// download, and decode machinery to `ArtworkStore`.
@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var currentPair = ImageURLPair(primary: nil, fallback: nil)
    private var task: Task<Void, Never>?

    func load(_ url: URL?, fallback: URL? = nil) {
        let pair = ImageURLPair(primary: url, fallback: fallback)
        guard pair != currentPair else { return }
        currentPair = pair
        task?.cancel()
        failed = false
        image = nil

        let candidates = ImageFallbackPlan.candidates(primary: url, fallback: fallback)
        guard !candidates.isEmpty else { return }

        let hasFallback = candidates.count > 1
        let primary = candidates[0]
        let fallbackHit = hasFallback ? ArtworkStore.cached(candidates[1]) : nil
        switch ImageFallbackPlan.initialRender(
            primaryCached: ArtworkStore.cached(primary) != nil,
            fallbackCached: fallbackHit != nil,
            primaryFailed: hasFallback && ArtworkStore.hasFailed(primary),
            hasFallback: hasFallback
        ) {
        case .showPrimary:
            image = ArtworkStore.cached(primary)
            return
        case .showFallback:
            image = fallbackHit
            return
        case .showFallbackThenFetchPrimary:
            image = fallbackHit   // placeholder only; the walk below still fetches the primary
        case .fetch:
            break
        }

        task = Task { [weak self] in
            let fetched = await ImageFallbackPlan.firstLoaded(
                candidates: candidates,
                skip: { ArtworkStore.hasFailed($0) },
                fetch: { url in
                    // Short window for a primary that has a fallback waiting behind it.
                    try await ArtworkStore.fetch(url, timeout: hasFallback && url == primary ? 8 : nil)
                },
                onFailure: { url, error in
                    // Record only for a primary that has a fallback, and only definitive outcomes.
                    guard hasFallback, url == primary, ArtworkStore.isDefinitiveFailure(error) else { return }
                    ArtworkStore.noteFailure(url)
                }
            )
            if Task.isCancelled { return }
            guard let self, self.currentPair == pair else { return }
            if let fetched {
                withAnimation(.easeIn(duration: 0.25)) { self.image = fetched }
            } else {
                self.failed = true
            }
        }
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
