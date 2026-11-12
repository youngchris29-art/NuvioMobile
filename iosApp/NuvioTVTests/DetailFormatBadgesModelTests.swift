import XCTest
import SharedCore
@testable import NuvioTV

/// `DetailFormatBadgesModel`: the dwell gate, the settings gate, the picker fold (grow only) and
/// probe cancellation, against a fake source so nothing touches the network.
@MainActor
final class DetailFormatBadgesModelTests: XCTestCase {

    private final class FakeSource: DetailFormatBadgeSource {
        var started: [String] = []
        var watched: [String] = []
        var cancelled: [String] = []
        var cached: [TitleFormatBadge] = []
        var generation: Int32 = 0
        private var continuations: [String: AsyncStream<DetailFormatBadgeSnapshot>.Continuation] = [:]

        func watch(_ request: TitleFormatRequest) { watched.append(request.key) }
        func start(_ request: TitleFormatRequest) { started.append(request.key) }
        func cancel(_ request: TitleFormatRequest) { cancelled.append(request.key) }
        func snapshot(for request: TitleFormatRequest) -> DetailFormatBadgeSnapshot {
            DetailFormatBadgeSnapshot(badges: cached, generation: generation)
        }
        func updates(for request: TitleFormatRequest) -> AsyncStream<DetailFormatBadgeSnapshot> {
            let (stream, continuation) = AsyncStream<DetailFormatBadgeSnapshot>.makeStream()
            continuations[request.key] = continuation
            return stream
        }
        func emit(_ badges: [TitleFormatBadge], key: String, generation: Int32? = nil) {
            continuations[key]?.yield(DetailFormatBadgeSnapshot(badges: badges, generation: generation ?? self.generation))
        }
        func hasUpdates(key: String) -> Bool { continuations[key] != nil }
    }

    private func request(_ id: String = "tt1") -> TitleFormatRequest {
        TitleFormatRequest(type: "movie", videoId: id, season: nil, episode: nil)
    }

    private func makeModel(_ source: FakeSource) -> DetailFormatBadgesModel {
        DetailFormatBadgesModel(source: source, dwell: .milliseconds(10))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func labels(_ model: DetailFormatBadgesModel) -> [String] { model.badges.map(\.label) }

    func testSettingOffNeverStartsAndLeavesBadgesEmpty() async {
        let source = FakeSource()
        let model = makeModel(source)
        await model.run(request: request(), enabled: false)
        XCTAssertTrue(source.started.isEmpty)
        XCTAssertTrue(model.badges.isEmpty)
    }

    func testNilRequestNeverStarts() async {
        let source = FakeSource()
        let model = makeModel(source)
        await model.run(request: nil, enabled: true)
        XCTAssertTrue(source.started.isEmpty)
        XCTAssertTrue(model.badges.isEmpty)
    }

    func testCancelDuringDwellNeverStarts() async {
        let source = FakeSource()
        let model = DetailFormatBadgesModel(source: source, dwell: .seconds(5))
        let req = request()
        let task = Task { await model.run(request: req, enabled: true) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        XCTAssertTrue(source.started.isEmpty)
        XCTAssertEqual(source.watched, [req.key], "tracked for the picker fold before the dwell")
    }

    func testAStaleSnapshotOnReappearanceReplacesTheShownBadges() async {
        let source = FakeSource()
        source.cached = [.uhd4k]
        let model = DetailFormatBadgesModel(source: source, dwell: .seconds(5))
        let req = request()
        let first = Task { await model.run(request: req, enabled: true) }
        await waitUntil("cached 4K") { !model.badges.isEmpty }
        first.cancel()
        await first.value

        // Expired or another configuration: the probe hides the old answer, same generation.
        source.cached = []
        let second = Task { await model.run(request: req, enabled: true) }
        await waitUntil("cleared") { model.badges.isEmpty }
        second.cancel()
        await second.value
    }

    func testStartsExactlyOnceAfterDwellAndFollowsEmissions() async {
        let source = FakeSource()
        let model = makeModel(source)
        let req = request()
        let task = Task { await model.run(request: req, enabled: true) }
        await waitUntil("start") { source.hasUpdates(key: req.key) }
        XCTAssertEqual(source.started, [req.key])
        source.emit([.uhd4k], key: req.key)
        await waitUntil("4K badge") { self.labels(model) == [TitleFormatBadge.uhd4k.label] }
        task.cancel()
        await task.value
        XCTAssertEqual(source.started.count, 1)
    }

    func testPickerFoldGrowsAndNeverShrinks() async {
        let source = FakeSource()
        let model = makeModel(source)
        let req = request()
        let task = Task { await model.run(request: req, enabled: true) }
        await waitUntil("start") { source.hasUpdates(key: req.key) }

        source.emit([.uhd4k], key: req.key)
        await waitUntil("4K") { self.labels(model) == [TitleFormatBadge.uhd4k.label] }
        source.emit([.uhd4k, .dolbyAtmos], key: req.key)
        let both = [TitleFormatBadge.uhd4k.label, TitleFormatBadge.dolbyAtmos.label]
        await waitUntil("4K + Atmos") { self.labels(model) == both }
        source.emit([.dolbyAtmos], key: req.key)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(labels(model), both)
        task.cancel()
        await task.value
    }

    func testAProbeResetReplacesTheBadges() async {
        let source = FakeSource()
        let model = makeModel(source)
        let req = request()
        let task = Task { await model.run(request: req, enabled: true) }
        await waitUntil("start") { source.hasUpdates(key: req.key) }

        source.emit([.uhd4k, .dolbyVision], key: req.key)
        await waitUntil("4K + DV") { model.badges.count == 2 }
        // The add-on set or filters changed: the probe starts a new generation, without the 4K.
        source.emit([.dolbyAtmos], key: req.key, generation: 7)
        await waitUntil("reset") { self.labels(model) == [TitleFormatBadge.dolbyAtmos.label] }
        task.cancel()
        await task.value
    }

    func testDolbyVisionThenHdrShowsOnlyDolbyVision() async {
        let source = FakeSource()
        let model = makeModel(source)
        let req = request()
        let task = Task { await model.run(request: req, enabled: true) }
        await waitUntil("start") { source.hasUpdates(key: req.key) }

        source.emit([.dolbyVision], key: req.key)
        await waitUntil("DV") { self.labels(model) == [TitleFormatBadge.dolbyVision.label] }
        source.emit([.hdr], key: req.key)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(labels(model), [TitleFormatBadge.dolbyVision.label])
        task.cancel()
        await task.value
    }

    func testCachedStateShowsBeforeTheDwell() async {
        let source = FakeSource()
        source.cached = [.uhd4k, .hdr]
        let model = DetailFormatBadgesModel(source: source, dwell: .seconds(5))
        let req = request()
        let task = Task { await model.run(request: req, enabled: true) }
        await waitUntil("cached badges") { !model.badges.isEmpty }
        XCTAssertTrue(source.started.isEmpty, "the dwell has not elapsed")
        XCTAssertEqual(labels(model), [TitleFormatBadge.uhd4k.label, TitleFormatBadge.hdr.label])
        task.cancel()
        await task.value
    }

    func testDisappearCancelsTheStartedRequest() async {
        let source = FakeSource()
        let model = makeModel(source)
        let req = request()
        let task = Task { await model.run(request: req, enabled: true) }
        await waitUntil("start") { source.hasUpdates(key: req.key) }
        model.disappear()
        XCTAssertEqual(source.cancelled, [req.key])
        model.disappear()
        XCTAssertEqual(source.cancelled, [req.key], "a second disappear cancels nothing more")
        task.cancel()
        await task.value
    }

    func testKeyChangeCancelsTheOldRequest() async {
        let source = FakeSource()
        let model = makeModel(source)
        let first = request("tt1")
        let second = request("tt2")
        let task = Task { await model.run(request: first, enabled: true) }
        await waitUntil("first start") { source.hasUpdates(key: first.key) }
        task.cancel()
        await task.value

        let task2 = Task { await model.run(request: second, enabled: true) }
        await waitUntil("second start") { source.hasUpdates(key: second.key) }
        XCTAssertEqual(source.cancelled, [first.key])
        XCTAssertEqual(source.started, [first.key, second.key])
        task2.cancel()
        await task2.value
    }

    func testNotReadyShowsKnownBadgesButNeverStarts() async {
        let source = FakeSource()
        source.cached = [.uhd4k]
        let model = makeModel(source)
        await model.run(request: request(), enabled: true, ready: false)
        XCTAssertTrue(source.started.isEmpty)
        XCTAssertEqual(labels(model), [TitleFormatBadge.uhd4k.label])
        XCTAssertNotEqual(DetailFormatBadgesModel.taskID(request: request(), enabled: true, ready: false),
                          DetailFormatBadgesModel.taskID(request: request(), enabled: true, ready: true))
    }

    func testCoveredStopsTheStartedProbeKeepsBadgesAndWatches() async {
        let source = FakeSource()
        let model = makeModel(source)
        let req = request()
        let task = Task { await model.run(request: req, enabled: true) }
        await waitUntil("start") { source.hasUpdates(key: req.key) }
        source.emit([.uhd4k], key: req.key)
        await waitUntil("4K") { self.labels(model) == [TitleFormatBadge.uhd4k.label] }
        task.cancel()
        await task.value

        source.cached = [.uhd4k]
        await model.run(request: req, enabled: true, covered: true)
        XCTAssertEqual(source.cancelled, [req.key], "one cancel")
        XCTAssertEqual(source.started, [req.key], "no further start under the cover")
        XCTAssertEqual(labels(model), [TitleFormatBadge.uhd4k.label])
        XCTAssertEqual(source.watched.last, req.key, "still tracked for the picker fold")
    }

    func testUncoveredRunStartsTheProbe() async {
        let source = FakeSource()
        let model = makeModel(source)
        let req = request()
        let task = Task { await model.run(request: req, enabled: true, covered: false) }
        await waitUntil("start") { source.hasUpdates(key: req.key) }
        XCTAssertEqual(source.started, [req.key])
        task.cancel()
        await task.value
    }

    /// Presenting a cover (any `DetailCoverStates` flag, the synopsis covers included) stops the
    /// running probe; dismissing it starts it again, from the cache, after the dwell.
    func testPresentingAndDismissingACoverStopsAndRestartsTheProbe() async {
        for synopsis in [DetailCoverStates(synopsisSheet: true), DetailCoverStates(aboutOverviewSheet: true)] {
            let source = FakeSource()
            let model = makeModel(source)
            let req = request()

            let running = Task { await model.run(request: req, enabled: true, covered: DetailCoverStates().isPresented) }
            await waitUntil("start") { source.hasUpdates(key: req.key) }
            XCTAssertEqual(source.started, [req.key])

            // The cover goes up: SwiftUI cancels the task for the old id and runs the new one.
            running.cancel()
            await running.value
            await model.run(request: req, enabled: true, covered: synopsis.isPresented)
            XCTAssertEqual(source.cancelled, [req.key], "the probe stopped behind the cover")
            XCTAssertEqual(source.started, [req.key], "and nothing started under it")

            // Dismissed: the probe runs again.
            let again = Task { await model.run(request: req, enabled: true, covered: DetailCoverStates().isPresented) }
            await waitUntil("restart") { source.started.count == 2 }
            again.cancel()
            await again.value
        }
    }

    func testTaskIDDiffersWhenCovered() {
        let a = request()
        XCTAssertNotEqual(DetailFormatBadgesModel.taskID(request: a, enabled: true, covered: true),
                          DetailFormatBadgesModel.taskID(request: a, enabled: true, covered: false))
    }

    func testTaskIDDiffersForSettingAndKey() {
        let a = request("tt1")
        let b = request("tt2")
        let onA = DetailFormatBadgesModel.taskID(request: a, enabled: true)
        XCTAssertNotEqual(onA, DetailFormatBadgesModel.taskID(request: a, enabled: false))
        XCTAssertNotEqual(onA, DetailFormatBadgesModel.taskID(request: b, enabled: true))
        XCTAssertEqual(onA, DetailFormatBadgesModel.taskID(request: request("tt1"), enabled: true))
        XCTAssertNotEqual(DetailFormatBadgesModel.taskID(request: nil, enabled: true), onA)
    }
}
