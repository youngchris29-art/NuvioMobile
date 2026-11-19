import XCTest
@testable import NuvioTV

/// Player P3 spike: the I-frame rendition trims a remuxed segment to its first sample.
final class IFrameFragmentTests: XCTestCase {
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return be(size) + Array(type.utf8) + payload
    }
    private func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// moof{ mfhd, traf{ tfhd, tfdt, trun(data_offset + per-sample size [+ duration]) } } + mdat.
    private func fragment(sizes: [UInt32], durations: Bool, dataOffsetOK: Bool = true,
                          withDataOffset: Bool = true) -> Data {
        let mfhd = box("mfhd", be(0) + be(7))
        let tfhd = box("tfhd", be(0x0002_0000) + be(1))          // default-base-is-moof, track 1
        let tfdt = box("tfdt", be(0) + be(1000))
        var flags: UInt32 = withDataOffset ? (0x1 | 0x200) : 0x200
        if durations { flags |= 0x100 }
        var trunPayload = be(flags) + be(UInt32(sizes.count))
        if withDataOffset { trunPayload += be(0) }                    // data_offset patched below
        for s in sizes { if durations { trunPayload += be(40) }; trunPayload += be(s) }
        let trun = box("trun", trunPayload)
        let traf = box("traf", tfhd + tfdt + trun)
        let moof = box("moof", mfhd + traf)
        let payload = (0..<sizes.reduce(0, +)).map { UInt8($0 & 0xFF) }
        let mdat = box("mdat", payload)
        var d = Data(moof + mdat)
        if dataOffsetOK && withDataOffset {
            // data_offset lives 16 bytes into the trun box; trun starts at moof+8+mfhd+8(traf hdr)+tfhd+tfdt.
            let trunStart = 8 + mfhd.count + 8 + tfhd.count + tfdt.count
            IFrameFragment.write32(&d, at: trunStart + 16, UInt32(moof.count + 8))
        }
        return d
    }

    func testTrimsToFirstSample() throws {
        let seg = fragment(sizes: [5, 7, 9], durations: false)
        let out = try XCTUnwrap(IFrameFragment.firstSample(of: seg))
        // Two entries of 4 bytes dropped.
        XCTAssertEqual(out.count, seg.count - 8 - (7 + 9))
        let moofSize = Int(IFrameFragment.be32(out, 0))
        XCTAssertEqual(IFrameFragment.boxType(out, at: 0), "moof")
        XCTAssertEqual(IFrameFragment.boxType(out, at: moofSize), "mdat")
        XCTAssertEqual(Int(IFrameFragment.be32(out, moofSize)), 8 + 5)
        let traf = try XCTUnwrap(IFrameFragment.child(out, in: 8..<moofSize, type: "traf"))
        let trunR = try XCTUnwrap(IFrameFragment.child(out, in: (traf.lowerBound + 8)..<traf.upperBound, type: "trun"))
        let trun = try XCTUnwrap(IFrameFragment.parseTrun(out, range: trunR))
        XCTAssertEqual(trun.sampleCount, 1)
        XCTAssertEqual(trun.firstSampleSize, 5)
        XCTAssertEqual(Int(IFrameFragment.be32(out, try XCTUnwrap(trun.dataOffsetField))), moofSize + 8)
        // The mdat payload is the first sample's bytes.
        XCTAssertEqual(Array(out.suffix(5)), [0, 1, 2, 3, 4])
        // Every box size adds up to the fragment.
        XCTAssertEqual(moofSize + 8 + 5, out.count)
    }

    func testTrimsWithPerSampleDurations() throws {
        let seg = fragment(sizes: [11, 3], durations: true)
        let out = try XCTUnwrap(IFrameFragment.firstSample(of: seg))
        XCTAssertEqual(out.count, seg.count - 8 - 3)
        XCTAssertEqual(Array(out.suffix(11)), (0..<11).map { UInt8($0) })
    }

    func testCutKeepsTheMoofAndEndsAfterTheFirstSample() throws {
        let seg = fragment(sizes: [5, 7, 9], durations: false)
        let out = try XCTUnwrap(IFrameFragment.cutAfterFirstSample(of: seg))
        let moofSize = Int(IFrameFragment.be32(seg, 0))
        XCTAssertEqual(out.count, moofSize + 8 + 5)
        XCTAssertEqual(out.prefix(moofSize), seg.prefix(moofSize))          // moof untouched
        XCTAssertEqual(Int(IFrameFragment.be32(out, moofSize)), 8 + 21)     // original mdat size kept
        XCTAssertEqual(Array(out.suffix(5)), [0, 1, 2, 3, 4])
    }

    func testSingleSampleIsUnchanged() throws {
        let seg = fragment(sizes: [6], durations: false)
        XCTAssertEqual(IFrameFragment.firstSample(of: seg), seg)
    }

    /// Review r1 P2 #3: a trun whose data_offset is not `moofSize + 8` (here 0) is refused by both
    /// cuts, so the server answers 404 rather than serving the wrong bytes.
    func testWrongDataOffsetYieldsNil() {
        let seg = fragment(sizes: [5, 7, 9], durations: false, dataOffsetOK: false)
        XCTAssertNil(IFrameFragment.firstSample(of: seg))
        XCTAssertNil(IFrameFragment.cutAfterFirstSample(of: seg))
        XCTAssertNil(IFrameFragment.body(for: seg, mode: .trim))
    }

    /// Review r1 P2 #3: a trun without a data_offset (data at the moof start) is refused too.
    func testMissingDataOffsetYieldsNil() {
        let seg = fragment(sizes: [5, 7, 9], durations: true, withDataOffset: false)
        XCTAssertNil(IFrameFragment.firstSample(of: seg))
        XCTAssertNil(IFrameFragment.cutAfterFirstSample(of: seg))
        // The same segment with the right data_offset still trims (the check, not the shape, refused it).
        XCTAssertNotNil(IFrameFragment.firstSample(of: fragment(sizes: [5, 7, 9], durations: true)))
    }

    func testMalformedYieldsNil() {
        XCTAssertNil(IFrameFragment.firstSample(of: Data([0, 0, 0, 8] + Array("free".utf8))))
        var seg = fragment(sizes: [5, 7], durations: false)
        seg.removeLast(8)                                    // mdat shorter than the first sample
        XCTAssertNil(IFrameFragment.firstSample(of: seg))
    }

    func testIFramePlaylistAndMasterLine() throws {
        // 1/1000 time base, keyframes every 2 s over 20 s, 4 s segments → 5 segments.
        let kf: [Int64] = stride(from: 0, to: 20_000, by: 2_000).map { Int64($0) }
        let map = try XCTUnwrap(SegmentMap.build(keyframeTicks: kf, timeBaseNum: 1, timeBaseDen: 1000,
                                                 totalDurationSec: 20, segDurSec: 4))
        let pl = map.iFramePlaylist()
        XCTAssertTrue(pl.contains("#EXT-X-I-FRAMES-ONLY\n"))
        XCTAssertTrue(pl.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertEqual(pl.components(separatedBy: "iframe-").count - 1, map.count)
        XCTAssertTrue(pl.hasSuffix("#EXT-X-ENDLIST\n"))
        XCTAssertEqual(SegmentMap.iFrameSegmentIndex("iframe-00003.m4s"), 3)
        XCTAssertNil(SegmentMap.iFrameSegmentIndex("seg-00003.m4s"))
        let sig = VideoSignaling(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: nil, videoRange: "PQ", width: 3840, height: 2160, frameRate: 23.976)
        let master = map.masterPlaylist(signaling: sig, bandwidth: 40_000_000, iFrames: true)
        let line = try XCTUnwrap(master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") })
        XCTAssertTrue(line.contains("CODECS=\"hvc1.2.4.L153.B0\""))
        XCTAssertTrue(line.contains("VIDEO-RANGE=PQ"))
        XCTAssertTrue(line.contains("RESOLUTION=3840x2160"))
        XCTAssertTrue(line.hasSuffix("URI=\"iframe.m3u8\""))
        XCTAssertFalse(map.masterPlaylist(signaling: sig, bandwidth: 1, iFrames: false).contains("I-FRAME"))
    }

    // MARK: - P3 Wave 1 B: gating, INDEPENDENT-SEGMENTS, no whole-segment fallback

    private func fiveSegmentMap() throws -> SegmentMap {
        let kf: [Int64] = stride(from: 0, to: 20_000, by: 2_000).map { Int64($0) }
        return try XCTUnwrap(SegmentMap.build(keyframeTicks: kf, timeBaseNum: 1, timeBaseDen: 1000,
                                              totalDurationSec: 20, segDurSec: 4))
    }
    private let hdrSig = VideoSignaling(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: "dvh1.08.06/db4h",
                                        videoRange: "PQ", width: 3840, height: 2160, frameRate: 23.976)

    func testMasterWithoutIFramesIsThePreP3Master() throws {
        let map = try fiveSegmentMap()
        let off = map.masterPlaylist(signaling: hdrSig, bandwidth: 40_000_000, iFrames: false)
        XCTAssertFalse(off.contains("I-FRAME"))
        XCTAssertFalse(off.contains("INDEPENDENT-SEGMENTS"))
        // The default is off, so an un-migrated caller gets the pre-P3 master too.
        XCTAssertEqual(map.masterPlaylist(signaling: hdrSig, bandwidth: 40_000_000), off)
        // With the rendition on, the ONLY difference is the I-frame line (no master-level tag).
        let on = map.masterPlaylist(signaling: hdrSig, bandwidth: 40_000_000, iFrames: true)
        XCTAssertFalse(on.contains("INDEPENDENT-SEGMENTS"))
        let onLines = on.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(onLines.filter { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }.count, 1)
        XCTAssertEqual(onLines.filter { !$0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }.joined(separator: "\n"), off)
        // The pre-P3 shape: header, then the stream line and the media URI.
        XCTAssertTrue(off.hasPrefix("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-STREAM-INF:"))
        XCTAssertTrue(off.hasSuffix("\nmedia.m3u8\n"))
    }

    /// BUG-168 native half: the master the native engine gets in both states of Developer › Native
    /// I-frame Scan, with Seek Preview Pictures at its default (Watched Parts).
    func testNativeMasterFollowsTheScanRow() throws {
        let map = try fiveSegmentMap()
        let mode = SeekPreviewMode.defaultMode
        let rowOff = map.masterPlaylist(signaling: hdrSig, bandwidth: 40_000_000,
                                        iFrames: mode.allowsNativeIFrames(scanEnabled: false))
        XCTAssertFalse(rowOff.contains("I-FRAME"))
        XCTAssertEqual(rowOff, map.masterPlaylist(signaling: hdrSig, bandwidth: 40_000_000))   // pre-P3 master
        let rowOn = map.masterPlaylist(signaling: hdrSig, bandwidth: 40_000_000,
                                       iFrames: mode.allowsNativeIFrames(scanEnabled: true))
        let iframeLines = rowOn.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }
        XCTAssertEqual(iframeLines.count, 1)
        XCTAssertTrue(iframeLines[0].contains("URI=\"\(SegmentMap.iFramePlaylistName)\""), String(iframeLines[0]))
    }

    func testMasterIndependentSegmentsOnlyWhenAsked() throws {
        let map = try fiveSegmentMap()
        let master = map.masterPlaylist(signaling: hdrSig, bandwidth: 1, iFrames: true, independentSegments: true)
        let lines = master.split(separator: "\n")
        XCTAssertEqual(lines[0], "#EXTM3U")
        XCTAssertEqual(lines[1], "#EXT-X-VERSION:7")
        XCTAssertEqual(lines[2], "#EXT-X-INDEPENDENT-SEGMENTS")   // third line (C19)
        XCTAssertEqual(lines.filter { $0 == "#EXT-X-INDEPENDENT-SEGMENTS" }.count, 1)
    }

    func testIFramePlaylistIsIndependent() throws {
        let pl = try fiveSegmentMap().iFramePlaylist()
        let lines = pl.split(separator: "\n")
        XCTAssertEqual(lines[1], "#EXT-X-VERSION:7")
        XCTAssertEqual(lines[2], "#EXT-X-INDEPENDENT-SEGMENTS")
        XCTAssertTrue(lines.contains("#EXT-X-I-FRAMES-ONLY"))
        // The media playlist never claims it: its segments can open on a CRA with leading pictures.
        XCTAssertFalse(try fiveSegmentMap().mediaPlaylist().contains("INDEPENDENT-SEGMENTS"))
    }

    func testServeModeParse() {
        XCTAssertEqual(IFrameFragment.ServeMode.defaultMode, .trim)
        XCTAssertEqual(IFrameFragment.ServeMode.parse(nil).mode, .trim)
        XCTAssertNil(IFrameFragment.ServeMode.parse(nil).ignored)
        XCTAssertEqual(IFrameFragment.ServeMode.parse("").mode, .trim)
        XCTAssertEqual(IFrameFragment.ServeMode.parse("cut").mode, .cut)
        XCTAssertEqual(IFrameFragment.ServeMode.parse("trim").mode, .trim)
        // The spike's "whole" mode is gone: ignored, trim served, and reported for the DEBUG log.
        let whole = IFrameFragment.ServeMode.parse("whole")
        XCTAssertEqual(whole.mode, .trim)
        XCTAssertEqual(whole.ignored, "whole")
        XCTAssertEqual(IFrameFragment.ServeMode.allCases, [.trim, .cut])
    }

    /// C20: a segment the trimmer cannot parse yields nil (the server answers 404), in both modes,
    /// never the whole segment.
    func testUncuttableSegmentNeverServesWhole() {
        var short = fragment(sizes: [5, 7], durations: false)
        short.removeLast(8)                                   // mdat shorter than the first sample
        let notMoof = Data([0, 0, 0, 8] + Array("free".utf8))
        var noTrun = fragment(sizes: [5, 7], durations: false)
        let trunType = 8 + 16 + 8 + 16 + 16 + 4             // moof hdr, mfhd, traf hdr, tfhd, tfdt, trun size
        XCTAssertEqual(IFrameFragment.boxType(noTrun, at: trunType - 4), "trun")
        noTrun.replaceSubrange(trunType ..< trunType + 4, with: Array("xxxx".utf8))
        for seg in [short, notMoof, noTrun, Data()] {
            for mode in IFrameFragment.ServeMode.allCases {
                XCTAssertNil(IFrameFragment.body(for: seg, mode: mode), "\(mode) \(seg.count)b")
            }
        }
        // A good multi-sample segment is cut, and the result is never the segment itself.
        let good = fragment(sizes: [5, 7, 9], durations: false)
        for mode in IFrameFragment.ServeMode.allCases {
            let body = IFrameFragment.body(for: good, mode: mode)
            XCTAssertNotNil(body, "\(mode)")
            XCTAssertLessThan(body?.count ?? .max, good.count, "\(mode)")
        }
    }

    private func server(iFrames: Bool, map: SegmentMap) -> LocalHLSServer {
        LocalHLSServer(rootDir: FileManager.default.temporaryDirectory, map: map, signaling: hdrSig,
                       bandwidth: 40_000_000, iFrames: iFrames,
                       producingInfo: { (1, nil) }, requestReposition: { _ in })
    }

    func testServerGatesTheRendition() throws {
        UserDefaults.standard.removeObject(forKey: "debug.iframeIndependentMaster")
        let map = try fiveSegmentMap()
        let off = server(iFrames: false, map: map)
        XCTAssertFalse(off.iFrames)
        XCTAssertFalse(off.independentMaster)
        XCTAssertNil(off.renderedPlaylist(named: SegmentMap.iFramePlaylistName))
        let offMaster = try XCTUnwrap(off.renderedMasterPlaylist())
        XCTAssertFalse(offMaster.contains("I-FRAME"))
        XCTAssertFalse(offMaster.contains("INDEPENDENT-SEGMENTS"))
        XCTAssertEqual(offMaster, map.masterPlaylist(signaling: hdrSig, bandwidth: 40_000_000))

        let on = server(iFrames: true, map: map)
        XCTAssertFalse(on.independentMaster)                  // DEBUG key unset → off
        let iframe = try XCTUnwrap(on.renderedPlaylist(named: SegmentMap.iFramePlaylistName))
        XCTAssertTrue(iframe.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        let onMaster = try XCTUnwrap(on.renderedMasterPlaylist())
        XCTAssertTrue(onMaster.contains("#EXT-X-I-FRAME-STREAM-INF:"))
        XCTAssertFalse(onMaster.contains("INDEPENDENT-SEGMENTS"))
    }

    #if DEBUG
    func testDebugIndependentMasterKey() throws {
        let key = "debug.iframeIndependentMaster"
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let map = try fiveSegmentMap()
        let on = server(iFrames: true, map: map)
        XCTAssertTrue(on.independentMaster)
        XCTAssertEqual(try XCTUnwrap(on.renderedMasterPlaylist()).split(separator: "\n")[2],
                       "#EXT-X-INDEPENDENT-SEGMENTS")
        // The key never adds the tag when the rendition is off (Off stays the pre-P3 master).
        let off = server(iFrames: false, map: map)
        XCTAssertFalse(off.independentMaster)
        XCTAssertFalse(try XCTUnwrap(off.renderedMasterPlaylist()).contains("INDEPENDENT-SEGMENTS"))
    }
    #endif
}
