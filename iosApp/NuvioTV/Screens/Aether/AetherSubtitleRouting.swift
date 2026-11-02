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
        useForcedSubtitles: Bool = false,
        preferredAudioTargets: [String] = []
    ) -> Bool {
        // Off shows nothing at start, except the forced pick "Use forced subtitles" still makes there.
        guard !subtitlesOff || useForcedSubtitles else { return false }
        guard probe.fontAttachmentCount > 0, !probe.subtitles.isEmpty else { return false }
        guard let track = initialTrack(probe: probe, preferredLanguages: preferredLanguages,
                                       subtitlesOff: subtitlesOff, useForcedSubtitles: useForcedSubtitles,
                                       preferredAudioTargets: preferredAudioTargets) else { return false }
        return isStyledASSCodec(track.codec)
    }

    /// Review r1 F2: the audio track playback starts on, resolved by the start plan's own audio
    /// resolver (`PlayerAudioLanguagePlan.trackToForce`, the mpv post-track-list pick): the first
    /// preferred-language target that matches a track decides; with no match the default stays. The
    /// probe carries no audio disposition, so its first track stands in for the default.
    static func effectiveAudioTrack(probe: ProbeResult, preferredAudioTargets: [String]) -> AudioStreamInfo? {
        let tracks = probe.audio.enumerated().map { offset, info in
            (id: offset, lang: info.language ?? "", selected: offset == 0)
        }
        if let forced = PlayerAudioLanguagePlan.trackToForce(targets: preferredAudioTargets, tracks: tracks),
           forced < probe.audio.count {
            return probe.audio[forced]
        }
        return probe.audio.first
    }

    static func isStyledASSCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c == "ass" || c == "ssa"
    }

    private static func initialTrack(probe: ProbeResult, preferredLanguages: [String], subtitlesOff: Bool,
                                     useForcedSubtitles: Bool, preferredAudioTargets: [String]) -> SubtitleStreamInfo? {
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
        // The audio the start plan matches forced tracks against: the one playback will select.
        let audio: AudioTrack? = effectiveAudioTrack(probe: probe, preferredAudioTargets: preferredAudioTargets).map {
            AudioTrack(index: 0, id: String($0.index), label: $0.language ?? "",
                       language: ($0.language?.isEmpty ?? true) ? nil : $0.language, isSelected: true)
        }
        // The shared start plan (`resolveSubtitleAutoSelectionPlan`, as the Aether controller and mpv
        // run it): forced-only on the audio language when it matches, the preferred languages otherwise.
        let targets: [String]
        let mode: SubtitleAutoSelectionMode
        if useForcedSubtitles {
            guard let plan = PlayerTrackSelectionKt.resolveSubtitleAutoSelectionPlan(
                selectedAudioTrack: audio,
                preferredAudioTargets: preferredAudioTargets,
                preferredSubtitleTargets: preferredLanguages,
                useForcedSubtitles: true) else { return nil }   // BUG-171: audio unknown → off
            targets = plan.targets
            mode = plan.mode
        } else {
            targets = preferredLanguages
            mode = .normalOnly
        }
        let match = PlayerTrackSelectionKt.findPreferredSubtitleTrackIndex(
            tracks: shared,
            targets: targets,
            mode: mode,
            selectedAudioTrack: audio
        )
        if match >= 0, Int(match) < probe.subtitles.count { return probe.subtitles[Int(match)] }
        // "Use forced subtitles" plans and Off with no match, and plans with no targets, show nothing
        // from the app's own pick; only mpv's container default can still surface a track.
        if useForcedSubtitles || subtitlesOff { return nil }
        return probe.subtitles.first { $0.isDefault }
    }
}
