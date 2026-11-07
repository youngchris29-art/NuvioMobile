import XCTest
import SharedCore
@testable import NuvioTV

/// Add-ons hub v2, A3: the pure rules behind the Installed pane's rows and context menu.
final class InstalledAddonsPaneTests: XCTestCase {
    private typealias Pane = InstalledAddonsPane

    private func actions(
        enabled: Bool = true, configurable: Bool = false, index: Int = 1, count: Int = 3,
        readOnly: Bool = false, status: AddonsViewModel.AddonStatus = .active
    ) -> [Pane.RowAction] {
        Pane.menuActions(
            enabled: enabled, configurable: configurable, index: index, count: count,
            isReadOnly: readOnly, status: status
        )
    }

    func testTrailingTextForAllStatuses() {
        XCTAssertEqual(Pane.trailingText(.active), "On")
        XCTAssertEqual(Pane.trailingText(.disabled), "Off")
        XCTAssertEqual(Pane.trailingText(.refreshing), "Refreshing…")
        XCTAssertEqual(Pane.trailingText(.stalled), "Still refreshing…")
        XCTAssertEqual(Pane.trailingText(.unavailable), "Unavailable")
    }

    func testRowKeyFormat() {
        XCTAssertEqual(Pane.rowKey("https://a.example.com/manifest.json"), "row:https://a.example.com/manifest.json")
    }

    /// A4: one "Move" item (Move mode) on any row of a list with more than one add-on.
    func testEveryRowOfALongerListOffersMove() {
        for index in 0..<3 {
            XCTAssertEqual(actions(index: index, count: 3), [.toggle(enable: false), .move, .refresh, .remove])
        }
    }

    func testOnlyRowHasNoMove() {
        XCTAssertEqual(actions(index: 0, count: 1), [.toggle(enable: false), .refresh, .remove])
    }

    /// A4: VoiceOver keeps the direct Move up / Move down actions where they apply.
    func testVoiceOverMovesFollowThePosition() {
        XCTAssertEqual(Pane.voiceOverMoves(index: 0, count: 3, isReadOnly: false), [.moveDown])
        XCTAssertEqual(Pane.voiceOverMoves(index: 1, count: 3, isReadOnly: false), [.moveUp, .moveDown])
        XCTAssertEqual(Pane.voiceOverMoves(index: 2, count: 3, isReadOnly: false), [.moveUp])
        XCTAssertEqual(Pane.voiceOverMoves(index: 1, count: 3, isReadOnly: true), [])
    }

    func testDisabledAddonOffersEnable() {
        XCTAssertEqual(actions(enabled: false, index: 0, count: 1, status: .disabled).first, .toggle(enable: true))
    }

    func testConfigurableAddsConfigureBeforeRemove() {
        let on = actions(configurable: true)
        XCTAssertEqual(on, [.toggle(enable: false), .move, .refresh, .configure, .remove])
        XCTAssertFalse(actions(configurable: false).contains(.configure))
    }

    func testStalledOffersRetryInsteadOfRefresh() {
        let list = actions(status: .stalled)
        XCTAssertTrue(list.contains(.retry))
        XCTAssertFalse(list.contains(.refresh))
    }

    func testReadOnlyOnlyRefreshesOrRetries() {
        XCTAssertEqual(actions(configurable: true, readOnly: true), [.refresh])
        XCTAssertEqual(actions(readOnly: true, status: .stalled), [.retry])
    }
}
