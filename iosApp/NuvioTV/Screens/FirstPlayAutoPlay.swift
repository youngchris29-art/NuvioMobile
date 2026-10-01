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
                autoPlayLog("[AutoPlay] pick #\(attemptsUsed) direct key=\(candidate.streamKey)")
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
            autoPlayLog("[AutoPlay] pick #\(attemptsUsed) resolving key=\(candidate.streamKey)")
            beginResolve(candidate)
            return
        }
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
                outcome = .failed(reason: "resolve threw: \(error.localizedDescription)", rejectsLink: true)
            }
            self?.finishResolve(attemptGeneration, candidate, outcome)
        }
        let deadline = deps.resolveDeadline
        resolveTimeout?.cancel()
        resolveTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(deadline, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishResolve(attemptGeneration, candidate,
                                .failed(reason: "resolve timed out after \(Int(deadline)) s", rejectsLink: true))
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
            if rejectsLink {
                deps.reject(candidate.streamKey, titleKey)
                deps.invalidate(candidate.stream)
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

        /// A link the active debrid service already has cached: a direct-debrid result the add-on
        /// marks cached for the active resolver, or a torrent the cache check found cached on it.
        /// The Swift twin of the shared selector's private `isReadyDebridAutoPlay`, restricted to
        /// positive cache evidence. Plain HTTP links do not qualify (nothing says they are cached).
        static func isCachedDebridLink(_ stream: StreamItem, debridEnabled: Bool,
                                       activeResolverProviderId: String?) -> Bool {
            guard debridEnabled, stream.isAddonDebridCandidate else { return false }
            if stream.isDirectDebridStream {
                let service: String? = stream.clientResolve?.service
                return matchesResolver(service, activeResolverProviderId)
            }
            if stream.isCachedDebridTorrentStream {
                let provider: String? = stream.debridCacheStatus?.providerId
                return matchesResolver(provider, activeResolverProviderId)
            }
            return false
        }

        /// Shared `matchesResolver`: no active resolver, or no provider on the link, matches.
        static func matchesResolver(_ value: String?, _ activeResolverProviderId: String?) -> Bool {
            let active = (activeResolverProviderId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !active.isEmpty, let value else { return true }
            return value.caseInsensitiveCompare(active) == .orderedSame
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
            }
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

/// Full-screen "Finding the best source…" cover over the stream list while auto mode works.
/// Holds the only focusable element on screen (the list underneath is disabled), so Menu reaches
/// its `onExitCommand` — which cancels auto mode and reveals the list — instead of closing the
/// picker. The tvOS rule that every screen keeps something focusable is met by the status block.
struct FirstPlayAutoPlayOverlay: View {
    let title: String
    let logoUrl: String?
    let artworkUrl: String?
    let message: String
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.Palette.background
            if let artworkUrl, let url = URL(string: artworkUrl) {
                // `Color.clear` takes the screen's size; the filled artwork rides on it and is
                // clipped there, so its own (larger) size never stretches the stack.
                Color.clear
                    .overlay {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    }
                    .clipped()
                    .overlay(Color.black.opacity(0.65))
            }
            VStack(spacing: Theme.Spacing.lg) {
                TitleLogoHeader(title: title, logoUrl: logoUrl, alignment: .center)
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.vertical, Theme.Spacing.md)
                Text(message)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Spacing.screen)
            .frame(maxWidth: 1100)
            .focusable()
            .focused($focused)
            .onExitCommand(perform: onCancel)
        }
        .ignoresSafeArea()
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
