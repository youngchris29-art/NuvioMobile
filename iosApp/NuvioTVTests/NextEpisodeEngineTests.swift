import Combine
import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for the up-next trigger in `Screens/NextEpisodeAutoPlay.swift`: the threshold math
/// (`NextEpisodeTriggerPolicy`, unchanged from the inline version), the FEAT-49 Tier 1 preload
/// (upstream 22c9ab20) through the engine's `Hooks.loadStreams` seam, and the #2150 end-of-file
/// re-arm decision. The engine is driven with `configureForTesting`, so no SharedCore singleton
/// (settings, streams, shuffle) is touched; `settings` stays nil, so `beginSearch()` returns right
/// after the `Hooks.searchBegan` signal (the offline gate sits before that call, in the engine's
/// two automatic start paths).
@MainActor
final class NextEpisodeEngineTests: XCTestCase {

    private static let duration: Double = 2400
    private static let slack: Double = 1.5

    // MARK: - Fixtures

    private struct LoadCall: Equatable {
        let type: String
        let videoId: String
        let season: Int?
        let episode: Int?
    }

    private final class Recorder {
        var calls: [LoadCall] = []
        var searchBegan = 0
        var clears = 0
        var watches = 0
        /// Every callback handed to `Hooks.watchStreams`, in order (the seam returns no watcher).
        var callbacks: [(StreamsUiState) -> Void] = []
        /// r2 P3: every flow operation in call order (`clear`, `watch`, `load:<videoId>`), so a
        /// test can see a clear that lands after the list's load (it cancels that load on device).
        var log: [String] = []
    }

    private func makeContext(episodes: [MetaVideo] = []) -> PlaybackContext {
        var context = PlaybackContext(
            url: URL(string: "https://cdn.example.com/s1e1.mkv")!, title: "S1E1", contentType: "series",
            parentMetaId: "tt1", videoId: "tt1:1:1",
            season: 1, episode: 1, poster: nil, background: nil, providerName: nil, providerAddonId: nil,
            streamTitle: nil, streamSubtitle: nil, externalSubtitles: []
        )
        context.episodes = episodes
        return context
    }

    private func episode(season: Int32, episode: Int32) -> MetaVideo {
        MetaVideo(
            id: "tt1:\(season):\(episode)", title: "Episode \(episode)", released: nil, available: true,
            thumbnail: nil, seasonPoster: nil,
            season: KotlinInt(int: season), episode: KotlinInt(int: episode),
            overview: nil, runtime: nil, rating: nil, streams: []
        )
    }

    private func trigger(percentageMode: Bool = true, percent: Double = 99, minutes: Double = 2,
                         timeout: Int = 3, preload: Bool = false) -> NextEpisodeEngine.TriggerSettings {
        NextEpisodeEngine.TriggerSettings(
            percentageMode: percentageMode,
            thresholdPercent: percent,
            thresholdMinutesBeforeEnd: minutes,
            autoPlayTimeoutSeconds: timeout,
            preloadEnabled: preload
        )
    }

    private func stream(url: String? = nil, ytId: String? = nil, infoHash: String? = nil) -> StreamItem {
        StreamItem(
            name: "1080p", title: nil, description: nil, url: url, infoHash: infoHash, fileIdx: nil,
            externalUrl: nil, ytId: ytId, sources: [], sourceName: nil, addonName: "Add-on", addonId: "addon:x",
            addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
    }

    // MARK: - Source predicates (batch D U2)

    func testYouTubeOnlyStreamIsListableButNeverAnAutoPlayCandidate() {
        // The debrid half is injected as "never" so no debrid settings are read.
        let never: (StreamItem) -> Bool = { _ in false }
        let yt = stream(ytId: "dQw4w9WgXcQ")
        XCTAssertFalse(NextEpisodeEngine.isAutoPlayCandidate(yt, resolvesThroughDebrid: never),
                       "auto-play never spends seconds resolving a YouTube video")
        XCTAssertTrue(NextEpisodeEngine.isListable(yt, resolvesThroughDebrid: never),
                      "the viewer may still pick it from the in-player source list")

        let direct = stream(url: "https://cdn.example.com/s1e2.mkv")
        XCTAssertTrue(NextEpisodeEngine.isAutoPlayCandidate(direct, resolvesThroughDebrid: never))
        XCTAssertTrue(NextEpisodeEngine.isListable(direct, resolvesThroughDebrid: never))

        let torrent = stream(infoHash: "feedface")
        XCTAssertFalse(NextEpisodeEngine.isAutoPlayCandidate(torrent, resolvesThroughDebrid: never))
        XCTAssertFalse(NextEpisodeEngine.isListable(torrent, resolvesThroughDebrid: never),
                       "a torrent with no debrid connection is neither")
        XCTAssertTrue(NextEpisodeEngine.isAutoPlayCandidate(torrent, resolvesThroughDebrid: { _ in true }))
        XCTAssertTrue(NextEpisodeEngine.isListable(torrent, resolvesThroughDebrid: { _ in true }))
    }

    // MARK: - BUG-228: binge-group-only needs a binge group

    /// The defaults (MANUAL, prefer binge group on, next-episode toggle off) restrict the pick to
    /// the playing stream's binge group only when it has one; a plugin stream with none falls back
    /// to the first stream instead of "no stream found".
    func testBingeGroupOnlyWithTheDefaultsNeedsAPlayingBingeGroup() {
        func restricted(_ group: String?) -> Bool {
            NextEpisodeEngine.bingeGroupOnlyManualMode(
                manualAutoSelect: true, nextEpisodeEnabled: false, fallbackEnabled: true,
                preferBingeGroup: true, playingBingeGroup: group)
        }
        XCTAssertTrue(restricted("debrid|1080p"), "a stream with a binge group stays in it")
        XCTAssertFalse(restricted(nil), "a stream with no binge group could never match")
        XCTAssertFalse(restricted(""), "an empty binge group is no binge group")
        XCTAssertFalse(restricted("  \n"), "a whitespace-only binge group is no binge group (trimmed like the selector)")
    }

    /// The other inputs keep their upstream f2c9b9f9 meaning when a binge group is present.
    func testBingeGroupOnlyTruthTableWithABingeGroup() {
        func restricted(manual: Bool = true, next: Bool, fallback: Bool, prefer: Bool = true) -> Bool {
            NextEpisodeEngine.bingeGroupOnlyManualMode(
                manualAutoSelect: manual, nextEpisodeEnabled: next, fallbackEnabled: fallback,
                preferBingeGroup: prefer, playingBingeGroup: "g")
        }
        XCTAssertFalse(restricted(next: true, fallback: true), "next-episode + fallback picks any source")
        XCTAssertTrue(restricted(next: true, fallback: false), "fallback off keeps the binge group")
        XCTAssertTrue(restricted(next: false, fallback: false))
        XCTAssertFalse(restricted(next: false, fallback: true, prefer: false), "no preference, no restriction")
        XCTAssertFalse(restricted(manual: false, next: false, fallback: true), "outside MANUAL auto-select")
    }

    private func makeEngine(trigger: NextEpisodeEngine.TriggerSettings, recorder: Recorder,
                            network: @escaping () -> Bool = { true }) -> NextEpisodeEngine {
        let hooks = NextEpisodeEngine.Hooks(loadStreams: { type, videoId, season, episode in
            recorder.calls.append(LoadCall(type: type, videoId: videoId, season: season?.value, episode: episode?.value))
            recorder.log.append("load:\(videoId)")
        }, searchBegan: { recorder.searchBegan += 1 },
        networkSatisfied: network,
        clearStreams: { recorder.clears += 1; recorder.log.append("clear") },
        watchStreams: { callback in
            recorder.watches += 1
            recorder.log.append("watch")
            recorder.callbacks.append(callback)
            return nil
        })
        let engine = NextEpisodeEngine(context: makeContext(), onPlayNext: { _ in }, hooks: hooks)
        engine.configureForTesting(nextVideo: episode(season: 1, episode: 2), trigger: trigger)
        return engine
    }

    private func reaches(_ position: Double, _ trigger: NextEpisodeEngine.TriggerSettings,
                         hold: Double? = nil, duration: Double = NextEpisodeEngineTests.duration) -> Bool {
        NextEpisodeTriggerPolicy.reachesThreshold(
            positionSec: position, durationSec: duration, trigger: trigger,
            holdUntilSec: hold, endOfFileSlack: Self.slack
        )
    }

    // MARK: - Policy: percentage

    func testNinetyNinePercentOf2400FiresAt2376Not2375() {
        let t = trigger(percent: 99)
        XCTAssertFalse(reaches(2375, t))
        XCTAssertTrue(reaches(2376, t))
    }

    func testPercentBelow97ClampsTo97() {
        let t = trigger(percent: 50)
        XCTAssertFalse(reaches(1200, t))
        XCTAssertFalse(reaches(2327, t))   // 96.96 %
        XCTAssertTrue(reaches(2328, t))    // 97 %
    }

    func testHundredPercentFiresOnlyAtTheEnd() {
        let t = trigger(percent: 100)
        XCTAssertFalse(reaches(2399, t))
        XCTAssertTrue(reaches(2400, t))
    }

    // MARK: - Policy: minutes before end

    func testTwoMinutesFiresAtDurationMinus120() {
        let t = trigger(percentageMode: false, minutes: 2)
        XCTAssertFalse(reaches(2279, t))
        XCTAssertTrue(reaches(2280, t))
    }

    func testTenMinutesClampsToThreeAndAHalf() {
        let t = trigger(percentageMode: false, minutes: 10)
        XCTAssertFalse(reaches(2189, t))
        XCTAssertTrue(reaches(2190, t))    // D − 210
    }

    func testZeroMinutesFiresAtTheEnd() {
        let t = trigger(percentageMode: false, minutes: 0)
        XCTAssertFalse(reaches(2399.9, t))
        XCTAssertTrue(reaches(2400, t))
    }

    // MARK: - Policy: post-credits hold

    func testHoldReplacesTheThreshold() {
        let t = trigger(percent: 99)       // would fire at 2376 without a hold
        XCTAssertFalse(reaches(2380, t, hold: 2390))
        XCTAssertTrue(reaches(2390, t, hold: 2390))
    }

    func testEndOfFileSlackFiresEvenWithAHoldBeyondTheEnd() {
        let t = trigger(percent: 99)
        XCTAssertFalse(reaches(2398.4, t, hold: 2500))
        XCTAssertTrue(reaches(2398.5, t, hold: 2500))   // D − 1.5
    }

    // MARK: - Policy: preload lead

    func testPreloadLeadIsTheTimeoutFlooredAtThirtySeconds() {
        XCTAssertEqual(NextEpisodeTriggerPolicy.preloadLeadSeconds(timeoutSeconds: 3), 30)
        XCTAssertEqual(NextEpisodeTriggerPolicy.preloadLeadSeconds(timeoutSeconds: 30), 30)
        XCTAssertEqual(NextEpisodeTriggerPolicy.preloadLeadSeconds(timeoutSeconds: 45), 45)
    }

    // MARK: - Engine: preload ticks

    func testPreloadOnIssuesOneSilentLoadThirtySecondsAhead() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99, preload: true), recorder: recorder)

        engine.onProgress(positionSec: 2340, durationSec: Self.duration)
        XCTAssertTrue(recorder.calls.isEmpty)

        engine.onProgress(positionSec: 2346, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls, [LoadCall(type: "series", videoId: "tt1:1:2", season: 1, episode: 2)])
        XCTAssertEqual(engine.phase, .hidden)

        engine.onProgress(positionSec: 2350, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(engine.phase, .hidden)
    }

    func testCancelInsideTheLeadWindowIsANoOpAndDoesNotReissue() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99, preload: true), recorder: recorder)

        engine.onProgress(positionSec: 2346, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls.count, 1)

        engine.cancel()                     // a backward seek before the card: nothing to cancel
        XCTAssertEqual(engine.phase, .hidden)

        engine.onProgress(positionSec: 2360, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(engine.phase, .hidden)
    }

    func testPreloadOffIssuesNothingBeforeTheThreshold() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99, preload: false), recorder: recorder)

        for position in [2340.0, 2346, 2350, 2360, 2375] {
            engine.onProgress(positionSec: position, durationSec: Self.duration)
        }
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(engine.phase, .hidden)
    }

    /// Upstream bb94cb1c1: offline, the preload skips without marking itself triggered, so the
    /// first tick after connectivity returns issues it.
    func testOfflinePreloadSkipsThenRetriesOnceTheNetworkReturns() {
        let recorder = Recorder()
        var online = false
        let engine = makeEngine(trigger: trigger(percent: 99, preload: true), recorder: recorder,
                                network: { online })

        engine.onProgress(positionSec: 2346, durationSec: Self.duration)   // inside the lead window
        engine.onProgress(positionSec: 2350, durationSec: Self.duration)
        XCTAssertTrue(recorder.calls.isEmpty, "preload hit the network while offline")
        XCTAssertEqual(engine.phase, .hidden)

        online = true
        engine.onProgress(positionSec: 2352, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls, [LoadCall(type: "series", videoId: "tt1:1:2", season: 1, episode: 2)])

        engine.onProgress(positionSec: 2356, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls.count, 1, "preload re-issued after it succeeded")
    }

    func testMinutesModePreloadFiresAtThresholdMinusLead() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percentageMode: false, minutes: 2, preload: true), recorder: recorder)

        engine.onProgress(positionSec: 2249, durationSec: Self.duration)
        XCTAssertTrue(recorder.calls.isEmpty)

        engine.onProgress(positionSec: 2250, durationSec: Self.duration)   // D − 150
        XCTAssertEqual(recorder.calls, [LoadCall(type: "series", videoId: "tt1:1:2", season: 1, episode: 2)])
        XCTAssertEqual(engine.phase, .hidden)
    }

    // MARK: - Engine: search trigger and #2150 rider
    //
    // `settings` is nil in tests, so `beginSearch()` returns right after `searchBegan`; phase stays
    // `.hidden`, which is why the dismissal is simulated (`simulateDismissForTesting`) instead of
    // calling `dismissIfVisible()`. Not exercised here: the `preloaded` reset after teardown, the
    // resolve-race guard (both need a live search / debrid resolve, i.e. SharedCore singletons), and
    // the `dismissIfVisible` phase switch (fix #3: `.noStream`/`.stillWatching` never arm the re-arm;
    // `.searching`/`.counting` arm it only when not at end of file), which
    // `simulateDismissForTesting()` bypasses.

    func testNoSearchBeforeTheThresholdThenOneAtIt() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder)

        for position in [2000.0, 2350, 2375] {
            engine.onProgress(positionSec: position, durationSec: Self.duration)
        }
        XCTAssertEqual(recorder.searchBegan, 0)

        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1)
        engine.onProgress(positionSec: 2377, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1)
    }

    /// Upstream bb94cb1c1: offline at the threshold, the auto-play search is skipped before
    /// `beginSearch()` runs (no `searchBegan`, no clear, no load, no watcher), but the card still
    /// shows (upstream keeps `showNextEpisodeCard = true`) in its own phase, `.offlineDeferred`
    /// (no spinner: nothing is searching), and the threshold stays spent.
    func testOfflineThresholdSkipsTheSearchButStillShowsTheCard() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { false })

        engine.onProgress(positionSec: 2376, durationSec: Self.duration)

        XCTAssertEqual(recorder.searchBegan, 0, "the offline threshold entered beginSearch()")
        XCTAssertTrue(recorder.calls.isEmpty, "the search loaded streams while offline")
        XCTAssertEqual(recorder.clears, 0)
        XCTAssertEqual(recorder.watches, 0)
        XCTAssertEqual(engine.phase, .offlineDeferred, "the offline card must stay up, without a spinner")
        XCTAssertTrue(engine.searchDeferredOffline)

        engine.onProgress(positionSec: 2377, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 0, "the threshold re-fired")
        XCTAssertEqual(engine.phase, .offlineDeferred)
    }

    /// Offline card, then the path returns: one press starts the next episode's search through
    /// `playNow()`, and it plays as soon as a stream resolves (`immediatePlay`).
    func testPressAfterReconnectStartsTheSearchFromTheOfflineCard() {
        let recorder = Recorder()
        var online = false
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { online })

        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertEqual(engine.phase, .offlineDeferred)
        XCTAssertEqual(recorder.searchBegan, 0)

        online = true
        XCTAssertTrue(engine.playNow(), "the press was not consumed by the offline card")
        // `settings` is nil in tests, so `beginSearch()` returns right after this signal and the
        // `loadStreams` call behind it is unreachable here; `searchBegan` is the observable.
        XCTAssertEqual(recorder.searchBegan, 1)
        XCTAssertEqual(engine.phase, .searching, "the pressed search shows the searching card")
        XCTAssertFalse(engine.searchDeferredOffline)
        XCTAssertFalse(engine.playNow(), "a second press must not start a second search")
        XCTAssertEqual(recorder.searchBegan, 1)
    }

    /// Menu on the offline card dismisses it and drops the deferral, so a later press cannot
    /// start a search for a card nobody sees.
    func testDismissingTheOfflineCardDropsTheDeferral() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { false })
        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertTrue(engine.dismissIfVisible())
        XCTAssertEqual(engine.phase, .hidden)
        XCTAssertFalse(engine.searchDeferredOffline)
        XCTAssertFalse(engine.playNow())
        XCTAssertEqual(recorder.searchBegan, 0)
    }

    /// Offline, the #2150 end-of-file re-arm is gated like the threshold, and since it only ever
    /// fires at end of file it shows no card at all: no search, no spinner, the post-play screen
    /// (gated on `.hidden`) takes over.
    func testOfflineRearmAtEndOfFileShowsNoCard() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { false })
        engine.onProgress(positionSec: 2380, durationSec: Self.duration)
        engine.simulateDismissForTesting()
        engine.onProgress(positionSec: 2398.5, durationSec: Self.duration)

        XCTAssertEqual(recorder.searchBegan, 0)
        XCTAssertEqual(engine.phase, .hidden, "an offline re-arm at end of file put a card back up")
        XCTAssertFalse(engine.searchDeferredOffline)
    }

    /// Offline card still up at end of file (the cover path): the tick inside the end-of-file
    /// slack drops it to `.hidden`, the post-play cover's gate on both engines, and nothing
    /// resurrects it afterwards, not even the path coming back or a press.
    func testOfflineCardDropsToHiddenAtEndOfFileForThePostPlayCover() {
        let recorder = Recorder()
        var online = false
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { online })
        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertEqual(engine.phase, .offlineDeferred)

        engine.onProgress(positionSec: 2398.6, durationSec: Self.duration)
        XCTAssertEqual(engine.phase, .hidden, "the offline card blocked the post-play cover")
        XCTAssertFalse(engine.searchDeferredOffline)

        online = true
        engine.onProgress(positionSec: 2399.5, durationSec: Self.duration)
        XCTAssertFalse(engine.playNow())
        XCTAssertEqual(recorder.searchBegan, 0, "a dropped offline card came back as a search")
        XCTAssertEqual(engine.phase, .hidden)
    }

    /// The players' end signal (mpv `isEnded`, native `didPlayToEnd`) drops the offline card
    /// even when no tick landed inside the slack; with the path back, it starts the search instead.
    func testPlaybackEndedResolvesTheOfflineCard() {
        let recorder = Recorder()
        let offline = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { false })
        offline.onProgress(positionSec: 2376, durationSec: Self.duration)
        offline.onProgress(positionSec: 2390, durationSec: Self.duration)
        XCTAssertEqual(offline.phase, .offlineDeferred)
        offline.playbackEnded()
        XCTAssertEqual(offline.phase, .hidden)
        XCTAssertEqual(recorder.searchBegan, 0)

        var online = false
        let back = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { online })
        back.onProgress(positionSec: 2376, durationSec: Self.duration)
        online = true
        back.playbackEnded()
        XCTAssertEqual(recorder.searchBegan, 1, "the end signal with the path back did not search")
        XCTAssertEqual(back.phase, .searching)

        // Not the offline card: the end signal is a no-op.
        let hidden = makeEngine(trigger: trigger(percent: 99), recorder: recorder)
        hidden.playbackEnded()
        XCTAssertEqual(hidden.phase, .hidden)
        XCTAssertEqual(recorder.searchBegan, 1)
    }

    /// The ticks are the reactive signal: the first one that sees the path back starts the
    /// deferred search by itself, once.
    func testReconnectTickStartsTheDeferredSearch() {
        let recorder = Recorder()
        var online = false
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { online })
        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        engine.onProgress(positionSec: 2377, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 0)

        online = true
        engine.onProgress(positionSec: 2378, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1, "the reconnect tick did not start the search")
        XCTAssertEqual(engine.phase, .searching)
        XCTAssertFalse(engine.searchDeferredOffline)

        engine.onProgress(positionSec: 2379, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1, "a second tick started a second search")
    }

    /// A press while the path is still down runs the search (the monitor may lag a reconnect);
    /// when it ends with no stream, still offline, the offline card comes back instead of the
    /// no-stream toast, so a later press, or the reconnect tick, can retry.
    func testPressWhileOfflineKeepsTheDeferral() {
        let recorder = Recorder()
        var online = false
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { online })
        engine.onProgress(positionSec: 2376, durationSec: Self.duration)

        XCTAssertTrue(engine.playNow())
        XCTAssertEqual(recorder.searchBegan, 1)
        XCTAssertEqual(engine.phase, .searching)
        engine.finishWithoutStreamForTesting()
        XCTAssertEqual(engine.phase, .offlineDeferred, "an offline press spent the threshold")
        XCTAssertTrue(engine.searchDeferredOffline)

        XCTAssertTrue(engine.playNow(), "a second offline press was not consumed")
        XCTAssertEqual(recorder.searchBegan, 2)
        engine.finishWithoutStreamForTesting()
        XCTAssertEqual(engine.phase, .offlineDeferred)

        online = true
        engine.onProgress(positionSec: 2380, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 3, "the reconnect tick did not retry after the offline press")
        engine.finishWithoutStreamForTesting()
        XCTAssertEqual(engine.phase, .noStream, "online, a search with no stream ends in the toast")
        XCTAssertFalse(engine.searchDeferredOffline)
        engine.cancel()
    }

    /// Menu on the offline card clears it; the #2150 re-arm at end of file then shows no card
    /// while still offline (no spinner, so no second Menu), and searches once the path is back.
    func testMenuDismissClearsTheOfflineCardAndTheRearmBringsNoSpinner() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { false })
        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertTrue(engine.dismissIfVisible())
        XCTAssertEqual(engine.phase, .hidden)
        XCTAssertFalse(engine.searchDeferredOffline)
        engine.onProgress(positionSec: 2390, durationSec: Self.duration)
        engine.onProgress(positionSec: 2398.5, durationSec: Self.duration)   // re-arm, offline
        XCTAssertEqual(engine.phase, .hidden, "the re-arm brought the card back offline")
        XCTAssertEqual(recorder.searchBegan, 0)
        XCTAssertFalse(engine.dismissIfVisible(), "a second Menu was needed")

        var online = false
        let back = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { online })
        back.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertTrue(back.dismissIfVisible())
        online = true
        back.onProgress(positionSec: 2398.5, durationSec: Self.duration)     // re-arm, online
        XCTAssertEqual(recorder.searchBegan, 1, "#2150: a dismissed offline card did not re-arm online")
    }

    /// Both engines offer Play Next on the offline card (native contextual action, mpv Down
    /// chip), with a caption of its own: no spinner, not the searching copy.
    func testOfflineCardActionAndCaption() {
        XCTAssertEqual(UpNextAction(phase: .offlineDeferred), .playNext)
        XCTAssertEqual(UpNextAction(phase: .counting(2)), .playNext)
        XCTAssertEqual(UpNextAction(phase: .stillWatching), .continueWatching)
        XCTAssertNil(UpNextAction(phase: .searching))
        XCTAssertNil(UpNextAction(phase: .hidden))
        XCTAssertNil(UpNextAction(phase: .noStream))

        let offline = NextEpisodeEngine.Phase.offlineDeferred.chipCaption(nextTitle: "S1E2")
        let searching = NextEpisodeEngine.Phase.searching.chipCaption(nextTitle: "S1E2")
        XCTAssertNotNil(offline)
        XCTAssertEqual(offline?.progress, false, "the offline card shows a spinner")
        XCTAssertEqual(offline?.symbol, "wifi.slash")
        XCTAssertNotEqual(offline?.text, searching?.text)
        XCTAssertEqual(searching?.progress, true)
    }

    /// A manual episode jump is a user action and is never gated on the path (upstream gates only
    /// the automatic launch and the preload): offline, it still reaches `beginSearch()`, keeps its
    /// busy-line flags, and is not mistaken for the offline card.
    func testOfflineManualJumpStillBeginsTheSearch() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder, network: { false })
        engine.sourceColumnAppeared()
        engine.loadSources()

        engine.jumpForTesting(to: episode(season: 1, episode: 5))

        XCTAssertEqual(recorder.searchBegan, 1, "the offline gate swallowed the manual jump")
        XCTAssertFalse(engine.searchDeferredOffline)
        XCTAssertTrue(engine.sourcesBlockedBySearch)
        XCTAssertTrue(engine.sourcesBlockedByJump)

        engine.finishWithoutStreamForTesting()
        XCTAssertFalse(engine.sourcesBlockedBySearch, "the jump's block was left stuck")
        engine.cancel()
    }

    func testDismissedCardRearmsOnceAtEndOfFileThenSticks() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder)

        engine.onProgress(positionSec: 2380, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1)

        engine.simulateDismissForTesting()
        engine.onProgress(positionSec: 2390, durationSec: Self.duration)     // dismissed, not at EOF
        XCTAssertEqual(recorder.searchBegan, 1)

        engine.onProgress(positionSec: 2398.5, durationSec: Self.duration)   // D - 1.5: re-arm
        XCTAssertEqual(recorder.searchBegan, 2)
        engine.onProgress(positionSec: 2399, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 2)

        engine.simulateDismissForTesting()                                   // second dismissal sticks
        engine.onProgress(positionSec: 2399.5, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 2)
    }

    // MARK: - #2150 rider policy

    func testRearmTruthTable() {
        func rearm(_ position: Double, dismissed: Bool, rearmed: Bool, duration: Double = Self.duration) -> Bool {
            NextEpisodeTriggerPolicy.shouldRearmAfterDismiss(
                positionSec: position, durationSec: duration,
                dismissedByUser: dismissed, alreadyRearmed: rearmed, endOfFileSlack: Self.slack
            )
        }
        // Dismissed by the user, first time, at the end → re-arm.
        XCTAssertTrue(rearm(2400, dismissed: true, rearmed: false))
        XCTAssertTrue(rearm(2398.5, dismissed: true, rearmed: false))
        // Not yet at the end.
        XCTAssertFalse(rearm(2398.4, dismissed: true, rearmed: false))
        XCTAssertFalse(rearm(2000, dismissed: true, rearmed: false))
        // A seek/exit cancel (not a dismissal) never re-arms.
        XCTAssertFalse(rearm(2400, dismissed: false, rearmed: false))
        // Once per session.
        XCTAssertFalse(rearm(2400, dismissed: true, rearmed: true))
        // No duration yet.
        XCTAssertFalse(rearm(0, dismissed: true, rearmed: false, duration: 0))
    }

    // MARK: - BUG-129: the Sources tab vs the up-next search

    private func nonEmptyState() -> StreamsUiState {
        let group = AddonStreamGroup(addonName: "Addon", addonId: "addon", streams: [], isLoading: false, error: nil)
        return StreamsUiState(
            requestToken: "t", groups: [group], activeAddonIds: [], installedAddonIds: ["addon"],
            selectedFilter: nil, isAnyLoading: false, emptyStateReason: nil, autoPlayStream: nil,
            autoPlayCandidates: [], isDirectAutoPlayFlow: false, showDirectAutoPlayOverlay: false,
            overlayMessage: nil
        )
    }

    /// (1) Busy guard: the list never clears or subscribes while a search owns the flow.
    func testSourcesDeferredWhileSearching() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.forceSearchingForTesting()
        let watchesBefore = recorder.watches

        engine.loadSources()

        XCTAssertTrue(engine.sourcesBlockedBySearch)
        XCTAssertFalse(engine.sourcesBlockedByJump)
        XCTAssertFalse(engine.sourcesLoading)
        XCTAssertEqual(recorder.clears, 0, "the list cleared the search's results")
        XCTAssertEqual(recorder.watches, watchesBefore, "the list subscribed during the search")
        XCTAssertTrue(recorder.calls.isEmpty, "the list issued a load during the search")
    }

    /// (2) Generation guard: an emission from a torn-down search is dropped.
    func testLateEmissionAfterTearDownIsDropped() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.forceSearchingForTesting()
        let staleCallback = recorder.callbacks.last!

        engine.cancel()                         // tearDownSearch
        XCTAssertEqual(engine.phase, .hidden)
        XCTAssertFalse(engine.sourcesBlockedBySearch)

        staleCallback(nonEmptyState())
        XCTAssertEqual(engine.searchEmissionsAccepted, 0, "a torn-down search consumed an emission")
        XCTAssertEqual(engine.phase, .hidden)

        // Control: the live search's own emission is accepted.
        engine.forceSearchingForTesting()
        recorder.callbacks.last!(nonEmptyState())
        XCTAssertEqual(engine.searchEmissionsAccepted, 1)
    }

    /// (2b) A source list opened after a search ended drops that search's late emissions too.
    /// The search ends through a seam that does NOT bump the generation, so only `loadSources`'
    /// own bump can drop the stale callback (r1 P3: `cancel()` bumped it first and hid the line).
    func testSearchEmissionAfterSourceListIsDropped() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.forceSearchingForTesting()
        let staleCallback = recorder.callbacks.last!
        engine.endForcedSearchWithoutGenerationBumpForTesting()
        engine.loadSources()
        staleCallback(nonEmptyState())
        XCTAssertEqual(engine.searchEmissionsAccepted, 0, "loadSources did not move the search generation on")
    }

    /// Control for (2b): the seam itself leaves the generation alone, so without `loadSources`
    /// the same stale callback is accepted.
    func testGenerationSeamDoesNotBump() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.forceSearchingForTesting()
        let staleCallback = recorder.callbacks.last!
        engine.endForcedSearchWithoutGenerationBumpForTesting()
        staleCallback(nonEmptyState())
        XCTAssertEqual(engine.searchEmissionsAccepted, 1)
    }

    /// (2c) r1 P3, reverse race: a search that starts while the Sources list is open shows the
    /// busy line instead of an emptied list.
    func testSearchStartingUnderOpenListShowsBusyLine() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.sourceColumnAppeared()
        engine.loadSources()
        XCTAssertFalse(engine.sourcesBlockedBySearch)

        engine.forceSearchingForTesting()
        XCTAssertTrue(engine.sourcesBlockedBySearch, "the open list was blanked with no busy line")
        XCTAssertFalse(engine.sourcesLoading)
    }

    /// (2d) r1 P3: when the search ends with the column still up, the list reloads by itself, so
    /// the column never falls through to "No alternate sources found yet.".
    func testSearchEndReloadsVisibleSourceList() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        let current = LoadCall(type: "series", videoId: "tt1:1:1", season: 1, episode: 1)
        engine.sourceColumnAppeared()
        engine.forceSearchingForTesting()
        engine.loadSources()                    // deferred: busy line
        XCTAssertTrue(engine.sourcesBlockedBySearch)
        XCTAssertFalse(recorder.calls.contains(current))

        let mark = recorder.log.count
        engine.cancel()                         // the search ends
        XCTAssertFalse(engine.sourcesBlockedBySearch)
        XCTAssertTrue(engine.sourcesLoading, "busy line fell through to the empty-list copy")
        XCTAssertEqual(recorder.calls.filter { $0 == current }.count, 1)
        assertListReloadIsLast(recorder, since: mark)
    }

    /// r2 P3: after an exit, the list's own `clear → watch → load` is the LAST thing on the flow.
    /// A clear after the load (the old `tearDownSearch` order) cancels the load on device.
    private func assertListReloadIsLast(_ recorder: Recorder, since mark: Int,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let tail = Array(recorder.log[mark...])
        XCTAssertEqual(Array(tail.suffix(3)), ["clear", "watch", "load:tt1:1:1"],
                       "the list did not reload last: \(tail)", file: file, line: line)
    }

    private func directStream() -> StreamItem {
        StreamItem(
            name: "S", title: nil, description: nil, url: "https://cdn.example.com/s1e2.mkv",
            infoHash: nil, fileIdx: nil, externalUrl: nil, ytId: nil, sources: [], sourceName: nil,
            addonName: "Addon", addonId: "addon", addonLogo: nil, streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
    }

    /// (2d-select) r2 P3: the common exit. The search picks a stream while the phase is still
    /// `.searching`; the deferred list must load then, not be deferred a second time.
    func testSelectExitReloadsVisibleSourceList() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.sourceColumnAppeared()
        engine.forceSearchingForTesting()
        engine.loadSources()
        XCTAssertTrue(engine.sourcesBlockedBySearch)
        XCTAssertEqual(engine.phase, .searching)

        let mark = recorder.log.count
        engine.selectForTesting(directStream())
        XCTAssertFalse(engine.sourcesBlockedBySearch, "busy line stayed up after the pick")
        XCTAssertTrue(engine.sourcesLoading, "the list was deferred again on the select exit")
        assertListReloadIsLast(recorder, since: mark)
        engine.cancel()
    }

    /// (2d-noStream) r2 P3: the search ends with no stream; the deferred list loads.
    func testNoStreamExitReloadsVisibleSourceList() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.sourceColumnAppeared()
        engine.forceSearchingForTesting()
        engine.loadSources()

        let mark = recorder.log.count
        engine.finishWithoutStreamForTesting()
        XCTAssertEqual(engine.phase, .noStream)
        XCTAssertFalse(engine.sourcesBlockedBySearch)
        XCTAssertTrue(engine.sourcesLoading, "the list was deferred again on the no-stream exit")
        assertListReloadIsLast(recorder, since: mark)
        engine.cancel()
    }

    /// (2d-jump) r2 P3: an episode jump while the Sources column is up shows the jump's busy line,
    /// and a jump that finds nothing reloads the list.
    func testEpisodeJumpShowsBusyLineThenReloads() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.sourceColumnAppeared()
        engine.loadSources()
        XCTAssertTrue(engine.sourcesLoading)

        engine.jumpForTesting(to: episode(season: 1, episode: 5))
        XCTAssertTrue(engine.sourcesBlockedBySearch, "the jump blanked the list with no busy line")
        XCTAssertTrue(engine.sourcesBlockedByJump)
        XCTAssertFalse(engine.sourcesLoading)

        let mark = recorder.log.count
        engine.finishWithoutStreamForTesting()
        XCTAssertFalse(engine.sourcesBlockedBySearch)
        XCTAssertTrue(engine.sourcesLoading, "a jump with no stream left the column empty")
        assertListReloadIsLast(recorder, since: mark)
        engine.cancel()
    }

    /// (2d-wiped) r2 P3: a cancel after the search already ended (list reloaded and live) wipes
    /// the flow; the list is reloaded after the wipe instead of being left empty.
    func testCancelAfterReloadKeepsListAlive() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.sourceColumnAppeared()
        engine.forceSearchingForTesting()
        engine.loadSources()
        engine.selectForTesting(directStream())   // list reloads; the countdown is pending
        XCTAssertTrue(engine.sourcesLoading)

        let mark = recorder.log.count
        engine.cancel()
        XCTAssertTrue(engine.sourcesLoading, "the cancel's clear left the list empty")
        assertListReloadIsLast(recorder, since: mark)
    }

    /// (2e) Column gone: a search end does not load a list nobody sees.
    func testSearchEndWithColumnClosedDoesNotReload() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)
        engine.sourceColumnAppeared()
        engine.forceSearchingForTesting()
        engine.loadSources()
        engine.sourceColumnDisappeared()
        engine.cancel()
        XCTAssertFalse(engine.sourcesBlockedBySearch)
        XCTAssertFalse(engine.sourcesLoading)
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    /// (3) Without a search the list clears once, subscribes and loads the current video.
    func testSourcesLoadWithoutSearch() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(), recorder: recorder)

        engine.loadSources()

        XCTAssertFalse(engine.sourcesBlockedBySearch)
        XCTAssertTrue(engine.sourcesLoading)
        XCTAssertEqual(recorder.clears, 1)
        XCTAssertEqual(recorder.watches, 1)
        XCTAssertEqual(recorder.calls, [LoadCall(type: "series", videoId: "tt1:1:1", season: 1, episode: 1)])
    }

    /// (4) Closing the native panel's source list re-arms the FEAT-49 preload it clobbered; the
    /// re-issue happens on the next tick past the lead.
    func testNativePanelCloseReissuesPreloadOnNextTick() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99, preload: true), recorder: recorder)
        let next = LoadCall(type: "series", videoId: "tt1:1:2", season: 1, episode: 2)

        engine.onProgress(positionSec: 2346, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls.filter { $0 == next }.count, 1)

        engine.loadSources()                    // the list clears the preload's results
        engine.onProgress(positionSec: 2348, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls.filter { $0 == next }.count, 1, "preload re-issued while the list owns the flow")

        engine.noteSourceListClosed()
        XCTAssertEqual(recorder.calls.filter { $0 == next }.count, 1, "closing only invalidates")

        engine.onProgress(positionSec: 2350, durationSec: Self.duration)
        XCTAssertEqual(recorder.calls.filter { $0 == next }.count, 2, "the next tick must re-issue the preload")
        XCTAssertEqual(engine.phase, .hidden)
    }

    // MARK: - BUG-229: a launch that carried no episode list

    /// Stands in for `Hooks.fetchEpisodes`: records each request and holds it until the test
    /// delivers (a delivery made before the request is handed over as soon as it arrives).
    private final class EpisodeFetchGate {
        var requests: [String] = []
        private var continuation: CheckedContinuation<[MetaVideo], Error>?
        private var pending: Result<[MetaVideo], Error>?

        func fetch(_ type: String, _ id: String) async throws -> [MetaVideo] {
            requests.append("\(type)/\(id)")
            if let pending {
                self.pending = nil
                return try pending.get()
            }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func deliver(_ result: Result<[MetaVideo], Error>) {
            if let continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else {
                pending = result
            }
        }
    }

    private final class NetworkBox { var satisfied = true }

    /// An engine started through `prime()`'s episode half (`primeEpisodesForTesting`) for the
    /// context's own list, with the plain aired-order pick in place of the shuffle singleton
    /// (`resolvedLists` records the list each pick saw) and `gate` in place of the meta fetch.
    private func makePrimedEngine(episodes: [MetaVideo], recorder: Recorder, gate: EpisodeFetchGate,
                                  network: NetworkBox = NetworkBox(),
                                  resolvedLists: ((Int) -> Void)? = nil) -> NextEpisodeEngine {
        var hooks = NextEpisodeEngine.Hooks(loadStreams: { type, videoId, season, episode in
            recorder.calls.append(LoadCall(type: type, videoId: videoId, season: season?.value, episode: episode?.value))
        }, searchBegan: { recorder.searchBegan += 1 },
        networkSatisfied: { network.satisfied },
        clearStreams: { recorder.clears += 1 },
        watchStreams: { _ in nil })
        hooks.resolveNextEpisode = { context, list in
            resolvedLists?(list.count)
            return NextEpisodeEngine.resolveNextAiredEpisode(
                episodes: list, currentSeason: context.season, currentEpisode: context.episode)
        }
        hooks.fetchEpisodes = { type, id in try await gate.fetch(type, id) }
        let engine = NextEpisodeEngine(context: makeContext(episodes: episodes), onPlayNext: { _ in }, hooks: hooks)
        engine.configureForTesting(nextVideo: nil, trigger: trigger(percent: 99))
        engine.primeEpisodesForTesting()
        return engine
    }

    private var seasonOne: [MetaVideo] {
        [episode(season: 1, episode: 1), episode(season: 1, episode: 2), episode(season: 1, episode: 3)]
    }

    /// Control: a launch that carried the list arms the card at the threshold and fetches nothing.
    func testLaunchWithEpisodesArmsAtTheThresholdAndFetchesNothing() {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let engine = makePrimedEngine(episodes: seasonOne, recorder: recorder, gate: gate)
        XCTAssertNil(engine.lateEpisodesTaskForTesting)
        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1)
        XCTAssertTrue(gate.requests.isEmpty)
    }

    /// BUG-229 repro, now fixed: a play started before the stream picker's own episode fetch
    /// finished hands the player an EMPTY list. Before the fix `nextVideo` was resolved once at
    /// start and the card never armed. The engine now fetches the list itself, off the start path,
    /// and resolves the next episode when it lands; a threshold already passed arms on the next tick.
    func testEmptyLaunchListArmsOnceTheFetchedListLands() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        var resolved: [Int] = []
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate,
                                      resolvedLists: { resolved.append($0) })
        XCTAssertNotNil(engine.lateEpisodesTaskForTesting, "the fetch starts with the engine")
        XCTAssertTrue(engine.episodes.isEmpty)

        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 0, "no next episode until the list lands")

        let fetch1 = engine.lateEpisodesTaskForTesting
        gate.deliver(.success(seasonOne))
        await fetch1?.value
        XCTAssertEqual(gate.requests, ["series/tt1"])
        XCTAssertEqual(resolved, [3], "the pick (shuffle-aware live) runs once, over the fetched list, never over []")
        XCTAssertEqual(engine.nextVideoForTesting?.id, "tt1:1:2")
        XCTAssertEqual(engine.nextEpisodeTitle, NextEpisodeEngine.episodeTitle(episode(season: 1, episode: 2)))

        engine.onProgress(positionSec: 2377, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1, "the late list arms the card on the next tick")
        XCTAssertEqual(gate.requests.count, 1)
    }

    /// The player is dismissed (`stop()`) before the fetch returns: the list is dropped, the engine
    /// adopts nothing and never arms.
    func testDismissBeforeTheFetchLandsDropsTheList() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate)
        let task = engine.lateEpisodesTaskForTesting
        XCTAssertNotNil(task)

        engine.stop()
        XCTAssertNil(engine.lateEpisodesTaskForTesting)
        gate.deliver(.success(seasonOne))
        await task?.value

        XCTAssertTrue(engine.episodes.isEmpty, "a cancelled fetch is never adopted")
        XCTAssertNil(engine.nextVideoForTesting)
        engine.onProgress(positionSec: 2390, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 0)
    }

    /// The fetched list has no episode after the playing one (the last aired episode): the Episodes
    /// panel still gets the list, the card never arms.
    func testFetchedListWithNoNextEpisodeNeverArms() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate)
        let fetch2 = engine.lateEpisodesTaskForTesting
        gate.deliver(.success([episode(season: 1, episode: 1)]))
        await fetch2?.value

        XCTAssertEqual(engine.episodes.count, 1)
        XCTAssertNil(engine.nextVideoForTesting)
        for position in [2376.0, 2390, 2399] {
            engine.onProgress(positionSec: position, durationSec: Self.duration)
        }
        XCTAssertEqual(recorder.searchBegan, 0)
        XCTAssertEqual(engine.phase, .hidden)
    }

    /// The fetched list feeds the Episodes column (published, so both players redraw their Episodes
    /// entry) and the next episode's `PlaybackContext`, so that launch starts with a list.
    func testFetchedListFeedsTheEpisodesPanelAndTheNextContext() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate)
        XCTAssertTrue(PlayerEpisodesColumn.sortedEpisodes(engine).isEmpty)
        var changes = 0
        let watch = engine.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }

        let fetch3 = engine.lateEpisodesTaskForTesting
        gate.deliver(.success(Array(seasonOne.reversed())))
        await fetch3?.value

        XCTAssertGreaterThan(changes, 0, "the panel and the players' Episodes entry observe the engine")
        XCTAssertEqual(PlayerEpisodesColumn.sortedEpisodes(engine).map(\.id), ["tt1:1:1", "tt1:1:2", "tt1:1:3"])
        let next = engine.nextContextForTesting(stream: stream(url: "https://cdn.example.com/s1e2.mkv"),
                                                url: URL(string: "https://cdn.example.com/s1e2.mkv")!)
        XCTAssertEqual(next?.videoId, "tt1:1:2")
        XCTAssertEqual(next?.episodes.count, 3, "the next episode's context carries the fetched list")
    }

    /// Offline at start: no fetch (it could only fail). The first tick that sees the path back
    /// starts it, once.
    func testOfflineStartDefersTheFetchUntilThePathIsBack() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let network = NetworkBox()
        network.satisfied = false
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate, network: network)
        XCTAssertNil(engine.lateEpisodesTaskForTesting)

        engine.onProgress(positionSec: 100, durationSec: Self.duration)
        XCTAssertNil(engine.lateEpisodesTaskForTesting, "still offline: still waiting")

        network.satisfied = true
        engine.onProgress(positionSec: 101, durationSec: Self.duration)
        XCTAssertNotNil(engine.lateEpisodesTaskForTesting)
        engine.onProgress(positionSec: 102, durationSec: Self.duration)
        let fetch4 = engine.lateEpisodesTaskForTesting
        gate.deliver(.success(seasonOne))
        await fetch4?.value
        XCTAssertEqual(gate.requests, ["series/tt1"], "one fetch for the reconnect")

        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1)
    }

    /// A fetch that fails while online is not retried (no request per tick); one that fails while
    /// the path is down is retried once it is back.
    func testFailedFetchRetriesOnlyAfterAnOutage() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let network = NetworkBox()
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate, network: network)
        let fetch5 = engine.lateEpisodesTaskForTesting
        gate.deliver(.failure(URLError(.badServerResponse)))
        await fetch5?.value
        engine.onProgress(positionSec: 100, durationSec: Self.duration)
        engine.onProgress(positionSec: 101, durationSec: Self.duration)
        XCTAssertEqual(gate.requests.count, 1, "an online failure is final")

        let offline = makePrimedEngine(episodes: [], recorder: recorder, gate: gate, network: network)
        network.satisfied = false
        let fetch6 = offline.lateEpisodesTaskForTesting
        gate.deliver(.failure(URLError(.notConnectedToInternet)))
        await fetch6?.value
        XCTAssertEqual(gate.requests.count, 2)
        network.satisfied = true
        offline.onProgress(positionSec: 100, durationSec: Self.duration)
        let retry = offline.lateEpisodesTaskForTesting
        XCTAssertNotNil(retry, "a failure during an outage retries on the path's return")
        gate.deliver(.success([]))
        await retry?.value
        XCTAssertEqual(gate.requests.count, 3)
    }

    /// r1 P2: the live fetch swallows network errors and returns no meta, so a path lost mid-fetch
    /// comes back as an EMPTY success. Offline then, it is retried like a failure on the path's
    /// return; online, an empty list is final.
    func testEmptyFetchDuringAnOutageRetriesOnReconnect() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let network = NetworkBox()
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate, network: network)
        network.satisfied = false
        let fetch1 = engine.lateEpisodesTaskForTesting
        gate.deliver(.success([]))
        await fetch1?.value
        engine.onProgress(positionSec: 100, durationSec: Self.duration)
        XCTAssertNil(engine.lateEpisodesTaskForTesting, "still offline: waiting")

        network.satisfied = true
        engine.onProgress(positionSec: 101, durationSec: Self.duration)
        let retry = engine.lateEpisodesTaskForTesting
        XCTAssertNotNil(retry, "the reconnect tick refetches")
        gate.deliver(.success(seasonOne))
        await retry?.value
        XCTAssertEqual(gate.requests.count, 2)
        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1)

        let online = makePrimedEngine(episodes: [], recorder: recorder, gate: gate, network: network)
        let fetch2 = online.lateEpisodesTaskForTesting
        gate.deliver(.success([]))
        await fetch2?.value
        online.onProgress(positionSec: 100, durationSec: Self.duration)
        online.onProgress(positionSec: 101, durationSec: Self.duration)
        XCTAssertNil(online.lateEpisodesTaskForTesting)
        XCTAssertEqual(gate.requests.count, 3, "an empty list online is final")
    }

    /// r1 P3: a list that lands inside the end-of-file slack resolves no next episode there (an
    /// automatic search would start over the post-play screen). A tick back out of the slack (a
    /// Replay) resolves it, and the card arms at that playthrough's threshold.
    func testListLandingAtEndOfFileDefersTheNextEpisode() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate)
        engine.onProgress(positionSec: 2399, durationSec: Self.duration)
        let fetch1 = engine.lateEpisodesTaskForTesting
        gate.deliver(.success(seasonOne))
        await fetch1?.value

        XCTAssertEqual(engine.episodes.count, 3, "the Episodes panel still gets the list")
        XCTAssertNil(engine.nextVideoForTesting)
        engine.onProgress(positionSec: 2399.5, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 0, "no automatic search over the post-play screen")
        XCTAssertEqual(engine.phase, .hidden)

        engine.onProgress(positionSec: 10, durationSec: Self.duration)
        XCTAssertEqual(engine.nextVideoForTesting?.id, "tt1:1:2", "a Replay resolves the deferred pick")
        XCTAssertEqual(recorder.searchBegan, 0)
        engine.onProgress(positionSec: 2376, durationSec: Self.duration)
        XCTAssertEqual(recorder.searchBegan, 1)
    }

    /// An episode jump made before the list lands keeps its episode: the late list never replaces it.
    func testJumpBeforeTheFetchLandsKeepsTheJumpedEpisode() async {
        let recorder = Recorder()
        let gate = EpisodeFetchGate()
        let engine = makePrimedEngine(episodes: [], recorder: recorder, gate: gate)
        engine.jumpForTesting(to: episode(season: 1, episode: 3))
        let fetch7 = engine.lateEpisodesTaskForTesting
        gate.deliver(.success(seasonOne))
        await fetch7?.value
        XCTAssertEqual(engine.episodes.count, 3)
        XCTAssertEqual(engine.nextVideoForTesting?.id, "tt1:1:3")
    }
}
