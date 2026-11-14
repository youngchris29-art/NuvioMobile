import XCTest
import SwiftUI
@testable import NuvioTV

/// Classic Home's Nuvio-style hero artwork fades in from the left on a smootherstep curve. These
/// tests pin the sampled stops: the curve starts clear, ends opaque at 45%, never decreases, and
/// has no abrupt slope change (the kink that showed as a hard line on bright art).
final class HomeHeroLeadingFadeTests: XCTestCase {

    private typealias Sample = (location: CGFloat, alpha: CGFloat)

    /// Slopes with a zero before the curve (the clear region) and a zero after it (the opaque
    /// region): `[0] + segment slopes + [0]`.
    private func slopes(_ samples: [Sample]) -> [CGFloat] {
        var s: [CGFloat] = [0]
        for i in 0..<(samples.count - 1) {
            s.append((samples[i + 1].alpha - samples[i].alpha) / (samples[i + 1].location - samples[i].location))
        }
        s.append(0)
        return s
    }

    /// The largest slope change between neighbouring segments, and the first segment's slope.
    private func metrics(_ samples: [Sample]) -> (maxChange: CGFloat, firstSlope: CGFloat) {
        let s = slopes(samples)
        var maxChange: CGFloat = 0
        for k in 0..<(s.count - 1) {
            maxChange = max(maxChange, abs(s[k + 1] - s[k]))
        }
        return (maxChange, s[1])
    }

    /// The three literal stops the mask used before the eased curve (clear at 0, 0.35 at 0.16,
    /// opaque at 0.32). Kept so the bound below is proven to separate old from new.
    private func oldStops() -> [Sample] {
        [(0.0, 0.0), (0.16, 0.35), (0.32, 1.0)]
    }

    func testFirstStopIsClearAtZero() {
        let first = HomeHeroLeadingFade.samples.first!
        XCTAssertEqual(first.location, 0, accuracy: 1e-9)
        XCTAssertEqual(first.alpha, 0, accuracy: 1e-9)
    }

    func testLastStopIsOpaqueAtEndLocation() {
        let last = HomeHeroLeadingFade.samples.last!
        XCTAssertEqual(last.alpha, 1, accuracy: 1e-9)
        XCTAssertEqual(last.location, 0.45, accuracy: 1e-9)
        XCTAssertEqual(HomeHeroLeadingFade.endLocation, 0.45, accuracy: 1e-9)
    }

    func testLocationsStrictlyIncreasingWithinUnitRange() {
        let samples = HomeHeroLeadingFade.samples
        for i in 0..<(samples.count - 1) {
            XCTAssertGreaterThan(samples[i + 1].location, samples[i].location, "location \(i + 1)")
        }
        for sample in samples {
            XCTAssertGreaterThanOrEqual(sample.location, 0)
            XCTAssertLessThanOrEqual(sample.location, 1)
        }
    }

    func testAlphaMonotonicNonDecreasing() {
        let samples = HomeHeroLeadingFade.samples
        for i in 0..<(samples.count - 1) {
            XCTAssertGreaterThanOrEqual(samples[i + 1].alpha, samples[i].alpha, "alpha \(i + 1)")
        }
    }

    func testSlopeChangeBounded() {
        let new = metrics(HomeHeroLeadingFade.samples)
        XCTAssertLessThan(new.maxChange, 1.5, "largest slope change between segments")
        XCTAssertLessThan(new.firstSlope, 0.25, "first segment slope")

        // The old stops fail both bounds (slope change 4.06, first slope 2.19), so the bounds
        // separate the two curves.
        let old = metrics(oldStops())
        XCTAssertGreaterThanOrEqual(old.maxChange, 1.5)
        XCTAssertGreaterThanOrEqual(old.firstSlope, 0.25)
    }

    func testSamplesMatchSmootherstep() {
        let samples = HomeHeroLeadingFade.samples
        XCTAssertEqual(samples.count, HomeHeroLeadingFade.segments + 1)
        for (i, sample) in samples.enumerated() {
            XCTAssertEqual(sample.alpha, HomeHeroLeadingFade.smootherstep(CGFloat(i) / 10), accuracy: 1e-9, "sample \(i)")
        }
        XCTAssertEqual(samples[5].alpha, 0.5, accuracy: 1e-9)
    }

    func testStopsMirrorSamples() {
        let samples = HomeHeroLeadingFade.samples
        let stops = HomeHeroLeadingFade.stops
        XCTAssertEqual(stops.count, samples.count)
        for (stop, sample) in zip(stops, samples) {
            XCTAssertEqual(stop.location, sample.location, accuracy: 1e-9)
        }
    }
}
