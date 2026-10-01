import XCTest
@testable import NuvioTV

/// Orivio batch, item 3: the poster hold menu's wording, glyph, ordering and state decisions.
/// All pure — the views in `TitleHoldMenu.swift` / `ContinueWatchingRow` only render these.
final class TitleHoldMenuPolicyTests: XCTestCase {
    // MARK: - Library

    func testLibraryLabelOffersAddWhenUnsavedAndRemoveWhenSaved() {
        XCTAssertEqual(TitleHoldMenuPolicy.libraryLabel(isSaved: false), "Add to Library")
        XCTAssertEqual(TitleHoldMenuPolicy.libraryLabel(isSaved: true), "Remove from Library")
    }

    func testLibraryIconMatchesDetailPlusAndLibraryTabTrash() {
        XCTAssertEqual(TitleHoldMenuPolicy.libraryIcon(isSaved: false), "plus")
        XCTAssertEqual(TitleHoldMenuPolicy.libraryIcon(isSaved: true), "trash")
    }

    // MARK: - Watched

    func testWatchedLabelFlipsOnStateForMoviesAndSeries() {
        for isSeries in [false, true] {
            XCTAssertEqual(TitleHoldMenuPolicy.watchedLabel(isWatched: false, isSeries: isSeries),
                           "Mark as Watched", "isSeries=\(isSeries)")
            XCTAssertEqual(TitleHoldMenuPolicy.watchedLabel(isWatched: true, isSeries: isSeries),
                           "Mark as Unwatched", "isSeries=\(isSeries)")
        }
    }

    func testWatchedIconFillsOnceWatched() {
        XCTAssertEqual(TitleHoldMenuPolicy.watchedIcon(isWatched: false), "checkmark.circle")
        XCTAssertEqual(TitleHoldMenuPolicy.watchedIcon(isWatched: true), "checkmark.circle.fill")
    }

    func testMovieWatchedStateIsItsOwnMarkerOnly() {
        // The fully-watched-series flag is meaningless for a movie and must never leak in.
        XCTAssertFalse(TitleHoldMenuPolicy.effectiveWatched(titleMarked: false, fullyWatchedSeries: true, isSeries: false))
        XCTAssertTrue(TitleHoldMenuPolicy.effectiveWatched(titleMarked: true, fullyWatchedSeries: false, isSeries: false))
    }

    func testSeriesWatchedStateFollowsTheFullyWatchedMarkerOrATitleMark() {
        // Mirrors `WatchingActions.togglePosterWatched`'s "currently watched" test, so the label
        // names exactly what the tap does (mark every released episode vs. unmark).
        XCTAssertTrue(TitleHoldMenuPolicy.effectiveWatched(titleMarked: false, fullyWatchedSeries: true, isSeries: true))
        XCTAssertTrue(TitleHoldMenuPolicy.effectiveWatched(titleMarked: true, fullyWatchedSeries: false, isSeries: true))
        XCTAssertFalse(TitleHoldMenuPolicy.effectiveWatched(titleMarked: false, fullyWatchedSeries: false, isSeries: true))
    }

    func testIsSeriesAcceptsTheSharedSeriesLikeTypes() {
        for type in ["series", "show", "tv", "tvshow", "Series", " TV ", "TvShow"] {
            XCTAssertTrue(TitleHoldMenuPolicy.isSeries(type: type), type)
        }
        for type in ["movie", "", "anime", "channel"] {
            XCTAssertFalse(TitleHoldMenuPolicy.isSeries(type: type), type)
        }
    }

    // MARK: - Continue Watching

    func testEpisodeEntryGetsAllFiveActionsInOrder() {
        XCTAssertEqual(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: true),
                       [.playManually, .goToDetails, .markEpisodeWatched, .startOver, .remove])
    }

    func testMovieEntryHasNoMarkEpisodeWatched() {
        XCTAssertEqual(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: false),
                       [.playManually, .goToDetails, .startOver, .remove])
    }

    func testRemoveIsAlwaysLastAndTheOnlyDestructiveAction() {
        for isEpisode in [false, true] {
            let actions = TitleHoldMenuPolicy.continueWatchingActions(isEpisode: isEpisode)
            XCTAssertEqual(actions.last, .remove, "isEpisode=\(isEpisode)")
            XCTAssertEqual(actions.filter(\.isDestructive), [.remove], "isEpisode=\(isEpisode)")
        }
    }

    func testEveryActionAppearsAtMostOnce() {
        for isEpisode in [false, true] {
            let actions = TitleHoldMenuPolicy.continueWatchingActions(isEpisode: isEpisode)
            XCTAssertEqual(actions.count, Set(actions).count, "isEpisode=\(isEpisode)")
        }
    }

    func testActionTitlesAndGlyphs() {
        let expected: [(TitleHoldMenuPolicy.CWAction, String, String)] = [
            (.playManually, "Play Manually", "list.bullet"),
            (.goToDetails, "Go to Details", "info.circle"),
            (.markEpisodeWatched, "Mark Episode Watched", "checkmark.circle"),
            (.startOver, "Start Over", "arrow.counterclockwise"),
            (.remove, "Remove from Continue Watching", "trash"),
        ]
        for (action, title, glyph) in expected {
            XCTAssertEqual(action.title, title)
            XCTAssertEqual(action.systemImage, glyph, "\(action)")
        }
        // The table above must cover every case, so a new action cannot ship without a pinned label.
        XCTAssertEqual(Set(expected.map(\.0)), Set(TitleHoldMenuPolicy.CWAction.allCases))
    }

    func testEpisodeNeedsBothSeasonAndEpisodeNumbers() {
        XCTAssertTrue(TitleHoldMenuPolicy.isEpisode(season: 2, episode: 5))
        XCTAssertFalse(TitleHoldMenuPolicy.isEpisode(season: nil, episode: nil))
        XCTAssertFalse(TitleHoldMenuPolicy.isEpisode(season: 2, episode: nil))
        XCTAssertFalse(TitleHoldMenuPolicy.isEpisode(season: nil, episode: 5))
    }
}
