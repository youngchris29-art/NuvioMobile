import Foundation
import SharedCore

/// Scope identity W2 (spec 8.2): when the shell of an entered profile must be left. Pure.
///
/// `entered` is the `IdentityState` captured when the profile was entered (scope and epoch). The
/// shell is left when the account differs, or, while no local select is in flight, when a
/// transition holds, the slot differs or the epoch advanced (P13).
nonisolated enum EnteredScopeRule {
    static func shouldLeave(entered: IdentityState?, state: IdentityState, localSelectInFlight: Bool) -> Bool {
        guard let entered else { return false }
        if !IdentityValues.same(state.scope.account, entered.scope.account) { return true }
        if localSelectInFlight { return false }
        return state.transitioning
            || state.scope.slot != entered.scope.slot
            || state.epoch.value > entered.epoch.value
    }
}

/// Kotlin value equality (data classes and objects export `isEqual`) for values Swift only sees
/// through protocols.
nonisolated enum IdentityValues {
    static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l as NSObject, r as NSObject): return l.isEqual(r)
        default: return false
        }
    }
}
