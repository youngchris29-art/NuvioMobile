import Foundation
import NuvioAether

/// Every request the Aether controller sends goes through exactly one of these (GitHub #29). Pure: no
/// UIKit, no UserDefaults, no engine. The controller calls it on every path and hands its output to
/// `runLoad` unchanged, the only caller of `session.load`.
///
/// - A fresh load (`startPlayback`) resolves the disk cache from inputs read once for the visit, after
///   awaiting the leftover cleanup's pending deletion (bounded; code review r5).
/// - The DV-interruption rebuild and Replay start from the session's `currentRequest`, so they keep
///   that load's cache snapshot and never read the setting again. A change in Settings applies at the
///   next fresh load (the next title or episode).
/// - The mpv handoff carries no cache: mpv gets a `PlaybackHandoff` and never reads the key.
///
/// Main-actor (the module default) only because `AetherReloadRequestPlan` is; nothing here touches state.
enum AetherLoadRequestFlow {
    /// The controller's base request (everything `makeLoadRequest` sets) plus the cache resolved from
    /// `inputs`. The base's own `diskCache` is replaced, never merged.
    static func fresh(base: AetherLoadRequest, inputs: AetherDiskCacheInputs) -> AetherLoadRequest {
        var r = base
        r.diskCache = AetherDiskCachePlan.resolve(inputs.choice, aetherOn: inputs.aetherOn,
                                                  freeBytes: inputs.freeBytes).cache
        #if DEBUG
        r.diskCache = AetherDiskCachePlan.applyingDebugHardLimit(r.diskCache, inputs.debugHardLimitBytes)
        #endif
        return r
    }

    /// What a fresh load built: the request, the inputs it read (the visit's snapshot for the log
    /// field), and whether the leftover cleanup finished before the read (false = the wait hit its bound).
    struct Fresh {
        let request: AetherLoadRequest
        let inputs: AetherDiskCacheInputs
        let cleanupFinished: Bool
    }

    /// The fresh load (code review r5): awaits `awaitCleanup` exactly once (the façade's bounded
    /// `AetherLeftoverCache.pendingDeletionFinished`, which suspends, never blocks), then reads the
    /// inputs through `readInputs` exactly once, so the free-space reading never counts leftovers still
    /// being deleted. A timed-out wait (false) proceeds with the reading as it is. Reloads never come
    /// here and never wait.
    static func fresh(base: AetherLoadRequest,
                      awaitCleanup: () async -> Bool,
                      readInputs: () -> AetherDiskCacheInputs) async -> Fresh {
        let finished = await awaitCleanup()
        let inputs = readInputs()
        return Fresh(request: fresh(base: base, inputs: inputs), inputs: inputs, cleanupFinished: finished)
    }

    /// The fresh load's start order (code review r6): the cleanup wait and the reading first, then,
    /// only while `isCurrent()` (not cancelled, handed off or torn down during the wait), the engine
    /// start watchdog and the load. The wait never counts against the watchdog, and a load dropped
    /// during the wait arms nothing and loads nothing. Returns nil when dropped.
    @discardableResult
    static func start(base: AetherLoadRequest,
                      awaitCleanup: () async -> Bool,
                      readInputs: () -> AetherDiskCacheInputs,
                      isCurrent: () -> Bool,
                      armWatchdog: () -> Void,
                      load: (Fresh) -> Void) async -> Fresh? {
        let built = await fresh(base: base, awaitCleanup: awaitCleanup, readInputs: readInputs)
        guard isCurrent() else { return nil }
        armWatchdog()
        load(built)
        return built
    }

    /// The DV-interruption rebuild and Replay: `AetherReloadRequestPlan.request(from: current, …)`.
    /// Takes no inputs: `diskCache` comes only from `current` (the snapshot). Always autoplays: after a
    /// paused fresh-load restore `current` carries `startPaused`, which belongs to that restore only
    /// (W5 r1: Play Again and the interruption rebuild must not come back paused).
    static func reload(from current: AetherLoadRequest, startSec: Double?, activeAudioID: Int?,
                       activeSubtitleID: Int?, subtitleDecided: Bool,
                       addedSubtitles: [AetherExternalSubtitle]) -> AetherLoadRequest {
        var r = AetherReloadRequestPlan.request(from: current, startSec: startSec, activeAudioID: activeAudioID,
                                                activeSubtitleID: activeSubtitleID, subtitleDecided: subtitleDecided,
                                                addedSubtitles: addedSubtitles)
        r.startPaused = false
        return r
    }

    /// Return from background, the fresh-load fallback (decision D): the engine refused to rebuild the
    /// torn-down session in place, so a fresh load of the visit's request at the authoritative position,
    /// mounted paused (decision A). Tracks come from the background snapshot (the teardown may publish
    /// empty lists while away), the delay and shaping from the live values read at background, and
    /// `diskCache` only from `current` (the visit's snapshot: never re-read, no cleanup wait; spec I8).
    static func restore(from current: AetherLoadRequest, atSec: Double, audioTrackID: Int?,
                        subtitleTrackID: Int?, subtitleDecided: Bool, liveAudioDelaySec: Double,
                        liveShaping: AetherAudioShaping,
                        addedSubtitles: [AetherExternalSubtitle]) -> AetherLoadRequest {
        var r = AetherReloadRequestPlan.request(from: current, startSec: atSec > 1 ? atSec : nil,
                                                activeAudioID: audioTrackID, activeSubtitleID: subtitleTrackID,
                                                subtitleDecided: subtitleDecided, addedSubtitles: addedSubtitles)
        r.startPaused = true
        r.audioDelaySec = liveAudioDelaySec
        r.audioShaping = liveShaping
        return r
    }

    /// The `diskCache=` field `logRequest` prints. `inputs` is the fresh load's snapshot (the same on its
    /// rebuild and Replay, so one visit logs one value); it only names why a request is Off.
    ///   `off`, `off(free unknown)`, `off(below 1 GB)`, or `shown:<G>GB,budget:<MB>,hard:<MB|->,window:<n>`
    /// (MB = 10⁶ bytes, G = the hard limit in 10⁹ bytes).
    static func cacheLogField(_ r: AetherLoadRequest, inputs: AetherDiskCacheInputs?) -> String {
        guard let c = r.diskCache else {
            guard let inputs, inputs.aetherOn, inputs.choice != .off else { return "off" }
            switch AetherDiskCachePlan.resolve(inputs.choice, aetherOn: true, freeBytes: inputs.freeBytes).label {
            case .unmeasured: return "off(free unknown)"
            case .notEnoughSpace: return "off(below 1 GB)"
            default: return "off"
            }
        }
        let perGB = Int(AetherDiskCachePlan.bytesPerGB)
        let shown: String
        if let hard = c.hardLimitBytes {
            shown = "\(hard / perGB)"
        } else if let inputs, let g = AetherDiskCachePlan.resolve(inputs.choice, aetherOn: inputs.aetherOn,
                                                                  freeBytes: inputs.freeBytes).shownGB {
            shown = "\(g)"
        } else {
            shown = "-"
        }
        let hard = c.hardLimitBytes.map { "\($0 / 1_000_000)" } ?? "-"
        return "shown:\(shown)GB,budget:\(c.budgetBytes / 1_000_000),hard:\(hard),window:\(c.forwardSegments)"
    }
}
