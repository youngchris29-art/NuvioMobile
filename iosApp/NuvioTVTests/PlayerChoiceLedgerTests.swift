import Combine
import XCTest
@testable import NuvioTV
import SharedCore

/// W4 review r1/r2: `PlayerChoiceLedger` (`Screens/Player/PlayerChoiceLedger.swift`), the type
/// `StreamPickerView` keeps in `@State` and calls from every handler (a viewer choice begun, taken
/// over or abandoned; a playback failure; the start-up limit; each walk's start, swap and give-up).
/// Each case is an event sequence in the order the view sends them; the walk cases run the real
/// `FirstPlayAutoPlayController` the view drives, against a fake resolver.
@MainActor
final class PlayerChoiceLedgerTests: XCTestCase {

    private func failure(started: Bool = false) -> PlaybackFailure {
        PlaybackFailure(reason: "mpv: loading failed", positionSec: started ? 120 : 0,
                        secondsPlayed: started ? 120 : 0, startedPlaying: started, kind: .http)
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
        func release() { let w = waiters; waiters = []; w.forEach { $0.resume() } }
        var played: [String] {
            events.compactMap { if case let .play(c, _, _, _, _) = $0 { return c.stream.name ?? "" }; return nil }
        }
    }

    private func makeWalk(_ world: World) -> FirstPlayAutoPlayController {
        let deps = FirstPlayAutoPlayController.Dependencies(
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
        let walk = FirstPlayAutoPlayController(titleKey: "tt1", dependencies: deps)
        walk.events.sink { world.events.append($0) }.store(in: &world.cancellables)
        return walk
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: - Choice begins → it reaches the screen

    func testAChoiceThatReachesTheScreenEndsPendingAndStalesEarlierWalks() {
        var ledger = PlayerChoiceLedger()
        ledger.walkStarted(.autoFailover, contextId: "ctx-1", failure: failure())
        XCTAssertTrue(ledger.admitsSwap(.autoFailover, replacing: "ctx-1", presented: "ctx-1"))
        let choice = UUID()
        ledger.choiceBegan(choice, walkInFlight: .autoFailover)
        XCTAssertTrue(ledger.choicePending)
        XCTAssertFalse(ledger.allowsAutomaticStart)
        XCTAssertFalse(ledger.admitsSwap(.autoFailover, replacing: "ctx-1", presented: "ctx-1"),
                       "selected is still ctx-1, yet the old walk may not swap")
        ledger.contextPresented()                                   // the pick's context is on screen
        XCTAssertFalse(ledger.choicePending)
        XCTAssertNil(ledger.heldFailure, "the failed context left the screen with its failure")
        XCTAssertNil(ledger.choiceAbandoned(choice), "a late abandon of a choice that took over changes nothing")
        XCTAssertEqual(ledger.failureArrived(contextId: "ctx-2", failure: failure()), .route)
    }

    // MARK: - Choice begins → abandoned → the playing source fails

    /// Scenario 1 of the finding (default settings): a manual source plays; a Sources pick fails
    /// to resolve; later the playing source fails. Its failure is routed (the manual alert).
    func testAnAbandonedChoiceLeavesTheNextFailureRouted() {
        var ledger = PlayerChoiceLedger()
        let choice = UUID()
        ledger.choiceBegan(choice, walkInFlight: nil)
        XCTAssertNil(ledger.choiceAbandoned(choice), "nothing was held")
        XCTAssertFalse(ledger.choicePending)
        XCTAssertTrue(ledger.allowsAutomaticStart)
        XCTAssertEqual(ledger.failureArrived(contextId: "ctx-manual", failure: failure(started: true)), .route)
    }

    /// The playing source fails while the choice is still resolving: held, and handed back to be
    /// routed when the choice is abandoned (the player reports a failure only once).
    func testAFailureDuringAPendingChoiceIsReplayedWhenTheChoiceIsAbandoned() {
        var ledger = PlayerChoiceLedger()
        let choice = UUID()
        ledger.choiceBegan(choice, walkInFlight: nil)
        let f = failure(started: true)
        XCTAssertEqual(ledger.failureArrived(contextId: "ctx-1", failure: f), .hold)
        XCTAssertEqual(ledger.choiceAbandoned(choice), PlayerChoiceLedger.HeldFailure(contextId: "ctx-1", failure: f))
        XCTAssertFalse(ledger.choicePending)
    }

    /// The same failure is dropped when the choice reaches the screen instead.
    func testAFailureDuringAPendingChoiceIsDroppedWhenTheChoiceTakesOver() {
        var ledger = PlayerChoiceLedger()
        let choice = UUID()
        ledger.choiceBegan(choice, walkInFlight: nil)
        XCTAssertEqual(ledger.failureArrived(contextId: "ctx-1", failure: failure()), .hold)
        ledger.contextPresented()
        XCTAssertNil(ledger.choiceAbandoned(choice))
    }

    // MARK: - Choice begins while a walk resolves → abandoned → the old walk's result arrives

    /// Scenario 2 of the finding: an auto-picked source failed and its failover resolves; the
    /// viewer picks a source; the pick fails to resolve. The old walk's result is dropped, the walk
    /// does not resume on its own, and the failure is routed again from scratch, which continues
    /// the walk with its next candidate.
    func testAnInterruptedWalksFailureIsRoutedAgainWhenTheChoiceIsAbandoned() async {
        let world = World()
        let walk = makeWalk(world)
        walk.seed(candidates: [stream("next"), stream("after")], alreadyTried: PlayerSourceFallbackTried.companion.None,
                  playing: stream("failing", direct: true))
        var ledger = PlayerChoiceLedger()
        let f = failure()
        // routeFailure: the walk starts for f.
        ledger.walkStarted(.autoFailover, contextId: "ctx-failing", failure: f)
        XCTAssertTrue(walk.failover(afterFailureOf: stream("failing", direct: true).playbackStreamKey, addonId: nil))
        await waitUntil { world.waiters.count == 1 }

        // viewerChoiceBegan: the walk was resolving; interruptWalks drops its in-flight work.
        let choice = UUID()
        ledger.choiceBegan(choice, walkInFlight: .autoFailover)
        walk.abandonFailover()
        XCTAssertEqual(walk.phase, .done)

        // The old walk's resolve lands: the controller drops it, and the ledger would too.
        world.release()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(world.events.isEmpty, "the interrupted walk never resumes on its own")
        XCTAssertFalse(ledger.admitsSwap(.autoFailover, replacing: "ctx-failing", presented: "ctx-failing"))

        // viewerChoiceAbandoned: the held failure comes back and is routed by the normal rules.
        let held = ledger.choiceAbandoned(choice)
        XCTAssertEqual(held, PlayerChoiceLedger.HeldFailure(contextId: "ctx-failing", failure: f))
        XCTAssertFalse(ledger.admitsGiveUp(.autoFailover), "no old ticket survives the abandon")
        ledger.walkStarted(.autoFailover, contextId: "ctx-failing", failure: f)
        XCTAssertTrue(walk.failover(afterFailureOf: stream("failing", direct: true).playbackStreamKey, addonId: nil))
        await waitUntil { world.waiters.count == 1 }
        world.release()
        await waitUntil { !world.played.isEmpty }
        XCTAssertEqual(world.played, ["after"], "the interrupted candidate counts as tried; the walk goes on")
        XCTAssertTrue(ledger.admitsSwap(.autoFailover, replacing: "ctx-failing", presented: "ctx-failing"))
    }

    /// A walk the start-up limit began (no failure) is not replayed: the slow source is still
    /// loading and its own watchdog reports later.
    func testAnInterruptedLimitWalkHasNothingToReplay() {
        var ledger = PlayerChoiceLedger()
        ledger.walkStarted(.episode, contextId: "ctx-slow", failure: nil)
        let choice = UUID()
        ledger.choiceBegan(choice, walkInFlight: .episode)
        XCTAssertNil(ledger.choiceAbandoned(choice))
        XCTAssertTrue(ledger.allowsAutomaticStart)
    }

    /// A give-up of a walk that a choice superseded closes nothing.
    func testAGiveUpAfterAChoiceClosesNothing() {
        var ledger = PlayerChoiceLedger()
        ledger.walkStarted(.autoFailover, contextId: "ctx-1", failure: failure())
        XCTAssertTrue(ledger.admitsGiveUp(.autoFailover))
        ledger.choiceBegan(UUID(), walkInFlight: .autoFailover)
        ledger.contextPresented()                                  // the manual source started
        XCTAssertFalse(ledger.admitsGiveUp(.autoFailover))
    }

    // MARK: - Two choices in a row

    func testOnlyTheNewestChoiceEndsPending() {
        var ledger = PlayerChoiceLedger()
        let first = UUID(), second = UUID()
        ledger.choiceBegan(first, walkInFlight: nil)
        XCTAssertEqual(ledger.failureArrived(contextId: "ctx-1", failure: failure()), .hold)
        ledger.choiceBegan(second, walkInFlight: nil)
        XCTAssertNil(ledger.choiceAbandoned(first), "superseded")
        XCTAssertTrue(ledger.choicePending)
        XCTAssertNotNil(ledger.choiceAbandoned(second), "the held failure survives until the newest choice ends")
        XCTAssertFalse(ledger.choicePending)
    }

    // MARK: - Choice begins → Menu

    func testMenuDuringAPendingChoiceEndsItAndStalesEverything() {
        var ledger = PlayerChoiceLedger()
        ledger.walkStarted(.episode, contextId: "ctx-1", failure: failure())
        let choice = UUID()
        ledger.choiceBegan(choice, walkInFlight: .episode)
        XCTAssertEqual(ledger.failureArrived(contextId: "ctx-1", failure: failure()), .hold)
        ledger.viewerActed()                                       // the cover's setter (Menu)
        XCTAssertFalse(ledger.choicePending)
        XCTAssertNil(ledger.heldFailure)
        XCTAssertNil(ledger.choiceAbandoned(choice), "the engine's stop() abandon after Menu changes nothing")
        XCTAssertFalse(ledger.admitsSwap(.episode, replacing: "ctx-1", presented: "ctx-1"))
        XCTAssertFalse(ledger.admitsGiveUp(.episode))
    }

    /// A hand-off or list pick (taking over at once) never leaves anything pending.
    func testAChoiceThatTakesOverAtOnceLeavesNothingPending() {
        var ledger = PlayerChoiceLedger()
        let ticketBefore = ledger.gate.ticket
        ledger.viewerActed()
        XCTAssertFalse(ledger.choicePending)
        XCTAssertTrue(ledger.allowsAutomaticStart)
        XCTAssertFalse(ledger.accepts(ticketBefore))
        XCTAssertTrue(ledger.accepts(ledger.gate.ticket))
    }

    /// A report swallowed by a walk already resolving keeps that walk's ticket and records the
    /// real failure (so an interruption replays it).
    func testADuplicateReportKeepsTheTicketAndRecordsTheFailure() {
        var ledger = PlayerChoiceLedger()
        ledger.walkStarted(.autoFailover, contextId: "ctx-slow", failure: nil)   // start-up limit
        let ticket = ledger.ticket(.autoFailover)
        let f = failure()
        ledger.walkStarted(.autoFailover, contextId: "ctx-slow", failure: f, keepTicket: true)
        XCTAssertEqual(ledger.ticket(.autoFailover), ticket)
        let choice = UUID()
        ledger.choiceBegan(choice, walkInFlight: .autoFailover)
        XCTAssertEqual(ledger.choiceAbandoned(choice), PlayerChoiceLedger.HeldFailure(contextId: "ctx-slow", failure: f))
    }

    // MARK: - The generation underneath

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
}
