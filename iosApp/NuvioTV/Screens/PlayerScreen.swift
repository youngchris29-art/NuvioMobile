import SharedCore
import SwiftUI

/// Engine dispatcher for all video playback in NuvioTV. Call sites present `PlayerScreen`; it probes
/// the stream and routes to the native AVPlayer path (`NativePlayerScreen` — true Dolby Vision via
/// the on-device remux), the experimental Aether engine (`MPVPlayerScreen(engine: .aether)`, Settings
/// > Playback, Off by default) or the libmpv path (`MPVPlayerScreen` — universal fallback), keeping
/// the choice invisible to callers.
///
/// The native path is gated by `PlayerTuning.nativeDVKey` (Settings > Playback beta toggle). With the
/// flag off, playback goes straight to mpv with no probe delay — non-beta behavior is unchanged. With
/// it on, a brief probe decides per file, and any native-path failure falls back to mpv for the same
/// context. See docs/tvos-hybrid-player-plan.md.
///
/// Failover (orivio batch item 2): `onPlaybackFailed` / `onPlaybackHealthy` are forwarded to both
/// engines. A native failure still falls back to mpv on the same URL first; mpv then reports for
/// the whole attempt (the native seconds played are carried over, and a native path that never
/// started gives mpv the shortened start watchdog). With both closures nil nothing changes.
///
/// Aether (Phase 1, W3-C): with `player.aetherEngine` On the router considers Aether before native
/// (plan section 4). An Aether failure that asks for a handoff swaps to mpv in the same watch session
/// with the position the engine was at (`handoffPositionSec`), the seconds played and the shortened
/// start budget when no frame ever showed; the failure alert never offers Aether back.
struct PlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)? = nil
    /// The playback failed (see `PlaybackFailure`); the host decides what plays next.
    var onPlaybackFailed: ((PlaybackFailure) -> Void)? = nil
    /// Fired once per engine session when the link has played `PlaybackFailoverPolicy.healthySeconds`.
    var onPlaybackHealthy: ((Double) -> Void)? = nil
    /// P5 B22: a post-play More Like This poster was chosen. The host stores it and navigates
    /// after its player cover dismisses; nil = no row.
    var onOpenTitle: ((MetaPreview) -> Void)? = nil

    @State private var decision: EngineDecision?
    /// The probe behind `decision` (nil with the native flag off or no probe): decides whether the
    /// failure alert may offer the native player after an mpv failure.
    @State private var probe: ProbeResult?
    /// Set when the native or Aether path falls back; pins this context to mpv.
    @State private var forcedMPV = false
    /// Seconds the native (or Aether) engine played before it fell back to mpv.
    @State private var nativeSecondsPlayed: Double = 0
    /// The native (or Aether) engine fell back before it ever started playing.
    @State private var nativeFailedBeforeStart = false
    /// Where the engine that fell back was (Aether and native handoffs); mpv resumes there when > 0.
    @State private var handoffPositionSec: Double?
    /// P4 B24: Settings › Playback › Loading Screen, read once (default on).
    @State private var loadingOverlayOn = PlayerLoadingOverlaySetting.enabled

    private var nativeDVEnabled: Bool { UserDefaults.standard.bool(forKey: PlayerTuning.nativeDVKey) }

    private var aetherEnabled: Bool { AetherTuning.isEngineEnabled() }

    private enum Shown { case deciding, native, aether, mpv }
    private var shown: Shown {
        if context.forcedEngine == .mpv || forcedMPV { return .mpv }
        // A failure-alert retry on the native player: no probe wait, and no silent fallback to
        // the mpv path that just failed (see `NativePlayerScreen`'s `onFallback: nil`).
        if context.forcedEngine == .native { return .native }
        // `debug.mpvSmokeEngine aether`: Aether without a probe; its failures still hand off to mpv.
        if context.forcedEngine == .aether { return .aether }
        guard nativeDVEnabled || aetherEnabled else { return .mpv }   // both off → mpv immediately, no probe wait
        guard let decision else { return .deciding }
        switch decision.engine {
        case .native: return .native
        case .aether: return .aether
        case .mpv: return .mpv
        }
    }

    var body: some View {
        Group {
            switch shown {
            case .native:
                NativePlayerScreen(context: context, onPlayNext: onPlayNext,
                                   onFallback: context.forcedEngine == .native ? nil : { position, secondsPlayed, startedPlaying in
                                       nativeSecondsPlayed = secondsPlayed
                                       // W3-C: the position the native engine reached now reaches mpv's
                                       // resume (it was discarded before; remove this line to restore).
                                       handoffPositionSec = position
                                       // Readiness, not the play clock (review r2 #1): only a native
                                       // item that never became ready shortens mpv's start budget.
                                       nativeFailedBeforeStart = !startedPlaying
                                       forcedMPV = true
                                   },
                                   routingNote: decision?.displayNote,
                                   onPlaybackFailed: annotated(.native),
                                   onPlaybackHealthy: onPlaybackHealthy,
                                   onOpenTitle: onOpenTitle)
            case .aether:
                // Its own `switch` case: the representable builds its controller once, so Aether and
                // the mpv screen after a handoff are different identities.
                MPVPlayerScreen(context: aetherContext, onPlayNext: onPlayNext,
                                routingNote: aetherRoutingNote,
                                onPlaybackFailed: annotated(.aether),
                                onPlaybackHealthy: onPlaybackHealthy,
                                onOpenTitle: onOpenTitle,
                                engine: .aether,
                                onFallback: { handoff in
                                    nativeSecondsPlayed = handoff.secondsPlayed
                                    // Readiness, not the play clock: only an Aether run that never showed
                                    // a frame shortens mpv's start budget.
                                    nativeFailedBeforeStart = !handoff.startedPlaying
                                    handoffPositionSec = handoff.positionSec
                                    forcedMPV = true
                                })
            case .mpv:
                MPVPlayerScreen(context: context, onPlayNext: onPlayNext,
                                routingNote: mpvRoutingNote,
                                onPlaybackFailed: annotated(.mpv),
                                onPlaybackHealthy: onPlaybackHealthy,
                                startWatchdogShortened: forcedMPV && nativeFailedBeforeStart,
                                nativeSecondsPlayedBeforeFallback: forcedMPV ? nativeSecondsPlayed : 0,
                                forcesGpuNext: mpvForcesGpuNext,
                                handoffPositionSec: forcedMPV ? handoffPositionSec : nil,
                                onOpenTitle: onOpenTitle)
            case .deciding:
                // B24: the probe is the first startup phase; the loading screen draws it from the
                // first frame (`.checking`, the only stage MediaProbe has). Off: the old spinner.
                Group {
                    if loadingOverlayOn {
                        PlayerLoadingOverlay(context: context, stage: .checking)
                    } else {
                        PlayerLoadingSpinner()
                    }
                }
                #if DEBUG
                .onAppear { PlayerLoadingHistory.shared.note(.checking, contextID: context.id) }
                #endif
            }
        }
        #if DEBUG
        // B24 legs' oracle (critique C9): every stage any engine showed for this context.
        .overlay { PlayerLoadingHistoryLabel() }
        #endif
        .task(id: context.id) { await decideEngine() }
        // Hosts that swap the context without rebuilding this view keep mpv pinned (`forcedMPV`),
        // but the native engine never played the new context: its carried-over state is reset.
        .onChange(of: context.id) { _, _ in
            nativeSecondsPlayed = 0
            nativeFailedBeforeStart = false
            handoffPositionSec = nil
        }
    }

    /// B10 (BUG-166): mpv renders a Dolby Vision profile 5 stream with `gpu-next`. The router flags
    /// the streams it sends to mpv; a native run that fell over carries the same probe.
    private var mpvForcesGpuNext: Bool {
        // `forcedEngine == .mpv`: the router returns the forced decision before its gpu-next check.
        if forcedMPV || context.forcedEngine == .mpv { return PlayerEngineRouter.mpvNeedsGpuNext(probe: probe) }
        return decision?.prefersGpuNext ?? false
    }

    /// The Stream Info / loading line for the mpv screen: the router's note, or "mpv · fallback"
    /// after a native failure, "· gpu-next" appended when B10 forces it.
    private var mpvRoutingNote: String? {
        guard forcedMPV else { return decision?.displayNote }
        let note = String(localized: "mpv \u{00B7} fallback")
        return mpvForcesGpuNext ? "\(note) \u{00B7} gpu-next" : note
    }

    /// The Stream Info / loading line for the Aether screen: the router's note ("Aether · DV P8.1"), or
    /// "Aether · forced" for the debug key.
    private var aetherRoutingNote: String? {
        decision?.engine == .aether ? decision?.displayNote : EngineDecision(engine: .aether, reason: "forced").displayNote
    }

    /// The context Aether opens. Release builds: the stream as given. DEBUG: `debug.mpvSmokeAetherBreak`
    /// YES makes Aether open a path that does not exist while mpv keeps the real URL, so the forced-bad
    /// run proves the policy's answer and mpv's takeover at the handoff position.
    private var aetherContext: PlaybackContext {
        #if DEBUG
        return AetherSmokeBreak.apply(to: context)
        #else
        return context
        #endif
    }

    /// Tags a failure with the reporting engine and whether the other engine could take over.
    private func annotated(_ engine: PlaybackEngine) -> ((PlaybackFailure) -> Void)? {
        guard let onPlaybackFailed else { return nil }
        // A forced-mpv run (a retry, or the native fallback) never offers native back: the alert
        // would alternate engines. Explicit here, not left to when the representable captures this.
        let eligibleForNative: Bool = {
            // With Aether On the native engine is reached only by the debug key: never offered.
            guard context.forcedEngine == nil, !forcedMPV, !aetherEnabled, let probe else { return false }
            return PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: false).engine == .native
        }()
        return { failure in
            var tagged = failure
            tagged.engine = engine
            // A native run that was itself a forced retry (after mpv failed) never offers mpv back.
            switch engine {
            // A native or Aether run that was itself a forced retry never offers mpv back. After an
            // Aether fallback the mpv run reports `.mpv` with `forcedMPV` set: it never offers Aether
            // (or native) back either (plan section 4).
            case .native, .aether: tagged.otherEngineEligible = context.forcedEngine == nil
            case .mpv: tagged.otherEngineEligible = eligibleForNative
            }
            onPlaybackFailed(tagged)
        }
    }

    /// Probe off-main (hard-bounded) and pick the engine. No-op straight to mpv when the flag is off.
    private func decideEngine() async {
        #if DEBUG
        let failures = PlayerEngineRouter.selfCheckFailures()
        if failures.isEmpty {
            print("[PlayerRouter] self-check passed")
        } else {
            failures.forEach { print("[PlayerRouter] \u{26A0}\u{FE0F} \($0)") }
        }
        #endif

        // Aether On always runs the probe (plan section 4); both flags off goes straight to mpv.
        let aetherOptions = makeAetherRoutingOptions()
        guard nativeDVEnabled || aetherOptions != nil else { return }

        let url = context.url
        let requestHeaders = context.requestHeaders
        let felToMpv = UserDefaults.standard.bool(forKey: PlayerTuning.dvP7FelMpvKey)
        let nativeOn = nativeDVEnabled
        let forced = context.forcedEngine
        let probeTimeoutSec = 4.0
        let (result, probeResult, probeMs) = await Task.detached(priority: .utility) {
            let t0 = ProcessInfo.processInfo.systemUptime
            let probe = MediaProbe.probe(url: url, timeoutSec: probeTimeoutSec, requestHeaders: requestHeaders)
            let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            return (PlayerEngineRouter.route(probe: probe, nativeDVEnabled: nativeOn, dvP7FelToMpv: felToMpv,
                                             aether: aetherOptions, forcedEngine: forced), probe, ms)
        }.value
        // P5 spike S2 (BUG-167): the probe is the first startup stage; a nil probe at the cap means a
        // timeout, which routes to mpv without `prefersGpuNext`.
        print("[PlayerRouter] probe took \(probeMs)ms cap=\(Int(probeTimeoutSec * 1000))ms result=\(probeResult == nil ? "nil" : "ok")"
              + (probeResult.map { " hdr=\($0.hdr.rawValue)" + ($0.hdrSource == .none ? "" : "/\($0.hdrSource.rawValue)") } ?? ""))
        if probeResult == nil {
            // W3-19 (BUG-166 / BUG-167, 2026-10-21): on a debrid link the 4 s cap is a coin flip, and a
            // timeout sends the film to mpv with no visible sign. One dedicated line tells a cap hit
            // (the probe ran out the clock) from a probe that failed early (unreachable, unreadable), so a
            // tester's "every HDR film opens in mpv" can be read off the log. Routing is unchanged.
            // Review r1 P3-2: a cap hit inside the P7 RPU scan returns a probe (elKind `.missing`), not
            // nil, so it never reaches this line; `MediaProbe.scanP7ELKind` logs that one itself. The
            // host is redacted to its top-level domain in Release (`PlayerRouterLog.host`). `print`
            // stays: the rig's console stream carries it (a tester's sysdiagnose does not).
            let capMs = Int(probeTimeoutSec * 1000)
            let kind = PlayerRouterLog.probeOutcome(ms: probeMs, capMs: capMs)
            print("[PlayerRouter] \(kind) after \(probeMs)ms (cap \(capMs)ms) host=\(PlayerRouterLog.host(url)) → mpv — \(context.title)")
        }
        print("[PlayerRouter] \(result.engine.rawValue) — \(result.reason) — \(context.title)")
        probe = probeResult
        decision = result
    }

    /// The Aether routing rows' inputs (plan section 4): the settings, the stream's URL and the subtitle
    /// preferences resolved exactly as the mpv engine resolves them at start. nil with Aether Off, so
    /// the router is today's.
    private func makeAetherRoutingOptions() -> AetherRoutingOptions? {
        guard aetherEnabled else { return nil }
        PlayerSettingsRepository.shared.ensureLoaded()
        let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState
        let primary = settings?.preferredSubtitleLanguage ?? ""
        let off = settings != nil && SubtitleFallbackGuard.isOff(primary: primary)
        let targets = settings.map {
            AetherSubtitleRouting.preferredTargets(primary: $0.preferredSubtitleLanguage,
                                                   secondary: $0.secondaryPreferredSubtitleLanguage,
                                                   deviceLanguages: DeviceLanguagePreferences.shared.preferredLanguageCodes())
        } ?? []
        return AetherRoutingOptions(
            enabled: true,
            dualLayerDV: AetherTuning.isDualLayerDVEnabled(),
            styledSubsToMpv: AetherTuning.keepStyledSubsOnMpv(),
            sourceURL: context.url,
            preferredSubtitleTargets: targets,
            subtitlesOff: off,
            useForcedSubtitles: settings?.subtitleStyle.useForcedSubtitles ?? false)
    }
}

/// Review r1 P3-2 (W3-19): the `[PlayerRouter]` probe lines' pure parts.
nonisolated enum PlayerRouterLog {
    /// `-debug.playerRouterHosts YES` (launch-latched, Release-readable) prints the full host on the
    /// rig. Rig console logs fall under the staging rule: a self-hosted add-on, proxy or home-server
    /// host is private, so Release prints the top-level domain only unless the rig asks. DEBUG
    /// builds always print the host.
    static let revealHostsKey = "debug.playerRouterHosts"
    static let revealsHosts: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: revealHostsKey)
        #endif
    }()

    /// The probe ran out the clock (within 50 ms of the cap) or failed early.
    static func probeOutcome(ms: Int, capMs: Int) -> String {
        ms >= capMs - 50 ? "probe cap hit" : "probe failed early"
    }

    /// `url`'s host for a log line: the full host when `reveal`, else `<redacted>.<tld>`
    /// (`<redacted>` for an IP literal or a dotless name). `-` when the URL has no host.
    static func host(_ url: URL, reveal: Bool = revealsHosts) -> String {
        guard let host = url.host, !host.isEmpty else { return "-" }
        if reveal { return host }
        let isIPLiteral = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        guard !isIPLiteral, let dot = host.lastIndex(of: "."), host.index(after: dot) < host.endIndex else {
            return "<redacted>"
        }
        return "<redacted>." + host[host.index(after: dot)...]
    }
}
