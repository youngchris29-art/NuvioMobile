import CoreGraphics
import Foundation

// Fork-owned value types for the Aether façade. Nothing in this file names an AetherEngine type, so the
// app (and NuvioTVTests) can build and compare every value without the engine. `LiveEngine.swift` is the
// one place these are converted to and from the engine's own types.

// MARK: - Request

/// Speaker layout for TrueHD Atmos / DTS:X object rendering. Same raw values as the engine's
/// `SpatialSpeakerLayout`.
public enum AetherSpeakerLayout: String, Sendable, CaseIterable {
    case l512 = "5.1.2"
    case l514 = "5.1.4"
    case l712 = "7.1.2"
    case l714 = "7.1.4"
    case l916 = "9.1.6"
}

/// `LoadOptions.objectAudioRendering`. Only `.off` and `.render` are exposed in Phase 1.
public enum AetherObjectAudio: Sendable, Equatable {
    case off
    case render(AetherSpeakerLayout)
}

/// `LoadOptions.audioBridgeMode`: how a codec AVPlayer cannot take (TrueHD, DTS, Opus, PCM...) reaches
/// the sink. `.lossless` is FLAC up to 7.1, decoded to LPCM (the fork's default, setting "Lossless
/// surround (LPCM)"); `.surroundCompat` is E-AC-3 5.1 for legacy-ARC soundbars (the engine's default).
public enum AetherAudioBridge: String, Sendable, CaseIterable {
    case surroundCompat
    case lossless
}

/// `LoadOptions.displayCriteriaOwner`. `.engine` writes range and rate before the item loads (Match
/// Content On); `.host` writes nothing so the panel stays in the user's tvOS output format (Match
/// Content Off). AVKit ownership is never used on this route (no `AVPlayerViewController`).
public enum AetherDisplayCriteriaOwner: Sendable, Equatable {
    case engine
    case host

    /// The fork's `player.matchFrameRate` toggle mapped to an owner (plan section 14).
    public static func forMatchContent(_ matchContentOn: Bool) -> AetherDisplayCriteriaOwner {
        matchContentOn ? .engine : .host
    }
}

/// Which subtitle track the engine activates on its own at load.
public enum AetherInitialSubtitle: Sendable, Equatable {
    /// Neither `initialSubtitleTrackID` nor `preferredSubtitleLanguages` is set.
    case off
    /// `LoadOptions.initialSubtitleTrackID`: a stream index, or `externalTrackIDBase + ordinal`.
    case track(id: Int)
    /// `LoadOptions.preferredSubtitleLanguages`.
    case preferLanguages([String])
}

/// One sidecar subtitle file. Wraps the engine's `ExternalSubtitleTrack`.
public struct AetherExternalSubtitle: Sendable, Equatable {
    public var url: URL
    public var name: String?
    public var language: String?
    public var isForced: Bool
    public var isHearingImpaired: Bool
    public var isDefault: Bool
    /// nil forwards the request's headers (the engine's own rule, same scheme and credential policy).
    public var httpHeaders: [String: String]?
    /// "srt", "ass", "vtt", "sup" when the URL path hides the format.
    public var formatHint: String?

    public init(url: URL, name: String? = nil, language: String? = nil,
                isForced: Bool = false, isHearingImpaired: Bool = false, isDefault: Bool = false,
                httpHeaders: [String: String]? = nil, formatHint: String? = nil) {
        self.url = url
        self.name = name
        self.language = language
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isDefault = isDefault
        self.httpHeaders = httpHeaders
        self.formatHint = formatHint
    }
}

/// The fork's view of the engine's `AudioShaping`. Both values at 0 is inactive, which keeps stream copy
/// (Atmos passthrough) on; anything above 0 moves the track onto the PCM bridge. Every change on a
/// running session is a session-preserving reload.
public struct AetherAudioShaping: Sendable, Equatable {
    /// Engine bound for `dialogueLiftDB` (`AudioShaping.maxDialogueGainDB`).
    public static let maxDialogueLiftDB: Double = 12
    /// Engine bound for `boostDB` (compressor makeup gain).
    public static let maxBoostDB: Double = 24

    /// `AudioShaping.dialogueGainDB`, 0...12. mpv's centre x1.5 is +3.5 dB.
    public var dialogueLiftDB: Double
    /// Audio Boost: `Compressor(thresholdDB: 0, ratio: 1, makeupGainDB: boostDB)`, a pure gain of
    /// `boostDB` (0...24) followed by the engine's limiter at -1 dBFS.
    public var boostDB: Double

    public init(dialogueLiftDB: Double = 0, boostDB: Double = 0) {
        self.dialogueLiftDB = dialogueLiftDB
        self.boostDB = boostDB
    }

    /// The value the engine stores: each field brought into range, a non-finite value to 0.
    public var clamped: AetherAudioShaping {
        AetherAudioShaping(dialogueLiftDB: Self.clamp(dialogueLiftDB, Self.maxDialogueLiftDB),
                           boostDB: Self.clamp(boostDB, Self.maxBoostDB))
    }

    public var isActive: Bool {
        let c = clamped
        return c.dialogueLiftDB > 0 || c.boostDB > 0
    }

    static func clamp(_ v: Double, _ hi: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), hi)
    }
}

/// Everything the engine reads before `load()` (engine docs, "What must be set before load()").
public struct AetherLoadRequest: Sendable, Equatable {
    public var url: URL
    /// `load(url:startPosition:)`. nil starts at the head.
    public var startSec: Double?
    /// `LoadOptions.httpHeaders`. Every value of 4+ bytes is registered as a log secret for the session.
    public var headers: [String: String]
    public var preferredAudioLanguages: [String]
    /// `load(...audioSourceStreamIndex:)`; wins over `preferredAudioLanguages`.
    public var audioStreamIndex: Int?
    public var initialSubtitle: AetherInitialSubtitle
    public var externalSubtitles: [AetherExternalSubtitle]
    public var objectAudio: AetherObjectAudio
    public var audioBridge: AetherAudioBridge
    /// `LoadOptions.preferDualLayerDolbyVision` (Profile 7 FEL composed on the GPU).
    public var dualLayerDV: Bool
    /// Who writes display criteria. Fill from `player.matchFrameRate` with `.forMatchContent(_:)`.
    public var displayCriteriaOwner: AetherDisplayCriteriaOwner
    /// `LoadOptions.matchContentEnabled`: the SYSTEM setting (`AVDisplayManager.isDisplayCriteriaMatchingEnabled`),
    /// never the fork's toggle. Fill with `AetherPlaybackSession.systemMatchingEnabled(in:)`.
    public var systemMatchingEnabled: Bool
    /// `LoadOptions.audioDelaySeconds`; the engine clamps to +/-2 s. Seeding it here avoids a start-time re-anchor.
    public var audioDelaySec: Double
    public var audioShaping: AetherAudioShaping
    /// `LoadOptions.preferredDecodePath = .software` (debug only).
    public var preferSoftwareDecode: Bool
    /// The engine's `logTag`, set before `load()`.
    public var logTag: String?

    public init(url: URL,
                startSec: Double? = nil,
                headers: [String: String] = [:],
                preferredAudioLanguages: [String] = [],
                audioStreamIndex: Int? = nil,
                initialSubtitle: AetherInitialSubtitle = .off,
                externalSubtitles: [AetherExternalSubtitle] = [],
                objectAudio: AetherObjectAudio = .off,
                audioBridge: AetherAudioBridge = .lossless,
                dualLayerDV: Bool = false,
                displayCriteriaOwner: AetherDisplayCriteriaOwner = .engine,
                systemMatchingEnabled: Bool = true,
                audioDelaySec: Double = 0,
                audioShaping: AetherAudioShaping = .init(),
                preferSoftwareDecode: Bool = false,
                logTag: String? = nil) {
        self.url = url
        self.startSec = startSec
        self.headers = headers
        self.preferredAudioLanguages = preferredAudioLanguages
        self.audioStreamIndex = audioStreamIndex
        self.initialSubtitle = initialSubtitle
        self.externalSubtitles = externalSubtitles
        self.objectAudio = objectAudio
        self.audioBridge = audioBridge
        self.dualLayerDV = dualLayerDV
        self.displayCriteriaOwner = displayCriteriaOwner
        self.systemMatchingEnabled = systemMatchingEnabled
        self.audioDelaySec = audioDelaySec
        self.audioShaping = audioShaping
        self.preferSoftwareDecode = preferSoftwareDecode
        self.logTag = logTag
    }

    /// The same request at another start position: Replay (`0`) and the DV-interruption rebuild (a fresh
    /// `load` at the last position, plan section 14).
    public func starting(atSec sec: Double?) -> AetherLoadRequest {
        var copy = self
        copy.startSec = sec
        return copy
    }

    /// Header values that must never reach a log line: the request's and every sidecar's, 4+ bytes.
    public var secretHeaderValues: Set<String> {
        var out = Set<String>()
        for v in headers.values where v.utf8.count >= 4 { out.insert(v) }
        for s in externalSubtitles {
            for v in (s.httpHeaders ?? [:]).values where v.utf8.count >= 4 { out.insert(v) }
        }
        return out
    }
}

// MARK: - Probe, tracks, chapters

public enum AetherVideoFormat: String, Sendable, CaseIterable {
    case sdr, hdr10, hdr10Plus, dolbyVision, hlg
}

/// One audio or subtitle track. Wraps the engine's `TrackInfo`.
public struct AetherTrack: Sendable, Equatable, Identifiable {
    /// Container stream index (`TrackInfo.id`); an external subtitle is `externalTrackIDBase + ordinal`.
    public let id: Int
    public let name: String
    /// Lower-case libavcodec name.
    public let codec: String
    public let language: String?
    public let channels: Int
    public let profile: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let isHearingImpaired: Bool
    public let isCommentary: Bool
    public let isAtmos: Bool
    public let isDTSX: Bool
    public let isExternal: Bool
    /// `TrackInfo.isNativelyRenderedSubtitle`: AVFoundation draws it. Always false off the remote bypass,
    /// which this route never takes; if it is ever true the host hides its overlay controls for the track.
    public let isNativelyRendered: Bool

    public init(id: Int, name: String, codec: String, language: String? = nil, channels: Int = 0,
                profile: String? = nil, isDefault: Bool = false, isForced: Bool = false,
                isHearingImpaired: Bool = false, isCommentary: Bool = false, isAtmos: Bool = false,
                isDTSX: Bool = false, isExternal: Bool = false, isNativelyRendered: Bool = false) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.profile = profile
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isCommentary = isCommentary
        self.isAtmos = isAtmos
        self.isDTSX = isDTSX
        self.isExternal = isExternal
        self.isNativelyRendered = isNativelyRendered
    }

    /// The engine's `externalSubtitleTrackIDBase` (100 000). Checked against the engine in `LiveEngine`.
    public static let externalTrackIDBase = 100_000
}

/// Source facts `load()` returns. Wraps the engine's `SourceProbe`.
public struct AetherProbeSummary: Sendable, Equatable {
    /// 0 for live streams and pipes.
    public let durationSec: Double
    public let videoCodec: String?
    public let width: Int
    public let height: Int
    public let frameRate: Double?
    public let isDolbyVision: Bool
    public let dvProfile: Int?
    public let sourceFormat: AetherVideoFormat
    public let audioTracks: [AetherTrack]
    public let subtitleTracks: [AetherTrack]

    public init(durationSec: Double, videoCodec: String?, width: Int, height: Int, frameRate: Double?,
                isDolbyVision: Bool, dvProfile: Int?, sourceFormat: AetherVideoFormat,
                audioTracks: [AetherTrack], subtitleTracks: [AetherTrack]) {
        self.durationSec = durationSec
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.isDolbyVision = isDolbyVision
        self.dvProfile = dvProfile
        self.sourceFormat = sourceFormat
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
    }
}

/// One chapter on the 0-based seek axis (pass `startSec` to `seek`). Wraps `ChapterInfo`.
public struct AetherChapter: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let startSec: Double
    public let durationSec: Double

    public init(id: Int, title: String, startSec: Double, durationSec: Double) {
        self.id = id
        self.title = title
        self.startSec = startSec
        self.durationSec = durationSec
    }
}

// MARK: - Cues

/// What a cue draws. Text cues carry plain text (rich-text runs are joined, ASS shows as plain text in
/// Phase 1). Bitmap cues carry a fully rendered premultiplied RGBA image and its rect in [0, 1] against
/// the source video frame.
public enum AetherCueBody: @unchecked Sendable {
    case text(String)
    /// `normalizedRect` is [0, 1] against `canvasSize` (the PGS/DVB composition canvas); `.zero` canvas
    /// means unknown, treat canvas == video.
    case image(CGImage, normalizedRect: CGRect, canvasSize: CGSize)
}

/// One subtitle cue on the raw source PTS axis (`AetherClock.sourceSec`). Wraps `SubtitleCue`.
public struct AetherCue: @unchecked Sendable, Identifiable, Equatable {
    /// Monotonic per session.
    public let id: Int
    public let startSec: Double
    public let endSec: Double
    public let body: AetherCueBody
    /// Bitmap only (`SubtitleImage.isForced`). Text cues are always false: use `AetherTrack.isForced`.
    public let isForced: Bool
    /// `SubtitleTextPlacement.alignment` (numpad 1...9), text cues, usually nil.
    public let alignment: Int?
    /// `SubtitleTextPlacement.position` in [0, 1], text cues, usually nil.
    public let anchor: CGPoint?

    public init(id: Int, startSec: Double, endSec: Double, body: AetherCueBody, isForced: Bool = false,
                alignment: Int? = nil, anchor: CGPoint? = nil) {
        self.id = id
        self.startSec = startSec
        self.endSec = endSec
        self.body = body
        self.isForced = isForced
        self.alignment = alignment
        self.anchor = anchor
    }

    /// The engine's own rule: ids are monotonic per session, so id and timing are enough for SwiftUI
    /// diffing without comparing images.
    public static func == (a: AetherCue, b: AetherCue) -> Bool {
        a.id == b.id && a.startSec == b.startSec && a.endSec == b.endSec
    }

    /// The text of a text cue, nil for a bitmap.
    public var text: String? {
        if case .text(let s) = body { return s }
        return nil
    }
}

// MARK: - Audio, video and diagnostics

/// The engine's `AudioDelivery`, 1:1. Classify on this, never on the decoder label.
public enum AetherAudioDelivery: String, Sendable, CaseIterable {
    case none, noAudioInSource, streamCopy, bridged, decoded, droppedNoPipeline, playerManaged
}

/// The engine's `VideoRoute`.
public enum AetherVideoRoute: String, Sendable, CaseIterable {
    case none, remoteBypass, loopback, software, audio
}

/// The engine's `AudioShapingState`.
public enum AetherAudioShapingState: String, Sendable, CaseIterable {
    case off, applied, unavailable
}

/// The engine's `videoGravity`: `.fit` resizeAspect, `.fill` resizeAspectFill, `.stretch` resize.
public enum AetherAspect: Sendable, Equatable {
    case fit, fill, stretch
}

/// Telemetry for the info panel and the device rig, coalesced to at most 2 Hz.
public struct AetherDiagnostics: Sendable, Equatable {
    public var route: AetherVideoRoute
    public var sourceFormat: AetherVideoFormat
    public var outputFormat: AetherVideoFormat
    public var sourceDVProfile: Int?
    /// `dolbyVisionConversion == .profile7ToProfile81` (EL dropped, RPU kept).
    public var dvConvertedP7ToP81: Bool
    public var videoCodec: String?
    public var container: String?
    public var frameRate: Double?
    public var videoBitrate: Int64
    /// Labels only.
    public var videoDecoder: String?
    public var audioDecoder: String?
    public var audioDelivery: AetherAudioDelivery
    public var audioShaping: AetherAudioShapingState
    /// Count of software-path escalations this session (owned by the session, not the engine sample).
    public var softwareEscalations: Int
    /// `softwareDisplaySize`, else coded width x pixel aspect ratio by height. nil before the first video facts.
    public var presentationSize: CGSize?

    public init(route: AetherVideoRoute = .none, sourceFormat: AetherVideoFormat = .sdr,
                outputFormat: AetherVideoFormat = .sdr, sourceDVProfile: Int? = nil,
                dvConvertedP7ToP81: Bool = false, videoCodec: String? = nil, container: String? = nil,
                frameRate: Double? = nil, videoBitrate: Int64 = 0, videoDecoder: String? = nil,
                audioDecoder: String? = nil, audioDelivery: AetherAudioDelivery = .none,
                audioShaping: AetherAudioShapingState = .off, softwareEscalations: Int = 0,
                presentationSize: CGSize? = nil) {
        self.route = route
        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        self.sourceDVProfile = sourceDVProfile
        self.dvConvertedP7ToP81 = dvConvertedP7ToP81
        self.videoCodec = videoCodec
        self.container = container
        self.frameRate = frameRate
        self.videoBitrate = videoBitrate
        self.videoDecoder = videoDecoder
        self.audioDecoder = audioDecoder
        self.audioDelivery = audioDelivery
        self.audioShaping = audioShaping
        self.softwareEscalations = softwareEscalations
        self.presentationSize = presentationSize
    }

    /// Dual-layer Profile 7 composed on the software route (FEL kept), as opposed to the 8.1 conversion.
    public var dualLayerComposed: Bool {
        route == .software && sourceDVProfile == 7 && !dvConvertedP7ToP81
    }
}

// MARK: - Seek, stills, escalation

public enum AetherSeekRejection: String, Sendable, CaseIterable {
    case noActiveSession, liveWithoutDVR, sourceNotSeekable, ended, notFinite
}

/// How a `seek(toSec:exact:)` ended, read from the engine's seek events (its `seek` returns Void).
public enum AetherSeekOutcome: Sendable, Equatable {
    /// Landed; `atSec` is the rendered time.
    case landed(atSec: Double)
    /// The engine reported a stall. It may still land later under the same id; the façade does not wait,
    /// and the transport model treats it as landed at the target.
    case stalled
    case superseded
    case rejected(AetherSeekRejection)
    /// No terminal event within `AetherSeekResolver.confirmationWindowSec` of the engine call returning.
    case unconfirmed
}

/// One scrub-preview still. Wraps `ScrubFrame`.
public struct AetherScrubFrame: @unchecked Sendable {
    public let image: CGImage
    public let actualSec: Double
    public let refined: Bool
    /// Positions this still also answers for (a keyframe ladder entry), nil when exact.
    public let validRange: Range<Double>?

    public init(image: CGImage, actualSec: Double, refined: Bool, validRange: Range<Double>? = nil) {
        self.image = image
        self.actualSec = actualSec
        self.refined = refined
        self.validRange = validRange
    }
}

/// The engine absorbed a native failure by rebuilding on the software path. Not a failure.
public struct AetherEscalation: Sendable, Equatable {
    public let atSec: Double
    /// True when it happened inside `load()`: the same `load()` keeps awaiting.
    public let duringStartup: Bool
    public let absorbed: AetherFailureKind

    public init(atSec: Double, duringStartup: Bool, absorbed: AetherFailureKind) {
        self.atSec = atSec
        self.duringStartup = duringStartup
        self.absorbed = absorbed
    }
}
