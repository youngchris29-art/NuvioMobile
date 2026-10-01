import Foundation
import SharedCore

/// Engine-agnostic watch-progress + Trakt scrobbling for a `PlaybackContext`. Mirrors the logic in
/// `MPVTVPlayerViewController` exactly so both engines record identically; the native AVPlayer path
/// (Phase 3) uses it. The mpv controller can be migrated onto this later — it still has its own copy
/// for now to avoid touching the shipping player. See docs/tvos-hybrid-player-plan.md.
@MainActor
final class PlaybackProgressRecorder {
    private let context: PlaybackContext

    init(context: PlaybackContext) { self.context = context }

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

    private lazy var session = Self.playbackSession(for: context)

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
            lastSourceUrl: context.url.absoluteString
        )
    }

    /// Record playback progress. `flush` forces an immediate write (use on teardown).
    func record(positionSec: Double, durationSec: Double, isPaused: Bool, speed: Double, flush: Bool) {
        guard durationSec > 0, positionSec > 1 else { return }
        let snapshot = PlayerPlaybackSnapshot(
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
        if flush {
            WatchProgressRepository.shared.flushPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        } else {
            WatchProgressRepository.shared.upsertPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        }
    }

    // MARK: - Trakt scrobbling

    private var traktItem: TraktScrobbleItem?
    private var traktRequested = false
    private var traktClosed = false

    func startTrakt(positionSec: Double, durationSec: Double) {
        guard !traktRequested else { return }
        // Error/placeholder clips (debrid cache-sync stubs, error videos) must not
        // open a Trakt session — mirrors the shared short-placeholder guard.
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000)) { return }
        traktRequested = true
        TraktScrobbleRepository.shared.buildItem(
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.title,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            releaseInfo: nil
        ) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, let item, !self.traktClosed else { return }
                self.traktItem = item
                TraktScrobbleRepository.shared.scrobbleStart(
                    profileId: ActiveProfileProvider.shared.activeProfileId,
                    item: item,
                    progressPercent: Self.percent(positionSec, durationSec)
                ) { _ in }
            }
        }
    }

    func stopTrakt(positionSec: Double, durationSec: Double) {
        traktClosed = true
        guard let item = traktItem else { return }
        traktItem = nil
        // A session can open before a placeholder's short duration is known; close
        // it at 0% so Trakt never marks the stub watched.
        let short = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000))
        TraktScrobbleRepository.shared.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            progressPercent: short ? 0 : Self.percent(positionSec, durationSec)
        ) { _ in }
    }

    private static func percent(_ positionSec: Double, _ durationSec: Double) -> Float {
        guard durationSec > 0 else { return 0 }
        return Float(min(100, max(0, positionSec / durationSec * 100)))
    }

    // MARK: - Other trackers (Simkl, MDBList)

    private lazy var trackerScrobble = TrackerScrobbleSession(context: context)

    /// Opens the non-Trakt tracker session alongside `startTrakt` — same trigger, same guard.
    func startTrackers(positionSec: Double, durationSec: Double) {
        trackerScrobble.start(positionSec: positionSec, durationSec: durationSec)
    }

    func stopTrackers(positionSec: Double, durationSec: Double) {
        trackerScrobble.stop(positionSec: positionSec, durationSec: durationSec)
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

    /// Progress for the closing `stop`: 0 for a clip that turned out to be a short placeholder
    /// (so no tracker marks the stub watched), else the clamped percentage — as the Trakt drivers.
    static func stopPercent(positionSec: Double, durationSec: Double) -> Double {
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: millis(durationSec)) { return 0 }
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
    private var sequencer = TrackerScrobbleSequencer()
    private var profileId: Int32 = 0
    private var media: TrackingMediaReference?
    private var recipients: [TrackingScrobbler] = []

    init(context: PlaybackContext) { self.context = context }

    func start(positionSec: Double, durationSec: Double) {
        guard TrackerScrobblePolicy.shouldOpen(durationSec: durationSec) else { return }
        guard sequencer.start() else { return }
        TrackingProviderRegistry.shared.ensureLoaded()
        let targets = TrackingProviderRegistry.shared.connectedScrobblers()
            .filter { TrackerScrobblePolicy.receivesFanout(storageId: $0.providerId.storageId) }
        guard !targets.isEmpty else { _ = sequencer.startCompleted(); return }
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
        self.media = media
        self.recipients = targets
        self.profileId = ActiveProfileProvider.shared.activeProfileId
        dispatch(.start, percent: TrackerScrobblePolicy.percent(positionSec: positionSec, durationSec: durationSec)) { [weak self] in
            Task { @MainActor in self?.startFinished() }
        }
    }

    private func startFinished() {
        if let percent = sequencer.startCompleted() {
            dispatch(.stop, percent: percent)
            media = nil
            recipients = []
        }
    }

    func stop(positionSec: Double, durationSec: Double) {
        let percent = TrackerScrobblePolicy.stopPercent(positionSec: positionSec, durationSec: durationSec)
        guard let now = sequencer.stop(percent: percent) else { return }
        guard media != nil, !recipients.isEmpty else { return }
        dispatch(.stop, percent: now)
        media = nil
        recipients = []
    }

    private func dispatch(_ action: TrackingScrobbleAction, percent: Double, completion: (@Sendable () -> Void)? = nil) {
        guard let media else { return }
        TrackingScrobbleCoordinatorKt.dispatchTrackingScrobble(
            scrobblers: recipients,
            profileId: profileId,
            action: action,
            event: TrackingScrobbleEvent(media: media, progressPercent: percent)
        ) { failures, _ in
            #if DEBUG
            for failure in failures ?? [] {
                print("[TrackerScrobble] \(failure.providerId.storageId) \(action.wireValue) failed: \(failure.cause)")
            }
            #endif
            completion?()
        }
    }
}
