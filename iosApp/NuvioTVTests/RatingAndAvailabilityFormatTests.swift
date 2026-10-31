import XCTest
import SharedCore
@testable import NuvioTV

/// Port batch 2026-10-31: upstream 96061025 (IMDb one-decimal rating) and 2f0185ce (Unavailable pill).
final class RatingAndAvailabilityFormatTests: XCTestCase {

    // MARK: - RatingFormat.oneDecimal

    func testLongAddonRatingRoundsToOneDecimal() {
        XCTAssertEqual(RatingFormat.oneDecimal("8.123456"), "8.1")
        XCTAssertEqual(RatingFormat.oneDecimal("7.96"), "8.0")
        XCTAssertEqual(RatingFormat.oneDecimal("6.25"), "6.3") // half rounds up, like Kotlin roundToInt
        XCTAssertEqual(RatingFormat.oneDecimal("9.99"), "10.0")
    }

    func testWholeAndPreRoundedValuesAlwaysShowOneDecimal() {
        XCTAssertEqual(RatingFormat.oneDecimal("8"), "8.0")
        XCTAssertEqual(RatingFormat.oneDecimal("7.5"), "7.5")
        XCTAssertEqual(RatingFormat.oneDecimal("7.50"), "7.5")
        XCTAssertEqual(RatingFormat.oneDecimal(" 8.3 "), "8.3")
    }

    func testSeparatorIgnoresDeviceLocale() {
        // `String(format:)` / NumberFormatter would print "8,1" under a comma-decimal locale.
        XCTAssertFalse(RatingFormat.oneDecimal("8.123456").contains(","))
    }

    func testNonNumericPassesThroughTrimmed() {
        XCTAssertEqual(RatingFormat.oneDecimal("N/A"), "N/A")
        XCTAssertEqual(RatingFormat.oneDecimal(" "), "")
    }

    func testOversizedOrNonFiniteNumbersPassThroughWithoutTrapping() {
        for raw in ["1e18", "9999999999999999999", "-1e18", "1e400", "inf", "nan", "1e15"] {
            XCTAssertEqual(RatingFormat.oneDecimal(raw), raw)
        }
        XCTAssertEqual(RatingFormat.oneDecimal("999999999999999"), "999999999999999.0") // largest accepted
    }

    // MARK: - EpisodeAvailability

    private let now: Int64 = 1_793_000_000_000 // 2026-10-26

    func testFlaggedUnavailableShowsPillEvenWhenAired() {
        XCTAssertTrue(EpisodeAvailability.isUnavailable(available: false, released: "2020-01-01T00:00:00Z", nowEpochMs: now))
    }

    func testFutureReleaseShowsPill() {
        XCTAssertTrue(EpisodeAvailability.isUnavailable(available: true, released: "2999-01-01T00:00:00Z", nowEpochMs: now))
    }

    func testAiredMissingOrUnparseableReleaseHidesPill() {
        XCTAssertFalse(EpisodeAvailability.isUnavailable(available: true, released: "2020-01-01T00:00:00Z", nowEpochMs: now))
        XCTAssertFalse(EpisodeAvailability.isUnavailable(available: true, released: nil, nowEpochMs: now))
        XCTAssertFalse(EpisodeAvailability.isUnavailable(available: true, released: "soon", nowEpochMs: now))
    }

    func testMetaVideoOverload() {
        func video(_ released: String?, available: Bool) -> MetaVideo {
            MetaVideo(id: "tt1:1:1", title: "E", released: released, available: available,
                      thumbnail: nil, seasonPoster: nil, season: KotlinInt(int: 1), episode: KotlinInt(int: 1),
                      overview: nil, runtime: nil, rating: nil, streams: [])
        }
        XCTAssertTrue(EpisodeAvailability.isUnavailable(video("2999-01-01", available: true)))
        XCTAssertTrue(EpisodeAvailability.isUnavailable(video(nil, available: false)))
        XCTAssertFalse(EpisodeAvailability.isUnavailable(video("2020-01-01", available: true)))
    }
}
