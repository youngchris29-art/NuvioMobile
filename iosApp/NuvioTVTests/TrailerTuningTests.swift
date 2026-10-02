import XCTest
@testable import NuvioTV

/// BUG-128: `TrailerTuning.parse` keeps every A/B knob inert at its default.
final class TrailerTuningTests: XCTestCase {
    func testAbsentGivesDefaults() {
        let v = TrailerTuning.parse(buffer: nil, maxFps: nil, letterboxProbeOff: nil, ladder: nil)
        XCTAssertEqual(v, TrailerTuning.Values(forwardBufferSeconds: nil, maxFps: 0, letterboxProbeOff: false, ladder: 0))
    }

    func testZeroGivesDefaults() {
        let v = TrailerTuning.parse(buffer: "0", maxFps: "0", letterboxProbeOff: "0", ladder: "0")
        XCTAssertEqual(v, TrailerTuning.Values(forwardBufferSeconds: nil, maxFps: 0, letterboxProbeOff: false, ladder: 0))
    }

    func testValuesParse() {
        let v = TrailerTuning.parse(buffer: "10", maxFps: 30, letterboxProbeOff: "YES", ladder: 2)
        XCTAssertEqual(v.forwardBufferSeconds, 10)
        XCTAssertEqual(v.maxFps, 30)
        XCTAssertTrue(v.letterboxProbeOff)
        XCTAssertEqual(v.ladder, 2)
    }

    func testNegativeBufferIsNil() {
        let v = TrailerTuning.parse(buffer: -4, maxFps: -30, letterboxProbeOff: nil, ladder: nil)
        XCTAssertNil(v.forwardBufferSeconds)
        XCTAssertEqual(v.maxFps, 0)
    }

    func testNonFiniteGivesDefaults() {
        for bad in ["nan", "inf", "-inf", "1e999"] {
            let v = TrailerTuning.parse(buffer: bad, maxFps: bad, letterboxProbeOff: nil, ladder: bad)
            XCTAssertEqual(v, TrailerTuning.Values(forwardBufferSeconds: nil, maxFps: 0, letterboxProbeOff: false, ladder: 0), bad)
        }
        let defaults = TrailerTuning.Values(forwardBufferSeconds: nil, maxFps: 0, letterboxProbeOff: false, ladder: 0)
        XCTAssertEqual(TrailerTuning.parse(buffer: "-1e300", maxFps: "-1e300", letterboxProbeOff: nil, ladder: "-1e300"), defaults)
        XCTAssertEqual(TrailerTuning.parse(buffer: -1e300, maxFps: -1e300, letterboxProbeOff: nil, ladder: -1e300), defaults)
    }
}
