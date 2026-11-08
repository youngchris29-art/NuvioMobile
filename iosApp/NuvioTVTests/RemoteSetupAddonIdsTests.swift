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
        XCTAssertEqual(ok(ids.resolve([(p, nil, true), (k, nil, false)], baseline: [k, p], currentUrls: [keyed, plain])), [
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
             (nil, "bare.example.com", nil)], baseline: [k],
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
            [(p, nil, true), (nil, "https://v3-cinemeta.strem.io/", false)], baseline: [p],
            currentUrls: [plain],
            sameManifest: AddonManifestURL.isSameManifest
        )), .alreadyInstalled)
        XCTAssertEqual(refusal(ids.resolve(
            [(nil, "https://a.example.com", true), (nil, "https://a.example.com/manifest.json", false)], baseline: [],
            currentUrls: [],
            sameManifest: AddonManifestURL.isSameManifest
        )), .invalidUrl, "two new rows for one manifest")
    }

    /// Dropping an unknown or stale entry would remove that add-on, so the proposal is refused.
    func testUnknownOrStaleIdsRefuseTheProposal() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        XCTAssertEqual(refusal(ids.resolve([(k, nil, true), ("s-99", nil, true)], baseline: [k], currentUrls: [keyed])), .stale)
        XCTAssertEqual(refusal(ids.resolve([(k, nil, true)], baseline: [k], currentUrls: [plain])), .stale, "the add-on left the list since")
        XCTAssertEqual(refusal(ids.resolve([(nil, nil, true)], baseline: [], currentUrls: [])), .stale)
    }

    /// An add-on that reached the TV after the page loaded is absent from the proposal and would
    /// be removed by omission, so a list that moved under the page refuses the proposal.
    func testAListThatChangedSinceThePageLoadedRefusesTheProposal() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        XCTAssertEqual(refusal(ids.resolve([(k, nil, false)], baseline: [k], currentUrls: [keyed, plain])), .stale,
                       "an add-on arrived during the alert")
        let p = ids.id(for: plain)
        XCTAssertEqual(refusal(ids.resolve([(k, nil, false)], baseline: [k, p], currentUrls: [plain, keyed])), .stale,
                       "the list was reordered")
        XCTAssertEqual(refusal(ids.resolve([(k, nil, false)], baseline: nil, currentUrls: [keyed])), .stale,
                       "no baseline")
        XCTAssertNotNil(ok(ids.resolve([(k, nil, false)], baseline: [k, p], currentUrls: [keyed, plain])),
                        "removing an add-on the page saw is fine")
    }

    func testBadNewAddressesRefuseTheProposal() {
        let ids = RemoteSetupAddonIds(prefix: "s")
        XCTAssertEqual(refusal(ids.resolve([(nil, "ftp://x.example.com/manifest.json", true)], baseline: [], currentUrls: [])), .invalidUrl)
        XCTAssertEqual(refusal(ids.resolve([(nil, "not a url", true)], baseline: [], currentUrls: [])), .invalidUrl)
    }

    func testDuplicateIdsAreDropped() {
        var ids = RemoteSetupAddonIds(prefix: "s")
        let k = ids.id(for: keyed)
        XCTAssertEqual(ok(ids.resolve([(k, nil, true), (k, nil, false)], baseline: [k], currentUrls: [keyed])),
                       [.init(url: keyed, enabled: true, isNew: false)])
    }
}

/// C1 review r2: confirming claims the change atomically with supersession.
final class RemoteSetupServerClaimTests: XCTestCase {
    func testASupersededChangeCannotBeClaimedAndSettledChangesStaySettled() throws {
        let server = RemoteSetupServer()
        server.minProposalInterval = 0
        let body = Data(#"{"rowOrder":["a"]}"#.utf8)
        let first = try XCTUnwrap(server.submitForTesting(body))
        let second = try XCTUnwrap(server.submitForTesting(body))
        XCTAssertFalse(server.isPending(id: first), "the newer proposal superseded it")
        XCTAssertFalse(server.claimForConfirm(id: first))
        XCTAssertTrue(server.claimForConfirm(id: second))
        XCTAssertFalse(server.claimForConfirm(id: second), "claimed once")
        server.reject(id: second, status: .stale)
        XCTAssertFalse(server.isPending(id: second))
        XCTAssertFalse(server.claimForConfirm(id: "unknown"))
    }
}
