import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (P, BUG-139): the native player's preparing caption says "Preparing
/// playback…" until the remux reports a Dolby Vision stream. It used to say "Preparing Dolby
/// Vision…" for every file on the native engine, SDR and HDR10 included.
final class NativePreparingLabelTests: XCTestCase {
    private let playbackText = String(localized: "Preparing playback\u{2026}")
    private let dolbyVisionText = String(localized: "Preparing Dolby Vision\u{2026}")

    /// Before the remux has inspected the streams there is no signaling yet: plain playback.
    func testNilIsPlayback() {
        XCTAssertFalse(NativePreparingLabel.isDolbyVision(nil))
        XCTAssertEqual(NativePreparingLabel.text(for: nil), playbackText)
        XCTAssertNotEqual(playbackText, dolbyVisionText)
    }

    /// HDR10 over HEVC (PQ range, no Dolby Vision record) is not Dolby Vision.
    func testHevcHdr10IsPlayback() {
        let hdr10 = VideoSignaling(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: nil, videoRange: "PQ")
        XCTAssertFalse(NativePreparingLabel.isDolbyVision(hdr10))
        XCTAssertEqual(NativePreparingLabel.text(for: hdr10), playbackText)

        // An SDR H.264 file and a source the remux could not describe stay plain playback too.
        let sdr = VideoSignaling(codecs: "avc1.640028", supplementalCodecs: nil, videoRange: nil)
        XCTAssertFalse(NativePreparingLabel.isDolbyVision(sdr))
        let unknown = VideoSignaling(codecs: "")
        XCTAssertFalse(NativePreparingLabel.isDolbyVision(unknown))
        XCTAssertEqual(NativePreparingLabel.text(for: unknown), playbackText)
    }

    /// Profile 8.1: an HDR10 base layer with the Dolby Vision tail in SUPPLEMENTAL-CODECS.
    func testP8SupplementalIsDV() {
        let p8 = VideoSignaling(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: "dvh1.08.06/db1p", videoRange: "PQ")
        XCTAssertTrue(NativePreparingLabel.isDolbyVision(p8))
        XCTAssertEqual(NativePreparingLabel.text(for: p8), dolbyVisionText)

        // An empty supplemental token is not a Dolby Vision signal.
        let empty = VideoSignaling(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: "", videoRange: "PQ")
        XCTAssertFalse(NativePreparingLabel.isDolbyVision(empty))
    }

    /// Profile 5 has no cross-compatible base layer: the Dolby Vision string is the codec string.
    func testP5CodecIsDV() {
        let p5 = VideoSignaling(codecs: "dvh1.05.06", supplementalCodecs: nil, videoRange: "PQ")
        XCTAssertTrue(NativePreparingLabel.isDolbyVision(p5))
        XCTAssertEqual(NativePreparingLabel.text(for: p5), dolbyVisionText)
    }

    /// The in-band `dvhe` variant counts the same as `dvh1`.
    func testDvheIsDV() {
        let dvhe = VideoSignaling(codecs: "dvhe.05.06", supplementalCodecs: nil, videoRange: "PQ")
        XCTAssertTrue(NativePreparingLabel.isDolbyVision(dvhe))
        XCTAssertEqual(NativePreparingLabel.text(for: dvhe), dolbyVisionText)
    }
}
