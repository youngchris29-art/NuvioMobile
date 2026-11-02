import UIKit

// Aether Phase 1, W2-B: the seam between the Siri-remote transport (presses, hold/step/scan, swipe
// scrub, preview, commit, Menu precedence, bar hide) and the engine that plays. The mpv controller
// conforms to both protocols (`MPVPlayerView.swift`, bottom); each member is a thin wrapper over
// the code that already ran there, so mpv sees the same commands, on the same queue, in the same
// order.

/// How a transport seek lands. mpv maps each to its `seek` flags; Aether to `seek(toSec:exact:)`.
nonisolated enum TransportSeekMode: Equatable, Sendable {
    /// mpv "relative" (one Left/Right click): `deltaSec` from wherever mpv is.
    case relative(deltaSec: Double)
    /// mpv "absolute" (chapter, chip, auto-skip, replay).
    case absolute
    /// mpv "absolute+keyframes": the first stage of a two-stage commit.
    case absoluteKeyframes
    /// mpv "absolute+exact": the second stage, a cached commit, a scan return.
    case absoluteExact
}

/// The playback operations the shared remote implementation needs. Main thread only; every read
/// is a cached value (never a synchronous engine query: the BUG-2/BUG-3 rule).
protocol PlayerTransportEngine: AnyObject {
    /// The engine has a live handle (mpv: `mpv != nil`).
    var canTransport: Bool { get }
    /// The media has loaded (mpv: `MPV_EVENT_FILE_LOADED` seen).
    var mediaLoaded: Bool { get }
    var transportPositionSec: Double { get }
    var transportDurationSec: Double { get }
    var transportIsPaused: Bool { get }

    /// The generation the last seek got; the next `issueSeek` returns this plus one.
    var seekGeneration: Int { get }
    /// The engine's seek funnel: tells the skip planner first (unless `planner` is false), bumps
    /// and returns the generation, runs the seek off-main, calls `onRejected` on main if refused.
    @discardableResult
    func issueSeek(kind: SkipSegmentPlanner.SeekKind, targetSec: Double?, fromSec: Double?,
                   mode: TransportSeekMode, planner: Bool, onRejected: (() -> Void)?) -> Int
    /// Runs `body` on main once seek `generation` has started (mpv: MPV_EVENT_SEEK); on the next
    /// main turn when it already has. The two-stage commit's exact stage waits on this.
    func whenSeekStarted(generation: Int, _ body: @escaping () -> Void)

    /// A seek the skip planner tracks is in flight (its target may be unknown).
    var hasSeekInFlight: Bool { get }
    /// That seek's target, nil when none is in flight or its target is unknown.
    var seekInFlightTargetSec: Double? { get }
    /// `SkipSegmentPlanner.noteInput`: true when the press revealed an auto-hidden chip.
    func noteTransportInput(now: TimeInterval) -> Bool
    /// Re-evaluates the skip chip from the cached position (a press revealed it).
    func refreshSkipPrompt()
    func refineSkipSeek(targetSec: Double, fromSec: Double, now: TimeInterval)
    func recordUserSpan(fromSec: Double, toSec: Double)

    func togglePause()
    /// Scan starts: mute, pitch correction off, `rate`x.
    func beginScan(rate: Int)
    func setScanRate(_ rate: Int)
    /// Scan ends: the user's speed back, mute and pitch correction as they were.
    func endScan(restoreSpeed: Double)
    func cycleAspect()

    var seekPreviewSource: SeekPreviewSource? { get }
    /// A scrub ended: the engine's own preview work for it stops (mpv: the keyframe thumbnailer).
    func scrubPreviewEnded(now: TimeInterval)
    /// A scrub lookup found no frame near `targetSec` (or one too far off).
    func scrubPreviewMissed(targetSec: Double, matchSec: Double?)
}

/// The UIKit side the transport needs from the controller that owns it.
protocol PlayerTransportHost: UIViewController {
    /// Settings › Pause Info Card (the paused bar-hide rule reads it).
    var pauseCardEnabled: Bool { get }
    /// For the `[MenuProbe]` lines only.
    var isLeavingPlayerForLog: Bool { get }
    /// Walk the tracks before a popover or shelf opens.
    func prepareTracksForPanel()
    /// Menu exit: close failover reporting, then leave the player.
    func exitPlayer()
}
