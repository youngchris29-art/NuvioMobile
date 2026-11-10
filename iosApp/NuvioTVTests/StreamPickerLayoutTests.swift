import XCTest
import SharedCore
@testable import NuvioTV

/// Stream picker A, P1 (`docs/stream-picker-addons-plan-2026-10-25.md` §2): the pure decisions
/// behind the two-pane layout — which art the backdrop shows, the info panel's facts and progress
/// lines, and the scrim's stops — pinned without a view host.
final class StreamPickerLayoutTests: XCTestCase {

    // MARK: - Backdrop art

    func testEpisodeStillLeadsWithTheBackdropAsFallback() {
        let plan = StreamPickerBackdrop.plan(
            episodeStill: "https://img/still.jpg",
            background: "https://images.metahub.space/background/medium/tt1/img",
            poster: "https://img/poster.jpg"
        )
        XCTAssertEqual(plan.primary, "https://img/still.jpg")
        XCTAssertEqual(plan.fallback, "https://images.metahub.space/background/medium/tt1/img")
    }

    func testBackdropIsUsedAsGivenNotTheLargerRendition() {
        // Review r1: a 1280 px decode under a scrim must not pull TMDB `original` on a cold cache.
        let plan = StreamPickerBackdrop.plan(
            episodeStill: nil,
            background: "https://image.tmdb.org/t/p/w1280/abc.jpg",
            poster: "https://img/poster.jpg"
        )
        XCTAssertEqual(plan.primary, "https://image.tmdb.org/t/p/w1280/abc.jpg")
        XCTAssertNil(plan.fallback)
    }

    func testPosterStandsInWhenThereIsNoBackdrop() {
        let plan = StreamPickerBackdrop.plan(episodeStill: "", background: nil, poster: "https://img/poster.jpg")
        XCTAssertEqual(plan.primary, "https://img/poster.jpg")
        XCTAssertNil(plan.fallback)
    }

    func testNoArtAtAll() {
        let plan = StreamPickerBackdrop.plan(episodeStill: nil, background: "", poster: nil)
        XCTAssertNil(plan.primary)
        XCTAssertNil(plan.fallback)
    }

    // MARK: - Title logo

    func testPassedLogoWinsOverTheDetailsRecord() {
        XCTAssertEqual(StreamPickerLogo.resolve(passed: "https://img/passed.png", peeked: "https://img/record.png"),
                       "https://img/passed.png")
    }

    func testDetailsRecordLogoStandsInWhenNoneWasPassed() {
        // Continue Watching entries saved without a logo, Top Shelf links.
        XCTAssertEqual(StreamPickerLogo.resolve(passed: nil, peeked: "https://img/record.png"), "https://img/record.png")
        XCTAssertEqual(StreamPickerLogo.resolve(passed: "", peeked: "https://img/record.png"), "https://img/record.png")
    }

    func testNoLogoAnywhereKeepsTheTextTitle() {
        XCTAssertNil(StreamPickerLogo.resolve(passed: nil, peeked: nil))
        XCTAssertNil(StreamPickerLogo.resolve(passed: "", peeked: ""))
    }

    // MARK: - Facts line

    func testEpisodeFactsLineCarriesMarkerNameAndRuntime() {
        let episodes = [episode(season: 1, episode: 3, title: "Double Cross")]
        let line = StreamPickerInfoPanel.factsLine(
            season: 1, episode: 3, episodes: episodes,
            meta: PlaybackMeta(year: "2024", runtime: "45 min", genres: ["Drama"])
        )
        XCTAssertEqual(line, "S1 \u{00B7} E3 \u{00B7} Double Cross \u{00B7} 45 min")
    }

    func testEpisodeFactsLineWithoutANameOrRuntime() {
        let line = StreamPickerInfoPanel.factsLine(season: 2, episode: 7, episodes: [], meta: nil)
        XCTAssertEqual(line, "S2 \u{00B7} E7")
    }

    func testEpisodeRuntimeBeatsTheTitleRuntime() {
        // Review r1: the episode's own minutes win over the series-level runtime string.
        let episodes = [episode(season: 1, episode: 3, title: "Double Cross", runtime: 52)]
        let line = StreamPickerInfoPanel.factsLine(
            season: 1, episode: 3, episodes: episodes,
            meta: PlaybackMeta(runtime: "45 min")
        )
        XCTAssertEqual(line, "S1 \u{00B7} E3 \u{00B7} Double Cross \u{00B7} 52 min")
    }

    func testMovieFactsLineIsGenresThenYear() {
        let line = StreamPickerInfoPanel.factsLine(
            season: nil, episode: nil, episodes: [],
            meta: PlaybackMeta(year: "2024", runtime: "166 min", genres: ["Sci-Fi", "Adventure", "Drama", "Action"])
        )
        XCTAssertEqual(line, "Sci-Fi \u{00B7} Adventure \u{00B7} Drama \u{00B7} 2024")
    }

    func testMovieFactsLineIsNilWithNoMeta() {
        XCTAssertNil(StreamPickerInfoPanel.factsLine(season: nil, episode: nil, episodes: [], meta: nil))
        XCTAssertNil(StreamPickerInfoPanel.factsLine(season: nil, episode: nil, episodes: [], meta: PlaybackMeta()))
    }

    // MARK: - Progress line

    func testProgressLineBeforeTheFirstEmissionAndWhileLoading() {
        // Before the repository has said anything (review r1): the plain loading line, no count.
        XCTAssertEqual(StreamPickerInfoPanel.progressText(StreamFanOutProgress()), "Finding streams\u{2026}")
        XCTAssertEqual(
            StreamPickerInfoPanel.progressText(StreamFanOutProgress(answered: 0, expected: 0, sources: 0, isLoading: true, hasOutcome: true)),
            "Finding streams\u{2026}"
        )
        XCTAssertEqual(
            StreamPickerInfoPanel.progressText(StreamFanOutProgress(answered: 3, expected: 4, sources: 90, addonsWithSources: 2, isLoading: true, hasOutcome: true)),
            "Finding streams\u{2026} 3 of 4"
        )
    }

    func testProgressLineWhenDone() {
        // Counts the add-ons that returned sources, not every add-on asked.
        XCTAssertEqual(
            StreamPickerInfoPanel.progressText(StreamFanOutProgress(answered: 4, expected: 4, sources: 155, addonsWithSources: 3, isLoading: false, hasOutcome: true)),
            "155 sources from 3 add-ons"
        )
        XCTAssertEqual(
            StreamPickerInfoPanel.progressText(StreamFanOutProgress(answered: 1, expected: 1, sources: 1, addonsWithSources: 1, isLoading: false, hasOutcome: true)),
            "1 source from 1 add-on"
        )
        // Done with nothing listable (no add-ons, all failed, all filtered): the reason sits beside the list.
        XCTAssertEqual(
            StreamPickerInfoPanel.progressText(StreamFanOutProgress(answered: 2, expected: 2, sources: 0, addonsWithSources: 0, isLoading: false, hasOutcome: true)),
            "No sources"
        )
        XCTAssertEqual(
            StreamPickerInfoPanel.progressText(StreamFanOutProgress(answered: 0, expected: 0, sources: 0, addonsWithSources: 0, isLoading: false, hasOutcome: true)),
            "No sources"
        )
    }

    // MARK: - Scrim

    func testScrimIsSolidAtBothEdgesAndOpenInTheMiddle() {
        let stops = StreamPickerScrimStops.horizontal
        XCTAssertEqual(stops.first?.opacity, 1.0)
        XCTAssertEqual(stops.last?.opacity, 1.0)
        XCTAssertEqual(stops.map(\.location), stops.map(\.location).sorted(), "stops must be ordered")
        XCTAssertEqual(stops.min(by: { $0.opacity < $1.opacity })?.location, 0.5)
        // Symmetric: both panes read the same.
        XCTAssertEqual(stops.map(\.opacity), stops.reversed().map(\.opacity))
    }

    func testBottomBandStartsBelowTheMiddle() {
        let stops = StreamPickerScrimStops.vertical
        XCTAssertEqual(stops.first?.opacity, 0)
        XCTAssertGreaterThan(stops[1].location, 0.5)
        XCTAssertEqual(stops.last?.opacity, 0.6)
    }

    // MARK: - Builders

    private func episode(season: Int32, episode: Int32, title: String, runtime: Int32? = nil) -> MetaVideo {
        MetaVideo(
            id: "tt1:\(season):\(episode)", title: title, released: nil, available: true,
            thumbnail: nil, seasonPoster: nil,
            season: KotlinInt(int: season), episode: KotlinInt(int: episode),
            overview: nil, runtime: runtime.map { KotlinInt(int: $0) }, rating: nil, streams: []
        )
    }
}
