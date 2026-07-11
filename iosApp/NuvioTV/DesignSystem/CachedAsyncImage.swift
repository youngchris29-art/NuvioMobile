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
                        .font(.system(size: 44))
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

/// Loads and caches a single image URL. Memory cache is shared process-wide; disk cache is backed
/// by a dedicated `URLCache` so it never evicts the app's data responses.
@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var currentURL: URL?
    private var task: Task<Void, Never>?

    /// Process-wide in-memory decoded-image cache. Bounded by decoded bytes, not just count —
    /// 400 unbounded images (a 4K RGBA backdrop is ~32 MB decoded) could exceed the Apple TV
    /// process budget during long catalog browsing (HI-006).
    private static let memory: NSCache<NSURL, UIImage> = {
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

    func load(_ url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        task?.cancel()
        failed = false
        image = nil

        guard let url else { return }

        if let cached = Self.memory.object(forKey: url as NSURL) {
            image = cached
            return
        }

        task = Task { [weak self] in
            do {
                let (data, response) = try await Self.session.data(from: url)

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
                guard data.count <= Self.maxDownloadBytes else {
                    throw URLError(.dataLengthExceedsMaximum)
                }

                // Decode off the main actor, downsampled to at most the panel's own resolution —
                // decoding artwork at source dimensions is what made the old cache balloon.
                let decoded = try await Task.detached(priority: .userInitiated) {
                    try Self.downsample(data: data)
                }.value

                let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 4 * 1024 * 1024
                Self.memory.setObject(decoded, forKey: url as NSURL, cost: cost)
                if Task.isCancelled { return }
                guard let self, self.currentURL == url else { return }
                withAnimation(.easeIn(duration: 0.25)) { self.image = decoded }
            } catch {
                if Task.isCancelled { return }
                guard let self, self.currentURL == url else { return }
                self.failed = true
            }
        }
    }

    /// ImageIO downsampling: decodes straight to a bounded thumbnail without ever materializing
    /// the full-size bitmap. 1920 px covers a full-screen 1080p-point layer; posters and cards
    /// render far smaller. Absurd source dimensions are rejected before any real decode work.
    nonisolated private static func downsample(data: Data) throws -> UIImage {
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

    deinit { task?.cancel() }
}

/// Animated shimmer placeholder shown while an image loads.
struct ShimmerView: View {
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
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}
