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

    private func ok(_ result: Result<[RemoteSetupAddonIds.Resolved], RemoteSetupAddonIds.Refusal>) -> [RemoteSetupAddonIds.Resolved]? {
        if case .success(let value) = result { return value }
        return nil
    }

    private func refusal(_ result: Result<[RemoteSetupAddonIds.Resolved], RemoteSetupAddonIds.Refusal>) -> RemoteSetupAddonIds.Refusal? {
        if case .failure(let value) = result { return value }
        return nil
    }

    func testResolveMapsIdsBackAndKeepsOrderAndFlags() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed), p = ids.id(for: plain)
        XCTAssertEqual(ok(ids.resolve([(p, nil, true), (k, nil, false)], currentUrls: [keyed, plain])), [
            .init(url: plain, enabled: true, isNew: false),
            .init(url: keyed, enabled: false, isNew: false),
        ])
    }

    func testNewUrlsAreNormalisedTheWayTheRepositoryDoes() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        let resolved = ok(ids.resolve(
            [(k, nil, true),
             (nil, "  https://new.example.com/manifest.json ", true),
             (nil, "stremio://deep.example.com/manifest.json", false),
             (nil, "bare.example.com", nil)],
            currentUrls: [keyed],
            sameManifest: AddonManifestURL.isSameManifest
        ))
        XCTAssertEqual(resolved, [
            .init(url: keyed, enabled: true, isNew: false),
            .init(url: "https://new.example.com/manifest.json", enabled: true, isNew: true),
            .init(url: "https://deep.example.com/manifest.json", enabled: false, isNew: true),
            .init(url: "https://bare.example.com/manifest.json", enabled: nil, isNew: true),
        ])
    }

    /// A new row for an installed manifest would carry settings the TV cannot tell apart from the
    /// installed row's, so the proposal is refused instead of silently dropping one of them.
    func testANewRowForAnInstalledAddonIsRefused() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let p = ids.id(for: plain)
        XCTAssertEqual(refusal(ids.resolve(
            [(p, nil, true), (nil, "https://v3-cinemeta.strem.io/", false)],
            currentUrls: [plain],
            sameManifest: AddonManifestURL.isSameManifest
        )), .alreadyInstalled)
        XCTAssertEqual(refusal(ids.resolve(
            [(nil, "https://a.example.com", true), (nil, "https://a.example.com/manifest.json", false)],
            currentUrls: [],
            sameManifest: AddonManifestURL.isSameManifest
        )), .invalidUrl, "two new rows for one manifest")
    }

    /// Dropping an unknown or stale entry would remove that add-on, so the proposal is refused.
    func testUnknownOrStaleIdsRefuseTheProposal() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        XCTAssertEqual(refusal(ids.resolve([(k, nil, true), ("s-99", nil, true)], currentUrls: [keyed])), .stale)
        XCTAssertEqual(refusal(ids.resolve([(k, nil, true)], currentUrls: [plain])), .stale, "the add-on left the list since")
        XCTAssertEqual(refusal(ids.resolve([(nil, nil, true)], currentUrls: [])), .stale)
    }

    func testBadNewAddressesRefuseTheProposal() {
        let ids = RemoteSetupAddonIds(prefix: "s")
        XCTAssertEqual(refusal(ids.resolve([(nil, "ftp://x.example.com/manifest.json", true)], currentUrls: [])), .invalidUrl)
        XCTAssertEqual(refusal(ids.resolve([(nil, "not a url", true)], currentUrls: [])), .invalidUrl)
    }

    func testDuplicateIdsAreDropped() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        XCTAssertEqual(ok(ids.resolve([(k, nil, true), (k, nil, false)], currentUrls: [keyed])),
                       [.init(url: keyed, enabled: true, isNew: false)])
    }
}
