import XCTest
import CoreGraphics
@testable import NuvioTV

/// Fake codec: `encode` returns `width * 10` bytes whose first byte tags the image width, so a
/// replaced entry is visible; `decode` counts calls and returns a 1 × 1 image.
private final class FakeCodec: PreviewFrameCodec, @unchecked Sendable {
    private let lock = NSLock()
    private var _decodes = 0
    var decodes: Int { lock.lock(); defer { lock.unlock() }; return _decodes }
    private(set) var lastDecodedTag: UInt8?

    func encode(_ image: CGImage) -> Data? {
        var d = Data(count: image.width * 10)
        d[0] = UInt8(truncatingIfNeeded: image.width)
        return d
    }

    func decode(_ data: Data) -> CGImage? {
        lock.lock(); _decodes += 1; lastDecodedTag = data.first; lock.unlock()
        return SeekPreviewStoreTests.image(width: 1)
    }
}

final class SeekPreviewStoreTests: XCTestCase {
    static func image(width: Int, height: Int = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        return ctx.makeImage()!
    }

    private func img(_ w: Int = 4) -> CGImage { Self.image(width: w) }

    private func store(maxEntries: Int = 200, maxBytes: Int = 6 * 1024 * 1024, codec: FakeCodec = FakeCodec()) -> SeekPreviewStore {
        SeekPreviewStore(streamKey: "test", codec: codec, maxEntries: maxEntries, maxBytes: maxBytes)
    }

    // 1
    func testInsertThenExactLookupHits() async {
        let s = store()
        await s.insert(img(), at: 10)
        let hit = await s.thumbnail(near: 10)
        XCTAssertNotNil(hit)
        let count = await s.count
        XCTAssertEqual(count, 1)
    }

    // 2
    func testNearestOfTwoWinsAndTieGoesEarlier() async {
        let codec = FakeCodec()
        let s = store(codec: codec)
        await s.insert(img(3), at: 10)
        await s.insert(img(7), at: 20)
        _ = await s.thumbnail(near: 18)
        XCTAssertEqual(codec.lastDecodedTag, 7)
        _ = await s.thumbnail(near: 15)       // tie
        XCTAssertEqual(codec.lastDecodedTag, 3)
    }

    // 3
    func testMissBeyondExplicitTolerance() async {
        let s = store()
        await s.insert(img(), at: 10)
        let miss = await s.thumbnail(near: 13, tolerance: 2)
        XCTAssertNil(miss)
        let hit = await s.thumbnail(near: 12, tolerance: 2)
        XCTAssertNotNil(hit)
    }

    // 4
    func testDefaultToleranceIsTenWithOneEntry() async {
        let s = store()
        await s.insert(img(), at: 100)
        let spacing = await s.sampleSpacing()
        XCTAssertEqual(spacing, 10)
        let within = await s.thumbnail(near: 110)
        XCTAssertNotNil(within)
        let beyond = await s.thumbnail(near: 110.5)
        XCTAssertNil(beyond)
    }

    // 5
    func testSpacingIsMedianOfGaps() async {
        let s = store()
        for t in [0.0, 5, 10, 30] { await s.insert(img(), at: t) }   // gaps 5, 5, 20
        let spacing = await s.sampleSpacing()
        XCTAssertEqual(spacing, 5)
        let hit = await s.thumbnail(near: 35)
        XCTAssertNotNil(hit)
        let miss = await s.thumbnail(near: 35.5)
        XCTAssertNil(miss)
    }

    // 6
    func testGapsOverSixtySecondsIgnoredBySpacing() async {
        let s = store()
        for t in [0.0, 4, 8, 500, 504] { await s.insert(img(), at: t) }   // 4, 4, 492, 4
        let spacing = await s.sampleSpacing()
        XCTAssertEqual(spacing, 4)
    }

    // 7
    func testToleranceClampedToThirtyWithSparseStamps() async {
        let s = store()
        for t in [0.0, 50, 100] { await s.insert(img(), at: t) }   // spacing 50
        let spacing = await s.sampleSpacing()
        XCTAssertEqual(spacing, 50)
        let hit = await s.thumbnail(near: 130)
        XCTAssertNotNil(hit)
        let miss = await s.thumbnail(near: 131)
        XCTAssertNil(miss)
    }

    // 8
    func testInsertWithinOneSecondReplaces() async {
        let codec = FakeCodec()
        let s = store(codec: codec)
        await s.insert(img(3), at: 10)
        await s.insert(img(9), at: 10.8)
        let count = await s.count
        XCTAssertEqual(count, 1)
        let bytes = await s.byteCount
        XCTAssertEqual(bytes, 90)
        _ = await s.thumbnail(near: 10.8)
        XCTAssertEqual(codec.lastDecodedTag, 9)
    }

    // 9
    func testEvictionDropsOldestInsertedEvenWhenLatestInTime() async {
        let codec = FakeCodec()
        let s = store(maxEntries: 3, codec: codec)
        await s.insert(img(1), at: 300)   // oldest inserted, largest sec
        await s.insert(img(2), at: 10)
        await s.insert(img(3), at: 20)
        await s.insert(img(4), at: 30)
        let count = await s.count
        XCTAssertEqual(count, 3)
        let cov = await s.coverage()
        XCTAssertEqual(cov.last?.upperBound, 30)
        let gone = await s.thumbnail(near: 300, tolerance: 1)
        XCTAssertNil(gone)
    }

    // 10
    func testLookupsDoNotRefreshRecency() async {
        let s = store(maxEntries: 2)
        await s.insert(img(), at: 10)
        await s.insert(img(), at: 20)
        _ = await s.thumbnail(near: 10)
        await s.insert(img(), at: 30)
        let stillThere = await s.thumbnail(near: 10, tolerance: 1)
        XCTAssertNil(stillThere)
        let newer = await s.thumbnail(near: 20, tolerance: 1)
        XCTAssertNotNil(newer)
    }

    // 11
    func testMaxBytesCapEvictsUntilUnder() async {
        let s = store(maxBytes: 100)     // 40 bytes per entry (width 4)
        for t in [0.0, 10, 20, 30] { await s.insert(img(4), at: t) }
        let count = await s.count
        let bytes = await s.byteCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(bytes, 80)
        let first = await s.thumbnail(near: 0, tolerance: 1)
        XCTAssertNil(first)
    }

    // 12
    func testCoverageJoinsAndSplits() async {
        let s = store()
        for t in [0.0, 10, 20, 200] { await s.insert(img(), at: t) }
        let cov = await s.coverage()
        XCTAssertEqual(cov, [0...20, 200...200])
    }

    // 13
    func testRemoveAllEmptiesAndClearsDecodeCache() async {
        let codec = FakeCodec()
        let s = store(codec: codec)
        await s.insert(img(), at: 10)
        _ = await s.thumbnail(near: 10)
        _ = await s.thumbnail(near: 10)
        XCTAssertEqual(codec.decodes, 1, "a still scrub decodes once")
        await s.removeAll()
        let count = await s.count
        let bytes = await s.byteCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(bytes, 0)
        let none = await s.thumbnail(near: 10)
        XCTAssertNil(none)
        await s.insert(img(), at: 10)
        _ = await s.thumbnail(near: 10)
        XCTAssertEqual(codec.decodes, 2, "the cache was cleared")
    }

    // 14
    func testNonFiniteNegativeAndOverWideInsertsIgnored() async {
        let s = store()
        await s.insert(img(), at: .nan)
        await s.insert(img(), at: .infinity)
        await s.insert(img(), at: -1)
        await s.insert(img(SeekPreviewStore.targetWidth + 1), at: 10)
        let count = await s.count
        XCTAssertEqual(count, 0)
    }

    // Conformance + scaler
    func testStoreIsASeekPreviewSource() async {
        let s = store()
        await s.insert(img(), at: 5)
        let source: SeekPreviewSource = s
        let hit = await source.thumbnail(near: 6)
        XCTAssertNotNil(hit)
    }

    func testScalerMakesBgr0Thumbnail() {
        let w = 640, h = 360, stride = w * 4
        let frame = MPVRawFrame(width: w, height: h, stride: stride, format: "bgr0", bytes: Data(count: stride * h))
        let thumb = PreviewFrameScaler.makeThumbnail(frame)
        XCTAssertEqual(thumb?.width, 320)
        XCTAssertEqual(thumb?.height, 180)
        let scope = MPVRawFrame(width: 1920, height: 804, stride: 1920 * 4, format: "bgr0", bytes: Data(count: 1920 * 4 * 804))
        XCTAssertEqual(PreviewFrameScaler.makeThumbnail(scope)?.height, 134)
        let hdr = MPVRawFrame(width: w, height: h, stride: stride * 2, format: "rgba64", bytes: Data(count: stride * 2 * h))
        XCTAssertNil(PreviewFrameScaler.makeThumbnail(hdr))
    }

    func testJPEGCodecRoundTrip() {
        let codec = JPEGPreviewCodec()
        let data = codec.encode(Self.image(width: 320, height: 180))
        XCTAssertNotNil(data)
        let back = data.flatMap { codec.decode($0) }
        XCTAssertEqual(back?.width, 320)
        XCTAssertEqual(back?.height, 180)
    }
}
