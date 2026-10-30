import XCTest
@testable import NuvioTV

/// FEAT-87 (GitHub #13): Settings › Detail Page › Trailers › Start Delay.
final class DetailTrailerStartDelayTests: XCTestCase {
    func testStorageKeyAndRawValues() {
        XCTAssertEqual(DetailSettingsKeys.trailerStartDelay, "detail_trailer_start_delay")
        XCTAssertEqual(DetailTrailerStartDelay.allCases.map(\.rawValue), ["default", "3", "5", "10", "15", "30"])
        // Not Home's FEAT-52 key: the two settings never share storage.
        XCTAssertNotEqual(DetailSettingsKeys.trailerStartDelay, TrailerStartDelay.storageKey)
    }

    func testSecondsMapping() {
        XCTAssertNil(DetailTrailerStartDelay.standard.seconds)
        XCTAssertEqual(DetailTrailerStartDelay.allCases.compactMap(\.seconds), [3, 5, 10, 15, 30])
    }

    func testResolveFallsBackToDefault() {
        XCTAssertEqual(DetailTrailerStartDelay.resolve("10"), .tenSeconds)
        XCTAssertEqual(DetailTrailerStartDelay.resolve(""), .standard)
        XCTAssertEqual(DetailTrailerStartDelay.resolve("4"), .standard)
        // erdist's patch stored seconds as an Int, so "0" may exist on a tester's box.
        XCTAssertEqual(DetailTrailerStartDelay.resolve("0"), .standard)
    }

    func testDefaultNeverHoldsTheBackgroundTrailer() {
        for elapsed in [false, true] {
            for returned in [false, true] {
                XCTAssertFalse(DetailTrailerStartDelay.standard.holdsBackground(elapsed: elapsed, returned: returned))
            }
        }
    }

    func testADelayHoldsUntilItElapsesOrThePageIsLeft() {
        let delay = DetailTrailerStartDelay.tenSeconds
        XCTAssertTrue(delay.holdsBackground(elapsed: false, returned: false))
        XCTAssertFalse(delay.holdsBackground(elapsed: true, returned: false))
        // Back from a pushed page before the delay ended: no second wait.
        XCTAssertFalse(delay.holdsBackground(elapsed: false, returned: true))
        XCTAssertFalse(delay.holdsBackground(elapsed: true, returned: true))
    }

    func testAutoPlayWait() {
        XCTAssertEqual(DetailTrailerStartDelay.defaultAutoPlaySeconds, 4)
        XCTAssertEqual(DetailTrailerStartDelay.standard.autoPlaySeconds(returned: false), 4)
        XCTAssertEqual(DetailTrailerStartDelay.threeSeconds.autoPlaySeconds(returned: false), 3)
        XCTAssertEqual(DetailTrailerStartDelay.thirtySeconds.autoPlaySeconds(returned: false), 30)
        // A return uses Default's timing, whatever the setting.
        for delay in DetailTrailerStartDelay.allCases {
            XCTAssertEqual(delay.autoPlaySeconds(returned: true), 4, delay.rawValue)
        }
    }

    func testLabelsAreDistinct() {
        let labels = DetailTrailerStartDelay.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
    }
}
