package com.nuvio.app.core.identity

import kotlin.test.Test
import kotlin.test.assertEquals

/** W2 fix round: publish vs wipe window, every cause × shown account × open kind. */
class WindowKindRuleTest {
    private val accounts = listOf(AccountKey.None, accountA, AccountKey.Guest("g"))

    @Test
    fun opening() {
        for (cause in WindowCause.entries) for (latest in accounts) {
            val expected = if (cause == WindowCause.Wipe && latest != AccountKey.None) TransitionKind.AccountWipe else TransitionKind.AccountPublished
            assertEquals(expected, WindowKindRule.opening(cause, latest), "$cause $latest")
        }
    }

    @Test
    fun withinOnlyEverUpgradesPublishToWipe() {
        for (current in listOf(TransitionKind.AccountPublished, TransitionKind.AccountWipe)) for (cause in WindowCause.entries) for (latest in accounts) {
            val upgrade = current == TransitionKind.AccountPublished && cause == WindowCause.Wipe && latest != AccountKey.None
            assertEquals(if (upgrade) TransitionKind.AccountWipe else current, WindowKindRule.within(current, cause, latest), "$current $cause $latest")
        }
    }

    /** Through the real IdentityImmediate: a sign-in (serial change, publish) from nobody is a publish window. */
    @Test
    fun signInFromNobodyIsAPublishWindow() {
        resetIdentityForTest()
        val log = EventLog()
        IdentityRevocation.revoker = RecordingRevoker(log)
        IdentityImmediate.serialChanging()
        IdentityImmediate.accountWipe {} // an accept that wipes the previous owner's data first
        IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Authenticated("user-a", null, isAnonymous = false)) {}
        IdentityImmediate.chainEnded()
        assertEquals(listOf("revoke AccountPublished"), log.all())
        resetIdentityForTest()
    }

    /** A lost session while an account is shown: the window turns into a wipe window before the wipe body. */
    @Test
    fun wipeWhileAnAccountIsShownRetargetsBeforeTheBody() {
        resetIdentityForTest()
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
        val log = EventLog()
        IdentityRevocation.revoker = RecordingRevoker(log)
        IdentityImmediate.serialChanging()
        IdentityImmediate.accountWipe { log.add("wipe body sees ${IdentityGate.state.value.kind}") }
        IdentityImmediate.chainEnded()
        assertEquals(listOf("revoke AccountPublished", "revoke AccountWipe", "wipe body sees AccountWipe"), log.all())
        resetIdentityForTest()
    }
}
