import XCTest
@testable import NuvioTV

final class EdgeClickModeTests: XCTestCase {
    private let five = [0.0, 90, 240, 390, 540].enumerated().map { TransportChapter(title: "C\($0.offset)", sec: $0.element) }

    private func click(_ mode: EdgeClickMode, _ dir: Int, _ base: Double, _ chapters: [TransportChapter]? = nil) -> EdgeClickAction {
        PlayerChapters.edgeClick(mode: mode, direction: dir, baseSec: base, chapters: chapters ?? five)
    }

    func testSkip10IgnoresChapters() {
        XCTAssertEqual(click(.skip10, 1, 100), .relative(10))
        XCTAssertEqual(click(.skip10, -1, 100), .relative(-10))
    }

    func testChapterRight() {
        XCTAssertEqual(click(.chapter, 1, 100), .absolute(240))
        XCTAssertEqual(click(.chapter, 1, 0), .absolute(90))
        XCTAssertEqual(click(.chapter, 1, 89.6), .absolute(240))   // 90 is within the 0.5 s guard
        XCTAssertEqual(click(.chapter, 1, 545), .relative(10))     // inside the last chapter
    }

    func testChapterLeft() {
        XCTAssertEqual(click(.chapter, -1, 100), .absolute(90))    // start of this chapter
        XCTAssertEqual(click(.chapter, -1, 92), .absolute(0))      // within 3 s of 90 → the one before
        XCTAssertEqual(click(.chapter, -1, 50), .absolute(0))
        XCTAssertEqual(click(.chapter, -1, 1), .absolute(0))       // nothing earlier → the start
        XCTAssertEqual(click(.chapter, -1, 300), .absolute(240))
    }

    func testTooFewChaptersSkips() {
        XCTAssertEqual(click(.chapter, 1, 100, [TransportChapter(title: "", sec: 0)]), .relative(10))
        XCTAssertEqual(click(.chapter, -1, 100, [TransportChapter(title: "", sec: 0)]), .relative(-10))
        XCTAssertEqual(click(.chapter, 1, 100, []), .relative(10))
        XCTAssertEqual(click(.chapter, -1, 100, []), .relative(-10))
    }

    func testSkipSecCarried() {
        XCTAssertEqual(PlayerChapters.edgeClick(mode: .skip10, direction: 1, baseSec: 0, chapters: five, skipSec: 30), .relative(30))
    }

    func testModeRawValues() {
        XCTAssertEqual(EdgeClickMode(rawValue: "skip10"), .skip10)
        XCTAssertEqual(EdgeClickMode(rawValue: "chapter"), .chapter)
        XCTAssertNil(EdgeClickMode(rawValue: "bogus"))
    }
}
