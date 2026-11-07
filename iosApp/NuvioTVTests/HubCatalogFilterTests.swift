import XCTest
import SharedCore
@testable import NuvioTV

/// Add-ons hub v2, A6 review r3: the Catalogs filter is derived from the CURRENT add-on list, so a
/// refreshed manifest or an ownership change shows up while the filtered pane is open.
final class HubCatalogFilterTests: XCTestCase {
    private func manifest(_ id: String, catalogs: [String]) -> AddonManifest {
        AddonManifest(
            id: id, name: id, description: "", version: "1.0.0", logoUrl: nil,
            resources: [AddonResource(name: "catalog", types: ["movie"], idPrefixes: [])],
            types: ["movie"], idPrefixes: [],
            catalogs: catalogs.map { AddonCatalog(type: "movie", id: $0, name: $0, extra: []) },
            behaviorHints: AddonBehaviorHints(configurable: false, configurationRequired: false, adult: false, p2p: false),
            transportUrl: "https://\(id).example.com"
        )
    }

    private func addon(_ slug: String, _ manifest: AddonManifest?, enabled: Bool = true) -> ManagedAddon {
        ManagedAddon(
            manifestUrl: "https://\(slug).example.com/manifest.json", manifest: manifest,
            userSetName: nil, enabled: enabled, isRefreshing: false, errorMessage: nil
        )
    }

    func testFilterFollowsARefreshedManifest() {
        let before = [addon("a", manifest("org.a", catalogs: ["top"]))]
        let url = before[0].manifestUrl
        XCTAssertEqual(AddonsHubSplitView.catalogFilter(for: url, addons: before)?.keys, ["org.a:movie:top"])
        let after = [addon("a", manifest("org.a", catalogs: ["top", "new"]))]
        XCTAssertEqual(AddonsHubSplitView.catalogFilter(for: url, addons: after)?.keys,
                       ["org.a:movie:top", "org.a:movie:new"])
        XCTAssertEqual(AddonsHubSplitView.catalogFilter(for: url, addons: after)?.addonTitle, "org.a")
    }

    func testFilterFollowsOwnershipChanges() {
        let first = addon("first", manifest("org.twin", catalogs: ["top"]))
        let mirror = addon("mirror", manifest("org.twin", catalogs: ["top"]))
        XCTAssertEqual(AddonsHubSplitView.catalogFilter(for: mirror.manifestUrl, addons: [first, mirror])?.keys, [])
        let firstOff = addon("first", manifest("org.twin", catalogs: ["top"]), enabled: false)
        XCTAssertEqual(AddonsHubSplitView.catalogFilter(for: mirror.manifestUrl, addons: [firstOff, mirror])?.keys,
                       ["org.twin:movie:top"])
    }

    func testFilterIsNilWithoutAnInstalledAddon() {
        XCTAssertNil(AddonsHubSplitView.catalogFilter(for: nil, addons: []))
        XCTAssertNil(AddonsHubSplitView.catalogFilter(for: "https://gone.example.com/manifest.json", addons: []))
    }
}
