import XCTest
import SharedCore
@testable import NuvioTV

/// H5 device finding: the sheet once rendered `manifest.description`, which on a bridged Kotlin
/// object is NSObject's `description` (the data class's toString, transportUrl and all).
final class AddonDetailPaneBlurbTests: XCTestCase {
    func testBlurbIsTheManifestDescriptionNotTheObjectDump() {
        let manifest = AddonManifest(
            id: "org.example.keyed", name: "Keyed", description: "Streams from a private tracker.",
            version: "2.0.0", logoUrl: nil,
            resources: [AddonResource(name: "stream", types: ["movie"], idPrefixes: [])],
            types: ["movie"], idPrefixes: [], catalogs: [],
            behaviorHints: AddonBehaviorHints(configurable: false, configurationRequired: false, adult: false, p2p: false),
            transportUrl: "https://example.com/SECRET-KEY-123/manifest.json"
        )
        let blurb = AddonDetailPane.blurb(of: manifest)
        XCTAssertEqual(blurb, "Streams from a private tracker.")
        XCTAssertFalse(blurb.contains("transportUrl"))
        XCTAssertFalse(blurb.contains("SECRET-KEY-123"))
        XCTAssertTrue(AddonDetailPane.blurb(of: manifest).isEmpty == false)
    }
}

/// Add-ons hub v2, A5: the pure rules behind the detail page.
final class AddonDetailPaneTests: XCTestCase {
    typealias Row = AddonDetailPane.DetailRow

    private func manifest(_ id: String, resources: [String]) -> AddonManifest {
        AddonManifest(
            id: id, name: id, description: "", version: "1.0.0", logoUrl: nil,
            resources: resources.map { AddonResource(name: $0, types: ["movie"], idPrefixes: []) },
            types: ["movie"], idPrefixes: [], catalogs: [],
            behaviorHints: AddonBehaviorHints(configurable: false, configurationRequired: false, adult: false, p2p: false),
            transportUrl: "https://\(id).example.com"
        )
    }

    private func addon(_ id: String, manifest: AddonManifest?, enabled: Bool = true) -> ManagedAddon {
        ManagedAddon(
            manifestUrl: "https://\(id).example.com/manifest.json", manifest: manifest,
            userSetName: nil, enabled: enabled, isRefreshing: false, errorMessage: nil
        )
    }

    private func catalog(_ key: String, enabled: Bool, collection: Bool = false, addonName: String = "Mine") -> HomeCatalogSettingsItem {
        HomeCatalogSettingsItem(
            key: key, defaultTitle: "t", addonName: addonName, customTitle: "", enabled: enabled,
            heroSourceEnabled: true, order: 0, isCollection: collection, collectionId: nil, isPinnedToTop: false
        )
    }

    // MARK: streamPosition

    func testStreamPositionSkipsDisabledCatalogOnlyAndManifestLessAddons() {
        let list = [
            addon("a", manifest: manifest("a", resources: ["stream"])),
            addon("off", manifest: manifest("off", resources: ["stream"]), enabled: false),
            addon("cat", manifest: manifest("cat", resources: ["catalog"])),
            addon("none", manifest: nil),
            addon("b", manifest: manifest("b", resources: ["catalog", "stream"])),
        ]
        XCTAssertEqual(AddonDetailPane.streamPosition(of: list[0].manifestUrl, in: list), 1)
        XCTAssertNil(AddonDetailPane.streamPosition(of: list[1].manifestUrl, in: list))
        XCTAssertNil(AddonDetailPane.streamPosition(of: list[2].manifestUrl, in: list))
        XCTAssertNil(AddonDetailPane.streamPosition(of: list[3].manifestUrl, in: list))
        XCTAssertEqual(AddonDetailPane.streamPosition(of: list[4].manifestUrl, in: list), 2)
        XCTAssertNil(AddonDetailPane.streamPosition(of: "https://missing.example.com/manifest.json", in: list))
    }

    // MARK: headerLine / ordinal

    func testHeaderLineJoinsVersionHostAndPosition() {
        XCTAssertEqual(
            AddonDetailPane.headerLine(version: "0.0.15", host: "torrentio.strem.fun", streamPosition: 2),
            "Version 0.0.15 · torrentio.strem.fun · 2nd in stream order"
        )
        XCTAssertEqual(
            AddonDetailPane.headerLine(version: nil, host: "torrentio.strem.fun", streamPosition: 2),
            "torrentio.strem.fun · 2nd in stream order"
        )
        XCTAssertEqual(
            AddonDetailPane.headerLine(version: "1.0.0", host: "h.example.com", streamPosition: nil),
            "Version 1.0.0 · h.example.com"
        )
        XCTAssertEqual(
            AddonDetailPane.headerLine(version: "", host: "h.example.com", streamPosition: nil),
            "h.example.com"
        )
    }

    func testOrdinalInEnglish() {
        XCTAssertEqual(AddonDetailPane.ordinal(1), "1st")
        XCTAssertEqual(AddonDetailPane.ordinal(2), "2nd")
        XCTAssertEqual(AddonDetailPane.ordinal(3), "3rd")
        XCTAssertEqual(AddonDetailPane.ordinal(11), "11th")
        XCTAssertEqual(AddonDetailPane.ordinal(22), "22nd")
    }

    // MARK: catalogs

    private func catalogManifest(_ id: String, catalogs: [AddonCatalog]) -> AddonManifest {
        AddonManifest(
            id: id, name: id, description: "", version: "1.0.0", logoUrl: nil,
            resources: [AddonResource(name: "catalog", types: ["movie"], idPrefixes: [])],
            types: ["movie"], idPrefixes: [], catalogs: catalogs,
            behaviorHints: AddonBehaviorHints(configurable: false, configurationRequired: false, adult: false, p2p: false),
            transportUrl: "https://\(id).example.com"
        )
    }

    func testCatalogKeysFollowTheSharedKeyFormatAndSkipRequiredExtras() {
        let mine = catalogManifest("org.mine", catalogs: [
            AddonCatalog(type: "movie", id: "top", name: "Top", extra: []),
            AddonCatalog(type: "series", id: "top", name: "Top", extra: []),
            AddonCatalog(type: "movie", id: "search", name: "Search",
                         extra: [AddonExtraProperty(name: "search", isRequired: true, options: [], optionsLimit: nil)]),
        ])
        let list = [addon("mine", manifest: mine)]
        XCTAssertEqual(AddonDetailPane.catalogKeys(ownedBy: list[0].manifestUrl, in: list),
                       ["org.mine:movie:top", "org.mine:series:top"])
        XCTAssertTrue(AddonDetailPane.catalogKeys(ownedBy: addon("none", manifest: nil).manifestUrl,
                                                  in: [addon("none", manifest: nil)]).isEmpty)
    }

    /// Review A5-r2: a mirror install (same manifest, another URL) owns only what its twin above
    /// it did not claim; a disabled install owns nothing (Home skips it).
    func testCatalogKeysFollowHomesOwnershipRule() {
        let shared = [AddonCatalog(type: "movie", id: "top", name: "Top", extra: [])]
        let first = addon("first", manifest: catalogManifest("org.twin", catalogs: shared))
        let mirror = addon("mirror", manifest: catalogManifest("org.twin", catalogs: shared + [
            AddonCatalog(type: "movie", id: "extra", name: "Extra", extra: []),
        ]))
        let list = [first, mirror]
        XCTAssertEqual(AddonDetailPane.catalogKeys(ownedBy: first.manifestUrl, in: list), ["org.twin:movie:top"])
        XCTAssertEqual(AddonDetailPane.catalogKeys(ownedBy: mirror.manifestUrl, in: list), ["org.twin:movie:extra"])
        let firstOff = addon("first", manifest: catalogManifest("org.twin", catalogs: shared), enabled: false)
        XCTAssertTrue(AddonDetailPane.catalogKeys(ownedBy: firstOff.manifestUrl, in: [firstOff, mirror]).isEmpty)
        XCTAssertEqual(AddonDetailPane.catalogKeys(ownedBy: mirror.manifestUrl, in: [firstOff, mirror]),
                       ["org.twin:movie:top", "org.twin:movie:extra"])
    }

    /// Review A5-r1: matched by key, so a renamed add-on keeps its catalogs and another add-on
    /// with the same display name does not add to them.
    func testCatalogCountsMatchByKeyAndSkipCollections() {
        let keys: Set<String> = ["org.mine:movie:top", "org.mine:series:top", "org.mine:movie:new"]
        let items = [
            catalog("org.mine:movie:top", enabled: true, addonName: "Renamed by me"),
            catalog("org.mine:series:top", enabled: false),
            catalog("org.mine:movie:new", enabled: true),
            catalog("collection_1", enabled: true, collection: true),
            catalog("org.other:movie:top", enabled: true, addonName: "Mine"),
        ]
        let counts = AddonDetailPane.catalogCounts(keys: keys, catalogs: items)
        XCTAssertEqual(counts.on, 2)
        XCTAssertEqual(counts.total, 3)
        let none = AddonDetailPane.catalogCounts(keys: [], catalogs: items)
        XCTAssertEqual(none.on, 0)
        XCTAssertEqual(none.total, 0)
        XCTAssertEqual(AddonDetailPane.catalogsValue(on: 2, total: 3), "2 of 3 on")
    }

    // MARK: rows / defaultRow

    private func rows(
        configurable: Bool = true, isReadOnly: Bool = false, addonCount: Int = 3,
        status: AddonsViewModel.AddonStatus = .active, catalogTotal: Int = 4, configureFirst: Bool = false
    ) -> [Row] {
        AddonDetailPane.rows(
            configurable: configurable, isReadOnly: isReadOnly, addonCount: addonCount,
            status: status, catalogTotal: catalogTotal, configureFirst: configureFirst
        )
    }

    func testFullRowSet() {
        XCTAssertEqual(rows(), [.enabled, .configure, .refresh, .move, .catalogs, .remove])
    }

    func testRowsDropWhatDoesNotApply() {
        XCTAssertEqual(rows(configurable: false), [.enabled, .refresh, .move, .catalogs, .remove])
        XCTAssertEqual(rows(addonCount: 1), [.enabled, .configure, .refresh, .catalogs, .remove])
        XCTAssertEqual(rows(catalogTotal: 0), [.enabled, .configure, .refresh, .move, .remove])
    }

    func testStalledShowsRetryInPlaceOfRefresh() {
        XCTAssertEqual(rows(status: .stalled), [.enabled, .configure, .retry, .move, .catalogs, .remove])
    }

    /// Stage A review: read-only profiles keep Configure (the QR) on a configurable add-on.
    func testReadOnlyOffersRefreshConfigureAndCatalogsOnly() {
        XCTAssertEqual(rows(isReadOnly: true), [.refresh, .configure, .catalogs])
        XCTAssertEqual(rows(configurable: false, isReadOnly: true), [.refresh, .catalogs])
        XCTAssertEqual(rows(configurable: false, isReadOnly: true, catalogTotal: 0), [.refresh])
        XCTAssertEqual(rows(isReadOnly: true, status: .stalled, configureFirst: true), [.configure, .retry, .catalogs])
    }

    func testConfigureFirstMovesConfigureToTheFront() {
        XCTAssertEqual(rows(configureFirst: true), [.configure, .enabled, .refresh, .move, .catalogs, .remove])
        XCTAssertEqual(
            rows(configurable: false, configureFirst: true), [.enabled, .refresh, .move, .catalogs, .remove]
        )
    }

    func testDefaultRow() {
        XCTAssertEqual(AddonDetailPane.defaultRow(rows(), configureFirst: false), .enabled)
        XCTAssertEqual(AddonDetailPane.defaultRow(rows(configureFirst: true), configureFirst: true), .configure)
        XCTAssertEqual(AddonDetailPane.defaultRow(rows(configurable: false), configureFirst: true), .enabled)
        XCTAssertEqual(AddonDetailPane.defaultRow(rows(isReadOnly: true), configureFirst: false), .refresh)
        XCTAssertNil(AddonDetailPane.defaultRow([], configureFirst: false))
    }

    // MARK: configureUrl / locationLine

    func testPageItemsPutTheCodeRightAfterConfigure() {
        let rows: [Row] = [.configure, .enabled, .refresh, .remove]
        XCTAssertEqual(AddonDetailPane.pageItems(rows, showsCode: true),
                       [.row(.configure), .code, .row(.enabled), .row(.refresh), .row(.remove)])
        XCTAssertEqual(AddonDetailPane.pageItems(rows, showsCode: false), rows.map { .row($0) })
        XCTAssertEqual(AddonDetailPane.pageItems([.enabled, .refresh], showsCode: true), [.row(.enabled), .row(.refresh)])
    }

    func testConfigureUrl() {
        XCTAssertEqual(
            AddonDetailPane.configureUrl("https://a.example.com/manifest.json?x=1"),
            "https://a.example.com/configure?x=1"
        )
        XCTAssertEqual(
            AddonDetailPane.configureUrl("https://a.example.com/torbox=KEY/manifest.json"),
            "https://a.example.com/torbox=KEY/configure"
        )
        XCTAssertEqual(AddonDetailPane.configureUrl("https://a.example.com/"), "https://a.example.com/configure")
        XCTAssertEqual(AddonDetailPane.configureUrl("https://a.example.com"), "https://a.example.com/configure")
    }

    func testLocationLineHidesKeys() {
        XCTAssertEqual(
            AddonDetailPane.locationLine("https://a.example.com/manifest.json"), "a.example.com/manifest.json"
        )
        XCTAssertEqual(
            AddonDetailPane.locationLine("https://a.example.com/manifest.json?key=SECRET"),
            "a.example.com/manifest.json (key hidden)"
        )
        let keyed = AddonDetailPane.locationLine("https://a.example.com/torbox=SECRET/manifest.json")
        XCTAssertEqual(keyed, "a.example.com/…/manifest.json (key hidden)")
        XCTAssertFalse(keyed.contains("SECRET"))
        XCTAssertEqual(AddonDetailPane.locationLine("https://a.example.com"), "a.example.com")
    }
}
