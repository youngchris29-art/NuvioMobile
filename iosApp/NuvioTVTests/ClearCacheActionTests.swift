import XCTest
@testable import NuvioTV

/// GitHub #34 (Clear Cache): the confirm action, with an injected clearer over temporary disk-only
/// caches (`memoryCapacity: 0`, so lookups show the disk) and the announcement captured instead of
/// spoken. The failed-URL memo is empty when `run` returns; the disk release is asynchronous, so the
/// caches are polled every 50 ms for at most 5 s.
@MainActor
final class ClearCacheActionTests: XCTestCase {
    private var root: URL!
    nonisolated(unsafe) private static var roots: [URL] = []
    private var originalPost: ((String) -> Void)!
    private var spoken: [String] = []

    override class func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        originalPost = ClearCacheAnnouncer.post
        spoken = []
        ClearCacheAnnouncer.post = { [weak self] in self?.spoken.append($0) }
    }

    override func tearDownWithError() throws {
        ClearCacheAnnouncer.post = originalPost
        // The folder is left for `tearDown()` of the class: a cache's database can still be open
        // here, and unlinking it under SQLite corrupts that connection.
        if let root { Self.roots.append(root) }
        try super.tearDownWithError()
    }

    /// Disk-only. The directory exists before the cache opens it.
    private func makeCache(_ name: String) -> URLCache {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return URLCache(memoryCapacity: 0, diskCapacity: 32 * 1024 * 1024, directory: directory)
    }

    private func url(_ path: String) -> URL { URL(string: "https://img.example.test/\(path)")! }

    /// Stores a response and waits (bounded) until the cache answers it.
    private func store(_ url: URL, in cache: URLCache) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/jpeg",
                                                      "Cache-Control": "max-age=86400"])!
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data(repeating: 1, count: 1024),
                                                    storagePolicy: .allowed),
                                  for: URLRequest(url: url))
        _ = poll { self.isCached(url, in: cache) }
    }

    private func isCached(_ url: URL, in cache: URLCache) -> Bool {
        cache.cachedResponse(for: URLRequest(url: url)) != nil
    }

    /// Checks `condition` every 50 ms for at most 5 s.
    private func poll(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= end { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private func seededClearer() -> (ArtworkDiskCacheClearer, [URL]) {
        let artwork = makeCache("artwork")
        let gif = makeCache("gif")
        let memo = ArtworkFailureMemo()
        let a = url("a.jpg"), g = url("g.gif")
        store(a, in: artwork)
        store(g, in: gif)
        memo.noteFailure(url("f.jpg"))
        return (ArtworkDiskCacheClearer(artworkCache: artwork, gifCache: gif, failures: memo), [a, g])
    }

    private func released(_ clearer: ArtworkDiskCacheClearer, _ urls: [URL]) -> Bool {
        poll { !self.isCached(urls[0], in: clearer.artworkCache) && !self.isCached(urls[1], in: clearer.gifCache) }
    }

    func testRunClearsBeforeItReturns() {
        let (clearer, urls) = seededClearer()
        XCTAssertTrue(isCached(urls[0], in: clearer.artworkCache), "fixture: artwork seeded")
        XCTAssertTrue(isCached(urls[1], in: clearer.gifCache), "fixture: gif seeded")
        XCTAssertEqual(clearer.failures.count, 1, "fixture: memo seeded")

        ClearCacheAction.run(clearer)

        // The memo is empty on return; the disk storage is released shortly after.
        XCTAssertEqual(clearer.failures.count, 0)
        XCTAssertTrue(released(clearer, urls), "the disk entries were not released within 5 s")
    }

    func testRunAnnouncesOnce() {
        let (clearer, urls) = seededClearer()

        ClearCacheAction.run(clearer)
        XCTAssertEqual(spoken, [String(localized: "Cache cleared")])

        ClearCacheAction.run(clearer)
        XCTAssertEqual(spoken, [String(localized: "Cache cleared"), String(localized: "Cache cleared")])
        XCTAssertEqual(clearer.failures.count, 0)
        XCTAssertTrue(released(clearer, urls), "the disk entries were not released within 5 s")
    }
}
