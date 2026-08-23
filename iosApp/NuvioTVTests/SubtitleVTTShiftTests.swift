import XCTest
@testable import NuvioTV

/// Unit tests for `SubtitleVTT.shift` (beta.15 §B3 re-timing) — the native-engine path that shifts
/// every cue of an already-converted WebVTT document by a delay offset. Pure string-in/string-out
/// logic (no mpv/AVPlayer dependency), so these run as plain XCTest against the real app target via
/// `@testable import NuvioTV` rather than through the UI-test bundle.
final class SubtitleVTTShiftTests: XCTestCase {

    // MARK: - Identity

    func testOffsetZeroIsIdentity() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello world\n"
        XCTAssertEqual(SubtitleVTT.shift(vtt, offsetMs: 0), vtt)
    }

    // MARK: - Positive shift

    func testPositiveShiftMovesBothEdgesLater() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello world\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 2000)
        XCTAssertTrue(shifted.contains("00:00:03.000 --> 00:00:05.000"), shifted)
        XCTAssertTrue(shifted.contains("Hello world"))
    }

    // MARK: - Negative shift with clamp-at-0 start

    func testNegativeShiftClampsStartAtZero() {
        // start=0.500 end=2.000, offset -1000ms: end lands at 1.000 (kept), start would go
        // negative (-0.500) and must clamp to 0 rather than render a negative timestamp.
        let vtt = "WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nClamped\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: -1000)
        XCTAssertTrue(shifted.contains("00:00:00.000 --> 00:00:01.000"), shifted)
        XCTAssertTrue(shifted.contains("Clamped"))
    }

    // MARK: - Cue dropped when end <= 0

    func testCueDroppedWhenShiftedEndIsAtOrBeforeZero() {
        // start=0.100 end=0.500, offset -1000ms: shifted end = -500ms <= 0 → the whole cue falls
        // off the front of the timeline and must be dropped entirely (not clamped, not kept).
        let vtt = "WEBVTT\n\n00:00:00.100 --> 00:00:00.500\nGone\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: -1000)
        XCTAssertFalse(shifted.contains("Gone"), shifted)
        XCTAssertFalse(shifted.contains("-->"), shifted)
    }

    // MARK: - Cue settings preserved

    func testCueSettingsPreservedAfterSpace() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000 line:90% align:middle\nHi\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 500)
        XCTAssertTrue(shifted.contains("00:00:01.500 --> 00:00:03.500 line:90% align:middle"), shifted)
    }

    func testCueSettingsPreservedAfterTab() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\tline:90% align:middle\nHi\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 500)
        XCTAssertTrue(shifted.contains("00:00:01.500 --> 00:00:03.500 line:90% align:middle"), shifted)
    }

    // MARK: - Header / NOTE / STYLE blocks untouched

    func testTimestampMapNoteAndStyleBlocksPassThroughUntouched() {
        let vtt = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        NOTE
        This is a note block, never touched by re-timing.

        STYLE
        ::cue { color: yellow; }

        00:00:01.000 --> 00:00:03.000
        Hello world
        """
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 1000)
        XCTAssertTrue(shifted.contains("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000"), shifted)
        XCTAssertTrue(shifted.contains("NOTE\nThis is a note block, never touched by re-timing."), shifted)
        XCTAssertTrue(shifted.contains("STYLE\n::cue { color: yellow; }"), shifted)
        XCTAssertTrue(shifted.contains("00:00:02.000 --> 00:00:04.000"), shifted)
    }

    // MARK: - Comma decimal separator tolerated (SRT leftovers)

    func testCommaDecimalSeparatorTolerated() {
        let vtt = "WEBVTT\n\n00:00:01,000 --> 00:00:03,000\nComma cue\n"
        let shifted = SubtitleVTT.shift(vtt, offsetMs: 1000)
        // Re-rendered timestamps always use the canonical dot separator.
        XCTAssertTrue(shifted.contains("00:00:02.000 --> 00:00:04.000"), shifted)
        XCTAssertTrue(shifted.contains("Comma cue"))
    }

    func testMillisFromVTTTimestampToleratesComma() {
        XCTAssertEqual(SubtitleVTT.millis(fromVTTTimestamp: "00:00:01,500"), 1500)
        XCTAssertEqual(SubtitleVTT.millis(fromVTTTimestamp: "00:00:01.500"), 1500)
    }
}
