import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (R2 + I1, critique #3): the tile-art loader's pure planning — which candidate
/// is a banner and which a poster, and the decode request each one needs to cover the tile. The
/// loader itself (cache lookups, fetches) is exercised by the trailer UI legs.
final class InlineTileArtLoaderPlanTests: XCTestCase {

    private typealias Step = InlineTileArtLoader.Step
    private let tile = CGSize(width: 586.67, height: 330)

    func testBannerThenPosterRoles() {
        let steps = InlineTileArtLoader.steps(primary: "https://a/banner.jpg", fallback: "https://a/poster.jpg")
        XCTAssertEqual(steps, [Step(url: "https://a/banner.jpg", role: .banner),
                               Step(url: "https://a/poster.jpg", role: .poster)])
    }

    func testPosterAsPrimaryStaysAPoster() {
        // `landscapeArtworkURL` returns the poster when an item has no banner, and `candidates`
        // de-duplicates the pair: the one remaining entry must still be loaded as a poster.
        let steps = InlineTileArtLoader.steps(primary: "https://a/poster.jpg", fallback: "https://a/poster.jpg")
        XCTAssertEqual(steps, [Step(url: "https://a/poster.jpg", role: .poster)])
    }

    func testBlankEntriesAreDropped() {
        XCTAssertEqual(InlineTileArtLoader.steps(primary: nil, fallback: "https://a/poster.jpg"),
                       [Step(url: "https://a/poster.jpg", role: .poster)])
        XCTAssertEqual(InlineTileArtLoader.steps(primary: "https://a/banner.jpg", fallback: nil),
                       [Step(url: "https://a/banner.jpg", role: .banner)])
        XCTAssertEqual(InlineTileArtLoader.steps(primary: "  ", fallback: ""), [])
    }

    func testStepsKeepTheCandidateOrder() {
        // The pre-I1 contract `InlineTrailerMorphPlanTests.testArtCandidatesOrder` pins.
        let steps = InlineTileArtLoader.steps(primary: "https://a/banner.jpg", fallback: "https://a/poster.jpg")
        XCTAssertEqual(steps.map(\.url),
                       InlineTileArtLoader.candidates(primary: "https://a/banner.jpg", fallback: "https://a/poster.jpg"))
    }

    func testBannerRequestIsTheTileSize() {
        let request = InlineTileArtLoader.request(for: .banner, tile: tile, scale: 2)
        XCTAssertEqual(request, ArtworkDecodeRequest(size: .points(width: 586.67, height: 330), fill: true, scale: 2).normalized)
        // 586.67 pt × 2 = 1173 px on the long side → the 1280 bucket.
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: ArtworkDecodeMath.neededLongSide(request, source: nil)), 1280)
    }

    func testPosterRequestCoversTheTileByItsLongSide() {
        // A 2:3 poster filling a 16:9 tile is drawn tile.width wide and 1.5 × that tall.
        let request = InlineTileArtLoader.request(for: .poster, tile: tile, scale: 2)
        XCTAssertEqual(request, ArtworkDecodeRequest(size: .points(width: 586.67, height: 586.67 * 1.5), fill: true, scale: 2).normalized)
        // 586.67 × 1.5 × 2 = 1760 px → the 1920 bucket (against the banner's 1280).
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: ArtworkDecodeMath.neededLongSide(request, source: nil)), 1920)
        // With the source size known, the math agrees: a 780×1170 poster needs 1760 px of its long side.
        let needed = ArtworkDecodeMath.neededLongSide(request, source: CGSize(width: 780, height: 1170))
        XCTAssertEqual(needed, 1760, accuracy: 1)
    }

    func testRequestsAreFillAndNormalised() {
        for role in [InlineTileArtLoader.Role.banner, .poster] {
            XCTAssertTrue(InlineTileArtLoader.request(for: role, tile: tile, scale: 2).fill)
        }
        // A zero-size tile (a card that has not been measured) degrades to today's legacy decode
        // instead of asking for a 128 px bucket.
        XCTAssertEqual(InlineTileArtLoader.request(for: .banner, tile: .zero, scale: 2), .legacy)
        XCTAssertEqual(InlineTileArtLoader.request(for: .poster, tile: .zero, scale: 2), .legacy)
    }
}
