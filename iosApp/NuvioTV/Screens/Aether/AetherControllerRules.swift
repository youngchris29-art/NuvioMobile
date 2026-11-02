import CoreGraphics
import Foundation
import NuvioAether

// Aether Phase 1, W3-A: the pure decisions behind `AetherTVPlayerViewController`, factored out so
// `AetherControllerTests` pins them without an engine (the façade's `FakeEngine` is package-internal).
// Fork and façade value types only; nothing here touches a session, a timer or UIKit.

// MARK: - Seeks

/// How a transport seek (`TransportSeekMode`, the mpv vocabulary) becomes one façade
/// `seek(toSec:exact:)`, and how its outcome reads back to the transport.
enum AetherSeekPlan {
    /// mpv's `hr-seek=default` rule, kept on Aether: absolute seeks are exact, a relative click and
    /// the first stage of a two-stage commit land on a keyframe.
    static func isExact(_ mode: TransportSeekMode) -> Bool {
        switch mode {
        case .relative, .absoluteKeyframes: return false
        case .absolute, .absoluteExact: return true
        }
    }

    /// The absolute target for a transport seek. A relative click starts where a seek in flight was
    /// going (the transport's own base rule), else at the playhead; an absolute mode uses `targetSec`.
    /// Clamped to the file (`clamp`). nil when nothing finite can be computed.
    static func target(mode: TransportSeekMode, targetSec: Double?, positionSec: Double,
                       inFlightTargetSec: Double?, durationSec: Double) -> Double? {
        let raw: Double?
        switch mode {
        case .relative(let delta):
            if let targetSec {
                raw = targetSec
            } else {
                raw = (inFlightTargetSec ?? positionSec) + delta
            }
        case .absolute, .absoluteKeyframes, .absoluteExact:
            raw = targetSec
        }
        guard let raw, raw.isFinite else { return nil }
        return clamp(raw, durationSec: durationSec)
    }

    /// `[0, duration - 0.5]` once the duration is known (a seek onto the last frame would end the
    /// file, which is terminal on Aether), else `>= 0`.
    static func clamp(_ sec: Double, durationSec: Double) -> Double {
        guard durationSec.isFinite, durationSec > 0.5 else { return max(0, sec) }
        return min(max(0, sec), durationSec - 0.5)
    }

    /// What the transport and the skip planner hear about a finished seek.
    enum Landing: Equatable {
        /// Landed at `atSec` (the rendered time, or the target when the engine did not say).
        case landed(atSec: Double)
        /// A newer seek replaced it: nothing to report, the newer one reports.
        case superseded
        /// Refused: the planner's seek is interrupted, `onRejected` runs.
        case rejected
    }

    /// `.stalled` counts as landed at the target (W2-A hand-over; the transport treats it so), and so
    /// does `.unconfirmed` (no terminal event inside the façade's window: the picture is wherever the
    /// engine put it, and holding the transport would leave the preview playhead stuck).
    static func landing(for outcome: AetherSeekOutcome, targetSec: Double) -> Landing {
        switch outcome {
        case .landed(let at): return .landed(atSec: at.isFinite ? at : targetSec)
        case .stalled, .unconfirmed: return .landed(atSec: targetSec)
        case .superseded: return .superseded
        case .rejected: return .rejected
        @unknown default: return .landed(atSec: targetSec)
        }
    }
}

// MARK: - Scan and speed

/// Hold-to-scan on Aether (plan section 14): the engine plays video at up to `maxRate` (2.0), so 2x is
/// a plain rate change and 3x / 4x play at the cap while a timer adds stepped forward seeks for the
/// rest. The rate chip shows the requested rate either way (the transport model owns it).
enum AetherScanPlan {
    /// The stepped seeks' period.
    static let stepIntervalSec: Double = 1
    /// No stepped seek this close to the end: the scan must not run the file into `.ended`.
    static let endGuardSec: Double = 3

    /// The engine rate for a scan at `rate`x: the rate itself up to the engine's cap.
    static func engineRate(scanRate: Int, maxRate: Float) -> Float {
        let cap = AetherRatePlan.effectiveMax(maxRate)
        return min(Float(max(scanRate, 1)), cap)
    }

    /// True when the engine cannot play `rate`x by itself and the timer must step.
    static func isStepped(scanRate: Int, maxRate: Float) -> Bool {
        Float(scanRate) > AetherRatePlan.effectiveMax(maxRate)
    }

    /// The next stepped seek's target: the playhead plus what the engine rate does not cover in one
    /// period. nil when the scan does not step, or the target would reach the end guard.
    static func stepTarget(positionSec: Double, scanRate: Int, maxRate: Float,
                           intervalSec: Double = stepIntervalSec, durationSec: Double) -> Double? {
        guard isStepped(scanRate: scanRate, maxRate: maxRate), positionSec.isFinite, intervalSec > 0 else { return nil }
        let extra = (Double(scanRate) - Double(engineRate(scanRate: scanRate, maxRate: maxRate))) * intervalSec
        let target = positionSec + extra
        if durationSec.isFinite, durationSec > 0, target >= durationSec - endGuardSec { return nil }
        return target
    }
}

enum AetherRatePlan {
    /// The façade documents 2.0 for video; a missing or nonsensical cap reads as that.
    static let assumedMax: Float = 2

    static func effectiveMax(_ maxRate: Float) -> Float {
        maxRate.isFinite && maxRate >= 1 ? maxRate : assumedMax
    }

    /// A panel speed the engine can play: anything above the cap plays at the cap (the panel's
    /// choices stop at 2x, so this only guards a remembered speed or a later choice), never below 0.25.
    static func clampedSpeed(_ speed: Double, maxRate: Float) -> Double {
        guard speed.isFinite, speed > 0 else { return 1 }
        return min(max(speed, 0.25), Double(effectiveMax(maxRate)))
    }
}

// MARK: - Audio delay

/// The engine clamps audio delay to +/-2 s (plan section 5): the panel's limit follows, and a larger
/// stream hint is clamped (and logged by the controller).
enum AetherAudioDelayPlan {
    static let engineLimitSec: Double = 2

    static func clamped(_ sec: Double) -> Double {
        guard sec.isFinite else { return 0 }
        return min(max(sec, -engineLimitSec), engineLimitSec)
    }

    /// The Audio Delay row's limit: the shared UI limit, never past the engine's.
    static func uiLimitSec(sharedLimitSec: Double) -> Double {
        min(max(sharedLimitSec, 0), engineLimitSec)
    }
}

/// Audio Boost and Dialogue on Aether (plan section 14): both ride one `AetherAudioShaping`.
enum AetherShapingPlan {
    /// mpv's centre x1.5 is +3.5 dB.
    static let dialogueLiftDB: Double = 3.5

    static func shaping(boostDb: Int, mode: PlayerAudioMode) -> AetherAudioShaping {
        AetherAudioShaping(dialogueLiftDB: mode == .dialogue ? dialogueLiftDB : 0,
                           boostDB: Double(PlayerAudioEffects.clampBoost(boostDb))).clamped
    }
}

// MARK: - Start watchdog and failures

/// The start budget on Aether: mpv's `MPVStartWatchdog` budget, measured to the first frame (a source
/// that opens but never draws is the failure the budget exists for).
enum AetherStartWatchdogRule {
    enum Action: Equatable {
        case wait
        /// The first frame is up (or the watchdog is spent): stop the timer.
        case standDown
        /// The budget ran out with no first frame: `session.reportFirstFrameTimeout()`.
        case reportTimeout
    }

    static func action(verdict: MPVStartWatchdog.Verdict, firstFrameShown: Bool) -> Action {
        if firstFrameShown { return .standDown }
        switch verdict {
        case .waiting: return .wait
        case .fired: return .reportTimeout
        case .inactive: return .standDown
        }
    }
}

enum AetherFailurePlan {
    /// A decider's verdict as the controller acts on it: the DV-interruption rebuild happens once per
    /// player, a second one falls back to mpv.
    static func resolve(_ decision: AetherFailureDecision, alreadyRebuilt: Bool) -> AetherFailureDecision {
        if decision == .rebuildOnce, alreadyRebuilt { return .fallbackToMpv }
        return decision
    }

    /// The `PlaybackFailureKind` a terminal Aether failure carries (W1-A ladder): a rate limit is the
    /// network's, everything else is this engine's own (never remembered against the link).
    static func failureKind(_ kind: AetherFailureKind) -> PlaybackFailureKind {
        kind == .sourceRateLimited ? .network : .local
    }

    /// Where the handoff resumes: the last clock position, finite and >= 0.
    static func handoffPosition(_ sec: Double) -> Double {
        sec.isFinite && sec > 0 ? sec : 0
    }
}

// MARK: - Tracks and chapters

enum AetherTrackRows {
    /// The mpv label shape: "lang · title (codec)", "Track n" when nothing names it.
    static func label(_ t: AetherTrack) -> String {
        let lang = (t.language ?? "").trimmingCharacters(in: .whitespaces)
        let name = t.name.trimmingCharacters(in: .whitespaces)
        let parts = [lang, name].filter { !$0.isEmpty }
        var label = parts.isEmpty ? String(localized: "Track \(t.id)") : parts.joined(separator: " \u{00B7} ")
        let codec = t.codec.trimmingCharacters(in: .whitespaces)
        if !codec.isEmpty { label += " (\(codec))" }
        return label
    }

    static func audio(_ tracks: [AetherTrack], activeID: Int?) -> [PlayerTrack] {
        tracks.map { PlayerTrack(id: $0.id, label: label($0), isSelected: $0.id == activeID) }
    }

    /// The mpv list shape: an "Off" row (id -1) first whenever there is anything to pick, else empty.
    static func subtitles(_ tracks: [AetherTrack], activeID: Int?) -> [PlayerTrack] {
        guard !tracks.isEmpty else { return [] }
        let off = PlayerTrack(id: -1, label: String(localized: "Off"), isSelected: activeID == nil)
        return [off] + tracks.map { PlayerTrack(id: $0.id, label: label($0), isSelected: $0.id == activeID) }
    }
}

enum AetherChapterMapping {
    /// Façade chapters as the transport's, in start order, end markers trimmed like mpv's.
    static func transportChapters(_ chapters: [AetherChapter], durationSec: Double) -> (raw: [TransportChapter], published: [TransportChapter]) {
        let raw = chapters
            .filter { $0.startSec.isFinite && $0.startSec >= 0 }
            .sorted { $0.startSec < $1.startSec }
            .map { TransportChapter(title: $0.title, sec: $0.startSec) }
        return (raw, PlayerChapters.trimmed(raw, durationSec: durationSec))
    }
}

// MARK: - Info rows

/// `AetherDiagnostics` in the existing `StreamInfoSnapshot` rows (Info shelf and the Stream Info card).
enum AetherStreamInfo {
    static func routeLabel(_ route: AetherVideoRoute) -> String? {
        switch route {
        case .remoteBypass, .loopback: return String(localized: "native")
        case .software: return String(localized: "software")
        case .audio: return String(localized: "audio only")
        case .none: return nil
        @unknown default: return nil
        }
    }

    static func deliveryLabel(_ delivery: AetherAudioDelivery) -> String? {
        switch delivery {
        case .streamCopy: return String(localized: "stream copy")
        case .bridged: return String(localized: "bridged")
        case .decoded: return String(localized: "decoded")
        case .playerManaged: return "AVPlayer"
        case .droppedNoPipeline: return String(localized: "dropped")
        case .noAudioInSource: return String(localized: "no audio")
        case .none: return nil
        @unknown default: return nil
        }
    }

    static func formatLabel(_ format: AetherVideoFormat, dvProfile: Int?) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg: return "HLG"
        case .dolbyVision: return dvProfile.map { "DV P\($0)" } ?? "DV"
        @unknown default: return "-"
        }
    }

    /// "Aether · software · audio decoded" (plus the DV path and escalations): the Engine row.
    static func engineLabel(routingNote: String, diagnostics d: AetherDiagnostics, subtitleDelaySec: Double) -> String {
        var parts = [routingNote.isEmpty ? "Aether" : routingNote]
        if let route = routeLabel(d.route) { parts.append(route) }
        if let delivery = deliveryLabel(d.audioDelivery) { parts.append(String(localized: "audio \(delivery)")) }
        if d.dualLayerComposed {
            parts.append(String(localized: "DV FEL dual-layer"))
        } else if d.dvConvertedP7ToP81 {
            parts.append("DV P7\u{2192}8.1")
        }
        if d.softwareEscalations > 0 { parts.append(String(localized: "escalations \(d.softwareEscalations)")) }
        if subtitleDelaySec != 0 { parts.append(String(format: "subs %+.2f s", subtitleDelaySec)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func snapshot(diagnostics d: AetherDiagnostics, routingNote: String, activeAudio: AetherTrack?,
                         bufferedAheadSec: Double, subtitleDelaySec: Double) -> StreamInfoSnapshot {
        var info = StreamInfoSnapshot()
        info.engine = engineLabel(routingNote: routingNote, diagnostics: d, subtitleDelaySec: subtitleDelaySec)
        var video = [d.videoCodec ?? ""].filter { !$0.isEmpty }
        let source = formatLabel(d.sourceFormat, dvProfile: d.sourceDVProfile)
        let output = formatLabel(d.outputFormat, dvProfile: d.dvConvertedP7ToP81 ? 8 : d.sourceDVProfile)
        video.append(source == output ? source : "\(source) \u{2192} \(output)")
        if let container = d.container, !container.isEmpty { video.append(container) }
        info.videoCodec = video.joined(separator: " \u{00B7} ")
        if let size = d.presentationSize, size.width > 0, size.height > 0 {
            info.resolution = "\(Int(size.width.rounded()))\u{00D7}\(Int(size.height.rounded()))"
        }
        if let fps = d.frameRate, fps.isFinite, fps > 0 { info.fps = String(format: "%.3f fps", fps) }
        info.hwdec = d.videoDecoder ?? ""
        if d.videoBitrate > 0 {
            info.videoBitrate = MPVTVPlayerViewController.streamInfoRate(Double(d.videoBitrate) / 1_000_000, unit: "Mbps")
        }
        var audio: [String] = []
        if let a = activeAudio {
            if !a.codec.isEmpty { audio.append(a.codec) }
            if a.channels > 0 { audio.append("\(a.channels)ch") }
            if a.isAtmos { audio.append("Atmos") } else if a.isDTSX { audio.append("DTS:X") }
        }
        if let decoder = d.audioDecoder, !decoder.isEmpty { audio.append(decoder) }
        if let delivery = deliveryLabel(d.audioDelivery) { audio.append(delivery) }
        if d.audioShaping == .applied { audio.append(String(localized: "shaped")) }
        info.audio = audio.joined(separator: " \u{00B7} ")
        if bufferedAheadSec.isFinite, bufferedAheadSec >= 0.5 {
            info.cache = String(format: "%.0fs buffered", bufferedAheadSec.rounded())
        }
        return info
    }
}

// MARK: - Badges

enum AetherBadgeFacts {
    /// Player badges from the façade's facts (the mpv walk's equivalent): picture size, codec, HDR and
    /// the playing audio track.
    static func facts(diagnostics d: AetherDiagnostics, activeAudio: AetherTrack?, metaCandidates: [String]) -> PlayerBadgeFacts {
        var f = PlayerBadgeFacts()
        if let size = d.presentationSize, size.width > 0, size.height > 0 {
            f.videoWidth = Int(size.width.rounded())
            f.videoHeight = Int(size.height.rounded())
        }
        f.videoCodec = d.videoCodec
        switch d.sourceFormat {
        case .dolbyVision: f.hdr = ["DV"]
        case .hdr10: f.hdr = ["HDR10"]
        case .hdr10Plus: f.hdr = ["HDR10+"]
        case .hlg: f.hdr = ["HLG"]
        case .sdr: f.hdr = []
        @unknown default: f.hdr = []
        }
        if let a = activeAudio {
            f.audioCodec = a.codec.isEmpty ? nil : a.codec
            var profiles = [a.profile, a.name.isEmpty ? nil : a.name].compactMap { $0 }
            if a.isAtmos { profiles.append("Dolby Atmos") }
            if a.isDTSX { profiles.append("DTS:X") }
            f.audioProfiles = profiles
            f.audioChannels = a.channels > 0 ? a.channels : nil
            f.languages = PlayerBadgeMatch.languageTokens(a.language ?? "")
        }
        f.metaCandidates = metaCandidates
        return f
    }
}
