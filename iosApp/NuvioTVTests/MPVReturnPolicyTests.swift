import AVKit
import CoreMedia
import XCTest
@testable import NuvioTV

// spec-mpv-return §5.1: the pure decisions behind the mpv return. Each class pins one type.

private let owner = PlaybackIdentity(accountKey: "acct-a", profileId: 1)
private let otherAccount = PlaybackIdentity(accountKey: "acct-b", profileId: 1)
private let otherProfile = PlaybackIdentity(accountKey: "acct-a", profileId: 2)

private func payload(owner o: PlaybackIdentity = owner, context: String = "ctx", start: PlayerReturnHandoff.Start = .position(100),
                     intent: PlayerReturnHandoff.Intent = .pause, generation: Int = 1,
                     origin: PlayerReturnHandoff.Origin = .mpvReturn) -> PlayerReturnHandoff {
    PlayerReturnHandoff(owner: o, contextID: context, streamKey: "key", start: start, intent: intent, playedSec: 12,
                        healthyReported: false, returnGeneration: generation, freshStartsLeft: origin == .mpvReturn ? 1 : 0,
                        audio: .auto, subtitle: .auto, audioDelaySec: nil, speed: 1, origin: origin)
}

final class PlayerReturnHandoffTests: XCTestCase {

    func testValidateOverOwnerContextGenerationAndOrigin() {
        let owners: [(PlaybackIdentity, Bool)] = [(owner, true), (otherAccount, false), (otherProfile, false)]
        let contexts: [(String, Bool)] = [("ctx", true), ("other", false)]
        let generations: [(Int, Bool)] = [(4, false), (5, false), (6, true), (60, true)]   // last accepted = 5
        let origins: [PlayerReturnHandoff.Origin] = [.mpvReturn, .nativeReturn, .aetherReturn]
        for (current, ownerOK) in owners {
            for (ctx, ctxOK) in contexts {
                for (gen, genOK) in generations {
                    for origin in origins {
                        let p = payload(generation: gen, origin: origin)
                        let v = p.validate(current: current, contextID: ctx, lastGeneration: 5)
                        let expected: PlayerReturnHandoff.Validation =
                            !ownerOK ? .discard(.owner) : !ctxOK ? .discard(.context) : !genOK ? .discard(.generation) : .accept
                        XCTAssertEqual(v, expected, "owner=\(current) ctx=\(ctx) gen=\(gen) origin=\(origin)")
                    }
                }
            }
        }
    }

    func testTheStartOptionFollowsTheIntent() {
        XCTAssertTrue(payload(intent: .pause).startsPaused)
        XCTAssertFalse(payload(intent: .play).startsPaused)
        XCTAssertEqual(PlayerReturnHandoff.Intent.pause.toggled, .play)
        XCTAssertEqual(PlayerReturnHandoff.Intent.play.toggled, .pause)
    }

    /// `.position` resumes exactly there for any p >= 0 (0 and <= 10 s included); live skips; a normal
    /// start (or none) is today's rule.
    func testReturnStartResume() {
        XCTAssertEqual(PlayerReturnResume.decide(.position(0)), .at(0))
        XCTAssertEqual(PlayerReturnResume.decide(.position(5)), .at(5))
        XCTAssertEqual(PlayerReturnResume.decide(.position(1265.8)), .at(1265.8))
        XCTAssertEqual(PlayerReturnResume.decide(.live), PlayerReturnResume.none)
        XCTAssertEqual(PlayerReturnResume.decide(.normalStart), .normal)
        XCTAssertEqual(PlayerReturnResume.decide(nil), .normal)
        XCTAssertEqual(PlayerReturnResume.decide(.position(-1)), .normal)
        XCTAssertEqual(PlayerReturnResume.decide(.position(.nan)), .normal)
    }

    /// Log tokens never carry a URL.
    func testLogTokensCarryNoURL() {
        let sub = PlayerReturnHandoff.SubtitlePick.addon(originalURL: "https://subs.example/abc.srt?token=secret",
                                                         lang: "en", title: "x")
        XCTAssertEqual(sub.logToken, "addon(pending)")
        XCTAssertFalse(sub.logToken.contains("http"))
        XCTAssertEqual(PlayerReturnHandoff.AudioPick.picked(lang: "eng", title: "t", ordinal: 0).logToken, "picked(eng)")
        XCTAssertEqual(PlayerReturnHandoff.Start.position(1265.81).logToken, "position(1265.8)")
    }
}

final class MPVReturnPlanTests: XCTestCase {

    private enum SnapKind: CaseIterable { case none, startup, playing, paused, live, seekInFlight, ownerInvalidAtPark, terminalAtPark }

    private func snapshot(_ kind: SnapKind) -> MPVReturnSnapshot? {
        switch kind {
        case .none: return nil
        case .startup: return snap(start: .normalStart)
        case .playing, .paused: return snap(start: .position(100))
        case .live: return snap(start: .live)
        case .seekInFlight: return snap(start: .position(250))
        case .ownerInvalidAtPark: return snap(start: .position(100), valid: false)
        case .terminalAtPark: return snap(start: .position(100), terminal: true)
        }
    }

    private func snap(start: PlayerReturnHandoff.Start, valid: Bool = true, terminal: Bool = false) -> MPVReturnSnapshot {
        MPVReturnSnapshot(owner: owner, ownerValidAtPark: valid, contextID: "ctx", streamKey: "key", start: start,
                          playedSec: 30, generation: 4, terminalAtPark: terminal)
    }

    private func facts(identity: PlaybackIdentity = owner, presence: PlayerPresence = .front, terminal: Bool = false,
                       swap: Bool = false) -> MPVReturnFacts {
        MPVReturnFacts(currentIdentity: identity, presence: presence, terminal: terminal, contextSwapPending: swap)
    }

    /// The full product, checked against the rows in order.
    func testFullProductOfSnapshotAndFacts() {
        let identities = [owner, otherAccount, otherProfile]
        let presences: [PlayerPresence] = [.front, .covered, .leaving]
        for kind in SnapKind.allCases {
            for identity in identities {
                for presence in presences {
                    for terminal in [false, true] {
                        for swap in [false, true] {
                            let s = snapshot(kind)
                            let f = facts(identity: identity, presence: presence, terminal: terminal, swap: swap)
                            let d = MPVReturnPlan.decide(snapshot: s, facts: f)
                            let expected: MPVReturnPlan.Decision
                            if s == nil { expected = .nothing(.notBackgrounded) }
                            else if !s!.ownerValidAtPark || identity != owner { expected = .abandon }
                            else if presence == .leaving { expected = .nothing(.leaving) }
                            else if terminal || s!.terminalAtPark { expected = .nothing(.terminal) }
                            else if swap { expected = .nothing(.contextSwap) }
                            else if presence == .covered { expected = .deferUntilFront }
                            else { expected = .replace(MPVReturnPlan.payload(from: s!)) }
                            XCTAssertEqual(d, expected, "\(kind) id=\(identity) \(presence) term=\(terminal) swap=\(swap)")
                        }
                    }
                }
            }
        }
    }

    func testTheReplacementCarriesTheSnapshotAndStartsPaused() {
        let s = snap(start: .position(1265.8))
        guard case let .replace(p) = MPVReturnPlan.decide(snapshot: s, facts: facts()) else { return XCTFail() }
        XCTAssertEqual(p.intent, .pause, "paused whatever was playing (decision A)")
        XCTAssertEqual(p.start, .position(1265.8))
        XCTAssertEqual(p.returnGeneration, 4)
        XCTAssertEqual(p.freshStartsLeft, 1)
        XCTAssertEqual(p.origin, .mpvReturn)
        XCTAssertEqual(p.owner, owner)
        XCTAssertEqual(p.playedSec, 30)
    }

    func testPressesAfterParkFlipTheIntentLastPressWins() {
        var s = snap(start: .position(10))
        s.notePress()
        guard case let .replace(p1) = MPVReturnPlan.decide(snapshot: s, facts: facts()) else { return XCTFail() }
        XCTAssertEqual(p1.intent, .play)
        s.notePress()
        guard case let .replace(p2) = MPVReturnPlan.decide(snapshot: s, facts: facts()) else { return XCTFail() }
        XCTAssertEqual(p2.intent, .pause)
    }

    func testTheStartRule() {
        typealias S = PlayerReturnHandoff.Start
        // live wins
        XCTAssertEqual(MPVReturnPlan.start(isLive: true, started: true, positionSec: 50, seekInFlightTargetSec: 70,
                                           ownReturnStart: nil, resumeTargetSec: nil), S.live)
        // started: the seek in flight, else the position (0 kept, NaN to 0)
        XCTAssertEqual(MPVReturnPlan.start(isLive: false, started: true, positionSec: 50, seekInFlightTargetSec: 70,
                                           ownReturnStart: nil, resumeTargetSec: nil), .position(70))
        XCTAssertEqual(MPVReturnPlan.start(isLive: false, started: true, positionSec: 50, seekInFlightTargetSec: nil,
                                           ownReturnStart: .position(9), resumeTargetSec: 3), .position(50))
        XCTAssertEqual(MPVReturnPlan.start(isLive: false, started: true, positionSec: 0, seekInFlightTargetSec: nil,
                                           ownReturnStart: nil, resumeTargetSec: nil), .position(0))
        XCTAssertEqual(MPVReturnPlan.start(isLive: false, started: true, positionSec: .nan, seekInFlightTargetSec: nil,
                                           ownReturnStart: nil, resumeTargetSec: nil), .position(0))
        // not started: own return start, else the resume target, else a normal start
        XCTAssertEqual(MPVReturnPlan.start(isLive: false, started: false, positionSec: 3, seekInFlightTargetSec: nil,
                                           ownReturnStart: .position(6), resumeTargetSec: 900), .position(6))
        XCTAssertEqual(MPVReturnPlan.start(isLive: false, started: false, positionSec: 3, seekInFlightTargetSec: nil,
                                           ownReturnStart: nil, resumeTargetSec: 900), .position(900))
        XCTAssertEqual(MPVReturnPlan.start(isLive: false, started: false, positionSec: 3, seekInFlightTargetSec: 40,
                                           ownReturnStart: nil, resumeTargetSec: nil), .normalStart)
    }
}

final class MPVSelectionRestoreTests: XCTestCase {
    private let tracks = [
        MPVTrackSemantics(id: 1, lang: "eng", title: "Main"),
        MPVTrackSemantics(id: 2, lang: "eng", title: "Commentary"),
        MPVTrackSemantics(id: 3, lang: "jpn", title: ""),
        MPVTrackSemantics(id: 4, lang: "eng", title: "Main"),
    ]

    func testOrdinalAmongTracksSharingLanguageAndTitle() {
        XCTAssertEqual(MPVSelectionRestore.ordinal(of: 1, in: tracks), 0)
        XCTAssertEqual(MPVSelectionRestore.ordinal(of: 4, in: tracks), 1)
        XCTAssertEqual(MPVSelectionRestore.ordinal(of: 2, in: tracks), 0)
        XCTAssertNil(MPVSelectionRestore.ordinal(of: 9, in: tracks))
    }

    func testPicksAcrossTrackLists() {
        let reloaded = tracks.map { MPVTrackSemantics(id: $0.id + 10, lang: $0.lang, title: $0.title) }
        XCTAssertEqual(MPVSelectionRestore.choose(.picked(lang: "eng", title: "Main", ordinal: 1), tracks: reloaded), .select(14))
        XCTAssertEqual(MPVSelectionRestore.choose(.picked(lang: "eng", title: "Commentary", ordinal: 0), tracks: reloaded), .select(12))
        XCTAssertEqual(MPVSelectionRestore.choose(.picked(lang: "jpn", title: "", ordinal: 0), tracks: reloaded), .select(13))
        XCTAssertEqual(MPVSelectionRestore.choose(.picked(lang: "eng", title: "Main", ordinal: 2), tracks: reloaded), .notFound)
        XCTAssertEqual(MPVSelectionRestore.choose(.picked(lang: "fre", title: "Main", ordinal: 0), tracks: reloaded), .notFound)
        XCTAssertEqual(MPVSelectionRestore.choose(.picked(lang: "eng", title: "Main", ordinal: -1), tracks: reloaded), .notFound)
        XCTAssertEqual(MPVSelectionRestore.choose(.picked(lang: "eng", title: "Main", ordinal: 0), tracks: []), .notFound)
        XCTAssertNil(MPVSelectionRestore.choose(PlayerReturnHandoff.AudioPick.auto, tracks: reloaded))
    }

    func testSubtitlePicksOnlyEmbeddedChooseATrack() {
        XCTAssertEqual(MPVSelectionRestore.choose(PlayerReturnHandoff.SubtitlePick.embedded(lang: "jpn", title: "", ordinal: 0),
                                                  tracks: tracks), .select(3))
        XCTAssertNil(MPVSelectionRestore.choose(PlayerReturnHandoff.SubtitlePick.auto, tracks: tracks))
        XCTAssertNil(MPVSelectionRestore.choose(PlayerReturnHandoff.SubtitlePick.off, tracks: tracks))
        XCTAssertNil(MPVSelectionRestore.choose(PlayerReturnHandoff.SubtitlePick.addon(originalURL: "u", lang: "en", title: ""),
                                                tracks: tracks))
    }
}

final class MPVPendingSubtitlePickTests: XCTestCase {
    private let url = "https://subs.example/en.srt"
    private typealias E = MPVPendingSubtitlePick.Event

    private func run(_ events: [E]) -> (outcomes: [MPVPendingSubtitlePick.Outcome], pick: MPVPendingSubtitlePick) {
        var pick = MPVPendingSubtitlePick(originalURL: url)
        var outcomes: [MPVPendingSubtitlePick.Outcome] = []
        for e in events { if let o = pick.handle(e) { outcomes.append(o) } }
        return (outcomes, pick)
    }

    func testEveryEventOrderResolvesExactlyOnce() {
        let added = E.trackAppeared(originalURL: url, trackID: 7)
        let failed = E.sideLoadFailed(originalURL: url)
        let listed = E.searchEnded(urls: [url, "other"])
        let missing = E.searchEnded(urls: ["other"])
        let cases: [([E], MPVPendingSubtitlePick.Outcome)] = [
            ([added], .select(trackID: 7)),
            ([listed, added], .select(trackID: 7)),
            ([added, .deadline], .select(trackID: 7)),          // added before the deadline
            ([.deadline, added], .fallbackAuto(.deadline)),      // added after it
            ([listed, failed], .fallbackAuto(.failed)),
            ([missing, added], .fallbackAuto(.missing)),
            ([.userPicked, added], .dropped),                    // user pick first
            ([added, .userPicked], .select(trackID: 7)),         // user pick last: already resolved
            ([listed, .userPicked], .dropped),
            ([listed, .deadline], .fallbackAuto(.deadline)),
        ]
        for (events, expected) in cases {
            let r = run(events)
            XCTAssertEqual(r.outcomes, [expected], "\(events)")
            XCTAssertFalse(r.pick.isPending)
        }
    }

    func testOtherURLsAndDuplicatesChangeNothing() {
        var pick = MPVPendingSubtitlePick(originalURL: url)
        XCTAssertNil(pick.handle(.trackAppeared(originalURL: "other", trackID: 3)))
        XCTAssertNil(pick.handle(.sideLoadFailed(originalURL: "other")))
        XCTAssertNil(pick.handle(.searchEnded(urls: [url])))
        XCTAssertTrue(pick.isPending)
        XCTAssertEqual(pick.handle(.trackAppeared(originalURL: url, trackID: 5)), .select(trackID: 5))
        XCTAssertNil(pick.handle(.trackAppeared(originalURL: url, trackID: 9)), "a duplicate never re-selects")
        XCTAssertNil(pick.handle(.deadline))
        XCTAssertEqual(pick.outcome, .select(trackID: 5))
    }

    /// The credential path hands mpv a local file: the job keeps the add-on URL as `original`.
    func testACredentialPathLocalFileIsMatchedByItsOriginalURL() {
        let job = MPVSubtitleSideLoadQueue.Job(source: "/tmp/mpv-sub-1.srt", title: "t", lang: "en", rank: 0, originalSource: url)
        XCTAssertEqual(job.original, url)
        let plain = MPVSubtitleSideLoadQueue.Job(source: url, title: "t", lang: "en", rank: nil)
        XCTAssertEqual(plain.original, url)
        var pick = MPVPendingSubtitlePick(originalURL: url)
        XCTAssertEqual(pick.handle(.trackAppeared(originalURL: job.original, trackID: 4)), .select(trackID: 4))
    }

    func testOutcomeLogTokensCarryNoURL() {
        for o: MPVPendingSubtitlePick.Outcome in [.select(trackID: 7), .fallbackAuto(.missing), .fallbackAuto(.deadline), .dropped] {
            XCTAssertFalse(o.logToken.contains("http"))
        }
    }
}

final class MPVTeardownStopTests: XCTestCase {
    private typealias A = MPVTeardownStop.Action

    private func latch(_ d: MPVTeardownStop.Disposition) -> MPVTeardownStop {
        var l = MPVTeardownStop()
        l.prepare(d)
        return l
    }

    /// Disposition × call order → exactly one or zero stops, and the position used.
    func testDispositionTimesCallOrder() {
        let orders: [[MPVTeardownStop.Call]] = [[.viewDidDisappear, .deinitialize], [.deinitialize],
                                               [.viewDidDisappear, .viewDidDisappear], [.viewDidDisappear]]
        let dispositions: [(MPVTeardownStop.Disposition, A)] = [
            (.normal, .flushAndStop(atSec: 42)),
            (.replaced(positionSec: 1265.8), .flushAndStop(atSec: 1265.8)),
            (.discard, .none),
        ]
        for (d, expected) in dispositions {
            for order in orders {
                var l = latch(d)
                let actions = order.map { l.next($0, livePositionSec: 42, ownerValid: true) }
                XCTAssertEqual(actions.first, expected, "\(d) \(order)")
                XCTAssertTrue(actions.dropFirst().allSatisfy { $0 == .none }, "\(d) \(order): one stop at most")
            }
        }
    }

    /// r3-3: the held position, never the old clock advanced after the snapshot.
    func testAReplacedStopUsesTheHeldPositionWithTheClockAdvanced() {
        var l = latch(.replaced(positionSec: 100))
        XCTAssertEqual(l.next(.viewDidDisappear, livePositionSec: 103.7, ownerValid: true), .flushAndStop(atSec: 100))
    }

    /// r3-2: the identity flipped after `prepareForReplacement`, before `viewDidDisappear`.
    func testAnOwnerChangeBeforeTheWriteDiscards() {
        var l = latch(.replaced(positionSec: 100))
        XCTAssertEqual(l.next(.viewDidDisappear, livePositionSec: 100, ownerValid: false), .none)
        XCTAssertEqual(l.disposition, .discard)
        XCTAssertEqual(l.next(.deinitialize, livePositionSec: 100, ownerValid: true), .none, "final")
        l.prepare(.replaced(positionSec: 5))
        XCTAssertEqual(l.disposition, .discard, "a discard is final")
    }

    /// r3-1: cover → Replay → exit: one stop per tracking session.
    func testCoverThenReplayThenExitStopsOncePerSession() {
        var l = MPVTeardownStop()
        XCTAssertEqual(l.next(.viewDidDisappear, livePositionSec: 3600, ownerValid: true), .flushAndStop(atSec: 3600))  // cover
        l.beginSession()                                                                                                // Replay
        XCTAssertEqual(l.next(.viewDidDisappear, livePositionSec: 80, ownerValid: true), .flushAndStop(atSec: 80))      // exit
        XCTAssertEqual(l.next(.deinitialize, livePositionSec: 80, ownerValid: true), .none)
    }

    func testBeginSessionIsIgnoredOnceReplacedOrDiscarded() {
        for d: MPVTeardownStop.Disposition in [.replaced(positionSec: 9), .discard] {
            var l = latch(d)
            _ = l.next(.viewDidDisappear, livePositionSec: 1, ownerValid: true)
            l.beginSession()
            XCTAssertEqual(l.next(.deinitialize, livePositionSec: 1, ownerValid: true), .none, "\(d)")
        }
    }

    /// The normal path ignores the owner flag (pre-existing profile reads are out of scope).
    func testTheNormalPathIsNotGatedByTheOwner() {
        var l = MPVTeardownStop()
        XCTAssertEqual(l.next(.viewDidDisappear, livePositionSec: 7, ownerValid: false), .flushAndStop(atSec: 7))
    }
}

final class MPVCommandGateTests: XCTestCase {
    func testCommandTimesParkedTimesGeneration() {
        for command in MPVCommandGate.Command.allCases {
            for parked in [false, true] {
                for (issued, current) in [(0, 0), (3, 3), (2, 3), (4, 3)] {
                    let allowed = MPVCommandGate.allows(command, parked: parked, issuedGeneration: issued, currentGeneration: current)
                    XCTAssertEqual(allowed, !parked && issued == current, "\(command) parked=\(parked) \(issued)/\(current)")
                }
            }
        }
    }

    func testTheParkBoxBumpsTheGenerationAndRefusesOlderWork() {
        let box = MPVParkBox()
        let issued = box.generation
        XCTAssertTrue(box.allows(.unpause, issuedGeneration: issued))
        let g = box.park()
        XCTAssertEqual(g, issued + 1)
        XCTAssertTrue(box.parked)
        XCTAssertFalse(box.allows(.unpause, issuedGeneration: issued))
        XCTAssertFalse(box.allows(.seek, issuedGeneration: g), "parked refuses even current work")
        box.unpark()
        XCTAssertTrue(box.allows(.load, issuedGeneration: g))
        XCTAssertFalse(box.allows(.load, issuedGeneration: issued), "work from before the park stays stale")
    }
}

final class MPVReturnLandingTests: XCTestCase {

    func testConfirmedOnTheFirstLanding() {
        var l = MPVReturnLanding(targetSec: 1265.781)
        l.seekIssued(generation: 3)
        XCTAssertEqual(l.landed(generation: 3, atSec: 1265.78, durationAtIssue: 7000, durationNow: 7000),
                       .complete(.settled(landedSec: 1265.78)))
        XCTAssertFalse(l.isPending)
    }

    func testCorrectThenConfirmed() {
        var l = MPVReturnLanding(targetSec: 1265.781)
        l.seekIssued(generation: 3)
        XCTAssertEqual(l.landed(generation: 3, atSec: 1252.209, durationAtIssue: 7000, durationNow: 7000), .correct(toSec: 1265.781))
        XCTAssertTrue(l.isPending)
        l.seekIssued(generation: 4)
        XCTAssertEqual(l.landed(generation: 4, atSec: 1265.7, durationAtIssue: 7000, durationNow: 7000),
                       .complete(.settled(landedSec: 1265.7)))
    }

    /// r3-4: two misses → `offTarget` with the actual landing; no confirmed settle.
    func testTwoMissesCompleteOffTarget() {
        var l = MPVReturnLanding(targetSec: 1265.781)
        l.seekIssued(generation: 3)
        _ = l.landed(generation: 3, atSec: 1252.209, durationAtIssue: 7000, durationNow: 7000)
        l.seekIssued(generation: 4)
        XCTAssertEqual(l.landed(generation: 4, atSec: 1252.3, durationAtIssue: 7000, durationNow: 7000),
                       .complete(.offTarget(landedSec: 1252.3)))
        XCTAssertEqual(l.completion, .offTarget(landedSec: 1252.3))
        l.seekIssued(generation: 5)
        XCTAssertEqual(l.landed(generation: 5, atSec: 1265.78, durationAtIssue: 7000, durationNow: 7000), .none, "one completion only")
    }

    func testAnUnreadSecondLandingKeepsTheFirst() {
        var l = MPVReturnLanding(targetSec: 100)
        l.seekIssued(generation: 1)
        _ = l.landed(generation: 1, atSec: 90, durationAtIssue: 7000, durationNow: 7000)
        l.seekIssued(generation: 2)
        XCTAssertEqual(l.landed(generation: 2, atSec: .nan, durationAtIssue: 7000, durationNow: 7000),
                       .complete(.offTarget(landedSec: 90)))
    }

    func testAnInvalidTargetCompletesOffTargetAtOnce() {
        var l = MPVReturnLanding(targetSec: -3)
        l.seekIssued(generation: 1)
        XCTAssertEqual(l.landed(generation: 1, atSec: 0, durationAtIssue: nil, durationNow: nil), .complete(.offTarget(landedSec: 0)))
    }

    func testARejectedCorrectiveSeekIsTheSecondMiss() {
        var l = MPVReturnLanding(targetSec: 100)
        l.seekIssued(generation: 1)
        _ = l.landed(generation: 1, atSec: 80, durationAtIssue: 7000, durationNow: 7000)
        l.seekIssued(generation: 2)
        XCTAssertEqual(l.seekRejected(generation: 1), .none, "stale")
        XCTAssertEqual(l.seekRejected(generation: 2), .complete(.offTarget(landedSec: 80)))
    }

    func testAStaleGenerationIsIgnored() {
        var l = MPVReturnLanding(targetSec: 100)
        l.seekIssued(generation: 2)
        XCTAssertEqual(l.landed(generation: 1, atSec: 100, durationAtIssue: nil, durationNow: nil), .none)
        XCTAssertTrue(l.isPending)
        XCTAssertEqual(l.landed(generation: 2, atSec: 100, durationAtIssue: nil, durationNow: nil), .complete(.settled(landedSec: 100)))
    }
}

@MainActor
final class DisplayCriteriaLeaseTests: XCTestCase {
    private var writes: [Bool] = []   // true = criteria set, false = cleared

    private func lease() -> DisplayCriteriaLease {
        DisplayCriteriaLease { [unowned self] _, criteria in self.writes.append(criteria != nil) }
    }

    private var criteria: AVDisplayCriteria {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264, width: 1920,
                                       height: 1080, extensions: nil, formatDescriptionOut: &fd)
        return AVDisplayCriteria(refreshRate: 24, formatDescription: fd!)
    }

    func testOnlyTheOwnerClears() {
        let l = lease()
        l.apply(criteria, window: UIWindow(), token: 1)
        XCTAssertFalse(l.clear(token: 2))
        XCTAssertTrue(l.holdsCriteria)
        XCTAssertTrue(l.clear(token: 1))
        XCTAssertFalse(l.holdsCriteria)
        XCTAssertEqual(writes, [true, false])
    }

    /// Replacement: after the transfer the old controller's clear does nothing; the fresh one owns it.
    func testATransferMovesOwnershipWithoutASwitch() {
        let l = lease()
        let window = UIWindow()
        l.apply(criteria, window: window, token: 4)
        l.transfer(to: 5)
        XCTAssertFalse(l.clear(token: 4), "the old controller's teardown")
        XCTAssertTrue(l.holdsCriteria)
        XCTAssertEqual(writes, [true], "no write at the transfer: the TV does not switch")
        XCTAssertTrue(l.clear(token: 5))
        XCTAssertEqual(writes, [true, false])
    }

    /// The fresh controller exits before it applied anything (failure or Menu before FILE_LOADED).
    func testAnExitWithNoSuccessorClearsWhatTheOldOneApplied() {
        let l = lease()
        l.apply(criteria, window: UIWindow(), token: 4)
        l.transfer(to: 5)
        l.clearAll()
        XCTAssertFalse(l.holdsCriteria)
        XCTAssertNil(l.owner)
        XCTAssertEqual(writes, [true, false])
    }

    func testATransferWithNothingAppliedOwnsNothing() {
        let l = lease()
        l.transfer(to: 5)
        XCTAssertNil(l.owner)
        XCTAssertFalse(l.clear(token: 5))
        l.clearAll()
        XCTAssertEqual(writes, [])
    }
}

/// spec-mpv-return §5.2, the part with no controller: the gate read on a real serial queue. A block
/// issued before the park and executed after it is refused; one issued after an unpark (kept
/// controller) runs; the park itself never waits on the queue.
final class MPVParkBoxQueueTests: XCTestCase {
    func testWorkQueuedBeforeTheParkIsRefusedAtExecution() {
        let box = MPVParkBox()
        let queue = DispatchQueue(label: "mpv-events-test")
        let hold = DispatchSemaphore(value: 0)
        let done = expectation(description: "drained")
        var executed: [String] = []
        queue.async { hold.wait() }                       // the queue is busy (a stuck command)
        for command in [MPVCommandGate.Command.load, .unpause, .seek] {
            let issued = box.generation
            queue.async {
                dispatchPrecondition(condition: .onQueue(queue))
                if box.allows(command, issuedGeneration: issued) { executed.append(command.rawValue) }
            }
        }
        let started = Date()
        let g = box.park()                                // main: never waits on the busy queue
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        hold.signal()
        queue.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(executed, [], "reconnect, toggle and seek issued before the park are refused")
        box.unpark()
        let after = expectation(description: "after unpark")
        queue.async {
            if box.allows(.unpause, issuedGeneration: g) { executed.append("unpause") }
            after.fulfill()
        }
        wait(for: [after], timeout: 2)
        XCTAssertEqual(executed, ["unpause"])
    }
}

/// Code review W7 r1 (findings 1-3): every app seek's outcome around a return, as one decision. Each
/// row is a sequence of issues and results; the oracle is that nothing outlives its seek.
final class MPVReturnSeeksTests: XCTestCase {
    private typealias S = MPVReturnSeeks
    private typealias O = MPVReturnSeeks.Outcome

    private func returnStart(target: Double = 100) -> S {
        var s = S()
        s.beginReturnLanding(targetSec: target, durationAtIssue: 7000)
        XCTAssertEqual(s.issued(.resume, generation: 1, targetSec: target), O())
        XCTAssertTrue(s.landingPending)
        return s
    }

    private func outcome(correct: Double? = nil, _ c: MPVReturnLanding.Completion? = nil, rejected: Bool = false) -> O {
        O(correctToSec: correct, completion: c, startupResumeRejected: rejected)
    }

    func testTheTable() {
        struct Row { let name: String; let run: (inout S) -> [O]; let expected: [O]; let pending: Bool; let inFlight: S.Seek? }
        let rows: [Row] = [
            Row(name: "resume lands on target",
                run: { s in [s.finished(generation: 1, result: .landed(atSec: 100), durationNow: 7000)] },
                expected: [outcome(.settled(landedSec: 100))], pending: false, inFlight: nil),
            Row(name: "resume misses, correction lands",
                run: { s in [s.finished(generation: 1, result: .landed(atSec: 90), durationNow: 7000),
                             s.issued(.correction, generation: 2, targetSec: 100),
                             s.finished(generation: 2, result: .landed(atSec: 100), durationNow: 7000)] },
                expected: [outcome(correct: 100), O(), outcome(.settled(landedSec: 100))], pending: false, inFlight: nil),
            Row(name: "two misses: offTarget",
                run: { s in [s.finished(generation: 1, result: .landed(atSec: 90), durationNow: 7000),
                             s.issued(.correction, generation: 2, targetSec: 100),
                             s.finished(generation: 2, result: .landed(atSec: 91), durationNow: 7000)] },
                expected: [outcome(correct: 100), O(), outcome(.offTarget(landedSec: 91))], pending: false, inFlight: nil),
            // Finding 1: the viewer's seek supersedes the resume; the resume never reports.
            Row(name: "viewer seek supersedes the resume",
                run: { s in [s.issued(.viewer, generation: 2, targetSec: 300),
                             s.finished(generation: 2, result: .landed(atSec: 300), durationNow: 7000)] },
                expected: [outcome(.cancelled(bySeekGeneration: 2)), O()], pending: false, inFlight: nil),
            Row(name: "viewer seek supersedes the correction",
                run: { s in [s.finished(generation: 1, result: .landed(atSec: 90), durationNow: 7000),
                             s.issued(.correction, generation: 2, targetSec: 100),
                             s.issued(.viewer, generation: 3, targetSec: nil),
                             s.finished(generation: 2, result: .landed(atSec: 100), durationNow: 7000)] },
                expected: [outcome(correct: 100), O(), outcome(.cancelled(bySeekGeneration: 3)), O()], pending: false, inFlight: nil),
            // Finding 2: a rejected resume (paused start): offTarget and the start completes.
            Row(name: "resume rejected while paused",
                run: { s in [s.finished(generation: 1, result: .rejected, durationNow: 7000)] },
                expected: [outcome(.offTarget(landedSec: nil), rejected: true)], pending: false, inFlight: nil),
            Row(name: "correction rejected",
                run: { s in [s.finished(generation: 1, result: .landed(atSec: 90), durationNow: 7000),
                             s.issued(.correction, generation: 2, targetSec: 100),
                             s.finished(generation: 2, result: .rejected, durationNow: 7000)] },
                expected: [outcome(correct: 100), O(), outcome(.offTarget(landedSec: 90))], pending: false, inFlight: nil),
            Row(name: "stale rejection ignored",
                run: { s in [s.finished(generation: 0, result: .rejected, durationNow: 7000)] },
                expected: [O()], pending: true, inFlight: S.Seek(generation: 1, targetSec: 100)),
            Row(name: "stale landing ignored",
                run: { s in [s.finished(generation: 7, result: .landed(atSec: 100), durationNow: 7000)] },
                expected: [O()], pending: true, inFlight: S.Seek(generation: 1, targetSec: 100)),
            Row(name: "resume rejected after a viewer seek superseded it: the viewer's restart starts it",
                run: { s in [s.issued(.viewer, generation: 2, targetSec: 50),
                             s.finished(generation: 1, result: .rejected, durationNow: 7000)] },
                expected: [outcome(.cancelled(bySeekGeneration: 2)), O()], pending: false, inFlight: S.Seek(generation: 2, targetSec: 50)),
        ]
        for row in rows {
            var s = returnStart()
            XCTAssertEqual(row.run(&s), row.expected, row.name)
            XCTAssertEqual(s.landingPending, row.pending, row.name)
            XCTAssertEqual(s.inFlight, row.inFlight, row.name)
        }
    }

    /// Finding 3: a rejected viewer seek is not the next background's held target.
    func testAViewerSeekRejectedThenBackground() {
        var s = S()
        _ = s.issued(.viewer, generation: 4, targetSec: 900)
        XCTAssertEqual(s.inFlight, S.Seek(generation: 4, targetSec: 900))
        _ = s.finished(generation: 4, result: .rejected, durationNow: 7000)
        XCTAssertNil(s.inFlight)
        XCTAssertEqual(MPVReturnPlan.start(isLive: false, started: true, positionSec: 120,
                                           seekInFlightTargetSec: s.inFlight?.targetSec, ownReturnStart: nil,
                                           resumeTargetSec: nil), .position(120))
        // An older seek's rejection never clears a newer one.
        _ = s.issued(.viewer, generation: 5, targetSec: 30)
        _ = s.issued(.viewer, generation: 6, targetSec: 40)
        _ = s.finished(generation: 5, result: .rejected, durationNow: nil)
        XCTAssertEqual(s.inFlight, S.Seek(generation: 6, targetSec: 40))
    }

    /// A normal start (no return landing): a rejected resume still completes the start; viewer seeks
    /// never touch a landing that does not exist.
    func testANormalStartsRejectedResumeCompletesTheStart() {
        var s = S()
        _ = s.issued(.resume, generation: 1, targetSec: 600)
        XCTAssertEqual(s.finished(generation: 1, result: .rejected, durationNow: nil), outcome(rejected: true))
        XCTAssertEqual(s.finished(generation: 1, result: .rejected, durationNow: nil), O(), "once")
        XCTAssertEqual(s.issued(.viewer, generation: 2, targetSec: 10), O())
        XCTAssertFalse(s.landingPending)
    }

    /// Exhaustive: for every sequence of up to three steps after the return's resume, the landing is
    /// never pending once its seek ended or was superseded, and at most one completion is reported.
    func testNoLandingOutlivesItsSeek() {
        enum Step: CaseIterable { case viewer, landOn, landOff, reject, staleLand, staleReject }
        func gen(_ s: S) -> Int { s.latestGeneration }
        for a in Step.allCases { for b in Step.allCases { for c in Step.allCases {
            var s = returnStart()
            var completions = 0
            var pendingSeek = 1   // generation the landing waits on, nil when none
            var waiting: Int? = pendingSeek
            for step in [a, b, c] {
                var out = O()
                switch step {
                case .viewer: out = s.issued(.viewer, generation: gen(s) + 1, targetSec: 5); waiting = nil
                case .landOn: out = s.finished(generation: gen(s), result: .landed(atSec: 100), durationNow: 7000)
                case .landOff: out = s.finished(generation: gen(s), result: .landed(atSec: 50), durationNow: 7000)
                case .reject: out = s.finished(generation: gen(s), result: .rejected, durationNow: 7000)
                case .staleLand: out = s.finished(generation: gen(s) - 1, result: .landed(atSec: 100), durationNow: 7000)
                case .staleReject: out = s.finished(generation: gen(s) - 1, result: .rejected, durationNow: 7000)
                }
                if let t = out.correctToSec {
                    pendingSeek = gen(s) + 1
                    _ = s.issued(.correction, generation: pendingSeek, targetSec: t)
                    waiting = pendingSeek
                } else if [.landOn, .landOff, .reject].contains(step) { waiting = nil }
                if out.completion != nil { completions += 1 }
                if s.landingPending { XCTAssertNotNil(waiting, "\(a) \(b) \(c): pending with no seek of its own") }
            }
            XCTAssertLessThanOrEqual(completions, 1, "\(a) \(b) \(c)")
        } } }
    }
}

final class MPVStartupResumeRejectedTests: XCTestCase {
    func testARejectedResumeCompletesAPausedStart() {
        var r = MPVStartupStageReducer()
        XCTAssertFalse(r.resumeSeekRejected(), "nothing before FILE_LOADED")
        r.fileLoaded(resumeGeneration: 3)
        XCTAssertFalse(r.tick(positionSec: 100, paused: true))
        XCTAssertFalse(r.tick(positionSec: 100, paused: true), "a paused start never trips the backstop")
        XCTAssertTrue(r.resumeSeekRejected())
        XCTAssertTrue(r.started)
        var none = MPVStartupStageReducer()
        none.fileLoaded(resumeGeneration: nil)
        XCTAssertFalse(none.resumeSeekRejected(), "no resume seek, nothing to complete")
    }
}
