import XCTest
@testable import NuvioTV

/// FEAT-35 (P1 §G): the Cinematic About section's rows — order, the series label, blank skipping,
/// and the Ratings row gate (D10). Labels are compared through `String(localized:)` so the test
/// holds in any test-runner language.
final class DetailAboutRowsTests: XCTestCase {
    private let ratings = [
        DetailRatingEntry(source: "imdb", label: "IMDb", value: "7.4"),
        DetailRatingEntry(source: "tomatoes", label: "Rotten Tomatoes", value: "88%"),
        DetailRatingEntry(source: "metacritic", label: "Metacritic", value: "71"),
    ]

    private func make(director: [String] = ["Denis Villeneuve"], writer: [String] = ["Jon Spaihts", "Denis Villeneuve"],
                      studios: [String] = ["Legendary"], networks: [String] = ["HBO"],
                      country: String? = "United States", language: String? = "English",
                      status: String? = "Released", awards: String? = "6 Oscars",
                      ratings: [DetailRatingEntry]? = nil, showRatings: Bool = true,
                      isSeries: Bool = false) -> [DetailAboutRow] {
        DetailAboutRows.make(director: director, writer: writer, studios: studios, networks: networks,
                             country: country, language: language, status: status, awards: awards,
                             ratings: ratings ?? self.ratings, showRatings: showRatings, isSeries: isSeries)
    }

    func testAllFieldsInOrder() {
        let rows = make()
        XCTAssertEqual(rows.map(\.label), [
            String(localized: "Director"), String(localized: "Writers"), String(localized: "Studios"),
            String(localized: "Network"), String(localized: "Country"), String(localized: "Language"),
            String(localized: "Status"), String(localized: "Awards"), String(localized: "Ratings"),
        ])
        XCTAssertEqual(rows[0].value, "Denis Villeneuve")
        XCTAssertEqual(rows[1].value, "Jon Spaihts, Denis Villeneuve")
        XCTAssertEqual(rows[7].value, "6 Oscars")
    }

    func testSeriesReadsCreatedBy() {
        XCTAssertEqual(make(isSeries: true).first?.label, String(localized: "Created by"))
    }

    func testBlankAndEmptyValuesAreSkipped() {
        let rows = make(director: [" ", ""], writer: [], studios: ["", "A24"], networks: [],
                        country: "  ", language: nil, status: "", awards: nil, ratings: [])
        XCTAssertEqual(rows.map(\.label), [String(localized: "Studios")])
        XCTAssertEqual(rows.first?.value, "A24")
    }

    func testRatingsHiddenWhenTheToggleIsOff() {
        XCTAssertFalse(make(showRatings: false).contains { $0.label == String(localized: "Ratings") })
    }

    func testRatingsJoinedInStripOrder() {
        let value = make().last?.value
        XCTAssertEqual(value, "IMDb 7.4 \u{00B7} Rotten Tomatoes 88% \u{00B7} Metacritic 71")
    }

    func testEverythingEmptyIsNoRows() {
        XCTAssertEqual(make(director: [], writer: [], studios: [], networks: [], country: nil, language: nil,
                            status: nil, awards: nil, ratings: []), [])
    }

    // MARK: - Status values (beta.19-rc1 verdict, D1, BUG-137)

    /// Steven's French screenshot read "Statut Released" / "Statut Ended": the label translated, the
    /// value did not. Every known TMDB / add-on status word maps to a `String(localized:)` key, in
    /// any case and with surrounding whitespace. Compared through `String(localized:)` so the test
    /// holds in any test-runner language.
    func testStatusKnownValuesMap() {
        let expected: [(raw: String, key: String)] = [
            ("Released", String(localized: "Released")),
            ("released", String(localized: "Released")),
            ("  RELEASED  ", String(localized: "Released")),
            ("Ended", String(localized: "Ended")),
            ("Returning Series", String(localized: "Returning Series")),
            ("returning series", String(localized: "Returning Series")),
            ("Continuing", String(localized: "Continuing")),
            ("Canceled", String(localized: "Canceled")),
            ("Cancelled", String(localized: "Canceled")),
            ("In Production", String(localized: "In Production")),
            ("Planned", String(localized: "Planned")),
            ("Post Production", String(localized: "Post Production")),
            ("Rumored", String(localized: "Rumored")),
            ("Pilot", String(localized: "Pilot")),
        ]
        for (raw, key) in expected {
            XCTAssertEqual(DetailStatusText.localized(raw), key, "status '\(raw)'")
        }
        // And it reaches the Status row of the About table.
        let row = make(status: "Ended").first { $0.label == String(localized: "Status") }
        XCTAssertEqual(row?.value, String(localized: "Ended"))
    }

    /// An add-on's own wording is shown as given (trimmed), never dropped or rewritten.
    func testStatusUnknownPassesThrough() {
        XCTAssertEqual(DetailStatusText.localized("Hiatus"), "Hiatus")
        XCTAssertEqual(DetailStatusText.localized("  On Hold "), "On Hold")
        XCTAssertEqual(make(status: "Hiatus").first { $0.label == String(localized: "Status") }?.value, "Hiatus")
    }

    func testStatusNilAndBlank() {
        XCTAssertNil(DetailStatusText.localized(nil))
        XCTAssertNil(DetailStatusText.localized(""))
        XCTAssertNil(DetailStatusText.localized("   \n "))
        XCTAssertFalse(make(status: "  ").contains { $0.label == String(localized: "Status") },
                       "a blank status must not produce a Status row")
    }
}
