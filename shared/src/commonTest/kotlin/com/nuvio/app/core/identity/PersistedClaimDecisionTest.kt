package com.nuvio.app.core.identity

import kotlin.test.Test
import kotlin.test.assertEquals

/** Spec 3.3: account key × phase (5, revision 10) × current account × slot = 150 cases against an oracle. */
class PersistedClaimDecisionTest {

    private enum class SessionKey(val raw: String?) {
        Missing(null), Malformed("bogus:u1"), Same("account:u1"), OtherAccount("account:u2"), GuestSameId("guest:u1"),
    }

    private enum class Current(val account: AccountKey) {
        None(AccountKey.None), Same(AccountKey.Account("u1")), Other(AccountKey.Account("u9")),
    }

    private val epoch = IdentityEpoch(3)
    private val phases = listOf(
        IdentityPhase.Open, IdentityPhase.Draining(epoch), IdentityPhase.Closed(epoch), IdentityPhase.Applying(epoch),
        IdentityPhase.Recovery(epoch),
    )

    private fun oracle(key: SessionKey, phase: IdentityPhase, current: Current, sameSlot: Boolean): ClaimVerdict = when {
        key == SessionKey.Missing || key == SessionKey.Malformed -> ClaimVerdict.Drop(DropReason.LegacySession)
        phase != IdentityPhase.Open -> ClaimVerdict.Park
        current == Current.None -> ClaimVerdict.Drop(DropReason.SignedOut)
        !(key == SessionKey.Same && current == Current.Same) -> ClaimVerdict.Drop(DropReason.OtherAccount)
        !sameSlot -> ClaimVerdict.Drop(DropReason.OtherProfile)
        else -> ClaimVerdict.Record
    }

    @Test
    fun everyCombination() {
        var count = 0
        for (key in SessionKey.entries) for (phase in phases) for (current in Current.entries)
            for (sameSlot in listOf(true, false)) {
                val scope = IdentityScope(current.account, 2)
                val actual = PersistedClaimDecision.decide(key.raw, if (sameSlot) 2 else 3, phase, scope)
                assertEquals(oracle(key, phase, current, sameSlot), actual, "$key $phase $current sameSlot=$sameSlot")
                count++
            }
        assertEquals(150, count)
    }

    @Test
    fun guestWithTheAccountsIdIsAnotherAccount() {
        assertEquals(
            ClaimVerdict.Drop(DropReason.OtherAccount),
            PersistedClaimDecision.decide("guest:u1", 1, IdentityPhase.Open, IdentityScope(AccountKey.Account("u1"), 1)),
        )
    }
}
