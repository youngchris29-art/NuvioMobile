import Combine
import ImageIO
import SwiftUI
import UIKit

/// Renders an animated GIF as a looping `UIImageView`, with the folder's static cover art shown
/// underneath while the GIF downloads/decodes and on any decode failure — the tile is never
/// blank. SwiftUI's `Image(uiImage:)` only ever draws an animated `UIImage`'s first frame, so
/// playback needs `UIImageView.startAnimating()`, hence the `UIViewRepresentable` wrapper.
///
/// Ported from the mobile Kotlin/Native reference,
/// `composeApp/src/iosMain/kotlin/com/nuvio/app/features/home/components/CollectionCardRemoteImage.ios.kt`:
/// `gifImageWithData` (ImageIO frame extraction + `UIImage.animatedImage(with:duration:)`),
/// `parseGifFrameDurations` (per-frame Graphic Control Extension delay parsing), and
/// `expandedGifFrames` (GCD-based frame-reference duplication so unequal per-frame delays still
/// play back correctly on a single fixed-duration `UIImage` animation).
///
/// BUG-19 (4th attempt — the first three moved decode work around without removing the actual
/// main-thread cost per focus step). The measured symptom was a 700–830 ms freeze of EVERY visible
/// tile on each D-pad step, i.e. a main-thread hang, not a slow animation. Four levers, all of
/// which had to land together:
///   1. the GIF `URLSession`'s `URLCache` had no `directory:`, so it silently had no disk tier at
///      all (same defect ArtworkStore hit — see the `session` comment below);
///   2. the memory cache's cost accounting made every realistic entry larger than the whole
///      budget, so it was evicted on insert and the "cached" path never hit (see `AnimatedGifCache`);
///   3. fetch + cache-write ran on the main actor (only the CGImage expansion hopped off);
///   4. the view was mounted/unmounted by focus, so every step tore down a whole pipeline (freeing
///      the expanded frame array on the main thread in `dismantleUIView`) and built a new one.
/// The view is now mounted for the tile's whole lifetime and focus only toggles
/// `isAnimating`/opacity — see `FolderTile` in `CollectionsUI.swift`.
struct AnimatedGifImage: View {
    private let url: URL?
    private let fallbackURLString: String?
    private let contentMode: ContentMode
    private let isAnimating: Bool
    private let targetSize: CGSize

    @StateObject private var loader = AnimatedGifLoader()

    /// - Parameters:
    ///   - string: the animated GIF's URL (Kotlin-bridged `String?`; empty/nil → no animation).
    ///   - fallback: the folder's static cover, shown underneath while the GIF loads and if it
    ///     never resolves to an animated image (bad URL, decode failure, non-GIF data). Pass `nil`
    ///     when the caller already mounts the cover itself (`FolderTile` does, so the cover isn't
    ///     torn down and re-decoded alongside the GIF).
    ///   - isAnimating: BUG-19 — drives playback AND visibility without changing view identity.
    ///     `false` keeps the decoded frames alive in this view's loader but stops the
    ///     `UIImageView` and fades the GIF out to reveal the cover underneath. The first
    ///     transition to `true` is also what lazily kicks off the download/decode: a 15-tile row
    ///     must not decode 15 GIFs at mount.
    ///   - targetSize: BUG-39 — the tile's actual rendered size, in points (e.g. `FolderTile`
    ///     passes its own `tileWidth`/`tileHeight`). Lets `AnimatedGifDecoder` downsample to
    ///     roughly what's actually displayed instead of a fixed worst-case pixel guess, so the
    ///     same 12 MiB per-GIF frame budget buys several times more frames at typical collection-
    ///     tile size — see `AnimatedGifDecoder.targetDecodePixelCeiling`. Captured once, at the
    ///     first `prepare()` call this loader makes for a given URL (see `AnimatedGifLoader.
    ///     prepare`'s doc for why a LATER `targetSize` change — e.g. the user live-editing the
    ///     Poster Style width in Settings — deliberately does NOT trigger a re-decode.
    init(
        string: String?,
        fallback: String?,
        contentMode: ContentMode = .fill,
        isAnimating: Bool = true,
        targetSize: CGSize
    ) {
        if let string, !string.isEmpty {
            self.url = URL(string: string)
        } else {
            self.url = nil
        }
        self.fallbackURLString = fallback
        self.contentMode = contentMode
        self.isAnimating = isAnimating
        self.targetSize = targetSize
    }

    /// Visible only once there is something to show AND the tile wants animation — until then the
    /// cover (this view's own fallback, or the caller's) shows through.
    private var gifVisible: Bool { isAnimating && loader.image != nil }

    var body: some View {
        ZStack {
            if let fallbackURLString, !fallbackURLString.isEmpty {
                CachedAsyncImage(string: fallbackURLString, contentMode: contentMode)
            }

            // Always mounted (BUG-19 lever 4): no `if` around this view, so focus changes never
            // create/destroy a UIImageView and never free the expanded frame array on the main
            // thread. `image` is nil until the decode lands.
            AnimatedUIImageView(
                image: loader.image,
                contentMode: contentMode,
                isAnimating: isAnimating
            )
            .opacity(gifVisible ? 1 : 0)
            .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.15), value: gifVisible)
        .onAppear {
            loader.prepare(url, targetSize: targetSize)
            if isAnimating { loader.loadIfNeeded() }
        }
        .onChange(of: url) { _, newURL in
            loader.prepare(newURL, targetSize: targetSize)
            if isAnimating { loader.loadIfNeeded() }
        }
        .onChange(of: isAnimating) { _, animating in
            // Lazy first focus: the decode starts here, not at mount.
            if animating { loader.loadIfNeeded() }
        }
    }
}

/// Thin `UIViewRepresentable` around `UIImageView` — the only UIKit type that actually plays an
/// animated `UIImage`'s frames back.
///
/// BUG-19: playback is now driven by the `isAnimating` INPUT rather than by the view's existence.
/// `makeUIView`/`dismantleUIView` therefore run once per tile instead of once per focus step, and
/// an unfocused tile costs exactly one stopped `UIImageView` holding an already-decoded image.
private struct AnimatedUIImageView: UIViewRepresentable {
    let image: UIImage?
    let contentMode: ContentMode
    let isAnimating: Bool

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: UIImageView) {
        if view.image !== image {
            // Reassigning `image` while animating leaves UIImageView's frame timer pointing at the
            // old frame array; stop first (this is the Kotlin reference's `updateGifImage` order).
            if view.isAnimating { view.stopAnimating() }
            view.image = image
        }
        if isAnimating, image != nil {
            if !view.isAnimating { view.startAnimating() }
        } else if view.isAnimating {
            // Stopped, NOT dismantled: the frames stay retained by the loader/cache so re-focusing
            // this tile is a `startAnimating()` call, not a fresh download+decode.
            view.stopAnimating()
        }
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: ()) {
        uiView.stopAnimating()
        uiView.image = nil
    }
}

/// Loads, decodes, and caches one animated-GIF URL for one `AnimatedGifImage`. Shaped like this
/// file's neighbor `CachedImageLoader` (`CachedAsyncImage.swift`): a `@MainActor`
/// `ObservableObject` that cancels its in-flight work when superseded or deallocated.
///
/// BUG-19: split into `prepare` (free — point at a URL, answer synchronously from the memory
/// cache, never start work) and `loadIfNeeded` (starts the one download+decode, at most once per
/// URL). `prepare` alone must stay cheap because every tile in a row calls it at mount.
@MainActor
private final class AnimatedGifLoader: ObservableObject {
    @Published var image: UIImage?

    private var currentURL: URL?
    /// BUG-39: the render target this loader will decode `currentURL` at, set once per URL by
    /// `prepare` (see its doc). Deliberately NOT re-read on every `loadIfNeeded` call from `body`
    /// — it's captured at `prepare` time and stays pinned for that URL's whole lifetime.
    private var currentTargetSize: CGSize = .zero
    private var task: Task<Void, Never>?
    /// Whether `loadIfNeeded` has already spent (or is spending) a fetch on `currentURL`. This is
    /// a RETRY LATCH, not a one-shot flag: on a failed decode it is cleared again (see below) so
    /// the tile's next focus retries, up to `maxLoadAttempts` total tries for this URL — only
    /// after the cap is reached does it stay latched, so a permanently-dead URL stops
    /// re-downloading on every focus.
    private var didRequestLoad = false
    /// Attempts already spent on `currentURL`. Reset only when `prepare` points the loader at a
    /// genuinely new URL (see below), so this counts total tries per URL, not per call.
    private var attemptCount = 0
    /// Retry cap (FINDING 1): a transient network error or truncated download must not permanently
    /// latch `didRequestLoad` — that left `image == nil` forever with no future focus ever trying
    /// again. But an unconditional retry-on-every-focus would hammer a permanently-dead URL
    /// forever too. Three attempts splits the difference: enough to ride out a flaky connection,
    /// bounded enough that a truly broken URL settles on the static cover for good.
    private static let maxLoadAttempts = 3

    /// Point the loader at a URL WITHOUT starting any network/decode work. A synchronous memory
    /// cache hit is taken immediately (that's the whole reason the cache exists — see
    /// `AnimatedGifCache`'s cost arithmetic, which previously made every hit a miss).
    ///
    /// BUG-39: `targetSize` is stored ONLY when `url` is actually new (the early-return guard
    /// below). If the caller's `targetSize` changes later without the URL changing — e.g. the
    /// user live-edits the Poster Style width in Settings while this tile is already decoded or
    /// mid-decode — this method is a no-op and the stale `currentTargetSize` from the first call
    /// keeps driving `loadIfNeeded`. That is deliberate: a target-size change is not worth a
    /// re-decode. Forcing one would mean every visible tile re-fetches and re-decodes its GIF the
    /// moment a settings slider moves, which is exactly the kind of main-thread/network churn
    /// BUG-19 spent four attempts eliminating from the FOCUS path — doing it from the SETTINGS
    /// path instead would just move the hang, not remove it. The visible cost is that a tile
    /// keeps whatever resolution it first decoded at until its GIF URL itself changes (a new
    /// folder, a refreshed feed, etc.), which is unnoticeable given collection-tile GIFs are
    /// already palette-quantised and low-detail.
    func prepare(_ url: URL?, targetSize: CGSize) {
        guard url != currentURL else { return }
        currentURL = url
        currentTargetSize = targetSize
        task?.cancel()
        task = nil
        didRequestLoad = false
        attemptCount = 0
        image = AnimatedGifCache.cached(url)
    }

    /// Lazily start the fetch+decode — called on the tile's FIRST focus, not at mount.
    func loadIfNeeded() {
        guard let url = currentURL, image == nil, !didRequestLoad else { return }
        didRequestLoad = true

        if let cached = AnimatedGifCache.cached(url) {
            image = cached
            return
        }

        attemptCount += 1
        let isFinalAttempt = attemptCount >= Self.maxLoadAttempts
        let targetSize = currentTargetSize

        task = Task { [weak self] in
            let decoded = await AnimatedGifDecoder.decode(url, targetSize: targetSize)
            if Task.isCancelled { return }
            guard let self, self.currentURL == url else { return }
            if let decoded {
                self.image = decoded
            } else if !isFinalAttempt {
                // FINDING 1 fix: clear the latch so the NEXT focus (not this one — no busy-retry)
                // re-attempts the fetch+decode. Once `attemptCount` hits the cap, fall through and
                // leave the latch set: `image` stays nil and the caller's fallback cover shows
                // indefinitely instead of refetching a dead URL on every subsequent focus.
                self.didRequestLoad = false
            }
        }
    }

    deinit { task?.cancel() }
}

/// Dedicated animated-image cache — deliberately NOT `ArtworkStore.memory` (`CachedAsyncImage.swift`).
/// That cache's cost accounting assumes one decoded single-frame bitmap per entry; an animated
/// `UIImage` here carries many frames, so it gets its own explicitly-costed budget instead of
/// silently blowing the shared artwork cache's assumptions.
///
/// BUG-19 cost arithmetic (the old numbers made this cache a no-op). Entry cost is now the TRUE
/// sum of every unique decoded frame's bitmap (`AnimatedGifDecoder.decodedGif`), and the decoder
/// caps that sum at `maxDecodedBytesPerGif` = 12 MB by shrinking the per-frame downsample ceiling
/// for long GIFs. So:
///
///   * worst case per entry ...... 12 MB (still possible for a large/landscape tile near the
///     400 px absolute cap, e.g. a 60-frame GIF decoded to ~229 px/side)
///   * typical square "Services"-style tile (BUG-39: decodes near its own ~220 px tile size, not
///     a blanket 400 px) ... 20 frames × 220×220 RGBA (~194 KB) ≈ 3.9 MB — well under budget, so
///     a GIF like this now keeps EVERY source frame instead of being frame-subsampled
///   * short 10-frame loop at the same tile size ........ 10 × 194 KB ≈ 1.9 MB
///
/// (See `AnimatedGifDecoder.targetDecodePixelCeiling` for the full per-tile-size breakdown; the
/// old fixed-400px numbers this comment used to cite are now only the worst case, not the norm.)
///
///   totalCostLimit 144 MB = 12 worst-case entries, or many more typical-size ones.
///   countLimit 24 covers the Services + Genres rows' visible+prefetched tiles together (the old
///   limit of 12 was per the Kotlin reference's `MaxCachedGifImages`, which is a phone-sized row).
///
/// The old configuration was countLimit 12 / 64 MB against an entry cost of
/// `frameCount × firstFrameBytes` ≈ 86 MB for a 60-frame 800 px collage: every entry exceeded the
/// entire budget, so `NSCache` evicted it during the very `setObject` that inserted it and the
/// synchronous hit path never fired — every focus step re-downloaded and re-decoded.
///
/// `nonisolated(unsafe)` mirrors `ArtworkStore.memory`: `NSCache` locks internally, and the
/// decoder writes to it from a detached task while views read it synchronously.
private enum AnimatedGifCache {
    nonisolated(unsafe) static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 144 * 1024 * 1024   // decoded bytes; see arithmetic above
        return cache
    }()

    /// Synchronous lookup — safe from any context (`NSCache` is thread-safe).
    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return shared.object(forKey: url as NSURL)
    }
}

/// Fetch + decode pipeline for animated GIFs, with in-flight de-duplication per URL (mirrors
/// `ArtworkStore.fetch`'s `inflight` dictionary shape).
///
/// This file gets its own disk-backed `URLSession` rather than reusing `ArtworkStore.session`
/// (which is `private` to `CachedAsyncImage.swift`), configured the same way
/// (`.returnCacheDataElseLoad`, a bounded `URLCache` **in its own directory**, the same 20 MB
/// download ceiling), so repeated focus/unfocus cycles on one tile hit disk instead of the network.
///
/// BUG-19: only `decode`'s bookkeeping is `@MainActor` now. The download, the ImageIO decode, the
/// frame expansion and the cache write all run on a detached task, so a focus step never waits on
/// them.
private enum AnimatedGifDecoder {
    private static let maxDownloadBytes = 20 * 1024 * 1024
    private static let defaultFrameDelayCentiseconds = 10

    /// BUG-19 lever (a). The `URLCache` MUST be given its own `directory:`. Constructed without
    /// one — as this session was — the instance shares the app's default cache store with
    /// `URLCache.shared` (which the Ktor/Supabase sessions open too); two `URLCache` instances
    /// over one store is unsupported and this one silently lost its disk tier: writes landed in
    /// Cache.db but every lookup missed. That is exactly the defect ArtworkStore hit and fixed in
    /// commit 8ab9fa23 (BUG-26, documented at `CachedAsyncImage.swift:78–95`); the GIF session was
    /// written from the same template *before* that fix and inherited the bug, which is why every
    /// focus step re-downloaded the GIF bytes over the network.
    nonisolated(unsafe) private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GifURLCache", isDirectory: true)
        config.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,     // 8 MB
            diskCapacity: 128 * 1024 * 1024,     // 128 MB of compressed GIF bytes
            directory: cacheDir
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    @MainActor private static var inflight: [URL: Task<UIImage?, Never>] = [:]

    /// De-dupe bookkeeping and the final `UIImage` handoff stay on the main actor; everything
    /// expensive happens inside the detached task.
    ///
    /// BUG-39: `targetSize` (points) is converted to a pixel ceiling HERE, on the main actor,
    /// because it needs `UIScreen.main.scale` — reading it inside the detached task would touch
    /// UIKit off the main thread. The resulting `Int` is a plain Sendable value, so it crosses
    /// into `Task.detached` for free.
    ///
    /// Note on de-dupe: if two tiles with DIFFERENT `targetSize`s race for the same GIF `url`
    /// (e.g. a portrait and a landscape folder both referencing the same shared GIF asset), the
    /// second one's request just awaits the first one's already-in-flight `work` and gets that
    /// decode's resolution, not its own. This is the same "keep the first decode" trade-off as
    /// `prepare`'s target-size latch above, and for the same reason: starting a second concurrent
    /// decode of the same bytes at a different size to chase per-tile pixel-perfection would cost
    /// real main-thread/network work for a difference that's invisible on a palette-quantised GIF.
    @MainActor
    static func decode(_ url: URL, targetSize: CGSize) async -> UIImage? {
        if let cached = AnimatedGifCache.cached(url) { return cached }
        if let existing = inflight[url] {
            return await existing.value
        }

        let targetPixelSize = targetDecodePixelCeiling(for: targetSize, scale: UIScreen.main.scale)

        // `Task.detached` (not `Task`): a plain `Task` created here would INHERIT @MainActor, which
        // is what put `fetchData`'s await, the frame expansion and the cache write on the main
        // thread. Only the CGImage decode hopped off before.
        let work = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard let data = try? await fetchData(url) else { return nil }
            guard let result = decodedGif(from: data, targetPixelSize: targetPixelSize) else { return nil }
            AnimatedGifCache.shared.setObject(result.image, forKey: url as NSURL, cost: result.cost)
            return result.image
        }
        inflight[url] = work
        defer { inflight[url] = nil }
        return await work.value
    }

    /// BUG-39: pixel ceiling for ImageIO's `kCGImageSourceThumbnailMaxPixelSize`, derived from the
    /// TILE's actual rendered point size instead of the old blanket `maxFramePixelSize` guess
    /// applied to every tile in the app regardless of its real size (that guess is now only the
    /// outer safety cap, below).
    ///
    /// `scale` converts the tile's point size to a pixel budget as if displayed at up to
    /// Retina/4K density; capping the SCALE itself at 2.0 — not just the final pixel count — is
    /// the "2x layout size" ceiling: a hypothetical higher-density screen can't blow the budget
    /// just because `UIScreen.main.scale` reports more than 2. The result is then clamped into
    /// `[minFramePixelSize, maxFramePixelSize]`: the floor protects a degenerate near-zero/NaN
    /// `targetSize` (defensive only — `FolderTile` computes its `targetSize` synchronously from
    /// `PosterStyle`, not from a UIKit layout pass, so it's never actually zero in practice) from
    /// producing a useless sliver thumbnail, and the ceiling means no tile can decode at a LARGER
    /// pixel size than the pre-BUG-39 fixed guess — this can only shrink the per-frame cost,
    /// never grow it past the old worst case.
    ///
    /// Concrete numbers for the default `PosterStyle` (220×330 pt portrait tiles, 220×220 pt
    /// square "Services"-style tiles, ~391×220 pt landscape tiles):
    ///   * square tile, scale 1 (Apple TV HD) → 220 px vs the old fixed 400 px: ~3.3× more bytes
    ///     of budget left per frame, so a GIF that used to fit ~20 frames now fits ~65+.
    ///   * portrait tile, scale 1 → 330 px vs 400 px: ~1.5× more frames.
    ///   * landscape tile, scale 1 → 391 px, barely below the 400 px cap: little change.
    ///   * at scale 2 (Apple TV 4K) the cap itself is scale-aware (beta.12): a 330 pt tile may
    ///     decode at up to 660 px instead of being clamped to 400 px (~half its real backing
    ///     store — the "still average" sharpness BUG-39's re-report measured). The per-GIF byte
    ///     budget still clamps longer GIFs below this ceiling exactly as before.
    private nonisolated static func targetDecodePixelCeiling(for targetSize: CGSize, scale: CGFloat) -> Int {
        let cappedScale = min(scale, 2.0)
        // BUG-39 (beta.12): the outer cap is a POINT budget, so it must scale with the panel like
        // the tile's own backing store does. The old `min(maxFramePixelSize, …)` treated 400 as a
        // PIXEL cap, which on a scale-2 (4K) panel decoded every GIF at ~half the tile's real
        // backing resolution — measured luma softness the reporter called "still average". A
        // scale-1 (HD) panel is byte-identical to the old behavior; on 4K, per-frame cost can rise
        // up to 4× for SHORT GIFs only — `framePixelCeiling` + the enforced running-total check
        // still clamp anything longer, so `maxDecodedBytesPerGif` remains the hard bound either way.
        let pixelCap = Int((CGFloat(maxFramePixelSize) * cappedScale).rounded())
        let longEdge = max(targetSize.width, targetSize.height)
        guard longEdge.isFinite, longEdge > 0 else { return pixelCap }
        let pixels = Int((longEdge * cappedScale).rounded())
        return min(pixelCap, max(minFramePixelSize, pixels))
    }

    private nonisolated static func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        guard !data.isEmpty, data.count <= maxDownloadBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        // BUG-19 lever (e): a truncated body still decodes — ImageIO happily returns the frames it
        // could parse and fills the rest with garbage, which is the 2-frame magenta corruption
        // caught on camera. Status + byte count can't see this (a cut-off transfer is still 200 OK
        // with a plausible length), so validate the container itself before anything caches or
        // renders it, and evict the bad bytes from the disk cache so the next focus retries the
        // network instead of replaying the corruption forever.
        guard isCompleteGif(data) else {
            session.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    /// Cheap completeness check on the raw payload: GIF magic, a parseable image source, and
    /// ImageIO's own "I have all the bytes" verdict.
    private nonisolated static func isCompleteGif(_ data: Data) -> Bool {
        guard hasGifHeader([UInt8](data.prefix(6))) else { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        guard CGImageSourceGetStatus(source) == .statusComplete else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    // MARK: - GIF decode (ported from `gifImageWithData` / `expandedGifFrames`)

    private struct DecodedGif {
        let image: UIImage
        /// Sum of EVERY unique frame's decoded bitmap bytes, for `NSCache`'s cost accounting.
        /// (The expanded array repeats frames by reference, so it adds no bitmap memory.)
        let cost: Int
    }

    private struct GifFrame {
        let image: CGImage
        let delayCentiseconds: Int
    }

    /// Outer safety cap on the per-frame downsample ceiling's long edge, regardless of tile size —
    /// in POINTS as of beta.12 (BUG-39 re-report): `targetDecodePixelCeiling` multiplies it by the
    /// capped screen scale, so it is 400 px on an HD panel and 800 px on a 4K one. tvOS lays every
    /// app out in a fixed 1920×1080 POINT space, so even the largest realistic collection tile
    /// (~360–420 pt landscape) tops out around here in points — but treating this as a PIXEL cap
    /// (the pre-beta.12 behavior) decoded every GIF at ~half its backing store on 4K, which is the
    /// measured softness the reporter kept filing.
    ///
    /// BUG-39: before this fix, EVERY tile decoded up to this fixed value regardless of its own
    /// rendered size — a 220 pt square tile paid the same per-frame bitmap cost as a 420 pt
    /// landscape one. `targetDecodePixelCeiling` (near `AnimatedGifDecoder.decode`) now derives
    /// the ACTUAL per-call ceiling from the tile's real `targetSize`, and this constant is only
    /// the upper bound that derivation is clamped to — so no tile can decode at a larger pixel
    /// size than before, but most tiles now decode well below it. See that function's doc for the
    /// concrete before/after numbers.
    private static let maxFramePixelSize = 400
    /// Floor for the adaptive ceiling below — never decode a tile-sized GIF smaller than this.
    /// FINDING 5: below `frameCount` ≈ `maxFramesAtFloorSize`, resolution can no longer shrink to
    /// hold the budget, so `decodedGif` shrinks the UNIQUE FRAME COUNT instead (see
    /// `subsampledIndices`) — the floor never lets a single GIF exceed `maxDecodedBytesPerGif`.
    private static let minFramePixelSize = 200
    /// Hard budget for ONE decoded GIF's total bitmap memory. FINDING B (round 2): actually
    /// enforced against the REAL running total of `bytesPerRow × height` for every frame as it
    /// decodes (see the budget check in `decodedGif`) — the pixel-ceiling/frame-subsampling
    /// combination below only steers the up-front resolution/frame-count guess and can undercount
    /// padded/aligned CGImage row strides, so it alone is not a hard bound; the decode-time check
    /// is what makes this literally true for the stored cache entry. A row of tiles keeps its
    /// decoded frames alive while mounted (that's the point of the fix), so the per-GIF number,
    /// not just the cache total, is what bounds a 15-tile row: 15 × 12 MB = 180 MB is a real
    /// worst case now, and in practice the `LazyHStack` unmounts scrolled-away tiles well before
    /// that.
    private static let maxDecodedBytesPerGif = 12 * 1024 * 1024
    /// FINDING 5: the most unique frames that fit inside `maxDecodedBytesPerGif` at the floor
    /// size — 12 MiB / (4 bytes/px × 200×200) ≈ 78. A GIF with more source frames than this
    /// doesn't get to keep them all at 200 px (that was the bug: a 100-frame square GIF hit
    /// ~15.3 MiB, 3.3 MiB over budget); instead `decodedGif` decodes only this many, evenly
    /// subsampled across the animation, with kept frames' delays summed to cover the frames they
    /// stand in for so total playback duration is unchanged. Unaffected by BUG-39: `minFramePixelSize`
    /// is still the absolute floor for every tile regardless of `targetDecodePixelCeiling`'s
    /// output (see that function's clamp), so this constant's math doesn't change — what changes
    /// is how OFTEN a real GIF actually needs it, since a smaller per-instance ceiling (BUG-39)
    /// makes `estimatedBytes` in `decodedGif` clear the budget at a higher `frameCount` than
    /// before, so fewer GIFs fall into this frame-subsampling path at all.
    private static let maxFramesAtFloorSize = maxDecodedBytesPerGif / (4 * minFramePixelSize * minFramePixelSize)

    /// Long GIFs get downsampled harder so no single entry can blow the budget:
    /// side = √(budget / (4 bytes per pixel × frames)), clamped to [`minFramePixelSize`, `ceiling`].
    /// Example at the old fixed 400 px ceiling: 10 frames → 400 px (clamped, ~6 MB) · 20 frames →
    /// 400 px (~12 MB) · 60 frames → 229 px. BUG-39: `ceiling` is now the CALLER-supplied,
    /// tile-size-derived value from `targetDecodePixelCeiling` rather than always
    /// `maxFramePixelSize` — for a small/typical tile this formula starts from a smaller ceiling,
    /// so a given `frameCount` is more likely to fit uncompressed at that smaller size (no need to
    /// shrink further), or — for frame counts that still don't fit — the frame-count subsampling
    /// below kicks in at a HIGHER `frameCount` than it used to, because a smaller `ceiling` means
    /// the per-frame cost was already cheaper going in.
    /// Note this alone only bounds bytes for frameCount ≤ `maxFramesAtFloorSize` (~78): above
    /// that the `minFramePixelSize` floor stops the math from working out and `decodedGif`
    /// additionally subsamples the frame count (see `maxFramesAtFloorSize`).
    private nonisolated static func framePixelCeiling(frameCount: Int, ceiling: Int) -> Int {
        guard frameCount > 0 else { return ceiling }
        let pixelsPerFrame = Double(maxDecodedBytesPerGif) / (4.0 * Double(frameCount))
        let side = Int(pixelsPerFrame.squareRoot())
        return min(ceiling, max(minFramePixelSize, side))
    }

    /// FINDING 5: evenly-spaced source-frame indices to keep when a GIF has more frames than
    /// `maxFramesAtFloorSize` can afford at the resolution floor. Spreads the kept frames across
    /// the whole animation (not just the first N) so subsampling doesn't visibly favor the start.
    private nonisolated static func subsampledIndices(totalCount: Int, keepCount: Int) -> [Int] {
        guard keepCount < totalCount, keepCount > 0 else { return Array(0..<totalCount) }
        let stride = Double(totalCount) / Double(keepCount)
        var indices: [Int] = []
        indices.reserveCapacity(keepCount)
        var seen = Set<Int>()
        for i in 0..<keepCount {
            let index = min(Int(Double(i) * stride), totalCount - 1)
            if seen.insert(index).inserted {
                indices.append(index)
            }
        }
        return indices.isEmpty ? [0] : indices
    }

    private nonisolated static func decodedGif(from data: Data, targetPixelSize: Int) -> DecodedGif? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let delays = parseFrameDurations(data)

        // FINDING 5: decide UP FRONT whether decoding every source frame at the adaptive-ceiling
        // side would exceed `maxDecodedBytesPerGif`. This only happens once `framePixelCeiling`
        // has bottomed out at `minFramePixelSize` (for smaller frame counts the ceiling formula
        // already keeps side×side×4×frameCount ≤ budget by construction) — in that regime the
        // fix is to decode FEWER unique frames, not smaller ones.
        //
        // FINDING B (round 2): `side² × 4` below is only an ESTIMATE used to pick a resolution/
        // frame-count strategy up front — it assumes an unpadded bitmap row. `CGImage` row
        // strides are actually padded/aligned, so the real per-frame cost (`bytesPerRow ×
        // height`, computed as each frame decodes) can run higher than this guess. This estimate
        // therefore only steers the subsample decision; it is NOT what enforces the 12 MiB bound
        // — the running `decodedBytesTotal` check in the decode loop below is the actual,
        // literal enforcement point.
        //
        // BUG-39: `targetPixelSize` (from `targetDecodePixelCeiling`, via `decode`'s caller) is
        // the tile-size-derived ceiling passed in here — `framePixelCeiling` clamps it down
        // further only if `count` is large enough that even this smaller starting point doesn't
        // fit the budget. So `ceilingSide` below is no longer "guess 400 px and see if it fits";
        // it's "start from what this tile actually needs, and shrink further only if the frame
        // count demands it."
        let ceilingSide = framePixelCeiling(frameCount: count, ceiling: targetPixelSize)
        let estimatedBytes = count * ceilingSide * ceilingSide * 4
        let frameIndices: [Int]
        let decodeSide: Int
        if estimatedBytes > maxDecodedBytesPerGif {
            frameIndices = subsampledIndices(totalCount: count, keepCount: max(maxFramesAtFloorSize, 1))
            decodeSide = minFramePixelSize
        } else {
            frameIndices = Array(0..<count)
            decodeSide = ceilingSide
        }

        var frames: [GifFrame] = []
        frames.reserveCapacity(frameIndices.count)
        // FINDING B (round 2): the actual, ENFORCED running total of decoded bitmap bytes — the
        // sum of `bytesPerRow × height` for every frame actually kept, updated as each frame
        // decodes (see the budget check below). This, not `estimatedBytes` above, is what makes
        // the "12 MiB is an enforced bound" doc comment on `maxDecodedBytesPerGif` literally true.
        var decodedBytesTotal = 0

        // BUG-19: `CGImageSourceCreateImageAtIndex` returns LAZILY-decoded images — the actual
        // bitmap decompression then happened on the MAIN thread at render time, once per frame
        // at full GIF resolution, which is exactly the scroll stutter the tester reported (every
        // D-pad step focuses a new tile and starts a fresh animation). Thumbnail creation with
        // ShouldCacheImmediately decodes each frame HERE, on this detached task, downsampled to
        // tile size — the render path then just blits ready bitmaps.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSide,
        ]

        for (position, index) in frameIndices.enumerated() {
            // Per-frame completeness (lever e): an individually incomplete frame is the magenta
            // garbage. Fail the whole decode so the caller falls back to the static cover.
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else { return nil }
            // No lazy `CGImageSourceCreateImageAtIndex` fallback any more: it would reintroduce
            // main-thread decompression at render time for exactly the frames we couldn't decode
            // cheaply here. Better a static cover than a stuttering tile.
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary) else {
                return nil
            }

            // FINDING B (round 2): `bytesPerRow` is CGImage's real (padded/aligned) row stride,
            // which can exceed the unpadded `side × 4` the pre-decode estimate above assumed.
            // Check the ACTUAL cost against the ACTUAL running total before this frame is kept —
            // once keeping it would push the total over `maxDecodedBytesPerGif`, stop decoding
            // (normally keep at least the first frame, guarded by `!frames.isEmpty`) and fold this
            // frame's delay AND every remaining source frame's delay into the last frame that was
            // actually kept, so total playback duration is preserved even though fewer unique
            // bitmaps end up stored.
            let frameBytes = cgImage.bytesPerRow * cgImage.height
            // Defensive guard: the scale-aware downsample ceiling on `decodeSide` (≤400px per
            // point of scale) should make this unreachable in practice, but the budget is
            // documented as a hard bound, so a
            // pathological first frame that alone exceeds it must fail the whole decode (→ static
            // cover) rather than being kept unconditionally by the `!frames.isEmpty` exemption below.
            if frames.isEmpty && frameBytes > maxDecodedBytesPerGif {
                return nil
            }
            if !frames.isEmpty && decodedBytesTotal + frameBytes > maxDecodedBytesPerGif {
                var extraDelay = 0
                for skipped in index..<count {
                    let raw = skipped < delays.count ? delays[skipped] : defaultFrameDelayCentiseconds
                    extraDelay += min(max(raw, minExpandedFrameDelayCentiseconds), maxRawFrameDelayCentiseconds)
                }
                let last = frames.removeLast()
                let mergedDelay = min(last.delayCentiseconds + extraDelay, maxAggregateFrameDelayCentiseconds)
                frames.append(GifFrame(image: last.image, delayCentiseconds: mergedDelay))
                break
            }

            // FINDING A / FINDING 5: when `frameIndices` is a subsample, this kept frame stands
            // in for itself AND every source frame skipped after it, so its delay is the SUM of
            // that run's RAW delays — fewer unique bitmaps, same total playback duration. Each
            // raw contribution is clamped to `[minExpandedFrameDelayCentiseconds,
            // maxRawFrameDelayCentiseconds]` BEFORE summing (protection against one pathological
            // source frame's delay); the aggregate itself is then bounded separately by the much
            // more generous `maxAggregateFrameDelayCentiseconds` sanity ceiling — NOT by the same
            // per-frame bound, or a heavily-subsampled GIF's kept frames get truncated back down
            // to roughly single-frame timing and the whole animation plays too fast.
            let nextIndex = position + 1 < frameIndices.count ? frameIndices[position + 1] : count
            var delay = 0
            for skipped in index..<nextIndex {
                let raw = skipped < delays.count ? delays[skipped] : defaultFrameDelayCentiseconds
                delay += min(max(raw, minExpandedFrameDelayCentiseconds), maxRawFrameDelayCentiseconds)
            }
            frames.append(GifFrame(image: cgImage, delayCentiseconds: min(max(delay, minExpandedFrameDelayCentiseconds), maxAggregateFrameDelayCentiseconds)))
            decodedBytesTotal += frameBytes
        }
        guard !frames.isEmpty else { return nil }

        let (expandedImages, tickCentiseconds) = expandedFrames(frames)
        let durationSeconds = Double(expandedImages.count * tickCentiseconds) / 100.0
        guard let animated = UIImage.animatedImage(with: expandedImages, duration: durationSeconds) else {
            return nil
        }

        // FINDING B (round 2): `decodedBytesTotal` is the exact, already-enforced sum of every
        // kept frame's actual bitmap bytes (see the budget check above) — use it directly as the
        // cache cost instead of recomputing `bytesPerRow × height` again here.
        if GifDecodeProbe.enabled {
            // BUG-39: the reporter's "still average" sharpness is a function of `decodeSide` vs the
            // tile's real backing store, and of how hard the 12 MiB budget squeezed this particular
            // GIF — numbers nobody can read off a screenshot. `sourceFrames` vs `keptFrames` also
            // tells the device pass whether real collection GIFs are long enough that only the
            // frame-vs-resolution trade (not the ceiling) governs their sharpness.
            NSLog("[GifDecode] side=%d ceiling=%d sourceFrames=%d keptFrames=%d bytes=%d",
                  decodeSide, targetPixelSize, count, frames.count, decodedBytesTotal)
        }
        return DecodedGif(image: animated, cost: max(decodedBytesTotal, 1))
    }

    /// BUG-39 probe knob, same house pattern as `TrailerProbe`/`HomeGeometryProbe`:
    ///
    ///     defaults write com.nuvio.media.NuvioTV debug.gifDecodeProbe -bool YES
    ///
    /// Deliberately not `#if DEBUG` — testers run release sideloads and `log show` is the only
    /// diagnostic channel that comes back from a device pass.
    private enum GifDecodeProbe {
        nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.gifDecodeProbe")
    }

    /// FINDING 6: floor for any frame's delay (raw OR aggregate) BEFORE it enters the GCD-tick
    /// computation below. GIF89a allows any 1–65535 cs delay per RAW frame, so a pathological
    /// file with e.g. a 1 cs frame next to a 65535 cs frame produces `gcd(1, 65535) == 1`: a 1 cs
    /// tick times a many-second total duration expands to hundreds of thousands of retained
    /// `UIImage` references (all pointing at the same handful of unique bitmaps, but each
    /// reference still costs array/object overhead and blows the decode-time peak). This floor
    /// keeps the tick itself from ever going below 2 cs. FINDING A (round 2): the matching UPPER
    /// bound is now split in two — see `maxRawFrameDelayCentiseconds` (applied pre-summation) and
    /// `maxAggregateFrameDelayCentiseconds` (applied post-summation) below — because a single
    /// shared 1000 cs ceiling on both raw and summed delays was truncating heavily-subsampled
    /// GIFs' aggregate frame delays back down to roughly one raw frame's worth.
    private static let minExpandedFrameDelayCentiseconds = 2
    /// FINDING A (round 2): this [2, 1000] cs clamp is protection against a pathological single
    /// GIF frame's raw delay (GIF89a allows 1–65535 cs) — apply it to each RAW per-source-frame
    /// delay BEFORE frames are subsampled and their delays summed (see the `delay +=` loops in
    /// `decodedGif`). It must NOT be reapplied to the SUMMED aggregate a kept frame ends up
    /// carrying: a kept frame standing in for e.g. 20 skipped source frames legitimately needs an
    /// aggregate delay up to ~20× a single frame's, and truncating that back down to 1000 cs made
    /// heavily-subsampled GIFs play substantially faster than their true duration.
    private static let maxRawFrameDelayCentiseconds = 1000
    /// FINDING A (round 2): separate, much more generous ceiling applied to the SUMMED aggregate
    /// delay a single kept frame carries after subsampling — purely a sanity bound on the
    /// expansion arithmetic below (so one absurd aggregate can't multiply `expandedCount` past
    /// anything reasonable before the `maxExpandedFrameCount` cap even gets a chance to look at
    /// it), not a playback-accuracy clamp. 60 s is far beyond any real per-tile GIF's per-frame
    /// hold time; anything hitting this ceiling is already pathological and falls through to the
    /// `maxExpandedFrameCount` uniform-delay fallback below.
    private static let maxAggregateFrameDelayCentiseconds = 60 * 100
    /// FINDING 6: hard ceiling on the TOTAL expanded array length, independent of the clamps above
    /// (a GIF with many frames, each individually reasonable, can still multiply out past this
    /// once ticked). Chosen well above any real per-tile animation's natural frame count so it
    /// only ever fires on pathological/adversarial input.
    private static let maxExpandedFrameCount = 1200

    /// Ported from `expandedGifFrames`: GIF allows each frame its own delay, but
    /// `UIImage.animatedImage(with:duration:)` only takes one total duration divided evenly
    /// across the image array — so frames with a longer delay are repeated (by reference, so no
    /// extra bitmap memory) to fill out their share of a common "tick" (the GCD of all delays).
    private nonisolated static func expandedFrames(_ frames: [GifFrame]) -> (images: [UIImage], tickCentiseconds: Int) {
        // FINDING A (round 2): `GifFrame.delayCentiseconds` already IS the post-summation
        // aggregate (raw per-source delays were clamped to `maxRawFrameDelayCentiseconds` and
        // summed in `decodedGif`, then bounded by `maxAggregateFrameDelayCentiseconds`) — only
        // floor it here, never re-clamp it down to the raw per-frame ceiling, or a kept frame
        // standing in for many skipped ones gets its aggregate truncated right back to roughly a
        // single frame's worth and the whole animation plays too fast.
        let delays = frames.map { max($0.delayCentiseconds, minExpandedFrameDelayCentiseconds) }
        let tick = delays.dropFirst().reduce(delays.first ?? defaultFrameDelayCentiseconds) { greatestCommonDivisor($0, $1) }

        let expandedCount = delays.reduce(0) { $0 + max($1 / tick, 1) }
        guard expandedCount <= maxExpandedFrameCount else {
            // FINDING 6: exact per-frame timing would blow the cap even after clamping — fall
            // back to one reference per unique frame at a uniform delay (the clamped average),
            // matching `UIImage.animatedImage`'s own even-division behavior. Visually
            // indistinguishable from correct timing for the pathological inputs that hit this
            // path; nowhere close for any real tile GIF, which never reaches this branch.
            let averageDelay = max(delays.reduce(0, +) / max(delays.count, 1), minExpandedFrameDelayCentiseconds)
            return (frames.map { UIImage(cgImage: $0.image) }, averageDelay)
        }

        var expanded: [UIImage] = []
        expanded.reserveCapacity(expandedCount)
        for (frame, delay) in zip(frames, delays) {
            let uiImage = UIImage(cgImage: frame.image)
            let repeatCount = max(delay / tick, 1)
            expanded.append(contentsOf: Array(repeating: uiImage, count: repeatCount))
        }
        return (expanded, tick)
    }

    private nonisolated static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return max(x, 1)
    }

    // MARK: - Per-frame delay parsing (ported from `parseGifFrameDurations`)

    private nonisolated static func parseFrameDurations(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, hasGifHeader(bytes) else { return [] }

        var index = 6
        guard index + 7 <= bytes.count else { return [] }

        let logicalScreenPacked = Int(bytes[index + 4])
        index += 7

        if logicalScreenPacked & 0x80 != 0 {
            let globalColorTableSize = 3 * (1 << ((logicalScreenPacked & 0x07) + 1))
            index += globalColorTableSize
        }

        var frameDurations: [Int] = []
        var pendingDelay: Int?

        while index < bytes.count {
            switch Int(bytes[index]) {
            case 0x21:
                guard index + 1 < bytes.count else { return frameDurations }
                let label = Int(bytes[index + 1])
                if label == 0xF9 {
                    guard index + 7 < bytes.count else { return frameDurations }
                    let delay = readUnsignedShort(bytes, index + 4)
                    pendingDelay = delay <= 0 ? defaultFrameDelayCentiseconds : delay
                    index += 8
                } else {
                    index += 2
                    index = skipSubBlocks(bytes, index)
                }

            case 0x2C:
                guard index + 9 < bytes.count else { return frameDurations }
                let imageDescriptorPacked = Int(bytes[index + 9])
                index += 10

                if imageDescriptorPacked & 0x80 != 0 {
                    let localColorTableSize = 3 * (1 << ((imageDescriptorPacked & 0x07) + 1))
                    index += localColorTableSize
                }

                guard index < bytes.count else { return frameDurations }
                index += 1
                index = skipSubBlocks(bytes, index)

                frameDurations.append(pendingDelay ?? defaultFrameDelayCentiseconds)
                pendingDelay = nil

            default:
                return frameDurations
            }
        }

        return frameDurations
    }

    private nonisolated static func hasGifHeader(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 6 &&
            bytes[0] == UInt8(ascii: "G") &&
            bytes[1] == UInt8(ascii: "I") &&
            bytes[2] == UInt8(ascii: "F") &&
            bytes[3] == UInt8(ascii: "8") &&
            (bytes[4] == UInt8(ascii: "7") || bytes[4] == UInt8(ascii: "9")) &&
            bytes[5] == UInt8(ascii: "a")
    }

    private nonisolated static func skipSubBlocks(_ bytes: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let blockSize = Int(bytes[index])
            index += 1
            if blockSize == 0 { return index }
            index += blockSize
        }
        return index
    }

    private nonisolated static func readUnsignedShort(_ bytes: [UInt8], _ start: Int) -> Int {
        guard start + 1 < bytes.count else { return 0 }
        return Int(bytes[start]) | (Int(bytes[start + 1]) << 8)
    }
}
