#if DEBUG
import Foundation
import UIKit

/// Return from background, DEBUG harness (spec 9.3): `-debug.backgroundCycleAtSec <t>` and
/// `-debug.backgroundCycleAwaySec <n>` post `didEnterBackgroundNotification`, wait `n` seconds (default
/// 5), then post `didBecomeActiveNotification`, once per player, when the playhead first reaches `t`
/// (0 = at the first tick). The engine and the players observe with `object: nil`, so the in-process
/// cycle drives the same code a real Home press does; `applicationState` stays `.active`, which is why
/// neither the rule nor the controllers read it. Compiled out of Release.
struct DebugBackgroundCycle {
    static let atKey = "debug.backgroundCycleAtSec"
    static let awayKey = "debug.backgroundCycleAwaySec"

    private var fired = false

    /// The configured trigger, nil when the key is absent (launch arguments arrive as strings).
    static func trigger(defaults: UserDefaults = .standard) -> (atSec: Double, awaySec: Double)? {
        guard defaults.object(forKey: atKey) != nil else { return nil }
        let at = max(0, defaults.double(forKey: atKey))
        let away = defaults.object(forKey: awayKey) != nil ? max(0, defaults.double(forKey: awayKey)) : 5
        return (at, away)
    }

    /// spec-mpv-return §5.3: `-debug.backgroundCycleAtStage loadIssued` runs the cycle when the player
    /// issues its load (mpv), instead of at a playhead position.
    static let stageKey = "debug.backgroundCycleAtStage"
    /// `-debug.backgroundCycleSecondAfterSec <n>` (leg M9): a second cycle n seconds after the first
    /// one's return, posted by the same harness (the fresh mpv controller is the one it backgrounds).
    static let secondAfterKey = "debug.backgroundCycleSecondAfterSec"

    /// The stage trigger. Returns true when the cycle started.
    @MainActor
    @discardableResult
    mutating func noteStage(_ stage: String, defaults: UserDefaults = .standard,
                            center: NotificationCenter = .default) -> Bool {
        guard !fired, defaults.string(forKey: Self.stageKey) == stage else { return false }
        fired = true
        let away = defaults.object(forKey: Self.awayKey) != nil ? max(0, defaults.double(forKey: Self.awayKey)) : 5
        print("[Return] DEBUG background cycle at stage \(stage) for \(away) s")
        Self.run(awaySec: away, defaults: defaults, center: center)
        return true
    }

    @MainActor
    private static func run(awaySec: Double, defaults: UserDefaults, center: NotificationCenter) {
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + awaySec) {
            print("[Return] DEBUG background cycle: active again")
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            guard defaults.object(forKey: secondAfterKey) != nil else { return }
            let after = max(0, defaults.double(forKey: secondAfterKey))
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("[Return] DEBUG second background cycle for \(awaySec) s")
                center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + awaySec) {
                    print("[Return] DEBUG second background cycle: active again")
                    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                }
            }
        }
    }

    /// The housekeeping tick. Returns true when the cycle started on this tick.
    @MainActor
    @discardableResult
    mutating func noteTick(positionSec: Double, defaults: UserDefaults = .standard,
                           center: NotificationCenter = .default) -> Bool {
        guard !fired, let trigger = Self.trigger(defaults: defaults), positionSec >= trigger.atSec else { return false }
        fired = true
        print("[Return] DEBUG background cycle at \(String(format: "%.1f", positionSec)) for \(trigger.awaySec) s")
        Self.run(awaySec: trigger.awaySec, defaults: defaults, center: center)
        return true
    }
}
#endif
