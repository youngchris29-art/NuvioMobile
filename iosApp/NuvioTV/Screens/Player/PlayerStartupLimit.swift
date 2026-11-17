import Combine
import Foundation

/// W4 (upstream 8fba6c71e's start-up timeout): how long an auto-picked source may take to show its
/// first frame before the host may move to the next one. Pure value, clock passed in (same shape as
/// `MPVStartWatchdog`). One budget per engine: an engine handoff before the first frame re-arms it,
/// so a source can take up to twice the limit when native or Aether hands it to mpv.
struct PlayerStartupLimit: Equatable {
    enum Verdict: Equatable {
        /// Armed and still inside the limit.
        case waiting
        /// The limit passed with no first frame; `elapsed` counts from the last (re-)arm.
        case reached(elapsed: TimeInterval)
        /// Not armed, already started, cancelled, or already reached and consumed.
        case inactive
    }

    private enum Phase: Equatable {
        case idle
        case armed(since: TimeInterval)
        /// Started, cancelled or reached: never fires again.
        case finished
    }

    let limitSeconds: Double
    private var phase: Phase = .idle

    init(limitSeconds: Double) {
        self.limitSeconds = limitSeconds
    }

    /// The source began loading at `at`. Ignored once the limit has finished.
    mutating func arm(at: TimeInterval) {
        if case .finished = phase { return }
        phase = .armed(since: at)
    }

    /// Native or Aether handed the source to mpv before it started: a full limit again. Ignored
    /// unless armed (after the first frame, or after the limit was reached, nothing restarts).
    mutating func noteHandoff(at: TimeInterval) {
        guard case .armed = phase else { return }
        phase = .armed(since: at)
    }

    /// The first frame showed: never fires again.
    mutating func noteStarted() { phase = .finished }

    /// The player is going away: never fires again.
    mutating func noteCancelled() { phase = .finished }

    var isArmed: Bool {
        if case .armed = phase { return true }
        return false
    }

    /// The verdict at `now`, latching `.reached` (returned exactly once).
    mutating func poll(now: TimeInterval) -> Verdict {
        guard case let .armed(since) = phase else { return .inactive }
        let elapsed = now - since
        guard elapsed >= limitSeconds else { return .waiting }
        phase = .finished
        return .reached(elapsed: elapsed)
    }
}

/// W4: drives one `PlayerStartupLimit` for `PlayerScreen` (a struct view, so the timer and the
/// callbacks live in this box, held as a `@StateObject`; nothing here is published). Polled from a
/// 1 s main-runloop timer; tests call `tick()` with their own clock and no timer. Forwards the
/// first "started" signal of the context once, whichever engine sent it.
@MainActor
final class PlayerStartupLimitClock: ObservableObject {
    private let now: () -> TimeInterval
    private let usesTimer: Bool
    private var limit: PlayerStartupLimit?
    private var timer: Timer?
    private var onReached: (() -> Void)?
    private var startedForwarded = false
    /// The context the clock runs for: a second `arm` for it changes nothing.
    private var contextID: String?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, usesTimer: Bool = true) {
        self.now = now
        self.usesTimer = usesTimer
    }

    deinit {
        timer?.invalidate()
    }

    /// The limit is armed and has not fired, started or been cancelled.
    var isArmed: Bool { limit?.isArmed ?? false }

    /// Starts the clock for `contextID`. nil `limitSeconds` or `onReached` (a manual pick, falling
    /// back off): nothing is armed. Arming again for the same context changes nothing (started,
    /// reached and cancelled stay so); arming for another context starts over.
    func arm(contextID: String, limitSeconds: Double?, onReached: (() -> Void)?) {
        guard contextID != self.contextID else { return }
        self.contextID = contextID
        stop()
        startedForwarded = false
        guard let limitSeconds, let onReached else {
            limit = nil
            self.onReached = nil
            return
        }
        var fresh = PlayerStartupLimit(limitSeconds: limitSeconds)
        fresh.arm(at: now())
        limit = fresh
        self.onReached = onReached
        print("[Startup] limit armed: \(Int(limitSeconds)) s")
        guard usesTimer else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Native or Aether handed the source to mpv (a no-op once started or reached).
    func noteHandoff() {
        guard var current = limit, current.isArmed else { return }
        current.noteHandoff(at: now())
        limit = current
        print("[Startup] limit re-armed for mpv after an engine handoff: \(Int(current.limitSeconds)) s")
    }

    /// The first frame showed. Returns true the first time for this arm (the host is told once).
    @discardableResult
    func noteStarted() -> Bool {
        if var current = limit {
            current.noteStarted()
            limit = current
        }
        stop()
        guard !startedForwarded else { return false }
        startedForwarded = true
        return true
    }

    /// The player is going away (disappear, context change): never fires.
    func cancel() {
        if var current = limit {
            current.noteCancelled()
            limit = current
        }
        stop()
        onReached = nil
    }

    /// One poll; the timer calls it every second.
    func tick() {
        guard var current = limit else { stop(); return }
        let verdict = current.poll(now: now())
        limit = current
        switch verdict {
        case .waiting:
            break
        case .inactive:
            stop()
        case let .reached(elapsed):
            stop()
            print("[Startup] limit reached: no first frame after \(Int(elapsed)) s")
            let callback = onReached
            onReached = nil
            callback?()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
