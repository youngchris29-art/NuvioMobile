import SharedCore
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (M5, BUG-138): stale hero after a folder. `HomeHeroFocusModel` is frozen
/// while Home is covered (a push, the Continue Watching stream picker, the shell): a nil report is
/// ignored and a pending revert cancelled, and an uncover with no report reverts after 0.6 s.
/// Real timers (commit 0.2 s, revert grace 0.3 s, uncover check 0.6 s), so each case waits ≤ ~1 s.
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

    func testUncoverWithNoReportRevertsAfterTheCheck() async {
        let item = makeItem()
        let model = await committed(item)
        var reverts = 0
        model.onRevert = { reverts += 1 }

        model.setCovered(true)
        model.reportFocus(nil, from: "row-a")
        model.setCovered(false)                   // pop; focus comes back somewhere else
        await pause(0.4)
        XCTAssertEqual(model.focusedItem?.id, item.id, "still held inside the 0.6 s check")

        await pause(0.4)                          // 0.8 s after the uncover
        XCTAssertNil(model.focusedItem, "no report within 0.6 s: reverted as a nil report would")
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
