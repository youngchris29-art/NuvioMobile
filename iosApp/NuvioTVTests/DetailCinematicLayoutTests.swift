import XCTest
@testable import NuvioTV

/// FEAT-35 (Detail revamp "Cinematic Clean"): the pure rules behind `DetailCinematicHero` —
/// hero height, layout resolution, ratings order/format, the synopsis truncation decision,
/// credits, the meta line, Start Over, the IMDb ★ rule (D10) and the dim ramp W2-A consumes.
final class DetailCinematicLayoutTests: XCTestCase {

    // MARK: - Geometry

    func testHeroHeight() {
        // containerHeight − 60 (page padding) − 36 (row gap) − 140 (peek), floored at 520.
        XCTAssertEqual(DetailCinematicLayout.heroHeight(containerHeight: 1080), 844)
        XCTAssertEqual(DetailCinematicLayout.heroHeight(containerHeight: 923), 687)
        XCTAssertEqual(DetailCinematicLayout.heroHeight(containerHeight: 0), 520)
        XCTAssertEqual(DetailCinematicLayout.heroHeight(containerHeight: 700), 520)
        XCTAssertEqual(DetailCinematicLayout.heroHeight(containerHeight: 756), 520)
        XCTAssertEqual(DetailCinematicLayout.heroHeight(containerHeight: 757), 521)
    }

    func testSlotConstants() {
        XCTAssertEqual(DetailCinematicLayout.textColumnMaxWidth, 900)
        XCTAssertEqual(DetailCinematicLayout.creditsMaxWidth, 640)
        XCTAssertEqual(DetailCinematicLayout.logoSlotHeight, 180)
        XCTAssertEqual(DetailCinematicLayout.logoMaxWidth, 600)
        XCTAssertEqual(DetailCinematicLayout.metaLineHeight, 40)
        XCTAssertEqual(DetailCinematicLayout.ratingsSlotHeight, 44)
        XCTAssertEqual(DetailCinematicLayout.peekBand, 140)
        XCTAssertEqual(DetailCinematicLayout.heroMinimumHeight, 520)
    }

    /// Correction F16: the nonisolated mirrors must match the `Theme` tokens they copy.
    @MainActor
    func testThemeMirrors() {
        XCTAssertEqual(DetailCinematicLayout.screenPadding, Theme.Spacing.screen)
        XCTAssertEqual(DetailCinematicLayout.pageRowSpacing, Theme.Spacing.lg + Theme.Spacing.sm)
    }

    // MARK: - Layout key

    func testLayoutResolve() {
        XCTAssertEqual(DetailLayout.resolve("classic"), .classic)
        XCTAssertEqual(DetailLayout.resolve("cinematic"), .cinematic)
        XCTAssertEqual(DetailLayout.resolve(""), .cinematic)
        XCTAssertEqual(DetailLayout.resolve("foo"), .cinematic)
        XCTAssertEqual(DetailSettingsKeys.layout, "detail_layout")
        XCTAssertEqual(DetailSettingsKeys.sectionRatings, "detail_section_ratings")
        XCTAssertEqual(DetailSettingsKeys.hideEpisodeSpoilers, "detail_hide_episode_spoilers")
    }

    // MARK: - Ratings

    private func inputs(_ pairs: [(String, Double)]) -> [DetailRatingInput] {
        pairs.map { DetailRatingInput(source: $0.0, value: $0.1) }
    }

    func testRatingsOrderedLeadingFirstWithFormats() {
        let out = DetailRatings.ordered(inputs([("tmdb", 72), ("imdb", 7.4), ("letterboxd", 3.62),
                                                ("tomatoes", 87.6), ("trakt", 76), ("metacritic", 71.2)]))
        XCTAssertEqual(out.map(\.source), ["imdb", "tomatoes", "metacritic", "trakt", "letterboxd", "tmdb"])
        XCTAssertEqual(out.map(\.value), ["7.4", "88%", "71", "76%", "3.6", "72%"])
        XCTAssertEqual(out.map(\.label), ["IMDb", "Rotten Tomatoes", "Metacritic", "Trakt", "Letterboxd", "TMDB"])
    }

    func testRatingsMdbListOrder() {
        let order = ["imdb", "tmdb", "tomatoes", "metacritic", "trakt", "letterboxd", "audience", "mal"]
        let out = DetailRatings.ordered(inputs(order.map { ($0, 50) }))
        XCTAssertEqual(out.map(\.source),
                       ["imdb", "tomatoes", "metacritic", "trakt", "letterboxd", "tmdb", "audience", "mal"])
    }

    func testRatingsEmptyDedupeAndUnknown() {
        XCTAssertEqual(DetailRatings.ordered([]), [])
        let dupes = DetailRatings.ordered(inputs([("imdb", 7), ("imdb", 8)]))
        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(dupes.first?.value, "7.0")
        let unknown = DetailRatings.ordered(inputs([("foo", 5.55), ("tmdb", 60)]))
        // Sources outside the leading five keep MDBList's own order.
        XCTAssertEqual(unknown.map(\.source), ["foo", "tmdb"])
        XCTAssertEqual(unknown.first?.label, "Foo")
    }

    func testRatingsFormats() {
        XCTAssertEqual(DetailRatings.formatted(source: "mal", value: 8.13), "8.1")
        XCTAssertEqual(DetailRatings.formatted(source: "audience", value: 90), "90%")
        XCTAssertEqual(DetailRatings.formatted(source: "unknown", value: 72.4), "72")
    }

    func testUsableImdbId() {
        XCTAssertTrue(DetailRatings.hasUsableImdbId(metaId: "tt0111161", fallbackId: nil, imdbId: nil))
        XCTAssertTrue(DetailRatings.hasUsableImdbId(metaId: "tmdb:278", fallbackId: "tmdb:278", imdbId: "tt0111161"))
        XCTAssertTrue(DetailRatings.hasUsableImdbId(metaId: nil, fallbackId: "tt0944947:1:1", imdbId: nil))
        XCTAssertFalse(DetailRatings.hasUsableImdbId(metaId: "tmdb:278", fallbackId: "kitsu:1", imdbId: ""))
        XCTAssertFalse(DetailRatings.hasUsableImdbId(metaId: nil, fallbackId: nil, imdbId: nil))
        XCTAssertFalse(DetailRatings.hasUsableImdbId(metaId: "tt", fallbackId: nil, imdbId: nil))
    }

    /// D10: Ratings OFF hides the ★; ON shows it only while the strip is off or empty.
    func testImdbStarRule() {
        XCTAssertFalse(DetailRatings.showsImdbStar(sectionRatings: false, ratingsGateOn: false, ratingCount: 0, imdbRating: "7.4"))
        XCTAssertTrue(DetailRatings.showsImdbStar(sectionRatings: true, ratingsGateOn: false, ratingCount: 3, imdbRating: "7.4"))
        XCTAssertTrue(DetailRatings.showsImdbStar(sectionRatings: true, ratingsGateOn: true, ratingCount: 0, imdbRating: "7.4"))
        XCTAssertFalse(DetailRatings.showsImdbStar(sectionRatings: true, ratingsGateOn: true, ratingCount: 2, imdbRating: "7.4"))
        XCTAssertFalse(DetailRatings.showsImdbStar(sectionRatings: true, ratingsGateOn: false, ratingCount: 0, imdbRating: nil))
        XCTAssertFalse(DetailRatings.showsImdbStar(sectionRatings: true, ratingsGateOn: false, ratingCount: 0, imdbRating: ""))
    }

    // MARK: - Synopsis teaser

    func testSynopsisTruncation() {
        XCTAssertEqual(DetailSynopsisTeaser.slotHeight(lineHeight: 30), 120)
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 120, lineHeight: 30))
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 121, lineHeight: 30))
        XCTAssertTrue(DetailSynopsisTeaser.isTruncated(fullTextHeight: 121.5, lineHeight: 30))
        XCTAssertTrue(DetailSynopsisTeaser.isTruncated(fullTextHeight: 150, lineHeight: 30))
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 0, lineHeight: 30))
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 150, lineHeight: 0))
        // Open Sans caption1 (scaled) ≈ 31.32 pt.
        XCTAssertEqual(DetailSynopsisTeaser.slotHeight(lineHeight: 31.32), 126)
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 126, lineHeight: 31.32))
        XCTAssertTrue(DetailSynopsisTeaser.isTruncated(fullTextHeight: 127, lineHeight: 31.32))
    }

    // MARK: - Credits

    func testCredits() {
        let basic = DetailCredits.make(cast: ["A", "B", "C", "D"], director: ["X"], writer: [], isSeries: false)
        XCTAssertEqual(basic.castNames, "A, B, C")
        XCTAssertEqual(basic.crewLabel, .directedBy)
        XCTAssertEqual(basic.crewNames, "X")

        let crewInCast = DetailCredits.make(cast: ["X", "W", "A", "B", "C"], director: ["X"], writer: ["W"], isSeries: false)
        XCTAssertEqual(crewInCast.castNames, "A, B, C")

        XCTAssertEqual(DetailCredits.make(cast: [], director: ["X"], writer: [], isSeries: true).crewLabel, .createdBy)
        XCTAssertEqual(DetailCredits.make(cast: [], director: ["X", "Y", "Z"], writer: [], isSeries: false).crewNames, "X, Y")

        let empty = DetailCredits.make(cast: [], director: [], writer: [], isSeries: false)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.crewLabel)

        XCTAssertEqual(DetailCredits.make(cast: ["", " ", "A"], director: [], writer: [], isSeries: false).castNames, "A")
    }

    // MARK: - Meta line

    func testMetaLineParts() {
        XCTAssertEqual(DetailMetaLine.textParts(year: "2026", runtime: "1h 50m", genres: ["Action", "Comedy", "Drama"]),
                       ["2026", "1h 50m", "Action, Comedy"])
        XCTAssertEqual(DetailMetaLine.textParts(year: nil, runtime: "", genres: []), [])
    }

    // MARK: - Start Over

    func testStartOverAvailability() {
        XCTAssertTrue(DetailStartOver.isAvailable(isSeries: true, seriesResumePositionMs: 120_000,
                                                  movieEntryPositionMs: nil, movieEntryResumable: false))
        XCTAssertFalse(DetailStartOver.isAvailable(isSeries: true, seriesResumePositionMs: nil,
                                                   movieEntryPositionMs: nil, movieEntryResumable: false))
        XCTAssertFalse(DetailStartOver.isAvailable(isSeries: true, seriesResumePositionMs: 0,
                                                   movieEntryPositionMs: nil, movieEntryResumable: false))
        XCTAssertTrue(DetailStartOver.isAvailable(isSeries: false, seriesResumePositionMs: nil,
                                                  movieEntryPositionMs: 5_000, movieEntryResumable: true))
        XCTAssertFalse(DetailStartOver.isAvailable(isSeries: false, seriesResumePositionMs: nil,
                                                   movieEntryPositionMs: 5_000, movieEntryResumable: false))
        XCTAssertFalse(DetailStartOver.isAvailable(isSeries: false, seriesResumePositionMs: nil,
                                                   movieEntryPositionMs: nil, movieEntryResumable: true))
    }

    // MARK: - Dim ramp

    func testDimRampDistance() {
        XCTAssertEqual(DetailDim.rampDistance(layout: .classic, heroHeight: 900), 400)
        XCTAssertEqual(DetailDim.rampDistance(layout: .cinematic, heroHeight: 627), 627)
        XCTAssertEqual(DetailDim.rampDistance(layout: .cinematic, heroHeight: 300), 400)
    }

    func testDimValue() {
        XCTAssertEqual(DetailDim.value(scrolled: 0, rampDistance: 400), 0, accuracy: 1e-9)
        XCTAssertEqual(DetailDim.value(scrolled: 100, rampDistance: 400), 0.20, accuracy: 1e-9)
        XCTAssertEqual(DetailDim.value(scrolled: 400, rampDistance: 400), 0.85, accuracy: 1e-9)
        XCTAssertEqual(DetailDim.value(scrolled: 1000, rampDistance: 400), 0.85, accuracy: 1e-9)
        XCTAssertEqual(DetailDim.value(scrolled: -50, rampDistance: 400), 0, accuracy: 1e-9)
        XCTAssertEqual(DetailDim.value(scrolled: 627, rampDistance: 627), 0.85, accuracy: 1e-9)
    }
}
