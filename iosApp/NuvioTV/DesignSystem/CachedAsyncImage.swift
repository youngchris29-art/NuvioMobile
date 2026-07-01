import SwiftUI
import UIKit
import Combine

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

    /// Process-wide in-memory decoded-image cache.
    private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        return cache
    }()

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
                let (data, _) = try await Self.session.data(from: url)
                guard let decoded = UIImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                Self.memory.setObject(decoded, forKey: url as NSURL)
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
