import XCTest
@testable import NuvioTV

/// A3.2 (C1): the Apple-style text season tabs (order, labels) and the viewed-season browse state
/// (debounce tickets, stale-switch cancel, per-season remembered episode).
final class EpisodeSeasonTabsTests: XCTestCase {

    // MARK: - Tabs

    func testSpecialsSortLast() {
        let tabs = EpisodeSeasonTabs.tabs(for: [0, 3, 1, 2])
        XCTAssertEqual(tabs.map(\.season), [1, 2, 3, 0])
        XCTAssertEqual(tabs.map(\.label), ["Season 1", "Season 2", "Season 3", "Specials"])
    }

    func testNegativeSeasonNormalizesToSpecialsOnce() {
        XCTAssertEqual(EpisodeSeasonTabs.tabs(for: [-1, 0, 2]).map(\.season), [2, 0])
    }

    func testDuplicatesCollapse() {
        XCTAssertEqual(EpisodeSeasonTabs.tabs(for: [2, 1, 2, 1]).map(\.season), [1, 2])
    }

    func testIdentifiersFollowSeasonPosterPattern() {
        XCTAssertEqual(EpisodeSeasonTabs.tabs(for: [1, 0]).map(\.accessibilityIdentifier),
                       ["season_tab_1", "season_tab_0"])
    }

    /// The season hold menu's "Mark Season N Watched" reads the same label as the tab.
    func testLabelMatchesSectionLabel() {
        XCTAssertEqual(EpisodeSeasonTabs.label(4), "Season 4")
        XCTAssertEqual(EpisodeSeasonTabs.label(0), "Specials")
    }

    func testSortKeyMatchesSection() {
        for season in [-2, 0, 1, 7] {
            XCTAssertEqual(EpisodeSeasonTabs.sortKey(season), EpisodesSection.seasonSortKey(season))
        }
    }

    // MARK: - Debounce / cancel

    func testFocusOnViewedSeasonSchedulesNothing() {
        var browse = SeasonTabBrowse()
        XCTAssertNil(browse.focus(on: 1, viewed: 1))
        XCTAssertNil(browse.pending)
    }

    func testFocusThenSettleSwitches() {
        var browse = SeasonTabBrowse()
        let ticket = browse.focus(on: 2, viewed: 1)
        XCTAssertNotNil(ticket)
        XCTAssertEqual(browse.settle(ticket: ticket!), 2)
        XCTAssertNil(browse.pending)
        // A second settle of the same ticket does nothing.
        XCTAssertNil(browse.settle(ticket: ticket!))
    }

    /// Sweeping 1 → 2 → 3: only the last tab's debounce switches the shelf.
    func testNewerFocusMakesOlderTicketStale() {
        var browse = SeasonTabBrowse()
        let t2 = browse.focus(on: 2, viewed: 1)!
        let t3 = browse.focus(on: 3, viewed: 1)!
        XCTAssertNil(browse.settle(ticket: t2))
        XCTAssertEqual(browse.settle(ticket: t3), 3)
    }

    /// Sweeping away and back to the viewed season before the debounce: nothing switches.
    func testReturningToViewedSeasonCancelsPending() {
        var browse = SeasonTabBrowse()
        let t2 = browse.focus(on: 2, viewed: 1)!
        XCTAssertNil(browse.focus(on: 1, viewed: 1))
        XCTAssertNil(browse.settle(ticket: t2))
    }

    /// Leaving the tab row before the debounce: the shelf on screen stays.
    func testCancelDropsPending() {
        var browse = SeasonTabBrowse()
        let t2 = browse.focus(on: 2, viewed: 1)!
        browse.cancel()
        XCTAssertNil(browse.pending)
        XCTAssertNil(browse.settle(ticket: t2))
    }

    /// Select before the debounce: switch now, and the sleeping ticket must not switch again.
    func testFlushReturnsPendingAndStalesTicket() {
        var browse = SeasonTabBrowse()
        let t2 = browse.focus(on: 2, viewed: 1)!
        XCTAssertEqual(browse.flush(), 2)
        XCTAssertNil(browse.settle(ticket: t2))
        XCTAssertNil(browse.flush())
    }

    func testDebounceIsInTheAgreedWindow() {
        XCTAssertGreaterThanOrEqual(SeasonTabBrowse.debounce, .milliseconds(150))
        XCTAssertLessThanOrEqual(SeasonTabBrowse.debounce, .milliseconds(250))
    }

    // MARK: - Per-season entry (next-up on first entry, remembered after)

    func testFirstEntryIsNextUp() {
        let browse = SeasonTabBrowse()
        XCTAssertEqual(browse.entryEpisode(season: 2, nextUpId: "s2e4", isListed: { _ in true }), "s2e4")
        XCTAssertFalse(browse.hasRemembered(season: 2))
    }

    func testRevisitIsRemembered() {
        var browse = SeasonTabBrowse()
        browse.remember(episodeId: "s1e7", season: 1)
        browse.remember(episodeId: "s2e2", season: 2)
        XCTAssertEqual(browse.entryEpisode(season: 1, nextUpId: "s1e3", isListed: { _ in true }), "s1e7")
        XCTAssertEqual(browse.entryEpisode(season: 2, nextUpId: "s2e1", isListed: { _ in true }), "s2e2")
        XCTAssertTrue(browse.hasRemembered(season: 1))
    }

    func testRememberedCardNoLongerListedFallsBackToNextUp() {
        var browse = SeasonTabBrowse()
        browse.remember(episodeId: "gone", season: 1)
        XCTAssertEqual(browse.entryEpisode(season: 1, nextUpId: "s1e3", isListed: { $0 != "gone" }), "s1e3")
    }

    func testNilSeasonIsNextUp() {
        var browse = SeasonTabBrowse()
        browse.remember(episodeId: "x", season: 1)
        XCTAssertEqual(browse.entryEpisode(season: nil, nextUpId: "n", isListed: { _ in true }), "n")
        XCTAssertFalse(browse.hasRemembered(season: nil))
    }

    /// Browsing tabs never touches the remembered episodes.
    func testTabFocusKeepsMemory() {
        var browse = SeasonTabBrowse()
        browse.remember(episodeId: "s1e5", season: 1)
        let t = browse.focus(on: 2, viewed: 1)!
        _ = browse.settle(ticket: t)
        _ = browse.focus(on: 1, viewed: 2)
        browse.cancel()
        XCTAssertEqual(browse.remembered, [1: "s1e5"])
    }
}
