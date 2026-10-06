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

    /// Review r2 P3-3: an in-flight toggle's value beats a stale emission.
    func testPendingOverrideWinsOverEmission() {
        let emitted = [option("mdblist:list:1", "Favourites", true), option("mdblist:list:2", "Horror", false)]
        let applied = MdbListLibraryListsPolicy.applying(pending: ["mdblist:list:1": false], to: emitted)
        XCTAssertEqual(applied.map(\.visible), [false, false])
        XCTAssertEqual(applied.map(\.name), ["Favourites", "Horror"])
        XCTAssertEqual(MdbListLibraryListsPolicy.applying(pending: [:], to: emitted).map(\.visible), [true, false])
        // A pending key no longer in the emission is ignored.
        XCTAssertEqual(MdbListLibraryListsPolicy.applying(pending: ["gone": true], to: emitted).map(\.visible), [true, false])
    }

    /// Review r2 P3-2: the service's English `require` text is localized; anything else passes.
    func testFailureCopy() {
        XCTAssertEqual(MdbListLibraryListsPolicy.failureCopy("This list is no longer available"),
                       String(localized: "This list is no longer available"))
        XCTAssertEqual(MdbListLibraryListsPolicy.failureCopy(""), String(localized: "Couldn't update this list. Try again."))
        XCTAssertEqual(MdbListLibraryListsPolicy.failureCopy("HTTP 500"), "HTTP 500")
    }
}
