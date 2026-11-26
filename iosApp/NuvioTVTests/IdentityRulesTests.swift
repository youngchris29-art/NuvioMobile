import SharedCore
import XCTest
@testable import NuvioTV

/// Scope identity W2 (spec 8.2): `EnteredScopeRule`, every combination against an oracle.
final class EnteredScopeRuleTests: XCTestCase {
    func testEveryCombination() {
        var cases = 0
        for otherAccount in [false, true] {
            for otherSlot in [false, true] {
                for transitioning in [false, true] {
                    for localSelect in [false, true] {
                        for advanced in [false, true] {
                            cases += 1
                            let entered = IdentityFixture.state(slot: 1, epoch: 3)
                            let state = IdentityFixture.state(
                                account: otherAccount ? IdentityFixture.other : IdentityFixture.guest,
                                slot: otherSlot ? 2 : 1,
                                epoch: advanced ? 4 : 3,
                                phase: transitioning ? IdentityPhaseDraining(from: IdentityEpoch(value: 3)) : IdentityPhaseOpen.shared,
                                kind: transitioning ? .profileselect : nil)
                            let expected = otherAccount || (!localSelect && (transitioning || otherSlot || advanced))
                            XCTAssertEqual(
                                EnteredScopeRule.shouldLeave(entered: entered, state: state, localSelectInFlight: localSelect),
                                expected,
                                "account other=\(otherAccount) slot other=\(otherSlot) transitioning=\(transitioning) local=\(localSelect) advanced=\(advanced)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 32)
    }

    func testNotEnteredNeverLeaves() {
        XCTAssertFalse(EnteredScopeRule.shouldLeave(entered: nil, state: IdentityFixture.draining(.signout), localSelectInFlight: false))
    }
}

/// Scope identity W2 (spec 8.2): the FEAT-65 latch.
final class ProfileAutoEnterLatchTests: XCTestCase {
    private func latch(_ events: [ProfileAutoEnterLatch.Event]) -> ProfileAutoEnterLatch {
        var latch = ProfileAutoEnterLatch()
        events.forEach { latch.apply($0) }
        return latch
    }

    func testFreshLatchMayAutoEnter() {
        XCTAssertTrue(ProfileAutoEnterLatch().mayAutoEnter)
    }

    func testEachEventFromEachState() {
        let gates: [AuthViewModel.Gate] = [.loading, .welcome, .main]
        for from in gates {
            for to in gates {
                let fresh = latch([.gate(from: from, to: to)])
                let consumes = from == .main && to == .welcome
                XCTAssertEqual(fresh.mayAutoEnter, !consumes, "\(from) → \(to)")
                XCTAssertEqual(fresh.provisionalWelcome, from == .loading && to == .welcome, "\(from) → \(to)")
                // A consumed latch stays consumed whatever the gate does next.
                XCTAssertFalse(latch([.autoEnterRan, .gate(from: from, to: to)]).mayAutoEnter)
            }
        }
        for event: ProfileAutoEnterLatch.Event in [.userStartedSignIn, .accountChangedWhileMain, .autoEnterRan] {
            XCTAssertFalse(latch([event]).mayAutoEnter, "\(event)")
            XCTAssertFalse(latch([.gate(from: .loading, to: .welcome), event]).mayAutoEnter, "\(event)")
        }
    }

    func testWatchdogWelcomeThenRestore() {
        XCTAssertTrue(latch([.gate(from: .loading, to: .welcome), .gate(from: .welcome, to: .main)]).mayAutoEnter)
    }

    func testSignedOutColdLaunchThenSignIn() {
        XCTAssertFalse(latch([.gate(from: .loading, to: .welcome), .userStartedSignIn, .gate(from: .welcome, to: .main)]).mayAutoEnter)
    }

    func testSignOutThenSignIn() {
        XCTAssertFalse(latch([.gate(from: .loading, to: .main), .gate(from: .main, to: .welcome), .gate(from: .welcome, to: .main)]).mayAutoEnter)
    }

    func testFiresOnce() {
        var latch = ProfileAutoEnterLatch()
        latch.apply(.gate(from: .loading, to: .main))
        XCTAssertTrue(latch.mayAutoEnter)
        latch.apply(.autoEnterRan)
        XCTAssertFalse(latch.mayAutoEnter)
    }
}
