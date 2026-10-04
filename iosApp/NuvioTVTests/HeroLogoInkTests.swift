import UIKit
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (M5, BUG-138; thresholds per critique #10): the hero logo ink check. Only a
/// near-black, low-chroma wordmark is whitened (`.dark`); red, blue, Netflix red and white stay as
/// drawn (`.legible`); a transparent bitmap or an opaque dark box is no logo at all (`.blank`).
@MainActor
final class HeroLogoInkTests: XCTestCase {

    private let side = HeroLogoInk.side

    /// A 32×32 premultiplied RGBA8 buffer: the first `coverage` of the pixels carry the glyph colour
    /// at `alpha`, the rest are transparent.
    private func pixels(r: UInt8, g: UInt8, b: UInt8, alpha: UInt8 = 255, coverage: Double) -> [UInt8] {
        let total = side * side
        let inked = Int((Double(total) * coverage).rounded())
        var out = [UInt8](repeating: 0, count: total * 4)
        func premultiplied(_ c: UInt8) -> UInt8 { UInt8((Double(c) * Double(alpha) / 255).rounded()) }
        for index in 0..<inked {
            out[index * 4] = premultiplied(r)
            out[index * 4 + 1] = premultiplied(g)
            out[index * 4 + 2] = premultiplied(b)
            out[index * 4 + 3] = alpha
        }
        return out
    }

    // MARK: - The table (critique #10)

    func testAllTransparentIsBlank() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 0, g: 0, b: 0, alpha: 0, coverage: 1)), .blank)
    }

    func testBlackGlyphOnTransparentIsDark() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 0, g: 0, b: 0, coverage: 0.25)), .dark)
    }

    func testDarkGreyGlyphIsDark() {
        let grey = UInt8((0.05 * 255).rounded())
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: grey, g: grey, b: grey, coverage: 0.25)), .dark)
    }

    func testPureRedGlyphIsLegible() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 255, g: 0, b: 0, coverage: 0.25)), .legible)
    }

    /// Pure blue's luma (0.0722) is under the dark threshold; its chroma is what keeps it as drawn.
    func testPureBlueGlyphIsLegible() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 0, g: 0, b: 255, coverage: 0.25)), .legible)
    }

    func testNetflixRedIsLegible() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 229, g: 9, b: 20, coverage: 0.25)), .legible)
    }

    func testWhiteGlyphIsLegible() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 255, g: 255, b: 255, coverage: 0.25)), .legible)
    }

    func testOpaqueBlackBoxIsBlank() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 0, g: 0, b: 0, coverage: 1)), .blank)
    }

    func testOpaqueMidGreyIsLegible() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 128, g: 128, b: 128, coverage: 1)), .legible)
    }

    // MARK: - Edges of the rule

    /// Premultiplied soft edges are un-premultiplied before the luma/chroma read: a half-alpha black
    /// glyph is still black ink, a half-alpha red glyph still red.
    func testSoftEdgesAreUnpremultiplied() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 0, g: 0, b: 0, alpha: 128, coverage: 0.25)), .dark)
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 255, g: 0, b: 0, alpha: 128, coverage: 0.25)), .legible)
    }

    /// Ink fainter than the alpha floor does not count, so a near-invisible haze reads blank.
    func testInkBelowTheAlphaFloorIsBlank() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 255, g: 255, b: 255, alpha: 20, coverage: 1)), .blank)
    }

    /// A few stray pixels (under 0.5 % of the frame) are nothing to read.
    func testTinyCoverageIsBlank() {
        XCTAssertEqual(HeroLogoInk.verdict(rgba: pixels(r: 255, g: 255, b: 255, coverage: 0.003)), .blank)
    }

    // MARK: - UIImage path and memo

    private func image(fill: UIColor, rect: CGRect, size: CGSize = CGSize(width: 200, height: 80)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            fill.setFill()
            context.fill(rect)
        }
    }

    func testImageVerdicts() {
        let glyph = CGRect(x: 20, y: 20, width: 160, height: 40)
        XCTAssertEqual(HeroLogoInk.verdict(of: image(fill: .black, rect: glyph)), .dark)
        XCTAssertEqual(HeroLogoInk.verdict(of: image(fill: .white, rect: glyph)), .legible)
        XCTAssertEqual(HeroLogoInk.verdict(of: image(fill: UIColor(red: 229 / 255, green: 9 / 255, blue: 20 / 255, alpha: 1),
                                                     rect: glyph)), .legible)
        XCTAssertEqual(HeroLogoInk.verdict(of: image(fill: .clear, rect: .zero)), .blank)
        XCTAssertEqual(HeroLogoInk.verdict(of: image(fill: .black, rect: CGRect(x: 0, y: 0, width: 200, height: 80))),
                       .blank, "an opaque dark box is not a wordmark")
    }

    func testMemoRoundTrip() async {
        let url = "https://example.com/logo-\(UUID().uuidString).png"
        XCTAssertNil(HeroLogoInk.cachedVerdict(for: url))
        HeroLogoInk.remember(.dark, for: url)
        XCTAssertEqual(HeroLogoInk.cachedVerdict(for: url), .dark)

        // `prepare` returns the memo without sampling, and memoizes a fresh sample.
        let white = image(fill: .white, rect: CGRect(x: 20, y: 20, width: 160, height: 40))
        let memoHit = await HeroLogoInk.prepare(white, url: url)
        XCTAssertEqual(memoHit, .dark)
        let freshURL = "https://example.com/logo-\(UUID().uuidString).png"
        let sampled = await HeroLogoInk.prepare(white, url: freshURL)
        XCTAssertEqual(sampled, .legible)
        XCTAssertEqual(HeroLogoInk.cachedVerdict(for: freshURL), .legible)
    }
}
