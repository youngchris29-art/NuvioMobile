import SharedCore
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
    /// P5 B22: a post-play More Like This poster was chosen. The host stores it and navigates
    /// after its player cover dismisses; nil = no row.
    var onOpenTitle: ((MetaPreview) -> Void)? = nil

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
    /// P4 B24: Settings › Playback › Loading Screen, read once (default on).
    @State private var loadingOverlayOn = PlayerLoadingOverlaySetting.enabled

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
                                   onPlaybackHealthy: onPlaybackHealthy,
                                   onOpenTitle: onOpenTitle)
            case .mpv:
                MPVPlayerScreen(context: context, onPlayNext: onPlayNext,
                                routingNote: mpvRoutingNote,
                                onPlaybackFailed: annotated(.mpv),
                                onPlaybackHealthy: onPlaybackHealthy,
                                startWatchdogShortened: forcedMPV && nativeFailedBeforeStart,
                                nativeSecondsPlayedBeforeFallback: forcedMPV ? nativeSecondsPlayed : 0,
                                forcesGpuNext: mpvForcesGpuNext,
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
        }
    }

    /// B10 (BUG-166): mpv renders a Dolby Vision profile 5 stream with `gpu-next`. The router flags
    /// the streams it sends to mpv; a native run that fell over carries the same probe.
    private var mpvForcesGpuNext: Bool {
        if forcedMPV { return PlayerEngineRouter.mpvNeedsGpuNext(probe: probe) }
        return decision?.prefersGpuNext ?? false
    }

    /// The Stream Info / loading line for the mpv screen: the router's note, or "mpv · fallback"
    /// after a native failure, "· gpu-next" appended when B10 forces it.
    private var mpvRoutingNote: String? {
        guard forcedMPV else { return decision?.displayNote }
        let note = String(localized: "mpv \u{00B7} fallback")
        return mpvForcesGpuNext ? "\(note) \u{00B7} gpu-next" : note
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
            // A native run that was itself a forced retry (after mpv failed) never offers mpv back.
            tagged.otherEngineEligible = engine == .native ? context.forcedEngine == nil : eligibleForNative
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
        let probeTimeoutSec = 4.0
        let (result, probeResult, probeMs) = await Task.detached(priority: .utility) {
            let t0 = ProcessInfo.processInfo.systemUptime
            let probe = MediaProbe.probe(url: url, timeoutSec: probeTimeoutSec, requestHeaders: requestHeaders)
            let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            return (PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: felToMpv), probe, ms)
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
