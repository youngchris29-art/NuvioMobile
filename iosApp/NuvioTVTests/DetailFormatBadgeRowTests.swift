import XCTest
@testable import NuvioTV

/// `DetailFormatBadgeRow`: the VoiceOver label and the reserved slot height. Focusability has no
/// unit-level probe (a SwiftUI view's focus behaviour is only observable on a running tree), so the
/// "never focusable" rule is covered by the UI legs, not here.
final class DetailFormatBadgeRowTests: XCTestCase {

    private func expected(_ labels: [String]) -> String {
        "Available in " + ListFormatter.localizedString(byJoining: labels)
    }

    func testAccessibilityLabelForOneTwoAndFourLabels() {
        for labels in [["4K"], ["4K", "Dolby Vision"], ["4K", "Dolby Vision", "HDR10+", "Dolby Atmos"]] {
            XCTAssertEqual(DetailFormatBadgeRow.accessibilityLabel(for: labels), expected(labels))
        }
    }

    func testAccessibilityLabelIsNilWhenEmpty() {
        XCTAssertNil(DetailFormatBadgeRow.accessibilityLabel(for: []))
    }

    func testReservedHeightIsZeroWhenOffOrWithoutRequest() {
        XCTAssertEqual(DetailFormatBadgeRow.reservedHeight(enabled: false, hasRequest: true), 0)
        XCTAssertEqual(DetailFormatBadgeRow.reservedHeight(enabled: true, hasRequest: false), 0)
        XCTAssertEqual(DetailFormatBadgeRow.reservedHeight(enabled: false, hasRequest: false), 0)
    }

    func testReservedHeightIsTheTokenWhenOnWithRequest() {
        XCTAssertEqual(DetailFormatBadgeRow.reservedHeight(enabled: true, hasRequest: true),
                       DetailGeometry.formatBadgeRowHeight)
    }
}
