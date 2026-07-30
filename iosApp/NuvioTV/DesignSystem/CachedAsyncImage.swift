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
struct CachedAsyncImage: View {
    private let url: URL?
    private let contentMode: ContentMode

    @StateObject private var loader = CachedImageLoader()

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    /// Convenience for the many Kotlin-bridged `String` URL fields; empty/nil → no image.
    init(string: String?, contentMode: ContentMode = .fill) {
        if let string, !string.isEmpty {
            self.url = URL(string: string)
        } else {
            self.url = nil
        }
        self.contentMode = contentMode
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if loader.failed {
                ZStack {
                    Theme.Palette.surface
                    Image(systemName: "film")
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } else if url == nil {
                // Nothing to load — flat surface rather than an endless shimmer.
                Theme.Palette.surface
            } else {
                ShimmerView()
            }
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { _, newURL in loader.load(newURL) }
    }
}

/// Shared artwork pipeline behind `CachedAsyncImage` (and the Home hero's logo/backdrop
/// prefetcher): a process-wide decoded-image memory cache, a dedicated disk-backed session,
/// ImageIO downsampling, and in-flight request coalescing so concurrent views (or a prefetch
/// plus a view) never download the same URL twice.
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
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,   // 32 MB
            diskCapacity: 256 * 1024 * 1024     // 256 MB
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
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

    @MainActor
    private static func acquireFetchSlot() async {
        if activeFetches < maxConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { fetchWaiters.append($0) }
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

    /// Synchronous memory-cache lookup. Safe from any context (NSCache locks internally); lets
    /// views seed their first frame without an async hop, avoiding a placeholder flash.
    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: url as NSURL)
    }

    /// Fetch + validate + decode + cache one URL. Concurrent calls for the same URL share one
    /// download. Cancelling an awaiting caller does NOT cancel the shared work — the image still
    /// lands in the cache for whoever wants it next.
    @MainActor
    static func fetch(_ url: URL) async throws -> UIImage {
        if let hit = cached(url) { return hit }
        if let existing = inflight[url] { return try await existing.value }

        let work = Task<UIImage, Error> {
            await acquireFetchSlot()
            defer { releaseFetchSlot() }
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
            } else {
                let (fetchedData, response) = try await session.data(from: url)

                // Reject unsuccessful responses, non-image payloads, and oversized downloads
                // before spending any decode work on them (HI-006).
                if let http = response as? HTTPURLResponse {
                    guard (200...299).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    if let mime = http.mimeType?.lowercased(), !mime.hasPrefix("image/") {
                        throw URLError(.cannotDecodeContentData)
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

/// Loads and caches a single image URL for one `CachedAsyncImage`, delegating the shared cache,
/// download, and decode machinery to `ArtworkStore`.
@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var currentURL: URL?
    private var task: Task<Void, Never>?

    func load(_ url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        task?.cancel()
        failed = false
        image = nil

        guard let url else { return }

        if let cached = ArtworkStore.cached(url) {
            image = cached
            return
        }

        task = Task { [weak self] in
            let fetched = try? await ArtworkStore.fetch(url)
            if Task.isCancelled { return }
            guard let self, self.currentURL == url else { return }
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
