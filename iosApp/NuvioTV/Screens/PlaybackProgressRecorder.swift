import Foundation
import SharedCore

// MARK: - Identity (return from background, spec section 7)

extension PlaybackIdentity {
    /// Who is signed in and which profile is active, read now. The owner of a playback is this value
    /// taken once when it starts; every Aether and native write is compared against it.
    #if DEBUG
    /// spec-mpv-return §5.3 `debug.ownerFlip`: a leg's stand-in for a profile change.
    @MainActor static var debugOverride: PlaybackIdentity?
    #endif

    @MainActor
    static func current() -> PlaybackIdentity {
        #if DEBUG
        if let debugOverride { return debugOverride }
        #endif
        let account = (AuthRepository.shared.state.value_ as? AuthStateAuthenticated)?.userId ?? "signed-out"
        return PlaybackIdentity(accountKey: account, profileId: ActiveProfileProvider.shared.activeProfileId)
    }
}

// MARK: - Seams

/// What a player controller needs from its progress and tracker recorder. `PlaybackProgressRecorder`
/// is the only production conformer; tests inject fakes.
@MainActor
protocol PlaybackRecording: AnyObject {
    func pendingResumePercent() -> Double?
    func resumePositionSec(actualDurationSec: Double) -> Double?
    func record(positionSec: Double, durationSec: Double, isPaused: Bool, speed: Double, flush: Bool, isLive: Bool)
    func startTrakt(positionSec: Double, durationSec: Double)
    func stopTrakt(positionSec: Double, durationSec: Double, isLive: Bool)
    func startTrackers(positionSec: Double, durationSec: Double)
    func stopTrackers(positionSec: Double, durationSec: Double, isLive: Bool)
}

/// A Trakt scrobble item as the backend hands it over (opaque to the recorder).
final class TraktItemBox {
    let item: TraktScrobbleItem?
    init(_ item: TraktScrobbleItem?) { self.item = item }
}

/// A non-Trakt tracker session's recipients and media, as the backend opened them (opaque to the
/// recorder: `stop` goes to exactly the recipients `start` reached).
protocol TrackerScrobbleTargets: AnyObject {}

enum TrackerScrobbleDispatch: Sendable, Equatable { case start, stop }

/// Every write the recorder and its tracker session dispatch, in one place. The live backend calls the
/// shared repositories; tests replace it to hold completions and count dispatches.
@MainActor
protocol PlaybackRecorderBackend: AnyObject {
    func noteSessionProgress(profileId: Int32, item: TraktItemBox, percent: Float)
    func writeProgress(context: PlaybackContext, snapshot: PlayerPlaybackSnapshot, flush: Bool)
    func buildTraktItem(context: PlaybackContext, completion: @escaping @MainActor (TraktItemBox?) -> Void)
    func scrobbleStart(profileId: Int32, item: TraktItemBox, percent: Float)
    func scrobbleStop(profileId: Int32, item: TraktItemBox, percent: Float)
    /// The connected non-Trakt scrobblers for `context`, nil when there are none.
    func openTrackerTargets(context: PlaybackContext) -> TrackerScrobbleTargets?
    func dispatchTracker(_ action: TrackerScrobbleDispatch, targets: TrackerScrobbleTargets, profileId: Int32,
                         percent: Double, completion: (@MainActor () -> Void)?)
}

/// The shared repositories (today's behaviour).
@MainActor
final class LivePlaybackRecorderBackend: PlaybackRecorderBackend {
    private var progressSession: WatchProgressPlaybackSession?

    func noteSessionProgress(profileId: Int32, item: TraktItemBox, percent: Float) {
        guard let traktItem = item.item else { return }
        TraktScrobbleRepository.shared.noteSessionProgress(profileId: profileId, item: traktItem,
                                                           progressPercent: percent) { _, _ in }
    }

    func writeProgress(context: PlaybackContext, snapshot: PlayerPlaybackSnapshot, flush: Bool) {
        let session = progressSession ?? PlaybackProgressRecorder.playbackSession(for: context)
        progressSession = session
        if flush {
            WatchProgressRepository.shared.flushPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        } else {
            WatchProgressRepository.shared.upsertPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        }
    }

    func buildTraktItem(context: PlaybackContext, completion: @escaping @MainActor (TraktItemBox?) -> Void) {
        TraktScrobbleRepository.shared.buildItem(
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.title,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            releaseInfo: nil
        ) { item, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(item.map(TraktItemBox.init)) }
            }
        }
    }

    func scrobbleStart(profileId: Int32, item: TraktItemBox, percent: Float) {
        guard let traktItem = item.item else { return }
        TraktScrobbleRepository.shared.scrobbleStart(profileId: profileId, item: traktItem, progressPercent: percent) { _ in }
    }

    func scrobbleStop(profileId: Int32, item: TraktItemBox, percent: Float) {
        guard let traktItem = item.item else { return }
        TraktScrobbleRepository.shared.scrobbleStop(profileId: profileId, item: traktItem, progressPercent: percent) { _ in }
    }

    private final class LiveTargets: TrackerScrobbleTargets {
        let media: TrackingMediaReference
        let recipients: [TrackingScrobbler]
        init(media: TrackingMediaReference, recipients: [TrackingScrobbler]) {
            self.media = media
            self.recipients = recipients
        }
    }

    func openTrackerTargets(context: PlaybackContext) -> TrackerScrobbleTargets? {
        TrackingProviderRegistry.shared.ensureLoaded()
        let targets = TrackingProviderRegistry.shared.connectedScrobblers()
            .filter { TrackerScrobblePolicy.receivesFanout(storageId: $0.providerId.storageId) }
        guard !targets.isEmpty else { return nil }
        let media = TrackingMediaKt.buildTrackingMediaReference(
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.title,
            releaseInfo: nil,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil
        )
        return LiveTargets(media: media, recipients: targets)
    }

    func dispatchTracker(_ action: TrackerScrobbleDispatch, targets: TrackerScrobbleTargets, profileId: Int32,
                         percent: Double, completion: (@MainActor () -> Void)?) {
        guard let live = targets as? LiveTargets else { return }
        let wire: TrackingScrobbleAction = action == .start ? .start : .stop
        TrackingScrobbleCoordinatorKt.dispatchTrackingScrobble(
            scrobblers: live.recipients,
            profileId: profileId,
            action: wire,
            event: TrackingScrobbleEvent(media: live.media, progressPercent: percent)
        ) { failures, _ in
            #if DEBUG
            for failure in failures ?? [] {
                print("[TrackerScrobble] \(failure.providerId.storageId) \(wire.wireValue) failed: \(failure.cause)")
            }
            #endif
            if let completion {
                Task { @MainActor in completion() }
            }
        }
    }
}

/// spec-mpv-return code r3-3: tracker and Trakt operations across an mpv controller replacement. The
/// replaced controller holds the chain from `prepareForReplacement` until its stops have settled (the
/// chain retains what it hands in, so a stop deferred behind an in-flight start is not lost when that
/// controller goes); the fresh controller's starts run only once the chain is idle. So the held-position
/// stop always reaches the trackers before the next session's start (one stop per tracking session,
/// design r3). Owned by `PlayerScreen`.
@MainActor
final class TrackerReturnChain {
    private var holds: [Int: AnyObject?] = [:]
    private var nextID = 0
    private var waiters: [@MainActor () -> Void] = []

    var isIdle: Bool { holds.isEmpty }

    /// Holds the chain (keeping `retaining` alive) until the returned closure runs (once; later calls do nothing).
    func hold(_ retaining: AnyObject? = nil) -> @MainActor () -> Void {
        nextID += 1
        let id = nextID
        holds[id] = .some(retaining)
        return { [weak self] in self?.release(id) }
    }

    /// Runs `body` now when idle, else after the last hold is released (in order).
    func whenIdle(_ body: @escaping @MainActor () -> Void) {
        if holds.isEmpty { body() } else { waiters.append(body) }
    }

    private func release(_ id: Int) {
        guard holds.removeValue(forKey: id) != nil, holds.isEmpty else { return }
        let run = waiters
        waiters = []
        run.forEach { $0() }
    }
}

/// The identity check every dispatch point runs (section 7): true when the write may go out. A refusal
/// logs one line naming the site.
@MainActor
struct PlaybackWriteGate {
    let owner: PlaybackIdentity?
    let identity: @MainActor () -> PlaybackIdentity

    func allows(_ site: String) -> Bool {
        guard let owner else { return true }
        if PlaybackWriteGuard.allows(owner: owner, current: identity()) { return true }
        print("[Return] write refused: identity changed (\(site))")
        return false
    }
}

@MainActor
final class PlaybackProgressRecorder: PlaybackRecording {
    private let context: PlaybackContext
    private let gate: PlaybackWriteGate
    private let backend: PlaybackRecorderBackend
    private let identity: @MainActor () -> PlaybackIdentity

    /// `owner` nil = today's behaviour (no identity check). With an owner, every write is refused once the
    /// account or profile is no longer the owner's (return from background, spec section 7).
    init(context: PlaybackContext, owner: PlaybackIdentity? = nil,
         identity: @escaping @MainActor () -> PlaybackIdentity = { PlaybackIdentity.current() },
         backend: PlaybackRecorderBackend? = nil) {
        self.context = context
        self.identity = identity
        self.gate = PlaybackWriteGate(owner: owner, identity: identity)
        self.backend = backend ?? LivePlaybackRecorderBackend()
    }

    // MARK: - Resume

    /// Saved percentage (0-100) for a percentage-only entry (no stored position), else nil.
    /// Used when the item duration is not yet finite at `readyToPlay`. nil for "Start Over".
    func pendingResumePercent() -> Double? {
        Self.pendingResumePercent(startFromBeginning: context.startFromBeginning, entry: savedEntry())
    }

    /// Pure form of `pendingResumePercent()`. "Start Over" wins before the saved entry is read
    /// (`entry` is only evaluated when it is needed). Unit tested (`PlaybackProgressRecorderTests`).
    nonisolated static func pendingResumePercent(startFromBeginning: Bool,
                                                 entry: @autoclosure () -> WatchProgressEntry?) -> Double? {
        guard !startFromBeginning else { return nil }
        guard let entry = entry(), !entry.isCompleted, entry.lastPositionMs <= 0,
              entry.progressFraction > 0 else { return nil }
        return Double(entry.progressFraction) * 100
    }

    private func savedEntry() -> WatchProgressEntry? {
        WatchProgressRepository.shared.progressForVideo(
            videoId: context.videoId,
            parentMetaId: context.parentMetaId,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) }
        )
    }

    /// Saved resume position in seconds — only if >10s in and not completed (mirrors MPV's gate).
    /// `actualDurationSec` (item duration, when finite) lets percentage-only rows resolve.
    /// "Start Over" (`context.startFromBeginning`) ignores saved progress: always nil.
    func resumePositionSec(actualDurationSec: Double = 0) -> Double? {
        Self.resumePositionSec(startFromBeginning: context.startFromBeginning,
                               actualDurationSec: actualDurationSec, entry: savedEntry())
    }

    /// Pure form of `resumePositionSec(actualDurationSec:)`. "Start Over" wins before the saved
    /// entry is read (`entry` is only evaluated when it is needed). Unit tested
    /// (`PlaybackProgressRecorderTests`).
    nonisolated static func resumePositionSec(startFromBeginning: Bool, actualDurationSec: Double,
                                              entry: @autoclosure () -> WatchProgressEntry?) -> Double? {
        guard !startFromBeginning else { return nil }
        guard let entry = entry(), !entry.isCompleted else { return nil }
        let durationMs = actualDurationSec.isFinite && actualDurationSec > 0 ? Int64(actualDurationSec * 1000) : 0
        let seconds = Double(entry.resolveResumePosition(actualDurationMs: durationMs)) / 1000.0
        return seconds > 10 ? seconds : nil
    }

    // MARK: - Progress save

    /// The progress-write session for `context`. Also what the stream picker hands the shared
    /// external-player return (`ExternalPlaybackReturn.prepare`) for an Infuse launch, so a
    /// position Infuse reports back lands on the same progress entry the built-in player writes.
    static func playbackSession(for context: PlaybackContext) -> WatchProgressPlaybackSession {
        WatchProgressPlaybackSession(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            parentMetaType: context.contentType,
            videoId: context.videoId,
            title: context.title,
            logo: nil,
            poster: context.poster,
            background: context.background,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            episodeThumbnail: nil,
            providerName: context.providerName,
            providerAddonId: context.providerAddonId,
            lastStreamTitle: context.streamTitle,
            lastStreamSubtitle: context.streamSubtitle,
            pauseDescription: nil,
            lastSourceUrl: context.persistedSourceUrl
        )
    }

    /// Record playback progress. `flush` forces an immediate write (use on teardown). A live
    /// stream (`isLive`, from `LivePlaybackPolicy`) writes nothing.
    func record(positionSec: Double, durationSec: Double, isPaused: Bool, speed: Double, flush: Bool, isLive: Bool) {
        // BUG-231: keep the position as a provisional pending Trakt stop (throttled in the
        // outbox, nothing is sent), so a crash or force-quit still leaves one for the next launch.
        // Before the gate below on purpose: a live stream or a placeholder clip reports 0 here,
        // which makes the outbox drop what this session wrote.
        if let item = traktItem, gate.allows("noteSessionProgress") {
            backend.noteSessionProgress(
                profileId: ActiveProfileProvider.shared.activeProfileId,
                item: item,
                percent: Float(TrackerScrobblePolicy.stopPercent(positionSec: positionSec, durationSec: durationSec,
                                                                 isLive: isLive)))
        }
        guard let snapshot = Self.progressSnapshot(positionSec: positionSec, durationSec: durationSec,
                                                   isPaused: isPaused, speed: speed, isLive: isLive) else { return }
        guard gate.allows(flush ? "progress flush" : "progress write") else { return }
        backend.writeProgress(context: context, snapshot: snapshot, flush: flush)
    }

    /// Pure form of `record`'s gate and snapshot: nil when nothing may be written
    /// (`LivePlaybackPolicy.shouldSaveResume`). Unit tested (`PlaybackProgressRecorderTests`).
    nonisolated static func progressSnapshot(positionSec: Double, durationSec: Double, isPaused: Bool,
                                             speed: Double, isLive: Bool) -> PlayerPlaybackSnapshot? {
        guard LivePlaybackPolicy.shouldSaveResume(isLive: isLive, positionSec: positionSec,
                                                  durationSec: durationSec) else { return nil }
        return PlayerPlaybackSnapshot(
            isLoading: false,
            isPlaying: !isPaused,
            isEnded: false,
            durationMs: Int64(durationSec * 1000),
            positionMs: Int64(positionSec * 1000),
            bufferedPositionMs: Int64(positionSec * 1000),
            playbackSpeed: Float(speed),
            videoWidth: 0,
            videoHeight: 0
        )
    }

    // MARK: - Trakt scrobbling

    private var traktItem: TraktItemBox?
    private var traktRequested = false
    private var traktClosed = false

    func startTrakt(positionSec: Double, durationSec: Double) {
        guard !traktRequested else { return }
        // Error/placeholder clips (debrid cache-sync stubs, error videos) must not
        // open a Trakt session — mirrors the shared short-placeholder guard.
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000)) { return }
        guard gate.allows("startTrakt") else {
            traktClosed = true
            return
        }
        traktRequested = true
        backend.buildTraktItem(context: context) { [weak self] item in
            guard let self, let item, !self.traktClosed else { return }
            // The item is built asynchronously: the identity is checked again right before the start.
            guard self.gate.allows("scrobbleStart") else {
                self.traktClosed = true
                return
            }
            self.traktItem = item
            self.backend.scrobbleStart(profileId: ActiveProfileProvider.shared.activeProfileId, item: item,
                                       percent: Self.percent(positionSec, durationSec))
        }
    }

    func stopTrakt(positionSec: Double, durationSec: Double, isLive: Bool) {
        traktClosed = true
        guard let item = traktItem else { return }
        traktItem = nil
        guard gate.allows("scrobbleStop") else { return }
        // A session can open before a placeholder's short duration is known, or before the stream
        // reads live: close it at 0% so Trakt never marks the stub or the live stream watched.
        backend.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            percent: Float(TrackerScrobblePolicy.stopPercent(positionSec: positionSec, durationSec: durationSec,
                                                             isLive: isLive)))
    }

    private static func percent(_ positionSec: Double, _ durationSec: Double) -> Float {
        guard durationSec > 0 else { return 0 }
        return Float(min(100, max(0, positionSec / durationSec * 100)))
    }

    // MARK: - Other trackers (Simkl, MDBList)

    private lazy var trackerScrobble = TrackerScrobbleSession(context: context, owner: gate.owner,
                                                              identity: identity, backend: backend)

    /// Opens the non-Trakt tracker session alongside `startTrakt` — same trigger, same guard.
    func startTrackers(positionSec: Double, durationSec: Double) {
        trackerScrobble.start(positionSec: positionSec, durationSec: durationSec)
    }

    func stopTrackers(positionSec: Double, durationSec: Double, isLive: Bool) {
        trackerScrobble.stop(positionSec: positionSec, durationSec: durationSec, isLive: isLive)
    }
}

// MARK: - Tracker scrobble fan-out (Simkl, MDBList)

/// Pure decisions for the non-Trakt scrobble fan-out, kept free of player state so they are unit
/// tested (`TrackerScrobblePolicyTests`).
enum TrackerScrobblePolicy {
    /// Trakt is excluded: both engines already drive it through `TraktScrobbleRepository`'s own
    /// `buildItem`/`scrobbleStart`/`scrobbleStop` (addon-id → videoId fallback, episode mapping),
    /// and sending it the fan-out too would double-scrobble. Every other connected scrobbler
    /// (Simkl, MDBList, and any provider registered later) receives it.
    static func receivesFanout(storageId: String) -> Bool {
        storageId.caseInsensitiveCompare(TrackingProviderId.trakt.storageId) != .orderedSame
    }

    /// Same short-placeholder guard the Trakt drivers run before opening a session.
    static func shouldOpen(durationSec: Double) -> Bool {
        !WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: millis(durationSec))
    }

    /// Progress for the closing `stop`, Trakt included: 0 for a clip that turned out to be a short
    /// placeholder (so no tracker marks the stub watched) or a live stream (near the live edge it
    /// reads ~100 %, which every tracker would mark watched; `LivePlaybackPolicy`), else the
    /// clamped percentage.
    static func stopPercent(positionSec: Double, durationSec: Double, isLive: Bool) -> Double {
        if isLive || WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: millis(durationSec)) { return 0 }
        return percent(positionSec: positionSec, durationSec: durationSec)
    }

    static func percent(positionSec: Double, durationSec: Double) -> Double {
        guard durationSec.isFinite, durationSec > 0, positionSec.isFinite else { return 0 }
        return min(100, max(0, positionSec / durationSec * 100))
    }

    private static func millis(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 1000)
    }
}

/// Ordering rules for one tracker scrobble session, free of player and Kotlin types so they are
/// unit tested (`TrackerScrobbleSequencerTests`). `start` and `stop` are fire-and-forget on the
/// Kotlin side and Simkl's path is not serialized, so a stop issued while the start is still in
/// flight is deferred until the start completes: a stop can never overtake its start.
struct TrackerScrobbleSequencer {
    private(set) var requested = false
    private(set) var closed = false
    private(set) var startInFlight = false
    private(set) var pendingStop: Double?

    /// True when the caller should dispatch `start` now. Refused once stopped or already started.
    mutating func start() -> Bool {
        guard !requested, !closed else { return false }
        requested = true
        startInFlight = true
        return true
    }

    /// A percent to dispatch as `stop` now, or nil when nothing should go out yet (stop before any
    /// start, a repeated stop, or a stop deferred behind an in-flight start).
    mutating func stop(percent: Double) -> Double? {
        guard !closed else { return nil }
        closed = true
        guard requested else { return nil }
        if startInFlight {
            pendingStop = percent
            return nil
        }
        return percent
    }

    /// Called when the start dispatch completes; returns a deferred stop percent to dispatch now.
    mutating func startCompleted() -> Double? {
        startInFlight = false
        defer { pendingStop = nil }
        return pendingStop
    }
}

/// Start-once/stop-once scrobble session for every connected tracker except Trakt, dispatched
/// through the shared `dispatchTrackingScrobble` (the same fan-out `TrackingScrobbleCoordinator`
/// uses; the coordinator itself is not called because it would also hit Trakt). Before this,
/// tvOS playback reached Simkl and MDBList only through the local Continue Watching row, so a
/// title watched on the TV never updated those services. Mirrors the Trakt driver's lifecycle:
/// no session for a short placeholder, stop at 0% if one is detected late, and the providers that
/// received `start` are the ones that receive `stop`. Ordering guarantee: `stop` is never
/// dispatched before the `start` dispatch has completed; a stop that arrives while the start is in
/// flight is held and sent from the start's completion (`TrackerScrobbleSequencer`).
@MainActor
final class TrackerScrobbleSession {
    private let context: PlaybackContext
    private let gate: PlaybackWriteGate
    private let backend: PlaybackRecorderBackend
    private var sequencer = TrackerScrobbleSequencer()
    private var profileId: Int32 = 0
    private var targets: TrackerScrobbleTargets?

    /// `owner` nil (the mpv controller's use) = today's behaviour; with one, every dispatch is refused
    /// once the identity changed, and a refusal closes the session's local state.
    init(context: PlaybackContext, owner: PlaybackIdentity? = nil,
         identity: @escaping @MainActor () -> PlaybackIdentity = { PlaybackIdentity.current() },
         backend: PlaybackRecorderBackend? = nil) {
        self.context = context
        self.gate = PlaybackWriteGate(owner: owner, identity: identity)
        self.backend = backend ?? LivePlaybackRecorderBackend()
    }

    func start(positionSec: Double, durationSec: Double) {
        guard TrackerScrobblePolicy.shouldOpen(durationSec: durationSec) else { return }
        guard gate.allows("tracker start") else {
            _ = sequencer.stop(percent: 0)
            return
        }
        guard sequencer.start() else { return }
        guard let opened = backend.openTrackerTargets(context: context) else { _ = sequencer.startCompleted(); return }
        targets = opened
        profileId = ActiveProfileProvider.shared.activeProfileId
        dispatch(.start, percent: TrackerScrobblePolicy.percent(positionSec: positionSec, durationSec: durationSec)) { [weak self] in
            self?.startFinished()
        }
    }

    /// spec-mpv-return code r3-3: told once the stop has gone out and completed (or once there is
    /// nothing to send), so a replacement can start its own session strictly after it.
    private var stopSettled: (@MainActor () -> Void)?

    private func startFinished() {
        if let percent = sequencer.startCompleted() {
            // The deferred stop goes out after an await: the identity is checked again here.
            let settled = stopSettled
            stopSettled = nil
            if gate.allows("tracker deferred stop"), targets != nil {
                dispatch(.stop, percent: percent, completion: settled)
            } else {
                settled?()
            }
            targets = nil
        }
    }

    /// `settled`: called exactly once, after the stop dispatch completed, or at once when there is
    /// nothing to send; a stop deferred behind an in-flight start calls it from that start's
    /// completion (the caller keeps this session alive until then).
    func stop(positionSec: Double, durationSec: Double, isLive: Bool, settled: (@MainActor () -> Void)? = nil) {
        let percent = TrackerScrobblePolicy.stopPercent(positionSec: positionSec, durationSec: durationSec, isLive: isLive)
        guard let now = sequencer.stop(percent: percent) else {
            if sequencer.startInFlight, sequencer.pendingStop != nil, stopSettled == nil {
                stopSettled = settled
            } else {
                settled?()
            }
            return
        }
        guard targets != nil else { settled?(); return }
        if gate.allows("tracker stop") {
            dispatch(.stop, percent: now, completion: settled)
        } else {
            settled?()
        }
        targets = nil
    }

    private func dispatch(_ action: TrackerScrobbleDispatch, percent: Double, completion: (@MainActor () -> Void)? = nil) {
        guard let targets else { return }
        backend.dispatchTracker(action, targets: targets, profileId: profileId, percent: percent, completion: completion)
    }
}
