import XCTest
@testable import NuvioTV

/// Unit tests for `RejectedStreamLinks` (`Screens/RejectedStreamLinks.swift`, orivio batch item 2):
/// the per-title memory of links that failed recently. Every test runs against its own
/// `UserDefaults(suiteName:)` and an injected clock, so nothing touches the app's defaults.
final class RejectedStreamLinksTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "RejectedStreamLinksTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func reject(_ key: String, _ title: String = "tt1", at offset: TimeInterval = 0) {
        RejectedStreamLinks.reject(key, title: title, defaults: defaults, now: t0.addingTimeInterval(offset))
    }

    private func rejected(_ title: String = "tt1", at offset: TimeInterval = 0) -> Set<String> {
        RejectedStreamLinks.rejected(for: title, defaults: defaults, now: t0.addingTimeInterval(offset))
    }

    // MARK: Basics

    func testStorageKeyMatchesTheWipeRegistryEntry() {
        // `AccountDataStores` (shared) wipes exactly this plain key at sign-out.
        XCTAssertEqual(RejectedStreamLinks.storageKey, "tvos_rejected_stream_links_v1")
    }

    func testRejectedKeyIsReturnedForItsTitleOnly() {
        reject("hash1#0")
        XCTAssertEqual(rejected(), ["hash1#0"])
        XCTAssertTrue(rejected("tt2").isEmpty)
    }

    func testEmptyKeyOrTitleIsIgnored() {
        reject("")
        reject("hash1#0", "")
        XCTAssertTrue(rejected().isEmpty)
        XCTAssertTrue(rejected("").isEmpty)
        XCTAssertNil(defaults.data(forKey: RejectedStreamLinks.storageKey), "nothing should have been written")
    }

    // MARK: TTL

    func testEntryExpiresAfterEightHours() {
        reject("hash1#0")
        XCTAssertEqual(rejected(at: 8 * 3600 - 60), ["hash1#0"])
        XCTAssertTrue(rejected(at: 8 * 3600 + 60).isEmpty)
    }

    func testRejectingAgainRefreshesTheTimestamp() {
        reject("hash1#0")
        reject("hash1#0", at: 7 * 3600)
        XCTAssertEqual(rejected(at: 9 * 3600), ["hash1#0"])
    }

    // MARK: Caps

    func testPerTitleCapOfSixDropsTheOldestKey() {
        for index in 0..<7 {
            reject("key\(index)", at: TimeInterval(index))
        }
        let keys = rejected(at: 10)
        XCTAssertEqual(keys.count, RejectedStreamLinks.maxKeysPerTitle)
        XCTAssertFalse(keys.contains("key0"), "the oldest key goes first")
        XCTAssertTrue(keys.contains("key6"))
    }

    func testTitleCapOfSixtyDropsTheOldestTitle() {
        for index in 0...RejectedStreamLinks.maxTitles {
            reject("key", "title\(index)", at: TimeInterval(index))
        }
        let now = TimeInterval(RejectedStreamLinks.maxTitles + 1)
        XCTAssertTrue(rejected("title0", at: now).isEmpty, "the title rejected longest ago goes first")
        XCTAssertEqual(rejected("title1", at: now), ["key"])
        XCTAssertEqual(rejected("title\(RejectedStreamLinks.maxTitles)", at: now), ["key"])
    }

    // MARK: keep

    func testKeepClearsOnlyThatKey() {
        reject("a")
        reject("b")
        reject("a", "tt2")
        RejectedStreamLinks.keep("a", title: "tt1", defaults: defaults, now: t0)
        XCTAssertEqual(rejected(), ["b"])
        XCTAssertEqual(rejected("tt2"), ["a"], "the same key under another title is untouched")
    }

    func testKeepOfAnUnknownKeyIsANoOp() {
        reject("a")
        RejectedStreamLinks.keep("zzz", title: "tt1", defaults: defaults, now: t0)
        RejectedStreamLinks.keep("", title: "tt1", defaults: defaults, now: t0)
        XCTAssertEqual(rejected(), ["a"])
    }

    // MARK: Read-through (the sign-out wipe deletes the key under the type)

    func testDeletingTheKeyForgetsEverythingImmediately() {
        reject("a")
        defaults.removeObject(forKey: RejectedStreamLinks.storageKey)
        XCTAssertTrue(rejected().isEmpty, "no in-memory cache may survive the wipe")
    }
}
