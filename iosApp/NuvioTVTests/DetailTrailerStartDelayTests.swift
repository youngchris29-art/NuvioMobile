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

    func testAutoPlayWaitWithTheBackgroundTrailerOff() {
        XCTAssertEqual(DetailTrailerStartDelay.defaultAutoPlaySeconds, 4)
        // Counted from the URL resolving, whenever that is.
        for sinceOpen: TimeInterval in [0, 2, 40] {
            XCTAssertEqual(DetailTrailerStartDelay.standard.autoPlaySeconds(returned: false, backgroundEnabled: false, sinceOpen: sinceOpen), 4)
            XCTAssertEqual(DetailTrailerStartDelay.threeSeconds.autoPlaySeconds(returned: false, backgroundEnabled: false, sinceOpen: sinceOpen), 3)
            XCTAssertEqual(DetailTrailerStartDelay.thirtySeconds.autoPlaySeconds(returned: false, backgroundEnabled: false, sinceOpen: sinceOpen), 30)
        }
    }

    /// Review r1 #2: with the background trailer on, auto-play is 4 s after the background trailer
    /// could first appear, from the same origin (page open): `max(delay, sinceOpen) + 4`. A cached
    /// URL (sinceOpen ≈ 0) no longer lands both trailers on the same deadline.
    func testAutoPlayDeadlineComposesWithTheBackgroundClock() {
        let cases: [(DetailTrailerStartDelay, TimeInterval, TimeInterval)] = [
            // (delay, URL resolved at, auto-play deadline from page open)
            (.standard, 0, 4),
            (.standard, 2, 6),
            (.threeSeconds, 0, 7),
            (.tenSeconds, 0, 14),
            (.tenSeconds, 2.5, 14),
            (.tenSeconds, 12, 16),  // resolved after the hold ended: 4 s after it appears
            (.thirtySeconds, 1, 34),
        ]
        for (delay, resolvedAt, deadline) in cases {
            let wait = delay.autoPlaySeconds(returned: false, backgroundEnabled: true, sinceOpen: resolvedAt)
            XCTAssertEqual(resolvedAt + wait, deadline, accuracy: 0.0001, "\(delay.rawValue) resolved at \(resolvedAt)")
            // Never on the background release: at least Default's 4 s after it.
            XCTAssertGreaterThanOrEqual(resolvedAt + wait, max(delay.seconds ?? 0, resolvedAt) + 4 - 0.0001)
        }
    }

    func testAReturnUsesDefaultTiming() {
        for delay in DetailTrailerStartDelay.allCases {
            for background in [false, true] {
                XCTAssertEqual(delay.autoPlaySeconds(returned: true, backgroundEnabled: background, sinceOpen: 0), 4, delay.rawValue)
            }
        }
    }

    func testLabelsAreDistinct() {
        let labels = DetailTrailerStartDelay.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
    }
}
