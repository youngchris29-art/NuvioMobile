import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for the pure failover decisions in `Screens/PlaybackModels.swift` (orivio batch
/// item 2): what each launch source does on a failure, the five-minute reject/keep line, the
/// placeholder-clip rule the engines apply, the "Try Next Source" choice, the stream key the
/// pickers remember links under, and the attempt suffix on `PlaybackContext.id`.
final class PlaybackFailoverPolicyTests: XCTestCase {

    private func failure(played: Double) -> PlaybackFailure {
        PlaybackFailure(reason: "mpv: loading failed", positionSec: 0, secondsPlayed: played, startedPlaying: played > 0)
    }

    private func makeContext(url: String = "https://cdn.example.com/movie.mkv", attempt: Int = 0,
                             headers: [String: String] = [:]) -> PlaybackContext {
        PlaybackContext(
            url: URL(string: url)!, title: "Movie", contentType: "movie", parentMetaId: "tt1", videoId: "tt1",
            season: nil, episode: nil, poster: nil, background: nil, providerName: nil, providerAddonId: nil,
            streamTitle: nil, streamSubtitle: nil, externalSubtitles: [],
            requestHeaders: headers, attempt: attempt
        )
    }

    // MARK: Response by launch source

    func testEachLaunchSourceHasItsOwnResponse() {
        XCTAssertEqual(PlaybackFailoverPolicy.response(for: .autoPlay), .autoFailover)
        XCTAssertEqual(PlaybackFailoverPolicy.response(for: .nextEpisode), .nextEpisodePicker)
        XCTAssertEqual(PlaybackFailoverPolicy.response(for: .manual), .manualAlert)
    }

    func testDefaultContextIsAManualFirstAttemptFromTheStart() {
        let context = makeContext()
        XCTAssertEqual(context.launchSource, .manual)
        XCTAssertEqual(context.attempt, 0)
        XCTAssertFalse(context.startFromBeginning)
        XCTAssertEqual(context.streamKey, "")
    }

    // MARK: Reject / keep line

    func testOnlyAFailureUnderFiveMinutesIsRemembered() {
        XCTAssertTrue(PlaybackFailoverPolicy.shouldReject(failure(played: 0)))
        XCTAssertTrue(PlaybackFailoverPolicy.shouldReject(failure(played: 299.9)))
        XCTAssertFalse(PlaybackFailoverPolicy.shouldReject(failure(played: 300)))
        XCTAssertFalse(PlaybackFailoverPolicy.shouldReject(failure(played: 2_400)))
    }

    func testFiveMinutesOfPlayIsHealthy() {
        XCTAssertFalse(PlaybackFailoverPolicy.shouldKeep(secondsPlayed: 299))
        XCTAssertTrue(PlaybackFailoverPolicy.shouldKeep(secondsPlayed: 300))
    }

    // MARK: Placeholder clips

    func testPlaceholderClipFailsOnlyInAutomaticFlows() {
        XCTAssertFalse(PlaybackFailoverPolicy.treatsPlaceholderClipAsFailure(.manual))
        XCTAssertTrue(PlaybackFailoverPolicy.treatsPlaceholderClipAsFailure(.autoPlay))
        XCTAssertTrue(PlaybackFailoverPolicy.treatsPlaceholderClipAsFailure(.nextEpisode))
    }

    // MARK: PlaybackContext.id

    func testIdHasNoAttemptSuffixOnTheFirstAttempt() {
        XCTAssertEqual(makeContext().id, "tt1|https://cdn.example.com/movie.mkv")
    }

    func testIdAppendsTheAttemptAfterAFailover() {
        XCTAssertEqual(makeContext(attempt: 2).id, "tt1|https://cdn.example.com/movie.mkv|a2")
        XCTAssertNotEqual(makeContext(attempt: 1).id, makeContext(attempt: 2).id,
                          "two candidates resolving to one URL must still rebuild the player")
    }

    func testIdKeepsTheHeaderFingerprintBeforeTheAttempt() {
        let id = makeContext(attempt: 1, headers: ["Referer": "https://site.example"]).id
        XCTAssertEqual(id, "tt1|https://cdn.example.com/movie.mkv|Referer\u{1F}https://site.example|a1")
    }

    // MARK: Try Next Source

    private func entries(_ pairs: [(String, String)]) -> [PlaybackFailoverPolicy.Entry] {
        pairs.map { PlaybackFailoverPolicy.Entry(key: $0.0, addonId: $0.1) }
    }

    func testNextManualPrefersTheSameAddonAfterTheFailedOne() {
        let list = entries([("a1", "A"), ("b1", "B"), ("a2", "A"), ("b2", "B")])
        XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(entries: list, failedKey: "a1", failedAddonId: "A", rejected: []), 2)
    }

    func testNextManualFallsBackToListOrderWhenTheAddonHasNothingLeft() {
        let list = entries([("a1", "A"), ("b1", "B"), ("c1", "C")])
        XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(entries: list, failedKey: "a1", failedAddonId: "A", rejected: []), 1)
    }

    func testNextManualOnlyLooksAfterTheFailedStream() {
        let list = entries([("a1", "A"), ("a2", "A"), ("b1", "B")])
        XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(entries: list, failedKey: "a2", failedAddonId: "A", rejected: []), 2,
                       "a1 sits before the failed stream and is not offered")
        XCTAssertNil(PlaybackFailoverPolicy.nextManualIndex(entries: list, failedKey: "b1", failedAddonId: "B", rejected: []))
    }

    func testNextManualSkipsRejectedAndEmptyKeys() {
        let list = entries([("a1", "A"), ("a2", "A"), ("", "A"), ("b1", "B")])
        XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(entries: list, failedKey: "a1", failedAddonId: "A", rejected: ["a2"]), 3)
    }

    func testNextManualConsidersTheWholeListWhenTheFailedStreamIsGone() {
        let list = entries([("b1", "B"), ("a2", "A")])
        XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(entries: list, failedKey: "a1", failedAddonId: "A", rejected: []), 1)
        XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(entries: list, failedKey: "a1", failedAddonId: nil, rejected: []), 0)
    }

    // MARK: Stream key

    func testTorrentKeyIsHashAndFileIndex() {
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: " ABCDEF ", fileIdx: 3, addonId: "addon:x",
                                              url: "https://ignored.example/x", label: "x"), "abcdef#3")
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: "abcdef", fileIdx: nil, addonId: "addon:x",
                                              url: nil, label: "x"), "abcdef#")
    }

    private func urlKey(_ url: String, addonId: String = "addon:x") -> String {
        PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: addonId, url: url, label: "x")
    }

    func testUrlKeyIsStableDigestOfAddonAndHostPath() {
        // Pinned: keys are persisted for eight hours, so the digest must not drift between builds.
        // e3600bd8 = SHA-256("addon:x")[0..<4], 05c9…990d = SHA-256("cdn.example.com/d/abc/file.mkv")[0..<16].
        XCTAssertEqual(urlKey("https://CDN.example.com/d/abc/file.mkv?token=secret#t=1"),
                       "e3600bd8|05c9e8e2ae7e7620befe2fea6c61990d")
        XCTAssertEqual(urlKey("https://cdn.example.com/d/abc/file.mkv"),
                       urlKey("https://cdn.example.com/d/abc/file.mkv"), "same host+path, same key")
    }

    func testUrlKeyIgnoresQueryFragmentAndHostCase() {
        let base = urlKey("https://cdn.example.com/d/abc/file.mkv")
        XCTAssertEqual(urlKey("https://cdn.example.com/d/abc/file.mkv?token=one"), base)
        XCTAssertEqual(urlKey("https://cdn.example.com/d/abc/file.mkv?token=two&exp=9#t=30"), base,
                       "a refreshed session token is still the same link")
        XCTAssertEqual(urlKey("https://CDN.Example.com/d/abc/file.mkv"), base)
    }

    func testUrlKeyChangesWithThePathHostOrAddon() {
        let base = urlKey("https://cdn.example.com/d/abc/file.mkv")
        XCTAssertNotEqual(urlKey("https://cdn.example.com/d/abc/other.mkv"), base)
        XCTAssertNotEqual(urlKey("https://mirror.example.com/d/abc/file.mkv"), base)
        XCTAssertNotEqual(urlKey("https://cdn.example.com/d/abc/file.mkv", addonId: "addon:y"), base,
                          "the same link from another add-on is its own entry")
    }

    func testUrlKeyNeverCarriesTheLinkOrAddonInTheClear() {
        // Torrentio-style: the debrid API key sits in the resolve path and in the configured
        // manifest URL that the add-on id embeds.
        let secret = "SECRETKEY123"
        let key = urlKey("https://torrentio.strem.fun/resolve/realdebrid/\(secret)/abcdef/null/0/file.mkv",
                         addonId: "addon:com.stremio.torrentio.addon:https://torrentio.strem.fun/realdebrid=\(secret)/manifest.json")
        XCTAssertFalse(key.contains(secret))
        XCTAssertFalse(key.contains("torrentio"))
        XCTAssertFalse(key.contains("realdebrid"))
        XCTAssertNotNil(key.range(of: "^[0-9a-f]{8}\\|[0-9a-f]{32}$", options: .regularExpression),
                        "an 8-hex add-on tag and a 32-hex link digest, nothing else: \(key)")
    }

    func testHostlessUrlKeyDropsTheQueryAndIsDigested() {
        let key = urlKey("plain-path/file.mkv?token=secret")
        XCTAssertEqual(key, urlKey("plain-path/file.mkv"))
        XCTAssertFalse(key.contains("plain-path"))
        XCTAssertFalse(key.contains("secret"))
    }

    func testKeyFallsBackToTheLabelDigestAndIsEmptyWithNothing() {
        let labelKey = PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "addon:x", url: nil, label: " 1080p ")
        XCTAssertEqual(labelKey, "e3600bd8|00a6c687935e22c7cabb42eeaafd06a9", "SHA-256(\"label\\u{1F}1080p\")[0..<16]")
        XCTAssertEqual(labelKey, PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "addon:x", url: nil, label: "1080p"))
        XCTAssertNotEqual(labelKey, urlKey("1080p"), "a label and a link with the same text are different keys")
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: "  ", fileIdx: nil, addonId: "addon:x", url: "", label: ""), "")
    }

    func testDigestHexIsTheLeadingBytesOfSha256() {
        // SHA-256("abc") = ba7816bf 8f01cfea 414140de 5dae2223 …
        XCTAssertEqual(PlaybackStreamKey.digestHex("abc", bytes: 4), "ba7816bf")
        XCTAssertEqual(PlaybackStreamKey.digestHex("abc", bytes: 16), "ba7816bf8f01cfea414140de5dae2223")
    }

    func testStreamItemKeyUsesItsInfoHash() {
        let stream = StreamItem(
            name: "Torrent", title: nil, description: nil, url: nil, infoHash: "FEEDFACE", fileIdx: KotlinInt(int: 2),
            externalUrl: nil, sources: [], sourceName: nil, addonName: "Add-on", addonId: "addon:x",
            addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
        XCTAssertEqual(stream.playbackStreamKey, "feedface#2")
    }

    // MARK: Runtime (external-player return duration)

    func testRuntimeMinutesParsesCatalogFormats() {
        XCTAssertEqual(PlaybackMeta.runtimeMinutes("1h 30m"), 90)
        XCTAssertEqual(PlaybackMeta.runtimeMinutes("45 min"), 45)
        XCTAssertEqual(PlaybackMeta.runtimeMinutes("2:05"), 125)
        XCTAssertEqual(PlaybackMeta.runtimeMinutes("118"), 118)
        XCTAssertNil(PlaybackMeta.runtimeMinutes("TBA"))
        XCTAssertNil(PlaybackMeta.runtimeMinutes(nil))
    }
}
