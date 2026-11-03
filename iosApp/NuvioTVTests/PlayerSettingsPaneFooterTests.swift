import XCTest
@testable import NuvioTV

final class PlayerSettingsPaneFooterTests: XCTestCase {
    func testFooterShownWhenEngineOn() {
        XCTAssertEqual(
            PlayerSettingsPane.experimentalEngineFooter(engineOn: true),
            String(localized: "Turning Lossless surround (LPCM) off sends TrueHD and DTS as Dolby Digital Plus 5.1, which older soundbars accept.")
        )
    }

    func testFooterHiddenWhenEngineOff() {
        XCTAssertNil(PlayerSettingsPane.experimentalEngineFooter(engineOn: false))
    }
}
