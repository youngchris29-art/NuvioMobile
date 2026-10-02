import XCTest
@testable import NuvioTV

/// beta.18 verdict (BUG-112 residue): the gate order and decline reasons of `HomeUpIntoHeroGate`.
final class HomeUpIntoHeroGateTests: XCTestCase {
    private let window: TimeInterval = 0.8

    private func eval(now: TimeInterval = 100, up: TimeInterval = 99.9, released: TimeInterval? = nil,
                      key: String? = "row", past: Bool = true) -> HomeUpIntoHeroGate.Verdict {
        HomeUpIntoHeroGate.evaluate(now: now, lastUpInputAt: up, lastRowReleasedAt: released,
                                    focusedRowKey: key, rowsScrolledPastTop: past, window: window)
    }

    func testStampInsideWindowReveals() {
        XCTAssertEqual(eval(up: 99.5), .reveal)
    }

    func testStampOutsideWindowDeclinesStale() {
        XCTAssertEqual(eval(up: 98.0), .declined(reason: "staleInput sinceUp=2000"))
    }

    func testExactBoundaryIsStale() {
        // 100 - 99.2 is 0.7999… in binary; stamp at 0 and evaluate at exactly the window value so
        // `now - lastUpInputAt` is bit-identical to `window`.
        XCTAssertEqual(eval(now: 0.8, up: 0), .declined(reason: "staleInput sinceUp=800"))
    }

    func testReleaseInsideWindowWithoutFocusedRowKeyReveals() {
        XCTAssertEqual(eval(released: 99.8, key: nil), .reveal)
    }

    func testFocusedRowKeyWithoutReleaseStampReveals() {
        XCTAssertEqual(eval(released: nil, key: "genres"), .reveal)
    }

    func testNoRowOriginDeclinesWithNone() {
        XCTAssertEqual(eval(released: nil, key: nil), .declined(reason: "noRowOrigin sinceRelease=none"))
    }

    func testOldReleaseDeclinesWithMs() {
        XCTAssertEqual(eval(released: 98.0, key: nil), .declined(reason: "noRowOrigin sinceRelease=2000"))
    }

    func testNotPastTopDeclinesFirst() {
        XCTAssertEqual(eval(up: 50, released: nil, key: nil, past: false), .declined(reason: "notPastTop"))
    }
}
