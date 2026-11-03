import XCTest
@testable import NuvioTV

final class PlayerSettingsPaneFooterTests: XCTestCase {
    func testFooterShownWhenEngineOn() {
        let footer = PlayerSettingsPane.experimentalEngineFooter(engineOn: true)
        XCTAssertNotNil(footer)
        XCTAssertTrue(footer?.contains("Lossless surround") ?? false)
    }

    func testFooterHiddenWhenEngineOff() {
        XCTAssertNil(PlayerSettingsPane.experimentalEngineFooter(engineOn: false))
    }
}
