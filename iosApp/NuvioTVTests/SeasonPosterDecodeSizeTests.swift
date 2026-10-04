import CoreGraphics
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (review r1, I1): the season poster selector card decodes at its drawn size,
/// not the unsized 1920 px legacy cap. The Kotlin season poster is now TMDB w780 (780x1170), so an
/// unsized decode would hold a ~3.6 MB bitmap per 180x270 pt card.
@MainActor
final class SeasonPosterDecodeSizeTests: XCTestCase {

    func testSeasonPosterCardDecodesAtItsDrawnSize() {
        XCTAssertEqual(
            SeasonPosterCard.decodeSize,
            .points(width: Theme.Size.miniPosterWidth, height: Theme.Size.miniPosterHeight)
        )
        XCTAssertNotEqual(SeasonPosterCard.decodeSize, .legacy)
    }

    func testSeasonPosterDecodeIsTheSameRequestAPosterOfThatSizeBuilds() {
        let request = ArtworkDecodeRequest(size: SeasonPosterCard.decodeSize, fill: true, scale: 2).normalized
        XCTAssertEqual(
            request,
            PosterCard.decodeRequest(width: Theme.Size.miniPosterWidth, height: Theme.Size.miniPosterHeight, scale: 2)
        )
        // 180x270 pt at scale 2 = 540 px on the long side: bucket 640, against a 1170 px source.
        let needed = ArtworkDecodeMath.neededLongSide(request, source: CGSize(width: 780, height: 1170))
        XCTAssertEqual(needed, 540, accuracy: 0.5)
        XCTAssertEqual(ArtworkDecodeMath.storeBucket(needed: needed, sourceLongSide: 1170), 640)
    }
}
