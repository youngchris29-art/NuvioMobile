import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (B2, BUG-131): how the inline card maps a `TrailerPlaybackURLOutcome` to an
/// action. The rule that matters: a timeout is a TRANSIENT, never "unavailable" and never "this
/// candidate is dead" (which would walk on to the next one).
final class InlineTrailerResolveOutcomeTests: XCTestCase {

    func testOutcomeMapping() {
        XCTAssertEqual(InlineTrailerResolveOutcome.action(for: .playable("http://127.0.0.1:8230/t/master.m3u8")),
                       .storeResolvedAndPlay)
        XCTAssertEqual(InlineTrailerResolveOutcome.action(for: .timedOut(progressive: "p")), .playUncached)
        XCTAssertEqual(InlineTrailerResolveOutcome.action(for: .timedOut(progressive: nil)), .storeTransient)
        XCTAssertEqual(InlineTrailerResolveOutcome.action(for: .nothingPlayable), .tryNextCandidate)
    }

    func testEmptyURLsCountAsAbsent() {
        // The old `!playable.isEmpty` checks, kept: an empty playable falls through to the next
        // candidate, an empty progressive on a timeout is a transient with nothing to play.
        XCTAssertEqual(InlineTrailerResolveOutcome.action(for: .playable("")), .tryNextCandidate)
        XCTAssertEqual(InlineTrailerResolveOutcome.action(for: .timedOut(progressive: "")), .storeTransient)
    }

    func testPlaybackURLFollowsTheAction() {
        XCTAssertEqual(InlineTrailerResolveOutcome.playbackURL(for: .playable("u")), "u")
        XCTAssertEqual(InlineTrailerResolveOutcome.playbackURL(for: .timedOut(progressive: "p")), "p")
        XCTAssertNil(InlineTrailerResolveOutcome.playbackURL(for: .timedOut(progressive: nil)))
        XCTAssertNil(InlineTrailerResolveOutcome.playbackURL(for: .timedOut(progressive: "")))
        XCTAssertNil(InlineTrailerResolveOutcome.playbackURL(for: .nothingPlayable))
        XCTAssertNil(InlineTrailerResolveOutcome.playbackURL(for: .playable("")))
    }

    // MARK: Cache-hit listener plan (review r1, A-5)

    /// Only a missing token re-resolves. A listener that is not up within the waits keeps the cached
    /// resolution (no YouTube re-extraction for a slow start); a ready port serves.
    func testCacheHitPlanInvalidatesOnlyWhenTheTokenIsGone() {
        XCTAssertEqual(InlineTrailerCacheHitPlan.action(tokenStored: false, readyPort: nil), .reresolve)
        XCTAssertEqual(InlineTrailerCacheHitPlan.action(tokenStored: false, readyPort: 8230), .reresolve)
        XCTAssertEqual(InlineTrailerCacheHitPlan.action(tokenStored: true, readyPort: nil), .waitForListener)
        XCTAssertEqual(InlineTrailerCacheHitPlan.action(tokenStored: true, readyPort: 8231), .serve(port: 8231))
    }

    /// One retry, not a loop: each wait is bounded by the listener's own attempt deadline, so the
    /// whole cache-hit hop stays bounded too. (`.serve`'s rebase onto a moved port is pinned by
    /// `TrailerLocalHLSListenerTests`' `servableURL` cases.)
    func testCacheHitPlanRetriesTheListenerOnce() {
        XCTAssertEqual(InlineTrailerCacheHitPlan.listenerWaits, 2)
    }

    func testATimeoutNeverMapsToTheNextCandidate() {
        // A slow repack says nothing about the candidate: walking on would burn the three-candidate
        // budget on a title whose first trailer is fine.
        for progressive in [nil, "", "p"] as [String?] {
            XCTAssertNotEqual(InlineTrailerResolveOutcome.action(for: .timedOut(progressive: progressive)),
                              .tryNextCandidate)
        }
    }
}
