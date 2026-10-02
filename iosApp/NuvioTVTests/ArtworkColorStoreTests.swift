import XCTest
import SwiftUI
import UIKit
@testable import NuvioTV

/// rc14 FEAT-46 (Steven rc13 verdict, 2026-09-30: "make the poster border dynamic, so that it
/// adapts to the dominant color of each poster"): the pure sampling half of `ArtworkColorStore`
/// (`DesignSystem/ArtworkColorStore.swift`) — the 16×16 draw, the saturation-weighted mean, the
/// grey verdict and the ring lift. Every image is synthesized at 16×16 / scale 1 / standard range,
/// so the draw into the sampler's own 16×16 bitmap is 1:1 and no interpolation can blend colours.
///
/// The store's asynchronous path (sample off-main, answer on the main actor) is not driven here:
/// the only way to put a decoded image into `ArtworkStore`'s memory is a real `ArtworkStore.fetch`,
/// which queues behind whatever the test host app is loading, so it cannot be made deterministic.
/// The synchronous "not in memory → nil, no download" contract is pinned instead.
final class ArtworkColorStoreTests: XCTestCase {

    private func image(_ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            draw(context.cgContext)
        }
    }

    private func solid(_ color: UIColor) -> UIImage {
        image { context in
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    /// Hue distance on the colour wheel (0…0.5), so red at 0.99 and 0.01 count as close.
    private func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    // MARK: - dominantColor

    func testSolidOrangeKeepsItsHueAndClearsTheRingFloors() throws {
        let orange = UIColor(red: 1, green: 0.5, blue: 0, alpha: 1)   // hue 30° ≈ 0.083
        let cgImage = try XCTUnwrap(solid(orange).cgImage)
        let rgb = try XCTUnwrap(ArtworkColorStore.dominantColor(of: cgImage))
        let hsb = ArtworkColorStore.hsb(r: rgb.r, g: rgb.g, b: rgb.b)
        XCTAssertLessThan(hueDistance(hsb.h, 30.0 / 360.0), 0.05, "hue \(hsb.h)")
        XCTAssertGreaterThanOrEqual(hsb.s, ArtworkColorStore.minRingSaturation - 0.001)
        XCTAssertGreaterThanOrEqual(hsb.v, ArtworkColorStore.minRingBrightness - 0.001)
    }

    func testSolidGreyIsNil() throws {
        let grey = UIColor(white: 0.5, alpha: 1)
        let cgImage = try XCTUnwrap(solid(grey).cgImage)
        XCTAssertNil(ArtworkColorStore.dominantColor(of: cgImage))
        // The SwiftUI wrapper the store actually calls agrees.
        XCTAssertNil(ArtworkColorStore.dominantColor(of: solid(grey)))
    }

    func testSolidBlackIsNil() throws {
        // A black poster has no hue to give; it must keep the accent ring, not divide by zero.
        let cgImage = try XCTUnwrap(solid(.black).cgImage)
        XCTAssertNil(ArtworkColorStore.dominantColor(of: cgImage))
    }

    func testHalfRedHalfGreyIsRed() throws {
        let split = image { context in
            context.setFillColor(UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
            context.setFillColor(UIColor(white: 0.5, alpha: 1).cgColor)
            context.fill(CGRect(x: 8, y: 0, width: 8, height: 16))
        }
        let cgImage = try XCTUnwrap(split.cgImage)
        let rgb = try XCTUnwrap(ArtworkColorStore.dominantColor(of: cgImage))
        let hsb = ArtworkColorStore.hsb(r: rgb.r, g: rgb.g, b: rgb.b)
        // Grey weighs nothing, so the grey half must not drag the result toward a muddy pink.
        XCTAssertLessThan(hueDistance(hsb.h, 0), 0.05, "hue \(hsb.h)")
        XCTAssertGreaterThan(hsb.s, 0.9, "saturation \(hsb.s)")
    }

    func testSwiftUIWrapperReturnsAColourForVividArt() {
        XCTAssertNotNil(ArtworkColorStore.dominantColor(of: solid(UIColor(red: 1, green: 0.5, blue: 0, alpha: 1))))
    }

    // MARK: - lifted

    func testLiftFloorsDullColoursAndKeepsTheHue() {
        let lifted = ArtworkColorStore.lifted(h: 0.6, s: 0.2, v: 0.3)
        XCTAssertEqual(lifted.h, 0.6, accuracy: 0.0001)
        XCTAssertEqual(lifted.s, ArtworkColorStore.minRingSaturation, accuracy: 0.0001)
        XCTAssertEqual(lifted.v, ArtworkColorStore.minRingBrightness, accuracy: 0.0001)
    }

    func testLiftLeavesVividColoursAlone() {
        let lifted = ArtworkColorStore.lifted(h: 0.33, s: 0.9, v: 0.95)
        XCTAssertEqual(lifted.h, 0.33, accuracy: 0.0001)
        XCTAssertEqual(lifted.s, 0.9, accuracy: 0.0001)
        XCTAssertEqual(lifted.v, 0.95, accuracy: 0.0001)
    }

    // MARK: - rail lift (beta.18 verdict, FEAT-46 corrected / FEAT-40 follow-up)

    func testRailLiftFullBrightnessAndClampedSaturation() {
        let low = ArtworkColorStore.railLifted(h: 0.6, s: 0.2, v: 0.3)
        XCTAssertEqual(low.h, 0.6, accuracy: 0.0001)
        XCTAssertEqual(low.s, 0.40, accuracy: 0.0001)
        XCTAssertEqual(low.v, 1.0, accuracy: 0.0001)
        let mid = ArtworkColorStore.railLifted(h: 0.1, s: 0.5, v: 0.6)
        XCTAssertEqual(mid.h, 0.1, accuracy: 0.0001)
        XCTAssertEqual(mid.s, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mid.v, 1.0, accuracy: 0.0001)
        let high = ArtworkColorStore.railLifted(h: 0.33, s: 0.95, v: 0.4)
        XCTAssertEqual(high.h, 0.33, accuracy: 0.0001)
        XCTAssertEqual(high.s, 0.70, accuracy: 0.0001)
        XCTAssertEqual(high.v, 1.0, accuracy: 0.0001)
    }

    /// One 16x16 sample, two lifts: the ring and the rail of the same art share the mean's hue.
    func testRingAndRailDeriveFromOneMean() throws {
        let orange = UIColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        let mean = try XCTUnwrap(ArtworkColorStore.meanChroma(of: solid(orange)))
        let ring = ArtworkColorStore.ringLifted(h: mean.h, s: mean.s, v: mean.v)
        let rail = ArtworkColorStore.railLifted(h: mean.h, s: mean.s, v: mean.v)
        XCTAssertEqual(ring.h, rail.h, accuracy: 0.0001)
        XCTAssertLessThan(hueDistance(mean.h, 30.0 / 360.0), 0.05, "hue \(mean.h)")
        // The pre-existing ring path is the same lift of the same mean.
        let cgImage = try XCTUnwrap(solid(orange).cgImage)
        let rgb = try XCTUnwrap(ArtworkColorStore.dominantColor(of: cgImage))
        let hsb = ArtworkColorStore.hsb(r: rgb.r, g: rgb.g, b: rgb.b)
        XCTAssertEqual(hsb.h, ring.h, accuracy: 0.001)
    }

    func testGreyArtGivesNoRailColour() throws {
        XCTAssertNil(ArtworkColorStore.meanChroma(of: solid(UIColor(white: 0.5, alpha: 1))))
        XCTAssertNil(ArtworkColorStore.meanChroma(of: solid(.black)))
        XCTAssertNil(ArtworkColorStore.color(from: nil, use: .rail))
    }

    // MARK: - HSB round trip

    func testHSBRoundTrip() {
        for (r, g, b) in [(1.0, 0.5, 0.0), (0.2, 0.4, 0.9), (0.1, 0.8, 0.3), (0.7, 0.1, 0.6)] as [(CGFloat, CGFloat, CGFloat)] {
            let hsb = ArtworkColorStore.hsb(r: r, g: g, b: b)
            let back = ArtworkColorStore.rgb(h: hsb.h, s: hsb.s, v: hsb.v)
            XCTAssertEqual(back.r, r, accuracy: 0.0001)
            XCTAssertEqual(back.g, g, accuracy: 0.0001)
            XCTAssertEqual(back.b, b, accuracy: 0.0001)
        }
    }

    // MARK: - Store contract

    /// Never downloads: art that is not already decoded in `ArtworkStore`'s memory answers nil,
    /// synchronously, inside the call.
    @MainActor
    func testArtNotInMemoryAnswersNilSynchronously() {
        let neverFetched = "https://example.invalid/feat46-never-fetched-\(UUID().uuidString).jpg"
        var answered = false
        var answeredAColour = false
        ArtworkColorStore.shared.color(for: [neverFetched, nil, ""]) { color in
            answered = true
            answeredAColour = color != nil
        }
        XCTAssertTrue(answered, "completion must run inside the call when nothing is in memory")
        XCTAssertFalse(answeredAColour)
        XCTAssertNil(ArtworkColorStore.shared.cachedColor(for: [neverFetched]))
    }

    /// Same contract for the rail lift: not in memory, nothing downloaded, nil inside the call.
    @MainActor
    func testRailColorNotInMemoryAnswersNilSynchronously() {
        let neverFetched = "https://example.invalid/feat46-rail-never-fetched-\(UUID().uuidString).jpg"
        var answered = false
        var answeredAColour = false
        ArtworkColorStore.shared.color(for: [neverFetched, nil, ""], use: .rail) { color in
            answered = true
            answeredAColour = color != nil
        }
        XCTAssertTrue(answered, "completion must run inside the call when nothing is in memory")
        XCTAssertFalse(answeredAColour)
        XCTAssertNil(ArtworkColorStore.shared.cachedColor(for: [neverFetched], use: .rail))
    }
}
