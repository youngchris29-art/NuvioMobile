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

/// Counts encodes (P3: a rejected decode insert must not pay one).
private final class CountingCodec: PreviewFrameCodec, @unchecked Sendable {
    private let lock = NSLock()
    private var _encodes = 0
    var encodes: Int { lock.lock(); defer { lock.unlock() }; return _encodes }
    func encode(_ image: CGImage) -> Data? {
        lock.lock(); _encodes += 1; lock.unlock()
        return Data(count: image.width * 10)
    }
    func decode(_ data: Data) -> CGImage? { SeekPreviewStoreTests.image(width: 1) }
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

    // MARK: - P3 merge rules (origin, snapshot, decode caps)

    private func insert(_ s: SeekPreviewStore, _ w: Int = 4, at t: Double, _ o: PreviewFrameOrigin) async -> SeekPreviewInsertOutcome {
        await s.insert(img(w), at: t, origin: o).outcome
    }

    // P3-1
    func testHarvestWithinOneSecondOfDecodeReplacesIt() async {
        let codec = FakeCodec()
        let s = store(codec: codec)
        let first = await insert(s, 3, at: 10, .decode)
        let second = await insert(s, 9, at: 10.6, .harvest)
        XCTAssertEqual(first, .stored)
        XCTAssertEqual(second, .replaced)
        let snap = await s.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.harvest, 1)
        XCTAssertEqual(snap.decode, 0)
        let m = await s.match(near: 10.6)
        XCTAssertEqual(m?.origin, .harvest)
        XCTAssertEqual(m?.sec, 10.6)
        XCTAssertEqual(codec.lastDecodedTag, 9)
    }

    // P3-2
    func testDecodeWithinOneSecondOfHarvestIsKeptExisting() async {
        let s = store()
        _ = await insert(s, 3, at: 10, .harvest)
        let before = await s.byteCount
        let r = await s.insert(img(9), at: 10.9, origin: .decode)
        XCTAssertEqual(r.outcome, .keptExisting)
        XCTAssertEqual(r.snapshot.bytes, before)
        XCTAssertEqual(r.snapshot.harvest, 1)
        XCTAssertEqual(r.snapshot.decode, 0)
    }

    // P3-3
    func testDecodeWithinOneSecondOfDecodeIsKeptExisting() async {
        let codec = FakeCodec()
        let s = store(codec: codec)
        _ = await insert(s, 3, at: 10, .decode)
        let r = await insert(s, 9, at: 9.2, .decode)
        XCTAssertEqual(r, .keptExisting)
        _ = await s.thumbnail(near: 10)
        XCTAssertEqual(codec.lastDecodedTag, 3)
    }

    // P3-4 (C17): densest decode entry goes first, never a harvest entry while a decode one is left.
    func testHarvestOverCapEvictsDensestDecodeEntry() async {
        let s = store(maxEntries: 4)
        _ = await insert(s, at: 0, .decode)      // coarse
        _ = await insert(s, at: 60, .decode)     // coarse
        _ = await insert(s, at: 100, .harvest)
        _ = await insert(s, at: 63, .decode)     // 3 s from 60: the densest pair
        let r = await s.insert(img(), at: 200, origin: .harvest)
        XCTAssertEqual(r.outcome, .stored)
        XCTAssertEqual(r.snapshot.count, 4)
        // 60 and 63 tie on gap 3; 60 is older and goes. The coarse 0 and both harvest frames stay.
        XCTAssertEqual(r.snapshot.stamps, [0, 63, 100, 200])
        XCTAssertEqual(r.snapshot.harvest, 2)
    }

    // P3-5
    func testHarvestOverCapWithNoDecodeEntriesEvictsOldestHarvest() async {
        let s = store(maxEntries: 2)
        _ = await insert(s, at: 300, .harvest)
        _ = await insert(s, at: 10, .harvest)
        let r = await s.insert(img(), at: 20, origin: .harvest)
        XCTAssertEqual(r.snapshot.stamps, [10, 20])
    }

    // P3-6
    func testDecodeAtEntryCapIsRejectedWithoutEncodeOrEviction() async {
        let codec = CountingCodec()
        let s = SeekPreviewStore(streamKey: "t", codec: codec, maxEntries: 2, maxBytes: 1 << 20)
        _ = await s.insert(img(), at: 0, origin: .harvest)
        _ = await s.insert(img(), at: 10, origin: .decode)
        let encodesBefore = codec.encodes
        let r = await s.insert(img(), at: 20, origin: .decode)
        XCTAssertEqual(r.outcome, .rejectedFull)
        XCTAssertEqual(codec.encodes, encodesBefore, "a rejected decode never pays the encode")
        XCTAssertEqual(r.snapshot.stamps, [0, 10])
        XCTAssertFalse(r.snapshot.acceptsDecode)
        let accepts = await s.acceptsDecode
        XCTAssertFalse(accepts)
    }

    // P3-7
    func testByteCapRejectsDecodeAndEvictsForHarvest() async {
        let s = store(maxEntries: 100, maxBytes: 100)    // 40 bytes per width-4 entry
        _ = await insert(s, at: 0, .decode)
        _ = await insert(s, at: 10, .decode)
        let full = await s.snapshot()
        XCTAssertFalse(full.acceptsDecode, "80 + 40 > 100")
        let rejected = await insert(s, at: 20, .decode)
        XCTAssertEqual(rejected, .rejectedFull)
        let r = await s.insert(img(), at: 30, origin: .harvest)
        XCTAssertEqual(r.outcome, .stored)
        XCTAssertEqual(r.snapshot.bytes, 80)
        XCTAssertEqual(r.snapshot.harvest, 1)
        XCTAssertEqual(r.snapshot.decode, 1)
        // Only harvest left over the cap: oldest harvest goes (P2).
        _ = await s.setCaps(maxEntries: 100, maxBytes: 40)
        let snap = await s.snapshot()
        XCTAssertEqual(snap.stamps, [30])
    }

    // P3-8
    func testMatchReturnsStampAndOriginAndThumbnailAgrees() async {
        let s = store()
        _ = await insert(s, at: 40, .decode)
        _ = await insert(s, at: 50, .harvest)
        let m = await s.match(near: 42)
        XCTAssertEqual(m?.sec, 40)
        XCTAssertEqual(m?.origin, .decode)
        let t = await s.thumbnail(near: 42)
        XCTAssertTrue(t === m?.image, "thumbnail(near:) is match(near:)?.image (same cached decode)")
        let source: SeekPreviewSource = s
        let viaProtocol = await source.match(near: 49)
        XCTAssertEqual(viaProtocol?.origin, .harvest)
        let none = await s.match(near: 500)
        XCTAssertNil(none)
    }

    // P3-9 (C18): concrete stamps.
    func testKeyframeSpacingRaisesToleranceUpToThirty() async {
        let s = store()
        _ = await insert(s, at: 0, .harvest)
        _ = await insert(s, at: 10, .harvest)                 // spacing 10 (fewer than 3 entries)
        var tol = await s.defaultTolerance()
        XCTAssertEqual(tol, 10)
        tol = await s.setKeyframeSpacing(8).tolerance
        XCTAssertEqual(tol, 10)
        tol = await s.setKeyframeSpacing(12).tolerance
        XCTAssertEqual(tol, 12)
        let hit = await s.thumbnail(near: 22)
        XCTAssertNotNil(hit)
        tol = await s.setKeyframeSpacing(40).tolerance
        XCTAssertEqual(tol, 30)
        tol = await s.setKeyframeSpacing(nil).tolerance
        XCTAssertEqual(tol, 10)
        tol = await s.setKeyframeSpacing(.nan).tolerance
        XCTAssertEqual(tol, 10)
    }

    // P3-10
    func testCountsAndStampsTrackInsertsReplacesAndEvictions() async {
        let s = store(maxEntries: 3)
        _ = await insert(s, at: 5, .decode)
        _ = await insert(s, at: 15, .decode)
        _ = await insert(s, at: 25, .harvest)
        var c = await s.counts
        XCTAssertEqual(c.harvest, 1); XCTAssertEqual(c.decode, 2)
        _ = await insert(s, at: 15.5, .harvest)                // replaces the decode at 15
        c = await s.counts
        XCTAssertEqual(c.harvest, 2); XCTAssertEqual(c.decode, 1)
        _ = await insert(s, at: 35, .harvest)                  // evicts the decode at 5
        c = await s.counts
        XCTAssertEqual(c.harvest, 3); XCTAssertEqual(c.decode, 0)
        let stamps = await s.stamps()
        XCTAssertEqual(stamps, [15.5, 25, 35])
    }

    // P3-11
    func testSnapshotIsTakenAfterTheInsert() async {
        let s = store()
        let r = await s.insert(img(4), at: 7, origin: .decode)
        XCTAssertEqual(r.snapshot, SeekPreviewSnapshot(count: 1, bytes: 40, harvest: 0, decode: 1, stamps: [7],
                                                       acceptsDecode: true, tolerance: 10, version: r.snapshot.version))
        let invalid = await s.insert(img(), at: -3, origin: .decode)
        XCTAssertEqual(invalid.outcome, .invalid)
        XCTAssertEqual(invalid.snapshot.count, 1)
        let cleared = await s.removeAll()
        XCTAssertEqual(cleared.count, 0); XCTAssertEqual(cleared.bytes, 0); XCTAssertEqual(cleared.stamps, [])
        XCTAssertTrue(cleared.supersedes(.empty))
    }

    // Review r1 P2 #4: every snapshot the actor hands out (insert, spacing, caps, removeAll,
    // snapshot()) carries a higher version than the one before; `.empty` is 0.
    func testSnapshotVersionIncreasesOnEveryOperation() async {
        let s = store()
        var versions: [UInt64] = []
        versions.append(await s.insert(img(4), at: 7, origin: .decode).snapshot.version)
        versions.append(await s.setKeyframeSpacing(4).version)
        versions.append(await s.insert(img(4), at: 20, origin: .harvest).snapshot.version)
        versions.append(await s.insert(img(), at: -1, origin: .decode).snapshot.version)   // invalid still counts
        versions.append(await s.setCaps(maxEntries: 50, maxBytes: 10_000).version)
        versions.append(await s.snapshot().version)
        versions.append(await s.removeAll().version)
        XCTAssertEqual(SeekPreviewSnapshot.empty.version, 0)
        XCTAssertGreaterThan(versions[0], 0)
        XCTAssertEqual(versions, versions.sorted())
        XCTAssertEqual(Set(versions).count, versions.count)
    }

    // Review r1 P2 #4: the controller's rule, pure: an older snapshot arriving after a newer one
    // is ignored, so the mirror never loses a stamp.
    func testOlderSnapshotIsIgnoredByTheMirrorRule() async {
        let s = store()
        let older = await s.insert(img(4), at: 7, origin: .decode).snapshot
        let newer = await s.insert(img(4), at: 30, origin: .harvest).snapshot
        var mirror = SeekPreviewSnapshot.empty
        for snap in [newer, older] where snap.supersedes(mirror) { mirror = snap }   // out of order
        XCTAssertEqual(mirror, newer)
        XCTAssertEqual(mirror.stamps, [7, 30])
        XCTAssertFalse(older.supersedes(newer))
        XCTAssertFalse(newer.supersedes(newer))
    }

    // Review r2 P3: the open path's `setKeyframeSpacing` completion crosses a live reconnect. The
    // old store's snapshot (a higher version than anything the new store has handed out) must not
    // become the new store's mirror, or the new store's snapshots would be dropped until their
    // versions caught up.
    func testMirrorDropsALateSnapshotFromAReplacedStore() async {
        let old = store()
        var mirror = SeekPreviewStoreMirror()
        mirror.install(ObjectIdentifier(old))
        for sec in [0.0, 10, 20, 30] { _ = await old.insert(img(4), at: sec, origin: .harvest) }
        let lateSpacing = await old.setKeyframeSpacing(4)          // in flight across the reconnect
        XCTAssertGreaterThan(lateSpacing.version, 1)

        let new = store()                                            // the reconnect installs a new store
        mirror.install(ObjectIdentifier(new))
        XCTAssertEqual(mirror.snapshot, .empty)
        XCTAssertFalse(mirror.apply(lateSpacing, from: ObjectIdentifier(old)), "the old store's late snapshot")
        XCTAssertEqual(mirror.snapshot, .empty)

        let first = await new.insert(img(4), at: 5, origin: .harvest).snapshot
        XCTAssertLessThan(first.version, lateSpacing.version)
        XCTAssertTrue(mirror.apply(first, from: ObjectIdentifier(new)), "the new store's first snapshot lands")
        XCTAssertEqual(mirror.snapshot.stamps, [5])
        let oldInsert = await old.insert(img(4), at: 40, origin: .decode).snapshot
        XCTAssertFalse(mirror.apply(oldInsert, from: ObjectIdentifier(old)))
        XCTAssertEqual(mirror.snapshot, first)
    }

    func testMirrorKeepsTheNewestSnapshotOfItsStore() async {
        let s = store()
        var mirror = SeekPreviewStoreMirror()
        mirror.install(ObjectIdentifier(s))
        let older = await s.insert(img(4), at: 7, origin: .decode).snapshot
        let newer = await s.setKeyframeSpacing(4)
        XCTAssertTrue(mirror.apply(newer, from: ObjectIdentifier(s)))
        XCTAssertFalse(mirror.apply(older, from: ObjectIdentifier(s)), "out of order")
        XCTAssertFalse(mirror.apply(newer, from: ObjectIdentifier(s)), "the same snapshot twice")
        XCTAssertEqual(mirror.snapshot, newer)
    }

    func testMirrorAcceptsNothingWithNoStoreInstalled() async {
        let s = store()
        var mirror = SeekPreviewStoreMirror()
        let snap = await s.insert(img(4), at: 7, origin: .decode).snapshot
        XCTAssertFalse(mirror.apply(snap, from: ObjectIdentifier(s)), "before the first install")
        mirror.install(ObjectIdentifier(s))
        XCTAssertTrue(mirror.apply(snap, from: ObjectIdentifier(s)))
        mirror.install(nil)                                           // teardown
        XCTAssertEqual(mirror.snapshot, .empty)
        let late = await s.setKeyframeSpacing(4)
        XCTAssertFalse(mirror.apply(late, from: ObjectIdentifier(s)), "after teardown")
        XCTAssertNil(mirror.storeID)
    }

    // P3-12
    func testDecodeCapsAndModeCaps() async {
        XCTAssertEqual(SeekPreviewStore.caps(for: .decode).maxEntries, 800)
        XCTAssertEqual(SeekPreviewStore.caps(for: .decode).maxBytes, 16 * 1024 * 1024)
        XCTAssertEqual(SeekPreviewStore.caps(for: .harvest).maxEntries, 200)
        XCTAssertEqual(SeekPreviewStore.caps(for: .off).maxBytes, 6 * 1024 * 1024)
        let s = store(maxEntries: 1)
        _ = await insert(s, at: 0, .harvest)
        let before = await s.acceptsDecode
        XCTAssertFalse(before)
        let after = await s.setCaps(maxEntries: 800, maxBytes: 16 * 1024 * 1024)
        XCTAssertTrue(after.acceptsDecode)
        let r = await insert(s, at: 10, .decode)
        XCTAssertEqual(r, .stored)
    }

    // P3-13: a decoded frame never displaces a harvest frame, even when the store is full of them.
    func testDecodeNeverEvictsHarvest() async {
        let s = store(maxEntries: 2)
        _ = await insert(s, at: 0, .harvest)
        _ = await insert(s, at: 10, .harvest)
        let r = await s.insert(img(), at: 50, origin: .decode)
        XCTAssertEqual(r.outcome, .rejectedFull)
        XCTAssertEqual(r.snapshot.stamps, [0, 10])
        XCTAssertEqual(r.snapshot.harvest, 2)
    }
}
