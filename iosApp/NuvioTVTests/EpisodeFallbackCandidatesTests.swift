import XCTest
@testable import NuvioTV
import SharedCore

/// W4: the candidates of the in-player fallback for an Up Next episode
/// (`Screens/StreamPicker/EpisodeFallbackCandidates.swift`): Up Next's Swift filters, then the
/// shared rule with Up Next's scope.
@MainActor
final class EpisodeFallbackCandidatesTests: XCTestCase {

    private func stream(_ name: String, addon: String = "addon:a", url: String? = nil,
                        hash: String? = nil, fileIdx: Int32? = nil) -> StreamItem {
        StreamItem(
            name: name, title: nil, description: nil,
            url: url ?? (hash == nil ? "https://cdn.example.com/\(addon)/\(name).mkv" : nil),
            infoHash: hash, fileIdx: fileIdx.map { KotlinInt(int: $0) },
            externalUrl: nil, ytId: nil, sources: [], sourceName: nil, addonName: "Add-on \(addon)", addonId: addon,
            addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: [], debridResolved: false
        )
    }

    /// Up Next's default scope: MANUAL with Prefer Same Source (first stream over every source, in
    /// list order).
    private var manualBingeScope: StreamAutoPickScope {
        NextEpisodeEngine.autoPickScope(mode: .manual, source: .allSources, regex: "", selectedAddons: [],
                                        selectedPlugins: [], nextEpisodeEnabled: false,
                                        nextEpisodeFallbackEnabled: true, preferBingeGroup: true,
                                        playingBingeGroup: nil)
    }

    private func ranked(_ streams: [StreamItem], tried: Set<String> = [], failed: StreamItem? = nil,
                        rejected: Set<String> = [], cachedOnly: Bool = false,
                        scope: StreamAutoPickScope? = nil) -> [String] {
        EpisodeFallbackCandidates.ranked(
            streams: streams, tried: PlayerSourceFallbackTried(keys: tried, attempts: 0), failed: failed,
            rejected: rejected, cachedOnly: cachedOnly, scope: scope ?? manualBingeScope,
            debridEnabled: false, activeResolverProviderId: nil, resolvesThroughDebrid: { _ in false }
        ).map { $0.name ?? "" }
    }

    func testListOrderInTheDefaultScope() {
        XCTAssertEqual(ranked([stream("720p"), stream("2160p"), stream("1080p")]), ["720p", "2160p", "1080p"])
    }

    func testTriedSourcesAreLeftOut() {
        let a = stream("a"), b = stream("b"), c = stream("c")
        let tried = PlayerSourceFallbackTried.companion.None.including(stream: a).including(stream: c).keys
        XCTAssertEqual(ranked([a, b, c], tried: tried), ["b"])
    }

    /// Review r1 (finding 4): the in-player walk's candidates after add-on X's copy of a torrent
    /// failed: Y's copy of the same file stays, X's other copy and the tried source go.
    func testTheSameTorrentFromAnotherAddonStaysACandidate() {
        let hash = "89abcdef0123456789abcdef0123456789abcdef"
        // Resolved links that carry their torrent's hash (as a debrid add-on's are).
        let x0 = stream("X0", addon: "addon:x", url: "https://x.example/0.mkv", hash: hash, fileIdx: 0)
        let x1 = stream("X1", addon: "addon:x", url: "https://x.example/1.mkv", hash: hash, fileIdx: 1)
        let y0 = stream("Y0", addon: "addon:y", url: "https://y.example/0.mkv", hash: hash, fileIdx: 0)
        let tried = PlayerSourceFallbackTried.companion.None.including(stream: x0).keys
        XCTAssertEqual(EpisodeFallbackCandidates.ranked(
            streams: [x0, x1, y0], tried: PlayerSourceFallbackTried(keys: tried, attempts: 0), failed: x0,
            rejected: [], cachedOnly: false, scope: manualBingeScope, debridEnabled: false,
            activeResolverProviderId: nil, resolvesThroughDebrid: { _ in false }
        ).map { $0.name ?? "" }, ["Y0"])
    }

    func testRecentlyFailedLinksAreLeftOut() {
        let a = stream("a"), b = stream("b")
        XCTAssertEqual(ranked([a, b], rejected: [a.playbackStreamKey]), ["b"])
    }

    func testCachedOnlyLeavesOutWhatIsNotCached() {
        XCTAssertEqual(ranked([stream("a"), stream("b")], cachedOnly: true), [],
                       "plain links carry no cache evidence")
    }

    func testStreamsThisDeviceCannotPlayAreLeftOut() {
        // A torrent with no debrid connection (the seam says no) and a ytId-only stream.
        let torrent = stream("t", hash: "0123456789abcdef0123456789abcdef01234567")
        let youTube = StreamItem(
            name: "yt", title: nil, description: nil, url: nil, infoHash: nil, fileIdx: nil, externalUrl: nil,
            ytId: "dQw4w9WgXcQ", sources: [], sourceName: nil, addonName: "Add-on", addonId: "addon:a",
            addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: [], debridResolved: false)
        XCTAssertEqual(ranked([torrent, youTube, stream("ok")]), ["ok"])
    }

    func testAUserFirstStreamScopeRanksByQuality() {
        let scope = NextEpisodeEngine.autoPickScope(mode: .firstStream, source: .allSources, regex: "",
                                                    selectedAddons: [], selectedPlugins: [],
                                                    nextEpisodeEnabled: false, nextEpisodeFallbackEnabled: true,
                                                    preferBingeGroup: false, playingBingeGroup: nil)
        XCTAssertEqual(ranked([stream("720p"), stream("2160p"), stream("1080p")], scope: scope),
                       ["2160p", "1080p", "720p"])
    }

    func testARegexScopeKeepsOnlyMatches() {
        let scope = NextEpisodeEngine.autoPickScope(mode: .regexMatch, source: .allSources, regex: "1080p",
                                                    selectedAddons: [], selectedPlugins: [],
                                                    nextEpisodeEnabled: false, nextEpisodeFallbackEnabled: true,
                                                    preferBingeGroup: false, playingBingeGroup: nil)
        XCTAssertEqual(ranked([stream("720p"), stream("1080p"), stream("2160p")], scope: scope), ["1080p"])
    }

    /// Plain MANUAL mode without the next-episode toggles auto-picks nothing (no fallback either).
    func testPlainManualPicksNothing() {
        let scope = NextEpisodeEngine.autoPickScope(mode: .manual, source: .allSources, regex: "",
                                                    selectedAddons: [], selectedPlugins: [],
                                                    nextEpisodeEnabled: false, nextEpisodeFallbackEnabled: true,
                                                    preferBingeGroup: false, playingBingeGroup: nil)
        XCTAssertEqual(ranked([stream("a")], scope: scope), [])
    }

    func testEmptyWithoutSettings() {
        let ctx = PlaybackContext(
            url: URL(string: "https://a.example/x.mkv")!, title: "x", contentType: "series", parentMetaId: "tt1",
            videoId: "tt1:1:2", season: 1, episode: 2, poster: nil, background: nil, providerName: nil,
            providerAddonId: nil, streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
        XCTAssertTrue(EpisodeFallbackCandidates.ranked(streams: [stream("a")], context: ctx, settings: nil,
                                                       tried: PlayerSourceFallbackTried(keys: [], attempts: 0)).isEmpty)
    }
}
