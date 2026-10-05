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
