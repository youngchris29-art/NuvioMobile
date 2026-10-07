import Foundation

/// When the mpv player saves a seek-preview frame (P2). Pure: the controller feeds it one tick per
/// `refreshState` and starts a harvest when `tick` returns true.
///
/// Counts playback time, not wall clock: paused, buffering, a moving transport (step, scan,
/// scrub), a seek in flight, a harvest in flight, or a press in the last 1.5 s make a tick
/// ineligible, and ineligible time does not count toward the interval. A landed seek schedules
/// one extra harvest 1 s later (a newer landing replaces it); a due seek harvest that meets an
/// ineligible tick waits for the next eligible one. A harvest that took over 60 ms triples the
/// interval for the rest of the file (critique C18) and ends seek harvests for it.
nonisolated struct HarvestScheduler {
    static let slowHarvestMs: Double = 60
    static let recentInputSec: TimeInterval = 1.5
    static let seekDebounceSec: TimeInterval = 1.0

    /// 10 (Auto), 5, 30; <= 0 = off.
    private(set) var intervalSec: Double
    private(set) var playedSinceLast: Double = 0
    private(set) var seekHarvestDue: TimeInterval? = nil
    private(set) var inFlight = false
    /// Set once a slow harvest tripled the interval (the backoff applies once per file).
    private(set) var backedOff = false
    private var lastTick: TimeInterval? = nil

    init(intervalSec: Double) { self.intervalSec = intervalSec }

    /// `debug.harvestIntervalSec`: 0 (unset) = Auto 10 s, -1 = Off, else that many seconds.
    static func interval(fromSetting value: Int) -> Double {
        if value == 0 { return 10 }
        if value < 0 { return 0 }
        return Double(value)
    }

    /// Called from every `refreshState` tick. Returns true when a harvest should start now.
    mutating func tick(now: TimeInterval, playing: Bool, transportIdle: Bool, seekInFlight: Bool,
                       recentInput: Bool) -> Bool {
        let dt = lastTick.map { min(max(now - $0, 0), 1.0) } ?? 0
        lastTick = now
        guard intervalSec > 0 else { return false }
        let eligible = playing && transportIdle && !seekInFlight && !inFlight && !recentInput
        guard eligible else { return false }
        playedSinceLast += dt
        if playedSinceLast >= intervalSec { return true }
        if let due = seekHarvestDue, now >= due { return true }
        return false
    }

    /// A seek landed: one harvest 1 s later (debounced: a newer landing replaces it). Not once
    /// the file has backed off: a slow readback right after a seek lands just when the picture is
    /// being watched (review r1 P3 #8); the tripled interval still harvests.
    mutating func noteSeekLanded(now: TimeInterval) {
        guard !backedOff else { return }
        seekHarvestDue = now + Self.seekDebounceSec
    }

    mutating func noteStarted() {
        inFlight = true
        playedSinceLast = 0
        seekHarvestDue = nil
    }

    /// The harvest finished. Returns true when this call tripled the interval (log it once).
    @discardableResult
    mutating func noteFinished(tookMs: Double? = nil) -> Bool {
        inFlight = false
        guard let tookMs, tookMs > Self.slowHarvestMs, !backedOff, intervalSec > 0 else { return false }
        backedOff = true
        intervalSec *= 3
        return true
    }
}
