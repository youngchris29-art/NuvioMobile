import XCTest
@testable import NuvioTV

/// Polish D2: a text chip with no parseable `tagColor` is the monochrome outline chip; a pack that
/// sets one keeps its colours. (The colour decisions are pinned in `StreamBadgeColorTests`, in this target.)
final class StreamBadgeTextChipStyleTests: XCTestCase {
    func testNoTagColorFallsBackToTheOutlineChip() {
        XCTAssertEqual(StreamBadgeChipView.textChipStyle(tagColorHex: ""), .outline)
        XCTAssertEqual(StreamBadgeChipView.textChipStyle(tagColorHex: "zzz"), .outline)
    }

    func testAParseableTagColorKeepsThePackColours() {
        XCTAssertEqual(StreamBadgeChipView.textChipStyle(tagColorHex: "#222222"), .packColors)
        XCTAssertEqual(StreamBadgeChipView.textChipStyle(tagColorHex: "FFFFFF"), .packColors)
        XCTAssertEqual(StreamBadgeChipView.textChipStyle(tagColorHex: "FF1A1A1A"), .packColors)
    }

    func testBadgeMetrics() {
        XCTAssertEqual(StreamBadgeMetrics.containerHeight, 34)
        XCTAssertEqual(StreamBadgeMetrics.imageHeight, 26)
        XCTAssertEqual(StreamBadgeMetrics.maxImageWidth, 150)
        XCTAssertEqual(StreamBadgeMetrics.outlineTracking, 0.4)
        XCTAssertEqual(StreamBadgeMetrics.outlineStrokeOpacity, 0.18)
    }
}
