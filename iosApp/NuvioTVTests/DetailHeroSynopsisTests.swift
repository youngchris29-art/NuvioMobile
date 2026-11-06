import XCTest
@testable import NuvioTV

/// C5 (A1.3): the Cinematic hero shows the Play/Resume target episode's synopsis for a series and
/// the title's own overview for a movie; the show overview is the fallback.
final class DetailHeroSynopsisTests: XCTestCase {
    private let show = "A family of detectives solves crimes."
    private let episodeText = "The detectives find a body in the lake."

    func testMovieShowsItsOverview() {
        let result = DetailHeroSynopsis.resolve(isSeries: false, showOverview: show,
                                                playTargetEpisodeOverview: nil, episodeSpoilerHidden: false)
        XCTAssertEqual(result, .init(text: show, isEpisode: false, season: nil, episode: nil))
    }

    func testMovieIgnoresAnyEpisodeText() {
        XCTAssertEqual(DetailHeroSynopsis.text(isSeries: false, showOverview: show,
                                               playTargetEpisodeOverview: episodeText, episodeSpoilerHidden: false),
                       show)
    }

    func testSeriesWithProgressShowsTheResumeEpisodeOverview() {
        let result = DetailHeroSynopsis.resolve(isSeries: true, showOverview: show,
                                                playTargetEpisodeOverview: episodeText, episodeSpoilerHidden: false,
                                                season: 2, episode: 3)
        XCTAssertEqual(result, .init(text: episodeText, isEpisode: true, season: 2, episode: 3))
    }

    /// No progress: Play targets the first (or next) episode, whose overview the hero shows.
    func testSeriesWithoutProgressShowsTheFirstEpisodeOverview() {
        let pilot = "Pilot: the family moves to town."
        XCTAssertEqual(DetailHeroSynopsis.text(isSeries: true, showOverview: show,
                                               playTargetEpisodeOverview: pilot, episodeSpoilerHidden: false),
                       pilot)
    }

    func testSeriesWithNoTargetYetFallsBackToTheShowOverview() {
        let result = DetailHeroSynopsis.resolve(isSeries: true, showOverview: show,
                                                playTargetEpisodeOverview: nil, episodeSpoilerHidden: false)
        XCTAssertEqual(result, .init(text: show, isEpisode: false, season: nil, episode: nil))
    }

    func testEpisodeWithMissingOverviewFallsBackToTheShowOverview() {
        for missing in ["", "   ", "\n\t "] {
            let result = DetailHeroSynopsis.resolve(isSeries: true, showOverview: show,
                                                    playTargetEpisodeOverview: missing, episodeSpoilerHidden: false,
                                                    season: 1, episode: 4)
            XCTAssertEqual(result?.text, show, "overview \(missing.debugDescription)")
            XCTAssertEqual(result?.isEpisode, false)
        }
    }

    func testSpoilerHiddenEpisodeFallsBackToTheShowOverview() {
        let hidden = EpisodeSpoilerRules.hidesSpoilers(settingOn: true, isWatched: false)
        XCTAssertTrue(hidden)
        let result = DetailHeroSynopsis.resolve(isSeries: true, showOverview: show,
                                                playTargetEpisodeOverview: episodeText, episodeSpoilerHidden: hidden,
                                                season: 2, episode: 3)
        XCTAssertEqual(result, .init(text: show, isEpisode: false, season: nil, episode: nil))
    }

    func testWatchedEpisodeIsNotSpoilerHidden() {
        let hidden = EpisodeSpoilerRules.hidesSpoilers(settingOn: true, isWatched: true)
        XCTAssertEqual(DetailHeroSynopsis.text(isSeries: true, showOverview: show,
                                               playTargetEpisodeOverview: episodeText, episodeSpoilerHidden: hidden),
                       episodeText)
    }

    func testNothingToShowIsNil() {
        XCTAssertNil(DetailHeroSynopsis.resolve(isSeries: true, showOverview: nil,
                                                playTargetEpisodeOverview: nil, episodeSpoilerHidden: false))
        XCTAssertNil(DetailHeroSynopsis.text(isSeries: false, showOverview: "",
                                             playTargetEpisodeOverview: nil, episodeSpoilerHidden: false))
    }

    func testEpisodeTextShowsEvenWhenTheShowHasNoOverview() {
        XCTAssertEqual(DetailHeroSynopsis.text(isSeries: true, showOverview: nil,
                                               playTargetEpisodeOverview: episodeText, episodeSpoilerHidden: false),
                       episodeText)
    }
}
