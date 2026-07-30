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
struct AnimatedGifImage: View {
    private let url: URL?
    private let fallbackURLString: String?
    private let contentMode: ContentMode

    @StateObject private var loader = AnimatedGifLoader()

    /// - Parameters:
    ///   - string: the animated GIF's URL (Kotlin-bridged `String?`; empty/nil → no animation).
    ///   - fallback: the folder's static cover, shown underneath while the GIF loads and if it
    ///     never resolves to an animated image (bad URL, decode failure, non-GIF data).
    init(string: String?, fallback: String?, contentMode: ContentMode = .fill) {
        if let string, !string.isEmpty {
            self.url = URL(string: string)
        } else {
            self.url = nil
        }
        self.fallbackURLString = fallback
        self.contentMode = contentMode
    }

    var body: some View {
        ZStack {
            CachedAsyncImage(string: fallbackURLString, contentMode: contentMode)

            if let image = loader.image {
                AnimatedUIImageView(image: image, contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: loader.image == nil)
        .onAppear { loader.load(url) }
        .onChange(of: url) { _, newURL in loader.load(newURL) }
    }
}

/// Thin `UIViewRepresentable` around `UIImageView` — the only UIKit type that actually plays an
/// animated `UIImage`'s frames back. Mirrors the Kotlin reference's `updateGifImage` helper:
/// stop before reassigning, (re)start whenever a non-nil image is set, and fully tear down
/// (stop + clear) when the view leaves the hierarchy so a scrolled-away tile never keeps
/// animating in the background.
private struct AnimatedUIImageView: UIViewRepresentable {
    let image: UIImage
    let contentMode: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        guard uiView.image !== image else {
            if !uiView.isAnimating { uiView.startAnimating() }
            return
        }
        uiView.stopAnimating()
        uiView.image = image
        uiView.startAnimating()
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: ()) {
        uiView.stopAnimating()
        uiView.image = nil
    }
}

/// Loads, decodes, and caches one animated-GIF URL for one `AnimatedGifImage`. Shaped like this
/// file's neighbor `CachedImageLoader` (`CachedAsyncImage.swift`): a `@MainActor`
/// `ObservableObject` that cancels its in-flight work when superseded or deallocated.
@MainActor
private final class AnimatedGifLoader: ObservableObject {
    @Published var image: UIImage?

    private var currentURL: URL?
    private var task: Task<Void, Never>?

    func load(_ url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        task?.cancel()
        image = nil

        guard let url else { return }

        if let cached = AnimatedGifCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }

        task = Task { [weak self] in
            let decoded = await AnimatedGifDecoder.decode(url)
            if Task.isCancelled { return }
            guard let self, self.currentURL == url else { return }
            self.image = decoded
        }
    }

    deinit { task?.cancel() }
}

/// Dedicated animated-image cache — deliberately NOT `ArtworkStore.memory` (`CachedAsyncImage.swift`).
/// That cache's cost accounting assumes one decoded single-frame bitmap per entry; an animated
/// `UIImage` here carries many frames, so it gets its own small, explicitly-costed budget instead
/// of silently blowing the shared artwork cache's assumptions. Sized to match the Kotlin
/// reference's `MaxCachedGifImages = 12`.
private enum AnimatedGifCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
}

/// Fetch + decode pipeline for animated GIFs, with in-flight de-duplication per URL (mirrors
/// `ArtworkStore.fetch`'s `inflight` dictionary shape).
///
/// Deviation from the task brief: the brief suggested reusing `ArtworkStore.session` for the raw
/// download so the GIF bytes ride its disk cache "for free". That property is `private` to
/// `CachedAsyncImage.swift` (inaccessible from this file), and this port is scoped to touch only
/// `AnimatedGifImage.swift` (new) and `CollectionsUI.swift` — widening `ArtworkStore`'s access
/// control was out of bounds. Instead this file gets its own small disk-backed `URLSession`,
/// configured the same way (`.returnCacheDataElseLoad`, a bounded `URLCache`, the same 20 MB
/// download ceiling as `ArtworkStore`), so repeated focus/unfocus cycles on one tile still hit
/// disk instead of the network without touching the shared store's internals.
private enum AnimatedGifDecoder {
    private static let maxDownloadBytes = 20 * 1024 * 1024
    private static let defaultFrameDelayCentiseconds = 10

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    @MainActor private static var inflight: [URL: Task<UIImage?, Never>] = [:]

    @MainActor
    static func decode(_ url: URL) async -> UIImage? {
        if let existing = inflight[url] {
            return await existing.value
        }

        let work = Task<UIImage?, Never> {
            guard let data = try? await fetchData(url) else { return nil }
            let result = await Task.detached(priority: .userInitiated) {
                decodedGif(from: data)
            }.value
            if let result {
                AnimatedGifCache.shared.setObject(result.image, forKey: url as NSURL, cost: result.cost)
            }
            return result?.image
        }
        inflight[url] = work
        defer { inflight[url] = nil }
        return await work.value
    }

    private static func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        guard !data.isEmpty, data.count <= maxDownloadBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return data
    }

    // MARK: - GIF decode (ported from `gifImageWithData` / `expandedGifFrames`)

    private struct DecodedGif {
        let image: UIImage
        /// frameCount × first-frame bitmap bytes, for `NSCache`'s explicit cost accounting.
        let cost: Int
    }

    private struct GifFrame {
        let image: CGImage
        let delayCentiseconds: Int
    }

    /// Frames are decoded down to at most this many pixels on the long edge. Collection tiles
    /// render at ~360–420pt; 800px comfortably covers @2x while cutting a 1080p GIF's per-frame
    /// bitmap (and its decode time) by ~4x.
    private static let maxFramePixelSize = 800

    private static func decodedGif(from data: Data) -> DecodedGif? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let delays = parseFrameDurations(data)
        var frames: [GifFrame] = []
        frames.reserveCapacity(count)

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
            kCGImageSourceThumbnailMaxPixelSize: maxFramePixelSize,
        ]

        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let delay = index < delays.count ? delays[index] : defaultFrameDelayCentiseconds
            frames.append(GifFrame(image: cgImage, delayCentiseconds: max(delay, 1)))
        }
        guard let firstFrame = frames.first else { return nil }

        let (expandedImages, tickCentiseconds) = expandedFrames(frames)
        let durationSeconds = Double(expandedImages.count * tickCentiseconds) / 100.0
        guard let animated = UIImage.animatedImage(with: expandedImages, duration: durationSeconds) else {
            return nil
        }

        let firstFrameBytes = firstFrame.image.bytesPerRow * firstFrame.image.height
        let cost = max(frames.count, 1) * max(firstFrameBytes, 1)
        return DecodedGif(image: animated, cost: cost)
    }

    /// Ported from `expandedGifFrames`: GIF allows each frame its own delay, but
    /// `UIImage.animatedImage(with:duration:)` only takes one total duration divided evenly
    /// across the image array — so frames with a longer delay are repeated (by reference, so no
    /// extra bitmap memory) to fill out their share of a common "tick" (the GCD of all delays).
    private static func expandedFrames(_ frames: [GifFrame]) -> (images: [UIImage], tickCentiseconds: Int) {
        let delays = frames.map { max($0.delayCentiseconds, 1) }
        let tick = delays.dropFirst().reduce(delays.first ?? defaultFrameDelayCentiseconds) { greatestCommonDivisor($0, $1) }

        var expanded: [UIImage] = []
        for frame in frames {
            let uiImage = UIImage(cgImage: frame.image)
            let repeatCount = max(max(frame.delayCentiseconds, 1) / tick, 1)
            expanded.append(contentsOf: Array(repeating: uiImage, count: repeatCount))
        }
        return (expanded, tick)
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return max(x, 1)
    }

    // MARK: - Per-frame delay parsing (ported from `parseGifFrameDurations`)

    private static func parseFrameDurations(_ data: Data) -> [Int] {
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

    private static func hasGifHeader(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 6 &&
            bytes[0] == UInt8(ascii: "G") &&
            bytes[1] == UInt8(ascii: "I") &&
            bytes[2] == UInt8(ascii: "F") &&
            bytes[3] == UInt8(ascii: "8") &&
            (bytes[4] == UInt8(ascii: "7") || bytes[4] == UInt8(ascii: "9")) &&
            bytes[5] == UInt8(ascii: "a")
    }

    private static func skipSubBlocks(_ bytes: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let blockSize = Int(bytes[index])
            index += 1
            if blockSize == 0 { return index }
            index += blockSize
        }
        return index
    }

    private static func readUnsignedShort(_ bytes: [UInt8], _ start: Int) -> Int {
        guard start + 1 < bytes.count else { return 0 }
        return Int(bytes[start]) | (Int(bytes[start + 1]) << 8)
    }
}
