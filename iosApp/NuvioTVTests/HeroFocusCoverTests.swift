import SharedCore
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (M5, BUG-138): stale hero after a folder. `HomeHeroFocusModel` is frozen
/// while Home is covered (a push, the Continue Watching stream picker, the shell): a nil report is
/// ignored and a pending revert cancelled, and an uncover with no report reverts after 0.6 s (a shell
/// cover) or, since review r1 (A P3), 1.2 s (a cover tvOS restores row focus from: a push, the stream
/// picker), so a pop whose restored report is late on hardware is not reverted and re-committed.
/// Real timers (commit 0.2 s, revert grace 0.3 s, uncover checks 0.6 / 1.2 s), so each case waits
/// ≤ ~1.8 s.
@MainActor
final class HeroFocusCoverTests: XCTestCase {

    /// A preview that never triggers the model's side lookups: a non-blank logo (no
    /// `TitleLogoStore` lookup) and a description plus banner (no TMDB gap-fill).
    private func makeItem(id: String = "tt0000001", name: String = "Movie") -> MetaPreview {
        MetaPreview(
            id: id, type: "movie", name: name,
            poster: "https://example.com/poster.jpg",
            banner: "https://example.com/banner.jpg",
            logo: "https://example.com/logo.png",
            posterShape: .poster,
            description: "A synopsis.", releaseInfo: "2026", rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: [],
            rawPosterUrl: nil,
            landscapePoster: nil,
            rawLandscapePosterUrl: nil,
            customPosterApplied: false
        )
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Commits `item` from `source` and waits past the 0.2 s commit dwell.
    private func committed(_ item: MetaPreview, from source: String = "row-a") async -> HomeHeroFocusModel {
        let model = HomeHeroFocusModel()
        model.reportFocus(item, from: source)
        await pause(0.35)
        XCTAssertEqual(model.focusedItem?.id, item.id, "precondition: the item committed")
        return model
    }

    func testCoveredNilReportKeepsTheItem() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.setCovered(true)
        model.reportFocus(nil, from: "row-a")   // focus leaving for the pushed page
        await pause(0.5)                          // past the 0.3 s revert grace

        XCTAssertEqual(model.focusedItem?.id, item.id, "a covered nil report must not revert the hero")
        XCTAssertEqual(reverts, 0)
    }

    func testSetCoveredCancelsAPendingRevert() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.reportFocus(nil, from: "row-a")   // revert grace starts (0.3 s)
        model.setCovered(true)                    // the push lands inside the grace
        await pause(0.5)

        XCTAssertEqual(model.focusedItem?.id, item.id, "the cover cancels the pending revert")
        XCTAssertEqual(reverts, 0)
    }

    /// A shell cover (a tab switch: focus comes back on the tab bar, never on the card) keeps the
    /// short 0.6 s check.
    func testUncoverWithNoReportRevertsAfterTheCheck() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.setCovered(true, restoresFocus: false)
        model.reportFocus(nil, from: "row-a")
        model.setCovered(false, restoresFocus: false)   // back on Home; focus is on the tab bar
        await pause(0.4)
        XCTAssertEqual(model.focusedItem?.id, item.id, "still held inside the 0.6 s check")

        await pause(0.4)                          // 0.8 s after the uncover
        XCTAssertNil(model.focusedItem, "no report within 0.6 s: reverted as a nil report would")
        XCTAssertEqual(reverts, 1)
    }

    // MARK: - beta.19-rc1 verdict (review r1, A P3): the pop's restored report may be late

    /// The uncover fallback per cover kind: a cover tvOS restores row focus from waits longer.
    func testUncoverDelayPerCoverKind() {
        XCTAssertEqual(HomeHeroFocusModel.uncoverDelay(restoresFocus: false), HomeHeroFocusModel.uncoverVerifyDelay)
        XCTAssertEqual(HomeHeroFocusModel.uncoverDelay(restoresFocus: true), HomeHeroFocusModel.uncoverRestoreDelay)
        XCTAssertEqual(HomeHeroFocusModel.uncoverVerifyDelay, 0.6)
        XCTAssertEqual(HomeHeroFocusModel.uncoverRestoreDelay, 1.2)
    }

    /// A pop with no report at all still reverts, but only after the longer fallback: at 0.8 s (past
    /// the old 0.6 s check, where a slow device restore used to lose the race) the hero is held.
    func testPopWithNoReportRevertsAfterTheLongerFallback() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.setCovered(true)                    // a push (restores focus: the default)
        model.reportFocus(nil, from: "row-a")
        model.setCovered(false)
        await pause(0.8)
        XCTAssertEqual(model.focusedItem?.id, item.id, "held past 0.6 s, waiting for the restored report")
        XCTAssertEqual(reverts, 0)

        await pause(0.6)                          // 1.4 s after the uncover
        XCTAssertNil(model.focusedItem, "no report within 1.2 s: reverted as a nil report would")
        XCTAssertEqual(reverts, 1)
    }

    /// Review r1's device race: the pop's restored report lands 0.9 s after `homePath` empties. The
    /// first report answers the uncover, so the hero is never reverted and never re-committed (the
    /// double swap BUG-138 removes).
    func testLateRestoredReportAfterAPopKeepsTheItem() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.setCovered(true)
        model.reportFocus(nil, from: "row-a")
        model.setCovered(false)
        await pause(0.9)                          // the old 0.6 s check would have reverted here
        model.reportFocus(item, from: "row-a")    // focus restored to the folder card, late
        await pause(0.6)

        XCTAssertEqual(model.focusedItem?.id, item.id)
        XCTAssertEqual(reverts, 0, "a late restored report must not cost a revert and a re-commit")
    }

    /// A push that joins a shell cover already in force lengthens the fallback; a cover can never
    /// shorten it.
    func testAPushJoiningAShellCoverUsesTheLongerFallback() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.setCovered(true, restoresFocus: false)    // shell
        model.setCovered(true, restoresFocus: true)     // a push lands while covered
        model.setCovered(true, restoresFocus: false)    // the push pops, the shell is still up
        model.reportFocus(nil, from: "row-a")
        model.setCovered(false, restoresFocus: false)
        await pause(0.8)
        XCTAssertEqual(model.focusedItem?.id, item.id, "the longer fallback applies")

        await pause(0.6)
        XCTAssertNil(model.focusedItem)
        XCTAssertEqual(reverts, 1)
    }

    /// The cover kind is per cover: after a pop is answered, a later tab switch is back on the short
    /// check.
    func testTheCoverKindResetsAfterEachUncover() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.setCovered(true)                    // push
        model.setCovered(false)                   // pop
        model.reportFocus(item, from: "row-a")    // restored on time

        model.setCovered(true, restoresFocus: false)    // then a tab switch
        model.reportFocus(nil, from: "row-a")
        model.setCovered(false, restoresFocus: false)
        await pause(0.8)
        XCTAssertNil(model.focusedItem, "a shell cover keeps the 0.6 s check")
        XCTAssertEqual(reverts, 1)
    }

    func testUncoverThenTheSameItemKeepsItWithoutARevert() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.setCovered(true)
        model.reportFocus(nil, from: "row-a")
        model.setCovered(false)
        model.reportFocus(item, from: "row-a")    // the pop restores focus to the same card
        await pause(0.8)

        XCTAssertEqual(model.focusedItem?.id, item.id)
        XCTAssertEqual(reverts, 0, "the restored card answers the uncover check")
    }
}
