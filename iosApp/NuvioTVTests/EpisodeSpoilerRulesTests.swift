import XCTest
@testable import NuvioTV

final class EpisodeSpoilerRulesTests: XCTestCase {
    private let today = "2026-10-02"

    func testIsAired() {
        XCTAssertTrue(EpisodeSpoilerRules.isAired(released: "2024-04-12", todayIsoDate: today))
        XCTAssertTrue(EpisodeSpoilerRules.isAired(released: "2026-10-02", todayIsoDate: today))
        XCTAssertFalse(EpisodeSpoilerRules.isAired(released: "2026-10-03", todayIsoDate: today))
        XCTAssertFalse(EpisodeSpoilerRules.isAired(released: nil, todayIsoDate: today))
        XCTAssertFalse(EpisodeSpoilerRules.isAired(released: "2024", todayIsoDate: today))
        XCTAssertTrue(EpisodeSpoilerRules.isAired(released: "2024-04-12T00:00:00.000Z", todayIsoDate: today))
        XCTAssertFalse(EpisodeSpoilerRules.isAired(released: "abcd-ef-ghij", todayIsoDate: today))
    }

    /// Review r1 #5: a full timestamp is an instant compared against `now`, not its UTC date prefix
    /// against the local date.
    func testIsAiredFullTimestamp() {
        // 2026-10-02 12:00 UTC.
        let now = Date(timeIntervalSince1970: 1_790_942_400)
        // Later the same UTC day: not aired yet, although its date prefix equals today.
        XCTAssertFalse(EpisodeSpoilerRules.isAired(released: "2026-10-02T20:00:00Z", todayIsoDate: today, now: now))
        XCTAssertFalse(EpisodeSpoilerRules.isAired(released: "2026-10-02T20:00:00.000Z", todayIsoDate: today, now: now))
        // Earlier the same day: aired.
        XCTAssertTrue(EpisodeSpoilerRules.isAired(released: "2026-10-02T01:00:00Z", todayIsoDate: today, now: now))
        XCTAssertTrue(EpisodeSpoilerRules.isAired(released: "2026-10-02T01:00:00.123Z", todayIsoDate: today, now: now))
        // Tomorrow's UTC date but already past as an instant (01:00 on the 3rd at +14:00 = 11:00 UTC on the 2nd).
        XCTAssertTrue(EpisodeSpoilerRules.isAired(released: "2026-10-03T01:00:00+14:00", todayIsoDate: today, now: now))
        // No zone designator: falls back to the date prefix.
        XCTAssertTrue(EpisodeSpoilerRules.isAired(released: "2026-10-02T23:00:00", todayIsoDate: today, now: now))
        XCTAssertFalse(EpisodeSpoilerRules.isAired(released: "2026-10-03T00:00:00", todayIsoDate: today, now: now))
        // Bare date keeps the date path whatever the time.
        XCTAssertTrue(EpisodeSpoilerRules.isAired(released: "2026-10-02", todayIsoDate: today, now: now))
    }

    func testAiredUnwatchedCountUsesNowForTimestamps() {
        let now = Date(timeIntervalSince1970: 1_790_942_400)
        let eps = [
            facts(1, 1, "2026-10-02T01:00:00Z"),
            facts(1, 2, "2026-10-02T20:00:00Z"),
        ]
        XCTAssertEqual(EpisodeSpoilerRules.airedUnwatchedCount(eps, watchedKeys: [], todayIsoDate: today, now: now), 1)
    }

    private func facts(_ s: Int?, _ e: Int?, _ released: String?) -> EpisodeSpoilerRules.EpisodeFacts {
        .init(season: s, episode: e, released: released)
    }

    func testAiredUnwatchedCount() {
        var eps = [
            facts(1, 1, "2024-01-01"),
            facts(1, 2, "2024-01-08"),
            facts(1, 3, "2024-01-15"),
        ]
        XCTAssertEqual(EpisodeSpoilerRules.airedUnwatchedCount(eps, watchedKeys: ["1:1"], todayIsoDate: today), 2)
        eps.append(facts(1, 4, "2030-01-01"))
        XCTAssertEqual(EpisodeSpoilerRules.airedUnwatchedCount(eps, watchedKeys: ["1:1"], todayIsoDate: today), 2)
        eps.append(facts(1, nil, "2024-02-01"))
        XCTAssertEqual(EpisodeSpoilerRules.airedUnwatchedCount(eps, watchedKeys: ["1:1"], todayIsoDate: today), 2)
        XCTAssertEqual(
            EpisodeSpoilerRules.airedUnwatchedCount(eps, watchedKeys: ["1:1", "1:2", "1:3"], todayIsoDate: today),
            0
        )
    }

    func testAiredUnwatchedLabel() {
        XCTAssertNil(EpisodeSpoilerRules.airedUnwatchedLabel(count: 0, settingOn: true))
        XCTAssertNil(EpisodeSpoilerRules.airedUnwatchedLabel(count: 3, settingOn: false))
        let label = EpisodeSpoilerRules.airedUnwatchedLabel(count: 3, settingOn: true)
        XCTAssertNotNil(label)
        XCTAssertTrue(label?.contains("3") == true)
    }

    func testHidesSpoilersTruthTable() {
        XCTAssertTrue(EpisodeSpoilerRules.hidesSpoilers(settingOn: true, isWatched: false))
        XCTAssertFalse(EpisodeSpoilerRules.hidesSpoilers(settingOn: true, isWatched: true))
        XCTAssertFalse(EpisodeSpoilerRules.hidesSpoilers(settingOn: false, isWatched: false))
        XCTAssertFalse(EpisodeSpoilerRules.hidesSpoilers(settingOn: false, isWatched: true))
    }

    func testDefaultsKeyMatchesDetailSettingsKey() {
        XCTAssertEqual(EpisodeSpoilerRules.defaultsKey, DetailSettingsKeys.hideEpisodeSpoilers)
    }
}
