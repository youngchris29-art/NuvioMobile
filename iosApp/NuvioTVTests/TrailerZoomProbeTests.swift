import XCTest
@testable import NuvioTV

/// BUG-81/Wave F item C: unit coverage for `TrailerZoomProbe`'s tail-rolling ring buffer — the
/// release-safe About > Trailer Diagnostics readout. Mirrors `HomeHeroProbeBufferTests`'s shape,
/// but `TrailerZoomProbe` is tail-rolling (like `StreamProbe`), not head-preserving (like
/// `HomeHeroProbe`): there is no launch head worth protecting for a single trailer dwell, so the
/// buffer just keeps the most recent `maxLines` lines.
///
/// `TrailerZoomProbe.log(_:)` gates the in-memory buffer on `TrailerZoomProbe.enabled`
/// (`debug.trailerDiagnostics`) — unlike `HomeHeroProbe.log`, which always appends regardless of
/// its own toggle. That means these tests DO need the toggle on to see anything land, and they
/// restore whatever was there before so this file doesn't leak state into other tests in the same
/// process.
final class TrailerZoomProbeTests: XCTestCase {
    private let key = "debug.trailerDiagnostics"
    private var previousValue: Bool = false

    override func setUp() {
        super.setUp()
        previousValue = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        TrailerZoomProbe.clear()
    }

    override func tearDown() {
        TrailerZoomProbe.clear()
        UserDefaults.standard.set(previousValue, forKey: key)
        super.tearDown()
    }

    func testDisabledKeyRecordsNothing() {
        UserDefaults.standard.set(false, forKey: key)
        TrailerZoomProbe.log("should-not-appear")
        XCTAssertTrue(TrailerZoomProbe.lines.isEmpty, "log() must be a no-op while debug.trailerDiagnostics is off")
    }

    func testSixtyLinesInKeepsNewest40() {
        XCTAssertEqual(TrailerZoomProbe.maxLines, 40)

        for i in 1...60 {
            TrailerZoomProbe.log(String(format: "tzpt-line-%04d", i))
        }

        let lines = TrailerZoomProbe.lines
        XCTAssertEqual(lines.count, 40, "buffer must cap at maxLines")

        // Oldest 20 (1...20) rolled off; the kept window is 21...60, newest last.
        XCTAssertTrue(lines.first?.hasSuffix("tzpt-line-0021") ?? false, "first kept line should be #21: \(lines.first ?? "-")")
        XCTAssertTrue(lines.last?.hasSuffix("tzpt-line-0060") ?? false, "last kept line should be #60 (newest): \(lines.last ?? "-")")

        // Ordering is oldest-to-newest throughout the kept window.
        for idx in 0..<lines.count {
            let expectedSuffix = String(format: "tzpt-line-%04d", idx + 21)
            XCTAssertTrue(lines[idx].hasSuffix(expectedSuffix), "lines[\(idx)] = \(lines[idx]) does not end with \(expectedSuffix)")
        }
    }

    func testEachLineCarriesAMillisecondTimestampPrefix() {
        TrailerZoomProbe.log("tzpt-timestamp-check")
        guard let line = TrailerZoomProbe.lines.last else {
            XCTFail("expected at least one line")
            return
        }
        XCTAssertTrue(line.hasSuffix("ms tzpt-timestamp-check"), "line should be stamped '<N>ms <text>': \(line)")
    }

    func testClearEmptiesTheBuffer() {
        TrailerZoomProbe.log("tzpt-before-clear")
        XCTAssertFalse(TrailerZoomProbe.lines.isEmpty)
        TrailerZoomProbe.clear()
        XCTAssertTrue(TrailerZoomProbe.lines.isEmpty)
    }
}
