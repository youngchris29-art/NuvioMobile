import Foundation

/// BUG-112: decides whether an Up press that reached `onMoveCommand` was in fact already consumed
/// by the focus engine. Device evidence 2026-09-30 (Living Room Apple TV 4K, tvOS 27): every one of
/// 28 press-triggered fallback starts was logged 30-180 ms AFTER a `focusUpdate` line showing the
/// engine had already moved focus up one row, so the ladder moved it a second row. A row-focus
/// change inside `consumedWindow` of the press therefore means the press is spent and the ladder
/// must stand down.
enum HomeUpPressConsumption {
    /// Covers the observed 30-180 ms lag with headroom.
    static let consumedWindow: TimeInterval = 0.3

    /// `true` when focus changed rows within `consumedWindow` before `now`. A nil or future
    /// timestamp is NOT consumed. Both inputs are `systemUptime` values.
    static func isConsumed(now: TimeInterval, lastRowFocusChange: TimeInterval?) -> Bool {
        guard let last = lastRowFocusChange else { return false }
        let elapsed = now - last
        return elapsed >= 0 && elapsed < consumedWindow
    }
}
