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
}
