import XCTest
@testable import NuvioTV

/// GitHub #33: the click latch, the composed preview-request lifecycle (design review r2-2) and
/// the completion rule (r1-5, r2-5).
final class SeekPreviewLifecycleTests: XCTestCase {

    // MARK: ClickPreviewLatch

    typealias Latch = ClickPreviewLatch

    func testQuickLandingEndsAtTheDwell() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        XCTAssertEqual(l.nextDeadline, 10 + Latch.fallbackSec)
        l.landed(generation: 3, now: 10.2)
        XCTAssertEqual(l.nextDeadline!, 10 + Latch.minDwellSec, accuracy: 1e-9)
        l.tick(now: 11.1)
        XCTAssertNotNil(l.active, "still inside the dwell")
        l.tick(now: 11.21)
        XCTAssertNil(l.active)
        XCTAssertNil(l.nextDeadline)
    }

    func testDelayedLandingEndsAtTheLanding() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.tick(now: 12)
        XCTAssertNotNil(l.active)
        l.landed(generation: 3, now: 12.5)
        XCTAssertEqual(l.nextDeadline, 12.5)
        l.tick(now: 12.5)
        XCTAssertNil(l.active)
    }

    func testNoLandingEndsAtTheFallback() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.tick(now: 13.99)
        XCTAssertNotNil(l.active)
        l.tick(now: 14)
        XCTAssertNil(l.active)
    }

    func testANewerSeekLandingSupersedes() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.landed(generation: 2, now: 10.1)
        XCTAssertEqual(l.nextDeadline, 14, "an older landing is ignored")
        l.landed(generation: 4, now: 10.2)
        XCTAssertNil(l.active)
    }

    func testRejected() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.rejected(generation: 2)
        XCTAssertNotNil(l.active, "another generation's rejection is ignored")
        l.rejected(generation: 4)
        XCTAssertNotNil(l.active)
        l.rejected(generation: 3)
        XCTAssertNil(l.active)
    }

    func testSecondClickReplaces() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.landed(generation: 3, now: 10.1)
        l.clicked(targetSec: 120, generation: 4, now: 10.5)
        XCTAssertEqual(l.active, Latch.Active(targetSec: 120, generation: 4, shownAt: 10.5, deadline: 14.5))
        l.landed(generation: 3, now: 10.75)
        XCTAssertEqual(l.nextDeadline, 14.5, "the first click's late landing does not end the second card")
    }

    func testClear() {
        var l = Latch()
        l.clicked(targetSec: 110, generation: 3, now: 10)
        l.clear()
        XCTAssertNil(l.active)
        XCTAssertNil(l.nextDeadline)
        l.landed(generation: 3, now: 11)
        l.rejected(generation: 3)
        l.tick(now: 20)
        XCTAssertNil(l.active)
    }

    func testNextDeadlineInEachState() {
        var l = Latch()
        XCTAssertNil(l.nextDeadline, "idle")
        l.clicked(targetSec: 1, generation: 1, now: 0)
        XCTAssertEqual(l.nextDeadline, 4, "waiting for the landing")
        l.landed(generation: 1, now: 0.5)
        XCTAssertEqual(l.nextDeadline!, 1.2, accuracy: 1e-9, "landed inside the dwell")
        l.clicked(targetSec: 1, generation: 2, now: 5)
        l.landed(generation: 2, now: 7)
        XCTAssertEqual(l.nextDeadline, 7, "landed after the dwell")
    }

    func testLandedReportsWhatItDid() {
        var l = Latch()
        XCTAssertEqual(l.landed(generation: 3, now: 1), .ignored, "no click")
        l.clicked(targetSec: 110, generation: 3, now: 10)
        XCTAssertEqual(l.landed(generation: 2, now: 10.1), .ignored, "an older seek")
        XCTAssertEqual(l.landed(generation: 3, now: 10.2), .own)
        XCTAssertEqual(l.landed(generation: 4, now: 10.3), .superseded)
        XCTAssertNil(l.active)
    }

    // MARK: SeekPreviewLifecycle

    typealias LC = SeekPreviewLifecycle
    typealias Key = SeekPreviewLifecycle.Key
    typealias E = SeekPreviewLifecycle.Effects

    private static let both = SeekPreviewCapability(fillsWatched: true, fillsUnwatched: true)
    private static let watched = SeekPreviewCapability(fillsWatched: true, fillsUnwatched: false)

    private func key(_ t: Double?, _ c: SeekPreviewCapability = both, gen: Int = 0, alive: Bool = true) -> Key {
        Key(requestTargetSec: t, capability: c, sourceGeneration: gen, alive: alive)
    }

    func testUnchanged() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(10)), [])
        XCTAssertEqual(LC.effects(from: key(nil), to: key(nil)), [])
    }

    func testTeardown() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(10, alive: false)), E.cleanup.union(.clearLatch))
        XCTAssertEqual(LC.effects(from: key(nil), to: key(nil, alive: false)), E.cleanup.union(.clearLatch))
        XCTAssertEqual(LC.effects(from: key(nil, alive: false), to: key(10, alive: false)), [], "nothing after teardown")
    }

    func testSourceGenerationChanged() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(10, gen: 1)), E.cleanup.union(.requestNow))
        XCTAssertEqual(LC.effects(from: key(10), to: key(20, gen: 1)), E.cleanup.union(.requestNow))
        XCTAssertEqual(LC.effects(from: key(nil), to: key(nil, gen: 1)), E.cleanup)
    }

    func testCapabilityLost() {
        // `any` lost: the plan has no request target any more (card time only).
        XCTAssertEqual(LC.effects(from: key(10), to: key(nil, .none)), E.cleanup)
        // `fillsUnwatched` lost, watched kept: cleaned up, then the same target asks again.
        XCTAssertEqual(LC.effects(from: key(10), to: key(10, Self.watched)), E.cleanup.union(.requestNow))
    }

    func testCapabilityGained() {
        XCTAssertEqual(LC.effects(from: key(nil, .none), to: key(10)), [.requestNow])
        XCTAssertEqual(LC.effects(from: key(10, Self.watched), to: key(10)), [.requestNow],
                       "fillsUnwatched gained during a stationary target")
        XCTAssertEqual(LC.effects(from: key(nil, .none), to: key(nil)), [], "no target, nothing to ask")
    }

    func testTargetEdges() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(nil)), E.cleanup)
        XCTAssertEqual(LC.effects(from: key(nil), to: key(10)), [.requestNow])
        XCTAssertEqual(LC.effects(from: key(10), to: key(20)), [.requestNow], "a move is a throttled sample")
    }

    // Combined edges (r2-2): every independent cleanup still runs.

    func testCapabilityGainPlusTargetExit() {
        XCTAssertEqual(LC.effects(from: key(10, Self.watched), to: key(nil)), E.cleanup)
    }

    func testSourceChangePlusTargetExit() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(nil, gen: 1)), E.cleanup)
    }

    func testSourceChangePlusTeardown() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(10, gen: 1, alive: false)), E.cleanup.union(.clearLatch),
                       "teardown dominates: never a request")
    }

    func testCapabilityLossPlusTargetMove() {
        XCTAssertEqual(LC.effects(from: key(10), to: key(20, Self.watched)), E.cleanup.union(.requestNow))
    }

    // Review r5: a click's own landing retries a picture that is not the target's match.

    func testLandingEffects() {
        let p = SeekPreviewPlan(requestTargetSec: 110, cardTargetSec: 110, placeholderAllowed: true)
        XCTAssertEqual(LC.landingEffects(.own, plan: p, matchedTargetSec: nil), [.requestNow], "no match shown")
        XCTAssertEqual(LC.landingEffects(.own, plan: p, matchedTargetSec: 100), [.requestNow],
                       "the accepted frame matched another target")
        XCTAssertEqual(LC.landingEffects(.own, plan: p, matchedTargetSec: 110), [], "the target's match is shown")
        XCTAssertEqual(LC.landingEffects(.ignored, plan: p, matchedTargetSec: nil), [], "an older seek")
        XCTAssertEqual(LC.landingEffects(.superseded, plan: p, matchedTargetSec: nil), [], "a newer seek")
        XCTAssertEqual(LC.landingEffects(.own, plan: .none, matchedTargetSec: nil), [], "the dwell is over")
    }

    // MARK: SeekPreviewCompletion

    typealias C = SeekPreviewCompletion
    private func plan(_ t: Double?) -> SeekPreviewPlan {
        SeekPreviewPlan(requestTargetSec: t, cardTargetSec: t, placeholderAllowed: true)
    }

    func testStaleGenerationDoesNothing() {
        let d = C.decide(requestGeneration: 1, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(100), shownSec: 100)
        XCTAssertEqual(d, C.Decision.stale)
        XCTAssertFalse(d.finishThrottle)
        XCTAssertNil(d.refineTargetSec)
    }

    func testCurrentAccepted() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(100), shownSec: 96)
        XCTAssertEqual(d, C.Decision(frame: .publish, finishThrottle: true, refineTargetSec: 100))
    }

    func testCurrentOutOfReach() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(300), shownSec: 100)
        XCTAssertEqual(d.frame, .keep, "120 s reach measured against the current target")
        XCTAssertTrue(d.finishThrottle)
        XCTAssertNil(d.refineTargetSec, "the old target is never refined")
    }

    func testCurrentNilSameTargetClears() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(100), shownSec: nil)
        XCTAssertEqual(d, C.Decision(frame: .clear, finishThrottle: true, refineTargetSec: 100))
    }

    func testCurrentNilMovedTargetKeeps() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(140), shownSec: nil)
        XCTAssertEqual(d, C.Decision(frame: .keep, finishThrottle: true, refineTargetSec: nil))
    }

    func testMovedTargetStillPublishesAFrameInReach() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: plan(140), shownSec: 101)
        XCTAssertEqual(d, C.Decision(frame: .publish, finishThrottle: true, refineTargetSec: nil))
    }

    func testNoCurrentTargetOnlyFinishes() {
        let d = C.decide(requestGeneration: 2, currentGeneration: 2, requestTargetSec: 100,
                         currentPlan: .none, shownSec: 100)
        XCTAssertEqual(d, C.Decision(frame: .keep, finishThrottle: true, refineTargetSec: nil))
    }
}

/// Review r2 P2 #1, r3 P2 #1: where a Left/Right click lands (`ClickLanding`), checked against
/// models of how each engine really lands a click: mpv's relative seek (player/playloop.c: the
/// base during a seek is `last_seek_pts` clamped to [0, length]; a seek before 0 lands on the start,
/// one past the end on the end) and Aether's absolute target (`AetherSeekPlan.target`, real code).
@MainActor
final class ClickLandingTests: XCTestCase {
    typealias L = ClickLanding

    enum Click: Equatable {
        case left, right, chapter(Double)
        var action: EdgeClickAction {
            switch self {
            case .left: return .relative(-10)
            case .right: return .relative(10)
            case .chapter(let s): return .absolute(s)
            }
        }
    }

    /// mpv, a chain of clicks each pressed while the earlier ones are still in flight.
    struct MPVModel {
        let durationSec: Double
        var positionSec: Double
        /// `last_seek_pts`, unclamped (mpv stores the raw target).
        var lastSeekPts: Double?

        /// `get_playback_time` while a seek runs: clamped to [0, length], never below 0.
        var playbackTime: Double {
            guard let p = lastSeekPts else { return positionSec }
            return durationSec > 0 ? min(max(p, 0), durationSec) : max(p, 0)
        }

        /// Issues `action` (a chapter jump is the absolute target the transport sends); returns
        /// where it lands once mpv is done.
        mutating func issue(_ action: EdgeClickAction, absoluteTargetSec: Double?) -> Double {
            let seekPts: Double
            switch action {
            case .relative(let d): seekPts = playbackTime + d
            case .absolute: seekPts = absoluteTargetSec!
            }
            lastSeekPts = seekPts
            return durationSec > 0 ? min(max(seekPts, 0), durationSec) : max(seekPts, 0)
        }
    }

    /// Runs `clicks` back to back (none lands before the next press) on `semantics`, the way the
    /// transport and the engine adapter do: decide, record what the adapter records, compare the
    /// card with the engine model's landing. Returns the cards.
    @discardableResult
    func run(_ clicks: [Click], positionSec: Double, durationSec: Double, semantics: SeekLandingSemantics,
             startInFlight: L.InFlight = .none, file: StaticString = #filePath, line: UInt = #line) -> [Double?] {
        var inFlight = startInFlight
        var mpv = MPVModel(durationSec: durationSec, positionSec: positionSec,
                           lastSeekPts: { if case .target(let t) = startInFlight { return t } else { return nil } }())
        var cards: [Double?] = []
        for click in clicks {
            let o = L.decide(click.action, positionSec: positionSec, inFlight: inFlight, durationSec: durationSec,
                             semantics: semantics)
            XCTAssertEqual(o.cardTargetSec, o.recordedTargetSec, "card == recorded", file: file, line: line)
            if let r = o.recordedTargetSec {
                XCTAssertGreaterThanOrEqual(r, 0, file: file, line: line)
                if durationSec > 0 { XCTAssertLessThanOrEqual(r, durationSec, file: file, line: line) }
            }
            switch semantics {
            case .mpvRelative:
                // A chapter jump goes to mpv as an absolute seek to the decided target.
                let landed = mpv.issue(click.action, absoluteTargetSec: o.recordedTargetSec)
                if let card = o.cardTargetSec {
                    XCTAssertEqual(card, landed, accuracy: 1e-9, "mpv lands where the card says", file: file, line: line)
                }
                // The adapter records what `seekBy` / `chapterSeek` pass (nil = unknown).
                inFlight = o.recordedTargetSec.map { .target($0) } ?? .unknownTarget
            case .aetherAbsolute:
                let mode: TransportSeekMode
                if case .relative(let d) = click.action { mode = .relative(deltaSec: d) } else { mode = .absolute }
                let inFlightTarget: Double? = { if case .target(let t) = inFlight { return t } else { return nil } }()
                let sent = AetherSeekPlan.target(mode: mode, targetSec: o.recordedTargetSec, positionSec: positionSec,
                                                 inFlightTargetSec: inFlightTarget, durationSec: durationSec)
                if let card = o.cardTargetSec {
                    XCTAssertEqual(card, sent!, accuracy: 1e-9, "Aether lands where the card says", file: file, line: line)
                }
                // The adapter records the target it sent.
                inFlight = sent.map { .target($0) } ?? inFlight
            }
            cards.append(o.cardTargetSec)
        }
        return cards
    }

    // MARK: Base

    func testInFlightBuildsFromTheEngine() {
        XCTAssertEqual(L.InFlight(hasSeekInFlight: false, targetSec: 50), .none)
        XCTAssertEqual(L.InFlight(hasSeekInFlight: true, targetSec: 50), .target(50))
        XCTAssertEqual(L.InFlight(hasSeekInFlight: true, targetSec: nil), .unknownTarget)
        XCTAssertEqual(L.InFlight(hasSeekInFlight: true, targetSec: .nan), .unknownTarget)
    }

    func testBase() {
        XCTAssertEqual(L.base(positionSec: 100, inFlight: .none, durationSec: 1000), 100)
        XCTAssertEqual(L.base(positionSec: 100, inFlight: .target(300), durationSec: 1000), 300)
        XCTAssertNil(L.base(positionSec: 100, inFlight: .unknownTarget, durationSec: 1000), "never the stale position")
        XCTAssertEqual(L.base(positionSec: 4, inFlight: .target(-6), durationSec: 1000), 0, "mpv clamps a seek's base")
        XCTAssertEqual(L.base(positionSec: 4, inFlight: .target(1012), durationSec: 1000), 1000)
        XCTAssertEqual(L.base(positionSec: 4, inFlight: .target(5000), durationSec: 0), 5000, "no known end")
        XCTAssertNil(L.base(positionSec: .nan, inFlight: .none, durationSec: 1000))
    }

    func testOriginFallsBackToThePosition() {
        XCTAssertEqual(L.originSec(positionSec: 100, inFlight: .unknownTarget, durationSec: 1000), 100)
        XCTAssertEqual(L.originSec(positionSec: 100, inFlight: .target(-6), durationSec: 1000), 0)
        XCTAssertEqual(L.originSec(positionSec: 100, inFlight: .target(300), durationSec: 1000), 300)
    }

    // MARK: Single clicks

    func testSingleClicks() {
        for s in [SeekLandingSemantics.mpvRelative, .aetherAbsolute] {
            XCTAssertEqual(run([.right], positionSec: 100, durationSec: 1000, semantics: s), [110])
            XCTAssertEqual(run([.left], positionSec: 100, durationSec: 1000, semantics: s), [90])
            XCTAssertEqual(run([.left], positionSec: 4, durationSec: 1000, semantics: s), [0])
        }
        XCTAssertEqual(run([.right], positionSec: 995, durationSec: 1000, semantics: .mpvRelative), [1000],
                       "mpv runs into the end")
        XCTAssertEqual(run([.right], positionSec: 995, durationSec: 1000, semantics: .aetherAbsolute), [999.5])
    }

    // MARK: Pairs and triples near 0 (review r3: at 4 s, Left then Right lands near 10 s)

    func testPairsNearZero() {
        for s in [SeekLandingSemantics.mpvRelative, .aetherAbsolute] {
            XCTAssertEqual(run([.left, .right], positionSec: 4, durationSec: 1000, semantics: s), [0, 10])
            XCTAssertEqual(run([.left, .left], positionSec: 4, durationSec: 1000, semantics: s), [0, 0])
            XCTAssertEqual(run([.right, .left], positionSec: 4, durationSec: 1000, semantics: s), [14, 4])
            XCTAssertEqual(run([.right, .right], positionSec: 4, durationSec: 1000, semantics: s), [14, 24])
        }
    }

    func testTriplesNearZero() {
        for s in [SeekLandingSemantics.mpvRelative, .aetherAbsolute] {
            XCTAssertEqual(run([.left, .left, .right], positionSec: 4, durationSec: 1000, semantics: s), [0, 0, 10])
            XCTAssertEqual(run([.left, .right, .left], positionSec: 4, durationSec: 1000, semantics: s), [0, 10, 0])
            XCTAssertEqual(run([.right, .left, .left], positionSec: 4, durationSec: 1000, semantics: s), [14, 4, 0])
        }
    }

    // MARK: Pairs and triples near the end

    func testPairsNearTheEnd() {
        XCTAssertEqual(run([.right, .left], positionSec: 995, durationSec: 1000, semantics: .mpvRelative), [1000, 990])
        XCTAssertEqual(run([.right, .right], positionSec: 995, durationSec: 1000, semantics: .mpvRelative), [1000, 1000])
        XCTAssertEqual(run([.left, .right], positionSec: 995, durationSec: 1000, semantics: .mpvRelative), [985, 995])
        XCTAssertEqual(run([.right, .left], positionSec: 995, durationSec: 1000, semantics: .aetherAbsolute), [999.5, 989.5])
        XCTAssertEqual(run([.right, .right], positionSec: 995, durationSec: 1000, semantics: .aetherAbsolute), [999.5, 999.5])
        XCTAssertEqual(run([.left, .right], positionSec: 995, durationSec: 1000, semantics: .aetherAbsolute), [985, 995])
    }

    func testTriplesNearTheEnd() {
        XCTAssertEqual(run([.right, .right, .left], positionSec: 995, durationSec: 1000, semantics: .mpvRelative),
                       [1000, 1000, 990])
        XCTAssertEqual(run([.right, .left, .right], positionSec: 995, durationSec: 1000, semantics: .mpvRelative),
                       [1000, 990, 1000])
        XCTAssertEqual(run([.right, .right, .left], positionSec: 995, durationSec: 1000, semantics: .aetherAbsolute),
                       [999.5, 999.5, 989.5])
        XCTAssertEqual(run([.right, .left, .right], positionSec: 995, durationSec: 1000, semantics: .aetherAbsolute),
                       [999.5, 989.5, 999.5])
    }

    // MARK: Unknown duration, unknown base

    func testUnknownDurationForwardHasNoCard() {
        for s in [SeekLandingSemantics.mpvRelative, .aetherAbsolute] {
            XCTAssertEqual(run([.right], positionSec: 100, durationSec: 0, semantics: s), [nil])
            XCTAssertEqual(run([.left], positionSec: 100, durationSec: 0, semantics: s), [90], "the start is known")
            XCTAssertEqual(run([.left], positionSec: 5, durationSec: 0, semantics: s), [0])
        }
        // mpv: the forward click's landing stays unknown, so the click after it has no base.
        XCTAssertEqual(run([.right, .left], positionSec: 100, durationSec: 0, semantics: .mpvRelative), [nil, nil])
        // Aether resolves the forward click itself (an absolute target it records), so the next
        // click starts from that.
        XCTAssertEqual(run([.right, .left], positionSec: 100, durationSec: 0, semantics: .aetherAbsolute), [nil, 100])
    }

    func testUnknownBaseHasNoRelativeCard() {
        for s in [SeekLandingSemantics.mpvRelative, .aetherAbsolute] {
            XCTAssertEqual(run([.right], positionSec: 10, durationSec: 1000, semantics: s, startInFlight: .unknownTarget), [nil])
            XCTAssertEqual(run([.left], positionSec: 10, durationSec: 1000, semantics: s, startInFlight: .unknownTarget), [nil])
        }
        let o = L.decide(.relative(10), positionSec: 10, inFlight: .unknownTarget, durationSec: 1000, semantics: .mpvRelative)
        XCTAssertNil(o.recordedTargetSec)
        XCTAssertNil(o.fromSec)
    }

    // MARK: Chapters

    func testChapterJumps() {
        for s in [SeekLandingSemantics.mpvRelative, .aetherAbsolute] {
            XCTAssertEqual(run([.chapter(240)], positionSec: 10, durationSec: 1000, semantics: s, startInFlight: .unknownTarget),
                           [240], "known whatever the base")
            XCTAssertEqual(run([.chapter(240), .right], positionSec: 10, durationSec: 1000, semantics: s), [240, 250])
            XCTAssertEqual(run([.chapter(1200)], positionSec: 10, durationSec: 1000, semantics: s), [999.5])
            XCTAssertEqual(run([.chapter(-3)], positionSec: 10, durationSec: 1000, semantics: s), [0])
            XCTAssertEqual(run([.chapter(5000)], positionSec: 10, durationSec: 0, semantics: s), [5000],
                           "a chapter start is a point in the file")
            XCTAssertEqual(run([.left, .chapter(0), .right], positionSec: 4, durationSec: 1000, semantics: s), [0, 0, 10])
        }
    }

    func testFromIsTheBase() {
        let o = L.decide(.relative(10), positionSec: 4, inFlight: .target(-6), durationSec: 1000, semantics: .mpvRelative)
        XCTAssertEqual(o.fromSec, 0)
        XCTAssertEqual(o.recordedTargetSec, 10)
    }

    func testNonFiniteInputsHaveNoCard() {
        XCTAssertNil(L.decide(.relative(.nan), positionSec: 4, inFlight: .none, durationSec: 1000, semantics: .mpvRelative).cardTargetSec)
        XCTAssertNil(L.decide(.absolute(.infinity), positionSec: 4, inFlight: .none, durationSec: 1000, semantics: .mpvRelative).cardTargetSec)
        XCTAssertNil(L.decide(.relative(10), positionSec: .nan, inFlight: .none, durationSec: 1000, semantics: .mpvRelative).cardTargetSec)
    }

    func testAetherMarginMatchesTheEngineClamp() {
        for d in [0.0, 0.6, 10, 1000] {
            for x in [-5.0, 0, 0.2, 9.8, 500, 999.7, 2000] {
                XCTAssertEqual(L.clamp(x, durationSec: d, semantics: .aetherAbsolute), AetherSeekPlan.clamp(x, durationSec: d),
                               "x=\(x) d=\(d)")
            }
        }
        // Shorter than the margin: the engine would not bound it; ours stays in the file and the
        // engine sends it unchanged.
        for d in [0.3, 0.5] {
            for x in [-5.0, 0, 0.2, 10] {
                let ours = L.clamp(x, durationSec: d, semantics: .aetherAbsolute)
                XCTAssertEqual(ours, 0)
                XCTAssertEqual(AetherSeekPlan.clamp(ours, durationSec: d), ours)
            }
        }
    }

    // MARK: Property loop

    /// Random chains of clicks on random files, both engines: every card equals the recorded
    /// estimate and the engine model's landing, and every recorded estimate stays in the file.
    func testRandomChainsStayInsideAndMatchTheEngine() {
        var seed: UInt64 = 0x5EEC
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let durations: [Double] = [0, 0.3, 8, 25, 1000, 7300]
        for _ in 0..<3000 {
            let duration = durations[Int(next() * Double(durations.count))]
            let position = duration > 0 ? next() * duration : next() * 500
            var clicks: [Click] = []
            for _ in 0..<(1 + Int(next() * 5)) {
                let r = next()
                if r < 0.4 { clicks.append(.left) } else if r < 0.8 { clicks.append(.right) } else {
                    clicks.append(.chapter((next() * 1.4 - 0.2) * max(duration, 100)))
                }
            }
            let start: L.InFlight = next() < 0.15 ? .unknownTarget : next() < 0.3 ? .target(next() * 1.4 * max(duration, 100) - 20) : .none
            for s in [SeekLandingSemantics.mpvRelative, .aetherAbsolute] {
                run(clicks, positionSec: position, durationSec: duration, semantics: s, startInFlight: start)
            }
        }
    }
}
