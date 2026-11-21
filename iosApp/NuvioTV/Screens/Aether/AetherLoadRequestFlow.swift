import Foundation
import NuvioAether

/// Every request the Aether controller sends goes through exactly one of these (GitHub #29). Pure: no
/// UIKit, no UserDefaults, no engine. The controller calls it on every path and hands its output to
/// `runLoad` unchanged, the only caller of `session.load`.
///
/// - A fresh load (`startPlayback`) resolves the disk cache from inputs read once for the visit.
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

    /// `fresh` with the inputs read through `readInputs` exactly once; returns what was read too, so
    /// the controller keeps it as the visit's snapshot for the log field.
    static func fresh(base: AetherLoadRequest,
                      readInputs: () -> AetherDiskCacheInputs) -> (request: AetherLoadRequest, inputs: AetherDiskCacheInputs) {
        let inputs = readInputs()
        return (fresh(base: base, inputs: inputs), inputs)
    }

    /// The DV-interruption rebuild and Replay: `AetherReloadRequestPlan.request(from: current, …)`.
    /// Takes no inputs: `diskCache` comes only from `current` (the snapshot).
    static func reload(from current: AetherLoadRequest, startSec: Double?, activeAudioID: Int?,
                       activeSubtitleID: Int?, subtitleDecided: Bool,
                       addedSubtitles: [AetherExternalSubtitle]) -> AetherLoadRequest {
        AetherReloadRequestPlan.request(from: current, startSec: startSec, activeAudioID: activeAudioID,
                                        activeSubtitleID: activeSubtitleID, subtitleDecided: subtitleDecided,
                                        addedSubtitles: addedSubtitles)
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
