import Foundation

/// A buffered / seekable span of the media, in seconds.
struct BufferedRange: Equatable {
    let start: Double
    let end: Double

    /// Sorts, clamps to `[0, durationSec]` (when known), drops empty spans and joins neighbours whose
    /// gap is under `gapSec` (overlaps join too).
    static func merge(_ ranges: [BufferedRange], gapSec: Double, durationSec: Double) -> [BufferedRange] {
        var clamped: [BufferedRange] = []
        for r in ranges {
            guard r.start.isFinite, r.end.isFinite else { continue }
            var s = max(0, r.start)
            var e = r.end
            if durationSec > 0 {
                s = min(s, durationSec)
                e = min(e, durationSec)
            }
            if e > s { clamped.append(BufferedRange(start: s, end: e)) }
        }
        clamped.sort { $0.start < $1.start }
        var out: [BufferedRange] = []
        for r in clamped {
            if let last = out.last, r.start - last.end < gapSec {
                out[out.count - 1] = BufferedRange(start: last.start, end: max(last.end, r.end))
            } else {
                out.append(r)
            }
        }
        return out
    }
}

/// The preview-then-commit model for held Left/Right in the mpv player. Pure value type: no UIKit,
/// no mpv, no clock of its own. The controller owns the timers and passes the hold time in.
struct TransportPreview {
    enum HoldMode: String { case step, scan }
    enum Mode: Equatable {
        case idle
        case stepping(direction: Int, accumulatedSec: Double, ticks: Int)
        case scanning(rate: Int)
        case scrubbing(targetSec: Double)               // P2 swipe scrub (`scrubBegan` … `scrubCommit`)

        var isActive: Bool { if case .idle = self { return false }; return true }
        var probeName: String {
            switch self {
            case .idle: return "idle"
            case .stepping: return "stepping"
            case .scanning: return "scanning"
            case .scrubbing: return "scrubbing"
            }
        }
    }
    enum Stage: Equatable { case keyframes, exact }
    struct CommitRequest: Equatable {
        let targetSec: Double
        let fromSec: Double
        let stages: [Stage]
    }
    enum Output: Equatable {
        case none
        case immediateSeek(deltaSec: Double)
        case startScan(rate: Int)
        case setScanRate(Int)
        case endScan(fromSec: Double, returnToSec: Double?)
        case commit(CommitRequest)
        /// A scrub moved the preview more than 1 s behind its origin: cancel next-episode autoplay
        /// (once per scrub, like a backward hold).
        case cancelUpNext
    }

    var holdMode: HoldMode = .step
    var rampScale: Double = 1
    var durationSec: Double = 0
    var seekableRanges: [BufferedRange] = []
    /// Set by the controller before a press: a hold that starts while paused steps (a scan would
    /// latch a rate on a core that does not move).
    var paused = false
    /// Set by the controller before a press (critique C8, chapter mode): a click acts on RELEASE
    /// (`.immediateSeek(±10)` from `pressEnded`, which the controller routes to a chapter jump), so
    /// a hold steps from the origin with no jump first. Latched per gesture when it starts.
    var clickOnRelease = false
    /// Swipe scrub rate (`debug.scrubCurve`, `debug.scrubRateScale`).
    var scrubCurve: ScrubRateCurve = .orivio
    var scrubRateScale: Double = 1
    private(set) var mode: Mode = .idle
    private(set) var originSec: Double = 0
    private(set) var previewSec: Double? = nil
    /// The preview moved beyond the press's own 10 s (a tick or a second press).
    private var moved = false
    /// This gesture may turn into a scan: Scan mode, Right, not paused (fixed when it starts).
    private var scanArmed = false
    /// `clickOnRelease` as it was when this gesture started.
    private var releaseClick = false
    /// The scrub preview moved at least once (a scrub with no movement commits nothing).
    private var scrubMovedAny = false
    /// `.cancelUpNext` was already returned for this scrub.
    private var scrubBackwardNoted = false

    static let firstStepSec: Double = 10
    static let holdStartSec: TimeInterval = 0.4
    static let defaultTickSec: TimeInterval = 0.25
    /// While playing, a scrub with no input for this long is cancelled (no seek).
    static let scrubIdleCancelSec: TimeInterval = 8
    static func stepSec(heldSec: Double, rampScale: Double = 1) -> Double {
        heldSec < 0.6 * rampScale ? 10 : heldSec < 1.2 * rampScale ? 20 : heldSec < 2.0 * rampScale ? 30 : 60
    }

    private func clamp(_ x: Double) -> Double {
        max(0, durationSec > 0 ? min(x, durationSec - 0.5) : x)
    }

    mutating func pressBegan(direction: Int, positionSec: Double) -> Output {
        let dir = direction >= 0 ? 1 : -1
        switch mode {
        case .idle:
            originSec = positionSec
            moved = false
            scanArmed = holdMode == .scan && dir > 0 && !paused
            releaseClick = clickOnRelease
            let acc = clamp(originSec + Double(dir) * Self.firstStepSec) - originSec
            mode = .stepping(direction: dir, accumulatedSec: acc, ticks: 0)
            previewSec = originSec + acc
            if scanArmed || releaseClick { return .none }
            return .immediateSeek(deltaSec: Double(dir) * Self.firstStepSec)
        case .stepping(_, let acc, _):
            let next = clamp(originSec + acc + Double(dir) * Self.firstStepSec) - originSec
            mode = .stepping(direction: dir, accumulatedSec: next, ticks: 0)
            previewSec = originSec + next
            moved = true
            return .none
        case .scanning(let rate):
            if dir > 0 {
                let next = rate >= 4 ? 2 : rate + 1
                mode = .scanning(rate: next)
                return .setScanRate(next)
            }
            return endScanInPlace()
        case .scrubbing:
            return .none
        }
    }

    mutating func holdTick(heldSec: Double) -> Output {
        guard case .stepping(let d, let acc, let n) = mode else { return .none }
        let ticks = n + 1
        if scanArmed && d > 0 && ticks == 1 && !moved {
            mode = .scanning(rate: 2)
            previewSec = originSec
            return .startScan(rate: 2)
        }
        let next = clamp(originSec + acc + Double(d) * Self.stepSec(heldSec: heldSec, rampScale: rampScale)) - originSec
        mode = .stepping(direction: d, accumulatedSec: next, ticks: ticks)
        moved = true
        previewSec = originSec + next
        return .none
    }

    mutating func pressEnded(direction: Int) -> Output {
        guard case .stepping(let d, let acc, let n) = mode else { return .none }
        let dir = direction >= 0 ? 1 : -1
        guard dir == d else { return .none }
        if n == 0 && !moved {
            mode = .idle
            previewSec = nil
            if releaseClick { return .immediateSeek(deltaSec: Double(d) * Self.firstStepSec) }
            if scanArmed && d > 0 { return .immediateSeek(deltaSec: Self.firstStepSec) }
            return .none
        }
        let target = clamp(originSec + acc)
        mode = .idle
        previewSec = target
        return .commit(commitRequest(target: target))
    }

    /// Two stages unless the target is already cached (then exact only).
    private func commitRequest(target: Double) -> CommitRequest {
        let covered = seekableRanges.contains { $0.start <= target && target <= $0.end }
        return CommitRequest(targetSec: target, fromSec: originSec,
                             stages: covered ? [.exact] : [.keyframes, .exact])
    }

    // MARK: Swipe scrub (P2)

    /// From idle only: the controller ends a scan or a step first.
    mutating func scrubBegan(positionSec: Double) -> Output {
        guard case .idle = mode else { return .none }
        originSec = positionSec
        let t = clamp(positionSec)
        mode = .scrubbing(targetSec: t)
        previewSec = t
        scrubMovedAny = false
        scrubBackwardNoted = false
        return .none
    }

    /// One pan sample's dx increment, through the rate curve and the scale.
    mutating func scrubMoved(deltaPoints: Double) -> Output {
        scrubShift(by: scrubCurve.deltaSec(points: deltaPoints, durationSec: durationSec) * scrubRateScale)
    }

    /// A Left / Right click while scrubbing: ±10 s on the preview.
    mutating func scrubNudge(direction: Int) -> Output {
        scrubShift(by: Double(direction >= 0 ? 1 : -1) * Self.firstStepSec)
    }

    private mutating func scrubShift(by d: Double) -> Output {
        guard case .scrubbing(let t) = mode else { return .none }
        let next = clamp(t + d)
        mode = .scrubbing(targetSec: next)
        previewSec = next
        if next != t { scrubMovedAny = true }
        if !scrubBackwardNoted && next < originSec - 1 {
            scrubBackwardNoted = true
            return .cancelUpNext
        }
        return .none
    }

    /// Select / Play: one deliberate seek to the target (same two-stage commit as a hold). A scrub
    /// that never moved seeks nowhere.
    mutating func scrubCommit() -> Output {
        guard case .scrubbing(let t) = mode else { return .none }
        mode = .idle
        guard scrubMovedAny else {
            previewSec = nil
            return .none
        }
        previewSec = t          // held until the commit lands, as the hold does
        return .commit(commitRequest(target: t))
    }

    /// Menu / Up / Down / idle timeout / panel: nothing committed.
    mutating func scrubCancel() -> Output {
        guard case .scrubbing = mode else { return .none }
        mode = .idle
        previewSec = nil
        return .none
    }

    mutating func endScanInPlace() -> Output {
        guard case .scanning = mode else { return .none }
        mode = .idle
        previewSec = nil
        return .endScan(fromSec: originSec, returnToSec: nil)
    }

    mutating func noteLivePosition(_ sec: Double) {
        guard case .scanning = mode else { return }
        previewSec = sec
    }

    mutating func noteCommitLanded() {
        if case .idle = mode { previewSec = nil }
    }

    mutating func cancel() -> Output {
        switch mode {
        case .stepping:
            mode = .idle
            previewSec = nil
            return .none
        case .scanning:
            mode = .idle
            previewSec = nil
            return .endScan(fromSec: originSec, returnToSec: originSec)
        case .scrubbing:
            return scrubCancel()
        case .idle:
            return .none
        }
    }

    /// `demuxer-cache-state` read as a string (mpv prints node properties as JSON):
    /// `{"seekable-ranges":[{"start":..,"end":..}], ...}`. Anything malformed is `[]`.
    static func parseSeekableRanges(_ json: String) -> [BufferedRange] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["seekable-ranges"] as? [[String: Any]] else { return [] }
        var out: [BufferedRange] = []
        for item in arr {
            guard let s = (item["start"] as? NSNumber)?.doubleValue,
                  let e = (item["end"] as? NSNumber)?.doubleValue else { continue }
            out.append(BufferedRange(start: s, end: e))
        }
        return out
    }
}
