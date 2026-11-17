import Combine
import XCTest
@testable import NuvioTV
import SharedCore

/// W4 review r1–r3: `PlayerChoiceLedger` (`Screens/Player/PlayerChoiceLedger.swift`), the type
/// `StreamPickerView` keeps in `@State` and calls from every handler, and the single owner of an
/// unhandled failure of the source on screen. Each case is an event sequence in the order the view
/// sends them; the walk cases run the real `FirstPlayAutoPlayController` the view drives.
@MainActor
final class PlayerChoiceLedgerTests: XCTestCase {

    private func failure(started: Bool = false) -> PlaybackFailure {
        PlaybackFailure(reason: "mpv: loading failed", positionSec: started ? 120 : 0,
                        secondsPlayed: started ? 120 : 0, startedPlaying: started, kind: .http)
    }

    private func context(_ name: String, launch: PlaybackLaunchSource = .nextEpisode) -> PlaybackContext {
        var ctx = PlaybackContext(
            url: URL(string: "https://cdn.example.com/\(name).mkv")!, title: name, contentType: "series",
            parentMetaId: "tt1", videoId: "tt1:1:2", season: 1, episode: 2, poster: nil, background: nil,
            providerName: nil, providerAddonId: nil, streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
        ctx.launchSource = launch
        return ctx
    }

    private func stream(_ name: String, direct: Bool = false) -> StreamItem {
        StreamItem(
            name: name, title: nil, description: nil,
            url: direct ? "https://cdn.example.com/\(name).mkv" : nil,
            infoHash: direct ? nil : "hash-\(name)", fileIdx: nil, externalUrl: nil, ytId: nil, sources: [],
            sourceName: nil, addonName: "Add-on", addonId: "addon:a", addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: [], debridResolved: false
        )
    }

    /// A walk whose resolves wait until `release()`.
    private final class World {
        var events: [FirstPlayAutoPlayController.Event] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        var cancellables: Set<AnyCancellable> = []
        var resolveCalls: [String] = []
        var freshCalls: [String] = []
        func release() { let w = waiters; waiters = []; w.forEach { $0.resume() } }
        var played: [(String, Int)] {
            events.compactMap { if case let .play(c, _, _, a, _) = $0 { return (c.stream.name ?? "", a) }; return nil }
        }
    }

    private func makeWalk(_ world: World, maxAttempts: Int = 4) -> FirstPlayAutoPlayController {
        var deps = FirstPlayAutoPlayController.Dependencies(
            expectedToken: { "t" }, consumeAutoPlay: {}, cachedOnly: { false }, isCachedDebridLink: { _ in false },
            rejected: { _ in [] }, reject: { _, _ in }, invalidate: { _ in },
            directURL: { stream in let u: String? = stream.url; return u.flatMap(URL.init(string:)) },
            canResolve: { _ in true },
            resolve: { stream in
                world.resolveCalls.append(stream.name ?? "")
                await withCheckedContinuation { world.waiters.append($0) }
                return .playable(stream, URL(string: "https://resolved.example/\(stream.name ?? "")")!)
            },
            resolveDeadline: 5, searchDeadline: 30)
        deps.maxAttempts = { maxAttempts }
        deps.now = { 10_000 }
        deps.resolveFresh = { stream in
            world.freshCalls.append(stream.name ?? "")
            await withCheckedContinuation { world.waiters.append($0) }
            return .failed(reason: "not cached", rejectsLink: true)
        }
        let walk = FirstPlayAutoPlayController(titleKey: "tt1:1:2", dependencies: deps)
        walk.events.sink { world.events.append($0) }.store(in: &world.cancellables)
        return walk
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: - (1) Episode fails → candidate load in flight → viewer pick → abandoned / succeeds

    /// Review r3 finding 1: the failure is the ledger's from arrival, so a pick made while the
    /// episode walk's candidates load holds it, and the pick's abandon hands it back.
    func testAFailureWhoseCandidatesAreLoadingIsHeldAndRoutedWhenThePickIsAbandoned() {
        var ledger = PlayerChoiceLedger()
        let failing = context("e2-first")
        let f = failure()
        XCTAssertEqual(ledger.failureArrived(context: failing, failure: f, rejectionDeferred: false), .route)
        ledger.walkStarted(.episode)                              // startEpisodeFallback: the load starts
        let loadTicket = ledger.gate.ticket
        let pick = UUID()
        ledger.choiceBegan(pick)                                  // a Sources pick while the load runs
        XCTAssertTrue(ledger.failureHeld)
        XCTAssertFalse(ledger.accepts(loadTicket), "the load's result is dropped when it lands")
        let routed = ledger.choiceAbandoned(pick)                 // the pick's resolve failed
        XCTAssertEqual(routed?.contextId, failing.id)
        XCTAssertEqual(routed?.failure, f, "routed again by the normal rules")
        XCTAssertFalse(ledger.failureHeld)
        XCTAssertNotNil(ledger.openFailure, "still open until its handling ends")
    }

    func testTheSameFailureIsDroppedWhenThePickReachesTheScreen() {
        var ledger = PlayerChoiceLedger()
        let failing = context("e2-first")
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: false)
        let pick = UUID()
        ledger.choiceBegan(pick)
        XCTAssertNil(ledger.contextPresented("ctx-picked"), "no deferred rejection to apply")
        XCTAssertNil(ledger.openFailure)
        XCTAssertNil(ledger.choiceAbandoned(pick))
    }

    /// A routed failure closes on its terminal outcome; a late abandon then has nothing to route.
    func testAHandledFailureLeavesNothingToRoute() {
        var ledger = PlayerChoiceLedger()
        let failing = context("e2-first")
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: false)
        XCTAssertNil(ledger.failureHandled(contextId: failing.id, rejectionSettled: true))
        let pick = UUID()
        ledger.choiceBegan(pick)
        XCTAssertNil(ledger.choiceAbandoned(pick))
        XCTAssertNil(ledger.failureHandled(contextId: "other", rejectionSettled: false))
    }

    /// Default settings, a manual source: the abandoned pick leaves the next failure routed.
    func testAnAbandonedChoiceLeavesTheNextFailureRouted() {
        var ledger = PlayerChoiceLedger()
        let pick = UUID()
        ledger.choiceBegan(pick)
        XCTAssertNil(ledger.choiceAbandoned(pick))
        XCTAssertTrue(ledger.allowsAutomaticStart)
        XCTAssertEqual(ledger.failureArrived(context: context("m", launch: .manual), failure: failure(started: true),
                                             rejectionDeferred: false), .route)
    }

    /// A failure that arrives while the pick is pending is held, then routed on the abandon.
    func testAFailureDuringAPendingChoiceIsHeldThenRouted() {
        var ledger = PlayerChoiceLedger()
        let pick = UUID()
        ledger.choiceBegan(pick)
        let playing = context("playing", launch: .manual)
        XCTAssertEqual(ledger.failureArrived(context: playing, failure: failure(started: true), rejectionDeferred: false), .hold)
        XCTAssertEqual(ledger.choiceAbandoned(pick)?.contextId, playing.id)
    }

    // MARK: - (2) Failover resolving candidate #2 → pick → abandoned → #2 is tried next, budget intact

    func testAnInterruptedFailoverGivesBackItsUntriedCandidateAndAttempt() async {
        let world = World()
        let walk = makeWalk(world, maxAttempts: 2)            // Sources to Try 1
        walk.seed(candidates: [stream("B"), stream("C")], alreadyTried: PlayerSourceFallbackTried.companion.None,
                  playing: stream("A", direct: true))
        var ledger = PlayerChoiceLedger()
        let failing = context("A", launch: .autoPlay)
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: false)
        ledger.walkStarted(.autoFailover)
        XCTAssertTrue(walk.failover(afterFailureOf: stream("A", direct: true).playbackStreamKey, addonId: nil))
        await waitUntil { world.waiters.count == 1 }
        XCTAssertEqual(walk.attemptsUsed, 2)

        let pick = UUID()
        ledger.choiceBegan(pick)
        walk.abandonFailover()                                 // interruptWalks
        XCTAssertEqual(walk.attemptsUsed, 1, "the budget B consumed is returned")
        XCTAssertFalse(walk.fallbackTried.contains(stream: stream("B")), "B never started: untried again")
        world.release()                                        // B's dropped resolve lands
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(world.events.isEmpty)

        let routed = try? XCTUnwrap(ledger.choiceAbandoned(pick))
        XCTAssertEqual(routed?.contextId, failing.id)
        ledger.walkStarted(.autoFailover)                     // routeFailure → .autoFailover
        XCTAssertTrue(walk.failover(afterFailureOf: stream("A", direct: true).playbackStreamKey, addonId: nil))
        await waitUntil { world.waiters.count == 1 }
        XCTAssertEqual(world.resolveCalls, ["B", "B"], "B is tried next, within the budget")
        world.release()
        await waitUntil { !world.played.isEmpty }
        XCTAssertEqual(world.played.first?.0, "B")
        XCTAssertEqual(world.played.first?.1, 2)
        XCTAssertTrue(ledger.admitsSwap(.autoFailover, replacing: failing.id, presented: failing.id))
        XCTAssertNil(ledger.failureHandled(contextId: failing.id, rejectionSettled: true))
        XCTAssertNil(ledger.openFailure)
    }

    /// A candidate whose resolve really answered stays tried (only the dropped one goes back).
    func testAResolvedCandidateIsNotGivenBack() async {
        let world = World()
        let walk = makeWalk(world)
        walk.seed(candidates: [stream("B")], alreadyTried: PlayerSourceFallbackTried.companion.None,
                  playing: stream("A", direct: true))
        _ = walk.failover(afterFailureOf: stream("A", direct: true).playbackStreamKey, addonId: nil)
        await waitUntil { world.waiters.count == 1 }
        world.release()
        await waitUntil { !world.played.isEmpty }
        walk.abandonFailover()                                 // nothing resolving: a no-op
        XCTAssertTrue(walk.fallbackTried.contains(stream: stream("B")))
        XCTAssertEqual(walk.attemptsUsed, 2)
    }

    // MARK: - (3) Deferred link rejection

    /// A refresh in flight is interrupted; the re-route finds that no refresh will run (the link was
    /// refreshed once already), so the rejection is applied then.
    func testAnInterruptedRefreshStillGetsItsLinkRejected() async {
        let world = World()
        let walk = makeWalk(world)
        let d1 = stream("D1")
        walk.seed(candidates: [d1, stream("E")], alreadyTried: PlayerSourceFallbackTried.companion.None, playing: d1)
        var ledger = PlayerChoiceLedger()
        let failing = context("D1", launch: .autoPlay)
        let candidate = FirstPlayAutoPlayController.Candidate(stream: d1)
        XCTAssertTrue(walk.willRefreshBeforeMovingOn(streamKey: candidate.streamKey))
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: true)
        XCTAssertNil(ledger.refreshDecided(willRefresh: true), "the refresh runs: still deferred")
        ledger.walkStarted(.autoFailover)
        _ = walk.failover(afterFailureOf: candidate.streamKey, addonId: nil, refreshFirst: candidate,
                          failedURL: URL(string: "https://resolved.example/D1"))
        await waitUntil { world.freshCalls == ["D1"] }

        let pick = UUID()
        ledger.choiceBegan(pick)
        walk.abandonFailover()
        let routed = ledger.choiceAbandoned(pick)
        XCTAssertNotNil(routed)
        XCTAssertFalse(walk.willRefreshBeforeMovingOn(streamKey: candidate.streamKey), "refreshed once already")
        let apply = ledger.refreshDecided(willRefresh: false)
        XCTAssertEqual(apply?.contextId, failing.id, "the deferred rejection is applied now")
        XCTAssertNil(ledger.refreshDecided(willRefresh: false), "once")
        world.release()
    }

    /// The held failure is dropped because the viewer's pick reached the screen: the rejection is
    /// still applied.
    func testADroppedFailureStillGetsItsDeferredRejection() {
        var ledger = PlayerChoiceLedger()
        let failing = context("D1", launch: .autoPlay)
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: true)
        ledger.choiceBegan(UUID())
        XCTAssertEqual(ledger.contextPresented("ctx-picked")?.contextId, failing.id)
        XCTAssertNil(ledger.openFailure)
    }

    /// A walk that gave up (or any close that did not swap in a replacement) applies it too; a swap
    /// does not (the refresh helped, or the walk remembered the link itself).
    func testOnlyASwapSettlesADeferredRejection() {
        var ledger = PlayerChoiceLedger()
        let failing = context("D1", launch: .autoPlay)
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: true)
        XCTAssertNil(ledger.failureHandled(contextId: failing.id, rejectionSettled: true))
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: true)
        XCTAssertEqual(ledger.failureHandled(contextId: failing.id, rejectionSettled: false)?.contextId, failing.id)
    }

    /// A second report of the same context keeps a deferral the first one made.
    func testASecondReportKeepsTheDeferral() {
        var ledger = PlayerChoiceLedger()
        let failing = context("D1", launch: .autoPlay)
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: true)
        _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: false)
        XCTAssertEqual(ledger.openFailure?.rejectionDeferred, true)
    }

    // MARK: - (4) Cancellation and the player going away mid-step

    /// Menu (the cover's setter) and the screen change it causes, during each phase: nothing held,
    /// nothing open, no walk ticket left; the deferred rejection is applied on the way out.
    func testThePlayerClosingMidStepLeavesNothingBehind() {
        for deferred in [false, true] {
            var ledger = PlayerChoiceLedger()
            let failing = context("x", launch: .autoPlay)
            _ = ledger.failureArrived(context: failing, failure: failure(), rejectionDeferred: deferred)
            ledger.walkStarted(.autoFailover)
            ledger.walkStarted(.episode)
            ledger.viewerActed()                                  // Menu
            let dropped = ledger.contextPresented(nil)            // selected = nil
            XCTAssertEqual(dropped != nil, deferred)
            XCTAssertNil(ledger.openFailure)
            XCTAssertFalse(ledger.failureHeld)
            XCTAssertFalse(ledger.choicePending)
            XCTAssertFalse(ledger.admitsSwap(.autoFailover, replacing: failing.id, presented: failing.id))
            XCTAssertFalse(ledger.admitsGiveUp(.episode))
        }
    }

    /// The same with a choice pending and the failure held.
    func testThePlayerClosingWithAHeldFailureLeavesNothingBehind() {
        var ledger = PlayerChoiceLedger()
        let pick = UUID()
        ledger.choiceBegan(pick)
        _ = ledger.failureArrived(context: context("x"), failure: failure(), rejectionDeferred: false)
        ledger.viewerActed()
        ledger.contextPresented(nil)
        XCTAssertNil(ledger.openFailure)
        XCTAssertNil(ledger.choiceAbandoned(pick), "the engine's stop() abandon changes nothing")
    }

    /// The controller's own exits: cancelled while a pick resolves (the player closed), and while a
    /// refresh runs: the late answer never plays, and no walk is left resolving.
    func testCancellingAWalkMidStepLeavesNoLiveWalk() async {
        let world = World()
        let walk = makeWalk(world)
        let d1 = stream("D1")
        walk.seed(candidates: [stream("B")], alreadyTried: PlayerSourceFallbackTried.companion.None, playing: d1)
        _ = walk.failover(afterFailureOf: d1.playbackStreamKey, addonId: nil)
        await waitUntil { world.waiters.count == 1 }
        walk.cancel(why: "player closed")
        XCTAssertEqual(walk.phase, .cancelled)
        world.release()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(world.events.isEmpty)

        let world2 = World()
        let walk2 = makeWalk(world2)
        walk2.seed(candidates: [stream("E")], alreadyTried: PlayerSourceFallbackTried.companion.None, playing: d1)
        let candidate = FirstPlayAutoPlayController.Candidate(stream: d1)
        _ = walk2.failover(afterFailureOf: candidate.streamKey, addonId: nil, refreshFirst: candidate,
                           failedURL: URL(string: "https://resolved.example/D1"))
        await waitUntil { world2.freshCalls == ["D1"] }
        walk2.cancel(why: "player closed")
        world2.release()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(world2.events.isEmpty)
        XCTAssertEqual(walk2.phase, .cancelled)
    }

    // MARK: - Choices

    func testOnlyTheNewestChoiceEndsPending() {
        var ledger = PlayerChoiceLedger()
        let first = UUID(), second = UUID()
        ledger.choiceBegan(first)
        _ = ledger.failureArrived(context: context("x"), failure: failure(), rejectionDeferred: false)
        ledger.choiceBegan(second)
        XCTAssertNil(ledger.choiceAbandoned(first), "superseded")
        XCTAssertTrue(ledger.choicePending)
        XCTAssertNotNil(ledger.choiceAbandoned(second))
        XCTAssertFalse(ledger.choicePending)
    }

    func testAChoiceStalesEveryEarlierWalkTicket() {
        var ledger = PlayerChoiceLedger()
        ledger.walkStarted(.autoFailover)
        XCTAssertTrue(ledger.admitsGiveUp(.autoFailover))
        ledger.choiceBegan(UUID())
        ledger.contextPresented("ctx-picked")
        XCTAssertFalse(ledger.admitsGiveUp(.autoFailover), "a give-up after the pick started closes nothing")
        let before = ledger.gate.ticket
        ledger.viewerActed()
        XCTAssertFalse(ledger.accepts(before))
        XCTAssertTrue(ledger.allowsAutomaticStart)
    }

    func testADuplicateReportKeepsTheWalkTicket() {
        var ledger = PlayerChoiceLedger()
        ledger.walkStarted(.autoFailover)
        let ticket = ledger.ticket(.autoFailover)
        ledger.walkStarted(.autoFailover, keepTicket: true)
        XCTAssertEqual(ledger.ticket(.autoFailover), ticket)
    }

    func testTheGateStalesTicketsAndBlocksWalksWhilePending() {
        var gate = AutoWalkIntentGate()
        let ticket = gate.ticket
        gate.viewerChose()
        XCTAssertFalse(gate.accepts(ticket))
        XCTAssertFalse(gate.allowsAutomaticWalk)
        gate.contextPresented()
        XCTAssertTrue(gate.allowsAutomaticWalk)
        XCTAssertFalse(gate.admitsSwap(ticket: gate.ticket, replacing: "a", presented: "b"))
        XCTAssertTrue(gate.admitsSwap(ticket: gate.ticket, replacing: nil, presented: "b"))
        XCTAssertFalse(gate.accepts(nil))
    }

    // MARK: - Stage B review finding 3: a start-up limit during a pending choice

    func testAStartupLimitDuringAPendingChoiceIsReplayedWhenTheChoiceIsAbandoned() {
        var ledger = PlayerChoiceLedger()
        let slow = context("slow", launch: .autoPlay)
        XCTAssertEqual(ledger.startupLimitReached(contextId: slow.id), .route, "nothing pending: routed")
        let pick = UUID()
        ledger.choiceBegan(pick)
        XCTAssertEqual(ledger.startupLimitReached(contextId: slow.id), .hold)
        let replay = ledger.choiceAbandoned(pick)
        guard case let .startupLimit(id)? = replay else { return XCTFail("the held limit comes back") }
        XCTAssertEqual(id, slow.id)
        XCTAssertNil(ledger.openFailure, "slow is not failed: no failure was opened")
    }

    func testAStartupLimitDuringAPendingChoiceIsDroppedWhenTheChoiceTakesOver() {
        var ledger = PlayerChoiceLedger()
        let slow = context("slow", launch: .autoPlay)
        let pick = UUID()
        ledger.choiceBegan(pick)
        _ = ledger.startupLimitReached(contextId: slow.id)
        ledger.contextPresented("ctx-picked")
        XCTAssertNil(ledger.heldStartupLimit)
        XCTAssertNil(ledger.choiceAbandoned(pick))
    }

    func testAFailureSupersedesAHeldStartupLimit() {
        var ledger = PlayerChoiceLedger()
        let slow = context("slow", launch: .autoPlay)
        let pick = UUID()
        ledger.choiceBegan(pick)
        _ = ledger.startupLimitReached(contextId: slow.id)
        XCTAssertEqual(ledger.failureArrived(context: slow, failure: failure(), rejectionDeferred: false), .hold)
        guard case .failure? = ledger.choiceAbandoned(pick) else { return XCTFail("the failure is replayed, not the limit") }
        XCTAssertNil(ledger.heldStartupLimit)
    }

    func testAHeldStartupLimitIsVoidOnceTheSourceStarts() {
        var ledger = PlayerChoiceLedger()
        let slow = context("slow", launch: .autoPlay)
        let pick = UUID()
        ledger.choiceBegan(pick)
        _ = ledger.startupLimitReached(contextId: slow.id)
        ledger.sourceStarted(contextId: slow.id)
        XCTAssertNil(ledger.choiceAbandoned(pick), "a source that started has no limit to act on")
    }

    func testMenuDropsAHeldStartupLimit() {
        var ledger = PlayerChoiceLedger()
        ledger.choiceBegan(UUID())
        _ = ledger.startupLimitReached(contextId: "slow")
        ledger.viewerActed()
        XCTAssertNil(ledger.heldStartupLimit)
    }
}
