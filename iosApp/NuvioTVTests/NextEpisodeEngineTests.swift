import XCTest
@testable import NuvioTV
import SharedCore

/// Unit tests for the up-next trigger in `Screens/NextEpisodeAutoPlay.swift`: the threshold math
/// (`NextEpisodeTriggerPolicy`, unchanged from the inline version), the FEAT-49 Tier 1 preload
/// (upstream 22c9ab20) through the engine's `Hooks.loadStreams` seam, and the #2150 end-of-file
/// re-arm decision. The engine is driven with `configureForTesting`, so no SharedCore singleton
/// (settings, streams, shuffle) is touched; `settings` stays nil, so `beginSearch()` returns right
/// after the `Hooks.searchBegan` signal.
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

    private func makeContext() -> PlaybackContext {
        PlaybackContext(
            url: URL(string: "https://cdn.example.com/s1e1.mkv")!, title: "S1E1", contentType: "series",
            parentMetaId: "tt1", videoId: "tt1:1:1",
            season: 1, episode: 1, poster: nil, background: nil, providerName: nil, providerAddonId: nil,
            streamTitle: nil, streamSubtitle: nil, externalSubtitles: []
        )
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

    /// Upstream bb94cb1c1: offline, `beginSearch()` records the attempt and returns before the
    /// flow is touched: no clear, no load, no watcher, and the phase never leaves `.hidden`.
    func testOfflineSearchRecordsTheAttemptButNeverTouchesTheFlow() {
        let recorder = Recorder()
        let engine = makeEngine(trigger: trigger(percent: 99), recorder: recorder, network: { false })

        engine.onProgress(positionSec: 2376, durationSec: Self.duration)

        XCTAssertEqual(recorder.searchBegan, 1)
        XCTAssertTrue(recorder.calls.isEmpty, "the search loaded streams while offline")
        XCTAssertEqual(recorder.clears, 0)
        XCTAssertEqual(recorder.watches, 0)
        XCTAssertEqual(engine.phase, .hidden)
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
}
