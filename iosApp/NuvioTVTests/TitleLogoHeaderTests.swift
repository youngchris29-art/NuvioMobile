import XCTest
@testable import NuvioTV

/// Unit tests for `TitleLogoHeader.slotHeight(logoUrl:slotHeight:)`, the pure helper behind
/// `TitleLogoHeader`'s fixed-height slot decision (`DesignSystem/TitleLogoHeader.swift`). No view
/// host — this exercises a plain function over an optional URL string, mirroring `SagaCardTests`'
/// approach to `SagaCardArt`.
final class TitleLogoHeaderTests: XCTestCase {

    func testSlotHeightNilWhenNoLogoUrl() {
        XCTAssertNil(TitleLogoHeader.slotHeight(logoUrl: nil, slotHeight: 110))
    }

    func testSlotHeightReturnsGivenHeightWhenLogoUrlPresent() {
        XCTAssertEqual(
            TitleLogoHeader.slotHeight(logoUrl: "https://example.com/logo.png", slotHeight: 110),
            110
        )
    }
}
