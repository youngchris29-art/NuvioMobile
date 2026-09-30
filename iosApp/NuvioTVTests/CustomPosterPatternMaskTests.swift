import XCTest
@testable import NuvioTV

/// `CustomPosterPatternMask` hides likely API keys in the Custom Posters value row.
final class CustomPosterPatternMaskTests: XCTestCase {

    func testRpdbKeySegmentIsMaskedAndHostAndPlaceholdersStay() {
        let input = "https://api.ratingposterdb.com/t1-abcdefghijklmnopqrst/imdb/poster-default/{id}.jpg"
        XCTAssertEqual(
            CustomPosterPatternMask.masked(input),
            "https://api.ratingposterdb.com/\u{2022}\u{2022}\u{2022}\u{2022}/imdb/poster-default/{id}.jpg"
        )
    }

    func testPatternWithoutKeyLikeSegmentIsUnchanged() {
        let input = "https://example.com/posters/{type}/{shape}/{id}.jpg"
        XCTAssertEqual(CustomPosterPatternMask.masked(input), input)
    }

    func testPlaceholdersAreNeverMaskedButQueryKeyIs() {
        let input = "https://svc.example.com/{imdb_id|kitsu_id_long_placeholder}/poster?apikey=secretvalue&size={shape}"
        XCTAssertEqual(
            CustomPosterPatternMask.masked(input),
            "https://svc.example.com/{imdb_id|kitsu_id_long_placeholder}/poster?apikey=\u{2022}\u{2022}\u{2022}\u{2022}&size={shape}"
        )
    }
}
