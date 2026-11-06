import XCTest
@testable import NuvioTV

/// A3.1 (C2): the Apple-style per-episode text block: content, the fixed block height and the
/// spoiler rule (overview and still hide together; number, title, date stay).
final class EpisodeCardTextTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func content(
        number: Int? = 3,
        title: String = "The Lake",
        overview: String? = "The detectives find a body in the lake.",
        airDate: String? = "Apr 12, 2024",
        runtime: Int? = 52,
        rating: Double? = 8.44,
        hides: Bool = false
    ) -> EpisodeCardText.Content {
        EpisodeCardText.make(episodeNumber: number, title: title, overview: overview, airDate: airDate,
                             runtimeMinutes: runtime, rating: rating, hidesSpoiler: hides)
    }

    // MARK: - Content

    func testLiftReserveHoldsTheAppleStyleTextStill() {
        XCTAssertEqual(EpisodeCardTextLayout.liftReserve(appleStyleText: true, zooms: true), 20)
        XCTAssertEqual(EpisodeCardTextLayout.liftReserve(appleStyleText: true, zooms: false), 0, "No Zoom on Focus")
        XCTAssertEqual(EpisodeCardTextLayout.liftReserve(appleStyleText: false, zooms: true), 0, "heading keeps its drop")
    }

    func testFullContent() {
        let c = content()
        XCTAssertEqual(c.numberLabel, "Episode 3")
        XCTAssertEqual(c.title, "The Lake")
        XCTAssertEqual(c.overview, "The detectives find a body in the lake.")
        XCTAssertFalse(c.overviewHidden)
        XCTAssertFalse(c.blursStill)
        XCTAssertEqual(c.metaLine, "Apr 12, 2024 \u{00B7} 52 min")
        XCTAssertEqual(c.ratingText, "8.4")
    }

    func testMissingDataLeavesRowsEmpty() {
        let c = content(number: nil, overview: nil, airDate: nil, runtime: nil, rating: nil)
        XCTAssertNil(c.numberLabel)
        XCTAssertNil(c.overview)
        XCTAssertNil(c.metaLine)
        XCTAssertNil(c.ratingText)
        XCTAssertEqual(c.title, "The Lake")
    }

    func testBlankOverviewIsMissing() {
        XCTAssertNil(content(overview: "   \n").overview)
        XCTAssertNil(content(overview: "").overview)
        XCTAssertEqual(content(overview: "  Text.  ").overview, "Text.")
    }

    func testMetaLineParts() {
        XCTAssertEqual(EpisodeCardText.metaLine(airDate: "Apr 12, 2024", runtimeMinutes: nil), "Apr 12, 2024")
        XCTAssertEqual(EpisodeCardText.metaLine(airDate: nil, runtimeMinutes: 45), "45 min")
        XCTAssertNil(EpisodeCardText.metaLine(airDate: "", runtimeMinutes: 0))
        XCTAssertNil(EpisodeCardText.metaLine(airDate: nil, runtimeMinutes: -1))
    }

    func testRatingText() {
        XCTAssertEqual(EpisodeCardText.ratingText(7), "7.0")
        XCTAssertEqual(EpisodeCardText.ratingText(9.96), "10.0")
        XCTAssertNil(EpisodeCardText.ratingText(nil))
        XCTAssertNil(EpisodeCardText.ratingText(.nan))
        XCTAssertNil(EpisodeCardText.ratingText(.infinity))
    }

    func testCardIdentifier() {
        XCTAssertEqual(EpisodeCardText.cardIdentifier(season: 2, episode: 5, fallbackId: "x"), "episode_card_2_5")
        XCTAssertEqual(EpisodeCardText.cardIdentifier(season: nil, episode: 1, fallbackId: "x"), "episode_card_0_1")
        XCTAssertEqual(EpisodeCardText.cardIdentifier(season: 0, episode: 1, fallbackId: "x"), "episode_card_0_1")
        XCTAssertEqual(EpisodeCardText.cardIdentifier(season: 1, episode: nil, fallbackId: "tt1:vid"), "episode_card_tt1:vid")
    }

    // MARK: - Air date

    func testAirDateFormatsCalendarDay() {
        XCTAssertEqual(EpisodeCardText.airDate(released: "2024-04-12", locale: en), "Apr 12, 2024")
        // A timestamp keeps its date prefix: no time-zone shift to a neighbouring day.
        XCTAssertEqual(EpisodeCardText.airDate(released: "2024-04-12T23:30:00.000Z", locale: en), "Apr 12, 2024")
        XCTAssertEqual(EpisodeCardText.airDate(released: "2024-01-01T00:00:00Z", locale: en), "Jan 1, 2024")
    }

    func testAirDateRejectsMalformed() {
        XCTAssertNil(EpisodeCardText.airDate(released: nil, locale: en))
        XCTAssertNil(EpisodeCardText.airDate(released: "2024", locale: en))
        XCTAssertNil(EpisodeCardText.airDate(released: "abcd-ef-ghij", locale: en))
        XCTAssertNil(EpisodeCardText.airDate(released: "2024-13-01", locale: en))
        XCTAssertNil(EpisodeCardText.airDate(released: "2024-02-30", locale: en))
        XCTAssertNil(EpisodeCardText.airDate(released: "2024/04/12", locale: en))
    }

    // MARK: - Spoilers (same rule as the shared panel: `EpisodeSpoilerRules.hidesSpoilers`)

    func testSettingOffShowsEverything() {
        let hides = EpisodeSpoilerRules.hidesSpoilers(settingOn: false, isWatched: false)
        let c = content(hides: hides)
        XCTAssertFalse(c.overviewHidden)
        XCTAssertFalse(c.blursStill)
        XCTAssertNotNil(c.overview)
    }

    func testSettingOnUnwatchedHidesOverviewAndStillTogether() {
        let hides = EpisodeSpoilerRules.hidesSpoilers(settingOn: true, isWatched: false)
        let c = content(hides: hides)
        XCTAssertTrue(c.overviewHidden)
        XCTAssertTrue(c.blursStill)
        XCTAssertNil(c.overview, "the overview text must never reach the view while hidden")
    }

    func testSettingOnWatchedShowsEverything() {
        let hides = EpisodeSpoilerRules.hidesSpoilers(settingOn: true, isWatched: true)
        let c = content(hides: hides)
        XCTAssertFalse(c.overviewHidden)
        XCTAssertFalse(c.blursStill)
        XCTAssertEqual(c.overview, "The detectives find a body in the lake.")
    }

    /// The panel showed its placeholder whether or not an overview existed; the card does the same.
    func testHiddenWithoutOverviewStillShowsPlaceholder() {
        let c = content(overview: nil, hides: true)
        XCTAssertTrue(c.overviewHidden)
        XCTAssertNil(c.overview)
    }

    /// Hidden keeps what the panel's caption kept: number, title, date and runtime. The rating
    /// follows the Episode Ratings setting, which the caller applies before passing it.
    func testHiddenKeepsNumberTitleDateAndRating() {
        let c = content(hides: true)
        XCTAssertEqual(c.numberLabel, "Episode 3")
        XCTAssertEqual(c.title, "The Lake")
        XCTAssertEqual(c.metaLine, "Apr 12, 2024 \u{00B7} 52 min")
        XCTAssertEqual(c.ratingText, "8.4")
        XCTAssertNil(content(rating: nil, hides: true).ratingText)
    }

    func testBlurAlwaysMatchesHiddenOverview() {
        for hides in [false, true] {
            for overview in [nil, "", "Text"] as [String?] {
                let c = content(overview: overview, hides: hides)
                XCTAssertEqual(c.blursStill, c.overviewHidden)
            }
        }
    }

    // MARK: - Fixed block height

    func testBlockHeightSumsFourRowsWithTwoOverviewLines() {
        // 30 + 30 + 2 × 30 + 30 + 3 × 4.
        XCTAssertEqual(EpisodeCardTextLayout.blockHeight(numberLine: 30, titleLine: 30, overviewLine: 30,
                                                         metaLine: 30, spacing: 4), 162)
        XCTAssertEqual(EpisodeCardTextLayout.overviewLineLimit, 2)
    }

    func testBlockHeightRoundsUp() {
        // 31 × 3 + 30.4 × 2 + 12 = 165.8 → 166.
        XCTAssertEqual(EpisodeCardTextLayout.blockHeight(numberLine: 31, titleLine: 31, overviewLine: 30.4,
                                                         metaLine: 31, spacing: 4), 166)
        XCTAssertEqual(EpisodeCardTextLayout.overviewHeight(overviewLine: 30.4), 61)
    }

    /// The height takes only font metrics: two cards with different data get the same block.
    func testBlockHeightIndependentOfContentAndUsesRowSpacing() {
        let a = EpisodeCardTextLayout.blockHeight(numberLine: 32, titleLine: 32, overviewLine: 32, metaLine: 32)
        XCTAssertEqual(a, (32 * 5 + EpisodeCardTextLayout.rowSpacing * 3).rounded(.up))
    }

    /// The slots the view stacks (rounded rows + rounded overview + spacing) never overflow the block.
    func testSlotsFitInsideBlock() {
        for line in stride(from: CGFloat(28), through: 44, by: 0.37) {
            let slot = line.rounded(.up)
            let block = EpisodeCardTextLayout.blockHeight(numberLine: slot, titleLine: slot, overviewLine: line,
                                                          metaLine: slot)
            let stacked = slot * 3 + EpisodeCardTextLayout.overviewHeight(overviewLine: line)
                + EpisodeCardTextLayout.rowSpacing * 3
            XCTAssertLessThanOrEqual(stacked, block + 0.0001, "line \(line)")
        }
    }
}
