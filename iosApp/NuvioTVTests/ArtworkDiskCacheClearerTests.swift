import XCTest
@testable import NuvioTV

/// GitHub #34 (Clear Cache): the orchestrator production calls, run against injected caches. Each
/// test builds its own artwork and GIF `URLCache`s in fresh temporary folders, an unrelated third
/// cache, a neighbour directory standing in for `PayloadStores`, and a fresh failure memo. The real
/// `ArtworkStore` caches are never touched.
///
/// What `clear()` guarantees: the failed-URL memo is empty when it returns, and the system releases
/// both caches' disk storage asynchronously (about 0.1 s on the simulator). A `URLCache`'s own
/// in-memory response store is not purged by `removeAllCachedResponses()`. So the eviction tests
/// build their caches with `memoryCapacity: 0`, which makes every lookup a disk lookup, and poll
/// (every 50 ms, at most 5 s) for the disk release.
@MainActor
final class ArtworkDiskCacheClearerTests: XCTestCase {
    private var root: URL!
    nonisolated(unsafe) private static var roots: [URL] = []

    override class func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // The folder is left for `tearDown()` of the class: a cache's database can still be open
        // here, and unlinking it under SQLite corrupts that connection.
        if let root { Self.roots.append(root) }
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private func directory(_ name: String) -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A disk-only cache by default. The directory exists before the cache opens it: a `URLCache`
    /// whose folder is missing cannot open its database, and its writes and deletes then fail.
    private func makeCache(_ name: String, memoryCapacity: Int = 0) -> URLCache {
        URLCache(memoryCapacity: memoryCapacity, diskCapacity: 32 * 1024 * 1024, directory: directory(name))
    }

    private func url(_ path: String) -> URL { URL(string: "https://img.example.test/\(path)")! }

    /// Stores a response and waits (bounded) until the cache answers it: the disk write is
    /// asynchronous, and a seeded write landing after the clear would look like a failed eviction.
    private func store(_ url: URL, in cache: URLCache, bytes: Int = 2048) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/jpeg",
                                                      "Cache-Control": "max-age=86400"])!
        let data = Data(repeating: 0xAB, count: bytes)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
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

    // MARK: - Tests

    func testClearEmptiesBothCaches() {
        let artwork = makeCache("artwork")
        let gif = makeCache("gif")
        let artworkURLs = [url("a1.jpg"), url("a2.jpg")]
        let gifURLs = [url("g1.gif"), url("g2.gif")]
        artworkURLs.forEach { store($0, in: artwork) }
        gifURLs.forEach { store($0, in: gif) }
        XCTAssertTrue(artworkURLs.allSatisfy { isCached($0, in: artwork) }, "fixture: artwork seeded")
        XCTAssertTrue(gifURLs.allSatisfy { isCached($0, in: gif) }, "fixture: gif seeded")

        ArtworkDiskCacheClearer(artworkCache: artwork, gifCache: gif, failures: ArtworkFailureMemo()).clear()

        XCTAssertTrue(poll {
            artworkURLs.allSatisfy { !self.isCached($0, in: artwork) } && gifURLs.allSatisfy { !self.isCached($0, in: gif) }
        }, "the disk entries were not released within 5 s: artwork=\(artworkURLs.map { isCached($0, in: artwork) }) gif=\(gifURLs.map { isCached($0, in: gif) })")
    }

    func testClearEmptiesFailureMemo() {
        let memo = ArtworkFailureMemo()
        let failed = [url("f1.jpg"), url("f2.jpg"), url("f3.jpg")]
        failed.forEach { memo.noteFailure($0) }
        XCTAssertEqual(memo.count, 3)

        ArtworkDiskCacheClearer(artworkCache: makeCache("artwork"), gifCache: makeCache("gif"), failures: memo).clear()

        // Synchronous: no wait.
        XCTAssertEqual(memo.count, 0)
        for u in failed {
            XCTAssertFalse(memo.hasFailed(u, ttl: ArtworkStore.failedURLTTL), "\(u)")
        }
    }

    func testClearLeavesUnrelatedCacheAndDirectory() throws {
        let artwork = makeCache("artwork")
        let gif = makeCache("gif")
        let unrelated = makeCache("unrelated")
        let artworkURL = url("a1.jpg")
        let unrelatedURL = url("data.json")
        store(artworkURL, in: artwork)
        store(unrelatedURL, in: unrelated)
        XCTAssertTrue(isCached(unrelatedURL, in: unrelated), "fixture: unrelated seeded")

        let neighbour = directory("PayloadStores")
        let file = neighbour.appendingPathComponent("payload.json")
        let bytes = Data("{\"addons\":[1,2,3]}".utf8)
        try bytes.write(to: file)

        ArtworkDiskCacheClearer(artworkCache: artwork, gifCache: gif, failures: ArtworkFailureMemo()).clear()

        // After the same wait that shows the artwork entry released, the others are untouched.
        XCTAssertTrue(poll { !self.isCached(artworkURL, in: artwork) }, "the artwork entry was not released within 5 s")
        XCTAssertTrue(isCached(unrelatedURL, in: unrelated), "an unrelated URLCache must keep its responses")
        XCTAssertEqual(try Data(contentsOf: file), bytes, "a neighbour directory must keep its files")
    }

    func testRepopulationAfterClearIsKept() {
        let artwork = makeCache("artwork")
        let gif = makeCache("gif")
        let memo = ArtworkFailureMemo()
        let old = url("old.jpg")
        store(old, in: artwork)
        memo.noteFailure(url("old-fail.jpg"))
        let clearer = ArtworkDiskCacheClearer(artworkCache: artwork, gifCache: gif, failures: memo)

        clearer.clear()
        XCTAssertTrue(poll { !self.isCached(old, in: artwork) }, "the old entry was not released within 5 s")
        // The permitted in-flight case: a response stored and a failure noted after the clear.
        let late = url("late.jpg")
        let lateFail = url("late-fail.jpg")
        store(late, in: artwork)
        memo.noteFailure(lateFail)

        XCTAssertTrue(isCached(late, in: artwork))
        XCTAssertFalse(isCached(old, in: artwork))
        XCTAssertTrue(memo.hasFailed(lateFail, ttl: ArtworkStore.failedURLTTL))
        XCTAssertFalse(memo.hasFailed(url("old-fail.jpg"), ttl: ArtworkStore.failedURLTTL))
        XCTAssertEqual(memo.count, 1)
    }

    func testClearOnEmptyStoresIsIdempotent() {
        let artwork = makeCache("artwork")
        let gif = makeCache("gif")
        let memo = ArtworkFailureMemo()
        let clearer = ArtworkDiskCacheClearer(artworkCache: artwork, gifCache: gif, failures: memo)

        clearer.clear()
        clearer.clear()

        XCTAssertEqual(memo.count, 0)
        XCTAssertFalse(isCached(url("a1.jpg"), in: artwork))
        XCTAssertFalse(isCached(url("g1.gif"), in: gif))
    }

    /// The accepted behaviour with an in-memory response store, as production has: a just-stored
    /// response may still answer from memory after `clear()`; nothing is asserted about that. The
    /// disk entry, read through a second disk-only instance on the same directory, is released
    /// within the bound — when that second instance can read the store at all. Two `URLCache`
    /// instances over one directory are not a supported configuration, so if the second one cannot
    /// see the entry before the clear, that part is reported and not asserted.
    func testInMemoryResponseStoreSurvivesClearButDiskIsReleased() {
        let artworkDir = directory("artwork")
        let artwork = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024, directory: artworkDir)
        let gif = makeCache("gif", memoryCapacity: 4 * 1024 * 1024)
        let u = url("memory.jpg")
        store(u, in: artwork)
        let diskView = URLCache(memoryCapacity: 0, diskCapacity: 32 * 1024 * 1024, directory: artworkDir)
        let diskViewReadable = poll { self.isCached(u, in: diskView) }

        ArtworkDiskCacheClearer(artworkCache: artwork, gifCache: gif, failures: ArtworkFailureMemo()).clear()

        let memoryStillAnswers = isCached(u, in: artwork)
        if diskViewReadable {
            XCTAssertTrue(poll { !self.isCached(u, in: diskView) }, "the disk entry was not released within 5 s")
        }
        let note = XCTAttachment(string: "memory_store_answers_after_clear=\(memoryStillAnswers) second_instance_readable=\(diskViewReadable)")
        note.name = "in_memory_store_behaviour"
        note.lifetime = .keepAlways
        add(note)
        NSLog("[ArtworkDiskCacheClearerTests] memory_store_answers_after_clear=%d second_instance_readable=%d",
              memoryStillAnswers ? 1 : 0, diskViewReadable ? 1 : 0)
    }

    /// The `ArtworkStore` forwards keep today's behaviour: the TTL expiry and the 512-entry reset.
    /// Unique URLs, and the shared memo is emptied before and after.
    func testFailureMemoForwardsKeepBehaviour() {
        ArtworkStore.clearFailedURLs()
        defer { ArtworkStore.clearFailedURLs() }
        let base = Date(timeIntervalSince1970: 1_000_000)
        let prefix = UUID().uuidString

        // TTL: inside the window it has failed, past it the entry expires and is dropped.
        let ttlURL = url("\(prefix)/ttl.jpg")
        ArtworkStore.noteFailure(ttlURL, now: base)
        XCTAssertTrue(ArtworkStore.hasFailed(ttlURL, now: base.addingTimeInterval(ArtworkStore.failedURLTTL - 1)))
        XCTAssertFalse(ArtworkStore.hasFailed(ttlURL, now: base.addingTimeInterval(ArtworkStore.failedURLTTL + 1)))
        XCTAssertEqual(ArtworkStore.failures.count, 0, "an expired entry is dropped on lookup")

        // Size bound: 512 entries, then the 513th starts the set over.
        for i in 0..<512 { ArtworkStore.noteFailure(url("\(prefix)/n\(i).jpg"), now: base) }
        XCTAssertEqual(ArtworkStore.failures.count, 512)
        XCTAssertTrue(ArtworkStore.hasFailed(url("\(prefix)/n0.jpg"), now: base))
        let overflow = url("\(prefix)/overflow.jpg")
        ArtworkStore.noteFailure(overflow, now: base)
        XCTAssertEqual(ArtworkStore.failures.count, 1)
        XCTAssertFalse(ArtworkStore.hasFailed(url("\(prefix)/n0.jpg"), now: base))
        XCTAssertTrue(ArtworkStore.hasFailed(overflow, now: base))

        // clearFailedURLs() empties the same memo.
        ArtworkStore.clearFailedURLs()
        XCTAssertEqual(ArtworkStore.failures.count, 0)
        XCTAssertFalse(ArtworkStore.hasFailed(overflow, now: base))
    }
}
