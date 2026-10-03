import AVFoundation
import Network
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (B2, BUG-131): unit tests for the `TrailerLocalHLS` listener lifecycle
/// (`Screens/TrailerLocalHLS.swift`). Everything runs against an injected listener factory, a fake
/// scheduler (timers fire on demand), a fake health check and a fake clock, so nothing here opens a
/// socket or sleeps. The class under test is `nonisolated`; the helpers below are too (this test
/// target has no default actor isolation), and `@Sendable` closures mutate them under a lock.

// MARK: - Fakes

private final class TrailerHLSTestLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class TrailerHLSTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// A listener that records `start` and `cancel`, and reports whatever the test `emit`s. `cancel()`
/// does NOT report `.cancelled` by itself: the real `NWListener` delivers it later, and the rebuild
/// logic must wait for that, so the test emits it explicitly.
private final class TrailerHLSFakeListener: TrailerLoopbackListening, @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var handler: (@Sendable (TrailerListenerState) -> Void)?
    private var cancels = 0
    private var starts = 0

    init(port: UInt16) { self.port = port }

    func start(queue: DispatchQueue,
               onState: @escaping @Sendable (TrailerListenerState) -> Void,
               onConnection: @escaping @Sendable (NWConnection) -> Void) {
        lock.lock(); handler = onState; starts += 1; lock.unlock()
    }

    func cancel() {
        lock.lock(); cancels += 1; lock.unlock()
    }

    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancels }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }

    func emit(_ state: TrailerListenerState) {
        lock.lock(); let h = handler; lock.unlock()
        h?(state)
    }
}

private final class TrailerHLSFakeFactory: @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var created: [TrailerHLSFakeListener] = []
    private var requested: [UInt16] = []
    private var throwing: Set<UInt16> = []

    func make(_ port: UInt16) throws -> TrailerLoopbackListening {
        lock.lock()
        requested.append(port)
        let shouldThrow = throwing.contains(port)
        lock.unlock()
        if shouldThrow { throw Failure() }
        let listener = TrailerHLSFakeListener(port: port)
        lock.lock(); created.append(listener); lock.unlock()
        return listener
    }

    func throwOn(_ ports: [UInt16]) { lock.lock(); throwing = Set(ports); lock.unlock() }
    var listeners: [TrailerHLSFakeListener] { lock.lock(); defer { lock.unlock() }; return created }
    var requestedPorts: [UInt16] { lock.lock(); defer { lock.unlock() }; return requested }
}

private final class TrailerHLSFakeScheduler: @unchecked Sendable {
    private struct Item { let delay: TimeInterval; let work: @Sendable () -> Void }
    private let lock = NSLock()
    private var items: [Item] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lock.lock(); items.append(Item(delay: delay, work: work)); lock.unlock()
    }

    func pendingCount(_ delay: TimeInterval) -> Int {
        lock.lock(); defer { lock.unlock() }
        return items.filter { $0.delay == delay }.count
    }

    /// Fires the oldest pending item scheduled with exactly `delay`.
    @discardableResult
    func fire(_ delay: TimeInterval) -> Bool {
        lock.lock()
        guard let index = items.firstIndex(where: { $0.delay == delay }) else { lock.unlock(); return false }
        let item = items.remove(at: index)
        lock.unlock()
        item.work()
        return true
    }
}

private final class TrailerHLSFakeHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var isAlive = true
    private var ports: [UInt16] = []

    var alive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isAlive }
        set { lock.lock(); isAlive = newValue; lock.unlock() }
    }
    var checkedPorts: [UInt16] { lock.lock(); defer { lock.unlock() }; return ports }

    func check(_ port: UInt16, _ done: @Sendable (Bool) -> Void) {
        lock.lock(); ports.append(port); let result = isAlive; lock.unlock()
        done(result)
    }
}

private final class TrailerHLSFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1_000
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// One `TrailerLocalHLS` wired to the fakes.
private final class TrailerHLSHarness {
    let factory = TrailerHLSFakeFactory()
    let scheduler = TrailerHLSFakeScheduler()
    let health = TrailerHLSFakeHealth()
    let clock = TrailerHLSFakeClock()
    let hls: TrailerLocalHLS

    init(basePort: UInt16 = 8230) {
        let factory = self.factory
        let scheduler = self.scheduler
        let health = self.health
        let clock = self.clock
        hls = TrailerLocalHLS(
            listenerFactory: { port in try factory.make(port) },
            schedule: { delay, work in scheduler.schedule(delay, work) },
            healthCheck: { port, done in health.check(port, done) },
            uptime: { clock.now },
            basePort: basePort,
            observesLifecycle: false
        )
    }

    /// Starts the server and reports `.ready` on whatever listener the factory just created.
    @discardableResult
    func startReady(results: TrailerHLSTestLog<UInt16?>? = nil) -> TrailerHLSFakeListener {
        hls.ensureStarted { results?.add($0) }
        let listener = factory.listeners.last!
        listener.emit(.ready)
        return listener
    }
}

// MARK: - Tests

final class TrailerLocalHLSListenerTests: XCTestCase {

    // MARK: Start

    func testConcurrentWaitersShareOneStart() {
        let h = TrailerHLSHarness()
        let results = TrailerHLSTestLog<UInt16?>()
        h.hls.ensureStarted { results.add($0) }
        h.hls.ensureStarted { results.add($0) }
        XCTAssertEqual(h.factory.requestedPorts, [8230], "two waiters, one start")
        XCTAssertTrue(results.all.isEmpty)
        h.factory.listeners[0].emit(.ready)
        XCTAssertEqual(results.all, [8230, 8230])
        // A ready port answers at once, with no new listener.
        h.hls.ensureStarted { results.add($0) }
        XCTAssertEqual(results.all, [8230, 8230, 8230])
        XCTAssertEqual(h.factory.requestedPorts, [8230])
    }

    func testWaitingHoldsUntilDeadlineThenNextPort() {
        let h = TrailerHLSHarness()
        let results = TrailerHLSTestLog<UInt16?>()
        h.hls.ensureStarted { results.add($0) }
        let first = h.factory.listeners[0]
        first.emit(.waiting("path unsatisfied"))
        XCTAssertEqual(h.factory.requestedPorts, [8230], "waiting does not move on by itself")
        XCTAssertTrue(results.all.isEmpty, "waiters keep waiting until the deadline")
        XCTAssertEqual(h.scheduler.pendingCount(TrailerLocalHLS.startDeadline), 1)

        h.scheduler.fire(TrailerLocalHLS.startDeadline)
        XCTAssertEqual(results.all, [nil], "the deadline resolves the waiters with nil (progressive fallback)")
        XCTAssertEqual(first.cancelCount, 1, "the stuck candidate is cancelled")
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8231])
        XCTAssertEqual(h.scheduler.pendingCount(TrailerLocalHLS.startDeadline), 1, "the next port gets a fresh deadline")
    }

    func testLateReadyAfterDeadlineIsIgnored() {
        let h = TrailerHLSHarness()
        let results = TrailerHLSTestLog<UInt16?>()
        h.hls.ensureStarted { results.add($0) }
        let first = h.factory.listeners[0]
        h.scheduler.fire(TrailerLocalHLS.startDeadline)
        XCTAssertEqual(results.all, [nil])
        let second = h.factory.listeners[1]

        first.emit(.ready)   // a late ready from the cancelled candidate
        let late = TrailerHLSTestLog<UInt16?>()
        h.hls.ensureStarted { late.add($0) }
        XCTAssertTrue(late.all.isEmpty, "the late ready did not make the server ready")
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8231])

        second.emit(.ready)
        XCTAssertEqual(late.all, [8231])
    }

    func testStaleDeadlineAfterReadyIsIgnored() {
        let h = TrailerHLSHarness()
        let results = TrailerHLSTestLog<UInt16?>()
        h.startReady(results: results)
        h.scheduler.fire(TrailerLocalHLS.startDeadline)
        XCTAssertEqual(h.factory.requestedPorts, [8230])
        XCTAssertEqual(h.factory.listeners[0].cancelCount, 0)
    }

    func testFailedOnPreferredPortRetriesSamePortThreeTimes() {
        let h = TrailerHLSHarness()
        let first = h.startReady()   // 8230 becomes the preferred port
        first.emit(.failed("boom"))  // death after ready: eager rebuild, waiting for the old socket
        XCTAssertEqual(h.factory.requestedPorts, [8230])
        first.emit(.cancelled)
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8230], "the rebuild prefers the same port")

        for retry in 1...3 {
            h.factory.listeners.last!.emit(.failed("addrinuse"))
            XCTAssertEqual(h.scheduler.pendingCount(TrailerLocalHLS.sameBindRetryDelay), 1, "retry \(retry) waits 100 ms")
            XCTAssertEqual(h.factory.requestedPorts.count, 1 + retry, "no factory call before the 100 ms elapse")
            h.scheduler.fire(TrailerLocalHLS.sameBindRetryDelay)
            XCTAssertEqual(h.factory.requestedPorts.last, 8230, "retry \(retry) is the SAME port")
        }
        // The fourth failure on the preferred port moves on at once.
        h.factory.listeners.last!.emit(.failed("addrinuse"))
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8230, 8230, 8230, 8230, 8231])
        XCTAssertEqual(h.scheduler.pendingCount(TrailerLocalHLS.sameBindRetryDelay), 0)
    }

    func testFailureOnAFirstEverPortGoesStraightToTheNext() {
        // No preferred port yet (nothing was ever ready): no same-port retries.
        let h = TrailerHLSHarness()
        h.hls.ensureStarted { _ in }
        h.factory.listeners[0].emit(.failed("addrinuse"))
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8231])
    }

    func testAllPortsExhaustedResolvesWaitersNil() {
        let h = TrailerHLSHarness(basePort: 8230)
        h.factory.throwOn((0..<20).map { UInt16(8230 + $0) })
        let results = TrailerHLSTestLog<UInt16?>()
        h.hls.ensureStarted { results.add($0) }
        XCTAssertEqual(results.all, [nil])
        XCTAssertEqual(h.factory.requestedPorts.count, 20)
        // Not stuck in flight: the next call tries again.
        h.factory.throwOn([])
        h.hls.ensureStarted { results.add($0) }
        XCTAssertEqual(h.factory.listeners.count, 1)
    }

    // MARK: Lifecycle

    func testActiveAfterBackgroundAliveDoesNothing() {
        let h = TrailerHLSHarness()
        let listener = h.startReady()
        h.health.alive = true
        h.hls.noteLifecycle(.background)
        h.hls.noteLifecycle(.active)
        XCTAssertEqual(h.health.checkedPorts, [8230], "verified first")
        XCTAssertEqual(listener.cancelCount, 0)
        XCTAssertEqual(h.factory.requestedPorts, [8230])
    }

    func testActiveAfterBackgroundDeadRebuildsAfterCancelled() {
        let h = TrailerHLSHarness()
        let listener = h.startReady()
        h.health.alive = false
        h.hls.noteLifecycle(.background)
        h.hls.noteLifecycle(.active)
        XCTAssertEqual(listener.cancelCount, 1, "the dead listener is cancelled")
        XCTAssertEqual(h.factory.requestedPorts, [8230], "no new listener until the old socket reports cancelled")

        listener.emit(.cancelled)
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8230], "then it rebinds the same port")
        h.factory.listeners.last!.emit(.ready)
        let results = TrailerHLSTestLog<UInt16?>()
        h.hls.ensureStarted { results.add($0) }
        XCTAssertEqual(results.all, [8230])
    }

    func testRebuildBindsAnywayAfterTheRetireWait() {
        let h = TrailerHLSHarness()
        let listener = h.startReady()
        h.health.alive = false
        h.hls.noteLifecycle(.background)
        h.hls.noteLifecycle(.active)
        XCTAssertEqual(h.factory.requestedPorts, [8230])
        XCTAssertEqual(h.scheduler.pendingCount(TrailerLocalHLS.retireWait), 1)

        h.scheduler.fire(TrailerLocalHLS.retireWait)
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8230])
        listener.emit(.cancelled)   // arrives too late: must not start a second rebuild
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8230])
    }

    func testActiveWithoutBackgroundDoesNothing() {
        let h = TrailerHLSHarness()
        let listener = h.startReady()
        h.health.alive = false
        h.hls.noteLifecycle(.active)
        XCTAssertTrue(h.health.checkedPorts.isEmpty)
        XCTAssertEqual(listener.cancelCount, 0)
        XCTAssertEqual(h.factory.requestedPorts, [8230])
    }

    func testActiveAfterBackgroundWithNothingReadyDoesNothing() {
        let h = TrailerHLSHarness()
        h.hls.noteLifecycle(.background)
        h.hls.noteLifecycle(.active)
        XCTAssertTrue(h.health.checkedPorts.isEmpty)
        XCTAssertTrue(h.factory.requestedPorts.isEmpty)
    }

    func testDeathAfterReadyRebuildsPreferringSamePort() {
        let h = TrailerHLSHarness()
        // 8230 refuses to bind; 8231 becomes the bound port.
        h.hls.ensureStarted { _ in }
        h.factory.listeners[0].emit(.failed("addrinuse"))
        let bound = h.factory.listeners[1]
        bound.emit(.ready)
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8231])

        bound.emit(.failed("socket reclaimed"))
        bound.emit(.cancelled)
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8231, 8231], "the rebuild goes straight to the last bound port")
    }

    func testWaitingAfterReadyIsADeath() {
        let h = TrailerHLSHarness()
        let listener = h.startReady()
        listener.emit(.waiting("path lost"))
        XCTAssertEqual(listener.cancelCount, 1)
        listener.emit(.cancelled)
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8230])
    }

    func testStaleEventsFromARetiredListenerAreIgnored() {
        let h = TrailerHLSHarness()
        let old = h.startReady()
        old.emit(.failed("boom"))
        old.emit(.cancelled)
        let rebuilt = h.factory.listeners.last!
        rebuilt.emit(.ready)
        old.emit(.ready)     // stale
        old.emit(.failed("late"))   // stale: must not kill the rebuilt listener
        XCTAssertEqual(rebuilt.cancelCount, 0)
        let results = TrailerHLSTestLog<UInt16?>()
        h.hls.ensureStarted { results.add($0) }
        XCTAssertEqual(results.all, [8230])
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8230])
    }

    func testEagerRebuildBudget() {
        let h = TrailerHLSHarness()
        var current = h.startReady()
        for index in 1...3 {
            current.emit(.failed("x"))
            current.emit(.cancelled)
            XCTAssertEqual(h.factory.listeners.count, index + 1, "death \(index) rebuilds eagerly")
            current = h.factory.listeners.last!
            current.emit(.ready)
        }
        // The fourth death inside 60 s is over budget: lazy, no new listener.
        current.emit(.failed("x"))
        XCTAssertEqual(h.factory.listeners.count, 4)
        XCTAssertEqual(current.cancelCount, 1, "the dead listener is still cancelled")
        // The next caller starts it.
        let results = TrailerHLSTestLog<UInt16?>()
        h.hls.ensureStarted { results.add($0) }
        XCTAssertEqual(h.factory.listeners.count, 5)
        h.factory.listeners.last!.emit(.ready)
        XCTAssertEqual(results.all, [8230])

        // Once the window has passed the budget is back.
        h.clock.now += 61
        let last = h.factory.listeners.last!
        last.emit(.failed("x"))
        last.emit(.cancelled)
        XCTAssertEqual(h.factory.listeners.count, 6)
    }

    func testHealthCheckDeadMarksDeadAndRebuilds() {
        let h = TrailerHLSHarness()
        let listener = h.startReady()
        h.health.alive = false
        h.hls.verifyListener(reason: "playback")
        XCTAssertEqual(h.health.checkedPorts, [8230])
        XCTAssertEqual(listener.cancelCount, 1)
        listener.emit(.cancelled)
        XCTAssertEqual(h.factory.requestedPorts, [8230, 8230])
    }

    func testHealthCheckAliveLeavesTheListenerAlone() {
        let h = TrailerHLSHarness()
        let listener = h.startReady()
        h.health.alive = true
        h.hls.verifyListener(reason: "playback")
        XCTAssertEqual(listener.cancelCount, 0)
        XCTAssertEqual(h.factory.requestedPorts, [8230])
    }

    func testVerifyWithNothingReadyDoesNothing() {
        let h = TrailerHLSHarness()
        h.hls.verifyListener(reason: "playback")
        XCTAssertTrue(h.health.checkedPorts.isEmpty)
    }

    // MARK: Cached URLs

    func testServableURL() {
        let h = TrailerHLSHarness()
        h.hls.storeTokenForTesting("tok")
        let url = "http://127.0.0.1:8230/tok/master.m3u8"
        XCTAssertEqual(h.hls.servableURL(url, readyPort: 8230), url, "same port: unchanged")
        XCTAssertEqual(h.hls.servableURL(url, readyPort: 8231), "http://127.0.0.1:8231/tok/master.m3u8",
                       "the port moved and the token is stored: rebased, no re-extraction")
        XCTAssertNil(h.hls.servableURL("http://127.0.0.1:8230/unknown/master.m3u8", readyPort: 8230), "token gone")
        XCTAssertNil(h.hls.servableURL(url, readyPort: nil), "no ready listener")
        let remote = "https://rr1---sn-abc.googlevideo.com/videoplayback?id=x"
        XCTAssertEqual(h.hls.servableURL(remote, readyPort: 8231), remote, "non-loopback URLs are unchanged")
        XCTAssertEqual(h.hls.servableURL(remote, readyPort: nil), remote)
    }

    func testPortInPlaybackURL() {
        XCTAssertEqual(TrailerLocalHLS.port(inPlaybackURL: "http://127.0.0.1:8230/tok/master.m3u8"), 8230)
        XCTAssertEqual(TrailerLocalHLS.port(inPlaybackURL: "http://127.0.0.1:8249/tok/video.m3u8"), 8249)
        XCTAssertNil(TrailerLocalHLS.port(inPlaybackURL: "https://rr1---sn-abc.googlevideo.com:443/videoplayback"))
        XCTAssertNil(TrailerLocalHLS.port(inPlaybackURL: "http://127.0.0.1/tok/master.m3u8"))
        XCTAssertNil(TrailerLocalHLS.port(inPlaybackURL: "not a url"))
    }

    func testPortOrderPutsThePreferredPortFirst() {
        XCTAssertEqual(TrailerLocalHLS.portOrder(base: 8230, count: 4, preferred: nil), [8230, 8231, 8232, 8233])
        XCTAssertEqual(TrailerLocalHLS.portOrder(base: 8230, count: 4, preferred: 8232), [8232, 8230, 8231, 8233])
        XCTAssertEqual(TrailerLocalHLS.portOrder(base: 8230, count: 4, preferred: 9000), [8230, 8231, 8232, 8233])
    }

    // MARK: Outcome API

    func testOutcomeTimeout() {
        // Never completes: the timeout wins.
        let scheduler = TrailerHLSFakeScheduler()
        let out = TrailerHLSTestLog<TrailerPlaybackURLOutcome>()
        let finishA = TrailerHLSTestBox<@Sendable (TrailerPlaybackURLOutcome) -> Void>()
        TrailerLocalHLS.race(
            timeout: TrailerLocalHLS.inlinePlaybackURLTimeout,
            schedule: { scheduler.schedule($0, $1) },
            work: { finish in finishA.value = finish },
            onTimeout: { .timedOut(progressive: "https://p") },
            completion: { out.add($0) }
        )
        XCTAssertEqual(TrailerLocalHLS.inlinePlaybackURLTimeout, 12)
        XCTAssertEqual(scheduler.pendingCount(12), 1)
        XCTAssertTrue(out.all.isEmpty)
        scheduler.fire(12)
        XCTAssertEqual(out.all, [.timedOut(progressive: "https://p")])
        // Completes late: ignored.
        finishA.value?(.playable("late"))
        XCTAssertEqual(out.all, [.timedOut(progressive: "https://p")])

        // Completes first: wins, and a later timer fire is ignored.
        let scheduler2 = TrailerHLSFakeScheduler()
        let out2 = TrailerHLSTestLog<TrailerPlaybackURLOutcome>()
        let finishB = TrailerHLSTestBox<@Sendable (TrailerPlaybackURLOutcome) -> Void>()
        TrailerLocalHLS.race(
            timeout: 12,
            schedule: { scheduler2.schedule($0, $1) },
            work: { finish in finishB.value = finish },
            onTimeout: { .timedOut(progressive: nil) },
            completion: { out2.add($0) }
        )
        finishB.value?(.playable("u"))
        scheduler2.fire(12)
        XCTAssertEqual(out2.all, [.playable("u")])

        // A synchronous answer arms no timer at all.
        let scheduler3 = TrailerHLSFakeScheduler()
        let out3 = TrailerHLSTestLog<TrailerPlaybackURLOutcome>()
        TrailerLocalHLS.race(
            timeout: 12,
            schedule: { scheduler3.schedule($0, $1) },
            work: { finish in finish(.nothingPlayable) },
            onTimeout: { .timedOut(progressive: nil) },
            completion: { out3.add($0) }
        )
        XCTAssertEqual(out3.all, [.nothingPlayable])
        XCTAssertEqual(scheduler3.pendingCount(12), 0)
    }

    func testTimedResolveFallsBackToProgressiveOrNone() {
        let h = TrailerHLSHarness()
        let finish1 = TrailerHLSTestBox<@Sendable (String?) -> Void>()
        let out1 = TrailerHLSTestLog<TrailerPlaybackURLOutcome>()
        h.hls.resolveTimed(videoId: nil, progressive: "https://p", timeout: 12,
                           repack: { finish in finish1.value = finish }, completion: { out1.add($0) })
        h.scheduler.fire(12)
        XCTAssertEqual(out1.all, [.timedOut(progressive: "https://p")])
        finish1.value?("http://127.0.0.1:8230/tok/master.m3u8")   // late repack: dropped
        XCTAssertEqual(out1.all, [.timedOut(progressive: "https://p")])

        let out2 = TrailerHLSTestLog<TrailerPlaybackURLOutcome>()
        h.hls.resolveTimed(videoId: nil, progressive: nil, timeout: 12,
                           repack: { _ in }, completion: { out2.add($0) })
        h.scheduler.fire(12)
        XCTAssertEqual(out2.all, [.timedOut(progressive: nil)], "a timeout is never 'nothing playable'")
    }

    func testResolveOutcomes() {
        let h = TrailerHLSHarness()
        let out = TrailerHLSTestLog<TrailerPlaybackURLOutcome>()
        // No adaptive pair: the progressive URL, immediately.
        h.hls.resolveRaw(videoId: nil, progressive: "https://p", repack: nil, completion: { out.add($0) })
        // Nothing at all.
        h.hls.resolveRaw(videoId: nil, progressive: nil, repack: nil, completion: { out.add($0) })
        // A repack that builds.
        h.hls.resolveRaw(videoId: nil, progressive: "https://p", repack: { $0("http://127.0.0.1:8230/t/master.m3u8") },
                         completion: { out.add($0) })
        // A repack that fails: the progressive URL.
        h.hls.resolveRaw(videoId: nil, progressive: "https://p", repack: { $0(nil) }, completion: { out.add($0) })
        // A repack that fails with no progressive: nothing playable.
        h.hls.resolveRaw(videoId: nil, progressive: nil, repack: { $0(nil) }, completion: { out.add($0) })
        XCTAssertEqual(out.all, [
            .playable("https://p"),
            .nothingPlayable,
            .playable("http://127.0.0.1:8230/t/master.m3u8"),
            .playable("https://p"),
            .nothingPlayable,
        ])
        XCTAssertEqual(TrailerPlaybackURLOutcome.playable("u").legacyURL, "u")
        XCTAssertNil(TrailerPlaybackURLOutcome.nothingPlayable.legacyURL)
        XCTAssertNil(TrailerPlaybackURLOutcome.timedOut(progressive: "p").legacyURL)
    }

    func testLegacyAPIHasNoOuterTimeout() {
        // Detail's `playbackURL(for:)` shape: `resolveRaw`, never `resolveTimed`.
        let h = TrailerHLSHarness()
        let finish = TrailerHLSTestBox<@Sendable (String?) -> Void>()
        let out = TrailerHLSTestLog<TrailerPlaybackURLOutcome>()
        h.hls.resolveRaw(videoId: nil, progressive: "https://p",
                         repack: { f in finish.value = f }, completion: { out.add($0) })
        XCTAssertEqual(h.scheduler.pendingCount(TrailerLocalHLS.inlinePlaybackURLTimeout), 0,
                       "the legacy path arms no outer timeout")
        h.clock.now += 20   // 20 s later
        finish.value?("http://127.0.0.1:8230/tok/master.m3u8")
        XCTAssertEqual(out.all, [.playable("http://127.0.0.1:8230/tok/master.m3u8")],
                       "a completion 20 s late still reaches the legacy callback")
    }

    // MARK: Failure classification

    @MainActor
    func testIsConnectionClass() {
        let network = NSError(domain: NSURLErrorDomain, code: -1004)
        let media = NSError(domain: AVFoundationErrorDomain, code: -11800)
        XCTAssertTrue(TrailerFailureCause.watchdogTimeout.isConnectionClass)
        XCTAssertTrue(TrailerFailureCause.itemFailed(network).isConnectionClass)
        XCTAssertTrue(TrailerFailureCause.failedToPlayToEnd(network).isConnectionClass)
        XCTAssertFalse(TrailerFailureCause.itemFailed(media).isConnectionClass)
        XCTAssertFalse(TrailerFailureCause.failedToPlayToEnd(media).isConnectionClass)
        XCTAssertFalse(TrailerFailureCause.itemFailed(nil).isConnectionClass)
        XCTAssertFalse(TrailerFailureCause.badURL.isConnectionClass)
    }
}
