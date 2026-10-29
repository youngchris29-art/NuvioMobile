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

    /// P4 (BUG-143): transient kinds are never remembered; link evidence is, under five minutes.
    func testOnlyLinkEvidenceIsRemembered() {
        func f(_ kind: PlaybackFailureKind, _ played: Double) -> PlaybackFailure {
            var x = failure(played: played); x.kind = kind; return x
        }
        for kind in [PlaybackFailureKind.network, .offline, .cancelled] {
            XCTAssertFalse(PlaybackFailoverPolicy.shouldReject(f(kind, 0)), kind.rawValue)
        }
        for kind in [PlaybackFailureKind.http, .decode, .unknown] {
            XCTAssertTrue(PlaybackFailoverPolicy.shouldReject(f(kind, 120)), kind.rawValue)
        }
        for kind in [PlaybackFailureKind.http, .decode, .placeholder, .endedEarly, .noMedia, .unknown,
                     .network, .offline, .cancelled, .local] {
            XCTAssertFalse(PlaybackFailoverPolicy.shouldReject(f(kind, 300)), kind.rawValue)
        }
    }

    // MARK: Permanent HTTP errors (NuvioTV 830e8e83c)

    /// NuvioTV 830e8e83c (no retry on a permanent HTTP error): the fork never had mpv / lavf
    /// auto-retry. mpv's END_FILE error goes straight to `onPlaybackFailed` once, with the classified
    /// verdict (`MPVPlayerView.reportEndFileError` → `reportPlaybackFailure`, guarded by
    /// `failoverReported`; not a pure seam, read rather than tested). What is pure, and pinned here
    /// for every permanent status: the log line classifies as `.http` with its status, the failure is
    /// remembered, and the next source the walk picks is never the failed link again: a retry of the
    /// same link is impossible from either the failed key or the rejected memory.
    func testPermanentHttpErrorIsRememberedAndNeverRetried() {
        let list = [PlaybackFailoverPolicy.Entry(key: "a1", addonId: "A"),
                    PlaybackFailoverPolicy.Entry(key: "a2", addonId: "A"),
                    PlaybackFailoverPolicy.Entry(key: "b1", addonId: "B")]
        for status in [400, 401, 403, 404, 410] {
            let verdict = PlaybackFailureClassifier.fromMpvLog(["ffmpeg: HTTP error \(status)"],
                                                               endFileError: "loading failed", watchdogFired: false)
            XCTAssertEqual(verdict, PlaybackFailureClassifier.Verdict(.http, http: status), "\(status)")
            var failed = failure(played: 0)
            failed.kind = verdict.kind
            failed.httpStatus = verdict.httpStatus
            XCTAssertTrue(PlaybackFailoverPolicy.shouldReject(failed), "\(status)")
            let rejected: Set<String> = PlaybackFailoverPolicy.shouldReject(failed) ? ["a2"] : []
            // a2 failed with a permanent status: the walk moves past it, never back to it.
            XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(entries: list, failedKey: "a2", failedAddonId: "A",
                                                                  rejected: rejected), 2, "\(status)")
            // Even listed again as the next candidate (a reloaded list puts it first), it is skipped.
            XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(entries: [list[1], list[0], list[2]], failedKey: "gone",
                                                                  failedAddonId: "A", rejected: rejected), 1, "\(status)")
            XCTAssertNil(PlaybackFailoverPolicy.nextManualIndex(entries: [list[1]], failedKey: "gone", failedAddonId: "A",
                                                                rejected: rejected), "\(status): nothing left but the failed link")
        }
    }

    /// The FFmpeg AVERROR form (remux / probe open) of the same statuses, 4XX catch-all included.
    func testPermanentHttpAVErrorsClassifyAsHttp() {
        typealias C = PlaybackFailureClassifier
        for (code, status) in [(C.httpBadRequest, 400), (C.httpUnauthorized, 401), (C.httpForbidden, 403),
                               (C.httpNotFound, 404), (C.httpOther4xx, 400)] {
            XCTAssertEqual(C.fromAVError(code, atOpen: true), C.Verdict(.http, http: status), "\(status)")
        }
    }

    /// 5xx, timeouts and network errors keep their current path: a 5xx is link evidence like a
    /// 4xx, network trouble is never remembered (the failover walk still moves on).
    func testServerAndNetworkErrorsKeepTheirCurrentPath() {
        let serverError = PlaybackFailureClassifier.fromMpvLog(["ffmpeg: Server returned 5XX Server Error reply"],
                                                               endFileError: nil, watchdogFired: false)
        XCTAssertEqual(serverError, PlaybackFailureClassifier.Verdict(.http, http: 500))
        let timeout = PlaybackFailureClassifier.fromMpvLog(["tcp: Connection timed out"],
                                                           endFileError: nil, watchdogFired: false)
        XCTAssertEqual(timeout.kind, .network)
        var failed = failure(played: 0)
        failed.kind = timeout.kind
        XCTAssertFalse(PlaybackFailoverPolicy.shouldReject(failed))
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
            externalUrl: nil, ytId: nil, sources: [], sourceName: nil, addonName: "Add-on", addonId: "addon:x",
            addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
        XCTAssertEqual(stream.playbackStreamKey, "feedface#2")
    }

    // MARK: Batch D U2 — ytId-only streams

    private func ytStream(url: String? = nil, ytId: String? = "dQw4w9WgXcQ") -> StreamItem {
        StreamItem(
            name: "Trailer 1080p", title: nil, description: nil, url: url, infoHash: nil, fileIdx: nil,
            externalUrl: nil, ytId: ytId, sources: [], sourceName: nil, addonName: "Add-on", addonId: "addon:x",
            addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
    }

    func testYouTubeKeyIsTheAddonTagAndTheVideoId() {
        // Pinned like the URL digest: persisted for eight hours, so it must not drift between builds.
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "addon:x", url: nil,
                                              label: "Trailer 1080p", youTubeId: " dQw4w9WgXcQ "),
                       "e3600bd8|yt:dQw4w9WgXcQ")
        // The video id outranks the label (two add-on rows naming the same video are one link) but
        // never a link: a stream with a URL and a ytId plays the URL, so the URL is its identity.
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "addon:x",
                                              url: "https://cdn.example.com/d/abc/file.mkv", label: "x", youTubeId: "dQw4w9WgXcQ"),
                       urlKey("https://cdn.example.com/d/abc/file.mkv"))
        XCTAssertEqual(PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "addon:x", url: nil, label: "x", youTubeId: "  "),
                       PlaybackStreamKey.make(infoHash: nil, fileIdx: nil, addonId: "addon:x", url: nil, label: "x"),
                       "a blank video id falls through to the label")
    }

    func testStreamItemKeyUsesItsYouTubeIdWhenItHasNoLink() {
        XCTAssertEqual(ytStream().playbackStreamKey, "e3600bd8|yt:dQw4w9WgXcQ")
        XCTAssertEqual(ytStream(url: "https://cdn.example.com/d/abc/file.mkv").playbackStreamKey,
                       urlKey("https://cdn.example.com/d/abc/file.mkv"))
    }

    func testYouTubeStreamIsRememberedByItsVideoIdNotTheResolvedLink() {
        // The picker keys the failover memory on the stream AS LISTED (`listedStream` /
        // `PlaybackContext.streamKey`), never on the googlevideo link the on-device resolve produced:
        // that link expires within hours, so a key built from it would never match again.
        let listed = ytStream()
        let resolvedLink = "https://rr3---sn-example.googlevideo.com/videoplayback?expire=1700000000&id=o-abc"
        let key = listed.playbackStreamKey
        XCTAssertEqual(key, "e3600bd8|yt:dQw4w9WgXcQ")
        XCTAssertNotEqual(key, urlKey(resolvedLink))
        XCTAssertFalse(key.contains(PlaybackStreamKey.digestHex("rr3---sn-example.googlevideo.com/videoplayback", bytes: 16)))
        XCTAssertFalse(key.contains("googlevideo"))
    }

    private func directStream(url: String, addonId: String = "addon:x") -> StreamItem {
        StreamItem(
            name: "Direct", title: nil, description: nil, url: url, infoHash: nil, fileIdx: nil,
            externalUrl: nil, ytId: nil, sources: [], sourceName: nil, addonName: "Add-on", addonId: addonId,
            addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
    }

    func testTryNextSourceSkipsYouTubeStreamsButStillFindsTheFailedOne() {
        // Review r1: "Try Next Source" never lands on a ytId-only stream (a resolve takes seconds
        // and may fail), yet the list is not filtered — the failed stream's own index must still be
        // found when ytId streams sit before it, or the search would restart from the top.
        let yt = ytStream()
        let failed = directStream(url: "https://cdn.example.com/a.mkv")
        let ytAfter = ytStream(ytId: "zzzzzzzzzzz")
        let next = directStream(url: "https://cdn.example.com/b.mkv")
        let list = [yt, failed, ytAfter, next]
        XCTAssertEqual(PlaybackFailoverPolicy.nextManualIndex(streams: list, failedKey: failed.playbackStreamKey,
                                                              failedAddonId: "addon:x", rejected: []), 3)
        // A ytId stream is skipped even when it is the same add-on's next entry, and nothing else
        // left means nil rather than the YouTube row.
        XCTAssertNil(PlaybackFailoverPolicy.nextManualIndex(streams: [failed, ytAfter], failedKey: failed.playbackStreamKey,
                                                            failedAddonId: "addon:x", rejected: []))
        // Already-rejected keys still apply on top.
        XCTAssertNil(PlaybackFailoverPolicy.nextManualIndex(streams: list, failedKey: failed.playbackStreamKey,
                                                            failedAddonId: "addon:x", rejected: [next.playbackStreamKey]))
    }

    func testStreamItemKeyIgnoresAYouTubeIdAttachedToAnOrdinaryLink() {
        // Review r1: `playbackStreamKey` keys on `youTubeIdToResolve` (the id the stream would be
        // PLAYED through), so a ytId riding along an ordinary link never becomes its identity.
        let withLink = ytStream(url: "https://cdn.example.com/d/abc/file.mkv")
        XCTAssertNil({ let id: String? = withLink.youTubeIdToResolve; return id }())
        XCTAssertEqual(withLink.playbackStreamKey, urlKey("https://cdn.example.com/d/abc/file.mkv"))
        XCTAssertNotNil({ let id: String? = ytStream().youTubeIdToResolve; return id }())
    }

    func testSessionOnlyContextPersistsNoSourceUrl() {
        var ctx = makeContext()
        XCTAssertEqual(ctx.persistedSourceUrl, ctx.url.absoluteString, "a normal link is stored as the entry's last source")
        ctx.sessionOnlySourceUrl = true
        XCTAssertNil(ctx.persistedSourceUrl, "a link resolved from a ytId is session-only")
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
