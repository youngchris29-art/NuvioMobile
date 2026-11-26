import SharedCore
import XCTest
@testable import NuvioTV

/// Scope identity W2 (spec 8.2 "Cover ownership", P13): one owner, one observable.
@MainActor
final class CoverOwnershipTests: XCTestCase {
    private var cover: FakeCover!
    private var root: FakeRoot!
    private var model: IdentityModel!
    private var sent: [Int64] = []

    override func setUp() async throws {
        cover = FakeCover()
        root = FakeRoot()
        model = IdentityModel(cover: cover, root: root)
        sent = []
        model.sendTeardown = { [weak self] in self?.sent.append($0) }
    }

    func testCoverFollowsLocalSelectAndTransitioningExactly() {
        let kinds: [TransitionKind?] = [nil, .profileselect, .activeprofiledelete, .slotremoved, .signout,
                                        .deleteaccount, .serverswitch, .accountwipe, .accountpublished]
        for kind in kinds {
            for local in [false, true] {
                let state = kind.map { IdentityFixture.draining($0) } ?? IdentityFixture.state()
                let expected: IdentityCoverKind?
                if local {
                    expected = .switching
                } else {
                    switch kind {
                    case .some(.profileselect), .some(.activeprofiledelete), .some(.slotremoved): expected = .switching
                    case .some(.signout), .some(.deleteaccount), .some(.serverswitch), .some(.accountwipe): expected = .signingOut
                    default: expected = nil
                    }
                }
                XCTAssertEqual(IdentityModel.coverKind(state: state, localSelectInFlight: local), expected,
                               "kind=\(String(describing: kind)) local=\(local)")
            }
        }
    }

    func testModelShowsAndHidesTheWindowWithItsInputs() {
        model.setState(IdentityFixture.state())
        XCTAssertFalse(model.coverVisible)
        model.localSelectInFlight = true
        XCTAssertTrue(model.coverVisible)
        XCTAssertTrue(cover.visible)
        model.localSelectInFlight = false
        XCTAssertFalse(cover.visible)
        model.setState(IdentityFixture.draining(.signout))
        XCTAssertEqual(model.coverKind, .signingOut)
        model.setState(IdentityFixture.state(account: AccountKeyNone.shared, epoch: 2))
        XCTAssertFalse(cover.visible)
    }

    /// B3a: a failed-closed switch publishes Open with the SAME epoch; the cover still hides.
    func testSameEpochOpenHidesTheCoverAndRecoversToRoot() {
        model.setState(IdentityFixture.draining(.profileselect, epoch: 4))
        XCTAssertTrue(cover.visible)
        model.setState(IdentityFixture.state(epoch: 4))
        XCTAssertFalse(cover.visible)
        XCTAssertEqual(root.recoveries, 1, "not entered: the picker must be the front screen")
    }

    func testNoRecoveryToRootWhileEntered() {
        model.isEntered = true
        model.setState(IdentityFixture.draining(.signout))
        model.setState(IdentityFixture.state(epoch: 2))
        XCTAssertEqual(root.recoveries, 0)
    }

    func testAccountPublishedWindowHasNoCover() {
        model.setState(IdentityFixture.state(phase: IdentityPhaseClosed(from: IdentityEpoch(value: 1)), kind: .accountpublished))
        XCTAssertFalse(model.coverVisible)
        XCTAssertTrue(cover.shown.isEmpty)
    }

    func testRevokeIsFalseWhenTheCoverCannotShow() {
        cover.canShow = false
        XCTAssertFalse(model.revoke(IdentityFixture.draining(.profileselect)))
        XCTAssertTrue(model.revoke(IdentityFixture.state(phase: IdentityPhaseClosed(from: IdentityEpoch(value: 1)), kind: .accountpublished)),
                      "a kind without a cover never fails on the window")
    }

    func testRevokeRunsTheShellRevocationSynchronously() {
        var revoked: [IdentityState] = []
        model.onRevoke = { revoked.append($0) }
        let state = IdentityFixture.draining(.slotremoved)
        XCTAssertTrue(model.revoke(state))
        XCTAssertEqual(revoked.count, 1)
        XCTAssertTrue(cover.visible, "visible before revoke returns")
    }

    // MARK: Teardown acknowledgement (4.6, revision 8)

    func testTeardownWaitsForTheShellAndTheDeepLinkCover() {
        model.surfaceAppeared(.shell)
        model.surfaceAppeared(.deepLinkCover)
        _ = model.revoke(IdentityFixture.draining(.profileselect, transitionId: 11))
        model.surfaceDisappeared(.shell)
        XCTAssertEqual(sent, [])
        model.surfaceDisappeared(.deepLinkCover)
        XCTAssertEqual(sent, [11])
    }

    /// A theme `.id()` rebuild mounts the new shell before the old one disappears: still mounted.
    func testRebuildOverlapKeepsTheShellCounted() {
        model.surfaceAppeared(.shell)
        model.surfaceAppeared(.shell) // the incoming tree
        model.surfaceDisappeared(.shell) // the outgoing tree
        _ = model.revoke(IdentityFixture.draining(.slotremoved, transitionId: 13))
        let tick = expectation(description: "tick")
        DispatchQueue.main.async { tick.fulfill() }
        wait(for: [tick], timeout: 1)
        XCTAssertEqual(sent, [], "the shell is still mounted")
        model.surfaceDisappeared(.shell)
        XCTAssertEqual(sent, [13])
    }

    func testNothingMountedAcknowledgesAfterTheRevoke() {
        _ = model.revoke(IdentityFixture.draining(.profileselect, transitionId: 12))
        XCTAssertEqual(sent, [], "never inside the revoke")
        let done = expectation(description: "ack")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(sent, [12])
    }

    func testWindowsAreNotAcknowledged() {
        _ = model.revoke(IdentityFixture.state(phase: IdentityPhaseClosed(from: IdentityEpoch(value: 1)), kind: .accountwipe, transitionId: 0))
        let done = expectation(description: "tick")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(sent, [])
    }

    // MARK: Recovery (decision AA)

    func testFailedPublishShowsTheSplashThenWelcomeAfterTheRetries() async {
        var retries = 0
        let recovering = IdentityFixture.state(phase: IdentityPhaseRecovery(from: IdentityEpoch(value: 1)), recovery: .failedpublish)
        model.retrySpacingNanoseconds = 1_000_000
        model.retryRecovery = { retries += 1 }
        model.currentStateForRetry = { recovering }
        model.setState(recovering)
        XCTAssertEqual(model.recoveryScreen, .splash)
        for _ in 0..<200 where model.recoveryScreen != .welcome {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.recoveryScreen, .welcome)
        XCTAssertEqual(retries, IdentityModel.maxRecoveryRetries)
    }

    func testFailedWipeGoesStraightToWelcomeAndApplyHasNoScreen() {
        model.setState(IdentityFixture.state(phase: IdentityPhaseRecovery(from: IdentityEpoch(value: 1)), recovery: .failedwipe))
        XCTAssertEqual(model.recoveryScreen, .welcome)
        model.setState(IdentityFixture.state(phase: IdentityPhaseRecovery(from: IdentityEpoch(value: 1)), recovery: .failedapply))
        XCTAssertEqual(model.recoveryScreen, .none)
        model.setState(IdentityFixture.state(epoch: 2))
        XCTAssertEqual(model.recoveryScreen, .none)
    }
}

/// Scope identity W2 (spec 8.0.3): the select sequence, one fake barrier per result.
@MainActor
final class SelectAndEnterSequenceTests: XCTestCase {
    private var cover: FakeCover!
    private var root: FakeRoot!
    private var model: IdentityModel!
    private var ports: FakeSelectPorts!

    override func setUp() async throws {
        cover = FakeCover()
        root = FakeRoot()
        model = IdentityModel(cover: cover, root: root)
        ports = FakeSelectPorts()
        ports.current = IdentityFixture.state(slot: 1, epoch: 1)
    }

    private func run(slot: Int32 = 2, bound: String? = "guest:g") async -> (entered: Bool, coverDuringEnter: Bool?) {
        var coverDuringEnter: Bool?
        var coverDuringSelect = false
        ports.duringSelect = { coverDuringSelect = self.cover.visible }
        let entered = await ProfilesViewModel.selectAndEnter(slot: slot, boundAccount: bound, identity: model, ports: ports) { _ in
            coverDuringEnter = self.cover.visible
        }
        XCTAssertTrue(coverDuringSelect, "the cover shows at the tap")
        XCTAssertFalse(model.localSelectInFlight, "the flag is always cleared")
        XCTAssertFalse(cover.visible, "the cover always hides")
        return (entered, coverDuringEnter)
    }

    func testDoneEntersAndTheCoverHidesOnlyAfterEntry() async {
        let final = IdentityFixture.state(slot: 2, epoch: 2)
        ports.currentAfterSelect = final
        ports.result = { TransitionResultDone(final: final) }
        let outcome = await run()
        XCTAssertTrue(outcome.entered)
        XCTAssertEqual(outcome.coverDuringEnter, true, "entered while the cover was still up")
        XCTAssertEqual(root.recoveries, 0, "recoverToRoot never runs after a successful select")
        XCTAssertEqual(ports.syncs, [2])
    }

    private func assertNotEntered(file: StaticString = #filePath, line: UInt = #line) async {
        let outcome = await run()
        XCTAssertFalse(outcome.entered, file: file, line: line)
        XCTAssertNil(outcome.coverDuringEnter, file: file, line: line)
        XCTAssertEqual(root.recoveries, 1, "the picker becomes the front screen once", file: file, line: line)
        XCTAssertEqual(ports.syncs, [], file: file, line: line)
    }

    func testPreempted() async {
        ports.result = { TransitionResultPreempted(final: IdentityFixture.state(slot: 1, epoch: 1)) }
        await assertNotEntered()
    }

    func testFailed() async {
        ports.result = { TransitionResultFailed(error: "teardown unconfirmed", final: IdentityFixture.state(slot: 1, epoch: 1)) }
        await assertNotEntered()
    }

    func testThrow() async {
        ports.result = { throw NSError(domain: "kotlin", code: 2) }
        await assertNotEntered()
    }

    func testStaleFinal() async {
        let final = IdentityFixture.state(slot: 2, epoch: 2)
        ports.currentAfterSelect = IdentityFixture.state(slot: 3, epoch: 3) // a later transition completed
        ports.result = { TransitionResultDone(final: final) }
        await assertNotEntered()
    }

    func testDoneUnderAnotherAccount() async {
        let final = IdentityFixture.state(account: IdentityFixture.other, slot: 2, epoch: 2)
        ports.currentAfterSelect = final
        ports.result = { TransitionResultDone(final: final) }
        await assertNotEntered()
    }

    func testRequested() async {
        ports.result = { TransitionResultRequested.shared }
        await assertNotEntered()
        XCTAssertEqual(ports.impossible.count, 1)
    }

    /// An account restore's gate can turn .main while its window (still naming None) is closing:
    /// auto-enter is bound to the restored account (the auth state's), so it waits and enters.
    func testTapDuringAClosingWindowReadsTheAccountAfterIt() async {
        let restored = IdentityFixture.state(slot: 1, epoch: 1)
        ports.current = IdentityFixture.state(account: AccountKeyNone.shared, phase: IdentityPhaseClosed(from: IdentityEpoch(value: 0)),
                                              kind: .accountpublished)
        let ports = self.ports!
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            ports.current = restored
        }
        let final = IdentityFixture.state(slot: 2, epoch: 2)
        ports.currentAfterSelect = final
        ports.result = { TransitionResultDone(final: final) }
        let outcome = await run()
        XCTAssertTrue(outcome.entered)
    }

    /// Review r1 #4: a tap on A's profile as a transition to B starts never selects in B.
    func testTapUnderAnotherAccountGoesBackToThePicker() async {
        ports.current = IdentityFixture.state(account: IdentityFixture.guest, phase: IdentityPhaseClosed(from: IdentityEpoch(value: 1)),
                                              kind: .accountpublished)
        let ports = self.ports!
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            ports.current = IdentityFixture.state(account: IdentityFixture.other, slot: 1, epoch: 2)
        }
        var selected = false
        ports.result = { selected = true; return TransitionResultRequested.shared }
        let entered = await ProfilesViewModel.selectAndEnter(slot: 2, boundAccount: "guest:g", identity: model, ports: ports) { _ in }
        XCTAssertFalse(entered)
        XCTAssertFalse(selected, "the barrier must not be asked to select in B")
        XCTAssertEqual(root.recoveries, 1)
        XCTAssertFalse(cover.visible)
    }

    func testUnboundTapNeverSelects() async {
        var selected = false
        ports.result = { selected = true; return TransitionResultRequested.shared }
        let entered = await ProfilesViewModel.selectAndEnter(slot: 2, boundAccount: nil, identity: model, ports: ports) { _ in }
        XCTAssertFalse(entered)
        XCTAssertFalse(selected)
    }

    func testFailBeforeBeginKnob() async {
        ports.failBeforeBegin = true
        ports.result = { XCTFail("the barrier must not be called"); return TransitionResultRequested.shared }
        ports.duringSelect = {}
        let entered = await ProfilesViewModel.selectAndEnter(slot: 2, boundAccount: "guest:g", identity: model, ports: ports) { _ in }
        XCTAssertFalse(entered)
        XCTAssertEqual(root.recoveries, 1)
        XCTAssertFalse(cover.visible)
    }
}

/// Scope identity W2 review r1 #4: every case of the tap binding.
final class TapBindingRuleTests: XCTestCase {
    func testEveryCase() {
        let open = IdentityPhaseOpen.shared
        let closed = IdentityPhaseClosed(from: IdentityEpoch(value: 1))
        for bound in [nil, "guest:g", "account:b"] as [String?] {
            for account in [IdentityFixture.guest, IdentityFixture.other, AccountKeyNone.shared] as [AccountKey] {
                for phase in [open, closed] as [IdentityPhase] {
                    let state = IdentityFixture.state(account: account, phase: phase)
                    let key = account.storageKey() ?? "none"
                    let expected: TapBinding = bound == nil ? .backToPicker : (phase is IdentityPhaseOpen ? (key == bound ? .proceed : .backToPicker) : .wait)
                    XCTAssertEqual(TapBindingRule.decide(bound: bound, current: state), expected, "\(String(describing: bound)) \(key) \(phase)")
                }
            }
            XCTAssertEqual(TapBindingRule.decide(bound: bound, current: nil), bound == nil ? .backToPicker : .wait)
        }
    }

    func testPickerBindingOnlyUnderAnOpenIdentity() {
        XCTAssertEqual(TapBindingRule.pickerBinding(IdentityFixture.state()), "guest:g")
        XCTAssertNil(TapBindingRule.pickerBinding(IdentityFixture.draining(.signout)))
        XCTAssertNil(TapBindingRule.pickerBinding(nil))
    }
}

/// Scope identity W2 (spec 4.6): the revoker runs its body on main before returning.
final class IdentityRevokerTests: XCTestCase {
    func testOffMainCallBlocksUntilTheMainThreadBodyRan() {
        var order: [String] = []
        let lock = NSLock()
        let revoker = IdentityRevokerImpl { _ in
            lock.lock(); order.append(Thread.isMainThread ? "body on main" : "body off main"); lock.unlock()
            return true
        }
        let done = expectation(description: "revoked")
        DispatchQueue.global().async {
            let result = revoker.revoke(state: IdentityFixture.draining(.profileselect))
            lock.lock(); order.append("returned \(result)"); lock.unlock()
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(order, ["body on main", "returned true"])
    }

    @MainActor
    func testOnMainCallRunsInline() {
        var ran = false
        let revoker = IdentityRevokerImpl { _ in ran = true; return true }
        XCTAssertTrue(revoker.revoke(state: IdentityFixture.draining(.signout)))
        XCTAssertTrue(ran)
    }

    @MainActor
    func testNoSceneReturnsFalse() {
        let cover = FakeCover()
        cover.canShow = false
        let model = IdentityModel(cover: cover, root: FakeRoot())
        let revoker = IdentityRevokerImpl { model.revoke($0) }
        XCTAssertFalse(revoker.revoke(state: IdentityFixture.draining(.profileselect)))
    }
}
