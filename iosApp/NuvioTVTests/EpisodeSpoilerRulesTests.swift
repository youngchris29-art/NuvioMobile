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
