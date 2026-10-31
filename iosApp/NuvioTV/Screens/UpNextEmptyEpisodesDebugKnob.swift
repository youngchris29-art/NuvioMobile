import Foundation

/// DEBUG harness knob (BUG-229): `-debug.upNextEmptyEpisodes YES` hands the up-next engine an EMPTY
/// episode list at every player start: the state a quick auto-picked source from Continue Watching
/// (Auto-Play Best Source) or Detail's Play leaves when it beats the stream picker's own episode
/// fetch. The engine's late fetch (`NextEpisodeEngine.fetchEpisodesIfMissing`) then has to resolve
/// the next episode, so a device pass can confirm the card still arms without winning that race.
///
/// Launch-latched (read once, like the other `debug.*` knobs), and always off in Release, like the
/// other knobs that change behaviour (`TmdbDebugOverride`, `AmoledDebugOverride`). Logs one line
/// each time it empties a list.
nonisolated enum UpNextEmptyEpisodesDebugKnob {
    static let debugKey = "debug.upNextEmptyEpisodes"

    static let enabled: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: debugKey)
        #else
        return false
        #endif
    }()

    /// `context` with its episode list emptied while the knob is on; unchanged otherwise.
    static func apply(to context: PlaybackContext) -> PlaybackContext {
        guard enabled, !context.episodes.isEmpty else { return context }
        print("[UpNext] debug.upNextEmptyEpisodes: start episode list emptied (\(context.episodes.count) episodes dropped)")
        var emptied = context
        emptied.episodes = []
        return emptied
    }
}
