import CoreGraphics
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (I1, BUG-134): the pure math behind the artwork decode size. The cap ImageIO
/// gets is the drawn size in pixels, aspect-aware, rounded UP to a shared bucket and never above the
/// source. No image, no cache, no view host.
@MainActor
final class ArtworkDecodeMathTests: XCTestCase {

    func testBucketRoundsUpAndClamps() {
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: 0), 128)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: 128), 128)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: 129), 256)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: 806), 896)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: 2915), 3072)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: 3840), 3840)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: 5000), 3840)
        // Non-finite and negative values never trap.
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: -10), 128)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: .nan), 128)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: .infinity), 128)
    }

    func testFullBleedIsScreenPixels() {
        let atScale2 = ArtworkDecodeRequest(size: .fullBleed, fill: true, scale: 2)
        let atScale1 = ArtworkDecodeRequest(size: .fullBleed, fill: true, scale: 1)
        XCTAssertEqual(ArtworkDecodeMath.neededLongSide(atScale2, source: nil), 3840)
        XCTAssertEqual(ArtworkDecodeMath.neededLongSide(atScale1, source: nil), 1920)
        // The source size does not change a full-bleed need.
        XCTAssertEqual(ArtworkDecodeMath.neededLongSide(atScale2, source: CGSize(width: 1280, height: 720)), 3840)
    }

    func testLegacyIs1920() {
        XCTAssertEqual(ArtworkDecodeMath.neededLongSide(.legacy, source: nil), 1920)
        XCTAssertEqual(ArtworkDecodeMath.neededLongSide(.legacy, source: CGSize(width: 500, height: 750)), 1920)
        // A legacy decode of a source smaller than 1920 is stored at the source's bucket.
        XCTAssertEqual(ArtworkDecodeMath.storeBucket(needed: 1920, sourceLongSide: 1170), 1280)
    }

    /// beta.19-rc1 verdict (review r1, B P2-1): the floor a cache lookup applies. For `.legacy` it is
    /// the bucket a legacy decode of the URL is stored under, `bucket(min(1920, source))`, so a card's
    /// smaller decode of the same URL is never a legacy hit.
    func testLookupBucketForLegacyIsTheLegacyDecodesOwnBucket() {
        XCTAssertEqual(ArtworkDecodeMath.lookupBucket(.legacy, source: nil), 1920)
        XCTAssertEqual(ArtworkDecodeMath.lookupBucket(.legacy, source: CGSize(width: 3840, height: 2160)), 1920)
        XCTAssertEqual(ArtworkDecodeMath.lookupBucket(.legacy, source: CGSize(width: 1280, height: 720)), 1280)
        XCTAssertEqual(ArtworkDecodeMath.lookupBucket(.legacy, source: CGSize(width: 500, height: 750)), 768)
        // A Continue Watching card's request for the same 1280 px backdrop lands in the 768 bucket,
        // under the legacy floor.
        let card = ArtworkDecodeRequest(size: .points(width: 360, height: 203), fill: true, scale: 2).normalized
        XCTAssertEqual(ArtworkDecodeMath.lookupBucket(card, source: CGSize(width: 1280, height: 720)), 768)
        // Every other request kind is unchanged: the bucket its decode is stored under.
        let fullBleed = ArtworkDecodeRequest(size: .fullBleed, fill: true, scale: 2).normalized
        XCTAssertEqual(ArtworkDecodeMath.lookupBucket(fullBleed, source: CGSize(width: 3840, height: 2160)), 3840)
        XCTAssertEqual(ArtworkDecodeMath.lookupBucket(fullBleed, source: CGSize(width: 1280, height: 720)), 1280)
    }

    func testPixelsPassThrough() {
        let request = ArtworkDecodeRequest(size: .pixels(256), fill: true, scale: 2)
        XCTAssertEqual(ArtworkDecodeMath.neededLongSide(request, source: nil), 256)
        XCTAssertEqual(ArtworkDecodeMath.neededLongSide(request, source: CGSize(width: 4000, height: 2250)), 256)
        // The normalized form ignores the scale, so a 1080p and a 4K caller share one decode.
        let other = ArtworkDecodeRequest(size: .pixels(256), fill: false, scale: 1)
        XCTAssertEqual(request.normalized, other.normalized)
    }

    func testPointsFillUsesSourceAspect() {
        // A 2:3 poster in a 360×203 pt tile at scale 2: the tile is 720×406 px, fill scales the
        // poster to cover it (k = 1.44), so its long side must be 750 × 1.44 = 1080 px.
        let request = ArtworkDecodeRequest(size: .points(width: 360, height: 203), fill: true, scale: 2)
        let needed = ArtworkDecodeMath.neededLongSide(request, source: CGSize(width: 500, height: 750))
        XCTAssertEqual(needed, 1080, accuracy: 0.001)
        // Without a source the answer is the long side of the view in pixels.
        XCTAssertEqual(ArtworkDecodeMath.neededLongSide(request, source: nil), 720, accuracy: 0.001)
    }

    func testPointsFitUsesSourceAspect() {
        // A 3:1 logo in a 600×180 pt slot at scale 2: the slot is 1200×360 px, fit scales the logo to
        // sit inside it (k = 1.2), so its long side must be 900 × 1.2 = 1080 px.
        let request = ArtworkDecodeRequest(size: .points(width: 600, height: 180), fill: false, scale: 2)
        let needed = ArtworkDecodeMath.neededLongSide(request, source: CGSize(width: 900, height: 300))
        XCTAssertEqual(needed, 1080, accuracy: 0.001)
    }

    func testZeroPointsNormalizeToLegacy() {
        XCTAssertEqual(ArtworkDecodeRequest(size: .points(width: 0, height: 540), fill: true, scale: 2).normalized, .legacy)
        XCTAssertEqual(ArtworkDecodeRequest(size: .points(width: 360, height: 0), fill: true, scale: 2).normalized, .legacy)
        XCTAssertEqual(ArtworkDecodeRequest(size: .points(width: -1, height: 100), fill: true, scale: 2).normalized, .legacy)
        XCTAssertEqual(ArtworkDecodeRequest(size: .points(width: .nan, height: 100), fill: true, scale: 2).normalized, .legacy)
        XCTAssertEqual(ArtworkDecodeRequest(size: .pixels(0), fill: true, scale: 2).normalized, .legacy)
        // A sane request keeps its size and a non-positive scale falls back to 1.
        let ok = ArtworkDecodeRequest(size: .points(width: 360, height: 540), fill: true, scale: 0).normalized
        XCTAssertEqual(ok.size, .points(width: 360, height: 540))
        XCTAssertEqual(ok.scale, 1)
    }

    func testStoreBucketNeverAboveSource() {
        // A 3840 px need against a 1170 px source is stored as 1280, not 3840.
        XCTAssertEqual(ArtworkDecodeMath.storeBucket(needed: 3840, sourceLongSide: 1170), 1280)
        XCTAssertEqual(ArtworkDecodeMath.storeBucket(needed: 3840, sourceLongSide: 5000), 3840)
        XCTAssertEqual(ArtworkDecodeMath.storeBucket(needed: 700, sourceLongSide: 5000), 768)
        // Unknown source: the request's own bucket.
        XCTAssertEqual(ArtworkDecodeMath.storeBucket(needed: 700, sourceLongSide: nil), 768)
    }

    func testServingOrderAscends() {
        XCTAssertEqual(ArtworkDecodeMath.servingOrder(from: 2560), [2560, 3072, 3840])
        XCTAssertEqual(ArtworkDecodeMath.servingOrder(from: 3840), [3840])
        XCTAssertEqual(ArtworkDecodeMath.servingOrder(from: 128).count, ArtworkDecodeMath.buckets.count)
    }

    func testPlaceholderOrderDescends() {
        XCTAssertEqual(ArtworkDecodeMath.placeholderOrder(below: 512), [384, 256, 128])
        XCTAssertEqual(ArtworkDecodeMath.placeholderOrder(below: 128), [])
        XCTAssertEqual(ArtworkDecodeMath.placeholderOrder(below: 3840).first, 3072)
    }

    func testPoolThreshold() {
        XCTAssertEqual(ArtworkDecodeMath.largePoolThreshold, 6 * 1024 * 1024)
        // A 2:3 poster at the 1280 bucket (853×1280 px, 4 bytes a pixel) stays in the small pool; a
        // 1920×1080 backdrop (8.3 MB) goes to the large one.
        XCTAssertLessThan(853 * 1280 * 4, ArtworkDecodeMath.largePoolThreshold)
        XCTAssertGreaterThan(1920 * 1080 * 4, ArtworkDecodeMath.largePoolThreshold)
    }

    func testIndexOfBucket() {
        XCTAssertEqual(ArtworkDecodeMath.index(of: 128), 0)
        XCTAssertEqual(ArtworkDecodeMath.index(of: 3840), ArtworkDecodeMath.buckets.count - 1)
        // A value that is not a bucket maps to the next bucket up.
        XCTAssertEqual(ArtworkDecodeMath.index(of: 1000), ArtworkDecodeMath.index(of: 1024))
    }

    func testPosterCardDecodeRequestIsPointsFillAtScale() {
        // The card, the folder page's reveal prefetch and the Home row-poster prewarm all ask for this one request.
        let request = PosterCard.decodeRequest(width: 360, height: 540, scale: 2)
        XCTAssertEqual(request, ArtworkDecodeRequest(size: .points(width: 360, height: 540), fill: true, scale: 2))
        // The zero-size first pass is the legacy request, not a 128 px bucket.
        XCTAssertEqual(PosterCard.decodeRequest(width: 0, height: 0, scale: 2), .legacy)
    }
}
