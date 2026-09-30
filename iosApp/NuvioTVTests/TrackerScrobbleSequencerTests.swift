import XCTest
@testable import NuvioTV

/// Unit tests for `TrackerScrobbleSequencer` (`Screens/PlaybackProgressRecorder.swift`): a tracker
/// `stop` must never be dispatched before the `start` dispatch has completed.
final class TrackerScrobbleSequencerTests: XCTestCase {

    func testStopAfterStartCompletedDispatchesImmediately() {
        var s = TrackerScrobbleSequencer()
        XCTAssertTrue(s.start())
        XCTAssertNil(s.startCompleted())
        XCTAssertEqual(s.stop(percent: 42), 42)
    }

    func testStopDuringInFlightStartIsDeferredAndReleasedByCompletion() {
        var s = TrackerScrobbleSequencer()
        XCTAssertTrue(s.start())
        XCTAssertNil(s.stop(percent: 7))
        XCTAssertEqual(s.startCompleted(), 7)
        XCTAssertNil(s.startCompleted(), "the deferred stop is released once")
    }

    func testSecondStopAfterClosedIsIgnored() {
        var s = TrackerScrobbleSequencer()
        XCTAssertTrue(s.start())
        XCTAssertNil(s.startCompleted())
        XCTAssertEqual(s.stop(percent: 50), 50)
        XCTAssertNil(s.stop(percent: 60))
    }

    func testSecondStopWhileDeferredKeepsFirstPercent() {
        var s = TrackerScrobbleSequencer()
        XCTAssertTrue(s.start())
        XCTAssertNil(s.stop(percent: 10))
        XCTAssertNil(s.stop(percent: 90))
        XCTAssertEqual(s.startCompleted(), 10)
    }

    func testStopBeforeAnyStartDispatchesNothing() {
        var s = TrackerScrobbleSequencer()
        XCTAssertNil(s.stop(percent: 30))
    }

    func testStartAfterStopIsRefused() {
        var s = TrackerScrobbleSequencer()
        XCTAssertNil(s.stop(percent: 30))
        XCTAssertFalse(s.start())
    }

    func testSecondStartIsRefused() {
        var s = TrackerScrobbleSequencer()
        XCTAssertTrue(s.start())
        XCTAssertFalse(s.start())
    }
}
