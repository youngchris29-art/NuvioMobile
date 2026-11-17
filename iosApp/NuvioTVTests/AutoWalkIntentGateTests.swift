import Combine
import XCTest
@testable import NuvioTV
import SharedCore

/// W4 review r1: the viewer's own choice invalidates every automatic walk (`AutoWalkIntentGate` in
/// `Screens/PlaybackModels.swift`, applied by `StreamPickerView` to every event of the first-play
/// failover and the in-player episode walk). Each case is an event sequence: the walk controller
/// runs against a fake resolver, the gate is driven exactly as the host drives it.
@MainActor
final class AutoWalkIntentGateTests: XCTestCase {

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

    /// A walk whose resolves wait until released (`release`) and then answer `answer`.
    private final class World {
        var events: [FirstPlayAutoPlayController.Event] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        var answer: FirstPlayAutoPlayController.ResolveOutcome?
        var cancellables: Set<AnyCancellable> = []

        func release() { let w = waiters; waiters = []; w.forEach { $0.resume() } }
    }

    private func makeWalk(_ world: World, deadline: TimeInterval = 5) -> FirstPlayAutoPlayController {
        let deps = FirstPlayAutoPlayController.Dependencies(
            expectedToken: { "t" }, consumeAutoPlay: {}, cachedOnly: { false }, isCachedDebridLink: { _ in false },
            rejected: { _ in [] }, reject: { _, _ in }, invalidate: { _ in },
            directURL: { stream in let u: String? = stream.url; return u.flatMap(URL.init(string:)) },
            canResolve: { _ in true },
            resolve: { stream in
                await withCheckedContinuation { world.waiters.append($0) }
                return world.answer ?? .playable(stream, URL(string: "https://resolved.example/\(stream.name ?? "")")!)
            },
            resolveDeadline: deadline, searchDeadline: 30)
        let walk = FirstPlayAutoPlayController(titleKey: "tt1:1:2", dependencies: deps)
        walk.events.sink { world.events.append($0) }.store(in: &world.cancellables)
        return walk
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private var playedCount: (World) -> Int = { world in
        world.events.filter { if case .play = $0 { return true }; return false }.count
    }

    // MARK: - The gate

    func testAChoiceStalesEveryEarlierTicketAndBlocksNewWalksUntilShown() {
        var gate = AutoWalkIntentGate()
        let ticket = gate.ticket
        XCTAssertTrue(gate.accepts(ticket))
        XCTAssertTrue(gate.allowsAutomaticWalk)
        gate.viewerChose()
        XCTAssertFalse(gate.accepts(ticket))
        XCTAssertFalse(gate.allowsAutomaticWalk, "the choice is pending: nothing automatic starts")
        XCTAssertFalse(gate.accepts(gate.ticket), "not even a ticket taken while it is pending")
        gate.contextPresented()
        XCTAssertTrue(gate.allowsAutomaticWalk)
        XCTAssertFalse(gate.accepts(ticket), "the old ticket stays stale")
        XCTAssertTrue(gate.accepts(gate.ticket))
        XCTAssertFalse(gate.accepts(nil))
    }

    func testASwapNeedsItsTicketAndTheContextItReplaces() {
        let gate = AutoWalkIntentGate()
        XCTAssertTrue(gate.admitsSwap(ticket: gate.ticket, replacing: "ctx-1", presented: "ctx-1"))
        XCTAssertFalse(gate.admitsSwap(ticket: gate.ticket, replacing: "ctx-1", presented: "ctx-2"))
        XCTAssertFalse(gate.admitsSwap(ticket: gate.ticket, replacing: "ctx-1", presented: nil))
        XCTAssertTrue(gate.admitsSwap(ticket: gate.ticket, replacing: nil, presented: "ctx-1"))
    }

    // MARK: - The finding's two scenarios

    /// An automatic replacement resolves; the viewer picks a debrid source in the player, which
    /// also has to resolve (the old context is still `selected`). The replacement lands first: it
    /// is dropped; the viewer's pick then goes on screen and stays.
    func testAManualDebridPickWinsOverAnAutomaticReplacementStillResolving() async {
        let world = World()
        let walk = makeWalk(world)
        walk.seed(candidates: [stream("auto-next")], alreadyTried: PlayerSourceFallbackTried(keys: [], attempts: 0),
                  playing: stream("failing", direct: true))
        var gate = AutoWalkIntentGate()
        let presented = "ctx-failing"
        let ticket = gate.ticket                              // the host takes it as the walk starts
        XCTAssertTrue(walk.failover(afterFailureOf: stream("failing", direct: true).playbackStreamKey, addonId: nil))
        await waitUntil { world.waiters.count == 1 }

        gate.viewerChose()                                    // the manual pick begins; it resolves too
        world.release()                                       // the automatic replacement lands first
        await waitUntil { self.playedCount(world) == 1 }
        XCTAssertEqual(playedCount(world), 1, "the walk produced its result")
        XCTAssertFalse(gate.admitsSwap(ticket: ticket, replacing: presented, presented: presented),
                       "selected is still the old context, yet the automatic result is dropped")

        gate.contextPresented()                               // the viewer's resolved pick is on screen
        XCTAssertFalse(gate.admitsSwap(ticket: ticket, replacing: presented, presented: "ctx-manual"))
    }

    /// The walk gives up after the viewer's own source already started: nothing closes.
    func testAGaveUpAfterAManualSourceStartedClosesNothing() async {
        let world = World()
        world.answer = .failed(reason: "not cached", rejectsLink: true)
        let walk = makeWalk(world)
        walk.seed(candidates: [stream("last")], alreadyTried: PlayerSourceFallbackTried(keys: [], attempts: 0),
                  playing: stream("failing", direct: true))
        var gate = AutoWalkIntentGate()
        let ticket = gate.ticket
        XCTAssertTrue(walk.failover(afterFailureOf: stream("failing", direct: true).playbackStreamKey, addonId: nil))
        await waitUntil { world.waiters.count == 1 }

        gate.viewerChose()                                    // a direct pick in the Sources panel
        gate.contextPresented()                               // ... and it started at once
        world.release()
        await waitUntil { !world.events.isEmpty }
        guard case .gaveUp(_, true)? = world.events.last else { return XCTFail("the walk gave up") }
        XCTAssertFalse(gate.accepts(ticket), "the host drops the give-up: the manual source keeps playing")
    }

    // MARK: - Menu and an episode jump during a walk

    func testMenuDuringAWalkDropsItsResult() async {
        let world = World()
        let walk = makeWalk(world)
        walk.seed(candidates: [stream("next")], alreadyTried: PlayerSourceFallbackTried(keys: [], attempts: 0),
                  playing: stream("failing", direct: true))
        var gate = AutoWalkIntentGate()
        let ticket = gate.ticket
        _ = walk.failover(afterFailureOf: stream("failing", direct: true).playbackStreamKey, addonId: nil)
        await waitUntil { world.waiters.count == 1 }

        gate.viewerChose()                                    // Menu: the cover's setter
        walk.cancel(why: "player closed")                     // the host's noteViewerChoice / dismissal
        gate.contextPresented()                               // selected == nil
        world.release()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(world.events.isEmpty, "a cancelled walk neither plays nor gives up")
        XCTAssertFalse(gate.accepts(ticket))
    }

    func testAnEpisodeJumpDuringAWalkDropsItsResult() async {
        let world = World()
        let walk = makeWalk(world)
        walk.seed(candidates: [stream("next")], alreadyTried: PlayerSourceFallbackTried(keys: [], attempts: 0),
                  playing: stream("failing", direct: true))
        var gate = AutoWalkIntentGate()
        let ticket = gate.ticket
        _ = walk.failover(afterFailureOf: stream("failing", direct: true).playbackStreamKey, addonId: nil)
        await waitUntil { world.waiters.count == 1 }

        gate.viewerChose()                                    // the jump is chosen; its search runs
        world.release()                                       // the walk's result lands meanwhile
        await waitUntil { self.playedCount(world) == 1 }
        XCTAssertFalse(gate.admitsSwap(ticket: ticket, replacing: "ctx-e2", presented: "ctx-e2"))
        XCTAssertFalse(gate.allowsAutomaticWalk, "nor may a start-up limit or failure start a walk now")
    }
}
