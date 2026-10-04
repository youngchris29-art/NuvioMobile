import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (C, BUG-135): the folder page header's rise. `s` is how far the grid has
/// scrolled; the header goes compact over the first `riseDistance` (106) points, then the chips
/// and band pin. See `FolderHeaderGeometry` (CollectionsUI.swift).
final class FolderHeaderGeometryTests: XCTestCase {
    private typealias G = FolderHeaderGeometry

    func testRIs106() {
        XCTAssertEqual(G.restTop, 32)
        XCTAssertEqual(G.logoSlot, 150)
        XCTAssertEqual(G.compactTop, 12)
        XCTAssertEqual(G.compactLogoSlot, 64)
        XCTAssertEqual(G.riseDistance, 106)
    }

    func testRestIsIdentity() {
        XCTAssertEqual(G.progress(scrolled: 0), 0)
        XCTAssertEqual(G.logoScale(scrolled: 0), 1)
        XCTAssertEqual(G.logoOffsetY(scrolled: 0), 0)
        XCTAssertEqual(G.pinnedOffsetY(scrolled: 0), 0)
        XCTAssertEqual(G.phase(scrolled: 0), 0)
    }

    func testRiseMidway() {
        XCTAssertEqual(G.logoScale(scrolled: 53), 0.7133, accuracy: 0.001)
        XCTAssertEqual(G.logoOffsetY(scrolled: 53), 43, accuracy: 0.001)
        XCTAssertEqual(G.pinnedOffsetY(scrolled: 53), 0)
        XCTAssertEqual(G.phase(scrolled: 53), 2)
    }

    func testCompactAtR() {
        XCTAssertEqual(G.logoScale(scrolled: 106), 64.0 / 150.0, accuracy: 1e-9)
        XCTAssertEqual(G.logoOffsetY(scrolled: 106), 86, accuracy: 1e-9)
        XCTAssertEqual(G.pinnedOffsetY(scrolled: 106), 0)
        XCTAssertEqual(G.phase(scrolled: 106), 4)
        XCTAssertEqual(G.phase(scrolled: 105), 3)
    }

    func testPinnedPastR() {
        XCTAssertEqual(G.pinnedOffsetY(scrolled: 306), 200)
        XCTAssertEqual(G.logoScale(scrolled: 306), 64.0 / 150.0, accuracy: 1e-9)
        // The logo cancels the scroll and sits at the compact top: layout top (32 − 306) + offset.
        XCTAssertEqual(G.restTop - 306 + G.logoOffsetY(scrolled: 306), G.compactTop, accuracy: 1e-9)
        XCTAssertEqual(G.phase(scrolled: 306), 4)
    }

    func testOverscrollMovesWithContent() {
        XCTAssertEqual(G.logoOffsetY(scrolled: -40), 0)
        XCTAssertEqual(G.logoScale(scrolled: -40), 1)
        XCTAssertEqual(G.pinnedOffsetY(scrolled: -40), 0)
        XCTAssertEqual(G.phase(scrolled: -40), 0)
    }

    /// While the header rises, the logo's bottom and the chips' top close in at the same rate, so
    /// the gap between them never changes (no overlap at any scroll amount).
    func testLogoToChipsGapIsConstant() {
        for step in 0...40 {
            let s = CGFloat(step) * 5 - 20   // −20 … 180
            let logoTop = G.restTop - s + G.logoOffsetY(scrolled: s)
            let logoBottom = logoTop + G.logoSlot * G.logoScale(scrolled: s)
            let chipsTop = G.restTop + G.logoSlot + G.gap - s + G.pinnedOffsetY(scrolled: s)
            XCTAssertEqual(chipsTop - logoBottom, G.gap, accuracy: 1e-9, "s=\(s)")
        }
    }

    func testNonFiniteScrollIsSafe() {
        XCTAssertEqual(G.progress(scrolled: .nan), 0)
        XCTAssertEqual(G.progress(scrolled: .infinity), 1)
    }
}
