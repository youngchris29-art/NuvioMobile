import AVKit
import SwiftUI

// Phase 3 of the hybrid player: the native AVPlayer playback screen, chosen by `PlayerScreen` for
// Dolby-Vision-eligible files. Shows a preparing state while the on-device remux spins up, then a
// full AVPlayerViewController (native tvOS transport, scrubbing, and audio/subtitle menus). Watch
// progress, resume, and Trakt live in `NativePlaybackCoordinator`; next-episode autoplay reuses
// `NextEpisodeEngine`. A pre-playback failure calls `onFallback` so the dispatcher can hand the same
// context to the mpv player. See docs/tvos-hybrid-player-plan.md.
struct NativePlayerScreen: View {
    let context: PlaybackContext
    var onPlayNext: ((PlaybackContext) -> Void)?
    /// Called with the last known position when the native path can't play — dispatcher → mpv.
    var onFallback: ((Double) -> Void)?

    @StateObject private var coordinator: NativePlaybackCoordinator
    @StateObject private var upNext: NextEpisodeEngine
    @Environment(\.dismiss) private var dismiss

    init(context: PlaybackContext,
         onPlayNext: ((PlaybackContext) -> Void)? = nil,
         onFallback: ((Double) -> Void)? = nil) {
        self.context = context
        self.onPlayNext = onPlayNext
        self.onFallback = onFallback
        _coordinator = StateObject(wrappedValue: NativePlaybackCoordinator(context: context))
        _upNext = StateObject(wrappedValue: NextEpisodeEngine(context: context, onPlayNext: onPlayNext ?? { _ in }))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch coordinator.phase {
            case .preparing:
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.6)
                    Text("Preparing Dolby Vision\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .playing:
                if let player = coordinator.player {
                    AVPlayerContainer(player: player)
                        .ignoresSafeArea()
                }
            case .failed:
                // Hand back to the dispatcher, which re-presents the mpv player for this context.
                Color.clear.onAppear {
                    if let onFallback { onFallback(coordinator.lastPositionSec) } else { dismiss() }
                }
            }

            // Non-interactive up-next card (the countdown auto-plays via onProgress → onPlayNext).
            if upNext.phase != .hidden {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        UpNextCard(engine: upNext).padding(60)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: upNext.phase)
        .onAppear {
            coordinator.onTick = { [weak upNext] position, duration in
                upNext?.onProgress(positionSec: position, durationSec: duration)
            }
            coordinator.start()
            // Only orchestrate up-next when a presenter can swap contexts (series autoplay).
            if onPlayNext != nil { upNext.startNative() }
        }
        .onDisappear {
            coordinator.stop()
            upNext.stop()
        }
    }
}

/// Thin AVPlayerViewController wrapper — gives the full native tvOS player UI (transport, scrubbing,
/// Now Playing, and the built-in audio/subtitle selection menus for whatever tracks the remux
/// included).
private struct AVPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
