import XCTest
@testable import NuvioTV

/// Home Stage & Strip (H5, W2-B; P2 spec §2.1, §4.2): which page a folder opens as, and the
/// device-local per-folder Grid choice (one `@AppStorage` string, Grid entries only, newest last,
/// capped at 200).
final class FolderLayoutStoreTests: XCTestCase {

    // MARK: - FolderPageLayout

    func testClassicIsAlwaysTheGrid() {
        XCTAssertEqual(FolderPageLayout.resolve(homeLayout: .classic, gridOverride: false), .grid)
        XCTAssertEqual(FolderPageLayout.resolve(homeLayout: .classic, gridOverride: true), .grid)
    }

    func testStageOpensRowsUnlessTheFolderChoseGrid() {
        XCTAssertEqual(FolderPageLayout.resolve(homeLayout: .stage, gridOverride: false), .rows)
        XCTAssertEqual(FolderPageLayout.resolve(homeLayout: .stage, gridOverride: true), .grid)
    }

    // MARK: - Keys

    func testKeyAndFormat() {
        XCTAssertEqual(FolderLayoutStore.defaultsKey, "folder_layout_grid")
        XCTAssertEqual(FolderLayoutStore.maxEntries, 200)
        XCTAssertEqual(FolderLayoutStore.entryKey(collectionId: "c", folderId: "f"), "c\u{1F}f")
        XCTAssertEqual(FolderLayoutStore.setting("", grid: true, collectionId: "c", folderId: "f"), "c\u{1F}f")
    }

    // MARK: - Round trip

    func testGridRoundTrip() {
        var raw = ""
        XCTAssertFalse(FolderLayoutStore.isGrid(raw, collectionId: "c1", folderId: "f1"))

        raw = FolderLayoutStore.setting(raw, grid: true, collectionId: "c1", folderId: "f1")
        XCTAssertTrue(FolderLayoutStore.isGrid(raw, collectionId: "c1", folderId: "f1"))

        // Setting Grid again does not duplicate the entry.
        raw = FolderLayoutStore.setting(raw, grid: true, collectionId: "c1", folderId: "f1")
        XCTAssertEqual(FolderLayoutStore.entries(raw).count, 1)

        // Rows removes the entry: the folder follows the Home layout again.
        raw = FolderLayoutStore.setting(raw, grid: false, collectionId: "c1", folderId: "f1")
        XCTAssertFalse(FolderLayoutStore.isGrid(raw, collectionId: "c1", folderId: "f1"))
        XCTAssertEqual(raw, "")
    }

    func testRowsForAFolderWithNoEntryChangesNothing() {
        let raw = FolderLayoutStore.setting("", grid: true, collectionId: "c1", folderId: "f1")
        XCTAssertEqual(FolderLayoutStore.setting(raw, grid: false, collectionId: "c1", folderId: "f2"), raw)
        XCTAssertEqual(FolderLayoutStore.setting("", grid: false, collectionId: "c1", folderId: "f1"), "")
    }

    /// Folder ids are unique per collection only.
    func testSameFolderIdInAnotherCollectionIsSeparate() {
        let raw = FolderLayoutStore.setting("", grid: true, collectionId: "c1", folderId: "shared")
        XCTAssertTrue(FolderLayoutStore.isGrid(raw, collectionId: "c1", folderId: "shared"))
        XCTAssertFalse(FolderLayoutStore.isGrid(raw, collectionId: "c2", folderId: "shared"))

        let both = FolderLayoutStore.setting(raw, grid: true, collectionId: "c2", folderId: "shared")
        let cleared = FolderLayoutStore.setting(both, grid: false, collectionId: "c1", folderId: "shared")
        XCTAssertFalse(FolderLayoutStore.isGrid(cleared, collectionId: "c1", folderId: "shared"))
        XCTAssertTrue(FolderLayoutStore.isGrid(cleared, collectionId: "c2", folderId: "shared"))
    }

    // MARK: - Cap

    func testTwoHundredAndOneEntriesKeepTheNewestTwoHundred() {
        var raw = ""
        for index in 0...200 {
            raw = FolderLayoutStore.setting(raw, grid: true, collectionId: "c", folderId: "f\(index)")
        }
        let entries = FolderLayoutStore.entries(raw)
        XCTAssertEqual(entries.count, 200)
        XCTAssertFalse(FolderLayoutStore.isGrid(raw, collectionId: "c", folderId: "f0"), "the oldest is dropped")
        XCTAssertTrue(FolderLayoutStore.isGrid(raw, collectionId: "c", folderId: "f1"))
        XCTAssertTrue(FolderLayoutStore.isGrid(raw, collectionId: "c", folderId: "f200"))
        XCTAssertEqual(entries.last, FolderLayoutStore.entryKey(collectionId: "c", folderId: "f200"), "newest last")
    }

    func testResettingMovesAnEntryToNewest() {
        var raw = ""
        for folder in ["a", "b", "c"] {
            raw = FolderLayoutStore.setting(raw, grid: true, collectionId: "c", folderId: folder)
        }
        raw = FolderLayoutStore.setting(raw, grid: true, collectionId: "c", folderId: "a")
        XCTAssertEqual(FolderLayoutStore.entries(raw), ["b", "c", "a"].map {
            FolderLayoutStore.entryKey(collectionId: "c", folderId: $0)
        })

        // Filling past the cap now drops "b" first; "a", re-set last, survives.
        for index in 0..<198 {
            raw = FolderLayoutStore.setting(raw, grid: true, collectionId: "c", folderId: "x\(index)")
        }
        XCTAssertEqual(FolderLayoutStore.entries(raw).count, 200)
        XCTAssertFalse(FolderLayoutStore.isGrid(raw, collectionId: "c", folderId: "b"))
        XCTAssertTrue(FolderLayoutStore.isGrid(raw, collectionId: "c", folderId: "c"))
        XCTAssertTrue(FolderLayoutStore.isGrid(raw, collectionId: "c", folderId: "a"))
    }

    // MARK: - Hygiene

    func testBlankLinesAreIgnored() {
        let entry = FolderLayoutStore.entryKey(collectionId: "c", folderId: "f")
        let raw = "\n\n\(entry)\n   \n"
        XCTAssertTrue(FolderLayoutStore.isGrid(raw, collectionId: "c", folderId: "f"))
        XCTAssertEqual(FolderLayoutStore.entries(raw), [entry])

        let added = FolderLayoutStore.setting(raw, grid: true, collectionId: "c2", folderId: "f2")
        XCTAssertEqual(added, "\(entry)\n" + FolderLayoutStore.entryKey(collectionId: "c2", folderId: "f2"),
                       "a write drops the blank lines")
        XCTAssertFalse(FolderLayoutStore.isGrid("\n \n", collectionId: "c", folderId: "f"))
    }
}
