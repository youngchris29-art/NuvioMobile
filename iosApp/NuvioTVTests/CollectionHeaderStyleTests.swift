import XCTest
@testable import NuvioTV

/// GitHub #28: Settings › Home Screen › Collection Header (`CollectionHeaderStyle`), and the DEBUG
/// grid-geometry probe's row formatting (`FolderGridProbe`).
final class CollectionHeaderStyleTests: XCTestCase {

    func testKeyDefaultAndResolve() {
        XCTAssertEqual(CollectionHeaderStyle.defaultsKey, "collection_header_style")
        XCTAssertEqual(CollectionHeaderStyle.defaultValue, .standard)
        XCTAssertEqual(CollectionHeaderStyle.resolve(nil), .standard)
        XCTAssertEqual(CollectionHeaderStyle.resolve(""), .standard)
        XCTAssertEqual(CollectionHeaderStyle.resolve("bogus"), .standard)
        XCTAssertEqual(CollectionHeaderStyle.resolve(" Compact "), .compact)
        XCTAssertEqual(CollectionHeaderStyle.resolve("standard"), .standard)
        XCTAssertEqual(CollectionHeaderStyle.allCases, [.standard, .compact])
        XCTAssertEqual(CollectionHeaderStyle.standard.rawValue, "standard")
        XCTAssertEqual(CollectionHeaderStyle.compact.rawValue, "compact")
    }

    func testAnEmptyDefaultsSuiteReadsStandard() {
        let defaults = UserDefaults(suiteName: "CollectionHeaderStyleTests.\(UUID().uuidString)")!
        XCTAssertEqual(CollectionHeaderStyle.resolve(defaults.string(forKey: CollectionHeaderStyle.defaultsKey)), .standard)
        defaults.set("compact", forKey: CollectionHeaderStyle.defaultsKey)
        XCTAssertEqual(CollectionHeaderStyle.resolve(defaults.string(forKey: CollectionHeaderStyle.defaultsKey)), .compact)
    }

    func testProbeRowsGroupsNineFramesIntoThreeRows() {
        var frames: [Int: CGRect] = [:]
        for i in 0..<9 {
            let row = CGFloat(i / 3)
            frames[i] = CGRect(x: CGFloat(i % 3) * 260, y: 32 + row * 413.5, width: 220, height: 373.5)
        }
        XCTAssertEqual(FolderGridProbe.rows(frames), "32-405.5;445.5-819;859-1232.5")
        XCTAssertEqual(FolderGridProbe.columns(frames), 3)
    }

    func testProbeRowsRoundsToWholePointsAndIsEmptyForNoFrames() {
        XCTAssertEqual(FolderGridProbe.rows([0: CGRect(x: 0, y: 31.9, width: 10, height: 330.2)]), "32-362")
        XCTAssertEqual(FolderGridProbe.rows([:]), "")
        XCTAssertEqual(FolderGridProbe.columns([:]), 0)
    }
}
