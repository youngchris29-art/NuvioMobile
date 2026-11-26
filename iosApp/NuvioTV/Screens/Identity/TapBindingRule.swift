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
    /// The identity is open (or recovering from a failed apply) on the bound account: run the select.
    case proceed
    /// A window or drained transition holds: wait and decide again.
    case wait
    /// The identity moved to another account (or the tap was never bound): back to the picker.
    case backToPicker
}

/// The barrier phase as the tap rule sees it: total over IdentityPhase and the recovery reason.
enum TapPhase: Equatable {
    case open
    /// Recovery(FailedApply): the picker is on screen and a profile select is the retry (B20a).
    case failedApply
    /// Recovery(FailedPublish / FailedWipe): splash or Welcome; cleared only by a publish or a wipe.
    case recoveryNotSelectable
    /// A window or drained transition holds.
    case holding

    static func of(_ state: IdentityState) -> TapPhase {
        if state.phase is IdentityPhaseOpen { return .open }
        if state.phase is IdentityPhaseRecovery {
            return state.recovery == .failedapply ? .failedApply : .recoveryNotSelectable
        }
        return .holding
    }
}

nonisolated enum TapBindingRule {
    static func decide(bound: String?, current: IdentityState?) -> TapBinding {
        guard let bound else { return .backToPicker }
        guard let current else { return .wait }
        switch TapPhase.of(current) {
        case .holding: return .wait
        case .recoveryNotSelectable: return .backToPicker
        case .open, .failedApply: return accountKey(current) == bound ? .proceed : .backToPicker
        }
    }

    /// The account key of [state] ("none" for no account).
    static func accountKey(_ state: IdentityState) -> String {
        state.scope.account.storageKey() ?? "none"
    }

    /// The key a picker tap binds to: the account of an identity whose picker can be used (open,
    /// or recovering from a failed profile apply), nil otherwise.
    static func pickerBinding(_ state: IdentityState?) -> String? {
        guard let state else { return nil }
        switch TapPhase.of(state) {
        case .open, .failedApply: return accountKey(state)
        case .holding, .recoveryNotSelectable: return nil
        }
    }
}
