import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for `TrackerScrobblePolicy` (`Screens/PlaybackProgressRecorder.swift`) — the pure
/// decisions behind the non-Trakt scrobble fan-out both player engines run next to their Trakt
/// session: which connected providers receive it, and the short-placeholder guard (shared floor
/// 121 s) applied before `start` and at `stop`, matching the Trakt drivers.
final class TrackerScrobblePolicyTests: XCTestCase {

    // MARK: Recipients

    func testTraktIsExcludedBecauseItHasItsOwnDriverPath() {
        XCTAssertFalse(TrackerScrobblePolicy.receivesFanout(storageId: TrackingProviderId.trakt.storageId))
        XCTAssertFalse(TrackerScrobblePolicy.receivesFanout(storageId: "TRAKT"))
    }

    func testSimklAndMdbListReceiveTheFanout() {
        XCTAssertTrue(TrackerScrobblePolicy.receivesFanout(storageId: TrackingProviderId.simkl.storageId))
        XCTAssertTrue(TrackerScrobblePolicy.receivesFanout(storageId: TrackingProviderId.mdblist.storageId))
    }

    func testEveryProviderExceptTraktReceivesTheFanout() {
        let recipients = TrackingProviderId.entries
            .filter { TrackerScrobblePolicy.receivesFanout(storageId: $0.storageId) }
        XCTAssertEqual(recipients.count, TrackingProviderId.entries.count - 1)
        XCTAssertFalse(recipients.contains(TrackingProviderId.trakt))
    }

    // MARK: Short-placeholder guard

    func testShortPlaceholderNeverOpensASession() {
        XCTAssertFalse(TrackerScrobblePolicy.shouldOpen(durationSec: 30))
        XCTAssertFalse(TrackerScrobblePolicy.shouldOpen(durationSec: 120))
    }

    func testRealContentAndUnknownDurationOpen() {
        XCTAssertTrue(TrackerScrobblePolicy.shouldOpen(durationSec: 2700))
        // Unknown (0 / non-finite) duration is not a placeholder — same as the Trakt drivers.
        XCTAssertTrue(TrackerScrobblePolicy.shouldOpen(durationSec: 0))
        XCTAssertTrue(TrackerScrobblePolicy.shouldOpen(durationSec: .nan))
    }

    func testStopOfALateDetectedPlaceholderReportsZero() {
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 29, durationSec: 30), 0)
    }

    func testStopReportsClampedPercentage() {
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 1350, durationSec: 2700), 50, accuracy: 0.001)
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 3000, durationSec: 2700), 100)
        XCTAssertEqual(TrackerScrobblePolicy.percent(positionSec: -5, durationSec: 2700), 0)
        XCTAssertEqual(TrackerScrobblePolicy.percent(positionSec: 10, durationSec: 0), 0)
    }
}
