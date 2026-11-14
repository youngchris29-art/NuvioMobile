import Combine
import Foundation

// Home Stage & Strip (P1 §3.5): the strip's own motion signal. The strip pages with an app-driven
// `.scrollPosition` animation (spike a2), so "are the rows moving" is known exactly: a page is in
// flight from the moment the pager starts its animation until that animation reports completion
// (#15). It feeds three readers: the rows' trailer dwell (`\.rowRestSource = .custom(signal)`, M3),
// the stage resolver's post-commit sharpen (`HeroArtResolver.restSource`), and the stage swap
// driver (through `StageController`), which never fades the text while a page is in flight.

/// The production schedule the strip signal and the stage swap driver share: `TextSwapModel`'s
/// `mainQueueSchedule` shape, so the unit tests can inject the same fake clock.
enum StageScheduling {
    /// Runs `work` after `after` seconds; cancelling the returned token drops it.
    typealias Schedule = @MainActor (_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable

    static func main(_ after: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, after), execute: item)
        return AnyCancellable { item.cancel() }
    }
}

/// See the file header. One page at a time: each `pageStarted` is a new GENERATION, and only the
/// latest generation's completion ends the page, so a held Down (a new page every hop, each
/// re-targeting the same `positionId` animation) reads as one page from the first hop to the glide's
/// real end (§3.2).
@MainActor
final class StripMotionSignal: RowRestSignal {
    /// Test seam.
    var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// True from `pageStarted` until the latest generation ends.
    private(set) var pageInFlight = false
    private(set) var generation = 0
    /// Whether the last page was ended by the fallback rather than by its animation's completion
    /// (the swap probe line's `pageEnd=timeout`).
    private(set) var lastEndedByTimeout = false
    /// When the last page ended (`now`), nil before the first.
    private(set) var lastPageEndedAt: TimeInterval?

    /// `StageController` wires these to the swap driver.
    var onPageStarted: (@MainActor () -> Void)?
    var onPageEnded: (@MainActor (_ byTimeout: Bool) -> Void)?

    /// How long past its nominal duration a page may run before the fallback ends it: the
    /// completion is not guaranteed (no view left depending on the animated value, the strip torn
    /// down mid-glide), and a page that never ended would hold the swap gate shut forever.
    static let fallbackSlack: TimeInterval = 0.5

    private let schedule: StageScheduling.Schedule
    private var fallback: AnyCancellable?

    init(schedule: StageScheduling.Schedule? = nil) {
        self.schedule = schedule ?? { after, work in StageScheduling.main(after, work) }
    }

    /// A page animation of `duration` seconds is starting. Returns its generation, which the pager
    /// hands back to `pageEnded(generation:)` from the animation's completion.
    @discardableResult
    func pageStarted(duration: TimeInterval) -> Int {
        generation &+= 1
        let started = generation
        pageInFlight = true
        lastEndedByTimeout = false
        RowsMotionClock.stamp()
        fallback?.cancel()
        fallback = schedule(max(0, duration) + Self.fallbackSlack) { [weak self] in
            self?.end(generation: started, byTimeout: true)
        }
        onPageStarted?()
        return started
    }

    /// The page animation `generation` finished. Ignored unless it is the latest generation.
    func pageEnded(generation ended: Int) {
        end(generation: ended, byTimeout: false)
    }

    // MARK: RowRestSignal

    var restPending: Bool { pageInFlight }

    /// The strip's vertical glide and every row's horizontal scroll stamp `RowsMotionClock`
    /// (`rowsMotionStamp(.vertical)` on the strip, `RowHScrollBox.record` in the rows), so the rows'
    /// own clock is the honest "since the rows last moved".
    var secondsSinceMotion: TimeInterval { RowsMotionClock.secondsSinceMotion() }

    // MARK: Private

    private func end(generation ended: Int, byTimeout: Bool) {
        guard ended == generation, pageInFlight else { return }
        pageInFlight = false
        lastEndedByTimeout = byTimeout
        lastPageEndedAt = now()
        fallback?.cancel()
        fallback = nil
        if byTimeout {
            StageStripProbe.shared.log("page gen=\(ended) pageEnd=timeout")
        }
        onPageEnded?(byTimeout)
    }
}

/// D10 r1: whether the strip is still MOVING, kept apart from `StripMotionSignal`, whose page ends at
/// its animation's logical completion about a frame into the glide (17-222 ms against a 415-1140 ms
/// visible glide in the simulator, 14-85 ms against ~510 ms on the Living Room box, 2026-11-13).
/// Moving = inside a started glide's nominal duration, or the strip's own offset changed within
/// `quiet`. `armRestCheck` asks for one `onRest` once the strip has been still since; nothing here
/// waits on an animation completion.
@MainActor
final class StripRestWatch {
    /// Test seam.
    var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Still this long after the last offset change = at rest. An ease-out tail still stamps every
    /// half point (`RowsMotionClock.bucket`), so a creeping tail reads as moving.
    static let quiet: TimeInterval = 0.12
    /// The pager's rest handler: set on its appear, cleared on its disappear (it captures the pager,
    /// whose `@State` holds the box that holds this watch).
    var onRest: (@MainActor () -> Void)?
    private(set) var glideDeadline: TimeInterval = -.infinity
    private(set) var lastOffsetChange: TimeInterval = -.infinity
    private var armedAt: TimeInterval?
    private var pending: AnyCancellable?
    private let schedule: StageScheduling.Schedule

    init(schedule: StageScheduling.Schedule? = nil) {
        self.schedule = schedule ?? { after, work in StageScheduling.main(after, work) }
    }

    /// A glide of `duration` seconds starts now (a page).
    func glideStarted(duration: TimeInterval) {
        glideDeadline = max(glideDeadline, now() + max(0, duration))
    }

    /// The strip's vertical offset moved (`StripScroller`'s `onScrollGeometryChange`).
    func offsetChanged() {
        lastOffsetChange = now()
    }

    var isMoving: Bool {
        let t = now()
        return t < glideDeadline || t < lastOffsetChange + Self.quiet
    }

    var isArmed: Bool { armedAt != nil }

    /// One `onRest` once the strip is at rest: no sooner than `quiet` after the latest arm, after the
    /// last started glide's nominal end, and `quiet` after the last offset change. Arming again while
    /// armed keeps one pending call.
    func armRestCheck() {
        armedAt = now()
        check()
    }

    /// Drops an armed check (the strip left the screen). True when one was armed.
    @discardableResult
    func cancel() -> Bool {
        pending?.cancel()
        pending = nil
        guard armedAt != nil else { return false }
        armedAt = nil
        return true
    }

    private func check() {
        pending?.cancel()
        pending = nil
        guard let armedAt else { return }
        let restAt = max(armedAt + Self.quiet, glideDeadline, lastOffsetChange + Self.quiet)
        let t = now()
        // 1 µs of slack: a timer due at `restAt` must not reschedule itself on a rounding error.
        guard t >= restAt - 1e-6 else {
            pending = schedule(restAt - t) { [weak self] in self?.check() }
            return
        }
        self.armedAt = nil
        onRest?()
    }
}
