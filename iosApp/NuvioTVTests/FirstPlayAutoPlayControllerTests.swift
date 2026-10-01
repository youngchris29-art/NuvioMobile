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

    private func stream(_ name: String, addon: String = "addon:a", direct: Bool = false) -> StreamItem {
        StreamItem(
            name: name, title: nil, description: nil,
            url: direct ? "https://cdn.example.com/\(name).mkv" : nil,
            // Resolve candidates carry an info hash, so each gets its own `playbackStreamKey`.
            infoHash: direct ? nil : "hash-\(name)",
            fileIdx: nil, externalUrl: nil, sources: [], sourceName: nil,
            addonName: addon, addonId: addon, addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
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
        enum Plan { case succeed, fail, failNotLinkFault, hang }

        var plans: [String: Plan] = [:]
        var rejectedByTitle: [String: Set<String>] = [:]
        var cachedNames: Set<String> = []
        var cachedOnly = false
        var unresolvable: Set<String> = []
        private(set) var resolveCalls: [String] = []
        private(set) var invalidated: [String] = []
        private(set) var consumed = 0
        private(set) var events: [FirstPlayAutoPlayController.Event] = []
        private var hung: [CheckedContinuation<Void, Never>] = []
        private var cancellables: Set<AnyCancellable> = []

        @MainActor
        func makeController(resolveDeadline: TimeInterval = 5, searchDeadline: TimeInterval = 30) -> FirstPlayAutoPlayController {
            let deps = FirstPlayAutoPlayController.Dependencies(
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
                    }
                },
                resolveDeadline: resolveDeadline,
                searchDeadline: searchDeadline
            )
            let controller = FirstPlayAutoPlayController(titleKey: "tt1", dependencies: deps)
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

    func testSameAddonIsTriedFirstAfterAFailure() async {
        let harness = Harness()
        harness.plans = ["A1": .fail]
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A1", addon: "addon:a"), stream("B1", addon: "addon:b"),
                                         stream("A2", addon: "addon:a")]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.resolveCalls, ["A1", "A2"])
        XCTAssertEqual(harness.played.map { $0.name }, ["A2"])
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

    func testResolveDeadlineMovesOnAndIgnoresTheLateAnswer() async {
        let harness = Harness()
        harness.plans = ["SLOW": .hang]
        let controller = harness.makeController(resolveDeadline: 0.05)
        controller.arm()
        controller.ingest(feed(settled: [stream("SLOW"), stream("FAST")]))
        await waitUntil { !harness.played.isEmpty }

        XCTAssertEqual(harness.played.map { $0.name }, ["FAST"])
        XCTAssertEqual(harness.rejectedByTitle["tt1"], [stream("SLOW").playbackStreamKey])

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

    func testFailoverSwapsInTheSameAddonsNextLink() async {
        let harness = Harness()
        let controller = harness.makeController()
        controller.arm()
        controller.ingest(feed(settled: [stream("A1", addon: "addon:a", direct: true),
                                         stream("B1", addon: "addon:b", direct: true),
                                         stream("A2", addon: "addon:a", direct: true)]))
        let failedKey = stream("A1", addon: "addon:a", direct: true).playbackStreamKey

        XCTAssertTrue(controller.failover(afterFailureOf: failedKey, addonId: "addon:a"))
        XCTAssertEqual(harness.played.map { $0.name }, ["A1", "A2"])
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
        XCTAssertNotNil(Policy.overlayMessage(for: .resolving(attempt: 2)))
        XCTAssertNotEqual(Policy.overlayMessage(for: .resolving(attempt: 2)), Policy.overlayMessage(for: .searching))
        for phase: FirstPlayAutoPlayController.Phase in [.idle, .done, .cancelled, .exhausted] {
            XCTAssertNil(Policy.overlayMessage(for: phase))
        }
    }

    func testCachedDebridLinkNeedsPositiveCacheEvidenceOnTheActiveResolver() {
        typealias Policy = FirstPlayAutoPlayController.Policy
        let hints = StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                        filename: nil, proxyHeaders: nil)
        func item(url: String? = nil, infoHash: String? = nil, resolve: StreamClientResolve? = nil,
                  cache: StreamDebridCacheStatus? = nil) -> StreamItem {
            StreamItem(name: "S", title: nil, description: nil, url: url, infoHash: infoHash, fileIdx: nil,
                       externalUrl: nil, sources: [], sourceName: nil, addonName: "Add-on", addonId: "addon:x",
                       addonLogo: nil, streamType: nil, behaviorHints: hints, clientResolve: resolve,
                       debridCacheStatus: cache, externalSubtitles: [], badges: [])
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
}
