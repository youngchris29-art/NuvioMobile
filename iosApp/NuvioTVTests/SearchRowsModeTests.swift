import XCTest
@testable import NuvioTV

/// Search & Discover batch (B6): the pure `search_rows_mode` resolution rules.
final class SearchRowsModeTests: XCTestCase {
    func testDefaultIsGrouped() {
        XCTAssertEqual(SearchRowsMode.defaultValue, .grouped)
        XCTAssertEqual(SearchRowsMode.resolve(nil), .grouped)
        XCTAssertEqual(SearchRowsMode.resolve(""), .grouped)
    }

    func testRawRoundTrip() {
        for mode in SearchRowsMode.allCases {
            XCTAssertEqual(SearchRowsMode.resolve(mode.rawValue), mode)
        }
        XCTAssertEqual(SearchRowsMode.perAddon.rawValue, "per_addon")
        XCTAssertEqual(SearchRowsMode.resolve(" PER_ADDON "), .perAddon)
    }

    func testGarbageResolvesToGrouped() {
        XCTAssertEqual(SearchRowsMode.resolve("garbage"), .grouped)
        XCTAssertEqual(SearchRowsMode.resolve("perAddon"), .grouped)
    }

    func testSetAndCurrentRoundTrip() {
        let saved = UserDefaults.standard.string(forKey: SearchRowsMode.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: SearchRowsMode.defaultsKey) }
        SearchRowsMode.set(.perAddon)
        XCTAssertEqual(SearchRowsMode.current(), .perAddon)
        SearchRowsMode.set(.grouped)
        XCTAssertEqual(SearchRowsMode.current(), .grouped)
    }
}
