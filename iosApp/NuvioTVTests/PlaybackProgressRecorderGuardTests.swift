import XCTest
import SharedCore
@testable import NuvioTV

/// Return from background, section 7: the recorder refuses every Aether and native write once the
/// account or profile is no longer the playback's owner, at every dispatch point, including the two
/// that run after an await (the Trakt item's build completion and the tracker's deferred stop).
@MainActor
final class PlaybackProgressRecorderGuardTests: XCTestCase {

    /// Records every dispatch and holds the two completions so a test can change the identity in between.
    @MainActor
    final class Backend: PlaybackRecorderBackend {
        final class Targets: TrackerScrobbleTargets {}

        var notes = 0
        var writes: [(positionMs: Int64, flush: Bool)] = []
        var builds = 0
        var starts = 0
        var stops = 0
        var trackerDispatches: [TrackerScrobbleDispatch] = []
        var hasTrackers = true
        private var buildCompletion: (@MainActor (TraktItemBox?) -> Void)?
        private var trackerCompletion: (@MainActor () -> Void)?

        func noteSessionProgress(profileId: Int32, item: TraktItemBox, percent: Float) { notes += 1 }
        func writeProgress(context: PlaybackContext, snapshot: PlayerPlaybackSnapshot, flush: Bool) {
            writes.append((snapshot.positionMs, flush))
        }
        func buildTraktItem(context: PlaybackContext, completion: @escaping @MainActor (TraktItemBox?) -> Void) {
            builds += 1
            buildCompletion = completion
        }
        func scrobbleStart(profileId: Int32, item: TraktItemBox, percent: Float) { starts += 1 }
        func scrobbleStop(profileId: Int32, item: TraktItemBox, percent: Float) { stops += 1 }
        func openTrackerTargets(context: PlaybackContext) -> TrackerScrobbleTargets? { hasTrackers ? Targets() : nil }
        func dispatchTracker(_ action: TrackerScrobbleDispatch, targets: TrackerScrobbleTargets, profileId: Int32,
                             percent: Double, completion: (@MainActor () -> Void)?) {
            trackerDispatches.append(action)
            if let completion { trackerCompletion = completion }
        }

        func finishBuild() { let c = buildCompletion; buildCompletion = nil; c?(TraktItemBox(nil)) }
        func finishTrackerStart() { let c = trackerCompletion; trackerCompletion = nil; c?() }
    }

    private let owner = PlaybackIdentity(accountKey: "user-1", profileId: 1)
    private var current = PlaybackIdentity(accountKey: "user-1", profileId: 1)
    private var backend: Backend!

    override func setUp() async throws {
        current = owner
        backend = Backend()
    }

    private func context() -> PlaybackContext {
        PlaybackContext(
            url: URL(string: "https://example.com/film.mkv")!, title: "Movie", contentType: "movie", parentMetaId: "tt1",
            videoId: "tt1", season: nil, episode: nil, poster: nil, background: nil, providerName: nil, providerAddonId: nil,
            streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
    }

    private func recorder(owner: PlaybackIdentity?) -> PlaybackProgressRecorder {
        PlaybackProgressRecorder(context: context(), owner: owner, identity: { [unowned self] in self.current },
                                 backend: backend)
    }

    private func changeProfile() { current = PlaybackIdentity(accountKey: "user-1", profileId: 2) }

    // MARK: Progress

    func testProgressWritesPassForTheOwnerAndStopAfterAnIdentityChange() {
        let r = recorder(owner: owner)
        r.record(positionSec: 600, durationSec: 3600, isPaused: false, speed: 1, flush: false, isLive: false)
        XCTAssertEqual(backend.writes.count, 1)
        changeProfile()
        r.record(positionSec: 610, durationSec: 3600, isPaused: false, speed: 1, flush: false, isLive: false)
        r.record(positionSec: 620, durationSec: 3600, isPaused: true, speed: 1, flush: true, isLive: false)
        XCTAssertEqual(backend.writes.count, 1, "neither the periodic write nor the teardown flush lands on the new profile")
        current = PlaybackIdentity(accountKey: "signed-out", profileId: 1)
        r.record(positionSec: 630, durationSec: 3600, isPaused: true, speed: 1, flush: true, isLive: false)
        XCTAssertEqual(backend.writes.count, 1)
    }

    // MARK: Trakt

    func testTraktStartAndStopPassForTheOwner() {
        let r = recorder(owner: owner)
        r.startTrakt(positionSec: 600, durationSec: 3600)
        backend.finishBuild()
        XCTAssertEqual(backend.starts, 1)
        r.record(positionSec: 610, durationSec: 3600, isPaused: false, speed: 1, flush: false, isLive: false)
        XCTAssertEqual(backend.notes, 1)
        r.stopTrakt(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.stops, 1)
    }

    func testTraktStartIsRefusedAtEntryAfterAnIdentityChange() {
        let r = recorder(owner: owner)
        changeProfile()
        r.startTrakt(positionSec: 600, durationSec: 3600)
        XCTAssertEqual(backend.builds, 0)
        backend.finishBuild()
        XCTAssertEqual(backend.starts, 0)
    }

    func testAnIdentityChangeBetweenStartAndTheBuildCompletionSendsNoStartAndClosesTheSession() {
        let r = recorder(owner: owner)
        r.startTrakt(positionSec: 600, durationSec: 3600)
        XCTAssertEqual(backend.builds, 1)
        changeProfile()
        backend.finishBuild()
        XCTAssertEqual(backend.starts, 0, "the start goes out after the await: checked there")
        current = owner
        r.record(positionSec: 610, durationSec: 3600, isPaused: false, speed: 1, flush: false, isLive: false)
        XCTAssertEqual(backend.notes, 0, "no item was kept")
        r.stopTrakt(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.stops, 0)
    }

    func testTraktStopAndTheProgressNoteAreRefusedAfterAnIdentityChange() {
        let r = recorder(owner: owner)
        r.startTrakt(positionSec: 600, durationSec: 3600)
        backend.finishBuild()
        changeProfile()
        r.record(positionSec: 610, durationSec: 3600, isPaused: false, speed: 1, flush: false, isLive: false)
        r.stopTrakt(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.notes, 0)
        XCTAssertEqual(backend.stops, 0)
    }

    // MARK: Other trackers

    func testTrackerStartAndStopPassForTheOwner() {
        let r = recorder(owner: owner)
        r.startTrackers(positionSec: 600, durationSec: 3600)
        backend.finishTrackerStart()
        r.stopTrackers(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.trackerDispatches, [.start, .stop])
    }

    func testTrackerStartIsRefusedAfterAnIdentityChange() {
        let r = recorder(owner: owner)
        changeProfile()
        r.startTrackers(positionSec: 600, durationSec: 3600)
        current = owner
        r.stopTrackers(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.trackerDispatches, [], "the refused start closed the session")
    }

    func testAnIdentityChangeBeforeTheDeferredStopSendsNoStopAndClearsTheSession() {
        let r = recorder(owner: owner)
        r.startTrackers(positionSec: 600, durationSec: 3600)
        // A stop while the start is in flight is deferred to the start's completion.
        r.stopTrackers(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.trackerDispatches, [.start])
        changeProfile()
        backend.finishTrackerStart()
        XCTAssertEqual(backend.trackerDispatches, [.start], "the deferred stop is checked after the await")
        current = owner
        r.stopTrackers(positionSec: 630, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.trackerDispatches, [.start], "the session is closed")
    }

    func testTrackerStopIsRefusedAfterAnIdentityChange() {
        let r = recorder(owner: owner)
        r.startTrackers(positionSec: 600, durationSec: 3600)
        backend.finishTrackerStart()
        changeProfile()
        r.stopTrackers(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.trackerDispatches, [.start])
    }

    // MARK: No owner (today's behaviour; the mpv controller's tracker session)

    func testWithoutAnOwnerEveryCallPasses() {
        let r = recorder(owner: nil)
        changeProfile()
        r.record(positionSec: 600, durationSec: 3600, isPaused: false, speed: 1, flush: true, isLive: false)
        r.startTrakt(positionSec: 600, durationSec: 3600)
        backend.finishBuild()
        r.stopTrakt(positionSec: 620, durationSec: 3600, isLive: false)
        r.startTrackers(positionSec: 600, durationSec: 3600)
        backend.finishTrackerStart()
        r.stopTrackers(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.writes.count, 1)
        XCTAssertEqual(backend.starts, 1)
        XCTAssertEqual(backend.stops, 1)
        XCTAssertEqual(backend.trackerDispatches, [.start, .stop])
    }

    func testTheMpvTrackerSessionKeepsItsOwnerlessInitialiser() {
        let session = TrackerScrobbleSession(context: context(), backend: backend)
        changeProfile()
        session.start(positionSec: 600, durationSec: 3600)
        backend.finishTrackerStart()
        session.stop(positionSec: 620, durationSec: 3600, isLive: false)
        XCTAssertEqual(backend.trackerDispatches, [.start, .stop])
    }
}
