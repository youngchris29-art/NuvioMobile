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

    func testUrlKeyIsAddonHostAndPathWithoutTheQuery() {
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "addon:x",
                                              url: "https://CDN.example.com/d/abc/file.mkv?token=secret#t=1", label: "x"),
                       "addon:x|cdn.example.com/d/abc/file.mkv")
    }

    func testKeyFallsBackToTheLabelAndIsEmptyWithNothing() {
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "addon:x", url: nil, label: " 1080p "),
                       "addon:x|1080p")
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: "  ", fileIdx: nil, addonId: "addon:x", url: "", label: ""), "")
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
