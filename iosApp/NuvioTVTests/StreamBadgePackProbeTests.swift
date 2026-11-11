import XCTest
import SwiftUI
import UIKit
@testable import NuvioTV

/// Opt-in evidence probe (GitHub #25): renders the real `StreamBadgeChipView` for the checked-in
/// first entries of two tester badge packs (`Fixtures/badge-pack-*-first4.json`) at rest and on the
/// focus platter, saves PNGs and prints the sampled interior colours. Skips unless
/// `BADGE_PROBE_OUT` (read as `TEST_RUNNER_BADGE_PROBE_OUT`) names an output directory. No network:
/// the artwork is the synthetic raster / SVG of `BadgeChipRenderHarness`. Never part of a gate.
@MainActor
final class StreamBadgePackProbeTests: XCTestCase {
    func testPackBadgesRestVersusPlatter() async throws {
        guard let outDir = ProcessInfo.processInfo.environment["BADGE_PROBE_OUT"] else {
            throw XCTSkip("BADGE_PROBE_OUT not set")
        }
        typealias H = BadgeChipRenderHarness
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let art = try H.writeArtwork()
        for pack in ["xperience", "sweatycab"] {
            for (i, e) in try H.fixture(pack).enumerated() {
                let info = H.info(e, art: art)
                let rest = await H.render(info, focused: false)
                let foc = await H.render(info, focused: true)
                for (suffix, img) in [("rest", rest), ("focused", foc)] {
                    if let d = img.pngData() {
                        try d.write(to: URL(fileURLWithPath: outDir)
                            .appendingPathComponent("\(pack)-\(String(format: "%02d", i))-\(suffix).png"))
                    }
                }
                print("[BadgeProbe] \(pack) #\(i) \(e.name) interior rest=\(H.px(rest, H.interior.x, H.interior.y)) focused=\(H.px(foc, H.interior.x, H.interior.y)) outside focused=\(H.px(foc, H.outside.x, H.outside.y))")
            }
        }
    }
}
