import XCTest
import SharedCore
@testable import NuvioTV

/// Add-ons hub C, H1: the pure rules behind the hub's summary line and the reorder buttons.
final class AddonsHubSummaryTests: XCTestCase {

    private func manifest(_ id: String, catalogs: Int) -> AddonManifest {
        AddonManifest(
            id: id, name: id, description: "", version: "1.0.0", logoUrl: nil,
            resources: [AddonResource(name: "stream", types: ["movie"], idPrefixes: [])],
            types: ["movie"], idPrefixes: [],
            catalogs: (0..<catalogs).map { AddonCatalog(type: "movie", id: "\(id)-\($0)", name: "Cat \($0)", extra: []) },
            behaviorHints: AddonBehaviorHints(configurable: false, configurationRequired: false, adult: false, p2p: false),
            transportUrl: "https://\(id).example.com"
        )
    }

    private func addon(
        _ id: String, manifest: AddonManifest?, enabled: Bool,
        refreshing: Bool = false, error: String? = nil
    ) -> ManagedAddon {
        ManagedAddon(
            manifestUrl: "https://\(id).example.com/manifest.json", manifest: manifest,
            userSetName: nil, enabled: enabled, isRefreshing: refreshing, errorMessage: error
        )
    }

    private func catalog(_ key: String, enabled: Bool, collection: Bool = false) -> HomeCatalogSettingsItem {
        HomeCatalogSettingsItem(
            key: key, defaultTitle: key, addonName: "Add-on", customTitle: "", enabled: enabled,
            heroSourceEnabled: true, order: 0, isCollection: collection, collectionId: nil, isPinnedToTop: false
        )
    }

    private var addons: [ManagedAddon] {
        [
            addon("a", manifest: manifest("a", catalogs: 2), enabled: true),
            addon("b", manifest: manifest("b", catalogs: 1), enabled: false),
            addon("c", manifest: nil, enabled: true),
        ]
    }

    private var catalogs: [HomeCatalogSettingsItem] {
        [
            catalog("one", enabled: true),
            catalog("two", enabled: true),
            catalog("three", enabled: false),
            catalog("shelf", enabled: true, collection: true),
        ]
    }

    func testSummaryCountsAddonsCatalogsDebridAndPlugins() {
        let summary = AddonsViewModel.summary(
            addons: addons, catalogs: catalogs, debridConnectedNames: ["TorBox"],
            pluginsEnabled: true, pluginRepositories: 2, pluginProviders: 7
        )
        XCTAssertEqual(summary, AddonsViewModel.HubSummary(
            addonsInstalled: 3, addonsOn: 2, catalogsOn: 2, catalogsTotal: 3,
            debridConnected: ["TorBox"],
            plugins: AddonsViewModel.PluginSummary(repositories: 2, providers: 7)
        ))
    }

    /// The on-count is stable while a manifest reloads: enabled with no manifest still counts.
    func testEnabledAddonWithoutManifestCountsAsOn() {
        let list = [
            addon("a", manifest: nil, enabled: true),
            addon("b", manifest: nil, enabled: false),
        ]
        let summary = AddonsViewModel.summary(
            addons: list, catalogs: [], debridConnectedNames: [],
            pluginsEnabled: false, pluginRepositories: 0, pluginProviders: 0
        )
        XCTAssertEqual(summary.addonsOn, 1)
    }

    func testDisabledPluginsGiveNoPluginSummary() {
        let summary = AddonsViewModel.summary(
            addons: addons, catalogs: catalogs, debridConnectedNames: ["TorBox"],
            pluginsEnabled: false, pluginRepositories: 2, pluginProviders: 7
        )
        XCTAssertNil(summary.plugins)
    }

    func testMoveTarget() {
        XCTAssertNil(AddonsViewModel.moveTarget(index: 0, by: -1, count: 3))
        XCTAssertNil(AddonsViewModel.moveTarget(index: 2, by: 1, count: 3))
        XCTAssertEqual(AddonsViewModel.moveTarget(index: 1, by: 1, count: 3), 2)
        XCTAssertEqual(AddonsViewModel.moveTarget(index: 1, by: -1, count: 3), 0)
        XCTAssertNil(AddonsViewModel.moveTarget(index: 1, by: 0, count: 3))
        XCTAssertNil(AddonsViewModel.moveTarget(index: 5, by: -1, count: 3))
        XCTAssertNil(AddonsViewModel.moveTarget(index: 0, by: 1, count: 0))
    }

    func testRefreshOutcomeCountsErrorsAndMissingAsFailed() {
        let list = [
            addon("a", manifest: manifest("a", catalogs: 1), enabled: true),
            addon("b", manifest: nil, enabled: true, error: "boom"),
            // Still refreshing when the wait gave up: not a success.
            addon("c", manifest: manifest("c", catalogs: 1), enabled: true, refreshing: true),
        ]
        let urls: Set<String> = [
            "https://a.example.com/manifest.json",
            "https://b.example.com/manifest.json",
            "https://c.example.com/manifest.json",
            "https://gone.example.com/manifest.json",
        ]
        XCTAssertEqual(
            AddonsViewModel.refreshOutcome(addons: list, refreshedUrls: urls),
            AddonsViewModel.RefreshOutcome(succeeded: 1, failed: 3)
        )
        XCTAssertEqual(
            AddonsViewModel.refreshOutcome(addons: list, refreshedUrls: []),
            AddonsViewModel.RefreshOutcome(succeeded: 0, failed: 0)
        )
    }

    func testStatusPriority() {
        let m = manifest("a", catalogs: 0)
        XCTAssertEqual(AddonsViewModel.status(of: addon("a", manifest: m, enabled: false, refreshing: true)), .refreshing)
        XCTAssertEqual(AddonsViewModel.status(of: addon("a", manifest: nil, enabled: false, error: "x")), .unavailable)
        XCTAssertEqual(AddonsViewModel.status(of: addon("a", manifest: m, enabled: false, error: "x")), .disabled)
        XCTAssertEqual(AddonsViewModel.status(of: addon("a", manifest: m, enabled: true)), .active)
    }

    func testStatusStalledOnlyWhileRefreshing() {
        let m = manifest("a", catalogs: 0)
        let refreshing = addon("a", manifest: m, enabled: true, refreshing: true)
        let url = refreshing.manifestUrl
        XCTAssertEqual(AddonsViewModel.status(of: refreshing, stalled: [url]), .stalled)
        XCTAssertEqual(AddonsViewModel.status(of: refreshing, stalled: []), .refreshing)
        XCTAssertEqual(AddonsViewModel.status(of: refreshing, stalled: ["https://other.example.com/manifest.json"]), .refreshing)
        let idle = addon("a", manifest: m, enabled: true)
        XCTAssertEqual(AddonsViewModel.status(of: idle, stalled: [idle.manifestUrl]), .active)
    }

    func testHostKeepsAnIPv6LiteralAndDropsItsPort() {
        XCTAssertEqual(AddonsViewModel.host(of: "http://[::1]:8080/manifest.json"), "[::1]")
        XCTAssertEqual(AddonsViewModel.host(of: "x.y/a?u=http://z"), "x.y")
    }

    func testHostDropsEverythingButTheHost() {
        XCTAssertEqual(
            AddonsViewModel.host(of: "https://user:pw@Addon.example.com:8080/KEY/manifest.json?token=1"),
            "Addon.example.com"
        )
    }

    func testResourceLabelsMapOrderAndDeduplicate() {
        let m = AddonManifest(
            id: "x", name: "x", description: "", version: "1", logoUrl: nil,
            resources: ["stream", "catalog", "subtitles", "meta", "addon_catalog", "stream"]
                .map { AddonResource(name: $0, types: [], idPrefixes: []) },
            types: [], idPrefixes: [], catalogs: [],
            behaviorHints: AddonBehaviorHints(configurable: false, configurationRequired: false, adult: false, p2p: false),
            transportUrl: "https://x.example.com"
        )
        XCTAssertEqual(
            AddonsViewModel.resourceLabels(of: m),
            ["Streams", "Catalogs", "Subtitles", "Metadata", "Addon catalog"]
        )
    }

    func testLogoUrlsTakeEnabledNonEmptyUpToLimit() {
        func withLogo(_ id: String, _ logo: String?, enabled: Bool = true) -> ManagedAddon {
            let base = manifest(id, catalogs: 0)
            let m = AddonManifest(
                id: base.id, name: base.name, description: "", version: "1", logoUrl: logo,
                resources: base.resources, types: base.types, idPrefixes: [], catalogs: [],
                behaviorHints: base.behaviorHints, transportUrl: base.transportUrl
            )
            return addon(id, manifest: m, enabled: enabled)
        }
        let list = [
            withLogo("a", "https://a/l.png"), withLogo("b", ""), withLogo("c", "https://c/l.png", enabled: false),
            withLogo("d", nil), withLogo("e", "https://e/l.png"), withLogo("f", "https://f/l.png"),
        ]
        XCTAssertEqual(AddonsViewModel.logoUrls(of: list, limit: 2), ["https://a/l.png", "https://e/l.png"])
    }

    /// Review r1: two identical outcomes in a row carry different serials, so `onChange` (which
    /// compares with `==`) fires for the second one. Uses the real view model: an unsupported
    /// scheme fails in the synchronous validation path, with no network.
    @MainActor
    func testRepeatedInstallFailuresGetDifferentSerials() {
        let model = AddonsViewModel()
        model.install("ftp://x.y/a")
        guard case .failed(let firstMessage, let firstSerial)? = model.installOutcome else {
            return XCTFail("first install did not fail: \(String(describing: model.installOutcome))")
        }
        model.install("ftp://x.y/a")
        guard case .failed(let secondMessage, let secondSerial)? = model.installOutcome else {
            return XCTFail("second install did not fail: \(String(describing: model.installOutcome))")
        }
        XCTAssertEqual(firstMessage, secondMessage)
        XCTAssertNotEqual(firstSerial, secondSerial)
    }

    /// Review r2: with no manifest and no user-set name the title is the host, never the URL's
    /// last path segment (which can be a key).
    func testDisplayTitleFallsBackToTheHostWithoutAManifest() {
        let keyed = ManagedAddon(
            manifestUrl: "https://torbox.example.com/torbox=SECRETKEY/manifest.json", manifest: nil,
            userSetName: nil, enabled: true, isRefreshing: false, errorMessage: nil
        )
        XCTAssertEqual(AddonsViewModel.displayTitle(keyed), "torbox.example.com")
        let named = ManagedAddon(
            manifestUrl: keyed.manifestUrl, manifest: nil,
            userSetName: "Mine", enabled: true, isRefreshing: false, errorMessage: nil
        )
        XCTAssertEqual(AddonsViewModel.displayTitle(named), "Mine")
        XCTAssertEqual(
            AddonsViewModel.displayTitle(addon("a", manifest: manifest("a", catalogs: 0), enabled: true)), "a"
        )
    }

    /// H3: the install sheet's phase rule. Busy wins over a stale outcome; no outcome is idle.
    func testInstallPhaseMapsBusyOutcomesAndIdle() {
        let installed = AddonsViewModel.InstallOutcome.installed(name: "Torrentio", serial: 1)
        let failed = AddonsViewModel.InstallOutcome.failed(message: "nope", serial: 2)
        XCTAssertEqual(AddonInstallSheet.installPhase(isInstalling: true, outcome: nil), .checking)
        XCTAssertEqual(AddonInstallSheet.installPhase(isInstalling: true, outcome: failed), .checking)
        XCTAssertEqual(AddonInstallSheet.installPhase(isInstalling: true, outcome: installed), .checking)
        XCTAssertEqual(AddonInstallSheet.installPhase(isInstalling: false, outcome: installed), .installed(name: "Torrentio"))
        XCTAssertEqual(AddonInstallSheet.installPhase(isInstalling: false, outcome: failed), .failed(message: "nope"))
        XCTAssertEqual(AddonInstallSheet.installPhase(isInstalling: false, outcome: nil), .idle)
    }

    /// H4: collections keep their index; the rest sort stably by add-on position, matched by the
    /// manifest id in the key (`<manifest.id>:<type>:<catalogId>`), else by title.
    func testCatalogOrderFollowsAddonsAndPinsCollections() {
        func item(_ key: String, addon: String, collection: Bool = false) -> HomeCatalogSettingsItem {
            HomeCatalogSettingsItem(
                key: key, defaultTitle: key, addonName: addon, customTitle: "", enabled: true,
                heroSourceEnabled: true, order: 0, isCollection: collection, collectionId: nil, isPinnedToTop: false
            )
        }
        let items = [
            item("b:movie:b1", addon: "B"), item("a:movie:a1", addon: "A"), item("a:series:a2", addon: "A"),
            item("collection_shelf", addon: "Collections", collection: true), item("b:movie:b2", addon: "B"),
        ]
        XCTAssertEqual(
            SettingsViewModel.catalogOrderFollowingAddons(items: items, addonIds: ["a", "b"], addonTitles: ["A", "B"]),
            ["a:movie:a1", "a:series:a2", "b:movie:b1", "collection_shelf", "b:movie:b2"]
        )
        // Two add-ons sharing a title: the id still tells them apart.
        let twins = [item("b:movie:x", addon: "Same"), item("a:movie:y", addon: "Same")]
        XCTAssertEqual(
            SettingsViewModel.catalogOrderFollowingAddons(items: twins, addonIds: ["a", "b"], addonTitles: ["Same", "Same"]),
            ["a:movie:y", "b:movie:x"]
        )
        // No id match: falls back to the title; unknown add-ons go last.
        let legacy = [item("zzz", addon: "Gone"), item("k", addon: "B"), item("j", addon: "A")]
        XCTAssertEqual(
            SettingsViewModel.catalogOrderFollowingAddons(items: legacy, addonIds: [], addonTitles: ["A", "B"]),
            ["j", "k", "zzz"]
        )
    }

    func testIdPrefixDropsTypeAndCatalogId() {
        XCTAssertEqual(SettingsViewModel.idPrefix(of: "com.x.addon:movie:top"), "com.x.addon")
        XCTAssertEqual(SettingsViewModel.idPrefix(of: "a:b:movie:top"), "a:b")
        XCTAssertNil(SettingsViewModel.idPrefix(of: "collection_shelf"))
    }

    /// Where focus lands after a move, from the list after the move.
    func testMoveLanding() {
        let none = Set<String>()
        // Row 0 moved down in [a b c]: now [b a c], a sits at 1 and can go further down.
        XCTAssertEqual(CatalogOrderView.moveLanding(key: "a", direction: 1, orderedKeys: ["b", "a", "c"], pinnedKeys: none), "down:a")
        // Last row moved down: [b c a], a is at the end.
        XCTAssertEqual(CatalogOrderView.moveLanding(key: "a", direction: 1, orderedKeys: ["b", "c", "a"], pinnedKeys: none), "card:a")
        // A middle row moved up in [a b c d]: [a c b d], c at 1 can still go up.
        XCTAssertEqual(CatalogOrderView.moveLanding(key: "c", direction: -1, orderedKeys: ["a", "c", "b", "d"], pinnedKeys: none), "up:c")
        // Moved up to the top: [c a b d].
        XCTAssertEqual(CatalogOrderView.moveLanding(key: "c", direction: -1, orderedKeys: ["c", "a", "b", "d"], pinnedKeys: none), "card:c")
        // Up to just under a pinned collection: it cannot go further.
        XCTAssertEqual(CatalogOrderView.moveLanding(key: "c", direction: -1, orderedKeys: ["p", "c", "a"], pinnedKeys: ["p"]), "card:c")
        // Gone from the list: the name area.
        XCTAssertEqual(CatalogOrderView.moveLanding(key: "z", direction: 1, orderedKeys: ["a"], pinnedKeys: none), "card:z")
    }

    func testMovesToReachAFinalOrder() {
        let moves = SettingsViewModel.movesToReach(current: ["c", "a", "b"], desired: ["a", "b", "c"])
        XCTAssertEqual(moves.map(\.from), [1, 2])
        XCTAssertEqual(moves.map(\.to), [0, 1])
        XCTAssertTrue(SettingsViewModel.movesToReach(current: ["a", "b"], desired: ["a", "b"]).isEmpty)
        XCTAssertTrue(SettingsViewModel.movesToReach(current: ["a", "b"], desired: ["a", "x"]).isEmpty)
    }
}
