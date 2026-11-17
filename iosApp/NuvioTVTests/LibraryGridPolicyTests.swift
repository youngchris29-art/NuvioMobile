import XCTest
import SharedCore
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
        XCTAssertNil(Policy.visibleProgress(fraction: 0, isCompleted: false))
        XCTAssertNil(Policy.visibleProgress(fraction: 0.97, isCompleted: false))
        XCTAssertNil(Policy.visibleProgress(fraction: .nan, isCompleted: false))
        XCTAssertEqual(Policy.visibleProgress(fraction: 0.01, isCompleted: false), 0.01)
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

    func testProviderControlsShowForProviderLibrariesOnly() {
        for provider in ["TRAKT", "SIMKL", "MDBLIST", "mdblist"] {
            XCTAssertTrue(Policy.showsProviderControls(sourceModeName: provider), provider)
        }
        XCTAssertFalse(Policy.showsProviderControls(sourceModeName: "LOCAL"))
        XCTAssertFalse(Policy.showsProviderControls(sourceModeName: ""))
    }

    func testDefaultSortIsNamedAfterTraktOnlyOnTrakt() {
        XCTAssertEqual(Policy.sortLabel(optionName: "DEFAULT", sourceModeName: "TRAKT"), "Trakt Order")
        XCTAssertEqual(Policy.sortLabel(optionName: "DEFAULT", sourceModeName: "SIMKL"), "List Order")
        XCTAssertEqual(Policy.sortLabel(optionName: "DEFAULT", sourceModeName: "MDBLIST"), "List Order")
        XCTAssertEqual(Policy.sortLabel(optionName: "ADDED_DESC", sourceModeName: "LOCAL"), "Recently Added")
        XCTAssertEqual(Policy.sortLabel(optionName: "TITLE_ASC", sourceModeName: "LOCAL"), "A\u{2013}Z")
    }

    func testReleaseDateSortsHaveLabels() {
        // Batch D U1 (upstream d8ce7258): the shared `LibrarySortOption.RELEASED_DESC` / `RELEASED_ASC`,
        // offered for MDBList lists. Without a case here the pill would print the raw enum name.
        XCTAssertEqual(Policy.sortLabel(optionName: "RELEASED_DESC", sourceModeName: "MDBLIST"), "Recently Released")
        XCTAssertEqual(Policy.sortLabel(optionName: "RELEASED_ASC", sourceModeName: "MDBLIST"), "Oldest Released")
        XCTAssertEqual(Policy.sortLabel(optionName: LibrarySortOption.releasedDesc.name, sourceModeName: "MDBLIST"),
                       "Recently Released", "the Swift label switch keys on the Kotlin entry name")
        XCTAssertEqual(Policy.sortLabel(optionName: LibrarySortOption.releasedAsc.name, sourceModeName: "MDBLIST"),
                       "Oldest Released")
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
        XCTAssertEqual(content(hasAnySection: true, visibleCount: 0, filtersActive: true), .noMatches)
        XCTAssertEqual(content(hasAnySection: true, visibleCount: 0, filtersActive: false), .empty)
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
        filtersActive: Bool = false
    ) -> LibraryGridPolicy.Content {
        LibraryGridPolicy.content(
            isLoaded: isLoaded,
            isLoading: isLoading,
            errorMessage: errorMessage,
            hasAnySection: hasAnySection,
            visibleCount: visibleCount,
            filtersActive: filtersActive
        )
    }

    // MARK: - Remove confirmation and failure

    func testRemoveConfirmationNamesTheList() {
        XCTAssertEqual(Policy.removeConfirmationTitle(listTitle: "Completed"), "Remove from Completed?")
        XCTAssertEqual(Policy.removeConfirmationTitle(listTitle: "  "), "Remove from Library?")
        XCTAssertEqual(Policy.removeConfirmationTitle(listTitle: nil), "Remove from Library?")
        XCTAssertTrue(Policy.removeConfirmationMessage(providerName: "Simkl").hasPrefix("Simkl also clears"))
    }

    func testRemoveFailureCopy() {
        XCTAssertEqual(Policy.removeFailedTitle(providerName: "MDBList"), "Couldn\u{2019}t update MDBList")
        XCTAssertEqual(Policy.removeFailedTitle(providerName: nil), "Couldn\u{2019}t remove the title")
        XCTAssertEqual(Policy.removeFailedMessage("  HTTP 429 \n"), "HTTP 429")
        XCTAssertEqual(Policy.removeFailedMessage(""), "Something went wrong. Try again.")
    }

    /// Batch K: read-only MDBList lists (external / dynamic / liked, upstream 3913a140b /
    /// 2cc2e6a61) get no remove; the local library (no list key) always keeps it.
    func testOffersRemoveOnlyOnWritableLists() {
        let readOnly: Set<String> = ["mdblist:external:7", "mdblist:dynamic:8", "mdblist:liked:9"]
        let canRemove: (String) -> Bool = { !readOnly.contains($0) }
        XCTAssertTrue(Policy.offersRemove(listKey: nil, canRemoveFromList: canRemove))
        XCTAssertTrue(Policy.offersRemove(listKey: "mdblist:list:1", canRemoveFromList: canRemove))
        XCTAssertTrue(Policy.offersRemove(listKey: "mdblist:watchlist", canRemoveFromList: canRemove))
        for key in readOnly {
            XCTAssertFalse(Policy.offersRemove(listKey: key, canRemoveFromList: canRemove), key)
        }
    }

    // MARK: - Genre and year (W5)

    private typealias Facet = LibraryGridPolicy.FacetOption

    func testFacetShowsWithTwoOptionsOrASelection() {
        let one = [Facet(key: "Drama", count: 3)]
        let two = one + [Facet(key: "Comedy", count: 1)]
        XCTAssertFalse(Policy.showsFacet([], selected: nil))
        XCTAssertFalse(Policy.showsFacet(one, selected: nil))
        XCTAssertTrue(Policy.showsFacet(two, selected: nil))
        XCTAssertTrue(Policy.showsFacet(one, selected: "Drama"))
        XCTAssertTrue(Policy.showsFacet([], selected: "Drama"))
    }

    func testGenreLabelUsesDiscoverNamesThenSlugWords() {
        XCTAssertEqual(Policy.genreLabel("drama"), "Drama")
        XCTAssertEqual(Policy.genreLabel("science-fiction"), "Science Fiction")
        XCTAssertEqual(Policy.genreLabel("Kdrama"), "Kdrama")
        XCTAssertEqual(Policy.genreLabel("sci-fi"), "Sci-Fi")
    }

    func testGenreLabelsDeduplicateRepeatedLabels() {
        let labels = Policy.genreLabels(["Action", "action"])
        XCTAssertEqual(labels["Action"], "Action")
        XCTAssertEqual(labels["action"], "action")
        // The fixture's pair stays two distinct rows.
        let scifi = Policy.genreLabels(["Sci-Fi", "science-fiction"])
        XCTAssertEqual(scifi["Sci-Fi"], "Sci-Fi")
        XCTAssertEqual(scifi["science-fiction"], "Science Fiction")
    }

    func testFacetOptionLabelsAndVoiceOverText() {
        XCTAssertEqual(Policy.facetOptionLabel("Drama", count: 12), "Drama (12)")
        XCTAssertEqual(Policy.facetOptionAccessibilityLabel("Drama", count: 12), "Drama, 12 titles")
        XCTAssertEqual(Policy.facetOptionAccessibilityLabel("Drama", count: 1), "Drama, 1 title")
        XCTAssertEqual(Policy.typeOptionLabel(nil, count: 14), "All types (14)")
        XCTAssertEqual(Policy.typeOptionLabel("movie", count: 8), "Movies (8)")
    }

    func testPillTitlesAndValuesFallBackToAll() {
        XCTAssertEqual(Policy.genrePillTitle(selectedLabel: nil), "Genre")
        XCTAssertEqual(Policy.genrePillTitle(selectedLabel: "Drama"), "Drama")
        XCTAssertEqual(Policy.yearPillTitle(selected: nil), "Year")
        XCTAssertEqual(Policy.yearPillTitle(selected: "2020"), "2020")
        XCTAssertEqual(Policy.genreAccessibilityValue(selectedLabel: nil), "All genres")
        XCTAssertEqual(Policy.genreAccessibilityValue(selectedLabel: "Drama"), "Drama")
        XCTAssertEqual(Policy.yearAccessibilityValue(selected: nil), "All years")
        XCTAssertEqual(Policy.yearAccessibilityValue(selected: "2020"), "2020")
    }

    // MARK: - The Show menu (W5)

    /// Every set `toggling` can reach maps to one choice, and back to a set that passes and fails
    /// the same titles.
    func testWatchChoiceRoundTripsEverySmartFilterSet() {
        var reachable: Set<Set<Policy.SmartFilter>> = [[]]
        var frontier: [Set<Policy.SmartFilter>] = [[]]
        while let set = frontier.popLast() {
            for filter in Policy.SmartFilter.allCases {
                let next = Policy.toggling(filter, in: set)
                if reachable.insert(next).inserted { frontier.append(next) }
            }
        }
        let samples = [watched, halfway, fresh, State(isWatched: true, progress: 0.4)]
        for set in reachable {
            let back = Policy.smartFilters(for: Policy.watchChoice(for: set))
            for state in samples {
                XCTAssertEqual(Policy.passes(state, filters: set), Policy.passes(state, filters: back), "\(set) vs \(back)")
            }
        }
        for choice in Policy.WatchChoice.allCases {
            XCTAssertEqual(Policy.watchChoice(for: Policy.smartFilters(for: choice)), choice)
        }
    }

    func testWatchChoicesListOnlyVisibleChips() {
        XCTAssertEqual(Policy.watchChoices(visible: []), [.all])
        XCTAssertEqual(Policy.watchChoices(visible: [.watched]), [.all, .watched])
        XCTAssertEqual(Policy.watchChoices(visible: [.unwatched, .watched]), [.all, .unwatched, .watched])
        XCTAssertEqual(Policy.watchChoices(visible: Policy.SmartFilter.allCases), [.all, .unwatched, .inProgress, .watched])
        XCTAssertEqual(Policy.WatchChoice.all.title, "All Titles")
    }
}
