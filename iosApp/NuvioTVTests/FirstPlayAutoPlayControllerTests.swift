import Combine
import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for `FirstPlayAutoPlayController` (`Screens/FirstPlayAutoPlay.swift`, orivio batch
/// items 1 and 2): the candidate walk behind "Auto-Play Best Source" and its playback failover.
/// Every SharedCore singleton the live controller uses is swapped for a closure on `Harness`, so
/// the walk runs against a fake resolver, an in-memory rejected-link store and a fixed token.
@MainActor
final class FirstPlayAutoPlayControllerTests: XCTestCase {

    private static let token = "movie::tt1::null::null::false"

    // MARK: - Fixtures

    /// `torrentHash` (W4): a real 40-hex info hash, so the shared torrent-copy rule sees it.
    private func stream(_ name: String, addon: String = "addon:a", direct: Bool = false,
                        torrentHash: String? = nil, fileIdx: Int32? = nil) -> StreamItem {
        StreamItem(
            name: name, title: nil, description: nil,
            url: direct ? "https://cdn.example.com/\(name).mkv" : nil,
            // Resolve candidates carry an info hash, so each gets its own `playbackStreamKey`.
            infoHash: torrentHash ?? (direct ? nil : "hash-\(name)"),
            fileIdx: fileIdx.map { KotlinInt(int: $0) }, externalUrl: nil, ytId: nil, sources: [], sourceName: nil,
            addonName: addon, addonId: addon, addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: [], debridResolved: false
        )
    }

    private func feed(token: String? = FirstPlayAutoPlayControllerTests.token, settled: [StreamItem] = [],
                      flow: Bool = true, loading: Bool = true, outcome: Bool = true) -> FirstPlayAutoPlayFeed {
        FirstPlayAutoPlayFeed(
            requestToken: token,
            autoPlayStream: settled.first,
            autoPlayCandidates: settled,
            isDirectAutoPlayFlow: flow,
            isAnyLoading: loading,
            hasOutcome: outcome
        )
    }

    /// Fake world for one controller: resolve plans per stream name, a rejected-link store, and
    /// everything the controller asked for, in order.
    private final class Harness {
        enum Plan { case succeed, fail, failNotLinkFault, hang, throwOffline }
        /// W4 (2b.7): what a cache-bypassing re-resolve answers.
        enum FreshPlan { case newLink, sameLink, fail }

        var plans: [String: Plan] = [:]
        var freshPlans: [String: FreshPlan] = [:]
        private(set) var freshCalls: [String] = []
        /// W4: the controller's clock (the refresh rule's "resolved less than a minute ago").
        var clock: TimeInterval = 1_000
        var rejectedByTitle: [String: Set<String>] = [:]
        var cachedNames: Set<String> = []
        var cachedOnly = false
        var unresolvable: Set<String> = []
        var networkSatisfied = true
        private(set) var resolveCalls: [String] = []
        private(set) var invalidated: [String] = []
        private(set) var consumed = 0
        private(set) var events: [FirstPlayAutoPlayController.Event] = []
        private var hung: [CheckedContinuation<Void, Never>] = []
        private var cancellables: Set<AnyCancellable> = []

        @MainActor
        func makeController(resolveDeadline: TimeInterval = 5, searchDeadline: TimeInterval = 30,
                            maxAttempts: Int = 4, titleKey: String = "tt1",
                            capProvider: (() -> Int)? = nil) -> FirstPlayAutoPlayController {
            var deps = FirstPlayAutoPlayController.Dependencies(
                expectedToken: { FirstPlayAutoPlayControllerTests.token },
                consumeAutoPlay: { [unowned self] in self.consumed += 1 },
                cachedOnly: { [unowned self] in self.cachedOnly },
                isCachedDebridLink: { [unowned self] in self.cachedNames.contains($0.name ?? "") },
                rejected: { [unowned self] in self.rejectedByTitle[$0] ?? [] },
                reject: { [unowned self] key, title in self.rejectedByTitle[title, default: []].insert(key) },
                invalidate: { [unowned self] in self.invalidated.append($0.name ?? "") },
                directURL: { stream in
                    let url: String? = stream.url
                    return url.flatMap(URL.init(string:))
                },
                canResolve: { [unowned self] in !self.unresolvable.contains($0.name ?? "") },
                resolve: { [unowned self] stream in
                    let name = stream.name ?? ""
                    self.resolveCalls.append(name)
                    switch self.plans[name] ?? .succeed {
                    case .succeed:
                        return .playable(stream, URL(string: "https://resolved.example/\(name)")!)
                    case .fail:
                        return .failed(reason: "not cached", rejectsLink: true)
                    case .failNotLinkFault:
                        return .failed(reason: "missing debrid API key", rejectsLink: false)
                    case .hang:
                        await withCheckedContinuation { self.hung.append($0) }
                        return .playable(stream, URL(string: "https://resolved.example/\(name)")!)
                    case .throwOffline:
                        throw URLError(.notConnectedToInternet)
                    }
                },
                resolveDeadline: resolveDeadline,
                searchDeadline: searchDeadline,
                networkSatisfied: { [unowned self] in self.networkSatisfied }
            )
            deps.maxAttempts = capProvider ?? { maxAttempts }
            deps.now = { [unowned self] in self.clock }
            deps.resolveFresh = { [unowned self] stream in
                let name = stream.name ?? ""
                self.freshCalls.append(name)
                switch self.freshPlans[name] ?? .fail {
                case .newLink: return .playable(stream, URL(string: "https://fresh.example/\(name)")!)
                case .sameLink: return .playable(stream, URL(string: "https://resolved.example/\(name)")!)
                case .fail: return .failed(reason: "not cached", rejectsLink: true)
                }
            }
            let controller = FirstPlayAutoPlayController(titleKey: titleKey, dependencies: deps)
            controller.events.sink { [unowned self] in self.events.append($0) }.store(in: &cancellables)
            return controller
        }

        /// Lets every hung resolve finish, as a late network answer would.
        func releaseHung() {
            let waiters = hung
            hung = []
            waiters.forEach { $0.resume() }
        }

        /// Names (and attempts) the controller asked the picker to play, in order.
        var played: [(name: String, attempt: Int, failover: Bool)] {
            events.compactMap { event -> (name: String, attempt: Int, failover: Bool)? in
                if case let .play(candidate, _, _, attempt, isFailover) = event {
                    return (candidate.stream.name ?? "", attempt, isFailover)
                }
                return nil
            }
        }

        var gaveUp: [(FirstPlayAutoPlayController.GiveUpReason, Bool)] {
            events.compactMap { event -> (FirstPlayAutoPlayController.GiveUpReason, Bool)? in
                if case let .gaveUp(reason, duringFailover) = event { return (reason, duringFailover) }
                return nil
            }
        }
    }

    /// Yields the main actor until `condition` holds (or the timeout passes).
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Walk order

    func testFirstDirectCandidatePlaysAndTheRepositoryIsConsumed() async {
        let harness = Harness()
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A", direct: true), stream("B", direct: true)]))

        XCTAssertEqual(harness.played.map { $0.name }, ["A"])
        XCTAssertEqual(harness.played.first?.attempt, 1)
        XCTAssertEqual(harness.played.first?.failover, false)
        XCTAssertEqual(harness.consumed, 1)
        XCTAssertEqual(controller.phase, .done)
        XCTAssertTrue(harness.resolveCalls.isEmpty, "a direct URL plays without a resolve")
    }

    func testFailedResolveIsRememberedAndTheNextCandidatePlays() async {
        let harness = Harness()
        harness.plans = ["T1": .fail, "T2": .succeed]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("T1"), stream("T2")]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["T1", "T2"])
        XCTAssertEqual(harness.played.map { $0.name }, ["T2"])
        XCTAssertEqual(harness.played.first?.attempt, 2)
        XCTAssertEqual(harness.rejectedByTitle["tt1"], [stream("T1").playbackStreamKey])
        XCTAssertEqual(harness.invalidated, ["T1"])
    }

    func testAFailureThatIsNotTheLinksFaultIsNotRemembered() async {
        let harness = Harness()
        harness.plans = ["T1": .failNotLinkFault]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("T1"), stream("T2")]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.played.map { $0.name }, ["T2"])
        XCTAssertNil(harness.rejectedByTitle["tt1"])
        XCTAssertTrue(harness.invalidated.isEmpty)
    }

    /// W4 (decision Q3, upstream's order): after a failure the next candidate in rank order plays,
    /// from any add-on; the failed link's add-on is no longer tried first.
    func testTheNextRankedCandidatePlaysAfterAFailureFromAnyAddon() async {
        let harness = Harness()
        harness.plans = ["A1": .fail]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A1", addon: "addon:a"), stream("B1", addon: "addon:b"),
                                         stream("A2", addon: "addon:a")]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["A1", "B1"])
        XCTAssertEqual(harness.played.map { $0.name }, ["B1"])
    }

    /// The pure `nextIndex` keeps its preference parameter (no caller passes one since W4).
    func testNextIndexStillHonoursAnExplicitAddonPreference() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        let candidates = [stream("A1", addon: "addon:a"), stream("B1", addon: "addon:b"), stream("A2", addon: "addon:a")]
            .map(FirstPlayAutoPlayController.Candidate.init(stream:))
        XCTAssertEqual(Policy.nextIndex(in: candidates, triedIndices: [0], rejected: [],
                                        preferAddonId: "addon:a"), 2)
        XCTAssertEqual(Policy.nextIndex(in: candidates, triedIndices: [0], rejected: [],
                                        preferAddonId: nil), 1)
    }

    func testAttemptCapIsFourPerVisit() async {
        let harness = Harness()
        let names = ["T1", "T2", "T3", "T4", "T5", "T6"]
        names.forEach { harness.plans[$0] = .fail }
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: names.map { stream($0) }))
        await waitUntil { !harness.gaveUp.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["T1", "T2", "T3", "T4"])
        XCTAssertEqual(harness.gaveUp.first?.0, .allFailed)
        XCTAssertEqual(harness.gaveUp.first?.1, false)
        XCTAssertEqual(controller.phase, .exhausted)
        XCTAssertTrue(harness.played.isEmpty)
    }

    /// P4 (BUG-143): a resolve that throws a network error does not remember the link.
    func testThrownNetworkErrorIsNotRemembered() async {
        let harness = Harness()
        harness.plans = ["NET": .throwOffline]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("NET"), stream("OK")]))
        await waitUntil { !harness.played.isEmpty }
        XCTAssertEqual(harness.played.map { $0.name }, ["OK"])
        XCTAssertNil(harness.rejectedByTitle["tt1"])
        XCTAssertTrue(harness.invalidated.isEmpty)
    }

    /// P4 (C-6): a provider `Error()` (rejectsLink: true) while the TV is offline is not remembered.
    func testOfflineResolveErrorIsNotRemembered() async {
        let harness = Harness()
        harness.plans = ["DOWN": .fail]
        harness.networkSatisfied = false
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("DOWN"), stream("OK")]))
        await waitUntil { !harness.played.isEmpty }
        XCTAssertEqual(harness.played.map { $0.name }, ["OK"])
        XCTAssertNil(harness.rejectedByTitle["tt1"])
        XCTAssertTrue(harness.invalidated.isEmpty)
    }

    func testResolveDeadlineMovesOnAndIgnoresTheLateAnswer() async {
        let harness = Harness()
        harness.plans = ["SLOW": .hang]
        let controller = harness.makeController(resolveDeadline: 0.05)
        controller.arm()
        controller.ingest(feed(settled: [stream("SLOW"), stream("FAST")]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.played.map { $0.name }, ["FAST"])
        // P4 (BUG-143): a timed-out resolve is transient — the walk moves on, the link is not remembered.
        XCTAssertNil(harness.rejectedByTitle["tt1"])

        harness.releaseHung()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.played.map { $0.name }, ["FAST"], "the late answer must not start a second player")
    }

    func testCandidateThisDeviceCannotResolveIsSkippedWithoutCounting() async {
        let harness = Harness()
        harness.unresolvable = ["P2P"]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("P2P"), stream("T1")]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["T1"])
        XCTAssertEqual(harness.played.first?.attempt, 1)
        XCTAssertNil(harness.rejectedByTitle["tt1"])
    }

    // MARK: - Filters

    func testCachedOnlyKeepsOnlyCachedDebridLinks() async {
        let harness = Harness()
        harness.cachedOnly = true
        harness.cachedNames = ["C"]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A", direct: true), stream("U"), stream("C")]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["C"])
        XCTAssertEqual(harness.played.map { $0.name }, ["C"])
    }

    func testCachedOnlyWithNothingCachedShowsTheList() async {
        let harness = Harness()
        harness.cachedOnly = true
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A", direct: true)]))

        XCTAssertEqual(harness.gaveUp.first?.0, .noCandidates)
        XCTAssertTrue(harness.played.isEmpty)
    }

    func testRecentlyFailedLinksAreSkipped() async {
        let harness = Harness()
        harness.rejectedByTitle["tt1"] = [stream("A", direct: true).playbackStreamKey]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A", direct: true), stream("B", direct: true)]))

        XCTAssertEqual(harness.played.map { $0.name }, ["B"])
        XCTAssertEqual(harness.played.first?.attempt, 1)
    }

    // MARK: - Ingest gating

    func testAStateForAnotherRequestIsIgnored() async {
        let harness = Harness()
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(token: "movie::tt1::null::null::true", settled: [stream("A", direct: true)]))
        controller.ingest(feed(token: nil, settled: [stream("A", direct: true)]))

        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertEqual(harness.consumed, 0)
        XCTAssertEqual(controller.phase, .searching)
    }

    func testNothingHappensBeforeArming() async {
        let harness = Harness()
        let controller = harness.makeController()
        controller.ingest(feed(settled: [stream("A", direct: true)]))

        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testTheFlowEndingWithNoCandidateShowsTheList() async {
        let harness = Harness()
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(flow: true, loading: true))        // flow on, still searching
        XCTAssertTrue(harness.events.isEmpty)
        controller.ingest(feed(flow: false, loading: true))       // settled with nothing, slow add-ons still fetch

        XCTAssertEqual(harness.gaveUp.first?.0, .noCandidates)
        XCTAssertEqual(controller.phase, .exhausted)
    }

    func testSearchDeadlineShowsTheList() async {
        let harness = Harness()
        let controller = harness.makeController(searchDeadline: 0.05)
        controller.arm()
        await waitUntil { !harness.gaveUp.isEmpty }

        XCTAssertEqual(harness.gaveUp.first?.0, .searchTimedOut)
    }

    // MARK: - Cancel

    func testCancelDuringAResolveNeverPlays() async {
        let harness = Harness()
        harness.plans = ["SLOW": .hang]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("SLOW"), stream("NEXT")]))
        await waitUntil { harness.resolveCalls == ["SLOW"] }
        XCTAssertEqual(controller.phase, .resolving(attempt: 1))

        controller.cancel()
        XCTAssertEqual(controller.phase, .cancelled)
        harness.releaseHung()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(harness.events.isEmpty, "a cancelled walk neither plays nor gives up")
        XCTAssertEqual(harness.resolveCalls, ["SLOW"])
        XCTAssertFalse(controller.isOverlayVisible)
    }

    func testCancelWhileSearchingHidesTheOverlay() async {
        let harness = Harness()
        let controller = harness.makeController()
        controller.arm()
        XCTAssertTrue(controller.isOverlayVisible)
        controller.cancel()
        controller.ingest(feed(settled: [stream("A", direct: true)]))

        XCTAssertEqual(controller.phase, .cancelled)
        XCTAssertFalse(controller.isOverlayVisible)
        XCTAssertTrue(harness.events.isEmpty)
    }

    // MARK: - Playback failover

    func testFailoverSwapsInTheNextRankedLink() async {
        let harness = Harness()
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A1", addon: "addon:a", direct: true),
                                         stream("B1", addon: "addon:b", direct: true),
                                         stream("A2", addon: "addon:a", direct: true)]))
        let failedKey = stream("A1", addon: "addon:a", direct: true).playbackStreamKey

        XCTAssertTrue(controller.failover(afterFailureOf: failedKey, addonId: "addon:a"))
        XCTAssertEqual(harness.played.map { $0.name }, ["A1", "B1"], "W4: rank order, not the failed add-on first")
        XCTAssertEqual(harness.played.last?.attempt, 2)
        XCTAssertEqual(harness.played.last?.failover, true)
    }

    func testFailoverStopsAtTheAttemptCap() async {
        let harness = Harness()
        let names = ["S1", "S2", "S3", "S4", "S5"]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: names.map { stream($0, direct: true) }))
        for name in names.prefix(4) {
            controller.failover(afterFailureOf: stream(name, direct: true).playbackStreamKey, addonId: "addon:a")
        }

        XCTAssertEqual(harness.played.map { $0.name }, ["S1", "S2", "S3", "S4"])
        XCTAssertEqual(harness.gaveUp.first?.0, .allFailed)
        XCTAssertEqual(harness.gaveUp.first?.1, true, "the picker closes the failed player")
    }

    // MARK: - External default player

    func testExternalDefaultTakesTheFirstPlayAndFailoverStaysBuiltIn() throws {
        typealias Policy = FirstPlayAutoPlayController.Policy
        let harness = Harness()
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A1", direct: true), stream("A2", direct: true)]))

        let first = try XCTUnwrap(harness.played.first)
        XCTAssertFalse(first.failover)
        XCTAssertEqual(Policy.startDestination(isFailover: first.failover, defaultExternalPlayerId: "infuse"),
                       .external(playerId: "infuse"), "the first auto pick goes to the external default")
        XCTAssertEqual(Policy.startDestination(isFailover: first.failover, defaultExternalPlayerId: nil),
                       .builtIn, "no external default: the built-in player")

        // A failover (only reachable when the first start played in NuvioTV) never hands off.
        controller.failover(afterFailureOf: stream("A1", direct: true).playbackStreamKey, addonId: "addon:a")
        XCTAssertEqual(harness.played.count, 2)
        let second = try XCTUnwrap(harness.played.last)
        XCTAssertEqual(second.name, "A2")
        XCTAssertTrue(second.failover)
        XCTAssertEqual(Policy.startDestination(isFailover: second.failover, defaultExternalPlayerId: "infuse"),
                       .builtIn)
    }

    func testStartDestinationNeedsANonEmptyDefault() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        XCTAssertEqual(Policy.startDestination(isFailover: false, defaultExternalPlayerId: ""), .builtIn)
        XCTAssertEqual(Policy.startDestination(isFailover: false, defaultExternalPlayerId: "vlc"), .external(playerId: "vlc"))
        XCTAssertEqual(Policy.startDestination(isFailover: true, defaultExternalPlayerId: "vlc"), .builtIn)
    }

    func testFailoverWithoutAStartedWalkDeclines() async {
        let harness = Harness()
        let controller = harness.makeController()
        XCTAssertFalse(controller.failover(afterFailureOf: "k", addonId: nil))
        controller.arm()
        XCTAssertFalse(controller.failover(afterFailureOf: "k", addonId: nil))
        XCTAssertTrue(harness.events.isEmpty)
    }

    // MARK: - Policy

    func testVerdictRules() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        let token = Self.token
        XCTAssertEqual(Policy.verdict(feed: feed(token: "other"), expectedToken: token, sawDirectFlow: true), .ignore)
        XCTAssertEqual(Policy.verdict(feed: feed(settled: [stream("A")]), expectedToken: token, sawDirectFlow: false), .walk)
        XCTAssertEqual(Policy.verdict(feed: feed(flow: true, loading: true), expectedToken: token, sawDirectFlow: true), .wait)
        // The bare request-start and the tmdb→IMDb remap states have no outcome yet.
        XCTAssertEqual(Policy.verdict(feed: feed(flow: false, loading: false, outcome: false), expectedToken: token, sawDirectFlow: false), .wait)
        XCTAssertEqual(Policy.verdict(feed: feed(flow: false, loading: true, outcome: false), expectedToken: token, sawDirectFlow: false), .wait)
        // Finished with nothing (embedded streams, no add-ons, nothing playable).
        XCTAssertEqual(Policy.verdict(feed: feed(flow: false, loading: false), expectedToken: token, sawDirectFlow: false), .showList)
        // Still loading: only a flow that was on and has now settled empty ends the wait.
        XCTAssertEqual(Policy.verdict(feed: feed(flow: false, loading: true), expectedToken: token, sawDirectFlow: false), .wait)
        XCTAssertEqual(Policy.verdict(feed: feed(flow: false, loading: true), expectedToken: token, sawDirectFlow: true), .showList)
    }

    func testOverlayMessages() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        XCTAssertEqual(Policy.overlayMessage(for: .searching), Policy.overlayMessage(for: .resolving(attempt: 1)))
        // W4 (h): the "of m" follows the walk's cap (the first start plus Sources to Try).
        XCTAssertEqual(Policy.overlayMessage(for: .resolving(attempt: 2), cap: 6),
                       String(localized: "Trying another source (\(2) of \(6))\u{2026}"))
        XCTAssertNotEqual(Policy.overlayMessage(for: .resolving(attempt: 2), cap: 6),
                          Policy.overlayMessage(for: .resolving(attempt: 2), cap: 4))
        XCTAssertNotNil(Policy.overlayMessage(for: .resolving(attempt: 2)))
        XCTAssertNotEqual(Policy.overlayMessage(for: .resolving(attempt: 2)), Policy.overlayMessage(for: .searching))
        for phase: FirstPlayAutoPlayController.Phase in [.idle, .done, .cancelled, .exhausted] {
            XCTAssertNil(Policy.overlayMessage(for: phase))
        }
    }

    func testCachedDebridLinkNeedsPositiveCacheEvidenceOnTheActiveResolver() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        let hints = StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                        filename: nil, proxyHeaders: nil, audioDelayMs: nil)
        func item(url: String? = nil, infoHash: String? = nil, resolve: StreamClientResolve? = nil,
                  cache: StreamDebridCacheStatus? = nil) -> StreamItem {
            StreamItem(name: "S", title: nil, description: nil, url: url, infoHash: infoHash, fileIdx: nil,
                       externalUrl: nil, ytId: nil, sources: [], sourceName: nil, addonName: "Add-on", addonId: "addon:x",
                       addonLogo: nil, streamType: nil, behaviorHints: hints, clientResolve: resolve,
                       debridCacheStatus: cache, externalSubtitles: [], badges: [], debridResolved: false)
        }
        let directDebrid = item(resolve: StreamClientResolve(
            type: "debrid", infoHash: nil, fileIdx: nil, magnetUri: nil, sources: [], torrentName: nil,
            filename: nil, mediaType: nil, mediaId: nil, mediaOnlyId: nil, title: nil, season: nil, episode: nil,
            service: "realdebrid", serviceIndex: nil, serviceExtension: nil, isCached: KotlinBoolean(bool: true),
            stream: nil
        ))
        XCTAssertTrue(Policy.isCachedDebridLink(directDebrid, debridEnabled: true, activeResolverProviderId: "realdebrid"))
        XCTAssertTrue(Policy.isCachedDebridLink(directDebrid, debridEnabled: true, activeResolverProviderId: "RealDebrid"))
        XCTAssertFalse(Policy.isCachedDebridLink(directDebrid, debridEnabled: true, activeResolverProviderId: "torbox"))
        XCTAssertFalse(Policy.isCachedDebridLink(directDebrid, debridEnabled: false, activeResolverProviderId: "realdebrid"))

        let cachedTorrent = item(infoHash: "abc", cache: StreamDebridCacheStatus(
            providerId: "torbox", providerName: "TorBox", state: .cached, cachedName: nil, cachedSize: nil))
        let uncachedTorrent = item(infoHash: "abc", cache: StreamDebridCacheStatus(
            providerId: "torbox", providerName: "TorBox", state: .notCached, cachedName: nil, cachedSize: nil))
        XCTAssertTrue(Policy.isCachedDebridLink(cachedTorrent, debridEnabled: true, activeResolverProviderId: "torbox"))
        XCTAssertFalse(Policy.isCachedDebridLink(uncachedTorrent, debridEnabled: true, activeResolverProviderId: "torbox"))

        XCTAssertFalse(Policy.isCachedDebridLink(item(url: "https://cdn.example.com/a.mkv"),
                                                 debridEnabled: true, activeResolverProviderId: "torbox"),
                       "a plain HTTP link carries no cache evidence")
    }

    func testAddonMarkedCachedLinkCountsForTheServiceItNames() {
        // GitHub #23: Settings → Sources → Cached Sources Only lists an add-on's resolved link it
        // marks cached; the walk must treat it the same way (one shared rule).
        typealias Policy = FirstPlayAutoPlayController.Policy
        let hints = StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                        filename: nil, proxyHeaders: nil, audioDelayMs: nil)
        func link(_ name: String) -> StreamItem {
            StreamItem(name: name, title: nil, description: nil, url: "https://cdn.example.com/a.mkv", infoHash: nil,
                       fileIdx: nil, externalUrl: nil, ytId: nil, sources: [], sourceName: nil, addonName: "Torrentio",
                       addonId: "addon:t", addonLogo: nil, streamType: nil, behaviorHints: hints, clientResolve: nil,
                       debridCacheStatus: nil, externalSubtitles: [], badges: [], debridResolved: false)
        }
        XCTAssertTrue(Policy.isCachedDebridLink(link("[TB+] Torrentio 4k"), debridEnabled: true, activeResolverProviderId: "torbox"))
        XCTAssertFalse(Policy.isCachedDebridLink(link("[RD+] Torrentio 4k"), debridEnabled: true, activeResolverProviderId: "torbox"),
                       "cached on another service than the active one")
        XCTAssertTrue(Policy.isCachedDebridLink(link("4K \u{26A1}"), debridEnabled: true, activeResolverProviderId: "torbox"),
                      "a bolt names no service")
        XCTAssertFalse(Policy.isCachedDebridLink(link("[TB download] Torrentio 4k"), debridEnabled: true, activeResolverProviderId: "torbox"))
        XCTAssertFalse(Policy.isCachedDebridLink(link("[TB+] Torrentio 4k"), debridEnabled: false, activeResolverProviderId: "torbox"))
    }

    // MARK: - Pick log (device session 2026-10-04)

    /// The `[AutoPlay] pick` line carries the four rank facts so a device log shows why a link won.
    func testRankSummaryPrintsTheRankFactsInOrder() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        XCTAssertEqual(Policy.rankSummary(resolution: 2160, dynamicRange: 1, cached: 1, size: 58_200_000_000),
                       "res=2160 hdr=1 cached=1 size=58.2GB")
        XCTAssertEqual(Policy.rankSummary(resolution: 1080, dynamicRange: 0, cached: 0, size: 2_460_000_000),
                       "res=1080 hdr=0 cached=0 size=2.5GB")
        XCTAssertEqual(Policy.rankSummary(resolution: 0, dynamicRange: 0, cached: 0, size: 0),
                       "res=- hdr=0 cached=0 size=-", "unknown resolution and size print a dash")
    }

    // MARK: - W4: source fallback budget, seeding, start-up limit, refresh

    /// (a) Sources to Try 1 (cap 2): two failed resolves end the walk.
    func testCapFromTheSettingEndsTheWalkAfterTwoAttempts() async {
        let harness = Harness()
        harness.plans = ["T1": .fail, "T2": .fail, "T3": .fail]
        let controller = harness.makeController(maxAttempts: 2)
        controller.arm()
        controller.ingest(feed(settled: [stream("T1"), stream("T2"), stream("T3")]))
        await waitUntil { !harness.gaveUp.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["T1", "T2"])
        XCTAssertEqual(harness.gaveUp.first?.0, .allFailed)
        XCTAssertEqual(controller.attemptCap, 2)
    }

    /// (b) Try Another Source on Failure Off (cap 1): one attempt, then the list.
    func testSwitchOffMakesOneAttempt() async {
        let harness = Harness()
        harness.plans = ["T1": .fail]
        let controller = harness.makeController(maxAttempts: 1)
        controller.arm()
        controller.ingest(feed(settled: [stream("T1"), stream("T2")]))
        await waitUntil { !harness.gaveUp.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["T1"], "no second resolve with the switch off")
        XCTAssertEqual(harness.gaveUp.first?.0, .allFailed)
        XCTAssertFalse(controller.failover(afterFailureOf: stream("T1").playbackStreamKey, addonId: nil),
                       "an exhausted walk has nothing to continue")
    }

    /// The cap is read when the walk starts (2b.9): a later settings change does not move it.
    func testTheCapIsReadOnceWhenTheWalkStarts() async {
        let harness = Harness()
        var cap = 3
        let controller = harness.makeController(capProvider: { cap })
        controller.arm()
        cap = 1
        XCTAssertEqual(controller.attemptCap, 3)
    }

    /// (c) An Up Next episode's walk continues Up Next's count and skips what it tried.
    func testASeededWalkContinuesTheHandedOverBudget() async {
        let harness = Harness()
        let a = stream("a", direct: true), b = stream("b"), c = stream("c")
        let handedOver = PlayerSourceFallbackTried(keys: PlayerSourceFallbackTried.companion.None.including(stream: a).keys,
                                                   attempts: 1)
        let controller = harness.makeController(maxAttempts: 4, titleKey: "tt1:1:2")
        controller.seed(candidates: [a, b, c], alreadyTried: handedOver, playing: a)
        XCTAssertEqual(controller.phase, .done)
        XCTAssertTrue(controller.isFailoverWalk)
        XCTAssertEqual(controller.attemptsUsed, 2)
        XCTAssertTrue(controller.hasOpenCandidate())

        XCTAssertTrue(controller.failover(afterFailureOf: a.playbackStreamKey, addonId: a.addonId))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["b"])
        XCTAssertEqual(harness.played.map { $0.name }, ["b"])
        XCTAssertEqual(harness.played.first?.attempt, 3)
        XCTAssertEqual(harness.played.first?.failover, true)
        let tried = controller.fallbackTried
        XCTAssertEqual(tried.attempts, 2, "two further sources moved to for the episode")
        XCTAssertTrue(tried.contains(stream: a))
        XCTAssertTrue(tried.contains(stream: b))
        XCTAssertFalse(tried.contains(stream: c))

        // b fails too: c is the last attempt the budget allows (cap 4), then the walk gives up.
        XCTAssertTrue(controller.failover(afterFailureOf: b.playbackStreamKey, addonId: b.addonId))
        await waitUntil { harness.played.count == 2 }
        XCTAssertEqual(harness.played.last?.name, "c")
        XCTAssertEqual(harness.played.last?.attempt, 4)
        XCTAssertFalse(controller.hasOpenCandidate(), "the budget is spent")
        XCTAssertTrue(controller.failover(afterFailureOf: c.playbackStreamKey, addonId: c.addonId))
        XCTAssertEqual(harness.gaveUp.first?.0, .allFailed)
        XCTAssertEqual(harness.gaveUp.first?.1, true)
    }

    /// A seeded walk whose budget Up Next already spent has nothing open.
    func testASeededWalkWithItsBudgetSpentHasNoOpenCandidate() {
        let harness = Harness()
        let controller = harness.makeController(maxAttempts: 4)
        controller.seed(candidates: [stream("x"), stream("y")], alreadyTried: PlayerSourceFallbackTried(keys: [], attempts: 3),
                        playing: stream("w"))
        XCTAssertEqual(controller.attemptsUsed, 4)
        XCTAssertFalse(controller.hasOpenCandidate())
    }

    /// Only an idle controller is seeded (a second seed changes nothing).
    func testSeedOnlyAppliesToAnIdleController() {
        let harness = Harness()
        let controller = harness.makeController()
        controller.seed(candidates: [stream("x")], alreadyTried: PlayerSourceFallbackTried(keys: [], attempts: 0), playing: nil)
        controller.seed(candidates: [stream("y"), stream("z")], alreadyTried: PlayerSourceFallbackTried(keys: [], attempts: 2),
                        playing: nil)
        XCTAssertEqual(controller.candidates.map { $0.stream.name ?? "" }, ["x"])
        XCTAssertEqual(controller.attemptsUsed, 1)
    }

    /// (d) The start-up limit starts a failover; the slow source starting first drops it, and the
    /// late resolve neither plays nor gives up.
    func testTheSlowSourceStartingAbandonsTheLimitsFailover() async {
        let harness = Harness()
        harness.plans = ["NEXT": .hang]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("SLOW", direct: true), stream("NEXT")]))
        XCTAssertEqual(harness.played.map { $0.name }, ["SLOW"])
        XCTAssertTrue(controller.hasOpenCandidate())

        XCTAssertTrue(controller.failover(afterFailureOf: stream("SLOW", direct: true).playbackStreamKey,
                                          addonId: nil, reason: .startupLimit))
        await waitUntil { harness.resolveCalls == ["NEXT"] }
        XCTAssertEqual(controller.phase, .resolving(attempt: 2))

        controller.abandonFailover()
        XCTAssertEqual(controller.phase, .done)
        harness.releaseHung()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.played.map { $0.name }, ["SLOW"], "the late resolve is dropped")
        XCTAssertTrue(harness.gaveUp.isEmpty)
        XCTAssertNil(harness.rejectedByTitle["tt1"], "a start-up limit never remembers a link")
    }

    /// (d) The start-up limit's walk never ends the source it would replace: when nothing else can
    /// start it stands down silently and the slow source keeps loading.
    func testALimitWalkThatRunsOutStandsDownWithoutGivingUp() async {
        let harness = Harness()
        harness.plans = ["NEXT": .fail]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("SLOW", direct: true), stream("NEXT")]))

        XCTAssertTrue(controller.failover(afterFailureOf: stream("SLOW", direct: true).playbackStreamKey,
                                          addonId: nil, reason: .startupLimit))
        await waitUntil { controller.phase == .done && harness.resolveCalls == ["NEXT"] }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(harness.gaveUp.isEmpty, "the slow player is never closed by its limit")
        XCTAssertEqual(controller.phase, .done)
        XCTAssertFalse(controller.hasOpenCandidate())
        // The slow source then fails for real: the walk has nothing left and gives up.
        XCTAssertTrue(controller.failover(afterFailureOf: stream("SLOW", direct: true).playbackStreamKey, addonId: nil))
        XCTAssertEqual(harness.gaveUp.first?.0, .allFailed)
        XCTAssertEqual(harness.gaveUp.first?.1, true)
    }

    /// (e) A failure reported while a failover resolves starts nothing new; once the slow source
    /// has failed, running out gives up.
    func testAFailureDuringALimitFailoverStartsNothingAndRunningOutThenGivesUp() async {
        let harness = Harness()
        harness.plans = ["NEXT": .hang]
        let controller = harness.makeController(resolveDeadline: 0.1)
        controller.arm()
        controller.ingest(feed(settled: [stream("SLOW", direct: true), stream("NEXT")]))
        let slowKey = stream("SLOW", direct: true).playbackStreamKey

        XCTAssertTrue(controller.failover(afterFailureOf: slowKey, addonId: nil, reason: .startupLimit))
        await waitUntil { harness.resolveCalls == ["NEXT"] }
        XCTAssertTrue(controller.failover(afterFailureOf: slowKey, addonId: nil), "the duplicate is swallowed")
        XCTAssertTrue(controller.failover(afterFailureOf: slowKey, addonId: nil, reason: .startupLimit))
        XCTAssertEqual(harness.resolveCalls, ["NEXT"], "no second resolve")

        await waitUntil { !harness.gaveUp.isEmpty }   // NEXT's resolve deadline passes
        XCTAssertEqual(harness.gaveUp.first?.0, .allFailed)
        XCTAssertEqual(harness.gaveUp.first?.1, true)
        XCTAssertEqual(harness.played.map { $0.name }, ["SLOW"])
    }

    /// The limit asks first: no open candidate when the rest cannot play on this device.
    func testHasOpenCandidateSkipsWhatThisDeviceCannotResolve() {
        let harness = Harness()
        harness.unresolvable = ["P2P"]
        let controller = harness.makeController()
        XCTAssertFalse(controller.hasOpenCandidate(), "nothing before a walk")
        controller.arm()
        controller.ingest(feed(settled: [stream("A", direct: true), stream("P2P")]))
        XCTAssertEqual(controller.phase, .done)
        XCTAssertFalse(controller.hasOpenCandidate())
    }

    /// (f) An HTTP failure of an auto-picked debrid link: one cache-bypassing re-resolve; a new
    /// link plays without using an attempt; a second failure of that source moves on.
    func testAnExpiredDebridLinkIsRefreshedOnceBeforeTheWalkMovesOn() async {
        let harness = Harness()
        harness.freshPlans = ["D1": .newLink]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("D1"), stream("D2")]))
        await waitUntil { harness.played.count == 1 }
        let d1 = FirstPlayAutoPlayController.Candidate(stream: stream("D1"))
        XCTAssertFalse(controller.willRefreshBeforeMovingOn(streamKey: d1.streamKey),
                       "resolved in this walk less than a minute ago: fresh")
        harness.clock += 61
        XCTAssertTrue(controller.willRefreshBeforeMovingOn(streamKey: d1.streamKey))

        XCTAssertTrue(controller.failover(afterFailureOf: d1.streamKey, addonId: nil, refreshFirst: d1,
                                          failedURL: URL(string: "https://resolved.example/D1")))
        await waitUntil { harness.played.count == 2 }
        XCTAssertEqual(harness.freshCalls, ["D1"])
        XCTAssertEqual(harness.played.last?.name, "D1")
        XCTAssertEqual(harness.played.last?.attempt, 1, "a refresh does not count against Sources to Try")
        XCTAssertNil(harness.rejectedByTitle["tt1"])

        XCTAssertFalse(controller.willRefreshBeforeMovingOn(streamKey: d1.streamKey), "once per source")
        XCTAssertTrue(controller.failover(afterFailureOf: d1.streamKey, addonId: nil, refreshFirst: d1,
                                          failedURL: URL(string: "https://fresh.example/D1")))
        await waitUntil { harness.played.count == 3 }
        XCTAssertEqual(harness.freshCalls, ["D1"], "no second refresh")
        XCTAssertEqual(harness.played.last?.name, "D2")
        XCTAssertEqual(harness.played.last?.attempt, 2)
    }

    /// (f) A refresh that fails, or hands back the link that failed, remembers the source (the
    /// picker left that to this step) and moves on.
    func testARefreshThatDoesNotHelpRemembersTheSourceAndMovesOn() async {
        for plan in [Harness.FreshPlan.fail, .sameLink] {
            let harness = Harness()
            harness.freshPlans = ["D1": plan]
            let controller = harness.makeController()
            controller.arm()
            controller.ingest(feed(settled: [stream("D1"), stream("D2")]))
            await waitUntil { harness.played.count == 1 }
            harness.clock += 120
            let d1 = FirstPlayAutoPlayController.Candidate(stream: stream("D1"))

            XCTAssertTrue(controller.failover(afterFailureOf: d1.streamKey, addonId: nil, refreshFirst: d1,
                                              failedURL: URL(string: "https://resolved.example/D1")))
            await waitUntil { harness.played.count == 2 }
            XCTAssertEqual(harness.played.last?.name, "D2", "\(plan)")
            XCTAssertEqual(harness.rejectedByTitle["tt1"], [d1.streamKey], "\(plan)")
            XCTAssertEqual(harness.invalidated, ["D1"], "\(plan)")
        }
    }

    /// (g) After hash H from add-on X fails, X's other copies of H are skipped; Y's copy is not.
    func testOtherCopiesOfTheFailedTorrentFromItsAddonAreSkipped() async {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let harness = Harness()
        harness.plans = ["XH0": .fail]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("XH0", addon: "addon:x", torrentHash: hash, fileIdx: 0),
                                         stream("XH1", addon: "addon:x", torrentHash: hash, fileIdx: 1),
                                         stream("YH2", addon: "addon:y", torrentHash: hash, fileIdx: 2)]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["XH0", "YH2"])
        XCTAssertEqual(harness.played.map { $0.name }, ["YH2"])
    }

    /// The handed-over tried set is honoured by the pure policy too.
    func testOpenIndicesLeaveOutAHandedOverTriedSource() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        let a = stream("a"), b = stream("b")
        let candidates = [a, b].map(FirstPlayAutoPlayController.Candidate.init(stream:))
        XCTAssertEqual(Policy.openIndices(in: candidates, triedIndices: [], rejected: [],
                                          tried: PlayerSourceFallbackTried.companion.None.including(stream: a)), [1])
    }

    // MARK: - Review r1 (finding 4): the same torrent from another add-on is another source

    /// First play: after add-on X's copy of hash H fails, Y's copy of the same torrent AND file is
    /// still a candidate and X's other copy is skipped; a tried source is never picked again.
    /// Review r2: X's torrent stays failed for X for the whole walk, so X's other file does not
    /// come back after Y's copy fails too.
    func testFirstPlayKeepsTheSameTorrentFromAnotherAddon() async {
        let hash = "89abcdef0123456789abcdef0123456789abcdef"
        let harness = Harness()
        // Failures that are not the link's fault (a missing key): nothing goes into the 8-hour
        // link memory, so only the tried set decides.
        harness.plans = ["X0": .failNotLinkFault]
        let x0 = stream("X0", addon: "addon:x", torrentHash: hash, fileIdx: 0)
        let x1 = stream("X1", addon: "addon:x", torrentHash: hash, fileIdx: 1)
        let y0 = stream("Y0", addon: "addon:y", torrentHash: hash, fileIdx: 0)
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [x0, x1, y0, stream("Z", addon: "addon:z")]))
        await waitUntil { !harness.played.isEmpty }
        XCTAssertEqual(harness.resolveCalls, ["X0", "Y0"], "Y's copy of the same file; X's other copy skipped")
        XCTAssertEqual(harness.played.map { $0.name }, ["Y0"])

        // Y0 then fails in the player: neither tried source comes back.
        XCTAssertTrue(controller.failover(afterFailureOf: y0.playbackStreamKey, addonId: y0.addonId))
        await waitUntil { harness.played.count == 2 }
        XCTAssertEqual(harness.resolveCalls, ["X0", "Y0", "Z"])
        XCTAssertEqual(harness.played.last?.name, "Z")
        XCTAssertTrue(controller.fallbackTried.contains(stream: x0))
        XCTAssertTrue(controller.fallbackTried.contains(stream: y0))
    }

    /// The 8-hour link memory is a different rule and stays add-on-blind: a "not cached" answer is
    /// the debrid service's about that torrent and file, whoever listed it (`playbackStreamKey` is
    /// `hash#file`), so a remembered failure of X's copy still skips Y's copy.
    func testARememberedLinkFailureStillCoversEveryAddonsCopy() async {
        let hash = "89abcdef0123456789abcdef0123456789abcdef"
        let harness = Harness()
        harness.plans = ["X0": .fail]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("X0", addon: "addon:x", torrentHash: hash, fileIdx: 0),
                                         stream("Y0", addon: "addon:y", torrentHash: hash, fileIdx: 0),
                                         stream("Z", addon: "addon:z")]))
        await waitUntil { !harness.played.isEmpty }
        XCTAssertEqual(harness.resolveCalls, ["X0", "Z"])
        XCTAssertEqual(harness.rejectedByTitle["tt1"], [stream("X0", addon: "addon:x", torrentHash: hash, fileIdx: 0).playbackStreamKey])
    }

    /// The in-player episode walk, seeded with Up Next's set: add-on X's failed copy rules out X's
    /// other copy, not Y's copy of the same file; the seeded source itself is never picked.
    func testTheEpisodeWalkKeepsTheSameTorrentFromAnotherAddon() async {
        let hash = "89abcdef0123456789abcdef0123456789abcdef"
        let harness = Harness()
        let x0 = stream("X0", addon: "addon:x", torrentHash: hash, fileIdx: 0)
        let x1 = stream("X1", addon: "addon:x", torrentHash: hash, fileIdx: 1)
        let y0 = stream("Y0", addon: "addon:y", torrentHash: hash, fileIdx: 0)
        let controller = harness.makeController(titleKey: "tt1:1:2")
        controller.seed(candidates: [x0, x1, y0], alreadyTried: PlayerSourceFallbackTried.companion.None, playing: x0)
        XCTAssertTrue(controller.hasOpenCandidate())
        XCTAssertTrue(controller.failover(afterFailureOf: x0.playbackStreamKey, addonId: x0.addonId))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["Y0"])
        XCTAssertEqual(harness.played.map { $0.name }, ["Y0"])
        XCTAssertTrue(controller.fallbackTried.contains(stream: x0))
        XCTAssertTrue(controller.fallbackTried.contains(stream: y0))
        XCTAssertFalse(controller.fallbackTried.contains(stream: x1))
    }

    // MARK: - Review r2: a real failure marks its torrent failed for its add-on for the whole walk

    /// A's copy 1 of torrent H fails, then B's source fails: A's copy 2 of H is still never picked
    /// (the copy rule no longer forgets A once a later source failed).
    func testAFailedTorrentStaysFailedForItsAddonAfterALaterFailure() async {
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let harness = Harness()
        harness.plans = ["A1": .fail, "B": .fail]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A1", addon: "addon:a", torrentHash: hash, fileIdx: 0),
                                         stream("B", addon: "addon:b"),
                                         stream("A2", addon: "addon:a", torrentHash: hash, fileIdx: 1),
                                         stream("Z", addon: "addon:z")]))
        await waitUntil { !harness.played.isEmpty }
        XCTAssertEqual(harness.resolveCalls, ["A1", "B", "Z"])
        XCTAssertEqual(harness.played.map { $0.name }, ["Z"])
    }

    /// The same after a playback failure in the player (the failover path).
    func testAPlaybackFailureMarksItsTorrentFailedForTheWholeWalk() async {
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let harness = Harness()
        harness.plans = ["B": .fail]
        let a1 = stream("A1", addon: "addon:a", direct: true, torrentHash: hash, fileIdx: 0)
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [a1, stream("B", addon: "addon:b"),
                                         stream("A2", addon: "addon:a", torrentHash: hash, fileIdx: 1),
                                         stream("Z", addon: "addon:z")]))
        XCTAssertEqual(harness.played.map { $0.name }, ["A1"])
        XCTAssertTrue(controller.failover(afterFailureOf: a1.playbackStreamKey, addonId: a1.addonId))
        await waitUntil { harness.played.count == 2 }
        XCTAssertEqual(harness.resolveCalls, ["B", "Z"], "A2 is skipped although B failed after A1")
        XCTAssertEqual(harness.played.last?.name, "Z")
    }

    /// A start-up-limit move-on is not a failure: the slow torrent's other copy from the same
    /// add-on stays a candidate (and is next in rank order here).
    func testAStartupLimitMoveOnDoesNotMarkTheTorrentFailed() async {
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let harness = Harness()
        let a1 = stream("A1", addon: "addon:a", direct: true, torrentHash: hash, fileIdx: 0)
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [a1, stream("A2", addon: "addon:a", torrentHash: hash, fileIdx: 1),
                                         stream("Z", addon: "addon:z")]))
        XCTAssertTrue(controller.hasOpenCandidate())
        XCTAssertTrue(controller.failover(afterFailureOf: a1.playbackStreamKey, addonId: a1.addonId, reason: .startupLimit))
        await waitUntil { harness.played.count == 2 }
        XCTAssertEqual(harness.resolveCalls, ["A2"])
        XCTAssertEqual(harness.played.last?.name, "A2")
        XCTAssertTrue(controller.fallbackTried.contains(stream: a1), "still tried: never picked again")
    }

    // MARK: - Stage B review findings 4 and 5: slow is not failed, a later failure is recorded

    /// The start-up limit's precheck keeps the slow torrent's other file from the same add-on
    /// (the limit's own pick does too), so it does not answer "nothing left" wrongly.
    func testTheStartupLimitPrecheckKeepsTheSlowTorrentsOtherFiles() async {
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let harness = Harness()
        let a0 = stream("A0", addon: "addon:a", direct: true, torrentHash: hash, fileIdx: 0)
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [a0, stream("A1", addon: "addon:a", torrentHash: hash, fileIdx: 1)]))
        XCTAssertEqual(harness.played.map { $0.name }, ["A0"])
        XCTAssertTrue(controller.hasOpenCandidate(), "A1 is open: A0 is only slow")
        XCTAssertTrue(controller.failover(afterFailureOf: a0.playbackStreamKey, addonId: a0.addonId, reason: .startupLimit))
        await waitUntil { harness.played.count == 2 }
        XCTAssertEqual(harness.played.last?.name, "A1")
    }

    /// A times out, B resolves, then A really fails: A's torrent is now failed for its add-on, so
    /// when B fails too A's other file is skipped.
    func testAFailureDuringALimitWalkMarksTheTorrentFailed() async {
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let harness = Harness()
        harness.plans = ["B": .hang]
        let a0 = stream("A0", addon: "addon:a", direct: true, torrentHash: hash, fileIdx: 0)
        let controller = harness.makeController(resolveDeadline: 0.1)
        controller.arm()
        controller.ingest(feed(settled: [a0, stream("B", addon: "addon:b"),
                                         stream("A1", addon: "addon:a", torrentHash: hash, fileIdx: 1),
                                         stream("Z", addon: "addon:z")]))
        XCTAssertTrue(controller.failover(afterFailureOf: a0.playbackStreamKey, addonId: a0.addonId, reason: .startupLimit))
        await waitUntil { harness.resolveCalls == ["B"] }
        XCTAssertTrue(controller.failover(afterFailureOf: a0.playbackStreamKey, addonId: a0.addonId), "the duplicate is swallowed")
        await waitUntil { harness.played.count == 2 }           // B's deadline passes, the walk moves on
        XCTAssertEqual(harness.resolveCalls, ["B", "Z"], "A1 is skipped: A0's torrent failed")
        XCTAssertEqual(harness.played.last?.name, "Z")
        XCTAssertTrue(controller.fallbackTried.contains(stream: a0))
    }

    /// The same failure survives an interruption of B (the rolled-back tried set keeps it).
    func testAFailureDuringALimitWalkSurvivesAnInterruption() async {
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let harness = Harness()
        harness.plans = ["B": .hang]
        let a0 = stream("A0", addon: "addon:a", direct: true, torrentHash: hash, fileIdx: 0)
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [a0, stream("B", addon: "addon:b"),
                                         stream("A1", addon: "addon:a", torrentHash: hash, fileIdx: 1),
                                         stream("Z", addon: "addon:z")]))
        _ = controller.failover(afterFailureOf: a0.playbackStreamKey, addonId: a0.addonId, reason: .startupLimit)
        await waitUntil { harness.resolveCalls == ["B"] }
        _ = controller.failover(afterFailureOf: a0.playbackStreamKey, addonId: a0.addonId)
        controller.abandonFailover()                             // a viewer choice interrupts B
        harness.plans["B"] = .fail
        XCTAssertTrue(controller.failover(afterFailureOf: a0.playbackStreamKey, addonId: a0.addonId))
        await waitUntil { harness.played.count == 2 }
        XCTAssertEqual(harness.resolveCalls, ["B", "B", "Z"], "B is retried (it never ran), A1 stays skipped")
        harness.releaseHung()
    }

    // MARK: - Stage B review r6 finding 2: an in-flight copy of a torrent that just failed

    /// A0 is slow, the limit's walk resolves A1 (same torrent, same add-on: allowed while A0 was
    /// only slow), then A0 really fails: A1's resolve is dropped, its attempt returned, and the
    /// walk moves on; A1's late answer never plays.
    func testAnInFlightCopyOfANewlyFailedTorrentIsDroppedAndTheWalkMovesOn() async {
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let harness = Harness()
        harness.plans = ["A1": .hang]
        let a0 = stream("A0", addon: "addon:a", direct: true, torrentHash: hash, fileIdx: 0)
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [a0, stream("A1", addon: "addon:a", torrentHash: hash, fileIdx: 1),
                                         stream("Z", addon: "addon:z")]))
        XCTAssertTrue(controller.failover(afterFailureOf: a0.playbackStreamKey, addonId: a0.addonId, reason: .startupLimit))
        await waitUntil { harness.resolveCalls == ["A1"] }
        XCTAssertTrue(controller.failover(afterFailureOf: a0.playbackStreamKey, addonId: a0.addonId))
        await waitUntil { harness.played.count == 2 }
        XCTAssertEqual(harness.resolveCalls, ["A1", "Z"])
        XCTAssertEqual(harness.played.last?.name, "Z")
        XCTAssertEqual(harness.played.last?.attempt, 2, "A1's attempt was given back")
        harness.releaseHung()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.played.map { $0.name }, ["A0", "Z"], "A1's late answer never plays")
    }

    /// The pure check behind it (also applied to every resolve result before it is accepted).
    func testInFlightStillEligibleFollowsTheFailedTorrentMarker() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let a0 = stream("A0", addon: "addon:a", torrentHash: hash, fileIdx: 0)
        let a1 = FirstPlayAutoPlayController.Candidate(stream: stream("A1", addon: "addon:a", torrentHash: hash, fileIdx: 1))
        let b1 = FirstPlayAutoPlayController.Candidate(stream: stream("B1", addon: "addon:b", torrentHash: hash, fileIdx: 1))
        let slowOnly = PlayerSourceFallbackTried.companion.None.including(stream: a0)
        let failed = PlayerSourceFallbackTried.companion.None.includingFailed(stream: a0)
        XCTAssertTrue(Policy.inFlightStillEligible(a1, triedBefore: slowOnly), "slow is not failed")
        XCTAssertFalse(Policy.inFlightStillEligible(a1, triedBefore: failed))
        XCTAssertTrue(Policy.inFlightStillEligible(b1, triedBefore: failed), "another add-on's copy stays")
    }
}
