import Foundation
import SharedCore

#if DEBUG
/// Home Stage & Strip (W3): a DEBUG-only, guest-only Continue Watching seed for the UI tests, the
/// watch-progress twin of the collections seed (`HomeViewModel.applyCollectionsSeedIfRequested`).
/// The FA87 fixture is a guest profile with no watch history, so without this nothing can put a
/// Continue Watching row on Home (Gate 1 finding 3).
///
///     -debug.continueWatchingSeedJsonB64 <base64 of a JSON array>
///
/// Base64 for the same reason as the collections seed: the launch-argument domain parses a
/// bracket-led value as an old-style plist and drops raw JSON. Each element:
///
///     {"type":"movie","id":"tt0111161","title":"The Shawshank Redemption",
///      "positionMin":60,"durationMin":142}
///
/// plus, optionally, `"videoId"` (default: `id` for a movie, `"<id>:<season>:<episode>"` for an
/// episode), `"season"`, `"episode"`, `"episodeTitle"`, `"poster"`, `"background"`, and
/// `"remove": true`, which clears that entry instead of writing it (the tests' cleanup relaunch).
///
/// Entries go through the shared repository's own write path (`upsertPlaybackProgress`, exactly as
/// `PlaybackProgressRecorder` records a playback, with `syncRemote: false`), so the Continue
/// Watching row reads them like any watched title. Applied once per launch, from the same place in
/// the Home pipeline as the collections seed. Refused on a signed-in cloud account with the
/// collections seed's own rule (`collectionsSeedRefusal`), so test data never reaches a real
/// account's history; a refusal does not latch, so a later Home start in the same launch retries.
@MainActor
enum ContinueWatchingDebugSeed {
    static let argumentKey = "debug.continueWatchingSeedJsonB64"

    private static var didApply = false

    static func applyIfRequested() {
        guard !didApply else { return }
        guard let b64 = UserDefaults.standard.string(forKey: argumentKey), !b64.isEmpty else { return }
        if let refusal = HomeViewModel.collectionsSeedRefusal(authState: AuthRepository.shared.state.value_) {
            NSLog("[ContinueWatchingSeed] applied=false refused=%@", refusal)
            return
        }
        didApply = true
        guard let data = Data(base64Encoded: b64),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            NSLog("[ContinueWatchingSeed] applied=false error=the payload is not base64 of a JSON array")
            return
        }
        WatchProgressRepository.shared.ensureLoaded()
        var written = 0
        var removed = 0
        var skipped = 0
        for entry in entries {
            guard let type = entry["type"] as? String, !type.isEmpty,
                  let id = entry["id"] as? String, !id.isEmpty else {
                skipped += 1
                continue
            }
            let season = (entry["season"] as? NSNumber)?.intValue
            let episode = (entry["episode"] as? NSNumber)?.intValue
            let videoId: String
            if let explicit = entry["videoId"] as? String, !explicit.isEmpty {
                videoId = explicit
            } else if let season, let episode {
                videoId = "\(id):\(season):\(episode)"
            } else {
                videoId = id
            }
            if (entry["remove"] as? Bool) == true {
                WatchProgressRepository.shared.clearProgress(videoId: videoId, parentMetaId: id)
                removed += 1
                continue
            }
            let positionMin = (entry["positionMin"] as? NSNumber)?.doubleValue ?? 30
            let durationMin = (entry["durationMin"] as? NSNumber)?.doubleValue ?? 120
            let session = WatchProgressPlaybackSession(
                profileId: ActiveProfileProvider.shared.activeProfileId,
                contentType: type,
                parentMetaId: id,
                parentMetaType: type,
                videoId: videoId,
                title: (entry["title"] as? String) ?? id,
                logo: nil,
                poster: entry["poster"] as? String,
                background: entry["background"] as? String,
                seasonNumber: season.map { KotlinInt(int: Int32($0)) },
                episodeNumber: episode.map { KotlinInt(int: Int32($0)) },
                episodeTitle: entry["episodeTitle"] as? String,
                episodeThumbnail: nil,
                providerName: nil,
                providerAddonId: nil,
                lastStreamTitle: nil,
                lastStreamSubtitle: nil,
                pauseDescription: nil,
                lastSourceUrl: nil
            )
            let snapshot = PlayerPlaybackSnapshot(
                isLoading: false,
                isPlaying: false,
                isEnded: false,
                durationMs: Int64(durationMin * 60_000),
                positionMs: Int64(positionMin * 60_000),
                bufferedPositionMs: Int64(positionMin * 60_000),
                playbackSpeed: 1,
                videoWidth: 0,
                videoHeight: 0
            )
            WatchProgressRepository.shared.upsertPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
            written += 1
        }
        NSLog("[ContinueWatchingSeed] applied=true written=%d removed=%d skipped=%d", written, removed, skipped)
    }
}
#endif
