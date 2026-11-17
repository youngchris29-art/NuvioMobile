import XCTest
@testable import NuvioTV
import SharedCore

/// W4: `PlaybackContext.replacingSource` (the in-place fallback of an Up Next episode, upstream
/// `replacementBeforePlaybackStartedKeepsTheResumePosition`): the episode stays, the source changes.
@MainActor
final class PlaybackContextReplacementTests: XCTestCase {

    private func stream(_ name: String, url: String?, addon: String = "addon:b", bingeGroup: String? = nil,
                        filename: String? = nil) -> StreamItem {
        StreamItem(
            name: name, title: nil, description: "desc \(name)", url: url, infoHash: nil, fileIdx: nil,
            externalUrl: nil, ytId: nil, sources: [], sourceName: nil, addonName: "Add-on \(name)", addonId: addon,
            addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: bingeGroup, notWebReady: false, videoHash: nil,
                                               videoSize: KotlinLong(value: 1_234), filename: filename,
                                               proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: [], debridResolved: false
        )
    }

    private func episodeContext() -> PlaybackContext {
        let listed = stream("first", url: "https://a.example/s1e2.mkv", addon: "addon:a", bingeGroup: "grp-a")
        var ctx = PlaybackContext(
            url: URL(string: "https://a.example/s1e2.mkv")!, title: "Episode 2", contentType: "series",
            parentMetaId: "tt1", videoId: "tt1:1:2", season: 1, episode: 2, poster: "poster", background: "bg",
            providerName: "Add-on first", providerAddonId: "addon:a", streamTitle: "first", streamSubtitle: nil,
            externalSubtitles: [], bingeGroup: "grp-a", synopsis: "syn", episodeStill: "still", logo: "logo",
            launchSource: .nextEpisode, streamKey: listed.playbackStreamKey, startFromBeginning: true,
            listedStream: listed)
        ctx.sourceFallback = PlayerSourceFallbackTried(keys: ["k-first"], attempts: 0)
        return ctx
    }

    func testTheEpisodeStaysAndTheSourceChanges() {
        let base = episodeContext()
        let listed = stream("second", url: nil, bingeGroup: "grp-b", filename: "s1e2.mkv")
        let resolved = stream("second", url: "https://b.example/resolved.mkv", bingeGroup: "grp-b", filename: "s1e2.mkv")
        let tried = PlayerSourceFallbackTried(keys: ["k-first", "k-second"], attempts: 1)
        let next = base.replacingSource(stream: resolved, url: URL(string: "https://b.example/resolved.mkv")!,
                                        listed: listed, attempt: base.attempt + 1, sourceFallback: tried, resumeAtSec: nil)

        // The episode, artwork, Start Over and the launch source stay.
        XCTAssertEqual(next.videoId, base.videoId)
        XCTAssertEqual(next.parentMetaId, base.parentMetaId)
        XCTAssertEqual(next.season, 1)
        XCTAssertEqual(next.episode, 2)
        XCTAssertEqual(next.title, base.title)
        XCTAssertEqual(next.poster, base.poster)
        XCTAssertEqual(next.background, base.background)
        XCTAssertEqual(next.synopsis, base.synopsis)
        XCTAssertEqual(next.episodeStill, base.episodeStill)
        XCTAssertEqual(next.logo, base.logo)
        XCTAssertEqual(next.launchSource, .nextEpisode)
        XCTAssertTrue(next.startFromBeginning)
        // The source fields follow the new stream; the key is the listed one's.
        XCTAssertEqual(next.url.absoluteString, "https://b.example/resolved.mkv")
        XCTAssertEqual(next.providerAddonId, "addon:b")
        XCTAssertEqual(next.providerName, "Add-on second")
        XCTAssertEqual(next.bingeGroup, "grp-b")
        XCTAssertEqual(next.streamFilename, "s1e2.mkv")
        XCTAssertEqual(next.fileSizeBytes, 1_234)
        XCTAssertEqual(next.streamKey, listed.playbackStreamKey)
        XCTAssertEqual(next.listedStream, listed)
        XCTAssertEqual(next.attempt, 1)
        XCTAssertEqual(next.sourceFallback, tried)
        XCTAssertNotEqual(next.id, base.id)
    }

    /// Two sources resolving to one URL still rebuild the player (the attempt joins the id).
    func testTheAttemptKeepsIdsApartForTheSameURL() {
        let base = episodeContext()
        let same = stream("again", url: base.url.absoluteString)
        let next = base.replacingSource(stream: same, url: base.url, listed: same, attempt: 1,
                                        sourceFallback: base.sourceFallback, resumeAtSec: nil)
        XCTAssertNotEqual(next.id, base.id)
    }

    /// Before the start the resume rule stays (saved progress / Start Over, or a carried position);
    /// after a start the replacement goes on from where the failed source was (decision Q4a).
    func testTheResumeRule() {
        var base = episodeContext()
        let other = stream("second", url: "https://b.example/x.mkv")
        let url = URL(string: "https://b.example/x.mkv")!
        XCTAssertNil(base.replacingSource(stream: other, url: url, listed: other, attempt: 1,
                                          sourceFallback: nil, resumeAtSec: nil).resumeAtSec)
        base.resumeAtSec = 42
        XCTAssertEqual(base.replacingSource(stream: other, url: url, listed: other, attempt: 1,
                                            sourceFallback: nil, resumeAtSec: nil).resumeAtSec, 42)
        XCTAssertEqual(base.replacingSource(stream: other, url: url, listed: other, attempt: 1,
                                            sourceFallback: nil, resumeAtSec: 734).resumeAtSec, 734)
    }

    /// A source the viewer picked carries no tried set (the default), so it never falls back.
    func testAContextCarriesNoTriedSetByDefault() {
        let manual = PlaybackContext(
            url: URL(string: "https://a.example/m.mkv")!, title: "M", contentType: "movie", parentMetaId: "tt9",
            videoId: "tt9", season: nil, episode: nil, poster: nil, background: nil, providerName: nil,
            providerAddonId: nil, streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
        XCTAssertNil(manual.sourceFallback)
        XCTAssertEqual(manual.launchSource, .manual)
    }
}
