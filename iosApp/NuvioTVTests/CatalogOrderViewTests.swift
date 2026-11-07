import XCTest
import SharedCore
@testable import NuvioTV

/// A6: the catalogs page's pure rules (filtering, menu and VoiceOver actions, captions).
final class CatalogOrderViewTests: XCTestCase {
    private func catalog(
        _ key: String, enabled: Bool = true, collection: Bool = false, pinned: Bool = false, addonName: String = "Mine"
    ) -> HomeCatalogSettingsItem {
        HomeCatalogSettingsItem(
            key: key, defaultTitle: "t", addonName: addonName, customTitle: "", enabled: enabled,
            heroSourceEnabled: true, order: 0, isCollection: collection, collectionId: nil, isPinnedToTop: pinned
        )
    }

    private let none = Set<String>()
    private let keys = ["a", "b", "c"]

    // MARK: visibleRows

    func testVisibleRowsWithoutFilterReturnsEverythingInOrder() {
        let items = [catalog("a"), catalog("col", collection: true), catalog("b")]
        XCTAssertEqual(CatalogOrderView.visibleRows(items, filter: nil).map(\.key), ["a", "col", "b"])
    }

    func testVisibleRowsWithFilterKeepsOrderAndDropsCollectionsAndOtherKeys() {
        let items = [catalog("c"), catalog("col", collection: true), catalog("x"), catalog("a")]
        let filter = CatalogFilter(keys: ["a", "c", "col"], addonTitle: "Mine")
        XCTAssertEqual(CatalogOrderView.visibleRows(items, filter: filter).map(\.key), ["c", "a"])
    }

    // MARK: menuActions

    func testMenuActionsToggleIsFirstAndFlipsTheState() {
        let on = CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 1, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: true, filtered: false)
        XCTAssertEqual(on.first, .toggle(turnOn: false))
        let off = CatalogOrderView.menuActions(
            item: false, isPinned: false, index: 1, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: true, filtered: false)
        XCTAssertEqual(off.first, .toggle(turnOn: true))
    }

    func testMenuActionsOffersMoveOnlyWhenTheRowCanMove() {
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 1, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: true, filtered: false), [.toggle(turnOn: false), .move])
        // A lone row cannot move either way.
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 0, orderedKeys: ["a"], pinnedKeys: none,
            allowsMoveMode: true, filtered: false), [.toggle(turnOn: false)])
        // First row can still move down.
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 0, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: true, filtered: false), [.toggle(turnOn: false), .move])
    }

    func testPinnedAndFilteredRowsGetOnlyToggle() {
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: true, index: 0, orderedKeys: keys, pinnedKeys: ["a"],
            allowsMoveMode: true, filtered: false), [.toggle(turnOn: false)])
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 1, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: true, filtered: true), [.toggle(turnOn: false)])
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 1, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: false, filtered: true), [.toggle(turnOn: false)])
    }

    func testSettingsHostGetsDirectMovesPerCanMove() {
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 1, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: false, filtered: false), [.toggle(turnOn: false), .moveUp, .moveDown])
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 0, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: false, filtered: false), [.toggle(turnOn: false), .moveDown])
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 2, orderedKeys: keys, pinnedKeys: none,
            allowsMoveMode: false, filtered: false), [.toggle(turnOn: false), .moveUp])
        // The neighbour above is pinned: no Move up.
        XCTAssertEqual(CatalogOrderView.menuActions(
            item: true, isPinned: false, index: 1, orderedKeys: keys, pinnedKeys: ["a"],
            allowsMoveMode: false, filtered: false), [.toggle(turnOn: false), .moveDown])
    }

    // MARK: voiceOverMoves

    func testVoiceOverMovesFollowCanMoveAndNothingWhenFiltered() {
        XCTAssertEqual(CatalogOrderView.voiceOverMoves(index: 1, orderedKeys: keys, pinnedKeys: none, filtered: false),
                       [.moveUp, .moveDown])
        XCTAssertEqual(CatalogOrderView.voiceOverMoves(index: 0, orderedKeys: keys, pinnedKeys: none, filtered: false),
                       [.moveDown])
        XCTAssertEqual(CatalogOrderView.voiceOverMoves(index: 2, orderedKeys: keys, pinnedKeys: none, filtered: false),
                       [.moveUp])
        XCTAssertEqual(CatalogOrderView.voiceOverMoves(index: 1, orderedKeys: keys, pinnedKeys: ["b"], filtered: false), [])
        XCTAssertEqual(CatalogOrderView.voiceOverMoves(index: 1, orderedKeys: keys, pinnedKeys: none, filtered: true), [])
    }

    // MARK: subtitle and filterLine

    func testSubtitleNamesTheAddonOrTheCollectionKind() {
        XCTAssertEqual(CatalogOrderView.subtitle(of: catalog("a", addonName: "Cinemeta")), "Cinemeta")
        XCTAssertEqual(CatalogOrderView.subtitle(of: catalog("c", collection: true)), "Collection")
        XCTAssertEqual(CatalogOrderView.subtitle(of: catalog("c", collection: true, pinned: true)), "Pinned collection")
    }

    func testFilterLineCountsAndNamesTheAddon() {
        let filter = CatalogFilter(keys: ["a"], addonTitle: "Cinemeta")
        XCTAssertEqual(CatalogOrderView.filterLine(filter, count: 3), "3 catalogs from Cinemeta")
    }

    /// Review A6-r1: a pin arriving during a move keeps the cancel below the pinned rows.
    func testCancelDestinationStaysBelowPinnedCollections() {
        XCTAssertEqual(CatalogOrderView.cancelDestination(origin: 0, pinnedKeys: ["x"]), 1)
        XCTAssertEqual(CatalogOrderView.cancelDestination(origin: 3, pinnedKeys: ["x"]), 3)
        XCTAssertEqual(CatalogOrderView.cancelDestination(origin: 0, pinnedKeys: []), 0)
    }
}
