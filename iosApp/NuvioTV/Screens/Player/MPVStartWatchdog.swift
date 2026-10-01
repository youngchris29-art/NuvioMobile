import Foundation

/// "No media ever arrived" watchdog for the libmpv path. libmpv answers a dead host, a stalled
/// handshake or a debrid link that never produces bytes with silence — no `MPV_EVENT_FILE_LOADED`
/// and no `MPV_EVENT_END_FILE` either — so without a clock the player would spin its buffering
/// wheel forever and the failover (try the next source) would never get its signal.
///
/// Pure value type, no timers and no mpv: the view controller arms it when `loadfile` is issued,
/// calls `poll(now:)` from a 1 s main-queue timer, and reports `onPlaybackFailed` on `.fired`.
/// Every timestamp is passed in (`ProcessInfo.systemUptime` in the app), so the tests drive time
/// by hand.
struct MPVStartWatchdog: Equatable {
    /// The normal budget, from `loadfile` to `MPV_EVENT_FILE_LOADED`.
    static let defaultLimitSeconds: Double = 25
    /// The shortened budget used when the native engine already failed before start (the viewer
    /// has waited through one engine's attempt; the second engine gets less time).
    static let shortenedLimitSeconds: Double = 15

    /// The limit for the host's `startWatchdogShortened` flag.
    static func limitSeconds(shortened: Bool) -> Double {
        shortened ? shortenedLimitSeconds : defaultLimitSeconds
    }

    enum Verdict: Equatable {
        /// Armed and still inside the budget.
        case waiting
        /// The budget ran out with no file loaded; `elapsed` is the seconds since the load began.
        case fired(elapsed: TimeInterval)
        /// Not armed, already satisfied (file loaded), cancelled, or already fired and consumed.
        case inactive
    }

    private enum Phase: Equatable {
        case idle                         // `noteLoadStarted` not called yet
        case armed(since: TimeInterval)
        case finished                     // loaded, cancelled or fired — never fires again
    }

    let limitSeconds: Double
    private var phase: Phase = .idle

    init(limitSeconds: Double) {
        self.limitSeconds = limitSeconds
    }

    /// `loadfile` was issued at `at`. Arms the clock; ignored once the watchdog has finished.
    mutating func noteLoadStarted(at: TimeInterval) {
        guard phase == .idle else { return }
        phase = .armed(since: at)
    }

    /// `MPV_EVENT_FILE_LOADED` arrived — media is flowing, the watchdog stands down for good.
    mutating func noteFileLoaded() {
        phase = .finished
    }

    /// The player is going away (user exit, context swap, teardown) — never fire after this.
    mutating func noteCancelled() {
        phase = .finished
    }

    /// What the watchdog says at `now`. Pure: asking twice gives the same answer, so a caller that
    /// only peeks sees `.fired` until it stands the watchdog down. Use `poll(now:)` to also latch.
    func verdict(now: TimeInterval) -> Verdict {
        switch phase {
        case .idle, .finished:
            return .inactive
        case .armed(let since):
            let elapsed = now - since
            return elapsed >= limitSeconds ? .fired(elapsed: elapsed) : .waiting
        }
    }

    /// `verdict(now:)` plus the fire-once latch: the first `.fired` is returned exactly once, and
    /// every later call answers `.inactive`.
    mutating func poll(now: TimeInterval) -> Verdict {
        let result = verdict(now: now)
        if case .fired = result { phase = .finished }
        return result
    }
}
