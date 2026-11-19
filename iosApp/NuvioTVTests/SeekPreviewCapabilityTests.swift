import XCTest
@testable import NuvioTV

/// GitHub #33 (design review finding 7): one owner of the mpv harvest interval, then the
/// capability builders for both engines.
final class SeekPreviewCapabilityTests: XCTestCase {
    typealias Cap = SeekPreviewCapability
    typealias R = SeekPreviewHarvestResolution

    /// setting {0, 10} × sentinel × synthetic × simulator: 16 cases.
    func testHarvestResolutionMatrix() {
        var cases = 0
        for setting in [0.0, 10.0] {
            for sentinel in [false, true] {
                for synthetic in [false, true] {
                    for simulator in [false, true] {
                        cases += 1
                        let got = R.effectiveIntervalSec(setting: setting, sentinelDisabled: sentinel,
                                                         synthetic: synthetic, isSimulator: simulator)
                        let expected: Double
                        if synthetic { expected = setting }             // bypasses sentinel and simulator
                        else if sentinel || simulator { expected = 0 }
                        else { expected = setting }
                        XCTAssertEqual(got, expected,
                                       "setting=\(setting) sentinel=\(sentinel) synthetic=\(synthetic) sim=\(simulator)")
                    }
                }
            }
        }
        XCTAssertEqual(cases, 16)
    }

    func testHarvestResolutionSpotChecks() {
        XCTAssertEqual(R.effectiveIntervalSec(setting: 10, sentinelDisabled: false, synthetic: false, isSimulator: false), 10)
        XCTAssertEqual(R.effectiveIntervalSec(setting: 10, sentinelDisabled: true, synthetic: false, isSimulator: false), 0)
        XCTAssertEqual(R.effectiveIntervalSec(setting: 10, sentinelDisabled: false, synthetic: false, isSimulator: true), 0)
        XCTAssertEqual(R.effectiveIntervalSec(setting: 10, sentinelDisabled: true, synthetic: true, isSimulator: true), 10)
    }

    /// mode {off, harvest, decode} × interval {0, 10}.
    func testMpvBuilder() {
        XCTAssertEqual(Cap.mpv(mode: .off, effectiveHarvestIntervalSec: 0), .none)
        XCTAssertEqual(Cap.mpv(mode: .off, effectiveHarvestIntervalSec: 10), .none, "Off wins over a (synthetic) harvest")
        XCTAssertEqual(Cap.mpv(mode: .harvest, effectiveHarvestIntervalSec: 0), .none)
        XCTAssertEqual(Cap.mpv(mode: .harvest, effectiveHarvestIntervalSec: 10),
                       Cap(fillsWatched: true, fillsUnwatched: false))
        XCTAssertEqual(Cap.mpv(mode: .decode, effectiveHarvestIntervalSec: 0),
                       Cap(fillsWatched: false, fillsUnwatched: true), "a crash or the simulator leaves decode on")
        XCTAssertEqual(Cap.mpv(mode: .decode, effectiveHarvestIntervalSec: 10),
                       Cap(fillsWatched: true, fillsUnwatched: true))
    }

    /// The end-to-end Off rule: synthetic harvest on the simulator still gives `.none` in Off mode.
    func testOffSuppressesSyntheticHarvest() {
        let interval = R.effectiveIntervalSec(setting: 10, sentinelDisabled: false, synthetic: true, isSimulator: true)
        XCTAssertEqual(interval, 10)
        XCTAssertEqual(Cap.mpv(mode: .off, effectiveHarvestIntervalSec: interval), .none)
        XCTAssertTrue(Cap.mpv(mode: .harvest, effectiveHarvestIntervalSec: interval).fillsWatched)
    }

    /// mode × supportsStills.
    func testAetherBuilder() {
        XCTAssertEqual(Cap.aether(mode: .off, supportsStills: false), .none)
        XCTAssertEqual(Cap.aether(mode: .off, supportsStills: true), .none, "Off is honoured on Aether")
        XCTAssertEqual(Cap.aether(mode: .harvest, supportsStills: false), .none)
        XCTAssertEqual(Cap.aether(mode: .harvest, supportsStills: true), Cap(fillsWatched: true, fillsUnwatched: true))
        XCTAssertEqual(Cap.aether(mode: .decode, supportsStills: false), .none)
        XCTAssertEqual(Cap.aether(mode: .decode, supportsStills: true), Cap(fillsWatched: true, fillsUnwatched: true))
    }

    func testAny() {
        XCTAssertFalse(Cap.none.any)
        XCTAssertTrue(Cap(fillsWatched: true, fillsUnwatched: false).any)
        XCTAssertTrue(Cap(fillsWatched: false, fillsUnwatched: true).any)
    }
}
