import Combine
import XCTest
@testable import NuvioTV

/// Home Stage & Strip (P1 §3.5, §9.3): the strip's page signal. `restPending` holds from
/// `pageStarted` until the LATEST generation's completion; a stale completion is ignored; a page whose
/// completion never arrives is ended by the fallback at duration + 0.5 s.
@MainActor
final class StripMotionSignalTests: XCTestCase {

    override func tearDown() async throws {
        // `pageStarted` stamps the shared rows motion clock.
        RowsMotionClock.resetForTesting()
    }

    private func makeSignal(_ clock: StageFakeClock) -> StripMotionSignal {
        let signal = StripMotionSignal(schedule: { after, work in clock.schedule(after, work) })
        signal.now = { clock.now }
        return signal
    }

    func testRestPendingUntilTheLatestGenerationEnds() {
        let clock = StageFakeClock()
        let signal = makeSignal(clock)
        XCTAssertFalse(signal.restPending)

        let first = signal.pageStarted(duration: 0.5)
        XCTAssertTrue(signal.restPending)
        clock.advance(0.3)
        let second = signal.pageStarted(duration: 0.5)
        XCTAssertNotEqual(first, second)

        signal.pageEnded(generation: first)
        XCTAssertTrue(signal.restPending, "a stale generation's completion is ignored")

        clock.advance(0.5)
        signal.pageEnded(generation: second)
        XCTAssertFalse(signal.restPending)
        XCTAssertFalse(signal.lastEndedByTimeout)
        XCTAssertEqual(signal.lastPageEndedAt ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(clock.pendingCount, 0, "the fallback is cancelled by the completion")
    }

    func testFallbackEndsAPageWithNoCompletion() {
        let clock = StageFakeClock()
        let signal = makeSignal(clock)
        signal.pageStarted(duration: 0.5)
        clock.advance(0.99)
        XCTAssertTrue(signal.restPending)
        clock.advance(0.01)
        XCTAssertFalse(signal.restPending, "ended at duration + 0.5 s")
        XCTAssertTrue(signal.lastEndedByTimeout)
        XCTAssertEqual(signal.lastPageEndedAt ?? -1, 1.0, accuracy: 1e-9)
    }

    /// A newer page restarts the fallback: the older generation's fallback never ends the newer page.
    func testANewPageReplacesTheFallback() {
        let clock = StageFakeClock()
        let signal = makeSignal(clock)
        signal.pageStarted(duration: 0.5)
        clock.advance(0.9)
        signal.pageStarted(duration: 0.5)
        clock.advance(0.2)   // 1.1: past the first page's fallback
        XCTAssertTrue(signal.restPending)
        XCTAssertEqual(clock.pendingCount, 1, "one fallback outstanding")
        clock.advance(0.8)   // 1.9: the second page's fallback (0.9 + 1.0)
        XCTAssertFalse(signal.restPending)
        XCTAssertTrue(signal.lastEndedByTimeout)
    }

    func testCallbacksAndMotionStamp() {
        let clock = StageFakeClock()
        let signal = makeSignal(clock)
        var started = 0
        var endedByTimeout: [Bool] = []
        signal.onPageStarted = { started += 1 }
        signal.onPageEnded = { endedByTimeout.append($0) }

        let generation = signal.pageStarted(duration: 0.5)
        XCTAssertEqual(started, 1)
        XCTAssertLessThan(signal.secondsSinceMotion, 1, "a page start stamps the rows motion clock")
        signal.pageEnded(generation: generation)
        signal.pageEnded(generation: generation)
        XCTAssertEqual(endedByTimeout, [false], "a completion ends a page once")

        signal.pageStarted(duration: 0)
        clock.advance(0.5)
        XCTAssertEqual(endedByTimeout, [false, true])
    }
}
