import XCTest
@testable import NuvioTV

/// Unit tests for `Screens/Player/LiveReconnectPolicy.swift` (GitHub #26): which end-of-file is a
/// live stream's, the reconnect cap, and the sliding window.
final class LiveReconnectPolicyTests: XCTestCase {
    typealias Policy = LiveReconnectPolicy

    /// Default: an HLS channel whose duration latched as growing.
    private func inputs(reportsLive: Bool = false, latched: Bool = true, undecided: Bool = false,
                        settled: Bool = false, adaptive: Bool = true, durationKnown: Bool = true,
                        film: Bool = false, loaded: Bool = true, closing: Bool = false, played: Double? = nil) -> Policy.Inputs {
        // By default every decision comes after a long healthy stretch, so only the time window
        // is under test; the streak cases pass `played` themselves.
        defaultPlayed += 1_000
        return Policy.Inputs(reportsLive: reportsLive, growthLatched: latched, growthUndecided: undecided,
                             growthSettled: settled, adaptiveFormat: adaptive, durationKnown: durationKnown,
                             filmOrEpisode: film, fileLoaded: loaded, closingOrSwapping: closing, secondsPlayed: played ?? defaultPlayed)
    }

    private var defaultPlayed: Double = 0

    func testAFilmEndsAsAFilm() {
        var policy = Policy()
        // An HLS film: seekable, a fixed duration, quiet since it loaded.
        XCTAssertEqual(policy.decide(inputs(latched: false, settled: true), nowSec: 100), .notEligible)
        // An MKV or MP4 film.
        XCTAssertEqual(policy.decide(inputs(latched: false, settled: true, adaptive: false), nowSec: 100), .notEligible)
        XCTAssertTrue(policy.recent.isEmpty, "a film's end must not count against the window")
    }

    func testANonSeekableFilmIsNeverReopened() {
        // Review r1 P2-1: a film served without byte ranges reads `seekable` false. Reopening it
        // would play it again from the start, for ever.
        var policy = Policy()
        XCTAssertEqual(policy.decide(inputs(reportsLive: true, latched: false, settled: true, adaptive: false),
                                     nowSec: 100), .notEligible, "MKV / MP4 / TS film with a duration")
        XCTAssertEqual(policy.decide(inputs(reportsLive: true, latched: false, settled: true, adaptive: true),
                                     nowSec: 100), .notEligible, "an HLS film whose duration never grew")
        // Even one whose duration looked like growth: only HLS and DASH can be live with a duration.
        XCTAssertEqual(policy.decide(inputs(reportsLive: true, latched: true, adaptive: false), nowSec: 100),
                       .notEligible)
        // Review r2 F1: a media server's progressive .ts transcode of a film has no duration either.
        XCTAssertEqual(policy.decide(inputs(reportsLive: true, latched: false, adaptive: false, durationKnown: false,
                                            film: true), nowSec: 100), .notEligible)
        XCTAssertTrue(policy.recent.isEmpty)
    }

    func testALiveStreamReconnects() {
        var policy = Policy()
        XCTAssertEqual(policy.decide(inputs(), nowSec: 100), .reconnect(attempt: 1), "HLS, growth latched")
        // A raw live transport stream: non-seekable and no duration at all.
        XCTAssertEqual(policy.decide(inputs(reportsLive: true, latched: false, adaptive: false, durationKnown: false),
                                     nowSec: 101), .reconnect(attempt: 2))
        // An HLS channel mpv reports non-seekable, dropped before growth could latch or settle.
        XCTAssertEqual(policy.decide(inputs(reportsLive: true, latched: false), nowSec: 102), .reconnect(attempt: 3))
    }

    func testAnUndecidedStreamReconnectsOnlyWhenAdaptive() {
        var policy = Policy()
        XCTAssertEqual(policy.decide(inputs(latched: false, undecided: true, adaptive: true), nowSec: 10),
                       .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(latched: false, undecided: true, adaptive: false), nowSec: 11),
                       .notEligible, "an MKV whose duration mpv is still refining is a film")
    }

    func testNothingBeforeTheFirstLoadOrWhileLeaving() {
        var policy = Policy()
        XCTAssertEqual(policy.decide(inputs(loaded: false), nowSec: 1), .notEligible)
        XCTAssertEqual(policy.decide(inputs(closing: true), nowSec: 2), .notEligible)
        XCTAssertTrue(policy.recent.isEmpty)
    }

    func testTheCapEndsADeadChannel() {
        var policy = Policy()
        for attempt in 1...Policy.limit {
            XCTAssertEqual(policy.decide(inputs(), nowSec: Double(attempt)), .reconnect(attempt: attempt))
        }
        XCTAssertEqual(policy.decide(inputs(), nowSec: 10), .capReached(reconnects: Policy.limit))
        XCTAssertEqual(policy.decide(inputs(), nowSec: 11), .capReached(reconnects: Policy.limit))
        XCTAssertEqual(policy.recent.count, Policy.limit, "a refused end-of-file is not recorded")
    }

    func testTheWindowSlides() {
        var policy = Policy()
        for attempt in 1...Policy.limit {
            XCTAssertEqual(policy.decide(inputs(), nowSec: Double(attempt) * 10), .reconnect(attempt: attempt))
        }
        // The first reconnect (t = 10) leaves the window just after t = 130.
        XCTAssertEqual(policy.decide(inputs(), nowSec: 130), .capReached(reconnects: Policy.limit))
        XCTAssertEqual(policy.decide(inputs(), nowSec: 130.5), .reconnect(attempt: Policy.limit))
        // Long quiet: everything has left the window.
        XCTAssertEqual(policy.decide(inputs(), nowSec: 1_000), .reconnect(attempt: 1))
    }

    func testAChannelThatOnlyReplaysItsLastSecondsEnds() {
        // Off air but still serving its last playlist: every reopen plays a few seconds, then the
        // demuxer takes two minutes to give up again. The time window never fills.
        var policy = Policy()
        XCTAssertEqual(policy.decide(inputs(played: 600), nowSec: 0), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(played: 606), nowSec: 130), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(played: 612), nowSec: 260), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(played: 618), nowSec: 390), .capReached(reconnects: Policy.unproductiveLimit))
        XCTAssertEqual(policy.decide(inputs(played: 618), nowSec: 400), .capReached(reconnects: Policy.unproductiveLimit + 1))
    }

    func testAChannelThatComesBackClearsTheStreak() {
        var policy = Policy()
        XCTAssertEqual(policy.decide(inputs(played: 600), nowSec: 0), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(played: 605), nowSec: 130), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(played: 610), nowSec: 260), .reconnect(attempt: 1))
        XCTAssertEqual(policy.unproductiveStreak, 2)
        // The third reopen brought the channel back for ten minutes.
        XCTAssertEqual(policy.decide(inputs(played: 1_210), nowSec: 990), .reconnect(attempt: 1))
        XCTAssertEqual(policy.unproductiveStreak, 0)
        XCTAssertEqual(policy.decide(inputs(played: 1_215), nowSec: 1_120), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(played: 1_240), nowSec: 1_250), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(played: 1_245), nowSec: 1_380), .capReached(reconnects: Policy.unproductiveLimit))
    }

    func testExactlyTheProductiveSecondsCountAsBack() {
        var policy = Policy()
        XCTAssertEqual(policy.decide(inputs(played: 100), nowSec: 0), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(played: 100 + Policy.productiveSec), nowSec: 200), .reconnect(attempt: 1))
        XCTAssertEqual(policy.unproductiveStreak, 0)
        XCTAssertEqual(policy.decide(inputs(played: 100 + 2 * Policy.productiveSec - 0.5), nowSec: 400), .reconnect(attempt: 1))
        XCTAssertEqual(policy.unproductiveStreak, 1)
    }

    func testAClockThatWentBackwardsDropsTheFutureEntries() {
        var policy = Policy()
        XCTAssertEqual(policy.decide(inputs(), nowSec: 500), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(), nowSec: 100), .reconnect(attempt: 1))
        XCTAssertEqual(policy.decide(inputs(), nowSec: .nan), .notEligible)
    }
}
