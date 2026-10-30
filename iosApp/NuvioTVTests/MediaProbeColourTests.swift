import XCTest
@testable import NuvioTV

/// HDR detection in the pre-playback probe, against six tiny HEVC fixtures (64×64, six frames,
/// `Fixtures/`) that place the colour tags differently:
///
/// - `hdr10-sps-only`: PQ only in the SPS VUI (+ HDR10 static-metadata SEI); the container carries
///   just a Range element (what FFmpeg 8's Matroska muxer writes).
/// - `hdr10-container-only`: PQ only in the Matroska Colour element; the SPS has no colour description.
/// - `hdr10-sps-and-container`: PQ in both places.
/// - `hdr10-sps-matrix-only-container`: PQ in the SPS, but the Colour element carries ONLY
///   MatrixCoefficients. This is the T8 badge fixture's shape (2026-10-29): FFmpeg 8.1.2's
///   `avformat_find_stream_info` restores the container's primaries/transfer/matrix as a block when
///   any one of them is set, so `codecpar.color_trc` comes back UNSPECIFIED, the probe read SDR, the
///   remux declared no VIDEO-RANGE, and tvOS rejected the PQ media with -12927.
/// - `hlg-sps-matrix-only-container`: the same shape with HLG.
/// - `sdr-bt709`: control.
///
/// The fixture tests run the real probe (MPVKit's FFmpeg); the rest exercise the pure precedence rule.
final class MediaProbeColourTests: XCTestCase {

    // MARK: Fixtures through the real probe

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: MediaProbeColourTests.self)
        if let url = bundle.url(forResource: name, withExtension: "mkv") { return url }
        if let url = bundle.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures") { return url }
        // Never skip: a broken Resources phase must fail the suite, not quietly green it.
        XCTFail("fixture \(name).mkv is not in the test bundle")
        throw NSError(domain: "MediaProbeColourTests", code: 1)
    }

    private func probe(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProbeResult {
        let url = try fixture(name)
        let result = try XCTUnwrap(MediaProbe.probe(url: url, timeoutSec: 10), "probe failed for \(name)", file: file, line: line)
        XCTAssertEqual(result.videoCodec, "hevc", file: file, line: line)
        return result
    }

    /// No container colour at all: FFmpeg's inspection keeps the decoder's SPS read, so the probe
    /// credits the decoder, not the scratch SPS parse.
    func testPQInTheSPSOnlyIsHDR10() throws {
        let p = try probe("hdr10-sps-only")
        XCTAssertEqual(p.hdr, .hdr10)
        XCTAssertEqual(p.hdrSource, .decoder)
    }

    func testPQInTheContainerOnlyIsHDR10() throws {
        let p = try probe("hdr10-container-only")
        XCTAssertEqual(p.hdr, .hdr10)
        XCTAssertEqual(p.hdrSource, .container)
    }

    func testPQInBothPlacesIsHDR10() throws {
        let p = try probe("hdr10-sps-and-container")
        XCTAssertEqual(p.hdr, .hdr10)
        XCTAssertEqual(p.hdrSource, .container)
    }

    /// The T8 fixture shape: a Colour element with MatrixCoefficients only must not hide the SPS's PQ.
    func testPQInTheSPSBehindAMatrixOnlyContainerIsHDR10() throws {
        let p = try probe("hdr10-sps-matrix-only-container")
        XCTAssertEqual(p.hdr, .hdr10)
        XCTAssertEqual(p.hdrSource, .sps)
    }

    func testHLGInTheSPSBehindAMatrixOnlyContainerIsHLG() throws {
        let p = try probe("hlg-sps-matrix-only-container")
        XCTAssertEqual(p.hdr, .hlg)
        XCTAssertEqual(p.hdrSource, .sps)
    }

    func testBT709StaysSDR() throws {
        let p = try probe("sdr-bt709")
        XCTAssertEqual(p.hdr, .sdr)
        XCTAssertEqual(p.hdrSource, .none)
    }

    // MARK: The precedence rule

    private let pqTags = ColourTags(primaries: 9, transfer: 16, matrix: 9)
    private let hlgTags = ColourTags(primaries: 9, transfer: 18, matrix: 9)
    private let bt709Tags = ColourTags(primaries: 1, transfer: 1, matrix: 1)
    private let matrixOnly = ColourTags(primaries: 2, transfer: 2, matrix: 9)

    private func resolve(container: ColourTags = .unspecified, sps: ColourTags? = nil,
                         inspected: ColourTags = .unspecified, dolbyVision: DolbyVisionInfo? = nil,
                         staticMetadata: Bool = false) -> ResolvedColour {
        MediaProbe.resolveColour(container: container, sps: sps, inspected: inspected,
                                 dolbyVision: dolbyVision, hasHDR10StaticMetadata: staticMetadata)
    }

    func testMatrixOnlyContainerTakesTheTransferFromTheSPS() {
        let r = resolve(container: matrixOnly, sps: pqTags, inspected: matrixOnly)
        XCTAssertEqual(r.tags, pqTags)
        XCTAssertEqual(r.transfer, ColourTags.transferPQ)
        XCTAssertEqual(r.transferSource, .sps)
        XCTAssertEqual(r.hdr, .hdr10)
    }

    func testContainerTransferWinsOverTheSPS() {
        let r = resolve(container: bt709Tags, sps: pqTags, inspected: bt709Tags)
        XCTAssertEqual(r.tags, bt709Tags)
        XCTAssertEqual(r.transferSource, .container)
        XCTAssertEqual(r.hdr, .sdr)
    }

    func testMergeIsPerField() {
        // Container: primaries only. SPS: transfer + matrix. Each field keeps the first layer that set it.
        let container = ColourTags(primaries: 9, transfer: 2, matrix: 2)
        let sps = ColourTags(primaries: 1, transfer: 18, matrix: 9)
        let r = resolve(container: container, sps: sps, inspected: container)
        XCTAssertEqual(r.tags, ColourTags(primaries: 9, transfer: 18, matrix: 9))
        XCTAssertEqual(r.transferSource, .sps)
        XCTAssertEqual(r.hdr, .hlg)
    }

    func testInspectedTagsAreTheFallbackWhenThereIsNoSPS() {
        let r = resolve(sps: nil, inspected: pqTags)
        XCTAssertEqual(r.tags, pqTags)
        XCTAssertEqual(r.transferSource, .decoder)
    }

    /// Empty container: inspection goes before the raw SPS, because only inspection applies the
    /// alternative-transfer SEI (HLG signalled as VUI 14 + SEI 18).
    func testWithNoContainerColourInspectionOutranksTheRawSPS() {
        let spsRaw = ColourTags(primaries: 9, transfer: 14, matrix: 9)
        let inspected = ColourTags(primaries: 9, transfer: 18, matrix: 9)
        let r = resolve(container: .unspecified, sps: spsRaw, inspected: inspected)
        XCTAssertEqual(r.tags, inspected)
        XCTAssertEqual(r.transferSource, .decoder)
        XCTAssertEqual(r.hdr, .hlg)
        // With a partial container the clobbered inspection loses to the SPS again.
        let clobbered = ColourTags(primaries: 2, transfer: 2, matrix: 9)
        XCTAssertEqual(resolve(container: matrixOnly, sps: spsRaw, inspected: clobbered).transfer, 14)
    }

    func testReservedCodesCountAsUnset() {
        let reserved = ColourTags(primaries: 0, transfer: 3, matrix: 0)
        let r = resolve(container: reserved, sps: pqTags, inspected: reserved)
        XCTAssertEqual(r.tags, pqTags)
        XCTAssertEqual(r.transferSource, .sps)
        XCTAssertTrue(reserved.isEmpty)
    }

    func testDolbyVisionImpliesTheRangeButNotTheTags() {
        let p5 = DolbyVisionInfo(profile: 5, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 0)
        let p81 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 1)
        let p84 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 4)
        let p82 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 2)
        let r5 = resolve(dolbyVision: p5)
        XCTAssertEqual(r5.transfer, ColourTags.transferPQ)
        XCTAssertEqual(r5.transferSource, .dolbyVision)
        XCTAssertEqual(r5.tags, .unspecified, "an implied range never becomes a colr tag")
        XCTAssertEqual(resolve(dolbyVision: p81).hdr, .hdr10)
        XCTAssertEqual(resolve(dolbyVision: p84).hdr, .hlg)
        XCTAssertEqual(resolve(dolbyVision: p82).hdr, .sdr)
        XCTAssertEqual(resolve(dolbyVision: p82).transferSource, .none)
        // The record outranks a tag that is not PQ/HLG: a stray BT.709 container tag on a P5 stream
        // (old movenc default) still declares PQ, as the remux always did; the tags stay BT.709.
        let strayBT709 = resolve(container: bt709Tags, dolbyVision: p5)
        XCTAssertEqual(strayBT709.hdr, .hdr10)
        XCTAssertEqual(strayBT709.transferSource, .dolbyVision)
        XCTAssertEqual(strayBT709.tags, bt709Tags)
        // P8.4 with the HLG VUI convention (14 in the VUI) declares HLG through the compat id.
        let p84over14 = resolve(sps: ColourTags(primaries: 9, transfer: 14, matrix: 9), dolbyVision: p84)
        XCTAssertEqual(p84over14.hdr, .hlg)
        XCTAssertEqual(p84over14.transferSource, .dolbyVision)
        // Tags that already say PQ/HLG are kept, source and all.
        XCTAssertEqual(resolve(container: hlgTags, dolbyVision: p81).hdr, .hlg)
        XCTAssertEqual(resolve(container: hlgTags, dolbyVision: p81).transferSource, .container)
    }

    func testHDR10StaticMetadataImpliesPQOnlyWhenNothingElseSaysOtherwise() {
        let r = resolve(staticMetadata: true)
        XCTAssertEqual(r.transfer, ColourTags.transferPQ)
        XCTAssertEqual(r.transferSource, .staticMetadata)
        XCTAssertEqual(r.tags, .unspecified)
        XCTAssertEqual(resolve(sps: hlgTags, staticMetadata: true).hdr, .hlg)
        XCTAssertEqual(resolve(sps: bt709Tags, staticMetadata: true).hdr, .sdr, "an explicit tag beats the metadata")
    }

    func testNothingAnywhereIsSDR() {
        let r = resolve()
        XCTAssertEqual(r.hdr, .sdr)
        XCTAssertEqual(r.transferSource, .none)
        XCTAssertEqual(r.transfer, ColourTags.unspecifiedCode)
    }

    func testTransferToHDRFamily() {
        XCTAssertEqual(MediaProbe.hdrFormat(transfer: 16), .hdr10)
        XCTAssertEqual(MediaProbe.hdrFormat(transfer: 18), .hlg)
        XCTAssertEqual(MediaProbe.hdrFormat(transfer: 14), .other)
        XCTAssertEqual(MediaProbe.hdrFormat(transfer: 15), .other)
        XCTAssertEqual(MediaProbe.hdrFormat(transfer: 1), .sdr)
        XCTAssertEqual(MediaProbe.hdrFormat(transfer: 2), .sdr)
    }

    // MARK: Master-playlist VIDEO-RANGE

    func testVideoRangeToken() {
        XCTAssertEqual(VideoSignaling.videoRange(forTransfer: 16), "PQ")
        XCTAssertEqual(VideoSignaling.videoRange(forTransfer: 18), "HLG")
        XCTAssertNil(VideoSignaling.videoRange(forTransfer: 1))
        XCTAssertNil(VideoSignaling.videoRange(forTransfer: 2))
        XCTAssertNil(VideoSignaling.videoRange(forTransfer: 14), "BT.2020 10-bit has no HLS token")
    }
}
