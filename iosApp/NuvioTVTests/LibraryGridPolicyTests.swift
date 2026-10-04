import XCTest
@testable import NuvioTV

/// Library L1 (2026-10-04): the Library grid's pure rules (smart filters, chip visibility, count
/// line, labels, which screen state shows). The views in `LibraryView.swift` only render these.
final class LibraryGridPolicyTests: XCTestCase {
    private typealias Policy = LibraryGridPolicy
    private typealias State = LibraryGridPolicy.WatchState

    private let watched = State(isWatched: true, progress: nil)
    private let halfway = State(isWatched: false, progress: 0.5)
    private let fresh = State(isWatched: false, progress: nil)

    // MARK: - Progress

    func testVisibleProgressDropsCompletedAndTheEnds() {
        XCTAssertNil(Policy.visibleProgress(fraction: 0.5, isCompleted: true))
        XCTAssertNil(Policy.visibleProgress(fraction: 0.01, isCompleted: false))
        XCTAssertNil(Policy.visibleProgress(fraction: 0.97, isCompleted: false))
        XCTAssertNil(Policy.visibleProgress(fraction: .nan, isCompleted: false))
        XCTAssertEqual(Policy.visibleProgress(fraction: 0.02, isCompleted: false), 0.02)
        XCTAssertEqual(Policy.visibleProgress(fraction: 0.5, isCompleted: false), 0.5)
    }

    func testWatchedTitleIsNeverInProgress() {
        XCTAssertFalse(State(isWatched: true, progress: 0.4).isInProgress)
        XCTAssertTrue(halfway.isInProgress)
        XCTAssertFalse(fresh.isInProgress)
    }

    // MARK: - Smart filters

    func testFiltersCombineWithAnd() {
        XCTAssertTrue(Policy.passes(halfway, filters: [.unwatched, .inProgress]))
        XCTAssertFalse(Policy.passes(fresh, filters: [.unwatched, .inProgress]))
        XCTAssertFalse(Policy.passes(watched, filters: [.unwatched]))
        XCTAssertTrue(Policy.passes(watched, filters: [.watched]))
        XCTAssertTrue(Policy.passes(fresh, filters: []))
    }

    func testTogglingWatchedDropsTheFiltersItCanNeverCombineWith() {
        XCTAssertEqual(Policy.toggling(.watched, in: [.unwatched, .inProgress]), [.watched])
        XCTAssertEqual(Policy.toggling(.unwatched, in: [.watched]), [.unwatched])
        XCTAssertEqual(Policy.toggling(.inProgress, in: [.watched]), [.inProgress])
        XCTAssertEqual(Policy.toggling(.inProgress, in: [.unwatched]), [.unwatched, .inProgress])
    }

    func testTogglingAnActiveFilterTurnsItOff() {
        XCTAssertEqual(Policy.toggling(.unwatched, in: [.unwatched, .inProgress]), [.inProgress])
    }

    func testChipShowsOnlyWhenItWouldSplitTheSet() {
        // Nothing watched and nothing started: every chip would keep all or nothing.
        XCTAssertEqual(Policy.visibleSmartFilters(states: [fresh, fresh], active: []), [])
        // A mix: all three split it, in their fixed order.
        XCTAssertEqual(
            Policy.visibleSmartFilters(states: [fresh, halfway, watched], active: []),
            [.unwatched, .inProgress, .watched]
        )
        // Everything watched: Unwatched and Watched would empty or keep all, In Progress keeps none.
        XCTAssertEqual(Policy.visibleSmartFilters(states: [watched, watched], active: []), [])
    }

    func testActiveChipAlwaysStaysVisibleSoItCanBeTurnedOff() {
        XCTAssertEqual(Policy.visibleSmartFilters(states: [fresh, fresh], active: [.watched]), [.watched])
    }

    // MARK: - Header

    func testCountLineCountsEachKindAndSkipsZeroes() {
        XCTAssertEqual(Policy.countLine(kinds: ["movie", "movie", "series"]), "2 movies \u{00B7} 1 series")
        XCTAssertEqual(Policy.countLine(kinds: ["movie"]), "1 movie")
        XCTAssertEqual(Policy.countLine(kinds: ["tv", "Show", "anime"]), "2 series \u{00B7} 1 anime")
        XCTAssertEqual(Policy.countLine(kinds: ["channel"]), "1 other title")
        XCTAssertEqual(Policy.countLine(kinds: []), "")
    }

    func testTypeLabelsFoldTrackerSpellings() {
        XCTAssertEqual(Policy.typeLabel("movie"), "Movies")
        XCTAssertEqual(Policy.typeLabel("tvshow"), "Series")
        XCTAssertEqual(Policy.typeLabel("anime"), "Anime")
        XCTAssertEqual(Policy.typeLabel("channel"), "Channel")
    }

    // MARK: - Source and sort

    func testProviderNameAndBadgeFromSourceMode() {
        XCTAssertNil(Policy.providerName(sourceModeName: "LOCAL"))
        XCTAssertNil(Policy.sourceBadge(sourceModeName: "LOCAL"))
        XCTAssertEqual(Policy.providerName(sourceModeName: "MDBLIST"), "MDBList")
        XCTAssertEqual(Policy.sourceBadge(sourceModeName: "SIMKL"), "SIMKL")
    }

    func testDefaultSortIsNamedAfterTraktOnlyOnTrakt() {
        XCTAssertEqual(Policy.sortLabel(optionName: "DEFAULT", sourceModeName: "TRAKT"), "Trakt Order")
        XCTAssertEqual(Policy.sortLabel(optionName: "DEFAULT", sourceModeName: "SIMKL"), "List Order")
        XCTAssertEqual(Policy.sortLabel(optionName: "DEFAULT", sourceModeName: "MDBLIST"), "List Order")
        XCTAssertEqual(Policy.sortLabel(optionName: "ADDED_DESC", sourceModeName: "LOCAL"), "Recently Added")
        XCTAssertEqual(Policy.sortLabel(optionName: "TITLE_ASC", sourceModeName: "LOCAL"), "A\u{2013}Z")
    }

    // MARK: - Screen state

    func testLoadingUntilLoadedOrWhileLoadingWithNothingToShow() {
        XCTAssertEqual(content(isLoaded: false), .loading)
        XCTAssertEqual(content(isLoading: true, hasAnySection: false), .loading)
        XCTAssertEqual(content(isLoading: true, hasAnySection: true, visibleCount: 3), .grid)
    }

    func testFailureShowsOnlyWithoutCachedSections() {
        XCTAssertEqual(content(errorMessage: "Trakt is down", hasAnySection: false), .failed(message: "Trakt is down"))
        XCTAssertEqual(content(errorMessage: "Trakt is down", hasAnySection: true, visibleCount: 2), .grid)
        XCTAssertEqual(content(errorMessage: "   ", hasAnySection: false), .empty)
    }

    func testEmptyVersusNoMatches() {
        XCTAssertEqual(content(hasAnySection: false), .empty)
        XCTAssertEqual(content(hasAnySection: true, visibleCount: 0, smartFiltersActive: true), .noMatches)
        XCTAssertEqual(content(hasAnySection: true, visibleCount: 0, smartFiltersActive: false), .empty)
    }

    func testProviderAwareCopy() {
        XCTAssertEqual(Policy.emptyTitle(providerName: nil), "Your library is empty")
        XCTAssertEqual(Policy.emptyTitle(providerName: "Simkl"), "Your Simkl library is empty")
        XCTAssertEqual(Policy.failedTitle(providerName: "Trakt"), "Couldn\u{2019}t load your Trakt library")
        XCTAssertEqual(Policy.emptyMessage(providerName: "Simkl"), "Titles you save on Simkl show up here.")
    }

    func testRemoveLabelNamesTheOpenList() {
        XCTAssertEqual(Policy.removeLabel(listTitle: nil), "Remove from Library")
        XCTAssertEqual(Policy.removeLabel(listTitle: ""), "Remove from Library")
        XCTAssertEqual(Policy.removeLabel(listTitle: "Watchlist"), "Remove from Watchlist")
    }

    // MARK: - Helpers

    private func content(
        isLoaded: Bool = true,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        hasAnySection: Bool = true,
        visibleCount: Int = 0,
        smartFiltersActive: Bool = false
    ) -> LibraryGridPolicy.Content {
        LibraryGridPolicy.content(
            isLoaded: isLoaded,
            isLoading: isLoading,
            errorMessage: errorMessage,
            hasAnySection: hasAnySection,
            visibleCount: visibleCount,
            smartFiltersActive: smartFiltersActive
        )
    }
}
