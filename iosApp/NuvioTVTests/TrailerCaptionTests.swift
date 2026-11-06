import XCTest
@testable import NuvioTV

/// Detail trailer cards: the second caption line drops a type that only repeats the title.
final class TrailerCaptionTests: XCTestCase {
    func testTypeAndYearWhenTheTitleDiffers() {
        XCTAssertEqual(TrailerCaption.metaLine(title: "Official Trailer", type: "Trailer", publishedAt: "2024-05-01"),
                       "Trailer \u{2022} 2024")
        XCTAssertEqual(TrailerCaption.metaLine(title: "Official Trailer", type: "Trailer", publishedAt: nil), "Trailer")
        XCTAssertEqual(TrailerCaption.metaLine(title: "Official Trailer", type: "Trailer", publishedAt: ""), "Trailer")
    }

    func testRepeatedTypeIsDroppedAndTheYearKept() {
        XCTAssertEqual(TrailerCaption.metaLine(title: "Trailer", type: "Trailer", publishedAt: "2019-01-01"), "2019")
        XCTAssertEqual(TrailerCaption.metaLine(title: "  trailer ", type: "Trailer", publishedAt: "2019"), "2019")
    }

    func testRepeatedTypeWithoutYearHidesTheLine() {
        XCTAssertNil(TrailerCaption.metaLine(title: "Trailer", type: "Trailer", publishedAt: nil))
        XCTAssertNil(TrailerCaption.metaLine(title: "TRAILER", type: " trailer ", publishedAt: "  "))
    }

    func testEmptyTypeNeverShowsABullet() {
        XCTAssertEqual(TrailerCaption.metaLine(title: "Teaser 2", type: "", publishedAt: "2020-02-02"), "2020")
        XCTAssertNil(TrailerCaption.metaLine(title: "Teaser 2", type: "", publishedAt: nil))
    }
}
