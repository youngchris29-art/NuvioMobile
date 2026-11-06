import Combine
import Foundation
import SharedCore
import SwiftUI

/// The shared `StreamsRepository` auto-play fields for the picker's current request, published by
/// `StreamsViewModel` as one value so the controller sees them change together. Copied verbatim:
/// the picker's playability filter applies to the LIST only, never to these.
struct FirstPlayAutoPlayFeed: Equatable {
    var requestToken: String?
    var autoPlayStream: StreamItem?
    var autoPlayCandidates: [StreamItem]
    var isDirectAutoPlayFlow: Bool
    var isAnyLoading: Bool
    /// The request has produced something — addon groups (loading placeholders count) or an
    /// empty-state reason. False for the bare "request started" states the repository publishes
    /// on its way in (`StreamsUiState(requestToken)` and the tmdb→IMDb remap's loading state),
    /// which must not read as "the auto-play flow ended with nothing".
    var hasOutcome: Bool

    static var empty: FirstPlayAutoPlayFeed {
        FirstPlayAutoPlayFeed(
            requestToken: nil, autoPlayStream: nil, autoPlayCandidates: [],
            isDirectAutoPlayFlow: false, isAnyLoading: false, hasOutcome: false
        )
    }
}

/// First-play "Auto-Play Best Source" for the stream picker (orivio batch item 1), plus the
/// failover walk over the same candidates (item 2).
///
/// With `streamAutoPlayMode == FIRST_STREAM` and the picker not forced manual, the picker arms
/// this controller and loads with `manualSelection: false`; the shared repository then settles
/// the best candidate (`autoPlayStream`) and its ordered fallbacks (`autoPlayCandidates`). The
/// controller snapshots those, consumes them from the repository, applies the "Cached Sources
/// Only" setting and the recently-failed links (`RejectedStreamLinks`), and walks them — a direct
/// URL plays as is, a debrid candidate resolves first (20 s deadline) — until one opens the
/// player, at most `PlaybackFailoverPolicy.maxAutoAttempts` attempts per picker visit. A player
/// that then fails calls `failover(afterFailureOf:addonId:)` to continue the same walk, the failed
/// link's add-on first.
///
/// The controller decides; the picker acts on its `events`. Every dependency on SharedCore
/// singletons is a closure in `Dependencies`, so `FirstPlayAutoPlayControllerTests` drives the
/// walk with a fake resolver.
@MainActor
final class FirstPlayAutoPlayController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for the shared repository to settle a candidate.
        case searching
        /// Attempt `attempt` (1-based) is resolving through debrid.
        case resolving(attempt: Int)
        /// A candidate opened the player.
        case done
        /// The viewer pressed Menu on the overlay (or closed the player mid-failover).
        case cancelled
        /// Nothing could start: the picker shows the list.
        case exhausted
    }

    struct Candidate: Equatable {
        let stream: StreamItem
        let addonId: String
        /// `StreamItem.playbackStreamKey` of the stream as listed (before any debrid resolve).
        let streamKey: String

        init(stream: StreamItem) {
            self.stream = stream
            self.addonId = stream.addonId
            self.streamKey = stream.playbackStreamKey
        }
    }

    enum GiveUpReason: Equatable {
        /// The repository settled nothing playable, or every candidate was filtered out.
        case noCandidates
        /// Every candidate tried failed, or the attempt cap was reached.
        case allFailed
        /// The repository never settled within the search deadline.
        case searchTimedOut
    }

    enum Event {
        /// Open the player on `url` (the resolved stream). `attempt` is 1-based; `isFailover` means
        /// this replaces a player that failed (the picker swaps it in place). Which player opens is
        /// `Policy.startDestination`: a first play may go to the viewer's external default.
        case play(candidate: Candidate, resolved: StreamItem, url: URL, attempt: Int, isFailover: Bool)
        /// Stop auto mode and show the list.
        case gaveUp(GiveUpReason, duringFailover: Bool)
    }

    enum ResolveOutcome {
        case playable(StreamItem, URL)
        /// `rejectsLink` is false for failures that are not the link's fault (no debrid key, a link
        /// for a provider that is not the active one): the walk moves on without remembering it.
        case failed(reason: String, rejectsLink: Bool)
    }

    struct Dependencies {
        /// `StreamsRepository.requestToken(…, manualSelection: false)` for this title.
        var expectedToken: () -> String
        var consumeAutoPlay: () -> Void
        /// `PlayerSettingsUiState.streamAutoPlayCachedOnly`.
        var cachedOnly: () -> Bool
        var isCachedDebridLink: (StreamItem) -> Bool
        var rejected: (_ title: String) -> Set<String>
        var reject: (_ streamKey: String, _ title: String) -> Void
        var invalidate: (StreamItem) -> Void
        /// The stream's own playable URL, nil when it needs a resolve.
        var directURL: (StreamItem) -> URL?
        var canResolve: (StreamItem) -> Bool
        /// Main-actor bound: the Kotlin resolve is started from the main thread, as everywhere else.
        var resolve: @MainActor (StreamItem) async throws -> ResolveOutcome
        var resolveDeadline: TimeInterval = 20
        var searchDeadline: TimeInterval = 40
        /// The `[AutoPlay] pick` line's ranking facts for a candidate (`Policy.rankSummary`), so a
        /// device log shows why a link came first. Empty in tests unless a test sets it.
        var rankSummary: (StreamItem) -> String = { _ in "" }
        /// P4 (BUG-143, C-6): is there a usable network path? A failure while offline is never
        /// remembered against the link (live: `NetworkPathMonitor.shared.isSatisfied`).
        var networkSatisfied: () -> Bool = { true }
    }

    @Published private(set) var phase: Phase = .idle
    let events = PassthroughSubject<Event, Never>()

    /// `RejectedStreamLinks` title: the picker's `videoId`.
    let titleKey: String
    private let deps: Dependencies

    /// Snapshot of the eligible candidates, in the repository's order.
    private(set) var candidates: [Candidate] = []
    private(set) var attemptsUsed = 0
    private var triedIndices: Set<Int> = []
    private var triedKeys: Set<String> = []
    /// The repository has reported the direct auto-play flow on for this request.
    private var sawDirectFlow = false
    /// The walk continues after a failed playback (the open player is swapped in place).
    private(set) var isFailoverWalk = false
    /// Bumped on every settle and cancel: a resolve (or its deadline) from an older attempt is
    /// ignored when it lands.
    private var generation = 0
    private var searchTimeout: Task<Void, Never>?
    private var resolveTimeout: Task<Void, Never>?

    init(titleKey: String, dependencies: Dependencies) {
        self.titleKey = titleKey
        self.deps = dependencies
    }

    deinit {
        searchTimeout?.cancel()
        resolveTimeout?.cancel()
    }

    var isOverlayVisible: Bool { Policy.overlayMessage(for: phase) != nil }

    // MARK: - Lifecycle

    /// Start a visit's auto mode: the picker calls this once, before its first load.
    func arm() {
        guard phase == .idle else { return }
        phase = .searching
        autoPlayLog("[AutoPlay] armed title=\(titleKey)")
        let deadline = deps.searchDeadline
        searchTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(deadline, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == .searching else { return }
            autoPlayLog("[AutoPlay] no candidate settled within \(Int(deadline)) s — showing the list")
            self.giveUp(.searchTimedOut)
        }
    }

    /// Feed one `StreamsViewModel.autoPlayFeed` value. Acts only while searching.
    func ingest(_ feed: FirstPlayAutoPlayFeed) {
        guard phase == .searching else { return }
        let expected = deps.expectedToken()
        if feed.requestToken == expected, feed.isDirectAutoPlayFlow { sawDirectFlow = true }
        switch Policy.verdict(feed: feed, expectedToken: expected, sawDirectFlow: sawDirectFlow) {
        case .ignore, .wait:
            return
        case .showList:
            autoPlayLog("[AutoPlay] repository settled no candidate — showing the list")
            giveUp(.noCandidates)
        case .walk:
            let streams = Policy.snapshot(feed)
            deps.consumeAutoPlay()
            startWalk(streams.map(Candidate.init(stream:)))
        }
    }

    /// Menu on the overlay, or the viewer closed the player while a failover resolved. Only
    /// in-flight work is cancelled; a settled phase is left alone. `why` only feeds the log line.
    func cancel(why: String = "cancelled") {
        switch phase {
        case .searching, .resolving:
            let from = phase
            generation += 1
            searchTimeout?.cancel()
            resolveTimeout?.cancel()
            phase = .cancelled
            autoPlayLog("[AutoPlay] cancelled (\(why)) in \(from) after \(attemptsUsed) attempt(s): \(walkSummary())")
        default:
            return
        }
    }

    /// A player this controller started failed: try the next candidate, the failed link's add-on
    /// first. Returns false when there is no walk to continue (the picker then gives up itself).
    @discardableResult
    func failover(afterFailureOf streamKey: String, addonId: String?) -> Bool {
        guard phase == .done, !candidates.isEmpty else {
            autoPlayLog("[AutoPlay] failover requested in phase \(phase) — nothing to continue")
            return false
        }
        if !streamKey.isEmpty { triedKeys.insert(streamKey) }
        isFailoverWalk = true
        autoPlayLog("[AutoPlay] playback failed key=\(streamKey) — failover (\(attemptsUsed)/\(PlaybackFailoverPolicy.maxAutoAttempts) used)")
        tryNext(preferAddonId: addonId)
        return true
    }

    // MARK: - Walk

    private func startWalk(_ snapshot: [Candidate]) {
        searchTimeout?.cancel()
        let rejected = deps.rejected(titleKey)
        let cachedOnly = deps.cachedOnly()
        candidates = Policy.eligible(snapshot, cachedOnly: cachedOnly,
                                     isCachedDebridLink: deps.isCachedDebridLink, rejected: rejected)
        autoPlayLog("[AutoPlay] candidates=\(snapshot.count) eligible=\(candidates.count) cachedOnly=\(cachedOnly) rejected=\(rejected.count)")
        tryNext(preferAddonId: nil)
    }

    private func tryNext(preferAddonId: String?) {
        while true {
            guard attemptsUsed < PlaybackFailoverPolicy.maxAutoAttempts else {
                autoPlayLog("[AutoPlay] exhausted: attempt cap \(PlaybackFailoverPolicy.maxAutoAttempts) reached")
                giveUp(.allFailed)
                return
            }
            let rejected = deps.rejected(titleKey)
            guard let index = Policy.nextIndex(in: candidates, triedIndices: triedIndices, triedKeys: triedKeys,
                                               rejected: rejected, preferAddonId: preferAddonId) else {
                autoPlayLog("[AutoPlay] exhausted: no candidate left after \(attemptsUsed) attempt(s)")
                giveUp(attemptsUsed == 0 && !isFailoverWalk ? .noCandidates : .allFailed)
                return
            }
            let candidate = candidates[index]
            triedIndices.insert(index)
            if !candidate.streamKey.isEmpty { triedKeys.insert(candidate.streamKey) }

            if let url = deps.directURL(candidate.stream) {
                attemptsUsed += 1
                // Key only: the add-on id embeds the manifest URL, which can hold a debrid API key
                // (a URL key's first part already names the add-on, as a digest).
                autoPlayLog("[AutoPlay] pick #\(attemptsUsed) direct key=\(candidate.streamKey)\(rankSuffix(candidate))")
                succeed(candidate, resolved: candidate.stream, url: url)
                return
            }
            guard deps.canResolve(candidate.stream) else {
                // Not playable on this device (no debrid connection for it): skipped, not counted,
                // not remembered — the link itself is not at fault.
                autoPlayLog("[AutoPlay] skip key=\(candidate.streamKey): needs a resolve this device cannot do")
                continue
            }
            attemptsUsed += 1
            phase = .resolving(attempt: attemptsUsed)
            autoPlayLog("[AutoPlay] pick #\(attemptsUsed) resolving key=\(candidate.streamKey)\(rankSuffix(candidate))")
            beginResolve(candidate)
            return
        }
    }

    /// " res=… hdr=… cached=… size=…" for a pick line, or nothing when no rank facts are wired.
    private func rankSuffix(_ candidate: Candidate) -> String {
        let facts = deps.rankSummary(candidate.stream)
        return facts.isEmpty ? "" : " " + facts
    }

    private func beginResolve(_ candidate: Candidate) {
        generation += 1
        let attemptGeneration = generation
        let resolve = deps.resolve
        Task { [weak self] in
            let outcome: ResolveOutcome
            do {
                outcome = try await resolve(candidate.stream)
            } catch {
                // BUG-143: a network error thrown by the resolve is not the link's fault.
                let kind = PlaybackFailureClassifier.fromNSError(error, origin: .remote).kind
                outcome = .failed(reason: "resolve threw (\(kind.rawValue)): \(error.localizedDescription)",
                                  rejectsLink: kind.remembersLink)
            }
            self?.finishResolve(attemptGeneration, candidate, outcome)
        }
        let deadline = deps.resolveDeadline
        resolveTimeout?.cancel()
        resolveTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(deadline, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // BUG-143: a slow resolve is the debrid API or the network, not proof the link is dead.
            self?.finishResolve(attemptGeneration, candidate,
                                .failed(reason: "resolve timed out after \(Int(deadline)) s (transient=1 skipped)", rejectsLink: false))
        }
    }

    private func finishResolve(_ attemptGeneration: Int, _ candidate: Candidate, _ outcome: ResolveOutcome) {
        // A late result (the deadline already moved on, or the viewer cancelled) is ignored.
        guard attemptGeneration == generation, case .resolving = phase else { return }
        generation += 1
        resolveTimeout?.cancel()
        switch outcome {
        case let .playable(resolved, url):
            succeed(candidate, resolved: resolved, url: url)
        case let .failed(reason, rejectsLink):
            autoPlayLog("[AutoPlay] attempt #\(attemptsUsed) failed key=\(candidate.streamKey): \(reason)")
            if rejectsLink, deps.networkSatisfied() {
                deps.reject(candidate.streamKey, titleKey)
                deps.invalidate(candidate.stream)
            } else if rejectsLink {
                // C-6: every debrid provider maps its own exceptions to `Error()`, so an offline TV
                // would otherwise blacklist every cached link for 8 h.
                autoPlayLog("[AutoPlay] reject key=\(candidate.streamKey) transient=1 offline=1 skipped")
            }
            tryNext(preferAddonId: candidate.addonId)
        }
    }

    private func succeed(_ candidate: Candidate, resolved: StreamItem, url: URL) {
        searchTimeout?.cancel()
        resolveTimeout?.cancel()
        generation += 1
        phase = .done
        autoPlayLog("[AutoPlay] play attempt #\(attemptsUsed) key=\(candidate.streamKey) failover=\(isFailoverWalk)")
        events.send(.play(candidate: candidate, resolved: resolved, url: url,
                          attempt: attemptsUsed, isFailover: isFailoverWalk))
    }

    private func giveUp(_ reason: GiveUpReason) {
        searchTimeout?.cancel()
        resolveTimeout?.cancel()
        generation += 1
        phase = .exhausted
        autoPlayLog("[AutoPlay] give up (\(reason)) after \(attemptsUsed) attempt(s): \(walkSummary())")
        events.send(.gaveUp(reason, duringFailover: isFailoverWalk))
    }

    /// Why a walk ended, for the log: how many candidates were eligible and tried, how many of this
    /// title's links are remembered as failed, and whether the walk was continuing after a failed
    /// playback. Counts only, never a key or a link.
    private func walkSummary() -> String {
        "candidates=\(candidates.count) tried=\(triedIndices.count) rejected=\(deps.rejected(titleKey).count)"
            + " failover=\(isFailoverWalk)"
    }

    // MARK: - Policy (pure)

    enum Policy {
        enum Verdict: Equatable {
            /// Not this title's auto-play request (stale state, a manual load).
            case ignore
            /// The repository has not settled yet.
            case wait
            /// A candidate settled: snapshot and walk.
            case walk
            /// The flow ended with no candidate: show the list.
            case showList
        }

        /// Only the auto-play request's own state counts (token match). "Show the list" when the
        /// direct flow is off with no candidate, the request has produced something, and either
        /// nothing is loading or the flow was on before (it settled with nothing while slower
        /// add-ons still fetch). The bare request-start states have no outcome yet and wait.
        static func verdict(feed: FirstPlayAutoPlayFeed, expectedToken: String, sawDirectFlow: Bool) -> Verdict {
            guard let token = feed.requestToken, token == expectedToken else { return .ignore }
            if feed.autoPlayStream != nil { return .walk }
            if !feed.isDirectAutoPlayFlow, feed.hasOutcome, !feed.isAnyLoading || sawDirectFlow {
                return .showList
            }
            return .wait
        }

        /// The settled candidates in the repository's order, the settled stream first.
        static func snapshot(_ feed: FirstPlayAutoPlayFeed) -> [StreamItem] {
            var streams = feed.autoPlayCandidates
            if let first = feed.autoPlayStream, !streams.contains(first) {
                streams.insert(first, at: 0)
            }
            return streams
        }

        /// "Cached Sources Only" keeps debrid-cached links only; recently failed links are dropped.
        static func eligible(_ candidates: [Candidate], cachedOnly: Bool,
                             isCachedDebridLink: (StreamItem) -> Bool, rejected: Set<String>) -> [Candidate] {
            candidates.filter { candidate in
                if !candidate.streamKey.isEmpty, rejected.contains(candidate.streamKey) { return false }
                if cachedOnly, !isCachedDebridLink(candidate.stream) { return false }
                return true
            }
        }

        /// The next candidate to try: the first untried, non-rejected one from `preferAddonId`
        /// (the add-on whose link just failed), else the first untried, non-rejected one — the
        /// head of a stable same-add-on-first partition of what is left. A key already tried this
        /// visit (the same torrent listed twice) is not tried again.
        static func nextIndex(in candidates: [Candidate], triedIndices: Set<Int>, triedKeys: Set<String>,
                              rejected: Set<String>, preferAddonId: String?) -> Int? {
            let open = candidates.indices.filter { index in
                guard !triedIndices.contains(index) else { return false }
                let key = candidates[index].streamKey
                return key.isEmpty || (!triedKeys.contains(key) && !rejected.contains(key))
            }
            if let preferAddonId, let same = open.first(where: { candidates[$0].addonId == preferAddonId }) {
                return same
            }
            return open.first
        }

        /// A link the active debrid service already has cached: a direct-debrid result or a
        /// cache-checked torrent on the active resolver, or an add-on's resolved http link it marks
        /// cached for that service ("[TB+]", a bolt). The shared selector owns the rule, so this
        /// walk, the Best Source card and Settings → Sources → Cached Sources Only agree. Unmarked
        /// plain HTTP links do not qualify (nothing says they are cached).
        static func isCachedDebridLink(_ stream: StreamItem, debridEnabled: Bool,
                                       activeResolverProviderId: String?) -> Bool {
            StreamAutoPlaySelector.shared.isCachedDebridLink(
                stream: stream, debridEnabled: debridEnabled, activeResolverProviderId: activeResolverProviderId
            )
        }

        /// Where an auto pick plays (`Event.play`).
        enum StartDestination: Equatable {
            case builtIn
            case external(playerId: String)
        }

        /// The first start of a visit follows the viewer's default player, as Select on a row does:
        /// an external default (`defaultExternalPlayerId`, the validated installed one) gets the
        /// handoff. A failover always stays on the built-in player: an external player reports no
        /// failure back, so a walk handed to one could never continue.
        static func startDestination(isFailover: Bool, defaultExternalPlayerId: String?) -> StartDestination {
            guard !isFailover, let playerId = defaultExternalPlayerId, !playerId.isEmpty else { return .builtIn }
            return .external(playerId: playerId)
        }

        /// `res=2160 hdr=1 cached=1 size=58.2GB`: the four `StreamQualityRank.Key` fields in rank
        /// order (`hdr` covers every HDR flavour and Dolby Vision, one tier). An unknown resolution or
        /// size prints `-`. Facts only, nothing that names the link.
        static func rankSummary(resolution: Int32, dynamicRange: Int32, cached: Int32, size: Int64) -> String {
            let res = resolution > 0 ? String(resolution) : "-"
            let gb = size > 0 ? String(format: "%.1fGB", Double(size) / 1_000_000_000) : "-"
            return "res=\(res) hdr=\(dynamicRange) cached=\(cached) size=\(gb)"
        }

        /// Overlay text for a phase; nil hides the overlay.
        static func overlayMessage(for phase: Phase) -> String? {
            switch phase {
            case .searching, .resolving(attempt: 1):
                return String(localized: "Finding the best source\u{2026}")
            case let .resolving(attempt):
                let cap = PlaybackFailoverPolicy.maxAutoAttempts
                return String(localized: "Trying another source (\(attempt) of \(cap))\u{2026}")
            case .idle, .done, .cancelled, .exhausted:
                return nil
            }
        }
    }
}

// MARK: - Live dependencies

extension FirstPlayAutoPlayController.Dependencies {
    /// The SharedCore-backed dependencies for one picker visit.
    static func live(type: String, videoId: String, season: Int?, episode: Int?) -> Self {
        let kotlinSeason = season.map { KotlinInt(int: Int32($0)) }
        let kotlinEpisode = episode.map { KotlinInt(int: Int32($0)) }
        return Self(
            expectedToken: {
                StreamsRepository.shared.requestToken(
                    type: type, videoId: videoId, season: kotlinSeason, episode: kotlinEpisode,
                    manualSelection: false
                )
            },
            consumeAutoPlay: { StreamsRepository.shared.consumeAutoPlay() },
            cachedOnly: {
                PlayerSettingsRepository.shared.ensureLoaded()
                let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState
                return settings?.streamAutoPlayCachedOnly ?? false
            },
            isCachedDebridLink: { stream in
                let debrid = DebridSettingsRepository.shared.snapshot()
                let active: String? = debrid.activeResolverProviderId
                return FirstPlayAutoPlayController.Policy.isCachedDebridLink(
                    stream, debridEnabled: debrid.canResolvePlayableLinks, activeResolverProviderId: active
                )
            },
            rejected: { RejectedStreamLinks.rejected(for: $0) },
            reject: { RejectedStreamLinks.reject($0, title: $1) },
            invalidate: { stream in
                guard stream.isAddonDebridCandidate else { return }
                DirectDebridPlaybackResolver.shared.invalidate(stream: stream, season: kotlinSeason, episode: kotlinEpisode)
            },
            // Batch D U2: a ytId-only stream (`youTubeIdToResolve`) has neither a direct URL nor a
            // debrid resolve, so the walk skips it by construction — on purpose: auto-play never
            // spends seconds extracting a YouTube link that expires within hours. The shared
            // `autoPlayCandidates` selector excludes it the same way; only a viewer's pick resolves it.
            directURL: { stream in
                let direct: String? = stream.playableDirectUrl
                guard let direct, !direct.isEmpty else { return nil }
                return URL(string: direct)
            },
            canResolve: { DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: $0) },
            resolve: { stream in
                let result = try await DirectDebridPlaybackResolver.shared.resolveToPlayableStreamChecked(
                    stream: stream, season: kotlinSeason, episode: kotlinEpisode
                )
                return FirstPlayAutoPlayController.outcome(from: result)
            },
            rankSummary: { stream in
                let active: String? = DebridSettingsRepository.shared.snapshot().activeResolverProviderId
                let key = StreamQualityRank.shared.key(stream: stream, activeResolverProviderId: active)
                return FirstPlayAutoPlayController.Policy.rankSummary(
                    resolution: key.resolution, dynamicRange: key.dynamicRange, cached: key.cached, size: key.size
                )
            },
            networkSatisfied: { NetworkPathMonitor.shared.isSatisfied }
        )
    }
}

extension FirstPlayAutoPlayController {
    /// Maps the shared resolve result. Not-cached and provider errors are the link's fault and are
    /// remembered; a missing key or a link for another provider (`Stale`) is skipped without that.
    nonisolated static func outcome(from result: DirectDebridPlayableResult) -> ResolveOutcome {
        if let success = result as? DirectDebridPlayableResult.Success {
            let resolved: String? = success.stream.playableDirectUrl
            if let resolved, !resolved.isEmpty, let url = URL(string: resolved) {
                return .playable(success.stream, url)
            }
            return .failed(reason: "resolved without a playable link", rejectsLink: true)
        }
        switch result {
        case is DirectDebridPlayableResult.NotCached:
            return .failed(reason: "not cached", rejectsLink: true)
        case let error as DirectDebridPlayableResult.Error:
            let message: String? = error.message
            return .failed(reason: message ?? "resolve error", rejectsLink: true)
        case is DirectDebridPlayableResult.MissingApiKey:
            return .failed(reason: "missing debrid API key", rejectsLink: false)
        case is DirectDebridPlayableResult.Stale:
            return .failed(reason: "link is for another debrid provider", rejectsLink: false)
        default:
            return .failed(reason: "unknown resolve result", rejectsLink: true)
        }
    }
}

// MARK: - Overlay

/// Full-screen cover over the stream list while auto mode works, while the auto pick's player is
/// being presented, and while the picker closes after a player (BUG-174/183).
///
/// BUG-183 (Steven rc7): it is the player's own loading screen (`PlayerLoadingOverlay`: black, the
/// pulsing title logo, the episode line), drawn from the picker's first frame when auto mode is on,
/// so picker → player reads as one screen and the list never flashes. D2: the "Finding the best
/// source…" text is no longer drawn; it stays the cover's accessibility label (the UI legs read it).
///
/// Holds the only focusable element on screen (the list underneath is disabled), so Menu reaches
/// its `onExitCommand` — which cancels auto mode and reveals the list — instead of closing the
/// picker. `onCancel` nil (the cover held over a player, or over the close) swallows Menu.
struct FirstPlayAutoPlayOverlay: View {
    let title: String
    let parentMetaId: String
    /// BUG-184: the picker's (localized) title logo.
    let logoUrl: String?
    let episodeLine: String?
    /// The playback's video id: the shared pulse clock's key (BUG-182).
    let pulseKey: String
    /// "Finding the best source…" / "Trying another source (n of m)…", spoken only; nil while held.
    let message: String?
    let onCancel: (() -> Void)?
    /// BUG-185 (Steven rc9, D6): false for the hold while the picker closes after a player — the
    /// title logo is for starts only, so the close draws plain black. Still focusable (BUG-47: the
    /// cover must hold focus so Menu never reaches the list or closes the picker twice).
    var showsLogo = true

    /// beta.19-rc1 verdict (review r2, P3-1): the title logo decode the stream picker's header uses
    /// (`StreamPickerView`: `.points(width: 600, height: 120)`, `upgrade: .logo`). The cover draws
    /// metahub's logo like the player's overlay now (BUG-183, one look across the swap); the size
    /// stays the header's contract, which `ArtworkMemoryTests` pins.
    static let logoDecodeSize: ArtworkDecodeSize = .points(width: 600, height: 120)

    @FocusState private var focused: Bool
    /// Settings › Playback › Loading Screen: off, the players draw the plain spinner, so the cover
    /// does too (the same screen either way).
    @State private var loadingLookOn = PlayerLoadingOverlaySetting.enabled

    var body: some View {
        Group {
            if !showsLogo {
                Color.black
                    .ignoresSafeArea()
                    .focusable()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(title))
                    .accessibilityIdentifier("streamPicker.closeHold")
            } else if loadingLookOn {
                PlayerLoadingOverlay(
                    title: title,
                    parentMetaId: parentMetaId,
                    logoUrl: logoUrl,
                    background: nil,
                    episodeLine: episodeLine,
                    pulseKey: pulseKey,
                    takesFocus: true,
                    accessibilityID: "streamPicker.loadingCover",
                    accessibilityText: message,
                    pulsePaused: false
                )
            } else {
                PlayerLoadingSpinner()
                    .focusable()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(message ?? title))
                    .accessibilityIdentifier("streamPicker.loadingCover")
            }
        }
        .focused($focused)
        .onExitCommand { onCancel?() }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// `[AutoPlay]` decision lines go through NSLog (as `%@`, so interpolated text is never a format
/// string) rather than `print`: the unified log is what `log show` / `devicectl --console` and a
/// post-hoc device read can see, and `print` never reaches it. The lines carry keys, counts and
/// reasons only — never a URL, label or add-on id (see PlaybackStreamKey).
func autoPlayLog(_ line: String) {
    NSLog("%@", line)
}
