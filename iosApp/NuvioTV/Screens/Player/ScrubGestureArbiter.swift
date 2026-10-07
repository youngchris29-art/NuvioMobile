import Foundation

// Swipe scrub on the mpv player (P2-A1). Pure Swift, no UIKit: the controller feeds the pan
// recogniser's cumulative translation in and performs the events that come out.

/// The rate curve for a horizontal scrub (D3). `deltaSec` takes one sample's increment in points.
enum ScrubRateCurve: String {
    /// Steady rate scaled by the file's length (Orivio): 0.25 s/pt at 10 min, 1.5 s/pt on a 2 h film.
    case orivio
    /// Speed-sensitive (bobsupra/NuvioTVOS `PlayerViewModel.swift:3025-3046`): a fast flick travels
    /// further per point than a slow drag.
    case bobsupra

    var probeCode: String { self == .orivio ? "o" : "b" }

    /// Reads `debug.scrubCurve`: "bobsupra" → `.bobsupra`, anything else `.orivio`.
    static func fromSetting(_ raw: String?) -> ScrubRateCurve { raw == "bobsupra" ? .bobsupra : .orivio }

    func deltaSec(points inc: Double, durationSec: Double) -> Double {
        switch self {
        case .orivio:
            return inc * max(durationSec / 4800, 0.25)
        case .bobsupra:
            let a = abs(inc)
            guard a > 0.0001 else { return 0 }
            let df = durationSec > 0 ? min(max((durationSec / 3600).squareRoot(), 0.8), 1.8) : 1
            let m: Double
            if a <= 3 {
                m = 0.7 + 0.3 * (a / 3)
            } else if a <= 8 {
                m = 1 + 1.5 * ((a - 3) / 5) * df
            } else {
                m = (2.5 + 3.5 * min((a - 8) / 12, 1)) * df
            }
            return (inc < 0 ? -1 : 1) * a * 0.06 * m
        }
    }
}

/// What the controller knows at each sample; built fresh by `MPVTVPlayerViewController.scrubContext()`.
struct ScrubContext: Equatable {
    var barVisible: Bool
    var paused: Bool
    var pillFocused: Bool
    var scrubbing: Bool                 // TransportPreview.mode is .scrubbing
    var canScrub: Bool                  // file loaded, duration > 0, no panel presented, not ended
    var pressesDown: Int                // the controller's `pressesDown.count`
    var lastPressUptime: TimeInterval   // the controller's `lastClickUptime`
}

/// Decides what one touch-surface stroke is: a horizontal scrub, a vertical swipe, a light tap, or
/// nothing (a diagonal stays undecided and nobody consumes it).
struct ScrubGestureArbiter {
    enum Intent: Equatable { case undecided, horizontal, vertical(down: Bool), ignored }
    enum Event: Equatable {
        case none
        case beginScrub                 // the stroke just became horizontal
        case scrubDelta(points: Double) // one sample's dx increment, stroke already horizontal
        case openPanel                  // vertical, downward
        case swipeUp                    // vertical, upward
        case lightTap                   // ended undecided with < tapMaxTravelPt of travel
    }

    static let horizontalIntentPt: Double = 45
    static let hiddenPlayingIntentPt: Double = 160
    static let pillIntentPt: Double = 190
    static let verticalIntentPt: Double = 110
    static let axisRatio: Double = 1.5
    static let tapMaxTravelPt: Double = 20
    static let moveSuppressSec: TimeInterval = 0.4

    private(set) var intent: Intent = .undecided
    private var originX: Double = 0
    private var originY: Double = 0
    private(set) var travel: Double = 0
    private var lastTx: Double = 0

    /// "u" undecided, "h" horizontal, "v" vertical, "i" ignored.
    var probeCode: String {
        switch intent {
        case .undecided: return "u"
        case .horizontal: return "h"
        case .vertical: return "v"
        case .ignored: return "i"
        }
    }

    mutating func touchBegan() {
        intent = .undecided
        originX = 0; originY = 0
        travel = 0
        lastTx = 0
    }

    mutating func moved(tx: Double, ty: Double, now: TimeInterval, context: ScrubContext) -> Event {
        // A click rolls the finger: nothing measured during or 0.4 s after a press counts, and the
        // measurement restarts from where the finger is.
        if context.pressesDown > 0 || now - context.lastPressUptime < Self.moveSuppressSec {
            originX = tx; originY = ty
            lastTx = tx
            return .none
        }
        let dx = tx - originX, dy = ty - originY
        travel = max(travel, (dx * dx + dy * dy).squareRoot())
        switch intent {
        case .horizontal:
            let inc = tx - lastTx
            lastTx = tx
            return inc == 0 ? .none : .scrubDelta(points: inc)
        case .vertical, .ignored:
            return .none
        case .undecided:
            break
        }
        if abs(dy) >= Self.verticalIntentPt && abs(dy) >= Self.axisRatio * abs(dx) {
            intent = .vertical(down: dy > 0)
            return dy > 0 ? .openPanel : .swipeUp
        }
        if abs(dx) >= Self.horizontalThreshold(context) && abs(dx) >= Self.axisRatio * abs(dy) {
            guard context.canScrub else {
                intent = .ignored
                return .none
            }
            intent = .horizontal
            lastTx = tx            // the travel up to the decision is NOT applied: no jump
            return .beginScrub
        }
        return .none
    }

    mutating func touchEnded(context: ScrubContext) -> Event {
        // The arbiter keeps `intent` (the probe shows the last stroke's verdict) until the next
        // `touchBegan`.
        if intent == .undecided && travel < Self.tapMaxTravelPt { return .lightTap }
        return .none
    }

    /// The scrub ended mid-stroke (Select, Menu, a press): the rest of this stroke does nothing.
    mutating func abandon() {
        if intent == .horizontal { intent = .ignored }
    }

    /// 190 pt with a pill focused, 45 pt while already scrubbing, 160 pt playing with the bar hidden
    /// (the brush guard), 45 pt otherwise. A pause never blocks a scrub (D1).
    static func horizontalThreshold(_ c: ScrubContext) -> Double {
        if c.pillFocused { return pillIntentPt }
        if c.scrubbing { return horizontalIntentPt }
        if !c.barVisible && !c.paused { return hiddenPlayingIntentPt }
        return horizontalIntentPt
    }
}

/// The preview-frame lookup rate (critique C17): a throttle, not a debounce. At most one lookup in
/// flight; a new one starts when ≥ `minIntervalSec` passed since the last start; a sample that
/// arrives while one is in flight or too soon is remembered and always gets a trailing lookup.
struct PreviewFrameThrottle {
    enum Decision: Equatable {
        case none
        case start                       // run a lookup for the current target now
        case wait(TimeInterval)          // arm a timer for this long, then call `timerFired`
    }

    static let minIntervalSec: TimeInterval = 0.066

    private(set) var inFlight = false
    private(set) var trailingPending = false
    private var lastStart: TimeInterval = -.greatestFiniteMagnitude

    /// A new target arrived.
    mutating func sample(now: TimeInterval) -> Decision {
        trailingPending = true
        return next(now: now)
    }

    /// The running lookup finished.
    mutating func finished(now: TimeInterval) -> Decision {
        inFlight = false
        return next(now: now)
    }

    /// The `.wait` timer fired.
    mutating func timerFired(now: TimeInterval) -> Decision { next(now: now) }

    /// The scrub ended: forget everything (a lookup still running is dropped by the token guard).
    mutating func reset() {
        inFlight = false
        trailingPending = false
        lastStart = -.greatestFiniteMagnitude
    }

    private mutating func next(now: TimeInterval) -> Decision {
        guard trailingPending, !inFlight else { return .none }
        let since = now - lastStart
        if since >= Self.minIntervalSec {
            inFlight = true
            trailingPending = false
            lastStart = now
            return .start
        }
        return .wait(Self.minIntervalSec - since)
    }
}

/// DEBUG scrub injection (`-debug.scrubInject`): the simulator cannot swipe. Samples separated by
/// `;`, each `dx,dt` or `dx,dt,dy` (per-sample increments in points; `dt` seconds before the
/// sample, clamped to [0, 1]; missing `dy` = 0). Malformed samples are skipped.
enum ScrubInjectScript {
    struct Sample: Equatable { let dx: Double; let dy: Double; let dt: Double }

    static func parse(_ s: String) -> [Sample] {
        var out: [Sample] = []
        for raw in s.split(separator: ";") {
            let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 || parts.count == 3,
                  let dx = Double(parts[0]), let dt = Double(parts[1]), dx.isFinite, dt.isFinite else { continue }
            var dy = 0.0
            if parts.count == 3 {
                guard let v = Double(parts[2]), v.isFinite else { continue }
                dy = v
            }
            out.append(Sample(dx: dx, dy: dy, dt: min(max(dt, 0), 1)))
        }
        return out
    }
}
