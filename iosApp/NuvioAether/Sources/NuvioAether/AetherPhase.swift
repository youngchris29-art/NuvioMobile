import CoreGraphics
import Foundation

// Session phase and the pure reducer that derives it from the engine's playback phase, plus the pure cue
// flattener. No engine import.

public enum AetherBufferingReason: Sendable, Equatable {
    case seeking
    case rebuffering
    case stalled(reconnecting: Bool)
}

/// What the chrome shows. Derived from the engine's `playbackPhase`, the only surface that tracks motion.
public enum AetherPhase: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering(AetherBufferingReason)
    /// Terminal: the source played to its end. Seek and play are refused until the next `load` (Replay).
    case ended
    /// Terminal for this load generation, emitted once.
    case failed(AetherFailure)

    public var isTerminal: Bool {
        switch self {
        case .ended, .failed: return true
        default: return false
        }
    }

    /// Short label for logs and the debug harness ("playing", "buffering(seeking)").
    public var label: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .playing: return "playing"
        case .paused: return "paused"
        case .buffering(.seeking): return "buffering(seeking)"
        case .buffering(.rebuffering): return "buffering(rebuffering)"
        case .buffering(.stalled(let reconnecting)): return "buffering(stalled reconnecting=\(reconnecting))"
        case .ended: return "ended"
        case .failed(let f): return "failed(\(f.kind.token))"
        }
    }
}

/// The engine's `PlaybackPhase` in fork types.
public enum AetherEnginePhase: Sendable, Equatable {
    case idle, loading, playing, paused, seeking, rebuffering
    case stalled(reconnecting: Bool)
    case ended
    case error(String)
}

public enum AetherPhaseReducer {
    /// The next session phase. `.ended` and `.failed` hold until the next load resets the phase to
    /// `.loading` (the session does that, not this reducer). An engine `.error` never sets the phase by
    /// itself: the failure arrives through the ledger, which owns the `.failed` transition.
    public static func reduce(_ current: AetherPhase, engine: AetherEnginePhase) -> AetherPhase {
        if current.isTerminal { return current }
        switch engine {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .buffering(.seeking)
        case .rebuffering: return .buffering(.rebuffering)
        case .stalled(let reconnecting): return .buffering(.stalled(reconnecting: reconnecting))
        case .ended: return .ended
        case .error: return current
        }
    }
}

// MARK: - Cue flattening

/// One engine `SubtitleCue` body in fork types, before flattening.
public enum AetherCueSource: @unchecked Sendable {
    case text(String)
    /// Styled runs (`.richText`); Phase 1 joins their text.
    case runs([String])
    /// `SubtitleImage`: rendered bitmap, rect in [0, 1], canvas size, forced flag.
    case image(CGImage, position: CGRect, canvasSize: CGSize, isForced: Bool)
}

public enum AetherCueFlattener {
    /// `.richText` becomes plain text (`SubtitleCue.text`'s rule: runs joined with nothing between them),
    /// a bitmap keeps its rect and canvas and carries its forced flag; text cues are never forced (the
    /// track says that). Placement is kept for text cues only.
    public static func flatten(id: Int, startSec: Double, endSec: Double, source: AetherCueSource,
                               alignment: Int? = nil, anchor: CGPoint? = nil) -> AetherCue {
        switch source {
        case .text(let s):
            return AetherCue(id: id, startSec: startSec, endSec: endSec, body: .text(s), isForced: false,
                             alignment: alignment, anchor: anchor)
        case .runs(let runs):
            return AetherCue(id: id, startSec: startSec, endSec: endSec, body: .text(runs.joined()),
                             isForced: false, alignment: alignment, anchor: anchor)
        case .image(let image, let position, let canvas, let forced):
            return AetherCue(id: id, startSec: startSec, endSec: endSec,
                             body: .image(image, normalizedRect: position, canvasSize: canvas),
                             isForced: forced, alignment: nil, anchor: nil)
        }
    }
}
