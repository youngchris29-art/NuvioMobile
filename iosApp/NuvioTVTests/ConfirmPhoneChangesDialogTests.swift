import XCTest
@testable import NuvioTV

/// Add-ons hub v2 C5: the phone confirm dialog's list is as tall as its lines, up to the cap.
final class ConfirmPhoneChangesDialogTests: XCTestCase {
    func testOneLineKeepsItsOwnHeight() {
        XCTAssertEqual(ConfirmPhoneChangesDialog.listFrameHeight(content: 72), 72)
    }

    func testLongListStopsAtTheCap() {
        XCTAssertEqual(ConfirmPhoneChangesDialog.listFrameHeight(content: 2_000), ConfirmPhoneChangesDialog.listHeight)
    }

    func testBeforeMeasurementUsesOneLineNotTheCap() {
        XCTAssertLessThan(ConfirmPhoneChangesDialog.listFrameHeight(content: 0), 100)
    }
}
