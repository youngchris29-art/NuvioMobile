import XCTest

/// Pure-logic coverage for BUG-39's frame-vs-resolution trade (beta.12) — see
/// `AnimatedGifDecoder.GifDecodePlanner` in `NuvioTV/DesignSystem/AnimatedGifImage.swift`.
///
/// Deliberately does NOT launch `XCUIApplication` — plain, fast asserts against the planning
/// function. Same reason this file MIRRORS the production logic instead of importing it as
/// `StreamBadgeColorTests.swift` explains at length: `NuvioTVUITests` is a UI-testing bundle in its
/// own runner process, so `@testable import NuvioTV` links nothing. The planner was written as pure
/// Swift (no ImageIO/UIKit) precisely so this mirror can be exact. Keep it in sync by hand with
/// `GifDecodePlanner` (+ `AnimatedGifDecoder.decodeBudgetBytes` / `decodeLimits`) whenever that
/// logic changes; if `NuvioTV` ever grows a hosted unit-test target, move these there and delete
/// the mirror.
final class GifDecodePlanTests: XCTestCase {

    // MARK: - Mirror of AnimatedGifDecoder.GifDecodePlanner

    private struct Limits {
        let ceiling: Int; let preferredMinSide: Int; let minSide: Int; let budgetBytes: Int
        func clamped(toSourceLongEdge edge: Int?) -> Limits {
            guard let edge, edge > 0, edge < ceiling else { return self }
            return Limits(ceiling: edge, preferredMinSide: preferredMinSide, minSide: minSide, budgetBytes: budgetBytes)
        }
    }
    private struct Plan: Equatable { let side: Int; let keepCount: Int; let minKeptFrames: Int }

    private let maxSubsampledFrameDelayCentiseconds = 12
    private let estimatedRowAlignmentBytes = 32

    private func frameBytes(side: Int, aspect: Double) -> Int {
        let width: Int
        let height: Int
        if aspect >= 1 {
            width = side
            height = max(1, Int((Double(side) / aspect).rounded()))
        } else {
            width = max(1, Int((Double(side) * aspect).rounded()))
            height = side
        }
        let row = width * 4
        let alignedRow = (row + estimatedRowAlignmentBytes - 1) / estimatedRowAlignmentBytes * estimatedRowAlignmentBytes
        return alignedRow * height
    }

    private func minKeptFrames(count: Int, delays: [Int]) -> Int {
        guard count > 0 else { return 0 }
        let total = delays.reduce(0, +)
        let byRate = (total + maxSubsampledFrameDelayCentiseconds - 1) / maxSubsampledFrameDelayCentiseconds
        return min(count, max(1, byRate))
    }

    private func largestSide(fitting frames: Int, aspect: Double, lo: Int, hi: Int, budget: Int) -> Int? {
        guard hi >= lo, frames > 0 else { return nil }
        let pixelsPerFrame = Double(budget) / (4.0 * Double(frames))
        let estimate = aspect >= 1
            ? (pixelsPerFrame * aspect).squareRoot()
            : (pixelsPerFrame / aspect).squareRoot()
        var side = min(hi, Int(estimate))
        while side >= lo {
            if frames * frameBytes(side: side, aspect: aspect) <= budget { return side }
            side -= 1
        }
        return nil
    }

    private func framesFitting(side: Int, aspect: Double, budget: Int) -> Int {
        budget / max(frameBytes(side: side, aspect: aspect), 1)
    }

    private func plan(count: Int, aspect rawAspect: Double, delays: [Int], limits: Limits) -> Plan {
        let aspect = rawAspect.isFinite && rawAspect > 0 ? rawAspect : 1.0
        let ceiling = max(limits.ceiling, 1)
        let minSide = max(1, min(limits.minSide, ceiling))
        let preferred = max(minSide, min(limits.preferredMinSide, ceiling))
        let budget = max(limits.budgetBytes, 1)
        let minKept = minKeptFrames(count: count, delays: delays)
        guard count > 0 else { return Plan(side: ceiling, keepCount: 0, minKeptFrames: 0) }

        if let side = largestSide(fitting: count, aspect: aspect, lo: preferred, hi: ceiling, budget: budget) {
            return Plan(side: side, keepCount: count, minKeptFrames: minKept)
        }
        let keepAtPreferred = min(count, framesFitting(side: preferred, aspect: aspect, budget: budget))
        if keepAtPreferred >= minKept {
            return Plan(side: preferred, keepCount: keepAtPreferred, minKeptFrames: minKept)
        }
        if let side = largestSide(fitting: minKept, aspect: aspect, lo: minSide, hi: preferred, budget: budget) {
            return Plan(side: side, keepCount: minKept, minKeptFrames: minKept)
        }
        let keepAtFloor = max(1, min(count, framesFitting(side: minSide, aspect: aspect, budget: budget)))
        return Plan(side: minSide, keepCount: keepAtFloor, minKeptFrames: minKept)
    }

    // MARK: - Mirror of AnimatedGifDecoder.decodeBudgetBytes / decodeLimits

    private let maxDecodedBytesPerGif = 12 * 1024 * 1024
    private let minFramePixelSize = 200
    private let maxFramePixelSize = 400

    private func decodeBudgetBytes(scale: CGFloat) -> Int {
        let cappedScale = max(1.0, min(scale.isFinite ? scale : 1.0, 2.0))
        let growth = 1.0 + 0.5 * (cappedScale - 1.0)
        return Int((Double(maxDecodedBytesPerGif) * growth).rounded())
    }

    private func targetDecodePixelCeiling(for targetSize: CGSize, scale: CGFloat) -> Int {
        let cappedScale = min(scale, 2.0)
        let pixelCap = Int((CGFloat(maxFramePixelSize) * cappedScale).rounded())
        let longEdge = max(targetSize.width, targetSize.height)
        guard longEdge.isFinite, longEdge > 0 else { return pixelCap }
        let pixels = Int((longEdge * cappedScale).rounded())
        return min(pixelCap, max(minFramePixelSize, pixels))
    }

    private func decodeLimits(for targetSize: CGSize, scale: CGFloat) -> Limits {
        let ceiling = targetDecodePixelCeiling(for: targetSize, scale: scale)
        let longEdge = max(targetSize.width, targetSize.height)
        let pointSide = longEdge.isFinite && longEdge > 0 ? Int(longEdge.rounded()) : ceiling
        return Limits(
            ceiling: ceiling,
            preferredMinSide: min(ceiling, max(minFramePixelSize, pointSide)),
            minSide: minFramePixelSize,
            budgetBytes: decodeBudgetBytes(scale: scale)
        )
    }

    // The default-PosterStyle landscape collection tile (`FolderTile`: 220 × 16/9 ≈ 391 × 220 pt),
    // which is what the 2026-08-11 device pass measured BUG-39 on.
    private let landscapeTile = CGSize(width: 220 * 16 / 9, height: 220)
    private let squareTile = CGSize(width: 220, height: 220)
    private let portraitTile = CGSize(width: 220, height: 330)
    private let deviceGifAspect = 1.75   // 200×114 px frames at the 200 px floor = 7113600 / 78 bytes

    // MARK: - Budget

    func testBudget_isBaseOnHD_and1_5xOn4K_andCappedAbove2x() {
        XCTAssertEqual(decodeBudgetBytes(scale: 1), 12 * 1024 * 1024)
        XCTAssertEqual(decodeBudgetBytes(scale: 2), 18 * 1024 * 1024)
        XCTAssertEqual(decodeBudgetBytes(scale: 3), 18 * 1024 * 1024)
        XCTAssertEqual(decodeBudgetBytes(scale: .nan), 12 * 1024 * 1024)
    }

    func testLimits_landscapeTile4K() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        XCTAssertEqual(l.ceiling, 782)          // the device probe's `ceiling=782`
        XCTAssertEqual(l.preferredMinSide, 391) // 1 px per point
        XCTAssertEqual(l.minSide, 200)
        XCTAssertEqual(l.budgetBytes, 18 * 1024 * 1024)
    }

    func testLimits_HD_preferredEqualsCeiling() {
        let l = decodeLimits(for: landscapeTile, scale: 1)
        XCTAssertEqual(l.ceiling, 391)
        XCTAssertEqual(l.preferredMinSide, 391)
        XCTAssertEqual(l.budgetBytes, 12 * 1024 * 1024)
    }

    // MARK: - The device-measured case

    /// The pre-trade code decoded this GIF at 200×114 px × 78 frames (`side=200 ceiling=782
    /// sourceFrames=90 keptFrames=78 bytes=7113600` on the Living Room 4K). Tier 4 now lands it at
    /// 328 px wide × 75 frames: 2.7× the pixels per frame, ~5 fewer unique frames than before out of
    /// 90 (still ≥ 8 fps for a 10 cs source), and the plan actually spends the budget.
    func testDeviceCase_90frameLandscape_10cs_4K() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        let p = plan(count: 90, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 90), limits: l)
        XCTAssertEqual(p, Plan(side: 328, keepCount: 75, minKeptFrames: 75))
        XCTAssertLessThanOrEqual(75 * frameBytes(side: 328, aspect: deviceGifAspect), l.budgetBytes)
        // And it did not leave more than one frame's worth of budget unspent.
        XCTAssertGreaterThan(75 * frameBytes(side: 329, aspect: deviceGifAspect), l.budgetBytes - frameBytes(side: 329, aspect: deviceGifAspect))
    }

    /// Same GIF, faster source (5 cs/frame): the rate floor allows dropping to 38 frames, so tier 3
    /// holds the full 1 px/pt side (391) and keeps 53 — every kept frame still ≤ 12 cs.
    func testDeviceCase_90frameLandscape_5cs_4K_holdsPreferredSide() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        let p = plan(count: 90, aspect: deviceGifAspect, delays: Array(repeating: 5, count: 90), limits: l)
        XCTAssertEqual(p, Plan(side: 391, keepCount: 53, minKeptFrames: 38))
    }

    /// HD panel, same GIF: aspect-awareness alone lifts it from 200 to 270 px wide (the old
    /// square-frame estimate wasted ~40% of the budget on landscape frames).
    func testDeviceCase_90frameLandscape_10cs_HD() {
        let l = decodeLimits(for: landscapeTile, scale: 1)
        let p = plan(count: 90, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 90), limits: l)
        XCTAssertEqual(p, Plan(side: 270, keepCount: 75, minKeptFrames: 75))
    }

    // MARK: - Tiers

    func testTier1_shortGif_fullCeiling_allFrames() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        let p = plan(count: 10, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 10), limits: l)
        XCTAssertEqual(p, Plan(side: 782, keepCount: 10, minKeptFrames: 9))
    }

    func testTier2_squareTile_allFramesAboveHDParity() {
        let l = decodeLimits(for: squareTile, scale: 2)   // ceiling 440, preferred 220
        let p = plan(count: 60, aspect: 1.0, delays: Array(repeating: 10, count: 60), limits: l)
        XCTAssertEqual(p, Plan(side: 280, keepCount: 60, minKeptFrames: 50))
        XCTAssertGreaterThanOrEqual(p.side, l.preferredMinSide)
    }

    func testTier2_portraitTile_aspectBelowOne() {
        let l = decodeLimits(for: portraitTile, scale: 2)   // ceiling 660, preferred 330
        let p = plan(count: 40, aspect: 2.0 / 3.0, delays: Array(repeating: 8, count: 40), limits: l)
        XCTAssertEqual(p, Plan(side: 420, keepCount: 40, minKeptFrames: 27))
        // Portrait: the long edge is the HEIGHT, so bytes are width(=side×aspect) × side.
        XCTAssertEqual(frameBytes(side: 420, aspect: 2.0 / 3.0), 1120 * 420)
    }

    func testTier5_pathologicalLength_floorSide_keepsWhatFits() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        let p = plan(count: 400, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 400), limits: l)
        XCTAssertEqual(p, Plan(side: 200, keepCount: 206, minKeptFrames: 334))
        XCTAssertLessThanOrEqual(206 * frameBytes(side: 200, aspect: deviceGifAspect), l.budgetBytes)
    }

    // MARK: - Invariants

    func testEveryPlan_fitsBudget_andRespectsClamps() {
        let l4k = decodeLimits(for: landscapeTile, scale: 2)
        let lhd = decodeLimits(for: squareTile, scale: 1)
        for limits in [l4k, lhd] {
            for count in [1, 3, 12, 30, 78, 90, 150, 600] {
                for aspect in [0.5, 2.0 / 3.0, 1.0, 1.75, 2.4] {
                    for delay in [2, 5, 10, 20, 100] {
                        let p = plan(count: count, aspect: aspect, delays: Array(repeating: delay, count: count), limits: limits)
                        XCTAssertLessThanOrEqual(p.keepCount * frameBytes(side: p.side, aspect: aspect), limits.budgetBytes,
                                                 "count=\(count) aspect=\(aspect) delay=\(delay) → \(p)")
                        XCTAssertGreaterThanOrEqual(p.side, limits.minSide)
                        XCTAssertLessThanOrEqual(p.side, limits.ceiling)
                        XCTAssertGreaterThanOrEqual(p.keepCount, 1)
                        XCTAssertLessThanOrEqual(p.keepCount, count)
                        // Frames are only dropped once resolution has already fallen to HD parity.
                        if p.keepCount < count { XCTAssertLessThanOrEqual(p.side, limits.preferredMinSide) }
                        // Resolution only goes below HD parity once the frame floor is binding.
                        if p.side < limits.preferredMinSide { XCTAssertLessThanOrEqual(p.keepCount, p.minKeptFrames) }
                    }
                }
            }
        }
    }

    func testDegenerateInputs() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        XCTAssertEqual(plan(count: 0, aspect: 1, delays: [], limits: l), Plan(side: 782, keepCount: 0, minKeptFrames: 0))
        // Non-finite / non-positive aspect → treated as square.
        XCTAssertEqual(plan(count: 10, aspect: .nan, delays: Array(repeating: 10, count: 10), limits: l),
                       plan(count: 10, aspect: 1, delays: Array(repeating: 10, count: 10), limits: l))
        XCTAssertEqual(plan(count: 10, aspect: 0, delays: Array(repeating: 10, count: 10), limits: l),
                       plan(count: 10, aspect: 1, delays: Array(repeating: 10, count: 10), limits: l))
        // Missing delays (parser failure) → rate floor is 1 frame, plan still valid.
        let p = plan(count: 30, aspect: 1, delays: [], limits: l)
        XCTAssertEqual(p.minKeptFrames, 1)
        XCTAssertLessThanOrEqual(p.keepCount * frameBytes(side: p.side, aspect: 1), l.budgetBytes)
    }

    /// ImageIO never upscales: a 300×171 source on the 782-ceiling tile is planned at a 300 ceiling,
    /// where all 90 frames fit at the source's own size — no frames are traded for pixels the
    /// source doesn't have. (Unclamped, the planner would have dropped to 75 frames at 328.)
    func testSourceSmallerThanTile_clampsCeiling_keepsAllFrames() {
        let l = decodeLimits(for: landscapeTile, scale: 2).clamped(toSourceLongEdge: 300)
        XCTAssertEqual(l.ceiling, 300)
        let p = plan(count: 90, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 90), limits: l)
        XCTAssertEqual(p, Plan(side: 300, keepCount: 90, minKeptFrames: 75))
        // A source larger than the ceiling leaves the limits untouched.
        XCTAssertEqual(decodeLimits(for: landscapeTile, scale: 2).clamped(toSourceLongEdge: 1280).ceiling, 782)
        XCTAssertEqual(decodeLimits(for: landscapeTile, scale: 2).clamped(toSourceLongEdge: nil).ceiling, 782)
    }

    func testMinKeptFrames_isDurationOverTwelveCentiseconds() {
        XCTAssertEqual(minKeptFrames(count: 90, delays: Array(repeating: 10, count: 90)), 75)
        XCTAssertEqual(minKeptFrames(count: 90, delays: Array(repeating: 5, count: 90)), 38)
        XCTAssertEqual(minKeptFrames(count: 5, delays: Array(repeating: 100, count: 5)), 5)   // never above count
        XCTAssertEqual(minKeptFrames(count: 5, delays: Array(repeating: 2, count: 5)), 1)     // never below 1
    }
}
