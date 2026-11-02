import UIKit

// Aether Phase 1, W2-B: what `MPVPlayerScreen`'s representable needs from a player controller, so
// one representable can build mpv today and the Aether controller in W3-A. The screen itself only
// touches `MPVPlaybackState`; the chrome (bar, pills, popovers, shelves) reads that state.

/// A player controller the shared chrome hosts. `MPVTVPlayerViewController` conforms; mpv-only
/// knobs (`forcesGpuNext`) stay on the concrete class and are set in its own branch.
protocol ChromePlayerController: UIViewController {
    /// Menu exit: the SwiftUI cover dismisses.
    var onExit: (() -> Void)? { get set }
    /// Fired at most once, on main, when this engine cannot give the viewer playback.
    var onPlaybackFailed: ((PlaybackFailure) -> Void)? { get set }
    /// Fired once, on main, when the seconds played first reach the healthy mark.
    var onPlaybackHealthy: ((Double) -> Void)? { get set }
    /// The engine before this one failed before start: the shortened start budget applies.
    var startWatchdogShortened: Bool { get set }
    /// Seconds the engine before this one played (added to this one's seconds played).
    var secondsPlayedBeforeFallback: Double { get set }
}

/// What a controller hands `PlayerScreen` when it gives up for mpv (the Aether controller only, in
/// Phase 1; the native engine keeps its own `onFallback`).
struct PlaybackHandoff: Equatable {
    /// Where the failing engine was (finite, >= 0).
    let positionSec: Double
    /// Seconds it actually played (playing ticks only).
    let secondsPlayed: Double
    /// The first frame was shown.
    let startedPlaying: Bool
    /// `.local` / `.network` per the W1-A ladder; diagnostic only.
    let kind: PlaybackFailureKind
}
