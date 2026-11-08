import XCTest
@testable import NuvioTV

/// Add-ons hub v2, Stage C (C1): the Remote Setup page works with per-session add-on ids, never
/// with manifest URLs (they can carry debrid keys).
final class RemoteSetupAddonIdsTests: XCTestCase {
    private let keyed = "https://torrentio.strem.fun/torbox=SECRET/manifest.json"
    private let plain = "https://v3-cinemeta.strem.io/manifest.json"

    func testIdsAreStablePerSessionAndCarryNoUrl() {
        var ids = RemoteSetupAddonIds(prefix: "abc")
        let first = ids.id(for: keyed)
        XCTAssertEqual(ids.id(for: keyed), first, "stable within the session")
        XCTAssertNotEqual(ids.id(for: plain), first)
        XCTAssertFalse(first.contains("SECRET"))
        XCTAssertFalse(first.contains("torrentio"))
        XCTAssertEqual(ids.url(for: first), keyed)
        XCTAssertNil(ids.url(for: "abc-99"))
    }

    func testFreshSessionsMintDifferentIds() {
        var a = RemoteSetupAddonIds()
        var b = RemoteSetupAddonIds()
        XCTAssertNotEqual(a.id(for: keyed), b.id(for: keyed))
    }

    func testResolveMapsIdsBackAndKeepsOrderAndFlags() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed), p = ids.id(for: plain)
        let resolved = ids.resolve([(p, nil, true), (k, nil, false)], currentUrls: [keyed, plain])
        XCTAssertEqual(resolved, [
            .init(url: plain, enabled: true, isNew: false),
            .init(url: keyed, enabled: false, isNew: false),
        ])
    }

    func testNewUrlsInstallAndAnExistingManifestIsNotDuplicated() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        let resolved = ids.resolve(
            [(k, nil, true), (nil, "  https://new.example.com/manifest.json ", true), (nil, plain, nil)],
            currentUrls: [keyed, plain]
        )
        XCTAssertEqual(resolved, [
            .init(url: keyed, enabled: true, isNew: false),
            .init(url: "https://new.example.com/manifest.json", enabled: true, isNew: true),
            .init(url: plain, enabled: nil, isNew: false),
        ])
    }

    /// Dropping an unknown or stale entry would remove that add-on, so the proposal is rejected.
    func testUnknownOrStaleIdsRejectTheProposal() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        XCTAssertNil(ids.resolve([(k, nil, true), ("s-99", nil, true)], currentUrls: [keyed]))
        XCTAssertNil(ids.resolve([(k, nil, true)], currentUrls: [plain]), "the add-on left the list since")
    }

    func testMalformedEntriesRejectTheProposal() {
        let ids = RemoteSetupAddonIds(prefix: "s")
        XCTAssertNil(ids.resolve([(nil, nil, true)], currentUrls: []))
        XCTAssertNil(ids.resolve([(nil, "ftp://x.example.com/manifest.json", true)], currentUrls: []))
        XCTAssertNil(ids.resolve([(nil, "not a url", true)], currentUrls: []))
    }

    func testDuplicatesAreDropped() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        XCTAssertEqual(ids.resolve([(k, nil, true), (k, nil, false)], currentUrls: [keyed]),
                       [.init(url: keyed, enabled: true, isNew: false)])
    }
}
