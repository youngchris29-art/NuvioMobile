import Combine
import Foundation

/// Every time value the engine publishes, in one snapshot.
public struct AetherClockSample: Sendable, Equatable {
    /// `clock.currentTime`: the scrubber and seek axis.
    public var currentSec: Double
    /// `clock.sourceTime`: the subtitle overlay axis (raw source PTS).
    public var sourceSec: Double
    /// `clock.sourceTimeFollowsPicture` (always true off the remote bypass).
    public var sourceFollowsPicture: Bool
    /// `clock.bufferedPosition`.
    public var bufferedSec: Double
    /// `engine.duration` (not on the engine's clock; copied here so time UI observes one object).
    public var durationSec: Double
    /// `engine.residentRanges` (<= 4 Hz), for `TransportBarModel.bufferedRanges`.
    public var residentRanges: [ClosedRange<Double>]
    /// `engine.isClockHeld`: the watchdog must not count a held clock as a stall.
    public var isClockHeld: Bool

    public init(currentSec: Double = 0, sourceSec: Double = 0, sourceFollowsPicture: Bool = true,
                bufferedSec: Double = 0, durationSec: Double = 0, residentRanges: [ClosedRange<Double>] = [],
                isClockHeld: Bool = false) {
        self.currentSec = currentSec
        self.sourceSec = sourceSec
        self.sourceFollowsPicture = sourceFollowsPicture
        self.bufferedSec = bufferedSec
        self.durationSec = durationSec
        self.residentRanges = residentRanges
        self.isClockHeld = isClockHeld
    }
}

/// Time-driven UI observes this, never the session: tvOS Menus rebuild on every `objectWillChange` of
/// what they observe, and the clock ticks at ~10 Hz (the engine keeps its own clock apart for the same
/// reason).
@MainActor
public final class AetherClock: ObservableObject {
    @Published public private(set) var currentSec: Double = 0
    @Published public private(set) var sourceSec: Double = 0
    @Published public private(set) var sourceFollowsPicture = true
    @Published public private(set) var bufferedSec: Double = 0
    @Published public private(set) var durationSec: Double = 0
    @Published public private(set) var residentRanges: [ClosedRange<Double>] = []
    @Published public private(set) var isClockHeld = false

    public init() {}

    /// The current values as one sample.
    public var sample: AetherClockSample {
        AetherClockSample(currentSec: currentSec, sourceSec: sourceSec, sourceFollowsPicture: sourceFollowsPicture,
                          bufferedSec: bufferedSec, durationSec: durationSec, residentRanges: residentRanges,
                          isClockHeld: isClockHeld)
    }

    /// Mirrors a sample, assigning only the fields that changed so an unchanged tick publishes nothing.
    public func apply(_ s: AetherClockSample) {
        if currentSec != s.currentSec { currentSec = s.currentSec }
        if sourceSec != s.sourceSec { sourceSec = s.sourceSec }
        if sourceFollowsPicture != s.sourceFollowsPicture { sourceFollowsPicture = s.sourceFollowsPicture }
        if bufferedSec != s.bufferedSec { bufferedSec = s.bufferedSec }
        if durationSec != s.durationSec { durationSec = s.durationSec }
        if residentRanges != s.residentRanges { residentRanges = s.residentRanges }
        if isClockHeld != s.isClockHeld { isClockHeld = s.isClockHeld }
    }

    /// Back to zero for a new source (not for Replay or a rebuild of the same one, which keep their axis).
    public func reset() { apply(AetherClockSample()) }
}
