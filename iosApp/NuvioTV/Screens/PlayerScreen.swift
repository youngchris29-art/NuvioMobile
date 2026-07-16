import SwiftUI

/// Engine dispatcher for all video playback in NuvioTV. Call sites present `PlayerScreen`; it
/// decides which engine actually renders the stream so the choice stays invisible to callers.
///
/// Phase 1 probes the stream and computes a routing decision (`PlayerEngineRouter`) that is logged
/// and surfaced in the player's Stream Info overlay, but playback still always goes through the
/// libmpv-backed `MPVPlayerScreen` — flipping the switch to the native AVPlayer path happens in a
/// later phase. Gated by `PlayerTuning.nativeDVKey`. See docs/tvos-hybrid-player-plan.md.
struct PlayerScreen: View {
    let context: PlaybackContext
    /// Present when a caller can swap the playing context (source switch / next-episode autoplay).
    var onPlayNext: ((PlaybackContext) -> Void)? = nil

    /// The routing decision's short label, shown in Stream Info once the async probe finishes.
    @State private var routingNote: String?

    var body: some View {
        MPVPlayerScreen(context: context, onPlayNext: onPlayNext, routingNote: routingNote)
            .task(id: context.id) { await computeRouting() }
    }

    /// Probe the stream off the main thread (hard-bounded), route it, and record the decision. Never
    /// affects playback in this phase — purely diagnostic.
    private func computeRouting() async {
        #if DEBUG
        let failures = PlayerEngineRouter.selfCheckFailures()
        if failures.isEmpty {
            print("[PlayerRouter] self-check passed")
        } else {
            failures.forEach { print("[PlayerRouter] \u{26A0}\u{FE0F} \($0)") }
        }
        #endif

        let nativeDVEnabled = UserDefaults.standard.bool(forKey: PlayerTuning.nativeDVKey)
        let url = context.url
        let decision = await Task.detached(priority: .utility) {
            let probe = MediaProbe.probe(url: url, timeoutSec: 4)
            return PlayerEngineRouter.route(probe: probe, nativeDVEnabled: nativeDVEnabled)
        }.value

        print("[PlayerRouter] \(decision.engine.rawValue) — \(decision.reason) — \(context.title)")
        routingNote = decision.displayNote
    }
}
