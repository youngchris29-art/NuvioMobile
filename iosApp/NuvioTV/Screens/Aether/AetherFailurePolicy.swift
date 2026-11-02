import AVFoundation
import Foundation
import NuvioAether

// Aether Phase 1, W3-C: the failure ladder (W1-A section 7, plan section 4) as the controller's
// `AetherFailureDeciding`. The façade reports, the controller acts, this decides.
//
// | Failure | Verdict |
// | --- | --- |
// | `sourceRateLimited` | `.fail` (no handoff: mpv meets the same meter; `.network`, not remembered) |
// | `nativeItemFailed` / `softwarePipelineFailed`, a first frame was shown, within 10 s of an audio-session interruption or route change | `.rebuildOnce` (a fresh `load` at the last position; the controller allows it once, then mpv) |
// | everything else (every other kind, the same two kinds outside the window or before a first frame, `firstFrameTimeout`, unknown future tokens, the live / HLS / custom-reader kinds that Phase 1 routes to mpv) | `.fallbackToMpv` (`.local`, never remembered against the link) |
//
// Not decided here: `audioDelivery == .droppedNoPipeline` and an engine that could not be created
// bypass the decider and always hand off (controller-raised); the engine's own software rebuild when
// AVPlayer refuses the media is internal to Aether and never reaches the host as a failure.

/// The interruption-aware decider. The pure part is `decide(kind:startedPlaying:secondsPlayed:sinceInterruptionSec:)`;
/// the instance observes `AVAudioSession.interruptionNotification` and `routeChangeNotification`,
/// stamps the last one (main queue, injected clock) and feeds the window to the pure rule.
final class AetherFailurePolicy: AetherFailureDeciding {
    /// "Within 10 s of an interruption or route change" (the spike's DV `-11868` teardown).
    static let interruptionWindowSec: Double = 10

    /// The kinds an HDMI / audio-route interruption tears a DV session down with.
    static let interruptionKinds: Set<AetherFailureKind> = [.nativeItemFailed, .softwarePipelineFailed]

    /// The pure ladder. `sinceInterruptionSec` is the age of the last interruption or route change
    /// (nil when there was none). `secondsPlayed` is carried for symmetry with the protocol; no ladder
    /// row reads it (the controller logs it).
    nonisolated static func decide(kind: AetherFailureKind, startedPlaying: Bool, secondsPlayed: Double,
                                   sinceInterruptionSec: Double?) -> AetherFailureDecision {
        if kind == .sourceRateLimited { return .fail }
        if startedPlaying, interruptionKinds.contains(kind), isWithinWindow(sinceInterruptionSec) {
            return .rebuildOnce
        }
        return .fallbackToMpv
    }

    /// 0 ... 10 s inclusive. A negative age (a clock that went backwards) is not inside the window.
    nonisolated static func isWithinWindow(_ sinceSec: Double?) -> Bool {
        guard let sinceSec, sinceSec.isFinite else { return false }
        return sinceSec >= 0 && sinceSec <= interruptionWindowSec
    }

    /// A route-change reason that is a real route event. `categoryChange` fires for the app's own
    /// `setCategory` / `setActive` calls (mpv re-asserts the category at every start), which would open
    /// the window at the start of every playback, so it does not count.
    nonisolated static func countsAsRouteChange(reasonRaw: UInt?) -> Bool {
        guard let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return true }
        return reason != .categoryChange
    }

    private let clock: () -> TimeInterval
    private var lastEventAt: TimeInterval?
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// `clock` is a monotonic seconds source (`ProcessInfo.systemUptime` by default). `center` is the
    /// notification center the session posts to; both are injectable for tests.
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         center: NotificationCenter = .default) {
        self.clock = clock
        self.center = center
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated { self?.noteEvent("interruption \(type == .ended ? "ended" : "began")") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard Self.countsAsRouteChange(reasonRaw: raw) else { return }
            MainActor.assumeIsolated { self?.noteEvent("route change reason=\(raw.map(String.init) ?? "-")") }
        })
    }

    deinit {
        observers.forEach { center.removeObserver($0) }
    }

    /// Stamp an interruption or route change now (main). Also the test hook.
    func noteEvent(_ what: String = "event") {
        lastEventAt = clock()
        print("[Failover] aether policy: audio session \(what)")
    }

    /// Age of the last interruption or route change, nil when there was none.
    var sinceInterruptionSec: Double? {
        lastEventAt.map { clock() - $0 }
    }

    func decide(_ failure: AetherFailure, startedPlaying: Bool, secondsPlayed: Double) -> AetherFailureDecision {
        Self.decide(kind: failure.kind, startedPlaying: startedPlaying, secondsPlayed: secondsPlayed,
                    sinceInterruptionSec: sinceInterruptionSec)
    }
}
