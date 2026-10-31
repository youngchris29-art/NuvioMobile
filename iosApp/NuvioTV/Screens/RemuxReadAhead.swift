import Foundation

// BUG-224: the read-ahead bound of the native player's remux. Before it, `RemuxSession` remuxed the
// whole source front to back as fast as the download and gnutls/nettle's software TLS decrypt
// allowed (the hybrid-player plan's "sequential read-ahead of 2–3 segments" was never built), and
// only parked at EOF: a 90 % CPU burst over the first ~100–160 s of every MKV, which tvOS files as
// a `cpu_resource` report. The worker now parks once it is `boundSec` of media ahead of the segment
// AVPlayer requested most recently, and wakes on the next request, a reposition, an audio switch or
// stop(). The burst becomes ~90 s of media up front, then production at playback speed.
//
// "Most recent", not "highest ever": after a seek back into produced segments the player is far
// behind the frontier, and the worker should wait for it there rather than keep the old lead.

/// Pacing gate shared by the remux worker (waits) and the loopback HLS server (notes requests).
/// Its lock is a leaf: callers never hold the session's `lock`/`control` while calling in, and the
/// worker's `interrupted` check (which takes them) is the only nesting, always gate → session.
nonisolated final class RemuxReadAhead: @unchecked Sendable {
    /// How far ahead of AVPlayer's latest segment request production may run, in seconds of media.
    /// 90 s: AVPlayer's own forward buffer is capped at 24 s (`NativePlaybackCoordinator.decorate`)
    /// and the JIT poll window is 6 segments (~24 s), so the lead sits well clear of both; it rides
    /// out a ~90 s source stall without AVPlayer noticing; a forward seek of up to ~90 s lands on
    /// produced segments (no reposition); and in steady playback the source read pauses for about
    /// one segment (~4 s) between resumes, short enough that a CDN keeps the connection.
    static let defaultBoundSec: Double = 90

    /// Device A/B knob, launch-latched and Release-readable (the rig walks Release):
    /// `-debug.remuxReadAheadSeconds <n>`. 0 = unbounded (the pre-BUG-224 behaviour); a positive
    /// value is the bound, floored at `minimumBoundSec`; unset, negative or non-numeric = default.
    static let boundKey = "debug.remuxReadAheadSeconds"
    /// Below AVPlayer's 24 s forward buffer its requests would outrun production on every segment.
    static let minimumBoundSec: Double = 24
    static let launchBoundSec: Double = resolveBound(from: .standard)

    /// The knob's parse, pure over its `UserDefaults` so the test can drive a scratch suite. A
    /// launch argument arrives as a string (`UserDefaults.double(forKey:)` converts it).
    static func resolveBound(from defaults: UserDefaults) -> Double {
        guard let raw = defaults.object(forKey: boundKey) else { return defaultBoundSec }
        if let text = raw as? String, Double(text.trimmingCharacters(in: .whitespaces)) == nil {
            return defaultBoundSec
        }
        let seconds = defaults.double(forKey: boundKey)
        guard seconds.isFinite, seconds >= 0 else { return defaultBoundSec }
        return seconds == 0 ? 0 : max(seconds, minimumBoundSec)
    }

    /// The pacing decision: park when the produced frontier is `boundSec` or more past the latest
    /// request. A bound of 0 (or anything non-finite) never parks.
    static func shouldPark(producedSec: Double, requestedSec: Double, boundSec: Double) -> Bool {
        guard boundSec > 0, boundSec.isFinite, producedSec.isFinite, requestedSec.isFinite else { return false }
        return producedSec - requestedSec >= boundSec
    }

    let boundSec: Double
    /// Start of each segment on the playlist timeline; index 0 = segment 1.
    private let startsSec: [Double]
    private let cond = NSCondition()
    /// The segment AVPlayer asked for most recently. Segment 1 until the first request, so the
    /// first run parks `boundSec` in rather than racing on while the player is still setting up.
    private var _latestRequested = 1

    /// nil = unbounded: a bound of 0, or a map without a usable duration (live / unknown length
    /// input; the remux cannot build a map for those today, so this is a guard, not a path).
    init?(segmentDurationsSec: [Double], totalDurationSec: Double, boundSec: Double) {
        guard boundSec > 0, totalDurationSec > 0, !segmentDurationsSec.isEmpty else { return nil }
        var starts: [Double] = []
        starts.reserveCapacity(segmentDurationsSec.count)
        var t = 0.0
        for d in segmentDurationsSec { starts.append(t); t += d }
        self.startsSec = starts
        self.boundSec = boundSec
    }

    convenience init?(map: SegmentMap, boundSec: Double = RemuxReadAhead.launchBoundSec) {
        self.init(segmentDurationsSec: map.segments.map(\.durationSec),
                  totalDurationSec: map.totalDurationSec, boundSec: boundSec)
    }

    var latestRequested: Int { cond.lock(); defer { cond.unlock() }; return _latestRequested }

    /// A media request for `segment` reached the server (served from disk or not). Latest wins.
    func noteRequest(segment: Int) {
        guard segment >= 1, segment <= startsSec.count else { return }
        cond.lock()
        _latestRequested = segment
        cond.signal()
        cond.unlock()
    }

    /// Something other than a request needs the worker (reposition, audio switch, stop): wake it so
    /// it re-evaluates `interrupted`. Call with no session lock held.
    func kick() {
        cond.lock(); cond.signal(); cond.unlock()
    }

    /// Whether `producing` (the segment being written; everything before it is on disk) is far
    /// enough ahead of the latest request to park.
    func isAhead(producing: Int) -> Bool {
        cond.lock(); defer { cond.unlock() }
        return isAheadLocked(producing: producing)
    }

    private func isAheadLocked(producing: Int) -> Bool {
        guard producing >= 1, producing <= startsSec.count else { return false }
        return Self.shouldPark(producedSec: startsSec[producing - 1],
                               requestedSec: startsSec[_latestRequested - 1], boundSec: boundSec)
    }

    /// Block while `producing` is ahead by the bound. Returns as soon as a request lowers the lead
    /// or `interrupted()` holds (a pending reposition / audio switch, or cancellation — the
    /// session's own mailbox, checked under this lock so a `kick()` can't slip between check and
    /// wait). The timed wait is lost-wakeup insurance, like `parkForRequest`. Returns the seconds
    /// spent parked (0 = it never waited).
    @discardableResult
    func waitWhileAhead(producing: Int, interrupted: () -> Bool) -> TimeInterval {
        cond.lock(); defer { cond.unlock() }
        guard isAheadLocked(producing: producing), !interrupted() else { return 0 }
        let start = Date()
        while isAheadLocked(producing: producing), !interrupted() {
            cond.wait(until: Date().addingTimeInterval(0.25))
        }
        return max(Date().timeIntervalSince(start), .leastNonzeroMagnitude)
    }
}
