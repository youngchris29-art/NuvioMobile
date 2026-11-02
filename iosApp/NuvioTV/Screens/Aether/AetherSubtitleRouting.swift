import Foundation
import SharedCore

// Aether (Phase 1), routing row 10: files whose start subtitle is styled ASS stay on mpv, which draws
// ASS exactly as authored. Pure and probe-driven so it is unit-testable and shares no state with the
// player. See docs/aether-phase1-plan-2026-11-01.md section 4.

nonisolated enum AetherSubtitleRouting {
    /// The subtitle language targets the player pursues, resolved exactly as the mpv engine does at
    /// start (`MPVPlayerView` subtitle auto-select): Off stays Off (`SubtitleFallbackGuard`), the
    /// secondary is dropped then, device languages fill in.
    static func preferredTargets(primary: String, secondary: String?, deviceLanguages: [String]) -> [String] {
        PlayerLanguagePreferencesKt.resolvePreferredSubtitleLanguageTargets(
            preferredSubtitleLanguage: primary,
            secondaryPreferredSubtitleLanguage: SubtitleFallbackGuard.effectiveSecondary(
                primary: primary, secondary: secondary
            ),
            deviceLanguages: deviceLanguages
        )
    }

    /// Whether the embedded subtitle track the fork would select at start is styled ASS: codec `ass`
    /// or `ssa` AND the container ships at least one font attachment. ASS without fonts (a converted
    /// SRT) renders fine as plain text on Aether.
    ///
    /// The start track mirrors `MPVPlayerView`'s auto-select (the `findPreferredSubtitleTrackIndex`
    /// call over the resolved `preferredLanguages`, normal tracks first, forced tracks only when
    /// `useForcedSubtitles` is on). When no language matches, mpv's own `sid=auto` shows the
    /// container's default-flagged track, so that track counts. `subtitlesOff` (Subtitles set to Off)
    /// means no track is selected at start.
    static func initialTrackIsStyledASS(
        probe: ProbeResult,
        preferredLanguages: [String],
        subtitlesOff: Bool,
        useForcedSubtitles: Bool = false
    ) -> Bool {
        guard !subtitlesOff, probe.fontAttachmentCount > 0, !probe.subtitles.isEmpty else { return false }
        guard let track = initialTrack(probe: probe, preferredLanguages: preferredLanguages,
                                       useForcedSubtitles: useForcedSubtitles) else { return false }
        return isStyledASSCodec(track.codec)
    }

    static func isStyledASSCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c == "ass" || c == "ssa"
    }

    private static func initialTrack(probe: ProbeResult, preferredLanguages: [String],
                                     useForcedSubtitles: Bool) -> SubtitleStreamInfo? {
        let shared = probe.subtitles.enumerated().map { offset, info in
            SubtitleTrack(
                index: Int32(offset),
                id: String(info.index),
                label: info.language ?? "",
                language: (info.language?.isEmpty ?? true) ? nil : info.language,
                isSelected: info.isDefault,
                isForced: info.isForced
            )
        }
        // Forced-only plans match on the audio language; the probe's first audio track stands in for
        // the track mpv would be playing (its language pick is the only part not mirrored here).
        let audio: AudioTrack? = useForcedSubtitles ? probe.audio.first.map {
            AudioTrack(index: 0, id: String($0.index), label: $0.language ?? "",
                       language: ($0.language?.isEmpty ?? true) ? nil : $0.language, isSelected: true)
        } : nil
        let match = PlayerTrackSelectionKt.findPreferredSubtitleTrackIndex(
            tracks: shared,
            targets: preferredLanguages,
            mode: useForcedSubtitles ? .forcedOnly : .normalOnly,
            selectedAudioTrack: audio
        )
        if match >= 0, Int(match) < probe.subtitles.count { return probe.subtitles[Int(match)] }
        // Forced-only plans with no forced match, and plans with no targets, show nothing from the
        // app's own pick; only mpv's container default can still surface a track.
        if useForcedSubtitles { return nil }
        return probe.subtitles.first { $0.isDefault }
    }
}
