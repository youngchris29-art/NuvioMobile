import Foundation
import SharedCore

/// Scope identity W2 review r1 #4: a profile tap is bound to the identity it was made under. Pure.
///
/// `bound` is the account key ("account:<id>", "guest:<id>") the tap belongs to: for a picker tap,
/// the open identity at the moment the picker showed and (for a PIN profile) verified that profile;
/// for the FEAT-65 auto-enter, the account the auth state names when the remembered profile was read
/// (its profile cache is that account's). nil means the picker was shown while no identity was open,
/// so what it listed cannot be trusted: never enter.
enum TapBinding: Equatable {
    /// The identity is open on the bound account: run the select.
    case proceed
    /// A window or drained transition holds: wait and decide again.
    case wait
    /// The identity moved to another account (or the tap was never bound): back to the picker.
    case backToPicker
}

nonisolated enum TapBindingRule {
    static func decide(bound: String?, current: IdentityState?) -> TapBinding {
        guard let bound else { return .backToPicker }
        guard let current, current.phase is IdentityPhaseOpen else { return .wait }
        return accountKey(current) == bound ? .proceed : .backToPicker
    }

    /// The account key of [state] ("none" for no account).
    static func accountKey(_ state: IdentityState) -> String {
        state.scope.account.storageKey() ?? "none"
    }

    /// The key a picker tap binds to: the open identity's account, nil while none is open.
    static func pickerBinding(_ state: IdentityState?) -> String? {
        guard let state, state.phase is IdentityPhaseOpen else { return nil }
        return accountKey(state)
    }
}
