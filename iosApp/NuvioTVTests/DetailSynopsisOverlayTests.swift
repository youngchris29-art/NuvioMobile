import XCTest
@testable import NuvioTV

/// A4.2 (C12): the compact synopsis overlay's info line and text-box height, and the About
/// section's show overview block.
final class DetailSynopsisOverlayTests: XCTestCase {
    private func info(year: String? = "2021", runtime: String? = "2h 35m",
                      genres: [String] = ["Science Fiction", "Adventure"],
                      ageRating: String? = "PG-13", imdbRating: String? = "8.04") -> DetailMetaLineModel {
        DetailMetaLineModel(year: year, runtime: runtime, genres: genres, ageRating: ageRating, imdbRating: imdbRating)
    }

    // MARK: - Info line

    func testInfoPartsInOrder() {
        XCTAssertEqual(DetailSynopsisOverlay.infoParts(info()),
                       ["2021", "2h 35m", "Science Fiction, Adventure", "PG-13"])
    }

    func testInfoPartsNilInfoIsEmpty() {
        XCTAssertEqual(DetailSynopsisOverlay.infoParts(nil), [])
        XCTAssertNil(DetailSynopsisOverlay.imdbScore(nil, ratingsOn: true))
    }

    func testInfoPartsSkipBlankValues() {
        let parts = DetailSynopsisOverlay.infoParts(info(year: "  ", runtime: nil, genres: ["", " Drama "], ageRating: ""))
        XCTAssertEqual(parts, ["Drama"])
    }

    func testInfoPartsCapGenresAtThree() {
        let parts = DetailSynopsisOverlay.infoParts(info(year: nil, runtime: nil,
                                                         genres: ["A", "B", "C", "D"], ageRating: nil))
        XCTAssertEqual(parts, ["A, B, C"])
    }

    func testImdbScoreOneDecimalAndBlank() {
        XCTAssertEqual(DetailSynopsisOverlay.imdbScore(info(imdbRating: "8.04"), ratingsOn: true), "8.0")
        XCTAssertEqual(DetailSynopsisOverlay.imdbScore(info(imdbRating: "7"), ratingsOn: true), "7.0")
        XCTAssertNil(DetailSynopsisOverlay.imdbScore(info(imdbRating: " "), ratingsOn: true))
        XCTAssertNil(DetailSynopsisOverlay.imdbScore(info(imdbRating: nil), ratingsOn: true))
    }

    /// Ratings section off: the overlay hides the score, like the hero's IMDb star (D10).
    func testImdbScoreHiddenWhenRatingsOff() {
        XCTAssertNil(DetailSynopsisOverlay.imdbScore(info(imdbRating: "8.04"), ratingsOn: false))
    }

    // MARK: - Text box height

    func testTextBoxTakesMaxBeforeMeasurement() {
        XCTAssertEqual(DetailSynopsisOverlay.textBoxHeight(contentHeight: 0, maxHeight: 560), 560)
    }

    func testTextBoxHugsShortText() {
        XCTAssertEqual(DetailSynopsisOverlay.textBoxHeight(contentHeight: 120.2, maxHeight: 560), 121)
    }

    func testTextBoxStopsAtMax() {
        XCTAssertEqual(DetailSynopsisOverlay.textBoxHeight(contentHeight: 1400, maxHeight: 560), 560)
    }

    // MARK: - About overview

    func testAboutOverviewTrimsAndDropsBlank() {
        XCTAssertEqual(DetailAboutOverview.text("  A chemistry teacher.\n"), "A chemistry teacher.")
        XCTAssertNil(DetailAboutOverview.text("   "))
        XCTAssertNil(DetailAboutOverview.text(nil))
    }

    func testAboutHasContentFromOverviewAlone() {
        XCTAssertTrue(DetailAboutOverview.hasContent(rows: [], overview: "A show."))
        XCTAssertFalse(DetailAboutOverview.hasContent(rows: [], overview: " "))
        XCTAssertTrue(DetailAboutOverview.hasContent(rows: [DetailAboutRow(label: "Country", value: "US")], overview: nil))
    }
}
