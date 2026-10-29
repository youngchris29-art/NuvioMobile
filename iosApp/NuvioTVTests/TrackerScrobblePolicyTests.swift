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
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 29, durationSec: 30, isLive: false), 0)
    }

    func testStopReportsClampedPercentage() {
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 1350, durationSec: 2700, isLive: false), 50, accuracy: 0.001)
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 3000, durationSec: 2700, isLive: false), 100)
        XCTAssertEqual(TrackerScrobblePolicy.percent(positionSec: -5, durationSec: 2700), 0)
        XCTAssertEqual(TrackerScrobblePolicy.percent(positionSec: 10, durationSec: 0), 0)
    }

    /// Both engines close Trakt (`PlaybackProgressRecorder.stopTrakt`, mpv's `stopTraktScrobble`)
    /// and the Simkl / MDBList fan-out through `stopPercent`. A live stream near the live edge reads
    /// ~100 % of what is loaded: it must close at 0 so no tracker marks it watched.
    func testStopOfALiveStreamReportsZero() {
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 3_590, durationSec: 3_600, isLive: true), 0)
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 600, durationSec: 3_600, isLive: true), 0)
        XCTAssertEqual(TrackerScrobblePolicy.stopPercent(positionSec: 3_590, durationSec: 3_600, isLive: false), 99.72,
                       accuracy: 0.01, "the same position on a VOD still closes at its percentage")
    }
}
