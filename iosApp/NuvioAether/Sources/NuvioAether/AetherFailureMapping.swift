import Foundation

// Pure failure and seek logic: no engine import, so NuvioTVTests and the package tests drive it directly.
// The session only wires engine events into these types; the app's AetherFailurePolicy decides what a
// failure means (fallback, retry, failover).

// MARK: - Failure kind

/// The engine's `PlaybackErrorKind` (22 tokens in 7.54.0) plus two façade cases. Classify on this, never
/// on `AetherFailure.message`.
public enum AetherFailureKind: Sendable, Equatable, Hashable {
    case sourceOpenFailed, sourceRefused, sourceCertificateRejected, customSourceProbeFailed
    case hlsFormatUnsupported, hlsIngestFailed, liveSourceUnavailable, hlsPlaylistOnRawLivePath
    case dolbyVisionRequiresHardware, demuxedAudioLiveUnsupported, nativeItemFailed
    case noPlayableTrackWithinBudget, masterPlaylistRejected, vodSourceFailed, sourceRateLimited
    case softwarePipelineFailed, audioSessionFailed, reloadFailed, liveReloadNeverReady
    case audioTrackSwitchFailed, audioBridgeProducedNoOutput, storageExhausted
    /// Façade-raised (`AetherPlaybackSession.reportFirstFrameTimeout()`): the host's start budget elapsed
    /// with no first frame.
    case firstFrameTimeout
    /// Any token a later engine adds, or a throw that published no `errorInfo` (`"thrown:<Type>"`).
    case unknown(String)

    /// Every engine token 7.54.0 defines (`PlaybackErrorInfo.swift`), in declaration order.
    public static let engineTokens: [String] = [
        "sourceOpenFailed", "sourceRefused", "sourceCertificateRejected", "customSourceProbeFailed",
        "hlsFormatUnsupported", "hlsIngestFailed", "liveSourceUnavailable", "hlsPlaylistOnRawLivePath",
        "dolbyVisionRequiresHardware", "demuxedAudioLiveUnsupported", "nativeItemFailed",
        "noPlayableTrackWithinBudget", "masterPlaylistRejected", "vodSourceFailed", "sourceRateLimited",
        "softwarePipelineFailed", "audioSessionFailed", "reloadFailed", "liveReloadNeverReady",
        "audioTrackSwitchFailed", "audioBridgeProducedNoOutput", "storageExhausted",
    ]

    /// Total: an unrecognised token lands in `.unknown(token)` and round-trips through `token`.
    public init(token: String) {
        switch token {
        case "sourceOpenFailed": self = .sourceOpenFailed
        case "sourceRefused": self = .sourceRefused
        case "sourceCertificateRejected": self = .sourceCertificateRejected
        case "customSourceProbeFailed": self = .customSourceProbeFailed
        case "hlsFormatUnsupported": self = .hlsFormatUnsupported
        case "hlsIngestFailed": self = .hlsIngestFailed
        case "liveSourceUnavailable": self = .liveSourceUnavailable
        case "hlsPlaylistOnRawLivePath": self = .hlsPlaylistOnRawLivePath
        case "dolbyVisionRequiresHardware": self = .dolbyVisionRequiresHardware
        case "demuxedAudioLiveUnsupported": self = .demuxedAudioLiveUnsupported
        case "nativeItemFailed": self = .nativeItemFailed
        case "noPlayableTrackWithinBudget": self = .noPlayableTrackWithinBudget
        case "masterPlaylistRejected": self = .masterPlaylistRejected
        case "vodSourceFailed": self = .vodSourceFailed
        case "sourceRateLimited": self = .sourceRateLimited
        case "softwarePipelineFailed": self = .softwarePipelineFailed
        case "audioSessionFailed": self = .audioSessionFailed
        case "reloadFailed": self = .reloadFailed
        case "liveReloadNeverReady": self = .liveReloadNeverReady
        case "audioTrackSwitchFailed": self = .audioTrackSwitchFailed
        case "audioBridgeProducedNoOutput": self = .audioBridgeProducedNoOutput
        case "storageExhausted": self = .storageExhausted
        case "firstFrameTimeout": self = .firstFrameTimeout
        default: self = .unknown(token)
        }
    }

    public var token: String {
        switch self {
        case .sourceOpenFailed: return "sourceOpenFailed"
        case .sourceRefused: return "sourceRefused"
        case .sourceCertificateRejected: return "sourceCertificateRejected"
        case .customSourceProbeFailed: return "customSourceProbeFailed"
        case .hlsFormatUnsupported: return "hlsFormatUnsupported"
        case .hlsIngestFailed: return "hlsIngestFailed"
        case .liveSourceUnavailable: return "liveSourceUnavailable"
        case .hlsPlaylistOnRawLivePath: return "hlsPlaylistOnRawLivePath"
        case .dolbyVisionRequiresHardware: return "dolbyVisionRequiresHardware"
        case .demuxedAudioLiveUnsupported: return "demuxedAudioLiveUnsupported"
        case .nativeItemFailed: return "nativeItemFailed"
        case .noPlayableTrackWithinBudget: return "noPlayableTrackWithinBudget"
        case .masterPlaylistRejected: return "masterPlaylistRejected"
        case .vodSourceFailed: return "vodSourceFailed"
        case .sourceRateLimited: return "sourceRateLimited"
        case .softwarePipelineFailed: return "softwarePipelineFailed"
        case .audioSessionFailed: return "audioSessionFailed"
        case .reloadFailed: return "reloadFailed"
        case .liveReloadNeverReady: return "liveReloadNeverReady"
        case .audioTrackSwitchFailed: return "audioTrackSwitchFailed"
        case .audioBridgeProducedNoOutput: return "audioBridgeProducedNoOutput"
        case .storageExhausted: return "storageExhausted"
        case .firstFrameTimeout: return "firstFrameTimeout"
        case .unknown(let token): return token
        }
    }

    /// Kinds whose `underlyingCode` is the origin's HTTP status.
    public var carriesHTTPStatus: Bool { self == .sourceRefused || self == .sourceRateLimited }
}

// MARK: - Failure

/// One playback failure, reported once per load generation.
public struct AetherFailure: Error, Sendable, Equatable {
    public let kind: AetherFailureKind
    /// The origin's status when `kind.carriesHTTPStatus`, else nil.
    public let httpStatus: Int?
    /// `PlaybackErrorInfo.underlyingDomain` (NSError domain).
    public let domain: String?
    /// `PlaybackErrorInfo.underlyingCode`.
    public let code: Int?
    /// `PlaybackErrorInfo.ffmpegErrorCode` (negative AVERROR).
    public let ffmpegCode: Int?
    /// For logs only: localized on the native paths. Never classify on it.
    public let message: String
    /// Playhead (`AetherClock.currentSec`) when it was published.
    public let atSec: Double
    public let beforeFirstFrame: Bool

    public init(kind: AetherFailureKind, httpStatus: Int? = nil, domain: String? = nil, code: Int? = nil,
                ffmpegCode: Int? = nil, message: String, atSec: Double, beforeFirstFrame: Bool) {
        self.kind = kind
        self.httpStatus = httpStatus
        self.domain = domain
        self.code = code
        self.ffmpegCode = ffmpegCode
        self.message = message
        self.atSec = atSec
        self.beforeFirstFrame = beforeFirstFrame
    }

    /// Builds a failure from the engine's `PlaybackErrorInfo` fields. `httpStatus` is taken from `code`
    /// only for the two kinds whose code is a status.
    public static func fromEngine(token: String, domain: String?, code: Int?, ffmpegCode: Int?,
                                  message: String, atSec: Double, beforeFirstFrame: Bool) -> AetherFailure {
        let kind = AetherFailureKind(token: token)
        return AetherFailure(kind: kind, httpStatus: kind.carriesHTTPStatus ? code : nil, domain: domain,
                             code: code, ffmpegCode: ffmpegCode, message: message, atSec: atSec,
                             beforeFirstFrame: beforeFirstFrame)
    }

    /// A throw that published no `errorInfo` (a probe error, say): `.unknown("thrown:<Type>")`.
    public static func thrown(_ error: Error, atSec: Double, beforeFirstFrame: Bool) -> AetherFailure {
        let ns = error as NSError
        return AetherFailure(kind: .unknown("thrown:\(type(of: error))"), domain: ns.domain, code: ns.code,
                             message: String(describing: error), atSec: atSec, beforeFirstFrame: beforeFirstFrame)
    }
}

// MARK: - Load ledger

/// One failure per load generation (engine docs, "How a load ends"): `$errorInfo` publishes before `$state`
/// turns `.error`, and `load()` throws for the same failure. Both paths report here with the generation
/// captured when the load began; the first wins. `end()` (from `stop()`) moves the generation on so late
/// events of a torn-down session are stale.
public struct AetherLoadLedger: Sendable, Equatable {
    public private(set) var generation = 0
    /// The failure this generation reported, if any.
    public private(set) var reportedFailure: AetherFailure?

    public init() {}

    /// `load()`: a new generation with nothing reported.
    public mutating func begin() -> Int {
        generation += 1
        reportedFailure = nil
        return generation
    }

    /// The failure to emit, or nil when this generation already reported one or `g` is stale.
    public mutating func report(_ failure: AetherFailure, generation g: Int) -> AetherFailure? {
        guard g == generation, reportedFailure == nil else { return nil }
        reportedFailure = failure
        return failure
    }

    /// `stop()`: everything still in flight is stale.
    public mutating func end() {
        generation += 1
        reportedFailure = nil
    }

    public func isCurrent(_ g: Int) -> Bool { g == generation }
}

// MARK: - Seek resolution

/// The engine's `SeekEvent` in fork types.
public struct AetherSeekEventSample: Sendable, Equatable {
    public enum Origin: String, Sendable, Equatable {
        /// A host `seek(to:)` (the façade's).
        case programmatic
        /// AVKit's own scrub; never the façade's.
        case nativeScrub
        /// A seek stashed while loading and replayed when the session settled (its target is clamped).
        case deferred
    }

    public enum Outcome: Sendable, Equatable {
        case began
        case landed(renderedSec: Double)
        case stalled
        case superseded
        case rejected(AetherSeekRejection)
    }

    public let id: UInt64
    public let origin: Origin
    public let target: Double
    public let outcome: Outcome

    public init(id: UInt64, origin: Origin, target: Double, outcome: Outcome) {
        self.id = id
        self.origin = origin
        self.target = target
        self.outcome = outcome
    }

    public var isTerminal: Bool { outcome != .began }
}

/// Resolves one `seek(toSec:exact:)` from the seek-event stream. Built before the engine call with the
/// highest event id seen so far; feed it every later event. It latches onto the first programmatic or
/// deferred event above that id whose target is the requested one (within 0.001 s, or the request clamped
/// to `[0, durationSec]`, the target a seek stashed during load carries), then resolves on that id's first
/// terminal event. A deferred ticket closed `.superseded` is the engine replaying the stashed seek under a
/// new programmatic ticket or refusing it as forward-only (the next event carries the same target and the
/// resolver follows it), or a second stashed seek replacing it (the next event carries another target:
/// `.superseded`).
public struct AetherSeekResolver: Sendable, Equatable {
    /// How long after the engine call returns the façade waits for a terminal event.
    public static let confirmationWindowSec: Double = 5
    public static let targetTolerance: Double = 0.001

    public let requestedSec: Double
    public let afterID: UInt64
    public let durationSec: Double
    public private(set) var latchedID: UInt64?
    public private(set) var outcome: AetherSeekOutcome?
    /// Set when the latched deferred ticket closed `.superseded`: the engine's very next event decides
    /// whether that was the replay of this seek (a `.began` at the same target) or another seek replacing it.
    public private(set) var awaitingReplay = false

    public init(requestedSec: Double, afterID: UInt64, durationSec: Double = 0) {
        self.requestedSec = requestedSec
        self.afterID = afterID
        self.durationSec = durationSec
    }

    /// Checks done before the engine is called: `.rejected(.ended)` after `.ended`, `.rejected(.notFinite)`
    /// for NaN or infinity, `.rejected(.noActiveSession)` with no session. nil means call the engine.
    public static func precheck(targetSec: Double, phase: AetherPhase, hasSession: Bool) -> AetherSeekOutcome? {
        guard targetSec.isFinite else { return .rejected(.notFinite) }
        if phase == .ended { return .rejected(.ended) }
        guard hasSession else { return .rejected(.noActiveSession) }
        return nil
    }

    func matchesTarget(_ t: Double) -> Bool {
        if abs(t - requestedSec) <= Self.targetTolerance { return true }
        let clamped = durationSec > 0 ? max(0, min(requestedSec, durationSec)) : max(0, requestedSec)
        return abs(t - clamped) <= Self.targetTolerance
    }

    /// Feeds one event. Returns the outcome when this event resolves the seek (once).
    @discardableResult
    public mutating func consume(_ e: AetherSeekEventSample) -> AetherSeekOutcome? {
        guard outcome == nil, e.id > afterID, e.origin != .nativeScrub else { return nil }
        if awaitingReplay {
            awaitingReplay = false
            guard matchesTarget(e.target) else {
                outcome = .superseded
                return .superseded
            }
            // The replay (`.began`), or the forward-only refusal the engine emits for the same target.
            latchedID = e.id
        }
        if let latched = latchedID {
            guard e.id == latched else { return nil }
        } else {
            guard matchesTarget(e.target) else { return nil }
            latchedID = e.id
        }
        if e.origin == .deferred, e.outcome == .superseded {
            latchedID = nil
            awaitingReplay = true
            return nil
        }
        let resolved: AetherSeekOutcome?
        switch e.outcome {
        case .began: resolved = nil
        case .landed(let rendered): resolved = .landed(atSec: rendered)
        case .stalled: resolved = .stalled
        case .superseded: resolved = .superseded
        case .rejected(let r): resolved = .rejected(r)
        }
        outcome = resolved
        return resolved
    }
}
