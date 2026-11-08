import XCTest
@testable import NuvioTV

/// Add-ons hub v2 C2: the Manage from phone pane's state.
final class ManageFromPhoneStatusTests: XCTestCase {
    func testStatusFollowsTheServer() {
        XCTAssertEqual(ManageFromPhoneStatus(isRunning: false, isStarting: false, startFailed: false, phoneConnected: false), .starting)
        XCTAssertEqual(ManageFromPhoneStatus(isRunning: false, isStarting: true, startFailed: false, phoneConnected: false), .starting)
        XCTAssertEqual(ManageFromPhoneStatus(isRunning: true, isStarting: false, startFailed: false, phoneConnected: false), .ready)
        XCTAssertEqual(ManageFromPhoneStatus(isRunning: true, isStarting: false, startFailed: false, phoneConnected: true), .connected)
        XCTAssertEqual(ManageFromPhoneStatus(isRunning: false, isStarting: false, startFailed: true, phoneConnected: false), .failed)
    }

    /// Every state offers a control, so focus can always enter the pane.
    func testEveryStateHasAControl() {
        for status in [ManageFromPhoneStatus.starting, .ready, .connected, .failed] {
            XCTAssertFalse(status.buttonTitle.isEmpty)
            XCTAssertFalse(status.title.isEmpty)
        }
        XCTAssertEqual(ManageFromPhoneStatus.failed.buttonTitle, "Try again")
        XCTAssertEqual(ManageFromPhoneStatus.ready.buttonTitle, "New code")
    }

    /// The hub's focus memory knows the pane's control.
    func testThePaneTakesPartInFocusMemory() {
        XCTAssertEqual(AddonsHubSplitView.firstContentKey(section: .phone, addons: []), ManageFromPhonePane.primaryKey)
    }
}
