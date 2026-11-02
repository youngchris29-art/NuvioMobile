import AVFoundation
import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(tvOS)
import AVKit
#endif

/// The Aether façade: one engine per session, fork types only. It reports; it never decides a fallback
/// (the app's `AetherFailurePolicy` does). Every session that is created is `stop()`ed on exit, failure
/// and fallback; the deinit is only a backstop.
@MainActor
public final class AetherPlaybackSession: ObservableObject {
    public static var engineVersion: String { LiveEngine.version }
    /// Optional engine components this build carries (trait names: TrueHDObjectAudio, DTSXObjectAudio, ...).
    public static var builtInComponents: [String] { LiveEngine.builtInComponents }

    /// Installs the process-wide engine log sink once (see `AetherLog.install`).
    @discardableResult
    public static func installLog(_ sink: @escaping @Sendable (String) -> Void) -> Bool {
        AetherLog.install(sink)
    }

    /// `LoadOptions.matchContentEnabled` comes from the system, never from the fork's Match Content
    /// toggle: tvOS Settings > Video and Audio > Match Content. false sends HDR down the auto-tonemap path.
    #if canImport(UIKit)
    public static func systemMatchingEnabled(in window: UIWindow?) -> Bool {
        #if os(tvOS)
        guard let window else { return true }
        return window.avDisplayManager.isDisplayCriteriaMatchingEnabled
        #else
        return true
        #endif
    }
    #endif

    /// Activates the shared audio session off the main thread. Idempotent; the app already activates at
    /// launch and mpv re-asserts its own category in its setup, so this only guarantees the bare
    /// `AVPlayerLayer` host has an active session (contract 6). Failure is logged, never thrown: the engine
    /// publishes `audioSessionFailed` itself if it cannot play.
    public static func ensureAudioSessionActive() async {
        await Task.detached(priority: .userInitiated) {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                AetherLog.hostLine("[NuvioAether] AVAudioSession.setActive(true) failed: \(error)")
            }
        }.value
    }

    // MARK: Published state

    public let clock = AetherClock()
    @Published public private(set) var phase: AetherPhase = .idle
    /// Transport intent (`state == .paused`); the phase lags it on a live join.
    @Published public private(set) var isPaused = false
    /// Latched per load: true from the first frame until the next `load`.
    @Published public private(set) var firstFrameShown = false
    @Published public private(set) var diagnostics = AetherDiagnostics()
    @Published public private(set) var audioTracks: [AetherTrack] = []
    @Published public private(set) var subtitleTracks: [AetherTrack] = []
    @Published public private(set) var activeAudioID: Int?
    @Published public private(set) var activeSubtitleID: Int?
    /// Window: 300 s behind the playhead to the decode lead, on the `clock.sourceSec` axis.
    @Published public private(set) var cues: [AetherCue] = []
    @Published public private(set) var chapters: [AetherChapter] = []

    // MARK: Events (set before `load`, called on the main actor)

    /// Once per load generation. Also published as `phase = .failed`.
    public var onFailure: ((AetherFailure) -> Void)?
    /// Once per load generation.
    public var onEnded: (() -> Void)?
    /// The engine rebuilt on the software path. Not a failure.
    public var onEscalatedToSoftware: ((AetherEscalation) -> Void)?
    /// 401/403 mid-session (log only in Phase 1; a terminal `sourceRefused` follows if nothing renews).
    public var onAuthorizationRefused: ((Int) -> Void)?
    /// `diagnostics.audioDelivery` reached `.droppedNoPipeline`, once per load generation.
    public var onAudioDropped: (() -> Void)?

    // MARK: Private

    private var engine: EngineDriving
    private var ledger = AetherLoadLedger()
    private var stopped = false
    /// Bumped by every `load` entry and every `stop()`.
    private var loadTicket = 0
    private var subscription: AnyCancellable?
    private var lastRequest: AetherLoadRequest?
    private var registeredSecrets = Set<String>()
    private var escalations = 0
    private var endedFired = false
    private var audioDroppedFired = false
    private var highestSeekID: UInt64 = 0
    private var pendingSeeks: [Int: PendingSeek] = [:]
    private var nextSeekToken = 0

    private struct PendingSeek {
        var resolver: AetherSeekResolver
        var continuation: CheckedContinuation<AetherSeekOutcome, Never>?
        var timeout: Task<Void, Never>?
        /// Set when the session ends the seek (stop, failure, new load) while the engine call is in flight.
        var forced: AetherSeekOutcome?
    }

    public convenience init() throws {
        self.init(engine: try LiveEngine())
    }

    init(engine: EngineDriving) {
        self.engine = engine
    }

    isolated deinit {
        // Backstop only: the shared output book counts an unstopped engine as playing.
        if !stopped {
            engine.stop(resetDisplayCriteria: true, finalTeardown: true)
        }
        AetherLog.unregister(registeredSecrets)
    }

    // MARK: Surface

    public var surface: AnyView { engine.surface }

    public var aspect: AetherAspect {
        get { engine.aspect }
        set { engine.aspect = newValue }
    }

    // MARK: Lifecycle

    /// The request of the last `load`, for Replay and the DV-interruption rebuild (`starting(atSec:)`).
    public var currentRequest: AetherLoadRequest? { lastRequest }

    /// Starts a new load generation. Throws `AetherFailure` (deduplicated with the published failure) or
    /// `CancellationError`, which is never a failure: a newer `load`, a `stop()` or a cancelled Task.
    @discardableResult
    public func load(_ request: AetherLoadRequest) async throws -> AetherProbeSummary? {
        // The only suspension before the engine call, taken before the generation moves: a running
        // session keeps reporting into its own generation until the new one begins, and nothing of the old
        // session can land between `begin()` and `engine.load` (which supersedes it synchronously).
        // A newer `load` or a `stop()` during that await wins: this call unwinds as a superseded load.
        loadTicket += 1
        let ticket = loadTicket
        await Self.ensureAudioSessionActive()
        guard ticket == loadTicket, !Task.isCancelled else { throw CancellationError() }

        let generation = ledger.begin()
        let newSource = lastRequest?.url != request.url
        stopped = false
        lastRequest = request
        resetForLoad(newSource: newSource)
        attach()
        rotateSecrets(to: request.secretHeaderValues)

        do {
            return try await engine.load(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard ledger.isCurrent(generation) else { throw CancellationError() }
            let failure = (error as? AetherFailure)
                ?? AetherFailure.thrown(error, atSec: engine.clockSample.currentSec, beforeFirstFrame: !firstFrameShown)
            report(failure, generation: generation)
            throw ledger.reportedFailure ?? failure
        }
    }

    /// Session-preserving rebuild at the playhead (tracks and transport kept). No-op with no session.
    /// Not the DV-interruption rebuild: that is a fresh `load(currentRequest.starting(atSec:))`.
    public func reloadAtCurrentPosition() async throws {
        guard !stopped, lastRequest != nil else { return }
        let generation = ledger.generation
        do {
            try await engine.reloadAtCurrentPosition()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard ledger.isCurrent(generation) else { throw CancellationError() }
            let failure = (error as? AetherFailure)
                ?? AetherFailure.thrown(error, atSec: engine.clockSample.currentSec, beforeFirstFrame: !firstFrameShown)
            report(failure, generation: generation)
            throw ledger.reportedFailure ?? failure
        }
    }

    /// Idempotent until the next `load`. `handingOff: true` keeps the panel mode for mpv (no display
    /// criteria reset, so no bounce); every other exit resets it.
    public func stop(handingOff: Bool = false) {
        loadTicket += 1
        guard !stopped else { return }
        stopped = true
        ledger.end()
        subscription?.cancel()
        subscription = nil
        resolveAllPendingSeeks(.rejected(.noActiveSession))
        engine.stop(resetDisplayCriteria: !handingOff, finalTeardown: true)
        rotateSecrets(to: [])
        if phase != .idle { phase = .idle }
    }

    /// The host's start budget elapsed with no first frame: reported once through the same channel as an
    /// engine failure (`onFailure`, `phase = .failed`). No-op once a frame is up or a failure was reported.
    public func reportFirstFrameTimeout() {
        guard !stopped, !firstFrameShown, lastRequest != nil else { return }
        let failure = AetherFailure(kind: .firstFrameTimeout, message: "no first frame within the host's start budget",
                                    atSec: engine.clockSample.currentSec, beforeFirstFrame: true)
        report(failure, generation: ledger.generation)
    }

    // MARK: Transport

    public var canSeek: Bool { !stopped && phase != .ended && engine.canSeek }
    /// 2.0 for video, 3.0 audio-only (the engine's cap; `setRate` clamps).
    public var maxRate: Float { engine.maxRate }

    public func play() {
        guard !stopped, !phase.isTerminal else { return }
        engine.play()
    }

    public func pause() {
        guard !stopped, !phase.isTerminal else { return }
        engine.pause()
    }

    public func togglePause() {
        guard !stopped, !phase.isTerminal else { return }
        engine.togglePause()
    }

    /// Clamped to `maxRate` by the engine; 0 pauses.
    public func setRate(_ rate: Float) {
        guard !stopped, !phase.isTerminal else { return }
        engine.setRate(rate)
    }

    /// Seeks and reports how it ended, from the engine's seek events (its own `seek` returns Void).
    public func seek(toSec target: Double, exact: Bool) async -> AetherSeekOutcome {
        if let refused = AetherSeekResolver.precheck(targetSec: target, phase: phase,
                                                     hasSession: !stopped && lastRequest != nil) {
            return refused
        }
        let token = nextSeekToken
        nextSeekToken += 1
        pendingSeeks[token] = PendingSeek(resolver: AetherSeekResolver(requestedSec: target, afterID: highestSeekID,
                                                                       durationSec: clock.durationSec))
        await engine.seek(toSec: target, exact: exact)
        guard let pending = pendingSeeks[token] else { return .rejected(.noActiveSession) }
        if let outcome = pending.forced ?? pending.resolver.outcome {
            pendingSeeks[token] = nil
            return outcome
        }
        return await withCheckedContinuation { (c: CheckedContinuation<AetherSeekOutcome, Never>) in
            pendingSeeks[token]?.continuation = c
            pendingSeeks[token]?.timeout = Task { [weak self] in
                // The window runs from the call returning, but a seek stashed during a load returns at once
                // and is replayed when the session settles: the window restarts while the phase is `.loading`.
                repeat {
                    try? await Task.sleep(nanoseconds: UInt64(AetherSeekResolver.confirmationWindowSec * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                } while self?.phase == .loading
                self?.finishSeek(token, with: .unconfirmed)
            }
        }
    }

    // MARK: Tracks

    /// Session-preserving reload, about 0.5 to 1 s.
    public func selectAudio(id: Int) {
        guard !stopped else { return }
        engine.selectAudio(id: id)
    }

    public func selectSubtitle(id: Int) {
        guard !stopped else { return }
        engine.selectSubtitle(id: id)
    }

    public func clearSubtitle() {
        guard !stopped else { return }
        engine.clearSubtitle()
    }

    /// Overlay-only after load (declare sidecars in the request for rendition eligibility). nil after
    /// `stop()` (no session to add it to).
    @discardableResult
    public func addExternalSubtitle(_ subtitle: AetherExternalSubtitle) -> AetherTrack? {
        guard !stopped, lastRequest != nil else { return nil }
        let extra = AetherLoadRequest(url: subtitle.url, externalSubtitles: [subtitle]).secretHeaderValues
        rotateSecrets(to: registeredSecrets.union(extra))
        return engine.addExternalSubtitle(subtitle)
    }

    // MARK: Audio

    /// In force for this session; the engine clamps to +/-2 s.
    public var audioDelaySec: Double { engine.audioDelaySec }

    /// Re-anchors: a seek on `.software`, a ~0.3 s reload on `.loopback`. Presses during one fold.
    public func setAudioDelay(_ sec: Double) {
        guard !stopped else { return }
        engine.setAudioDelay(sec)
    }

    /// In force for this session, as clamped by the engine.
    public var audioShaping: AetherAudioShaping { engine.audioShaping }

    /// Boost and Dialogue lift. A session-preserving reload per change (folded); while active, stream
    /// copy (Atmos passthrough) is off.
    public func setAudioShaping(_ shaping: AetherAudioShaping) {
        guard !stopped else { return }
        engine.setAudioShaping(shaping.clamped)
    }

    // MARK: Stills

    /// False before load and on DV Profile 5 / AV1 P10.0: show time only.
    public var supportsScrubStills: Bool { !stopped && engine.supportsScrubStills }
    /// Changes when the source changes: fence late stills with it.
    public var scrubStillsSourceGeneration: UUID { engine.scrubStillsSourceGeneration }

    /// Reads only resident segments or the software packet cache: never seeks, never opens a second
    /// connection. nil when missing, cancelled or stale.
    public func scrubFrame(atSec: Double, refined: Bool, maxWidth: Int,
                           isCancelled: @escaping @Sendable () -> Bool) async -> AetherScrubFrame? {
        guard !stopped else { return nil }
        return await engine.scrubFrame(atSec: atSec, refined: refined, maxWidth: maxWidth, isCancelled: isCancelled)
    }

    // MARK: Headers

    /// Exposed, unused in Phase 1 (the fork has no renewal source). True when the live readers took it.
    @discardableResult
    public func updateRequestHeaders(_ headers: [String: String]) -> Bool {
        guard !stopped else { return false }
        if var r = lastRequest {
            r.headers = headers
            lastRequest = r
            // Keep the old values redacted too: lines about requests already in flight may still carry them.
            rotateSecrets(to: registeredSecrets.union(r.secretHeaderValues))
        }
        return engine.updateRequestHeaders(headers)
    }

    // MARK: Event handling

    private func attach() {
        guard subscription == nil else { return }
        subscription = engine.events.sink { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func resetForLoad(newSource: Bool) {
        resolveAllPendingSeeks(.superseded)
        endedFired = false
        audioDroppedFired = false
        escalations = 0
        if phase != .loading { phase = .loading }
        if firstFrameShown { firstFrameShown = false }
        if !cues.isEmpty { cues = [] }
        var d = diagnostics
        d.softwareEscalations = 0
        if d != diagnostics { diagnostics = d }
        if newSource {
            clock.reset()
            if !chapters.isEmpty { chapters = [] }
        }
    }

    func handle(_ event: EngineEvent) {
        guard !stopped else { return }
        switch event {
        case .state(let paused):
            if isPaused != paused { isPaused = paused }
        case .phase(let p):
            let next = AetherPhaseReducer.reduce(phase, engine: p)
            if next != phase { phase = next }
            if next == .ended, !endedFired {
                endedFired = true
                onEnded?()
            }
            if case .error(let message) = p {
                // `errorInfo` normally reported first; this covers an engine that published neither.
                report(AetherFailure(kind: .unknown("phaseError"), message: message,
                                     atSec: engine.clockSample.currentSec, beforeFirstFrame: !firstFrameShown),
                       generation: ledger.generation)
            }
        case .failure(let f):
            report(f, generation: ledger.generation)
        case .firstFrame(let v):
            if v, !firstFrameShown { firstFrameShown = true }
        case .clock(let sample):
            if phase != .ended { clock.apply(sample) }
        case .cues(let c):
            if cues != c { cues = c }
        case .chapters(let c):
            if chapters != c { chapters = c }
        case .diagnostics(var d):
            d.softwareEscalations = escalations
            if diagnostics != d { diagnostics = d }
        case .audioDelivery(let d):
            if d == .droppedNoPipeline, !audioDroppedFired {
                audioDroppedFired = true
                onAudioDropped?()
            }
        case .tracks(let audio, let subtitle, let activeAudio, let activeSubtitle):
            if audioTracks != audio { audioTracks = audio }
            if subtitleTracks != subtitle { subtitleTracks = subtitle }
            if activeAudioID != activeAudio { activeAudioID = activeAudio }
            if activeSubtitleID != activeSubtitle { activeSubtitleID = activeSubtitle }
        case .seek(let sample):
            highestSeekID = max(highestSeekID, sample.id)
            for token in pendingSeeks.keys.sorted() {
                guard var pending = pendingSeeks[token] else { continue }
                if let outcome = pending.resolver.consume(sample) {
                    pendingSeeks[token] = pending
                    if pending.continuation != nil { finishSeek(token, with: outcome) }
                } else {
                    pendingSeeks[token] = pending
                }
            }
        case .escalation(let e):
            escalations += 1
            var d = diagnostics
            d.softwareEscalations = escalations
            diagnostics = d
            onEscalatedToSoftware?(e)
        case .authorizationRefused(let status):
            onAuthorizationRefused?(status)
        }
    }

    private func report(_ failure: AetherFailure, generation: Int) {
        guard let emitted = ledger.report(failure, generation: generation) else { return }
        phase = .failed(emitted)
        resolveAllPendingSeeks(.rejected(.noActiveSession))
        onFailure?(emitted)
    }

    private func finishSeek(_ token: Int, with outcome: AetherSeekOutcome) {
        guard let pending = pendingSeeks.removeValue(forKey: token) else { return }
        pending.timeout?.cancel()
        pending.continuation?.resume(returning: outcome)
    }

    private func resolveAllPendingSeeks(_ outcome: AetherSeekOutcome) {
        for token in pendingSeeks.keys.sorted() {
            guard let pending = pendingSeeks[token] else { continue }
            if pending.continuation != nil {
                finishSeek(token, with: outcome)
            } else if pending.resolver.outcome == nil, pending.forced == nil {
                // The engine call has not returned yet: `seek` reads this when it does.
                pendingSeeks[token]?.forced = outcome
            }
        }
    }

    private func rotateSecrets(to next: Set<String>) {
        let added = next.subtracting(registeredSecrets)
        let removed = registeredSecrets.subtracting(next)
        AetherLog.register(added)
        AetherLog.unregister(removed)
        registeredSecrets = next
    }
}
