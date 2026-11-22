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
    /// W4: the auto-picked context's start-up limit in seconds (nil: none). Set by the host
    /// (`PlaybackFailoverPolicy.startupLimit(for:settings:)`); a manual pick never carries one.
    var startupLimitSec: Double? = nil
    /// W4: the limit passed with no first frame. The engine keeps loading; the host decides
    /// whether another source replaces it. Fired at most once per context.
    var onStartupLimitReached: (() -> Void)? = nil
    /// W4: the first frame showed, on whichever engine. Fired at most once per context.
    var onPlaybackStarted: (() -> Void)? = nil
    /// W4 review r1: the viewer made a choice of their own in the player (a Sources pick, even one
    /// still resolving; an episode jump; Play Next). The host invalidates its automatic walks.
    var onViewerChoice: ((UUID) -> Void)? = nil
    /// Review r2: that choice will not reach the screen (same id): the host ends its pending state.
    var onViewerChoiceAbandoned: ((UUID) -> Void)? = nil

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
    /// W4: the start-up limit's clock (a box, so its timer never captures this struct). Armed on
    /// appear and on a context change, re-armed by an engine handoff before the first frame,
    /// stood down by the first frame, cancelled on disappear.
    @StateObject private var startupClock = PlayerStartupLimitClock()
    /// spec-mpv-return §3.3, §3.6: the payload the current mpv controller starts from (nil: a normal
    /// start), the mpv controller generation (its `.id` and lease token), the last accepted return
    /// generation, and the display-criteria lease every mpv controller of this screen shares.
    @State private var returnPayload: PlayerReturnHandoff?
    @State private var mpvGeneration = 0
    /// Code r4-3: the one owner of the return generation for every mpv controller this screen creates.
    @State private var returnEpoch = PlayerReturnEpoch()
    @State private var displayLease = DisplayCriteriaLease()
    /// Code r3-3: a replaced mpv controller's tracker stops settle before the fresh one's starts.
    private var trackerChain: TrackerReturnChain { .shared }
    /// Code r3-2: a return-start failure with no host callback (the library) gets this screen's own alert.
    @State private var localReturnFailure: PlaybackFailure?
    /// The held start the local alert's "Try with mpv" retries at (the next mpv controller's context).
    @State private var localRetryStart: PlayerReturnHandoff.Start?
    @Environment(\.dismiss) private var dismissPlayer

    /// The native screen delivers its return transfer just before `onFallback` (a box, so the two
    /// closures share it without a state round trip).
    @State private var pendingTransfer = PlayerReturnTransferSlot()

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
                                       // spec-mpv-return §3.3: the return rule's handoff (delivered just
                                       // before this) seeds the mpv start; outside a return there is none.
                                       if let transfer = pendingTransfer.take() {
                                           acceptTransfer(transfer, origin: .nativeReturn, playedSec: secondsPlayed)
                                       }
                                       // W4: mpv gets the full start-up limit (a no-op once a frame showed).
                                       startupClock.noteHandoff()
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
                                   onOpenTitle: onOpenTitle,
                                   onPlaybackStarted: noteStarted,
                                   onViewerChoice: onViewerChoice,
                                onViewerChoiceAbandoned: onViewerChoiceAbandoned,
                                onReturnTransfer: { pendingTransfer.set($0) })
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
                                    if let transfer = handoff.returnTransfer {
                                        acceptTransfer(transfer, origin: .aetherReturn, playedSec: handoff.secondsPlayed)
                                    }
                                    // W4: mpv gets the full start-up limit (a no-op once a frame showed).
                                    startupClock.noteHandoff()
                                    nativeSecondsPlayed = handoff.secondsPlayed
                                    // Readiness, not the play clock: only an Aether run that never showed
                                    // a frame shortens mpv's start budget.
                                    nativeFailedBeforeStart = !handoff.startedPlaying
                                    handoffPositionSec = handoff.positionSec
                                    forcedMPV = true
                                },
                                startupLimitSec: startupLimitSec,
                                onPlaybackStarted: noteStarted,
                                onViewerChoice: onViewerChoice,
                                onViewerChoiceAbandoned: onViewerChoiceAbandoned)
            case .mpv:
                MPVPlayerScreen(context: mpvContext, onPlayNext: onPlayNext,
                                routingNote: mpvRoutingNote,
                                onPlaybackFailed: annotated(.mpv),
                                onPlaybackHealthy: onPlaybackHealthy,
                                startWatchdogShortened: forcedMPV && nativeFailedBeforeStart,
                                nativeSecondsPlayedBeforeFallback: forcedMPV ? nativeSecondsPlayed : 0,
                                forcesGpuNext: mpvForcesGpuNext,
                                handoffPositionSec: forcedMPV ? handoffPositionSec : nil,
                                onOpenTitle: onOpenTitle,
                                startupLimitSec: startupLimitSec,
                                onPlaybackStarted: noteStarted,
                                onViewerChoice: onViewerChoice,
                                onViewerChoiceAbandoned: onViewerChoiceAbandoned,
                                returnHandoff: returnPayload,
                                displayLease: displayLease,
                                leaseToken: mpvGeneration,
                                onReturnReplace: { payload, prepare in acceptReturn(payload, prepare: prepare) },
                                trackerChain: trackerChain,
                                onReturnFailed: { failure in noteLocalReturnFailure(failure) },
                                returnGenerationBase: returnEpoch.baseForNextController)
                // One mpv controller per accepted return payload (spec-mpv-return §3.1).
                .id(mpvGeneration)
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
        // W4: one start-up clock per context (the probe counts: it is the first startup stage).
        // `arm` is idempotent per context id: modifiers on this `Group` reach each engine view it
        // switches to, so `onAppear` runs again on deciding → native → mpv. No `onDisappear`
        // cancel for the same reason (the deciding view disappearing is not the player leaving);
        // the clock's timer goes with the `@StateObject` when the player closes, and the host
        // drops a callback for a context it no longer presents.
        .onAppear { armStartupLimit() }
        // Hosts that swap the context without rebuilding this view keep mpv pinned (`forcedMPV`),
        // but the native engine never played the new context: its carried-over state is reset.
        .onChange(of: context.id) { _, _ in
            nativeSecondsPlayed = 0
            nativeFailedBeforeStart = false
            handoffPositionSec = nil
            returnPayload = nil
            localRetryStart = nil
            returnEpoch.reset()
            armStartupLimit()
        }
        // spec-mpv-return §3.7 (M6): a background before the start cancels the start-up limit for the
        // context, on every engine; the engine's own watchdog stays the only start budget.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            startupClock.noteBackgrounded()
        }
        // Code r3-2: the same manual alert as the picker's, with Try with mpv at the held start and Close
        // in place of the picker's actions (existing strings only).
        .alert(
            "Couldn\u{2019}t play this source",
            isPresented: Binding(get: { localReturnFailure != nil }, set: { if !$0 { localReturnFailure = nil } }),
            presenting: localReturnFailure
        ) { failure in
            Button(LocalizedStringKey("Try with mpv")) {
                localReturnFailure = nil
                retryLocally(failure)
            }
            Button("Close", role: .cancel) {
                localReturnFailure = nil
                dismissPlayer()
            }
        } message: { failure in
            Text(verbatim: failure.reason)
        }
    }

    /// The mpv screen's context: a local retry carries the held start.
    private var mpvContext: PlaybackContext {
        guard let start = localRetryStart else { return context }
        var ctx = context
        ctx.returnStart = start
        return ctx
    }

    /// Code r3-2: a return-start failure when the host gave no failure callback.
    private func noteLocalReturnFailure(_ failure: PlaybackFailure) {
        guard onPlaybackFailed == nil else { return }
        print("[MPVReturn] return failure -> local alert start=\(failure.returnRecovery?.logToken ?? "-")")
        localReturnFailure = failure
    }

    /// "Try with mpv": a fresh mpv controller (no payload) at the held start, as the picker's retry does.
    private func retryLocally(_ failure: PlaybackFailure) {
        guard let plan = PlaybackFailoverPolicy.returnAlert(for: context, failure: failure, pickerVideoId: context.videoId) else { return }
        localRetryStart = plan.retry.returnStart
        returnPayload = nil
        forcedMPV = true
        mpvGeneration += 1
        print("[MPVReturn] local retry start=\(plan.retry.returnStart?.logToken ?? "-") ctl=\(mpvGeneration)")
    }

    /// spec-mpv-return §3.6: the mpv controller asks for its replacement. In one main turn: validate
    /// (identity, context, generation), `prepare` the old controller, move the lease to the fresh
    /// controller's token, set the payload and bump the generation (the `.id`).
    private func acceptReturn(_ payload: PlayerReturnHandoff, prepare: () -> Void) -> Bool {
        switch returnEpoch.accept(payload, current: PlaybackIdentity.current(), contextID: context.id) {
        case .discard(let reason):
            print("[MPVReturn] payload discarded reason=\(reason.rawValue) g=\(payload.returnGeneration)")
            return false
        case .accept:
            prepare()
            let next = mpvGeneration + 1
            displayLease.transfer(to: next)
            returnPayload = payload
            mpvGeneration = next
            print("[MPVReturn] payload accepted g=\(payload.returnGeneration) ctl=\(next)")
            return true
        }
    }

    /// spec-mpv-return §3.3 (M10): a native or Aether return rule handed off to mpv. The payload is
    /// validated the same way; a stale or mismatched one is dropped and mpv starts as today.
    private func acceptTransfer(_ transfer: PlayerReturnTransfer, origin: PlayerReturnHandoff.Origin, playedSec: Double) {
        let payload = transfer.payload(contextID: context.id, streamKey: context.streamKey, origin: origin,
                                       playedSec: playedSec)
        switch returnEpoch.accept(payload, current: PlaybackIdentity.current(), contextID: context.id) {
        case .discard(let reason):
            print("[MPVReturn] payload discarded reason=\(reason.rawValue) g=\(payload.returnGeneration) origin=\(origin)")
        case .accept:
            returnPayload = payload
            print("[MPVReturn] payload accepted g=\(payload.returnGeneration) origin=\(origin) start=\(payload.start.logToken) intent=\(payload.intent == .play ? "play" : "pause")")
        }
    }

    /// W4: arms the start-up clock for the current context; nothing without a limit or a host.
    private func armStartupLimit() {
        startupClock.arm(contextID: context.id, limitSeconds: startupLimitSec, onReached: onStartupLimitReached)
    }

    /// W4: the first frame showed on some engine: the limit stands down and the host hears it once.
    private func noteStarted() {
        guard startupClock.noteStarted() else { return }
        onPlaybackStarted?()
    }

    /// B10 (BUG-166): mpv renders a Dolby Vision profile 5 stream with `gpu-next`. The router flags
    /// the streams it sends to mpv; a native run that fell over carries the same probe.
    private var mpvForcesGpuNext: Bool {
        // Aether On only: `forcedEngine == .mpv` makes the router return the forced decision before its
        // gpu-next check. With Aether Off the router never sees it (`forcedEngineForRouting`).
        if forcedMPV || (aetherEnabled && context.forcedEngine == .mpv) {
            return PlayerEngineRouter.mpvNeedsGpuNext(probe: probe)
        }
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
            // An Aether rate limit or offline failure never offers mpv: it meets the same wall.
            case .native: tagged.otherEngineEligible = context.forcedEngine == nil
            case .aether:
                tagged.otherEngineEligible = context.forcedEngine == nil
                    && AetherFailurePlan.offersMpvRetry(failure.kind)
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
        let forced = PlayerEngineRouter.forcedEngineForRouting(context.forcedEngine, aether: aetherOptions)
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
        let device = DeviceLanguagePreferences.shared.preferredLanguageCodes()
        let targets = settings.map {
            AetherSubtitleRouting.preferredTargets(primary: $0.preferredSubtitleLanguage,
                                                   secondary: $0.secondaryPreferredSubtitleLanguage,
                                                   deviceLanguages: device)
        } ?? []
        // The same audio targets the Aether load request carries (`makeLoadRequest`).
        let audioTargets = settings.map {
            PlayerLanguagePreferencesKt.resolvePreferredAudioLanguageTargets(
                preferredAudioLanguage: $0.preferredAudioLanguage,
                secondaryPreferredAudioLanguage: $0.secondaryPreferredAudioLanguage,
                deviceLanguages: device,
                contentOriginalLanguage: PlayerAudioLanguagePlan.originalLanguage(for: context))
        } ?? []
        return AetherRoutingOptions(
            enabled: true,
            dualLayerDV: AetherTuning.isDualLayerDVEnabled(),
            styledSubsToMpv: AetherTuning.keepStyledSubsOnMpv(),
            sourceURL: context.url,
            preferredSubtitleTargets: targets,
            subtitlesOff: off,
            useForcedSubtitles: settings?.subtitleStyle.useForcedSubtitles ?? false,
            preferredAudioTargets: audioTargets)
    }
}

/// spec-mpv-return §3.3: holds a native return transfer between its two callbacks.
final class PlayerReturnTransferSlot {
    private var value: PlayerReturnTransfer?
    func set(_ transfer: PlayerReturnTransfer) { value = transfer }
    func take() -> PlayerReturnTransfer? { defer { value = nil }; return value }
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
