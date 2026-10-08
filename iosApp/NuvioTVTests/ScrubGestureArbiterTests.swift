import XCTest
@testable import NuvioTV

final class ScrubGestureArbiterTests: XCTestCase {
    typealias A = ScrubGestureArbiter

    private let now: TimeInterval = 100

    /// Defaults: bar up, playing, no pill, not scrubbing, can scrub, no presses, last press 10 s ago.
    private func ctx(bar: Bool = true, paused: Bool = false, pill: Bool = false, scrubbing: Bool = false,
                     canScrub: Bool = true, presses: Int = 0, lastPress: TimeInterval = 90) -> ScrubContext {
        ScrubContext(barVisible: bar, paused: paused, pillFocused: pill, scrubbing: scrubbing,
                     canScrub: canScrub, pressesDown: presses, lastPressUptime: lastPress)
    }

    private func stroke(_ tx: Double, _ ty: Double = 0, _ c: ScrubContext? = nil) -> (A, A.Event) {
        var a = A()
        a.touchBegan()
        let e = a.moved(tx: tx, ty: ty, now: now, context: c ?? ctx())
        return (a, e)
    }

    // 1, 2
    func testBarUpThresholdIs45() {
        let (a, e) = stroke(44)
        XCTAssertEqual(e, .none)
        XCTAssertEqual(a.intent, .undecided)
        XCTAssertEqual(stroke(45).1, .beginScrub)
        XCTAssertEqual(stroke(-45).1, .beginScrub)
    }

    // 3
    func testHiddenPlayingNeeds160() {
        XCTAssertEqual(stroke(159, 0, ctx(bar: false)).1, .none)
        XCTAssertEqual(stroke(160, 0, ctx(bar: false)).1, .beginScrub)
    }

    // 4
    func testHiddenPausedScrubsAt45() {
        XCTAssertEqual(stroke(45, 0, ctx(bar: false, paused: true)).1, .beginScrub)
    }

    // 5
    func testPillFocusedNeeds190() {
        XCTAssertEqual(stroke(189, 0, ctx(pill: true)).1, .none)
        XCTAssertEqual(stroke(190, 0, ctx(pill: true)).1, .beginScrub)
    }

    // 6
    func testAlreadyScrubbingBarHiddenIs45() {
        XCTAssertEqual(stroke(45, 0, ctx(bar: false, scrubbing: true)).1, .beginScrub)
        XCTAssertEqual(A.horizontalThreshold(ctx(bar: false, scrubbing: true)), 45)
    }

    // 7
    func testVerticalDownDecidesAt110AndOpensAtTheLift() {
        XCTAssertEqual(stroke(0, 109).1, .none)
        var (a, e) = stroke(0, 110)
        XCTAssertEqual(e, .none, "the threshold decides the stroke, the lift opens the panel")
        XCTAssertEqual(a.intent, .vertical(down: true))
        XCTAssertEqual(a.probeCode, "v")
        XCTAssertEqual(a.moved(tx: 0, ty: 300, now: now, context: ctx()), .none)
        XCTAssertEqual(a.touchEnded(context: ctx()), .openPanel)
    }

    /// Device pass 2026-10-08: the finger rolling onto a clickpad edge before a Left/Right click
    /// read as 112–127 pt of slow downward travel and opened the panel mid pill walk.
    func testVerticalDownWithAClickInTheStrokeNeverOpens() {
        var (a, _) = stroke(0, 120)
        XCTAssertEqual(a.intent, .vertical(down: true))
        a.pressBegan()
        XCTAssertEqual(a.intent, .ignored)
        XCTAssertEqual(a.touchEnded(context: ctx()), .none)
        // A press that began before the threshold counts too.
        var b = A()
        b.touchBegan()
        b.pressBegan()
        XCTAssertEqual(b.moved(tx: 0, ty: 120, now: now, context: ctx(lastPress: 90)), .none)
        XCTAssertEqual(b.touchEnded(context: ctx()), .none)
    }

    func testVerticalDownLiftWithThePressStillDownDoesNotOpen() {
        var (a, _) = stroke(0, 120)
        XCTAssertEqual(a.touchEnded(context: ctx(presses: 1)), .none)
    }

    // 8
    func testVerticalUpIsSwipeUp() {
        XCTAssertEqual(stroke(0, -110).1, .swipeUp)
    }

    // 9
    func testVerticalWinsOverHorizontal() {
        var (a, e) = stroke(60, 120)
        XCTAssertEqual(e, .none)
        XCTAssertEqual(a.intent, .vertical(down: true))
        XCTAssertEqual(a.touchEnded(context: ctx()), .openPanel)
    }

    // 10
    func testDiagonalStaysUndecidedAndIsNotATap() {
        var (a, e) = stroke(100, 90)
        XCTAssertEqual(e, .none)
        XCTAssertEqual(a.intent, .undecided)
        e = a.touchEnded(context: ctx())
        XCTAssertEqual(e, .none)
    }

    // 11
    func testShortTravelIsALightTap() {
        var a = A()
        a.touchBegan()
        _ = a.moved(tx: 12, ty: 0, now: now, context: ctx())
        XCTAssertEqual(a.touchEnded(context: ctx()), .lightTap)
        a.touchBegan()
        _ = a.moved(tx: 20, ty: 0, now: now, context: ctx())
        XCTAssertEqual(a.touchEnded(context: ctx()), .none)
    }

    // 12
    func testAfterHorizontalSamplesArePerSampleIncrements() {
        var (a, e) = stroke(60)
        XCTAssertEqual(e, .beginScrub)
        XCTAssertEqual(a.probeCode, "h")
        e = a.moved(tx: 80, ty: 3, now: now, context: ctx(scrubbing: true))
        XCTAssertEqual(e, .scrubDelta(points: 20))      // not 80: the decision's own travel is dropped
        e = a.moved(tx: 70, ty: 3, now: now, context: ctx(scrubbing: true))
        XCTAssertEqual(e, .scrubDelta(points: -10))
        e = a.moved(tx: 70, ty: 40, now: now, context: ctx(scrubbing: true))
        XCTAssertEqual(e, .none)
        XCTAssertEqual(a.touchEnded(context: ctx(scrubbing: true)), .none)
    }

    // 13
    func testMoveSuppressionAfterAPressRebasesTheOrigin() {
        var a = A()
        a.touchBegan()
        XCTAssertEqual(a.moved(tx: 80, ty: 0, now: now, context: ctx(lastPress: now - 0.3)), .none)
        XCTAssertEqual(a.intent, .undecided)
        let c = ctx(lastPress: now - 0.3)
        XCTAssertEqual(a.moved(tx: 124, ty: 0, now: now + 0.15, context: c), .none)
        XCTAssertEqual(a.moved(tx: 125, ty: 0, now: now + 0.15, context: c), .beginScrub)
    }

    // 14
    func testPressDownSuppresses() {
        XCTAssertEqual(stroke(200, 0, ctx(presses: 1)).1, .none)
        XCTAssertEqual(stroke(0, 200, ctx(presses: 1)).1, .none)
    }

    // 15
    func testCannotScrubIgnoresTheStroke() {
        var (a, e) = stroke(45, 0, ctx(canScrub: false))
        XCTAssertEqual(e, .none)
        XCTAssertEqual(a.intent, .ignored)
        XCTAssertEqual(a.probeCode, "i")
        e = a.moved(tx: 300, ty: 0, now: now, context: ctx())
        XCTAssertEqual(e, .none)
        e = a.moved(tx: 300, ty: 300, now: now, context: ctx())
        XCTAssertEqual(e, .none)
    }

    // 16
    func testAbandonStopsTheStroke() {
        var (a, _) = stroke(60)
        a.abandon()
        XCTAssertEqual(a.intent, .ignored)
        XCTAssertEqual(a.moved(tx: 100, ty: 0, now: now, context: ctx()), .none)
        // A new stroke starts fresh.
        a.touchBegan()
        XCTAssertEqual(a.probeCode, "u")
        XCTAssertEqual(a.moved(tx: 45, ty: 0, now: now, context: ctx()), .beginScrub)
    }

    // 17
    func testOrivioCurve() {
        let c = ScrubRateCurve.orivio
        XCTAssertEqual(c.deltaSec(points: 1, durationSec: 600), 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.deltaSec(points: 1, durationSec: 7200), 1.5, accuracy: 1e-9)
        XCTAssertEqual(c.deltaSec(points: 1, durationSec: 0), 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.deltaSec(points: -4, durationSec: 600), -1, accuracy: 1e-9)
        XCTAssertEqual(c.probeCode, "o")
    }

    // 18
    func testBobsupraCurve() {
        let c = ScrubRateCurve.bobsupra
        XCTAssertEqual(c.deltaSec(points: 2, durationSec: 600), 2 * 0.06 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(c.deltaSec(points: 5, durationSec: 600), 5 * 0.06 * (1 + 1.5 * 0.4 * 0.8), accuracy: 1e-9)
        XCTAssertEqual(c.deltaSec(points: 20, durationSec: 600), 5.76, accuracy: 1e-9)
        XCTAssertEqual(c.deltaSec(points: -20, durationSec: 600), -5.76, accuracy: 1e-9)
        XCTAssertEqual(c.deltaSec(points: 20, durationSec: 14400), 12.96, accuracy: 1e-9)
        XCTAssertEqual(c.deltaSec(points: 0.00001, durationSec: 600), 0)
        XCTAssertEqual(c.probeCode, "b")
        XCTAssertEqual(ScrubRateCurve.fromSetting("bobsupra"), .bobsupra)
        XCTAssertEqual(ScrubRateCurve.fromSetting(""), .orivio)
        XCTAssertEqual(ScrubRateCurve.fromSetting(nil), .orivio)
    }

    // 19
    func testInjectScriptParse() {
        let s = ScrubInjectScript.parse("20,0.03;0,0.03,30;bad")
        XCTAssertEqual(s, [.init(dx: 20, dy: 0, dt: 0.03), .init(dx: 0, dy: 30, dt: 0.03)])
        XCTAssertEqual(ScrubInjectScript.parse("5,9;1,2,3,4;x,1"), [.init(dx: 5, dy: 0, dt: 1)])
        XCTAssertEqual(ScrubInjectScript.parse("5,-1").first?.dt, 0)
        XCTAssertTrue(ScrubInjectScript.parse("").isEmpty)
    }

    // C17: the preview-frame throttle.
    func testThrottleStartsAtMostOneLookupAndAlwaysRunsATrailingOne() {
        var t = PreviewFrameThrottle()
        XCTAssertEqual(t.sample(now: 0), .start)
        XCTAssertTrue(t.inFlight)
        // Samples while one is in flight only mark a trailing lookup.
        XCTAssertEqual(t.sample(now: 0.01), .none)
        XCTAssertEqual(t.sample(now: 0.02), .none)
        // The lookup finishes before the interval: wait out the remainder.
        guard case .wait(let d) = t.finished(now: 0.03) else { return XCTFail("expected wait") }
        XCTAssertEqual(d, 0.036, accuracy: 1e-9)
        XCTAssertEqual(t.timerFired(now: 0.066), .start)
        // Finished with nothing pending: idle.
        XCTAssertEqual(t.finished(now: 0.08), .none)
        XCTAssertFalse(t.trailingPending)
        // A sample long after the last start starts at once.
        XCTAssertEqual(t.sample(now: 1.0), .start)
        // A finish after the interval with a pending sample starts the trailing one at once.
        XCTAssertEqual(t.sample(now: 1.01), .none)
        XCTAssertEqual(t.finished(now: 1.2), .start)
    }

    func testThrottleSteadySwipeLooksUpWhileMoving() {
        // A sample every 16 ms with an instant source: lookups keep starting every ~66 ms, not
        // only once the finger stops (the debounce the critique rejected).
        var t = PreviewFrameThrottle()
        var starts = 0
        var timerDue: TimeInterval?
        var clock: TimeInterval = 0
        while clock < 0.5 {
            if let due = timerDue, due <= clock {
                timerDue = nil
                if t.timerFired(now: clock) == .start { starts += 1; _ = t.finished(now: clock) }
            }
            switch t.sample(now: clock) {
            case .start:
                starts += 1
                if case .wait(let d) = t.finished(now: clock), timerDue == nil { timerDue = clock + d }
            case .wait(let d):
                if timerDue == nil { timerDue = clock + d }
            case .none: break
            }
            clock += 0.016
        }
        XCTAssertGreaterThanOrEqual(starts, 6)
        XCTAssertLessThanOrEqual(starts, 9)
    }

    func testThrottleResetForgetsPending() {
        var t = PreviewFrameThrottle()
        XCTAssertEqual(t.sample(now: 0), .start)
        XCTAssertEqual(t.sample(now: 0.01), .none)
        t.reset()
        XCTAssertFalse(t.inFlight)
        XCTAssertFalse(t.trailingPending)
        XCTAssertEqual(t.timerFired(now: 0.02), .none)
        XCTAssertEqual(t.sample(now: 0.02), .start)
    }
}
