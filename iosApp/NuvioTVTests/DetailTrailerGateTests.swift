import XCTest
@testable import NuvioTV

/// BUG-198: the hero trailer stops under every cover the Detail page presents, the series Play
/// cover included (GitHub #8: it kept playing, with sound, under the series picker and the player).
final class DetailTrailerGateTests: XCTestCase {
    private var open: DetailTrailerGate.Inputs {
        .init(enabled: true, hasTrailer: true, stopped: false, startDelayHeld: false, filmPickerShown: false,
              seriesPlayShown: false, fullScreenTrailerShown: false, synopsisSheetShown: false,
              shuffleSheetShown: false)
    }

    func testRunsWhenEnabledWithATrailerAndNoCover() {
        XCTAssertTrue(DetailTrailerGate.isActive(open))
    }

    func testSeriesPlayCoverStopsIt() {
        var i = open; i.seriesPlayShown = true
        XCTAssertFalse(DetailTrailerGate.isActive(i))
    }

    func testEveryCoverStopsIt() {
        let covers: [(String, (inout DetailTrailerGate.Inputs) -> Void)] = [
            ("film picker", { $0.filmPickerShown = true }),
            ("series Play", { $0.seriesPlayShown = true }),
            ("full-screen trailer", { $0.fullScreenTrailerShown = true }),
            ("synopsis sheet", { $0.synopsisSheetShown = true }),
            ("shuffle sheet", { $0.shuffleSheetShown = true }),
        ]
        for (name, apply) in covers {
            var i = open; apply(&i)
            XCTAssertFalse(DetailTrailerGate.isActive(i), name)
        }
    }

    func testSettingTrailerAndStopStillGate() {
        var a = open; a.enabled = false
        var b = open; b.hasTrailer = false
        var c = open; c.stopped = true
        var d = open; d.startDelayHeld = true
        XCTAssertFalse(DetailTrailerGate.isActive(a))
        XCTAssertFalse(DetailTrailerGate.isActive(b))
        XCTAssertFalse(DetailTrailerGate.isActive(c))
        XCTAssertFalse(DetailTrailerGate.isActive(d), "FEAT-87 Start Delay")
    }
}
