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
struct PlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)? = nil

    @State private var decision: EngineDecision?
    /// Set when the native path fails; pins this context to mpv.
    @State private var forcedMPV = false

    private var nativeDVEnabled: Bool { UserDefaults.standard.bool(forKey: PlayerTuning.nativeDVKey) }

    private enum Shown { case deciding, native, mpv }
    private var shown: Shown {
        if forcedMPV { return .mpv }
        guard nativeDVEnabled else { return .mpv }       // flag off → mpv immediately, no probe wait
        guard let decision else { return .deciding }
        return decision.engine == .native ? .native : .mpv
    }

    var body: some View {
        Group {
            switch shown {
            case .native:
                NativePlayerScreen(context: context, onPlayNext: onPlayNext,
                                   onFallback: { _ in forcedMPV = true },
                                   routingNote: decision?.displayNote)
            case .mpv:
                MPVPlayerScreen(context: context, onPlayNext: onPlayNext,
                                routingNote: forcedMPV ? String(localized: "mpv \u{00B7} fallback") : decision?.displayNote)
            case .deciding:
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().scaleEffect(1.5)
                }
            }
        }
        .task(id: context.id) { await decideEngine() }
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
        let felToMpv = UserDefaults.standard.bool(forKey: PlayerTuning.dvP7FelMpvKey)
        let result = await Task.detached(priority: .utility) {
            let probe = MediaProbe.probe(url: url, timeoutSec: 4)
            return PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true, dvP7FelToMpv: felToMpv)
        }.value
        print("[PlayerRouter] \(result.engine.rawValue) — \(result.reason) — \(context.title)")
        decision = result
    }
}
