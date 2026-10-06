import XCTest
import SharedCore
@testable import NuvioTV

/// Search & Discover batch (B7): the pure rules behind the MDBList "Library lists" page.
final class MdbListLibraryListsPolicyTests: XCTestCase {
    private func option(_ key: String, _ name: String, _ visible: Bool = true) -> MdbListLibraryListOption {
        MdbListLibraryListOption(key: key, name: name, visible: visible)
    }

    func testWatchlistIsExcluded() {
        let rows = MdbListLibraryListsPolicy.rows([
            option("mdblist:watchlist", "Watchlist"),
            option("mdblist:list:1", "Favourites"),
            option("mdblist:list:2", "Horror", false),
        ])
        XCTAssertEqual(rows.map(\.key), ["mdblist:list:1", "mdblist:list:2"])
    }

    func testEmptyWhenOnlyWatchlist() {
        XCTAssertTrue(MdbListLibraryListsPolicy.rows([option("mdblist:watchlist", "Watchlist")]).isEmpty)
        XCTAssertTrue(MdbListLibraryListsPolicy.rows([]).isEmpty)
    }

    func testSummaryCounts() {
        XCTAssertEqual(MdbListLibraryListsPolicy.summary(shown: 2, total: 5), "2 of 5 shown")
        XCTAssertEqual(MdbListLibraryListsPolicy.summary(shown: 0, total: 0), "0 of 0 shown")
    }
}
