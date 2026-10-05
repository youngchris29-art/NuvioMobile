import XCTest
@testable import NuvioTV

/// Home Stage & Strip (P1 §3.3, §9.3): the focus request's target rule (Classic must resolve exactly
/// as before), the per-row memory box, and the remounted-row horizontal restore.
@MainActor
final class StripFocusMemoryTests: XCTestCase {

    // MARK: PinnedRowFocusRequest.target(for:)

    func testClassicRequestResolvesToTheFirstCard() {
        let classic = PinnedRowFocusRequest(rowKey: "row", generation: 1)
        XCTAssertNil(classic.itemId)
        XCTAssertFalse(classic.forceFirst)
        XCTAssertEqual(PinnedRowFocusRequest.target(for: classic, rowKey: "row", firstId: "a", remembered: nil), "a")
        XCTAssertNil(PinnedRowFocusRequest.target(for: classic, rowKey: "row", firstId: nil, remembered: nil),
                     "no first card, nothing to focus (the Classic guard)")
    }

    func testStageItemIdWins() {
        let request = PinnedRowFocusRequest(rowKey: "row", generation: 2, itemId: "c")
        XCTAssertEqual(PinnedRowFocusRequest.target(for: request, rowKey: "row", firstId: "a", remembered: "b"), "c")
    }

    func testNoItemIdFallsToRememberedThenFirst() {
        let request = PinnedRowFocusRequest(rowKey: "row", generation: 3)
        XCTAssertEqual(PinnedRowFocusRequest.target(for: request, rowKey: "row", firstId: "a", remembered: "b"), "b")
        XCTAssertEqual(PinnedRowFocusRequest.target(for: request, rowKey: "row", firstId: "a", remembered: nil), "a")
    }

    func testAnotherRowGetsNothing() {
        let request = PinnedRowFocusRequest(rowKey: "row", generation: 4, itemId: "c")
        XCTAssertNil(PinnedRowFocusRequest.target(for: request, rowKey: "other", firstId: "a", remembered: "b"))
        XCTAssertNil(PinnedRowFocusRequest.target(for: .none, rowKey: "row", firstId: "a", remembered: "b"))
    }

    /// The last restore rung lands on the first card even when a remembered card exists.
    func testForceFirstIgnoresItemAndMemory() {
        let request = PinnedRowFocusRequest(rowKey: "row", generation: 5, itemId: "c", forceFirst: true)
        XCTAssertEqual(PinnedRowFocusRequest.target(for: request, rowKey: "row", firstId: "a", remembered: "b"), "a")
    }

    /// The new fields default, so every Classic construction is unchanged (and two requests that
    /// differ only in generation still differ).
    func testDefaultsKeepClassicRequestsDistinct() {
        XCTAssertEqual(PinnedRowFocusRequest.none, PinnedRowFocusRequest(rowKey: nil, generation: 0))
        XCTAssertNotEqual(PinnedRowFocusRequest(rowKey: "row", generation: 1),
                          PinnedRowFocusRequest(rowKey: "row", generation: 2))
    }

    // MARK: StripFocusMemory

    func testRememberItemIdAndPrune() {
        let memory = StripFocusMemory()
        XCTAssertTrue(memory.drivesDefaultFocus)
        XCTAssertNil(memory.itemId(for: "row0"))
        memory.remember(rowKey: "row0", itemId: "card3")
        memory.remember(rowKey: "row1", itemId: "card1")
        XCTAssertEqual(memory.itemId(for: "row0"), "card3")
        memory.remember(rowKey: "row0", itemId: "card4")
        XCTAssertEqual(memory.itemId(for: "row0"), "card4", "the latest card wins")
        XCTAssertEqual(memory.rememberedRowCount, 2)
        memory.prune(keeping: ["row1", "row9"])
        XCTAssertNil(memory.itemId(for: "row0"), "a row that left Home is forgotten")
        XCTAssertEqual(memory.itemId(for: "row1"), "card1")
        XCTAssertEqual(memory.rememberedRowCount, 1)
    }

    func testDefaultFocusSwitch() {
        XCTAssertFalse(StripFocusMemory(drivesDefaultFocus: false).drivesDefaultFocus)
        // The test host passes no `-debug.stripFocusMemory`: memory drives default focus.
        XCTAssertTrue(StageStripTuning.focusMemoryDefaultFocus)
    }

    // MARK: StripRowRestore (remounted rows)

    /// 220 pt cards, 28 pt gap, a 1640 pt viewport, 18 cards (content 18 × 248 − 28 = 4436).
    private func sample(offset: CGFloat = 0, content: CGFloat = 4436, inset: CGFloat = 0) -> RowHScrollSample {
        RowHScrollSample(offsetX: offset - inset, viewportWidth: 1640, contentWidth: content,
                         insetLeading: inset, insetTrailing: 0)
    }

    func testRestoreIsNilWhenTheCardIsVisible() {
        XCTAssertNil(StripRowRestore.offset(index: 2, cardWidth: 220, gap: 28, sample: sample()))
        XCTAssertNil(StripRowRestore.offset(index: 0, cardWidth: 220, gap: 28, sample: sample()))
    }

    func testRestoreBringsAFarCardToTheTrailingEdge() {
        // Card 10: leading 2480, trailing 2700 → 2700 − 1640.
        XCTAssertEqual(StripRowRestore.offset(index: 10, cardWidth: 220, gap: 28, sample: sample()) ?? -1,
                       1060, accuracy: 0.001)
    }

    func testRestoreClampsAtTheRowEnd() {
        // The last card's trailing edge IS the content end.
        XCTAssertEqual(StripRowRestore.offset(index: 17, cardWidth: 220, gap: 28, sample: sample()) ?? -1,
                       2796, accuracy: 0.001)
        // A short content estimate clamps the scroll.
        XCTAssertEqual(StripRowRestore.offset(index: 10, cardWidth: 220, gap: 28, sample: sample(content: 2000)) ?? -1,
                       360, accuracy: 0.001)
    }

    func testRestoreScrollsBackToACardLeftOfTheViewport() {
        XCTAssertEqual(StripRowRestore.offset(index: 2, cardWidth: 220, gap: 28, sample: sample(offset: 1500)) ?? -1,
                       496, accuracy: 0.001)
    }

    func testRestoreHonoursTheLeadingInset() {
        // Padded space: card 10 trailing = 20 + 2700 = 2720 → offset 1080 → raw 1080 − 20.
        XCTAssertEqual(StripRowRestore.offset(index: 10, cardWidth: 220, gap: 28, sample: sample(inset: 20)) ?? -1,
                       1060, accuracy: 0.001)
    }
}
