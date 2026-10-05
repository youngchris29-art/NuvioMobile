import Combine
import SharedCore
import SwiftUI
import XCTest
@testable import NuvioTV

/// A test payload: identity `id`, revision `rev` (same id, new rev = a same-identity gap-fill).
private nonisolated struct SwapItem: StageSwapPayload {
    let id: String
    var rev: Int = 0
    var swapIdentity: String { id }
}

/// `TextSwapTiming.stage`, spelled out so the cases do not depend on the launch knobs.
private let stageTiming = TextSwapTiming(pause: 0.45, fadeOut: 0.15, fadeIn: 0.20)

/// Home Stage & Strip (P1 §4, §9.3): the pure swap core, case by case on explicit times (§4.4's
/// timeline A–H plus the edge rules), with the three invariants asserted after every input; then the
/// driver on a fake clock.
@MainActor
final class StageSwapModelTests: XCTestCase {

    private typealias Core = StageSwapCore<SwapItem>

    /// Wraps a core and asserts I1–I3 around every input.
    private struct Harness {
        var core: Core

        init(timing: TextSwapTiming = stageTiming, reduceMotion: Bool = false, seed: String? = "P0") {
            core = Core(timing: timing, reduceMotion: reduceMotion)
            core.seed(seed.map { SwapItem(id: $0) })
        }

        mutating func at(_ t: TimeInterval, file: StaticString = #filePath, line: UInt = #line,
                         _ input: (inout Core) -> Void) {
            let before = core
            input(&core)
            Self.assertInvariants(before: before, after: core, now: t, file: file, line: line)
        }

        mutating func tick(_ t: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
            at(t, file: file, line: line) { $0.tick(now: t) }
        }

        static func assertInvariants(before: Core, after: Core, now t: TimeInterval,
                                     file: StaticString, line: UInt) {
            // I1: the shown identity changes only inside a swap, and only while hidden (or RM).
            if let was = before.shown?.swapIdentity, let isNow = after.shown?.swapIdentity, was != isNow {
                XCTAssertEqual(after.swaps, before.swaps + 1, "I1: identity changed outside a swap", file: file, line: line)
                XCTAssertTrue(before.textOpacity == 0 || after.reduceMotion,
                              "I1: swapped while the text was visible", file: file, line: line)
            }
            // I2: the gate never opens before the pause has run.
            if let gate = after.gateTime() {
                XCTAssertGreaterThanOrEqual(gate, after.lastActivity + after.timing.pause,
                                            "I2", file: file, line: line)
            }
            // I3: no fade-out starts mid-page or within `quiet` of rows motion.
            if after.phase == .fadingOut, before.phase != .fadingOut {
                XCTAssertFalse(after.pageInFlight, "I3: fade-out during a page", file: file, line: line)
                XCTAssertGreaterThanOrEqual(t + 1e-6, after.lastMotion + Core.quiet,
                                            "I3: fade-out within quiet of motion", file: file, line: line)
            }
        }
    }

    private func item(_ id: String, rev: Int = 0) -> SwapItem { SwapItem(id: id, rev: rev) }

    // MARK: Seed and clear

    func testSeedShowsAtOnceWithoutFade() {
        let h = Harness()
        XCTAssertEqual(h.core.shown, item("P0"))
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertEqual(h.core.textOpacity, 1)
        XCTAssertEqual(h.core.fade, .instant)
        XCTAssertEqual(h.core.swaps, 0)
    }

    func testFirstPresentWithNothingShownIsTheSeedPath() {
        var h = Harness(seed: nil)
        h.at(1) { $0.present(SwapItem(id: "P1"), now: 1) }
        XCTAssertEqual(h.core.shown, item("P1"))
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertEqual(h.core.fade, .instant)
        XCTAssertEqual(h.core.swaps, 0)
    }

    func testPresentNilClears() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.2) { $0.present(SwapItem(id: "P1"), now: 0.2) }
        h.at(0.3) { $0.present(nil, now: 0.3) }
        XCTAssertNil(h.core.shown)
        XCTAssertNil(h.core.pending)
        XCTAssertEqual(h.core.textOpacity, 1)
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertNil(h.core.nextDeadline)
    }

    // MARK: §4.4 timeline

    /// A. Right, no page: 0.20 present → 0.45 out → 0.60 swap → 0.80 idle, resting.
    func testCaseA_RightWithoutAPage() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        XCTAssertEqual(h.core.phase, .pausing)
        XCTAssertEqual(h.core.textOpacity, 1)
        XCTAssertEqual(h.core.nextDeadline ?? -1, 0.45, accuracy: 1e-9)
        h.tick(0.44)
        XCTAssertEqual(h.core.phase, .pausing)
        h.tick(0.45)
        XCTAssertEqual(h.core.phase, .fadingOut)
        XCTAssertEqual(h.core.textOpacity, 0)
        XCTAssertEqual(h.core.fade, .fadeOut(0.15))
        XCTAssertEqual(h.core.shown, item("P0"))
        XCTAssertEqual(h.core.swaps, 0)
        h.tick(0.60)
        XCTAssertEqual(h.core.phase, .fadingIn)
        XCTAssertEqual(h.core.shown, item("P1"))
        XCTAssertEqual(h.core.textOpacity, 1)
        XCTAssertEqual(h.core.fade, .fadeIn(0.20))
        XCTAssertEqual(h.core.swaps, 1)
        XCTAssertNil(h.core.resting)
        h.tick(0.80)
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertEqual(h.core.resting, "P1")
        XCTAssertNil(h.core.nextDeadline)
    }

    /// A row scroll still moving at 0.45 holds the fade-out until 0.05 s after it stops.
    func testCaseA_RowsMotionHoldsTheFadeOut() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.at(0.42) { $0.motion(at: 0.42) }
        XCTAssertEqual(h.core.nextDeadline ?? -1, 0.47, accuracy: 1e-9)
        h.tick(0.45)
        XCTAssertEqual(h.core.phase, .pausing, "motion 0.03 s before the gate holds it")
        h.tick(0.47)
        XCTAssertEqual(h.core.phase, .fadingOut)
    }

    /// B. Down, page 0.5 s: no gate while in flight; completion 0.50 + 0.05 still → out 0.55,
    /// swap 0.70, idle 0.90.
    func testCaseB_DownWithAPage() {
        var h = Harness()
        h.at(0) {
            $0.focusActivity(now: 0)
            $0.pageStarted(now: 0)
        }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        XCTAssertEqual(h.core.phase, .pausing)
        XCTAssertNil(h.core.gateTime(), "no gate while the page is in flight")
        XCTAssertNil(h.core.nextDeadline)
        h.tick(0.49)
        XCTAssertEqual(h.core.phase, .pausing)
        h.at(0.50) {
            $0.motion(at: 0.50)
            $0.pageEnded(now: 0.50)
        }
        XCTAssertEqual(h.core.nextDeadline ?? -1, 0.55, accuracy: 1e-9)
        h.tick(0.54)
        XCTAssertEqual(h.core.phase, .pausing)
        h.tick(0.55)
        XCTAssertEqual(h.core.phase, .fadingOut)
        h.tick(0.70)
        XCTAssertEqual(h.core.phase, .fadingIn)
        XCTAssertEqual(h.core.shown, item("P1"))
        XCTAssertEqual(h.core.swaps, 1)
        h.tick(0.90)
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertEqual(h.core.resting, "P1")
    }

    /// C. Two Rights 0.3 s apart: the gate moves to 0.75; P1 is replaced by P2 and never shown.
    func testCaseC_TwoRightsInARow() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.at(0.30) { $0.focusActivity(now: 0.30) }
        h.at(0.50) { $0.present(SwapItem(id: "P2"), now: 0.50) }
        XCTAssertEqual(h.core.pending, item("P2"))
        XCTAssertEqual(h.core.nextDeadline ?? -1, 0.75, accuracy: 1e-9)
        h.tick(0.74)
        XCTAssertEqual(h.core.phase, .pausing)
        h.tick(0.75)
        XCTAssertEqual(h.core.phase, .fadingOut)
        h.tick(0.90)
        XCTAssertEqual(h.core.shown, item("P2"))
        XCTAssertEqual(h.core.swaps, 1)
        h.tick(1.10)
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertEqual(h.core.swaps, 1, "P1 never shown")
    }

    /// D. Activity during the fade-out cancels it (text stays hidden); the swap happens at the next
    /// gate with no second fade-out.
    func testCaseD_ActivityDuringTheFadeOut() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.tick(0.45)
        XCTAssertEqual(h.core.phase, .fadingOut)
        h.at(0.52) { $0.focusActivity(now: 0.52) }
        XCTAssertEqual(h.core.phase, .pausing, "cancelled")
        XCTAssertEqual(h.core.textOpacity, 0, "the text stays hidden")
        XCTAssertNil(h.core.stepDue)
        XCTAssertEqual(h.core.nextDeadline ?? -1, 0.97, accuracy: 1e-9)
        h.tick(0.60)
        XCTAssertEqual(h.core.shown, item("P0"), "no swap at the old fade end")
        h.at(0.72) { $0.present(SwapItem(id: "P2"), now: 0.72) }
        XCTAssertEqual(h.core.phase, .pausing)
        h.tick(0.96)
        XCTAssertEqual(h.core.swaps, 0)
        h.tick(0.97)
        XCTAssertEqual(h.core.phase, .fadingIn, "already hidden: swap at once")
        XCTAssertEqual(h.core.shown, item("P2"))
        XCTAssertEqual(h.core.swaps, 1)
        h.tick(1.17)
        XCTAssertEqual(h.core.phase, .idle)
    }

    /// E. Held Down 3 s (a page per hop, intermediate titles committing): one swap, after the glide.
    func testCaseE_HeldDown() {
        var h = Harness()
        var t: TimeInterval = 0
        var hop = 1
        while t < 2.9 - 1e-9 {
            let now = t
            h.at(now) {
                $0.focusActivity(now: now)
                $0.pageStarted(now: now)
            }
            let commit = now + 0.2
            let id = "P\(hop)"
            if commit < 2.9 {
                h.at(commit) { $0.present(SwapItem(id: id), now: commit) }
            }
            XCTAssertEqual(h.core.swaps, 0, "nothing swaps while the hand is down")
            t += 0.58
            hop += 1
        }
        // The last hop at 2.9 commits at 3.1; the glide completes at 3.40.
        h.at(2.9) {
            $0.focusActivity(now: 2.9)
            $0.pageStarted(now: 2.9)
        }
        h.at(3.10) { $0.present(SwapItem(id: "Plast"), now: 3.10) }
        h.at(3.40) {
            $0.motion(at: 3.40)
            $0.pageEnded(now: 3.40)
        }
        h.tick(3.44)
        XCTAssertEqual(h.core.phase, .pausing)
        h.tick(3.45)
        XCTAssertEqual(h.core.phase, .fadingOut)
        h.tick(3.60)
        XCTAssertEqual(h.core.shown, item("Plast"))
        XCTAssertEqual(h.core.swaps, 1)
        h.tick(3.80)
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertEqual(h.core.swaps, 1)
    }

    /// F. Cold art: the present arrives past the gate and goes straight out.
    func testCaseF_ColdArtArrivesPastTheGate() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.tick(0.45)
        XCTAssertEqual(h.core.resting, "P0", "the old title rested while the new art resolved")
        h.at(0.60) { $0.present(SwapItem(id: "P1"), now: 0.60) }
        XCTAssertEqual(h.core.phase, .fadingOut, "out at arrival")
        XCTAssertEqual(h.core.stepDue ?? -1, 0.75, accuracy: 1e-9)
        h.tick(0.75)
        XCTAssertEqual(h.core.shown, item("P1"))
        XCTAssertEqual(h.core.swaps, 1)
    }

    /// G. Right then Left within 0.4 s: the present is the shown identity, so no fade at all.
    func testCaseG_RightThenLeft() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.at(0.30) { $0.focusActivity(now: 0.30) }
        h.at(0.50) { $0.present(SwapItem(id: "P0", rev: 1), now: 0.50) }
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertNil(h.core.pending)
        XCTAssertEqual(h.core.textOpacity, 1)
        h.tick(1.0)
        XCTAssertEqual(h.core.swaps, 0)
        XCTAssertEqual(h.core.shown, item("P0", rev: 1))
    }

    /// H. Reduce Motion: the same gates, then an instant cut.
    func testCaseH_ReduceMotion() {
        var h = Harness(reduceMotion: true)
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.tick(0.44)
        XCTAssertEqual(h.core.shown, item("P0"))
        h.tick(0.45)
        XCTAssertEqual(h.core.shown, item("P1"))
        XCTAssertEqual(h.core.textOpacity, 1)
        XCTAssertEqual(h.core.fade, .instant)
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertEqual(h.core.swaps, 1)
    }

    // MARK: Edge rules

    func testSameIdentitySharpenWhileIdle() {
        var h = Harness()
        h.at(1) { $0.present(SwapItem(id: "P0", rev: 1), now: 1) }
        XCTAssertEqual(h.core.shown, item("P0", rev: 1), "shown replaced")
        XCTAssertEqual(h.core.phase, .idle)
        XCTAssertEqual(h.core.swaps, 0)
        XCTAssertEqual(h.core.fade, .instant)
    }

    func testSameIdentityDuringTheFadeOutBringsTheTextBack() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.tick(0.45)
        XCTAssertEqual(h.core.phase, .fadingOut)
        h.at(0.50) { $0.present(SwapItem(id: "P0", rev: 2), now: 0.50) }
        XCTAssertEqual(h.core.phase, .fadingIn)
        XCTAssertEqual(h.core.textOpacity, 1)
        XCTAssertEqual(h.core.fade, .fadeIn(0.20))
        XCTAssertNil(h.core.pending)
        XCTAssertEqual(h.core.swaps, 0)
    }

    func testNewIdentityDuringTheFadeInPausesAtTheFadeEnd() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.tick(0.45)
        h.tick(0.60)
        XCTAssertEqual(h.core.phase, .fadingIn)
        h.at(0.70) {
            $0.focusActivity(now: 0.70)
            $0.present(SwapItem(id: "P2"), now: 0.70)
        }
        XCTAssertEqual(h.core.phase, .fadingIn, "the fade-in finishes first")
        h.tick(0.80)
        XCTAssertEqual(h.core.phase, .pausing)
        XCTAssertEqual(h.core.nextDeadline ?? -1, 1.15, accuracy: 1e-9, "gate respected")
        h.tick(1.14)
        XCTAssertEqual(h.core.phase, .pausing)
        h.tick(1.15)
        XCTAssertEqual(h.core.phase, .fadingOut)
    }

    func testPageStartedWhilePausingRemovesTheDeadline() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        XCTAssertNotNil(h.core.nextDeadline)
        h.at(0.30) { $0.pageStarted(now: 0.30) }
        XCTAssertNil(h.core.nextDeadline)
        h.tick(2.0)
        XCTAssertEqual(h.core.phase, .pausing, "no gate until the page ends")
        h.at(2.1) { $0.pageEnded(now: 2.1) }
        XCTAssertEqual(h.core.nextDeadline ?? -1, 2.1, accuracy: 1e-9)
    }

    func testPageStartedDuringTheFadeOutCancelsIt() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.tick(0.45)
        h.at(0.50) { $0.pageStarted(now: 0.50) }
        XCTAssertEqual(h.core.phase, .pausing)
        XCTAssertEqual(h.core.textOpacity, 0)
        XCTAssertNil(h.core.nextDeadline)
    }

    func testKnobPauseMovesCaseA() {
        var h = Harness(timing: TextSwapTiming(pause: 0.3, fadeOut: 0.15, fadeIn: 0.20))
        h.at(0) { $0.focusActivity(now: 0) }
        h.at(0.20) { $0.present(SwapItem(id: "P1"), now: 0.20) }
        h.tick(0.30)
        XCTAssertEqual(h.core.phase, .fadingOut)
        h.tick(0.44)
        XCTAssertEqual(h.core.swaps, 0)
        h.tick(0.45)
        XCTAssertEqual(h.core.swaps, 1, "case A's swap moves to 0.45")
    }

    func testRestingIsSetAtTheGateAndClearedByActivityOrAPage() {
        var h = Harness()
        h.at(0) { $0.focusActivity(now: 0) }
        h.tick(0.44)
        XCTAssertNil(h.core.resting, "not before the gate")
        h.tick(0.45)
        XCTAssertEqual(h.core.resting, "P0")
        h.at(1.0) { $0.focusActivity(now: 1.0) }
        XCTAssertNil(h.core.resting, "activity clears it")
        h.tick(1.45)
        XCTAssertEqual(h.core.resting, "P0")
        h.at(2.0) { $0.pageStarted(now: 2.0) }
        XCTAssertNil(h.core.resting, "a page start clears it")
        h.at(2.5) { $0.pageEnded(now: 2.5) }
        h.tick(2.5)
        XCTAssertEqual(h.core.resting, "P0")
    }

    // MARK: Driver

    /// One wake outstanding at a time; outputs written in an animation-free transaction; the wash
    /// feed's `pending` written on a new pending identity and `displayed` at the swap; a pending-only
    /// change leaves `output` unwritten.
    func testDriverWakesFeedsAndOutputs() {
        let clock = StageFakeClock()
        let driver = StageSwapDriver(timing: stageTiming,
                                     now: { clock.now },
                                     motionAge: { .greatestFiniteMagnitude },
                                     schedule: { after, work in clock.schedule(after, work) })
        var outputWrites = 0
        let subscription = driver.$output.dropFirst().sink { _ in outputWrites += 1 }
        defer { subscription.cancel() }

        XCTAssertNil(StageSwapDriver.writeTransaction().animation, "writes carry no animation")

        driver.receive(presentation("movie:p0"))
        XCTAssertEqual(driver.output.shown?.identity, "movie:p0", "nothing shown yet: at once")
        XCTAssertEqual(driver.washFeed.displayed?.identity, "movie:p0")
        XCTAssertLessThanOrEqual(clock.pendingCount, 1)

        // No activity yet, so the idle gate is long past: the first title rests at once and no wake
        // is left outstanding.
        clock.advance(0)
        XCTAssertEqual(driver.output.restingKey, "movie:p0")
        XCTAssertEqual(clock.pendingCount, 0)

        driver.noteFocusActivity()
        XCTAssertNil(driver.output.restingKey)
        XCTAssertLessThanOrEqual(clock.pendingCount, 1)

        clock.advance(0.20)
        let writesBeforePending = outputWrites
        driver.receive(presentation("movie:p1"))
        XCTAssertEqual(driver.washFeed.pending?.identity, "movie:p1", "the pause began: the wash warms it")
        XCTAssertEqual(outputWrites, writesBeforePending, "a pending-only change leaves output unwritten")
        XCTAssertEqual(driver.output.shown?.identity, "movie:p0")
        XCTAssertEqual(clock.pendingCount, 1)

        clock.advance(0.25)   // 0.45: out
        XCTAssertEqual(driver.output.textOpacity, 0)
        XCTAssertEqual(driver.output.fade, .fadeOut(0.15))
        XCTAssertNotNil(driver.output.animation)
        XCTAssertEqual(driver.washFeed.displayed?.identity, "movie:p0", "the wash waits for the swap")
        XCTAssertEqual(clock.pendingCount, 1)

        clock.advance(0.15)   // 0.60: swap
        XCTAssertEqual(driver.output.shown?.identity, "movie:p1")
        XCTAssertEqual(driver.output.art?.identity, "movie:p1", "the art follows the text")
        XCTAssertEqual(driver.output.textOpacity, 1)
        XCTAssertEqual(driver.output.fade, .fadeIn(0.20))
        XCTAssertNotNil(driver.output.animation)
        XCTAssertEqual(driver.washFeed.displayed?.identity, "movie:p1")
        XCTAssertLessThanOrEqual(clock.pendingCount, 1)

        clock.advance(0.20)   // 0.80: idle, resting
        XCTAssertEqual(driver.output.restingKey, "movie:p1")
        XCTAssertEqual(driver.core.phase, .idle)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    /// The seed writes the wash feed at once with the folder's cover as its fallback; later titles
    /// carry none.
    func testDriverSeedFeedsTheWashWithItsFallback() {
        let clock = StageFakeClock()
        let driver = StageSwapDriver(timing: stageTiming,
                                     now: { clock.now },
                                     motionAge: { .greatestFiniteMagnitude },
                                     schedule: { after, work in clock.schedule(after, work) })
        let folder = metaPreview(id: "nuvio-folder://c/f", type: "nuvio.folder")
        driver.seed(folder, washFallback: "https://example.com/cover.jpg")
        XCTAssertEqual(driver.washFeed.displayed?.identity, "nuvio.folder:nuvio-folder://c/f")
        XCTAssertEqual(driver.washFeed.displayed?.washFallback, "https://example.com/cover.jpg")
        XCTAssertNil(driver.output.shown, "the art still resolves through the resolver")

        driver.receive(HeroPresentation(item: folder, backdrop: nil, logo: nil,
                                        identity: "nuvio.folder:nuvio-folder://c/f"))
        XCTAssertEqual(driver.output.shown?.identity, "nuvio.folder:nuvio-folder://c/f")
        XCTAssertEqual(driver.washFeed.displayed?.washFallback, "https://example.com/cover.jpg")

        driver.noteFocusActivity()
        driver.receive(presentation("movie:p1"))
        XCTAssertNil(driver.washFeed.pending?.washFallback)
    }

    // MARK: Fixtures

    private func metaPreview(id: String, type: String = "movie") -> MetaPreview {
        MetaPreview(
            id: id, type: type, name: id,
            poster: nil, banner: nil, logo: nil,
            posterShape: .poster,
            description: nil, releaseInfo: nil, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: [],
            rawPosterUrl: nil,
            landscapePoster: nil,
            rawLandscapePosterUrl: nil,
            customPosterApplied: false
        )
    }

    /// `identity` is `"<type>:<id>"`.
    private func presentation(_ identity: String) -> HeroPresentation {
        let parts = identity.split(separator: ":", maxSplits: 1).map(String.init)
        let item = metaPreview(id: parts.last ?? identity, type: parts.first ?? "movie")
        return HeroPresentation(item: item, backdrop: nil, logo: nil, identity: identity)
    }
}

/// A deterministic schedule: jobs run only when the test advances the clock, in due-time order, and
/// a cancelled token never runs (`HeroTextSwapModelTests`' clock).
@MainActor
final class StageFakeClock {
    private struct Job {
        let id: Int
        let due: TimeInterval
        let work: @MainActor () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var jobs: [Job] = []
    private var cancelled = Set<Int>()
    private var nextId = 0

    /// Jobs still waiting to run.
    var pendingCount: Int { jobs.filter { !cancelled.contains($0.id) }.count }

    func schedule(_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        nextId += 1
        let id = nextId
        jobs.append(Job(id: id, due: now + after, work: work))
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated { _ = self?.cancelled.insert(id) }
        }
    }

    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = jobs
            .filter({ !cancelled.contains($0.id) && $0.due <= end + 1e-9 })
            .min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            jobs.removeAll { $0.id == next.id }
            now = max(now, next.due)
            next.work()
        }
        now = end
    }
}
