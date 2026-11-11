import XCTest
import SwiftUI
import UIKit
@testable import NuvioTV

/// A tester's badge-pack entry as checked in under `Fixtures/` (fields only; the artwork is not
/// ours to redistribute, so the tests draw synthetic artwork of the same kind).
struct BadgePackFixtureEntry: Decodable {
    let name: String
    let tagStyle: String
    let tagColor: String
    let textColor: String
    let borderColor: String
    let imageURL: String
    /// "raster" (decodes on tvOS) or "svg" (does not: the chip shows the name).
    let imageKind: String
}

/// Shared harness for the hosted badge render tests and the opt-in probe: no network, ever.
@MainActor
enum BadgeChipRenderHarness {
    static let restBackdrop = Color(hex: 0x1A1A1A)
    static let size = CGSize(width: 260, height: 70)

    static func fixture(_ pack: String) throws -> [BadgePackFixtureEntry] {
        let name = "badge-pack-\(pack)-first4"
        let bundle = Bundle(for: BadgeFixtureAnchor.self)
        let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        let found = try XCTUnwrap(url, "fixture \(name).json is not in the test bundle")
        struct File: Decodable { let filters: [BadgePackFixtureEntry] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: found)).filters
    }

    /// Synthetic artwork: a raster PNG (white bar on the left 40 %, transparent elsewhere) and a
    /// minimal SVG, written to a fresh temp dir. Returns `file://` URLs.
    static func writeArtwork() throws -> (png: URL, svg: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badge-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 120, height: 52)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width * 0.4, height: size.height))
        }
        let pngURL = dir.appendingPathComponent("art.png")
        try png.write(to: pngURL)
        let svgURL = dir.appendingPathComponent("art.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="60" height="26"><text x="4" y="18" fill="#fff">4K</text></svg>"##.utf8)
            .write(to: svgURL)
        return (pngURL, svgURL)
    }

    static func info(_ e: BadgePackFixtureEntry, art: (png: URL, svg: URL)) -> StreamBadgeInfo {
        StreamBadgeInfo(name: e.name,
                        imageURL: (e.imageKind == "svg" ? art.svg : art.png).absoluteString,
                        tagColor: e.tagColor, tagStyle: e.tagStyle,
                        textColor: e.textColor, borderColor: e.borderColor)
    }

    static func render(_ info: StreamBadgeInfo, focused: Bool, settleSteps: Int = 12) async -> UIImage {
        let view = ZStack {
            focused ? Color.white : restBackdrop
            StreamBadgeChipView(badge: info)
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
        .environment(\.colorScheme, focused ? .light : .dark)
        .environment(\.settingsRowIsFocused, focused)
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.safeAreaRegions = []
        for _ in 0..<settleSteps {
            try? await Task.sleep(nanoseconds: 100_000_000)
            host.view.layoutIfNeeded()
        }
        let img = UIGraphicsImageRenderer(bounds: window.bounds).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        window.isHidden = true
        return img
    }

    /// RGB at a point (in points) of a rendered image.
    static func px(_ img: UIImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        guard let cg = img.cgImage else { return (0, 0, 0) }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let sc = Int(img.scale)
        let i = (min(y * sc, h - 1) * w + min(x * sc, w - 1)) * 4
        return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
    }

    /// Inside the chip, 3 pt under its top edge, centred: clear of the artwork bar, the fallback
    /// text and the border, so it shows the colour the chip paints behind them.
    static let interior = (x: 130, y: 21)
    /// Outside the chip: the row backdrop.
    static let outside = (x: 4, y: 4)
}

final class BadgeFixtureAnchor {}

/// GitHub #25 follow-up: on the highlighted row a non-filled image chip's interior is the row's
/// resting card colour, the same as at rest (spec `spec-badge-focus-2026-11-11`, option D).
@MainActor
final class StreamBadgeChipRenderTests: XCTestCase {
    private typealias H = BadgeChipRenderHarness

    private func assertNear(_ got: (Int, Int, Int), _ want: (Int, Int, Int), _ msg: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(got.0 - want.0), 2, "\(msg) r=\(got)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(got.1 - want.1), 2, "\(msg) g=\(got)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(got.2 - want.2), 2, "\(msg) b=\(got)", file: file, line: line)
    }

    func testFocusedChipInteriorMatchesRest() async throws {
        let art = try H.writeArtwork()
        for pack in ["xperience", "sweatycab"] {
            let entries = try H.fixture(pack)
            XCTAssertFalse(entries.isEmpty)
            for e in entries.prefix(2) {
                let info = H.info(e, art: art)
                let rest = await H.render(info, focused: false)
                let focused = await H.render(info, focused: true)
                let want = (26, 26, 26)
                assertNear(H.px(rest, H.interior.x, H.interior.y), want, "\(pack) \(e.name) rest interior")
                assertNear(H.px(focused, H.interior.x, H.interior.y), want, "\(pack) \(e.name) focused interior")
                // The accepted remaining edge: the backdrop outside the chip is the white platter.
                assertNear(H.px(focused, H.outside.x, H.outside.y), (255, 255, 255), "\(pack) platter")
            }
        }
    }

    func testSvgArtworkDoesNotDecode() throws {
        let art = try H.writeArtwork()
        let svg = try Data(contentsOf: art.svg)
        let png = try Data(contentsOf: art.png)
        XCTAssertNil(BadgeImageDecoder.decodeThumbnail(data: svg, maxPixel: 400),
                     "tvOS ImageIO decodes SVG now: SVG badge packs could render; revisit the spec's section 3")
        XCTAssertNotNil(BadgeImageDecoder.decodeThumbnail(data: png, maxPixel: 400))
    }
}
