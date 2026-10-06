import XCTest
@testable import NuvioTV

/// Search & Discover batch (A5): the pure `discover_placement` resolution rules.
final class DiscoverPlacementTests: XCTestCase {
    func testResolveDefaultsToOwnTab() {
        XCTAssertEqual(DiscoverPlacement.resolve(nil), .ownTab)
        XCTAssertEqual(DiscoverPlacement.resolve(""), .ownTab)
        XCTAssertEqual(DiscoverPlacement.resolve("   "), .ownTab)
        XCTAssertEqual(DiscoverPlacement.resolve("garbage"), .ownTab)
        XCTAssertEqual(DiscoverPlacement.resolve(" TAB "), .ownTab)
    }

    func testResolveKnownValues() {
        XCTAssertEqual(DiscoverPlacement.resolve("search"), .underSearch)
        XCTAssertEqual(DiscoverPlacement.resolve("off"), .off)
        XCTAssertEqual(DiscoverPlacement.resolve(" Search "), .underSearch)
    }

    func testEffective() {
        XCTAssertEqual(DiscoverPlacement.effective(stored: "tab", hideDiscover: true), .off)
        XCTAssertEqual(DiscoverPlacement.effective(stored: "search", hideDiscover: false), .underSearch)
        XCTAssertEqual(DiscoverPlacement.effective(stored: nil, hideDiscover: false), .ownTab)
        XCTAssertEqual(DiscoverPlacement.effective(stored: "off", hideDiscover: true, argumentOverride: "tab"), .ownTab)
        XCTAssertEqual(DiscoverPlacement.effective(stored: "tab", hideDiscover: false, argumentOverride: "search"), .underSearch)
    }

    func testWrites() {
        XCTAssertEqual(DiscoverPlacement.writes(for: .off).placementRaw, "off")
        XCTAssertTrue(DiscoverPlacement.writes(for: .off).hideDiscover)
        XCTAssertEqual(DiscoverPlacement.writes(for: .underSearch).placementRaw, "search")
        XCTAssertFalse(DiscoverPlacement.writes(for: .underSearch).hideDiscover)
        XCTAssertEqual(DiscoverPlacement.writes(for: .ownTab).placementRaw, "tab")
        XCTAssertFalse(DiscoverPlacement.writes(for: .ownTab).hideDiscover)
    }

    func testAllCasesOrder() {
        XCTAssertEqual(DiscoverPlacement.allCases, [.off, .underSearch, .ownTab])
    }
}
