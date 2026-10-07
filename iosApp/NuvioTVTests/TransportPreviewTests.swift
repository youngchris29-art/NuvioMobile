import XCTest
@testable import NuvioTV

final class TransportPreviewTests: XCTestCase {
    typealias TP = TransportPreview

    private func held(_ k: Int) -> Double { 0.4 + 0.25 * Double(k - 1) }

    private func make(mode: TP.HoldMode = .step, duration: Double = 3000) -> TP {
        var t = TP()
        t.holdMode = mode
        t.durationSec = duration
        return t
    }

    private func ticks(_ t: inout TP, _ n: Int) {
        for k in 1...n { _ = t.holdTick(heldSec: held(k)) }
    }

    func testStepSecBoundaries() {
        XCTAssertEqual(TP.stepSec(heldSec: 0.4), 10)
        XCTAssertEqual(TP.stepSec(heldSec: 0.59), 10)
        XCTAssertEqual(TP.stepSec(heldSec: 0.6), 20)
        XCTAssertEqual(TP.stepSec(heldSec: 1.19), 20)
        XCTAssertEqual(TP.stepSec(heldSec: 1.2), 30)
        XCTAssertEqual(TP.stepSec(heldSec: 1.99), 30)
        XCTAssertEqual(TP.stepSec(heldSec: 2.0), 60)
        XCTAssertEqual(TP.stepSec(heldSec: 10), 60)
        XCTAssertEqual(TP.stepSec(heldSec: 0.3, rampScale: 0.5), 20)
        XCTAssertEqual(TP.stepSec(heldSec: 0.6, rampScale: 0.5), 30)
        XCTAssertEqual(TP.stepSec(heldSec: 1.0, rampScale: 0.5), 60)
        XCTAssertEqual(TP.stepSec(heldSec: 1.19, rampScale: 2), 10)
        XCTAssertEqual(TP.stepSec(heldSec: 3.99, rampScale: 2), 30)
        XCTAssertEqual(TP.stepSec(heldSec: 4.0, rampScale: 2), 60)
    }

    func testFirstPressFromIdleIsImmediateSeek() {
        var t = make()
        XCTAssertEqual(t.pressBegan(direction: 1, positionSec: 100), .immediateSeek(deltaSec: 10))
        XCTAssertEqual(t.mode, .stepping(direction: 1, accumulatedSec: 10, ticks: 0))
        XCTAssertEqual(t.previewSec, 110)
    }

    func testPressAndReleaseWithoutTickIsNoSecondSeek() {
        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        XCTAssertEqual(t.pressEnded(direction: 1), .none)
        XCTAssertEqual(t.mode, .idle)
        XCTAssertNil(t.previewSec)
    }

    func testTwoTicksThenReleaseCommits() {
        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 2)
        XCTAssertEqual(t.pressEnded(direction: 1),
                       .commit(.init(targetSec: 140, fromSec: 100, stages: [.keyframes, .exact])))
        XCTAssertEqual(t.mode, .idle)
        XCTAssertEqual(t.previewSec, 140)
    }

    func testFourTicks() {
        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 4)
        XCTAssertEqual(t.previewSec, 180)
    }

    func testSevenTicks() {
        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 7)
        XCTAssertEqual(t.previewSec, 270)   // 10 + 10 + 3*20 + 3*30 = 170
    }

    func testEightTicks() {
        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 8)
        XCTAssertEqual(t.previewSec, 330)   // 170 + 60 = 230
    }

    func testBackwardClampsAtZero() {
        var t = make()
        _ = t.pressBegan(direction: -1, positionSec: 25)
        ticks(&t, 3)
        XCTAssertEqual(t.previewSec, 0)
        guard case .commit(let r) = t.pressEnded(direction: -1) else { return XCTFail() }
        XCTAssertEqual(r.targetSec, 0)
    }

    func testForwardNearEndClamps() {
        var t = make(duration: 1500)
        _ = t.pressBegan(direction: 1, positionSec: 1490)
        XCTAssertEqual(t.previewSec, 1499.5)
        ticks(&t, 2)
        guard case .commit(let r) = t.pressEnded(direction: 1) else { return XCTFail() }
        XCTAssertEqual(r.targetSec, 1499.5)
    }

    func testUnknownDurationHasNoUpperClamp() {
        var t = make(duration: 0)
        _ = t.pressBegan(direction: 1, positionSec: 10_000)
        ticks(&t, 8)
        XCTAssertEqual(t.previewSec, 10_000 + 230)
    }

    func testReversalAtClampMovesAtOnce() {
        var t = make(duration: 1500)
        _ = t.pressBegan(direction: 1, positionSec: 1490)
        ticks(&t, 3)                                  // pinned at 1499.5
        _ = t.pressBegan(direction: -1, positionSec: 0)
        XCTAssertEqual(t.previewSec, 1489.5)           // 1499.5 - 10, not 1499.5 + (overshoot) - 10
    }

    func testDirectionChangeMidHold() {
        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 3)                                  // 10 + 10 + 20 + 20 = 60
        let before = t.previewSec!
        XCTAssertEqual(t.pressBegan(direction: -1, positionSec: 100), .none)
        XCTAssertEqual(t.previewSec, before - 10)
        XCTAssertEqual(t.pressEnded(direction: 1), .none)   // first key's release ignored
        XCTAssertTrue(t.mode.isActive)
        guard case .commit(let r) = t.pressEnded(direction: -1) else { return XCTFail() }
        XCTAssertEqual(r.targetSec, before - 10)
        XCTAssertEqual(r.fromSec, 100)
    }

    func testCommitStagesKeyframesOutsideRanges() {
        var t = make()
        t.seekableRanges = [BufferedRange(start: 0, end: 120)]
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 2)
        guard case .commit(let r) = t.pressEnded(direction: 1) else { return XCTFail() }
        XCTAssertEqual(r.stages, [.keyframes, .exact])
    }

    func testCommitStagesExactInsideRangeInclusive() {
        for end in [140.0, 200.0] {
            var t = make()
            t.seekableRanges = [BufferedRange(start: 0, end: end)]
            _ = t.pressBegan(direction: 1, positionSec: 100)
            ticks(&t, 2)
            guard case .commit(let r) = t.pressEnded(direction: 1) else { return XCTFail() }
            XCTAssertEqual(r.stages, [.exact])
        }
        var t = make()
        t.seekableRanges = [BufferedRange(start: 140, end: 300)]
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 2)
        guard case .commit(let r) = t.pressEnded(direction: 1) else { return XCTFail() }
        XCTAssertEqual(r.stages, [.exact])
    }

    func testScanClickSeeksOnRelease() {
        var t = make(mode: .scan)
        XCTAssertEqual(t.pressBegan(direction: 1, positionSec: 100), .none)
        XCTAssertEqual(t.pressEnded(direction: 1), .immediateSeek(deltaSec: 10))
        XCTAssertEqual(t.mode, .idle)
    }

    func testScanHoldForwardStartsScanOnFirstTick() {
        var t = make(mode: .scan)
        _ = t.pressBegan(direction: 1, positionSec: 100)
        XCTAssertEqual(t.holdTick(heldSec: held(1)), .startScan(rate: 2))
        XCTAssertEqual(t.mode, .scanning(rate: 2))
        XCTAssertEqual(t.previewSec, 100)
        XCTAssertEqual(t.holdTick(heldSec: held(2)), .none)
        XCTAssertEqual(t.mode, .scanning(rate: 2))
    }

    func testScanBackwardHoldSteps() {
        var t = make(mode: .scan)
        XCTAssertEqual(t.pressBegan(direction: -1, positionSec: 200), .immediateSeek(deltaSec: -10))
        ticks(&t, 2)
        XCTAssertEqual(t.mode, .stepping(direction: -1, accumulatedSec: -40, ticks: 2))
        guard case .commit(let r) = t.pressEnded(direction: -1) else { return XCTFail() }
        XCTAssertEqual(r.targetSec, 160)
    }

    func testScanIsLatchedOnRelease() {
        var t = make(mode: .scan)
        _ = t.pressBegan(direction: 1, positionSec: 100)
        _ = t.holdTick(heldSec: held(1))
        XCTAssertEqual(t.pressEnded(direction: 1), .none)
        XCTAssertEqual(t.mode, .scanning(rate: 2))
    }

    func testRightPressesCycleRate() {
        var t = make(mode: .scan)
        _ = t.pressBegan(direction: 1, positionSec: 100)
        _ = t.holdTick(heldSec: held(1))
        _ = t.pressEnded(direction: 1)
        for expected in [3, 4, 2] {
            XCTAssertEqual(t.pressBegan(direction: 1, positionSec: 0), .setScanRate(expected))
            XCTAssertEqual(t.pressEnded(direction: 1), .none)
        }
        XCTAssertEqual(t.mode, .scanning(rate: 2))
    }

    func testLeftPressWhileScanningEndsInPlace() {
        var t = make(mode: .scan)
        _ = t.pressBegan(direction: 1, positionSec: 100)
        _ = t.holdTick(heldSec: held(1))
        _ = t.pressEnded(direction: 1)
        XCTAssertEqual(t.pressBegan(direction: -1, positionSec: 0), .endScan(fromSec: 100, returnToSec: nil))
        XCTAssertEqual(t.mode, .idle)
        XCTAssertNil(t.previewSec)
    }

    func testEndScanInPlace() {
        var t = make(mode: .scan)
        XCTAssertEqual(t.endScanInPlace(), .none)
        _ = t.pressBegan(direction: 1, positionSec: 100)
        _ = t.holdTick(heldSec: held(1))
        XCTAssertEqual(t.endScanInPlace(), .endScan(fromSec: 100, returnToSec: nil))
    }

    func testNoteLivePosition() {
        var t = make(mode: .scan)
        t.noteLivePosition(5)
        XCTAssertNil(t.previewSec)
        _ = t.pressBegan(direction: 1, positionSec: 100)
        _ = t.holdTick(heldSec: held(1))
        t.noteLivePosition(130)
        XCTAssertEqual(t.previewSec, 130)
    }

    func testCancelWhileSteppingCommitsNothing() {
        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 2)
        XCTAssertEqual(t.cancel(), .none)
        XCTAssertEqual(t.mode, .idle)
        XCTAssertNil(t.previewSec)
        XCTAssertEqual(t.pressEnded(direction: 1), .none)
    }

    /// `pressesCancelled` (Home / Siri mid-hold): the run-on preview is dropped and the next
    /// gesture starts from the live position, not from the cancelled hold's accumulation.
    func testCancelledHoldThenNewPressStartsFresh() {
        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 8)
        XCTAssertEqual(t.cancel(), .none)
        XCTAssertEqual(t.pressBegan(direction: 1, positionSec: 110), .immediateSeek(deltaSec: 10))
        XCTAssertEqual(t.previewSec, 120)
        XCTAssertEqual(t.pressEnded(direction: 1), .none)
    }

    func testScanHoldWhilePausedSteps() {
        var t = make(mode: .scan)
        t.paused = true
        XCTAssertEqual(t.pressBegan(direction: 1, positionSec: 100), .immediateSeek(deltaSec: 10))
        XCTAssertEqual(t.holdTick(heldSec: held(1)), .none)
        XCTAssertEqual(t.mode, .stepping(direction: 1, accumulatedSec: 20, ticks: 1))
        guard case .commit(let r) = t.pressEnded(direction: 1) else { return XCTFail("no commit") }
        XCTAssertEqual(r.targetSec, 120)
        // Unpaused again: the next hold scans.
        t.paused = false
        _ = t.pressBegan(direction: 1, positionSec: 120)
        XCTAssertEqual(t.holdTick(heldSec: held(1)), .startScan(rate: 2))
    }

    func testCancelWhileScanningReturnsToOrigin() {
        var t = make(mode: .scan)
        _ = t.pressBegan(direction: 1, positionSec: 100)
        _ = t.holdTick(heldSec: held(1))
        XCTAssertEqual(t.cancel(), .endScan(fromSec: 100, returnToSec: 100))
    }

    func testParseSeekableRangesAndCommitLanded() {
        let json = #"{"seekable-ranges":[{"start":0.0,"end":12.5},{"start":40,"end":90.25}],"cache-end":90.25,"fw-bytes":123}"#
        XCTAssertEqual(TP.parseSeekableRanges(json),
                       [BufferedRange(start: 0, end: 12.5), BufferedRange(start: 40, end: 90.25)])
        XCTAssertEqual(TP.parseSeekableRanges("garbage"), [])
        XCTAssertEqual(TP.parseSeekableRanges(#"{"cache-end":3}"#), [])
        XCTAssertEqual(TP.parseSeekableRanges(#"{"seekable-ranges":[]}"#), [])

        var t = make()
        _ = t.pressBegan(direction: 1, positionSec: 100)
        ticks(&t, 2)
        _ = t.pressEnded(direction: 1)
        XCTAssertNotNil(t.previewSec)
        t.noteCommitLanded()
        XCTAssertNil(t.previewSec)
    }

    // MARK: Swipe scrub (P2)

    private func scrubbing(origin: Double = 100, duration: Double = 600) -> TP {
        var t = make(duration: duration)
        XCTAssertEqual(t.scrubBegan(positionSec: origin), .none)
        return t
    }

    func testScrubBeganFromIdle() {
        let t = scrubbing()
        XCTAssertEqual(t.mode, .scrubbing(targetSec: 100))
        XCTAssertEqual(t.previewSec, 100)
        XCTAssertEqual(t.originSec, 100)
    }

    func testScrubMovedOrivio() {
        var t = scrubbing()
        XCTAssertEqual(t.scrubMoved(deltaPoints: 140), .none)
        XCTAssertEqual(t.mode, .scrubbing(targetSec: 135))
        XCTAssertEqual(t.previewSec, 135)
    }

    func testScrubRateScale() {
        var t = scrubbing()
        t.scrubRateScale = 2
        _ = t.scrubMoved(deltaPoints: 140)
        XCTAssertEqual(t.previewSec, 170)
    }

    func testScrubBobsupraCurve() {
        var t = scrubbing()
        t.scrubCurve = .bobsupra
        for _ in 0..<7 { _ = t.scrubMoved(deltaPoints: 20) }
        XCTAssertEqual(t.previewSec ?? -1, 140.32, accuracy: 0.01)
    }

    func testScrubClamps() {
        var t = scrubbing(origin: 590)
        _ = t.scrubMoved(deltaPoints: 400)
        XCTAssertEqual(t.previewSec, 599.5)
        var u = scrubbing(origin: 5)
        _ = u.scrubMoved(deltaPoints: -400)
        XCTAssertEqual(u.previewSec, 0)
    }

    func testScrubBackwardCancelsUpNextOnce() {
        var t = scrubbing()
        XCTAssertEqual(t.scrubNudge(direction: 1), .none)          // 110
        XCTAssertEqual(t.scrubNudge(direction: -1), .none)         // 100, not below origin − 1
        XCTAssertEqual(t.scrubNudge(direction: -1), .cancelUpNext) // 90
        XCTAssertEqual(t.previewSec, 90)
        XCTAssertEqual(t.scrubNudge(direction: -1), .none)         // only once
        XCTAssertEqual(t.scrubMoved(deltaPoints: -40), .none)
        XCTAssertEqual(t.previewSec, 70)
    }

    func testScrubCommitAfterMovesUncoveredAndCovered() {
        var t = scrubbing()
        _ = t.scrubMoved(deltaPoints: 140)
        XCTAssertEqual(t.scrubCommit(), .commit(.init(targetSec: 135, fromSec: 100, stages: [.keyframes, .exact])))
        XCTAssertEqual(t.mode, .idle)
        XCTAssertEqual(t.previewSec, 135)

        var c = scrubbing()
        c.seekableRanges = [BufferedRange(start: 0, end: 200)]
        _ = c.scrubMoved(deltaPoints: 140)
        XCTAssertEqual(c.scrubCommit(), .commit(.init(targetSec: 135, fromSec: 100, stages: [.exact])))
        c.noteCommitLanded()
        XCTAssertNil(c.previewSec)
    }

    func testScrubCommitWithoutMovementSeeksNowhere() {
        var t = scrubbing()
        XCTAssertEqual(t.scrubMoved(deltaPoints: 0), .none)
        XCTAssertEqual(t.scrubCommit(), .none)
        XCTAssertEqual(t.mode, .idle)
        XCTAssertNil(t.previewSec)
        // Moved away and back to the origin still counts as moved (the user scrubbed).
        var u = scrubbing()
        _ = u.scrubNudge(direction: 1)
        _ = u.scrubNudge(direction: -1)
        XCTAssertEqual(u.scrubCommit(), .commit(.init(targetSec: 100, fromSec: 100, stages: [.keyframes, .exact])))
    }

    func testScrubCancelAndGenericCancel() {
        var t = scrubbing()
        _ = t.scrubMoved(deltaPoints: 40)
        XCTAssertEqual(t.scrubCancel(), .none)
        XCTAssertEqual(t.mode, .idle)
        XCTAssertNil(t.previewSec)
        var u = scrubbing()
        _ = u.scrubMoved(deltaPoints: 40)
        XCTAssertEqual(u.cancel(), .none)
        XCTAssertEqual(u.mode, .idle)
        XCTAssertNil(u.previewSec)
    }

    func testScrubBeganOutsideIdleChangesNothing() {
        var t = make(mode: .scan, duration: 600)
        _ = t.pressBegan(direction: 1, positionSec: 100)
        _ = t.holdTick(heldSec: held(1))
        XCTAssertEqual(t.mode, .scanning(rate: 2))
        XCTAssertEqual(t.scrubBegan(positionSec: 300), .none)
        XCTAssertEqual(t.mode, .scanning(rate: 2))

        var s = make(duration: 600)
        _ = s.pressBegan(direction: -1, positionSec: 100)
        let before = s.mode
        XCTAssertEqual(s.scrubBegan(positionSec: 300), .none)
        XCTAssertEqual(s.mode, before)
        XCTAssertEqual(s.previewSec, 90)
    }

    func testScrubMethodsOutsideScrubbingDoNothing() {
        var t = make(duration: 600)
        XCTAssertEqual(t.scrubMoved(deltaPoints: 100), .none)
        XCTAssertEqual(t.scrubNudge(direction: 1), .none)
        XCTAssertEqual(t.scrubCommit(), .none)
        XCTAssertEqual(t.scrubCancel(), .none)
        XCTAssertEqual(t.mode, .idle)
        XCTAssertNil(t.previewSec)
        // A press while scrubbing does nothing to the model (the controller nudges instead).
        var s = scrubbing()
        XCTAssertEqual(s.pressBegan(direction: 1, positionSec: 0), .none)
        XCTAssertEqual(s.mode, .scrubbing(targetSec: 100))
    }

    // MARK: Click on release (critique C8)

    func testClickOnReleaseActsOnRelease() {
        var t = make()
        t.clickOnRelease = true
        XCTAssertEqual(t.pressBegan(direction: -1, positionSec: 100), .none)
        XCTAssertNil(t.previewSec, "no +10 s preview while a release-click is down (review r1 P3 #6)")
        XCTAssertEqual(t.pressEnded(direction: -1), .immediateSeek(deltaSec: -10))
        XCTAssertEqual(t.mode, .idle)
        XCTAssertNil(t.previewSec)
        XCTAssertEqual(t.pressBegan(direction: 1, positionSec: 100), .none)
        XCTAssertEqual(t.pressEnded(direction: 1), .immediateSeek(deltaSec: 10))
    }

    func testClickOnReleaseHoldStepsFromOriginWithNoJump() {
        var t = make()
        t.clickOnRelease = true
        XCTAssertEqual(t.pressBegan(direction: 1, positionSec: 100), .none)   // no immediate seek
        XCTAssertNil(t.previewSec)
        _ = t.holdTick(heldSec: held(1))
        XCTAssertNotNil(t.previewSec, "the first hold tick draws the preview")
        _ = t.holdTick(heldSec: held(2))
        // Latched at the gesture's start: flipping it mid-hold changes nothing.
        t.clickOnRelease = false
        XCTAssertEqual(t.pressEnded(direction: 1),
                       .commit(.init(targetSec: 140, fromSec: 100, stages: [.keyframes, .exact])))
        // Off again: the first press is the P1 immediate seek.
        XCTAssertEqual(t.pressBegan(direction: 1, positionSec: 140), .immediateSeek(deltaSec: 10))
    }
}
