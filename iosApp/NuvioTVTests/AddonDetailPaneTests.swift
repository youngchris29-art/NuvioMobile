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

    private func catalog(_ name: String?, enabled: Bool, collection: Bool = false) -> HomeCatalogSettingsItem {
        HomeCatalogSettingsItem(
            key: UUID().uuidString, defaultTitle: "t", addonName: name ?? "", customTitle: "", enabled: enabled,
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

    func testCatalogCountsMatchByNameAndSkipCollections() {
        let items = [
            catalog("Mine", enabled: true),
            catalog("Mine", enabled: false),
            catalog("Mine", enabled: true),
            catalog("Mine", enabled: true, collection: true),
            catalog("Other", enabled: true),
        ]
        let counts = AddonDetailPane.catalogCounts(addonName: "Mine", catalogs: items)
        XCTAssertEqual(counts.on, 2)
        XCTAssertEqual(counts.total, 3)
        let none = AddonDetailPane.catalogCounts(addonName: nil, catalogs: items)
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

    func testReadOnlyOffersRefreshAndCatalogsOnly() {
        XCTAssertEqual(rows(isReadOnly: true), [.refresh, .catalogs])
        XCTAssertEqual(rows(isReadOnly: true, catalogTotal: 0), [.refresh])
        XCTAssertEqual(rows(isReadOnly: true, status: .stalled, configureFirst: true), [.retry, .catalogs])
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
