import Foundation
import SharedCore
@testable import NuvioTV

/// Builders and fakes shared by the scope-identity W2 tests.
enum IdentityFixture {
    static let guest: AccountKey = AccountKeyGuest(guestId: "g")
    static let other: AccountKey = AccountKeyAccount(userId: "b")

    static func state(account: AccountKey = guest,
                      slot: Int32 = 1,
                      epoch: Int64 = 1,
                      phase: IdentityPhase = IdentityPhaseOpen.shared,
                      kind: TransitionKind? = nil,
                      transitionId: Int64 = 0,
                      recovery: RecoveryReason? = nil) -> IdentityState {
        IdentityState(scope: IdentityScope(account: account, slot: slot),
                      epoch: IdentityEpoch(value: epoch),
                      phase: phase,
                      kind: kind,
                      transitionId: transitionId,
                      recovery: recovery)
    }

    static func draining(_ kind: TransitionKind, epoch: Int64 = 1, slot: Int32 = 1, transitionId: Int64 = 7,
                         account: AccountKey = guest) -> IdentityState {
        state(account: account, slot: slot, epoch: epoch, phase: IdentityPhaseDraining(from: IdentityEpoch(value: epoch)),
              kind: kind, transitionId: transitionId)
    }
}

@MainActor
final class FakeCover: IdentityCoverPresenting {
    var canShow = true
    private(set) var shown: [IdentityCoverKind] = []
    private(set) var hides = 0
    private(set) var visible = false

    func show(_ kind: IdentityCoverKind) -> Bool {
        guard canShow else { return false }
        shown.append(kind)
        visible = true
        return true
    }

    func hide() {
        hides += 1
        visible = false
    }
}

@MainActor
final class FakeRoot: IdentityRootRecovering {
    private(set) var recoveries = 0
    func recoverToRoot() { recoveries += 1 }
}

@MainActor
final class FakeSelectPorts: ProfileSelectPorts {
    var result: () throws -> TransitionResult = { throw NSError(domain: "test", code: 1) }
    var current: IdentityState?
    /// What `currentState()` returns once the select returned (a later transition, say).
    var currentAfterSelect: IdentityState?
    var duringSelect: () -> Void = {}
    private(set) var syncs: [Int32] = []
    private(set) var impossible: [String] = []
    var failBeforeBegin = false

    func select(slot: Int32) async throws -> TransitionResult {
        duringSelect()
        if let after = currentAfterSelect { current = after }
        return try result()
    }

    func currentState() -> IdentityState? { current }
    func startSync(slot: Int32) { syncs.append(slot) }
    func reportImpossible(_ message: String) { impossible.append(message) }
}
