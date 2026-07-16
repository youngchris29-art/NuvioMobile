import SwiftUI

/// Engine dispatcher for all video playback in NuvioTV. Call sites present `PlayerScreen`; it
/// decides which engine actually renders the stream so the choice stays invisible to callers.
///
/// Phase 0 always uses the libmpv-backed `MPVPlayerScreen`. Later phases add a native AVPlayer
/// path (true Dolby Vision output + hardware decode, fed by an on-device MKV→fMP4 remux) selected
/// per-file by `PlayerEngineRouter` and gated by `PlayerTuning.nativeDVKey`, with MPV as the
/// universal fallback. See docs/tvos-hybrid-player-plan.md.
struct PlayerScreen: View {
    let context: PlaybackContext
    /// Present when a caller can swap the playing context (source switch / next-episode autoplay).
    var onPlayNext: ((PlaybackContext) -> Void)? = nil

    var body: some View {
        // Single engine for now; routing is introduced in Phase 1+ without changing this signature.
        MPVPlayerScreen(context: context, onPlayNext: onPlayNext)
    }
}
