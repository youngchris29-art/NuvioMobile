import XCTest
@testable import NuvioTV
import SharedCore

/// Home Stage & Strip (P1 §5, §9.3, W2-A): the stage's Continue-Watching-aware copy
/// (`Screens/Home/StageCopy.swift`) — the meta line, the synopsis rule, the time-left label, the
/// Continue Watching index the stage looks titles up in — and the strip's "heading · add-on" rule.
/// Pure functions fed hand-built Kotlin models, no repository.
@MainActor
final class StageCopyTests: XCTestCase {

    private let dot = " \u{00B7} "

    // MARK: Fixtures

    private func preview(id: String = "tt1",
                         type: String = "series",
                         name: String = "Show",
                         description: String? = "The series synopsis.",
                         releaseInfo: String? = "2024",
                         genres: [String] = ["Drama", "Crime"]) -> MetaPreview {
        MetaPreview(
            id: id, type: type, name: name,
            poster: nil, banner: nil, logo: nil,
            posterShape: .poster,
            description: description, releaseInfo: releaseInfo, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: genres,
            rawPosterUrl: nil,
            landscapePoster: nil,
            rawLandscapePosterUrl: nil,
            customPosterApplied: false
        )
    }

    /// Defaults: S1 E3 "The Hunt" of "Show", 15 of 60 minutes watched (45 left).
    private func entry(type: String = "series",
                       id: String = "tt1",
                       title: String = "Show",
                       season: Int32? = 1,
                       episode: Int32? = 3,
                       episodeTitle: String? = "The Hunt",
                       positionMs: Int64 = 15 * 60_000,
                       durationMs: Int64 = 60 * 60_000,
                       pauseDescription: String? = nil) -> WatchProgressEntry {
        WatchProgressEntry(
            contentType: type, parentMetaId: id, parentMetaType: type, videoId: "\(id):video", title: title,
            logo: nil, poster: nil, background: nil,
            seasonNumber: season.map { KotlinInt(int: $0) },
            episodeNumber: episode.map { KotlinInt(int: $0) },
            episodeTitle: episodeTitle, episodeThumbnail: nil,
            lastPositionMs: positionMs, durationMs: durationMs, lastUpdatedEpochMs: 0,
            providerName: nil, providerAddonId: nil, lastStreamTitle: nil, lastStreamSubtitle: nil,
            pauseDescription: pauseDescription, lastSourceUrl: nil, isCompleted: false,
            progressPercent: nil, source: "local",
            trackingProviderId: nil, trackingProviderItemId: nil, trackingSourceUrl: nil,
            progressKey: nil, excludedNextUpSeasons: []
        )
    }

    // MARK: Meta line (§9.3)

    func testEpisodeTitleAndTimeLeft() {
        let copy = StageCopy.make(item: preview(), progress: entry())
        XCTAssertEqual(copy.meta, "S1 E3\(dot)The Hunt\(dot)45m left")
    }

    func testNoEpisodeTitle() {
        let copy = StageCopy.make(item: preview(), progress: entry(episodeTitle: nil))
        XCTAssertEqual(copy.meta, "S1 E3\(dot)45m left")
        let blank = StageCopy.make(item: preview(), progress: entry(episodeTitle: "   "))
        XCTAssertEqual(blank.meta, "S1 E3\(dot)45m left", "a blank episode title counts as none")
    }

    func testEpisodeTitleThatRepeatsTheShowIsDropped() {
        let sameAsEntry = StageCopy.make(item: preview(), progress: entry(episodeTitle: "show "))
        XCTAssertEqual(sameAsEntry.meta, "S1 E3\(dot)45m left")
        let sameAsItem = StageCopy.make(item: preview(name: "The Hunt"),
                                        progress: entry(title: "Another Name"))
        XCTAssertEqual(sameAsItem.meta, "S1 E3\(dot)45m left")
    }

    func testMovieFromAnHourShowsHoursAndMinutes() {
        let movie = preview(id: "tt9", type: "movie", name: "Film")
        let progress = entry(type: "movie", id: "tt9", title: "Film", season: nil, episode: nil,
                             episodeTitle: nil, positionMs: 55 * 60_000, durationMs: 120 * 60_000)
        XCTAssertEqual(StageCopy.make(item: movie, progress: progress).meta, "1h 5m left")
    }

    func testUnknownDurationHasNoTime() {
        let copy = StageCopy.make(item: preview(), progress: entry(positionMs: 0, durationMs: 0))
        XCTAssertEqual(copy.meta, "S1 E3\(dot)The Hunt", "Trakt/Simkl percent-only rows carry no duration")
    }

    func testUnderAMinuteLeftHasNoTime() {
        let copy = StageCopy.make(item: preview(),
                                  progress: entry(positionMs: 60 * 60_000 - 30_000, durationMs: 60 * 60_000))
        XCTAssertEqual(copy.meta, "S1 E3\(dot)The Hunt")
    }

    func testNothingKnownFallsBackToClassicMeta() {
        let movie = preview(id: "tt9", type: "movie", name: "Film", releaseInfo: "2019", genres: ["Action"])
        let progress = entry(type: "movie", id: "tt9", title: "Film", season: nil, episode: nil,
                             episodeTitle: nil, positionMs: 0, durationMs: 0)
        let copy = StageCopy.make(item: movie, progress: progress)
        XCTAssertEqual(copy.meta, StageCopy.classicMeta(movie))
        XCTAssertEqual(copy.meta, "2019  \u{00B7}  Action")
    }

    func testSeasonWithoutEpisodeIsNoCode() {
        let copy = StageCopy.make(item: preview(), progress: entry(episode: nil))
        XCTAssertEqual(copy.meta, "The Hunt\(dot)45m left")
    }

    func testNoProgressIsClassicCopy() {
        let item = preview()
        let copy = StageCopy.make(item: item, progress: nil)
        XCTAssertEqual(copy.meta, "2024  \u{00B7}  Drama \u{00B7} Crime")
        XCTAssertEqual(copy.synopsis, "The series synopsis.")
    }

    // MARK: Synopsis

    func testPauseDescriptionBeatsTheDescription() {
        let copy = StageCopy.make(item: preview(),
                                  progress: entry(pauseDescription: "  The episode's own text.  "))
        XCTAssertEqual(copy.synopsis, "The episode's own text.")
    }

    func testBlankPauseDescriptionFallsBackToTheDescription() {
        let copy = StageCopy.make(item: preview(), progress: entry(pauseDescription: " \n "))
        XCTAssertEqual(copy.synopsis, "The series synopsis.")
        let none = StageCopy.make(item: preview(description: nil), progress: entry())
        XCTAssertEqual(none.synopsis, "", "a Continue Watching preview carries no description until TMDB fills it")
    }

    // MARK: Folders

    func testFolderStaysPlainWhateverTheLookupAnswers() {
        let folder = preview(id: "nuvio-folder://col/f1", type: "nuvio.folder", name: "Action",
                             description: "4 sources", releaseInfo: "Genres", genres: [])
        let copy = StageCopy.make(item: folder, progress: entry(pauseDescription: "Should not show"))
        XCTAssertEqual(copy, StageCopy(meta: "Genres", synopsis: "4 sources"))
    }

    func testFolderLiteralsMatchTheHomeConstants() {
        XCTAssertEqual(StageCopy.folderType, collectionHeroType)
        XCTAssertEqual(StageCopy.folderIdScheme, collectionHeroIdScheme)
        let folder = preview(id: "\(collectionHeroIdScheme)col/f1", type: collectionHeroType)
        XCTAssertEqual(StageCopy.isFolderPreview(folder), isCollectionHero(folder))
        XCTAssertTrue(StageCopy.isFolderPreview(folder))
        XCTAssertFalse(StageCopy.isFolderPreview(preview()))
    }

    // MARK: Time left

    func testRemainingLabelBoundaries() {
        XCTAssertEqual(StageCopy.remainingLabel(positionMs: 0, durationMs: 60_000), "1m left")
        XCTAssertNil(StageCopy.remainingLabel(positionMs: 1, durationMs: 60_000), "59.999 s is under a minute")
        XCTAssertEqual(StageCopy.remainingLabel(positionMs: 0, durationMs: 3_600_000), "1h 0m left")
        XCTAssertEqual(StageCopy.remainingLabel(positionMs: 15 * 60_000 + 30_000, durationMs: 3_600_000),
                       "44m left", "minutes round down")
        XCTAssertEqual(StageCopy.remainingLabel(positionMs: -5_000, durationMs: 120_000), "2m left",
                       "a negative position counts from 0")
        XCTAssertNil(StageCopy.remainingLabel(positionMs: 200_000, durationMs: 120_000))
        XCTAssertNil(StageCopy.remainingLabel(positionMs: 0, durationMs: -1))
    }

    func testEpisodeCode() {
        XCTAssertEqual(StageCopy.episodeCode(season: 1, episode: 3), "S1 E3")
        XCTAssertEqual(StageCopy.episodeCode(season: 10, episode: 12), "S10 E12")
    }

    // MARK: Continue Watching index

    func testIndexKeysByParentAndTheFirstEntryWins() {
        let shown = entry(episode: 3)
        let older = entry(episode: 2)
        let movie = entry(type: "movie", id: "tt9", title: "Film", season: nil, episode: nil, episodeTitle: nil)
        let index = StageCopy.progressIndex([shown, older, movie])
        XCTAssertEqual(index.count, 2)
        XCTAssertTrue(index["series:tt1"] === shown, "the row's first card for a title is the one the stage reads")
        XCTAssertTrue(index["movie:tt9"] === movie)
    }

    func testLookupFindsTheTitleFocusedInAnyRow() {
        let progress = entry()
        let lookup = StageCopy.progressLookup([progress])
        XCTAssertNotNil(lookup)
        // A catalog card for the same title (same type and id as the entry's parent) finds it…
        XCTAssertTrue(lookup?(preview(name: "Show (catalog card)")) === progress)
        // …as does the Continue Watching card's own preview…
        XCTAssertTrue(lookup?(StageCopy.preview(from: progress)) === progress)
        // …and another type or id does not.
        XCTAssertNil(lookup?(preview(type: "movie")))
        XCTAssertNil(lookup?(preview(id: "tt2")))
    }

    func testNoEntriesInstallNoLookup() {
        XCTAssertNil(StageCopy.progressLookup([]))
    }

    // MARK: Row heading add-on (§5)

    func testHeadingAddon() {
        XCTAssertEqual(StageCopy.headingAddon(title: "Popular", addonName: "Cinemeta"), "Cinemeta")
        XCTAssertEqual(StageCopy.headingAddon(title: "Popular", addonName: "  Cinemeta \n"), "Cinemeta")
        XCTAssertNil(StageCopy.headingAddon(title: "Popular", addonName: ""))
        XCTAssertNil(StageCopy.headingAddon(title: "Popular", addonName: "   "))
        XCTAssertNil(StageCopy.headingAddon(title: "Cinemeta Popular", addonName: "cinemeta"),
                     "a heading that already names its add-on is left alone")
        XCTAssertNil(StageCopy.headingAddon(title: "Popular - Torrentio", addonName: "TORRENTIO"))
    }
}

/// Home Stage & Strip (P1 §7, W2-A): when the stage's background trailer may arm
/// (`StageTrailerGate` in `Screens/Home/StageController.swift`). The model it arms is the shared
/// `InlineTrailerCardModel`, whose dwell (M4's start delay) is covered by `TrailerStartGateTests`.
@MainActor
final class StageTrailerGateTests: XCTestCase {

    private let open = StageTrailerGate(modeOn: true, autoplayAllowed: true, sceneActive: true,
                                        covered: false, stripOwnsFocus: true, chromeHoldsFocus: false)

    private func armed(_ gate: StageTrailerGate,
                       resting: String? = "movie:tt1",
                       shown: String? = "movie:tt1",
                       folder: Bool = false,
                       focused: String? = "movie:tt1") -> String? {
        gate.armedIdentity(restingKey: resting, shownIdentity: shown, shownIsFolder: folder, focusedIdentity: focused)
    }

    func testArmsWhenTheStageRestsOnTheFocusedTitle() {
        XCTAssertTrue(open.isOpen)
        XCTAssertEqual(armed(open), "movie:tt1")
    }

    func testEveryClosedConditionBlocks() {
        var off = open; off.modeOn = false
        var noAutoplay = open; noAutoplay.autoplayAllowed = false
        var inactive = open; inactive.sceneActive = false
        var covered = open; covered.covered = true
        var focusOut = open; focusOut.stripOwnsFocus = false
        var chrome = open; chrome.chromeHoldsFocus = true
        for (name, gate) in [("mode", off), ("autoplay", noAutoplay), ("scene", inactive),
                             ("cover", covered), ("strip focus", focusOut), ("chrome", chrome)] {
            XCTAssertFalse(gate.isOpen, name)
            XCTAssertNil(armed(gate), name)
        }
    }

    func testNoRestNoTrailer() {
        XCTAssertNil(armed(open, resting: nil), "any focus activity or page start clears the rest")
    }

    func testTheRestMustBeOnTheShownTitle() {
        XCTAssertNil(armed(open, resting: "movie:tt1", shown: "movie:tt2"))
        XCTAssertNil(armed(open, shown: nil))
    }

    func testTheRestMustBeOnTheFocusedTitle() {
        // A cold resolve: focus committed to tt2, the stage still rests on tt1.
        XCTAssertNil(armed(open, focused: "movie:tt2"))
        // A See All tile or an art-less folder: no committed title, the stage keeps tt1 (D5).
        XCTAssertNil(armed(open, focused: nil))
    }

    func testAFolderNeverArms() {
        let folder = "nuvio.folder:nuvio-folder://col/f1"
        XCTAssertNil(armed(open, resting: folder, shown: folder, folder: true, focused: folder))
    }
}
