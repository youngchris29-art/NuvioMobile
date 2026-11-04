import XCTest
import SharedCore
@testable import NuvioTV

/// Orivio batch, item 3: the poster hold menu's wording, glyph, ordering and state decisions.
/// All pure — the views in `TitleHoldMenu.swift` / `ContinueWatchingRow` only render these.
/// Fix round 1 adds the explicit-action model (each button performs what its label says, never a
/// toggle of whatever the live state is) and the Detail hold-Play availability rule.
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

    // MARK: - Explicit actions (fix round 1)

    func testLibraryActionFollowsTheLabelState() {
        XCTAssertEqual(TitleHoldMenuPolicy.libraryAction(isSaved: false), .save)
        XCTAssertEqual(TitleHoldMenuPolicy.libraryAction(isSaved: true), .remove)
    }

    func testWatchedActionFollowsTheLabelState() {
        XCTAssertEqual(TitleHoldMenuPolicy.watchedAction(isWatched: false), .mark)
        XCTAssertEqual(TitleHoldMenuPolicy.watchedAction(isWatched: true), .unmark)
    }

    func testActionAndLabelCanNeverDisagree() {
        // The label and the action are both functions of the same captured state: a button that
        // says "Remove from Library" removes, one that says "Mark as Unwatched" unmarks.
        for isSaved in [false, true] {
            let isRemoveLabel = TitleHoldMenuPolicy.libraryLabel(isSaved: isSaved).hasPrefix("Remove")
            XCTAssertEqual(isRemoveLabel, TitleHoldMenuPolicy.libraryAction(isSaved: isSaved) == .remove, "isSaved=\(isSaved)")
        }
        for isSeries in [false, true] {
            for isWatched in [false, true] {
                let isUnmarkLabel = TitleHoldMenuPolicy.watchedLabel(isWatched: isWatched, isSeries: isSeries).hasSuffix("Unwatched")
                XCTAssertEqual(isUnmarkLabel, TitleHoldMenuPolicy.watchedAction(isWatched: isWatched) == .unmark,
                               "isWatched=\(isWatched) isSeries=\(isSeries)")
            }
        }
    }

    func testToggleGuardOnlyLetsAToggleRunWhileTheLabelIsCurrent() {
        // Label built unsaved/unwatched, still so: the toggle does what the label says.
        XCTAssertTrue(TitleHoldMenuPolicy.labelStillMatchesLiveState(labelState: false, liveState: false))
        XCTAssertTrue(TitleHoldMenuPolicy.labelStillMatchesLiveState(labelState: true, liveState: true))
        // Stale label (Detail or a finished playback changed the title after the menu was built):
        // a toggle would now do the OPPOSITE of what the button says, so it must not run.
        XCTAssertFalse(TitleHoldMenuPolicy.labelStillMatchesLiveState(labelState: false, liveState: true))
        XCTAssertFalse(TitleHoldMenuPolicy.labelStillMatchesLiveState(labelState: true, liveState: false))
    }

    func testSeriesGuardUsesTheSameEffectiveWatchedStateAsTheLabel() {
        // The label's state is `effectiveWatched`; the guard compares the live value of that same
        // function, so a series that became fully watched elsewhere reads as stale for an old
        // "Mark as Watched" label and current for a fresh "Mark as Unwatched" one.
        let labelBuiltBeforeFinish = TitleHoldMenuPolicy.effectiveWatched(titleMarked: false, fullyWatchedSeries: false, isSeries: true)
        let liveAfterFinish = TitleHoldMenuPolicy.effectiveWatched(titleMarked: false, fullyWatchedSeries: true, isSeries: true)
        XCTAssertFalse(TitleHoldMenuPolicy.labelStillMatchesLiveState(labelState: labelBuiltBeforeFinish, liveState: liveAfterFinish))
        XCTAssertTrue(TitleHoldMenuPolicy.labelStillMatchesLiveState(labelState: liveAfterFinish, liveState: liveAfterFinish))
    }

    // MARK: - Detail hold-Play menu

    func testHoldPlayMenuNeedsAutoPlayOnAndPlayEnabled() {
        XCTAssertTrue(TitleHoldMenuPolicy.holdPlayMenuAvailable(autoPlayFirstStreamOn: true, isPlayEnabled: true))
        // Auto-play off: a plain press already opens the source list.
        XCTAssertFalse(TitleHoldMenuPolicy.holdPlayMenuAvailable(autoPlayFirstStreamOn: false, isPlayEnabled: true))
        // A disabled Play never carries a menu.
        XCTAssertFalse(TitleHoldMenuPolicy.holdPlayMenuAvailable(autoPlayFirstStreamOn: true, isPlayEnabled: false))
        XCTAssertFalse(TitleHoldMenuPolicy.holdPlayMenuAvailable(autoPlayFirstStreamOn: false, isPlayEnabled: false))
    }

    // MARK: - Continue Watching

    func testEpisodeEntryGetsAllFiveActionsInOrder() {
        XCTAssertEqual(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: true),
                       [.playManually, .goToDetails, .markEpisodeWatched, .startOver, .remove])
    }

    func testMovieEntryGetsMarkAsWatched() {
        XCTAssertEqual(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: false),
                       [.playManually, .goToDetails, .markWatched, .startOver, .remove])
    }

    func testMarkWatchedIsHiddenWhenTheSharedVerdictSaysNo() {
        XCTAssertEqual(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: true, isNextUp: true, canMarkWatched: false),
                       [.playManually, .goToDetails, .remove])
        XCTAssertEqual(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: false, canMarkWatched: false),
                       [.playManually, .goToDetails, .startOver, .remove])
    }

    /// FEAT-85: an Up Next card already plays from the beginning, so it has no Start Over; it keeps
    /// Remove (a synced dismissal) and Mark Episode Watched.
    func testUpNextEntryHasNoStartOver() {
        XCTAssertEqual(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: true, isNextUp: true),
                       [.playManually, .goToDetails, .markEpisodeWatched, .remove])
    }

    func testIsNextUpDefaultsToFalse() {
        for isEpisode in [false, true] {
            XCTAssertEqual(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: isEpisode),
                           TitleHoldMenuPolicy.continueWatchingActions(isEpisode: isEpisode, isNextUp: false))
        }
    }

    func testRemoveIsAlwaysLastAndTheOnlyDestructiveAction() {
        for isEpisode in [false, true] {
            let actions = TitleHoldMenuPolicy.continueWatchingActions(isEpisode: isEpisode)
            XCTAssertEqual(actions.last, .remove, "isEpisode=\(isEpisode)")
            let upNext = TitleHoldMenuPolicy.continueWatchingActions(isEpisode: isEpisode, isNextUp: true)
            XCTAssertEqual(upNext.last, .remove, "isEpisode=\(isEpisode) upNext")
            XCTAssertEqual(upNext.filter(\.isDestructive), [.remove], "isEpisode=\(isEpisode) upNext")
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
            (.markWatched, "Mark as Watched", "checkmark.circle"),
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

    // MARK: - Detail episode and season menus (FEAT-83)

    @MainActor
    func testEpisodeMenuOrderIsTheEpisodeThenThePreviousEpisodes() {
        XCTAssertEqual(TitleHoldMenuPolicy.episodeActions(isEpisodeWatched: false, previousCount: 3, arePreviousWatched: false),
                       [.episode(isWatched: false), .previousEpisodes(areWatched: false)])
        XCTAssertEqual(TitleHoldMenuPolicy.episodeActions(isEpisodeWatched: true, previousCount: 3, arePreviousWatched: true),
                       [.episode(isWatched: true), .previousEpisodes(areWatched: true)])
    }

    @MainActor
    func testEpisodeLabelFlipsWithTheEpisodesOwnState() {
        // "Mark Episode Watched" is the Continue Watching key (its translations carry over).
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.episode(isWatched: false).title, "Mark Episode Watched")
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.episode(isWatched: true).title, "Mark Episode Unwatched")
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.episode(isWatched: false).title,
                       TitleHoldMenuPolicy.CWAction.markEpisodeWatched.title)
    }

    @MainActor
    func testPreviousIsLeftOutOnTheFirstEpisode() {
        // Mobile's `canMarkPreviousEpisodes = previousEpisodes.isNotEmpty()`.
        for watched in [false, true] {
            XCTAssertEqual(TitleHoldMenuPolicy.episodeActions(isEpisodeWatched: watched, previousCount: 0, arePreviousWatched: false),
                           [.episode(isWatched: watched)])
        }
    }

    @MainActor
    func testPreviousLabelFlipsOnceEveryPreviousEpisodeIsWatched() {
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.previousEpisodes(areWatched: false).title, "Mark Previous Episodes Watched")
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.previousEpisodes(areWatched: true).title, "Mark Previous Episodes Unwatched")
        // The episode's own state never drives the previous item.
        let actions = TitleHoldMenuPolicy.episodeActions(isEpisodeWatched: false, previousCount: 2, arePreviousWatched: true)
        XCTAssertEqual(actions.last, .previousEpisodes(areWatched: true))
    }

    @MainActor
    func testSeasonItemIsLeftOutWithNoReleasedEpisode() {
        XCTAssertEqual(TitleHoldMenuPolicy.seasonActions(seasonLabel: "Season 3", releasedCount: 0, isSeasonWatched: false), [])
        XCTAssertEqual(TitleHoldMenuPolicy.seasonActions(seasonLabel: "Season 3", releasedCount: 4, isSeasonWatched: false),
                       [.season(seasonLabel: "Season 3", isWatched: false)])
    }

    @MainActor
    func testSeasonLabelNamesTheSeasonAndFlipsWithItsState() {
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.season(seasonLabel: "Season 2", isWatched: false).title, "Mark Season 2 Watched")
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.season(seasonLabel: "Season 2", isWatched: true).title, "Mark Season 2 Unwatched")
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.season(seasonLabel: "Specials", isWatched: false).title, "Mark Specials Watched")
    }

    func testSeasonIsWatchedOnlyWhenEveryReleasedEpisodeIs() {
        let watched: Set<String> = ["1:1", "1:2", "1:3"]
        XCTAssertTrue(TitleHoldMenuPolicy.seasonIsWatched(releasedKeys: ["1:1", "1:2", "1:3"], watchedKeys: watched))
        XCTAssertFalse(TitleHoldMenuPolicy.seasonIsWatched(releasedKeys: ["1:1", "1:2", "1:4"], watchedKeys: watched))
        // No released episode: never "watched" (mobile's `episodes.isNotEmpty() && …`).
        XCTAssertFalse(TitleHoldMenuPolicy.seasonIsWatched(releasedKeys: [], watchedKeys: watched))
        // An entry with neither number has no episode key and never reads as watched.
        XCTAssertFalse(TitleHoldMenuPolicy.seasonIsWatched(releasedKeys: ["1:1", nil], watchedKeys: watched))
        // Unaired episodes are not in the released list, so they never hold the label at "Watched".
        XCTAssertTrue(TitleHoldMenuPolicy.seasonIsWatched(releasedKeys: ["1:1", "1:2"], watchedKeys: watched))
    }

    func testAreAllWatchedFollowsTheSameRuleForThePreviousEpisodes() {
        let watched: Set<String> = ["1:1", "1:2", "2:1"]
        XCTAssertTrue(TitleHoldMenuPolicy.areAllWatched(keys: ["1:1", "1:2", "2:1"], watchedKeys: watched))
        XCTAssertFalse(TitleHoldMenuPolicy.areAllWatched(keys: ["1:1", "1:2", "2:1", "2:2"], watchedKeys: watched))
        XCTAssertFalse(TitleHoldMenuPolicy.areAllWatched(keys: [], watchedKeys: watched))
    }

    func testEpisodeKeyMatchesTheWatchedEpisodeKeysFormat() {
        XCTAssertEqual(TitleHoldMenuPolicy.episodeKey(season: 2, episode: 5), "2:5")
        XCTAssertEqual(TitleHoldMenuPolicy.episodeKey(season: 0, episode: 1), "0:1")
        // Review r1 P3-8: one number is enough, the missing one is -1 as in the shared key.
        XCTAssertEqual(TitleHoldMenuPolicy.episodeKey(season: nil, episode: 5), "-1:5")
        XCTAssertEqual(TitleHoldMenuPolicy.episodeKey(season: 2, episode: nil), "2:-1")
        XCTAssertNil(TitleHoldMenuPolicy.episodeKey(season: nil, episode: nil))
        // So an episode with one number can read as watched, and its menu label flips.
        XCTAssertTrue(TitleHoldMenuPolicy.areAllWatched(
            keys: [TitleHoldMenuPolicy.episodeKey(season: nil, episode: 5)], watchedKeys: ["-1:5"]))
    }

    /// The tvOS key is the shared `watchedKey`'s season/episode tail, so the two can never disagree
    /// about which stored mark an entry reads.
    func testEpisodeKeyIsTheSharedWatchedKeyTail() {
        let cases: [(Int?, Int?)] = [(2, 5), (0, 1), (nil, 5), (2, nil)]
        for (season, episode) in cases {
            let shared = WatchingPoliciesKt.watchedKey(
                content: WatchingContentRef(type: "series", id: "tt1"),
                seasonNumber: season.map { KotlinInt(int: Int32($0)) },
                episodeNumber: episode.map { KotlinInt(int: Int32($0)) }
            )
            XCTAssertEqual(shared, "series:tt1:" + (TitleHoldMenuPolicy.episodeKey(season: season, episode: episode) ?? ""))
        }
    }

    @MainActor
    func testEveryDetailActionDoesWhatItsLabelSays() {
        let all: [TitleHoldMenuPolicy.DetailTileAction] = [
            .episode(isWatched: false), .episode(isWatched: true),
            .previousEpisodes(areWatched: false), .previousEpisodes(areWatched: true),
            .season(seasonLabel: "Season 1", isWatched: false), .season(seasonLabel: "Season 1", isWatched: true),
        ]
        for action in all {
            XCTAssertFalse(action.title.isEmpty, "\(action)")
            XCTAssertFalse(action.systemImage.isEmpty, "\(action)")
            // A "… Unwatched" label unmarks and passes `true` (currently watched) to the shared toggle.
            XCTAssertEqual(action.title.hasSuffix("Unwatched"), action.watchedAction == .unmark, "\(action)")
            XCTAssertEqual(action.watchedAction == .unmark, action.labelState, "\(action)")
        }
    }

    @MainActor
    func testDetailActionGlyphs() {
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.episode(isWatched: false).systemImage, "checkmark.circle")
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.episode(isWatched: true).systemImage, "checkmark.circle.fill")
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.season(seasonLabel: "Season 1", isWatched: true).systemImage, "checkmark.circle.fill")
        XCTAssertEqual(TitleHoldMenuPolicy.DetailTileAction.previousEpisodes(areWatched: false).systemImage, "checklist")
    }
}
