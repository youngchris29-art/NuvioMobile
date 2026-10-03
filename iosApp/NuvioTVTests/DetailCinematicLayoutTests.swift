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

    /// Review r1 #1: the slot is decided from settings alone, so it is the same before the meta
    /// load (no `tt…` id yet for a `tmdb:`/`kitsu:` item) as after it.
    func testRatingsSlotReservedFromSettingsOnly() {
        XCTAssertTrue(DetailRatings.reservesSlot(sectionRatings: true, mdbListActive: true))
        XCTAssertFalse(DetailRatings.reservesSlot(sectionRatings: false, mdbListActive: true))
        XCTAssertFalse(DetailRatings.reservesSlot(sectionRatings: true, mdbListActive: false))
        XCTAssertFalse(DetailRatings.reservesSlot(sectionRatings: false, mdbListActive: false))
    }

    /// Review r1 #1: pre-meta (slot reserved, no ratings yet) the ★ still shows; once MDBList fills
    /// the reserved slot the ★ steps aside; a title that never gets ratings keeps the ★.
    func testImdbStarWithReservedSlotBeforeAndAfterMeta() {
        let gate = DetailRatings.reservesSlot(sectionRatings: true, mdbListActive: true)
        // Pre-meta: preview's imdbRating, no ratings list yet.
        XCTAssertTrue(DetailRatings.showsImdbStar(sectionRatings: true, ratingsGateOn: gate, ratingCount: 0, imdbRating: "8.1"))
        // MDBList emission lands.
        XCTAssertFalse(DetailRatings.showsImdbStar(sectionRatings: true, ratingsGateOn: gate, ratingCount: 4, imdbRating: "8.1"))
        // Pre-meta with no rating at all: nothing to show.
        XCTAssertFalse(DetailRatings.showsImdbStar(sectionRatings: true, ratingsGateOn: gate, ratingCount: 0, imdbRating: nil))
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

    /// Review r1 #10: the button form never leaves the tree while it holds focus.
    func testTeaserButtonLatchWhileFocused() {
        XCTAssertTrue(DetailSynopsisTeaser.rendersAsButton(measuredTruncated: true, currentlyButton: false, teaserFocused: false))
        XCTAssertTrue(DetailSynopsisTeaser.rendersAsButton(measuredTruncated: false, currentlyButton: true, teaserFocused: true))
        XCTAssertFalse(DetailSynopsisTeaser.rendersAsButton(measuredTruncated: false, currentlyButton: true, teaserFocused: false))
        XCTAssertFalse(DetailSynopsisTeaser.rendersAsButton(measuredTruncated: false, currentlyButton: false, teaserFocused: true))
    }

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

    /// Gate 1 bug (Dune Part Two drew 3 lines): the slot is the MEASURED four-line height once the
    /// probe lands; `4 × UIFont.lineHeight` only until then.
    func testSynopsisResolvedSlot() {
        XCTAssertEqual(DetailSynopsisTeaser.resolvedSlotHeight(measuredFourLineHeight: 0, lineHeight: 30), 120)
        XCTAssertEqual(DetailSynopsisTeaser.resolvedSlotHeight(measuredFourLineHeight: 126.8, lineHeight: 30), 127)
        XCTAssertEqual(DetailSynopsisTeaser.resolvedSlotHeight(measuredFourLineHeight: 127, lineHeight: 30), 127)
        XCTAssertEqual(DetailSynopsisTeaser.resolvedSlotHeight(measuredFourLineHeight: -1, lineHeight: 31.32), 126)
    }

    func testSynopsisTruncationAgainstTheSlot() {
        // Four rendered lines of a 31.7 pt pitch fill a 127 pt slot exactly: not truncated.
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 126.8, slotHeight: 127))
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 128, slotHeight: 127))
        XCTAssertTrue(DetailSynopsisTeaser.isTruncated(fullTextHeight: 158.5, slotHeight: 127))
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 0, slotHeight: 127))
        XCTAssertFalse(DetailSynopsisTeaser.isTruncated(fullTextHeight: 300, slotHeight: 0))
    }

    // MARK: - Credits

    func testCredits() {
        let basic = DetailCredits.make(cast: ["A", "B", "C", "D"], director: ["X"], writer: [], isSeries: false)
        XCTAssertEqual(basic.castNames, "A, B, C")
        XCTAssertEqual(basic.crewLabel, .directedBy)
        XCTAssertEqual(basic.crewNames, "X")

        let crewInCast = DetailCredits.make(cast: ["X", "W", "A", "B", "C"], director: ["X"], writer: ["W"], isSeries: false)
        XCTAssertEqual(crewInCast.castNames, "A, B, C")

        // Review r1 #6: only the leading crew run is dropped; an actor-director billed in the cast
        // proper keeps their place.
        let actorDirector = DetailCredits.make(cast: ["X", "A", "X", "B"], director: ["X"], writer: [], isSeries: false)
        XCTAssertEqual(actorDirector.castNames, "A, X, B")
        let noPrepend = DetailCredits.make(cast: ["A", "W", "B"], director: [], writer: ["W"], isSeries: false)
        XCTAssertEqual(noPrepend.castNames, "A, W, B")
        // Director prepended, then the same person top-billed as an actor.
        let starDirector = DetailCredits.make(cast: ["X", "X", "A"], director: ["X"], writer: [], isSeries: false)
        XCTAssertEqual(starDirector.castNames, "X, A")

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

    /// Review r1 #3: percentage-only progress (Trakt/Simkl, `lastPositionMs == 0`) offers Start Over.
    func testStartOverPercentOnlyProgress() {
        // Movie: fraction only.
        XCTAssertTrue(DetailStartOver.isAvailable(isSeries: false, seriesResumePositionMs: nil,
                                                  movieEntryPositionMs: 0, movieEntryFraction: 0.42,
                                                  movieEntryResumable: true))
        // Movie: fraction but finished.
        XCTAssertFalse(DetailStartOver.isAvailable(isSeries: false, seriesResumePositionMs: nil,
                                                   movieEntryPositionMs: 0, movieEntryFraction: 0.95,
                                                   movieEntryResumable: false))
        // Movie: nothing saved.
        XCTAssertFalse(DetailStartOver.isAvailable(isSeries: false, seriesResumePositionMs: nil,
                                                   movieEntryPositionMs: 0, movieEntryFraction: 0,
                                                   movieEntryResumable: true))
        // Series: no resume position, but the primary action's episode has a resumable fraction.
        XCTAssertTrue(DetailStartOver.isAvailable(isSeries: true, seriesResumePositionMs: nil,
                                                  seriesEntryFraction: 0.3, seriesEntryResumable: true,
                                                  movieEntryPositionMs: nil, movieEntryResumable: false))
        XCTAssertFalse(DetailStartOver.isAvailable(isSeries: true, seriesResumePositionMs: nil,
                                                   seriesEntryFraction: 0.3, seriesEntryResumable: false,
                                                   movieEntryPositionMs: nil, movieEntryResumable: false))
        XCTAssertFalse(DetailStartOver.isAvailable(isSeries: true, seriesResumePositionMs: nil,
                                                   seriesEntryFraction: 0, seriesEntryResumable: true,
                                                   movieEntryPositionMs: nil, movieEntryResumable: false))
    }

    // MARK: - Late Play focus (review r1 #2)

    func testLatePlayFocusUserMove() {
        XCTAssertFalse(DetailLatePlayFocus.isUserMove(old: nil, new: .watched))
        XCTAssertFalse(DetailLatePlayFocus.isUserMove(old: .watched, new: nil))
        XCTAssertFalse(DetailLatePlayFocus.isUserMove(old: .watched, new: .watched))
        XCTAssertTrue(DetailLatePlayFocus.isUserMove(old: .watched, new: .library))
        XCTAssertTrue(DetailLatePlayFocus.isUserMove(old: .teaser, new: .watched))
    }

    func testLatePlayFocusClaim() {
        func claim(cinematic: Bool = true, claimed: Bool = false, interacted: Bool = false, moved: Bool = false,
                   inHero: Bool = true, focus: DetailHeroFocus? = .watched) -> Bool {
            DetailLatePlayFocus.shouldClaim(isCinematic: cinematic, alreadyClaimed: claimed, userInteracted: interacted,
                                            userMovedInHero: moved, heroHasFocus: inHero, currentFocus: focus)
        }
        XCTAssertTrue(claim())
        XCTAssertTrue(claim(focus: .teaser))
        XCTAssertFalse(claim(cinematic: false))
        XCTAssertFalse(claim(claimed: true))
        XCTAssertFalse(claim(interacted: true))
        XCTAssertFalse(claim(moved: true))
        XCTAssertFalse(claim(inHero: false))
        XCTAssertFalse(claim(focus: .play))
    }

    // MARK: - Dim ramp

    func testDimRampDistance() {
        XCTAssertEqual(DetailDim.rampDistance(layout: .classic, heroHeight: 900), 400)
        XCTAssertEqual(DetailDim.rampDistance(layout: .cinematic, heroHeight: 627), 627)
        XCTAssertEqual(DetailDim.rampDistance(layout: .cinematic, heroHeight: 300), 400)
    }

    /// W2-A: Classic keeps `offset − inset` (today's formula); Cinematic measures from the real top
    /// (`offset + inset`, the top resting at `offset == −inset`).
    func testDimScrolledDistance() {
        XCTAssertEqual(DetailDim.scrolledDistance(layout: .classic, contentOffset: 600, contentInsetTop: 157), 443)
        XCTAssertEqual(DetailDim.scrolledDistance(layout: .cinematic, contentOffset: -157, contentInsetTop: 157), 0)
        XCTAssertEqual(DetailDim.scrolledDistance(layout: .cinematic, contentOffset: 600, contentInsetTop: 157), 757)
        // Hero 687 on the fixture: the hero-exit rest (first row at screenRest 108) is past the
        // ramp, so the dim saturates and the 0.80 trailer latch closes.
        let heroHeight: CGFloat = 687
        let firstRowTop = 60 + heroHeight + 36
        let exitOffset = DetailRowAnchorMirror.expectedOffset(rowTop: firstRowTop, inset: 157)
        let dim = DetailDim.value(scrolled: DetailDim.scrolledDistance(layout: .cinematic, contentOffset: exitOffset,
                                                                       contentInsetTop: 157),
                                  rampDistance: DetailDim.rampDistance(layout: .cinematic, heroHeight: heroHeight))
        XCTAssertEqual(dim, DetailDim.ceiling, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(dim, 0.80)
        // At the top: no dim.
        XCTAssertEqual(DetailDim.value(scrolled: DetailDim.scrolledDistance(layout: .cinematic, contentOffset: -157,
                                                                            contentInsetTop: 157),
                                       rampDistance: 687), 0, accuracy: 1e-9)
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

/// `DetailRowAnchor.scrollTarget`/`expectedOffset` restated for `testDimScrolledDistance` (rest at
/// `screenRest` 108): offset = rowTop + inset − 108 − inset = rowTop − 108.
private enum DetailRowAnchorMirror {
    static func expectedOffset(rowTop: CGFloat, inset: CGFloat) -> CGFloat {
        (rowTop + inset - 108) - inset
    }
}
