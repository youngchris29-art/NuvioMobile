import XCTest
@testable import NuvioTV

/// About › Support: the explainer shows a QR code for the tip-jar address because tvOS cannot
/// open a link.
@MainActor
final class SettingsQRCodeTests: XCTestCase {
    func testSupportAddressProducesASquareCode() throws {
        let image = try XCTUnwrap(SettingsQRCode.image(for: AboutSettingsPane.supportURLString))
        XCTAssertEqual(image.size.width, image.size.height)
        // The smallest QR symbol is 21 modules plus Core Image's one-module border on each side.
        XCTAssertGreaterThanOrEqual(image.size.width, 23)
    }

    func testRowAddressMatchesTheEncodedURL() {
        XCTAssertEqual(
            AboutSettingsPane.supportURLString,
            "https://" + AboutSettingsPane.supportDisplayAddress
        )
    }
}
