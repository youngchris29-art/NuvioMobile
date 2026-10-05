import XCTest
@testable import NuvioTV

/// Home Stage & Strip (H5, W2-B; P2 spec §2.5, §4.2): the folder logo's rise. Docked in the
/// stage's logo slot at full size only until the viewer's first move (Q1, decided 2026-10-05), then
/// a 60 % title `compactGap` above the stage block, floored at `compactTopFloor`, for good.
final class FolderStageLogoTests: XCTestCase {

    func testConstants() {
        XCTAssertEqual(FolderStageLogo.compactScale, 0.6)
        XCTAssertEqual(FolderStageLogo.compactGap, 8)
        XCTAssertEqual(FolderStageLogo.compactTopFloor, 12)
    }

    func testDockedOnlyWhileNotFollowing() {
        XCTAssertTrue(FolderStageLogo.docked(followsFocus: false))
        XCTAssertFalse(FolderStageLogo.docked(followsFocus: true))
    }

    /// Q1: no re-dock. Once a move has started following, returning to row 0's initial card (Up
    /// back to where the page opened) keeps following, so the logo stays compact.
    func testNoPathBackToDocked() {
        let initial = FolderStageInput.cardKey(rowId: "folder_f_1", itemId: "tt0")
        let moved = FolderStageInput.cardKey(rowId: "folder_f_2", itemId: "tt5")
        var state = FolderStageInput.State.initial
        XCTAssertTrue(FolderStageLogo.docked(followsFocus: state.follows), "open: docked")

        state = FolderStageInput.step(state, report: initial).state
        XCTAssertTrue(FolderStageLogo.docked(followsFocus: state.follows), "the initial landing keeps it docked")

        state = FolderStageInput.step(state, report: moved).state
        XCTAssertFalse(FolderStageLogo.docked(followsFocus: state.follows), "the first move undocks it")

        for report in [initial, nil, moved, initial] {
            state = FolderStageInput.step(state, report: report).state
            XCTAssertFalse(FolderStageLogo.docked(followsFocus: state.follows), "never re-docks (\(report ?? "nil"))")
        }
    }

    func testCompactTop() {
        XCTAssertEqual(FolderStageLogo.compactTop(blockTop: 120, slot: 150), 22, accuracy: 1e-9)
        XCTAssertEqual(FolderStageLogo.compactTop(blockTop: 120, slot: 110), 46, accuracy: 1e-9)
        XCTAssertEqual(FolderStageLogo.compactTop(blockTop: 60, slot: 150), 12, accuracy: 1e-9, "floored")
    }

    /// The spec's example: block top 120 and slot 150 give a 90 pt logo at y 22…112; a compressed
    /// 110 slot gives 66 pt at y 46…112. The compact bottom always sits `compactGap` above the block.
    func testCompactLogoEndsJustAboveTheStageBlock() {
        for (blockTop, slot) in [(CGFloat(120), CGFloat(150)), (120, 110)] {
            let top = FolderStageLogo.compactTop(blockTop: blockTop, slot: slot)
            let bottom = top + FolderStageLogo.compactScale * slot
            XCTAssertEqual(bottom, blockTop - FolderStageLogo.compactGap, accuracy: 1e-9, "slot \(slot)")
        }
    }

    func testOffset() {
        XCTAssertEqual(FolderStageLogo.offsetY(docked: true, blockTop: 120, slot: 150), 0)
        XCTAssertEqual(FolderStageLogo.offsetY(docked: true, blockTop: 120, slot: 110), 0)
        XCTAssertEqual(FolderStageLogo.offsetY(docked: false, blockTop: 120, slot: 150), -98, accuracy: 1e-9)
        XCTAssertEqual(FolderStageLogo.offsetY(docked: false, blockTop: 120, slot: 110), -74, accuracy: 1e-9)
    }
}
