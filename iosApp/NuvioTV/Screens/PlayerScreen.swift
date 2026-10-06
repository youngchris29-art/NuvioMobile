import SwiftUI

/// Engine dispatcher for all video playback in NuvioTV. Call sites present `PlayerScreen`; it probes
/// the stream and routes to the native AVPlayer path (`NativePlayerScreen` — true Dolby Vision via
/// the on-device remux) or the libmpv path (`MPVPlayerScreen` — universal fallback), keeping the
/// choice invisible to callers.
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
struct PlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)? = nil
    /// The playback failed (see `PlaybackFailure`); the host decides what plays next.
    var onPlaybackFailed: ((PlaybackFailure) -> Void)? = nil
    /// Fired once per engine session when the link has played `PlaybackFailoverPolicy.healthySeconds`.
    var onPlaybackHealthy: ((Double) -> Void)? = nil

    @State private var decision: EngineDecision?
    /// The probe behind `decision` (nil with the native flag off or no probe): decides whether the
    /// failure alert may offer the native player after an mpv failure.
    @State private var probe: ProbeResult?
    /// Set when the native path fails; pins this context to mpv.
    @State private var forcedMPV = false
    /// Seconds the native engine played before it fell back to mpv.
    @State private var nativeSecondsPlayed: Double = 0
    /// The native engine fell back before it ever started playing.
    @State private var nativeFailedBeforeStart = false

    private var nativeDVEnabled: Bool { UserDefaults.standard.bool(forKey: PlayerTuning.nativeDVKey) }

    private enum Shown { case deciding, native, mpv }
    private var shown: Shown {
        if context.forcedEngine == .mpv || forcedMPV { return .mpv }
        // A failure-alert retry on the native player: no probe wait, and no silent fallback to
        // the mpv path that just failed (see `NativePlayerScreen`'s `onFallback: nil`).
        if context.forcedEngine == .native { return .native }
        guard nativeDVEnabled else { return .mpv }       // flag off → mpv immediately, no probe wait
        guard let decision else { return .deciding }
        return decision.engine == .native ? .native : .mpv
    }

    var body: some View {
        Group {
            switch shown {
            case .native:
                NativePlayerScreen(context: context, onPlayNext: onPlayNext,
                                   onFallback: context.forcedEngine == .native ? nil : { _, secondsPlayed, startedPlaying in
                                       nativeSecondsPlayed = secondsPlayed
                                       // Readiness, not the play clock (review r2 #1): only a native
                                       // item that never became ready shortens mpv's start budget.
                                       nativeFailedBeforeStart = !startedPlaying
                                       forcedMPV = true
                                   },
                                   routingNote: decision?.displayNote,
                                   onPlaybackFailed: annotated(.native),
                                   onPlaybackHealthy: onPlaybackHealthy)
            case .mpv:
                MPVPlayerScreen(context: context, onPlayNext: onPlayNext,
                                routingNote: forcedMPV ? String(localized: "mpv \u{00B7} fallback") : decision?.displayNote,
                                onPlaybackFailed: annotated(.mpv),
                                onPlaybackHealthy: onPlaybackHealthy,
                                startWatchdogShortened: forcedMPV && nativeFailedBeforeStart,
                                nativeSecondsPlayedBeforeFallback: forcedMPV ? nativeSecondsPlayed : 0)
            case .deciding:
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().scaleEffect(1.5)
                }
            }
        }
        .task(id: context.id) { await decideEngine() }
        // Hosts that swap the context without rebuilding this view keep mpv pinned (`forcedMPV`),
        // but the native engine never played the new context: its carried-over state is reset.
        .onChange(of: context.id) { _, _ in
            nativeSecondsPlayed = 0
            nativeFailedBeforeStart = false
        }
    }

    /// Tags a failure with the reporting engine and whether the other engine could take over.
    private func annotated(_ engine: PlaybackEngine) -> ((PlaybackFailure) -> Void)? {
        guard let onPlaybackFailed else { return nil }
        // A forced-mpv run (a retry, or the native fallback) never offers native back: the alert
        // would alternate engines. Explicit here, not left to when the representable captures this.
        let eligibleForNative: Bool = {
            guard context.forcedEngine == nil, !forcedMPV, let probe else { return false }
            return PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: false).engine == .native
        }()
        return { failure in
            var tagged = failure
            tagged.engine = engine
            tagged.otherEngineEligible = engine == .native ? true : eligibleForNative
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

        guard nativeDVEnabled else { return }

        let url = context.url
        let requestHeaders = context.requestHeaders
        let felToMpv = UserDefaults.standard.bool(forKey: PlayerTuning.dvP7FelMpvKey)
        let (result, probeResult) = await Task.detached(priority: .utility) {
            let probe = MediaProbe.probe(url: url, timeoutSec: 4, requestHeaders: requestHeaders)
            return (PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: felToMpv), probe)
        }.value
        print("[PlayerRouter] \(result.engine.rawValue) — \(result.reason) — \(context.title)")
        probe = probeResult
        decision = result
    }
}
