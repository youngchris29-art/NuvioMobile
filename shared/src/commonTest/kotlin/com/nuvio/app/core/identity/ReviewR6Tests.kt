package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.auth.ProvisionalPublishRule
import com.nuvio.app.features.auth.ServerConnectionUiState
import com.nuvio.app.features.auth.ServerSwitchFailure
import com.nuvio.app.features.auth.ServerSwitchOutcome
import com.nuvio.app.features.profiles.NuvioProfile
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.profiles.ProfileState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/* W2 review round 6: row-bound actions, the guest delete section, the watchdog rule, the switch outcome. */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

class RowBoundDeleteTest {
    private val rpcs = mutableListOf<Int>()

    @BeforeTest fun setUp() {
        resetIdentityForTest(serial = 1)
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(EventLog()))
        ProfileRepository.isGuestForTest = false
        ProfileRepository.deleteRpcForTest = { rpcs += it }
    }

    @AfterTest fun tearDown() {
        ProfileRepository.deleteRpcForTest = null
        ProfileRepository.isGuestForTest = null
        resetProfilesForTest()
        resetIdentityForTest()
    }

    private fun rowOf(token: AccountToken) =
        ProfileState(profiles = listOf(NuvioProfile(profileIndex = 1), NuvioProfile(profileIndex = 2)), listToken = token).displayedRow(2)!!

    /** r6 #1: a row of A's list whose PIN check completes after B opened never deletes in B. */
    @Test
    fun aRowOfAnotherAccountNeverDeletes() = real {
        val rowOfA = rowOf(AccountToken(accountA, 1))
        IdentityRuntime.authSerial = { 2 }
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountB, 1), latestAccount = accountB))
        ProfileRepository.deleteProfile(rowOfA)
        assertEquals(emptyList(), rpcs, "no RPC for a row of another account")
    }

    @Test
    fun aCurrentRowDeletes() = real {
        ProfileRepository.deleteProfile(rowOf(AccountToken(accountA, 1)))
        assertEquals(listOf(2), rpcs)
    }
}

/** r6 #2: the guest delete's remaining list comes from the current list inside its commit section. */
class GuestDeleteSectionTest {
    private val token = AccountToken(AccountKey.Guest("g"), 1)

    @BeforeTest fun setUp() {
        resetIdentityForTest(serial = 1)
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(AccountKey.Guest("g"), 1), latestAccount = AccountKey.Guest("g")))
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(EventLog()))
        ProfileRepository.isGuestForTest = true
        ProfileRepository.setStateForTest(ProfileState(profiles = (1..3).map { NuvioProfile(profileIndex = it) }, isLoaded = true, listToken = token))
    }

    @AfterTest fun tearDown() {
        ProfileRepository.beforeGuestDeleteCommitForTest = {}
        ProfileRepository.isGuestForTest = null
        resetProfilesForTest()
        resetIdentityForTest()
    }

    @Test
    fun aConcurrentGuestEditSurvivesTheDelete() = real {
        val row = ProfileRepository.state.value.displayedRow(3)!!
        ProfileRepository.beforeGuestDeleteCommitForTest = {
            // A guest create committed between the delete's start and its section.
            IdentityGate.commitAccount(token) {
                ProfileRepository.setStateForTest(ProfileRepository.state.value.copy(profiles = (1..4).map { NuvioProfile(profileIndex = it) }))
            }
        }
        ProfileRepository.deleteProfile(row)
        assertEquals(listOf(1, 2, 4), ProfileRepository.state.value.profiles.map { it.profileIndex })
    }
}

class ProvisionalPublishRuleTest {
    private val account = AuthState.Authenticated("A", null, isAnonymous = false)
    private val guest = AuthState.Authenticated("g", null, isAnonymous = true)

    /** watchdog × published × pending (a pending publish exists exactly in Recovery(FailedPublish)). */
    @Test
    fun everyCase() {
        for (published in listOf(AuthState.Loading, AuthState.Unauthenticated, account, guest)) for (pending in listOf(null, account, guest)) {
            assertEquals(published == AuthState.Loading && pending == null, ProvisionalPublishRule.watchdogShowsWelcome(published, pending), "$published $pending")
            for (liveIsGuest in listOf(false, true)) for (fired in listOf(false, true)) {
                assertEquals(!liveIsGuest && !fired && pending == null, ProvisionalPublishRule.initializingShowsLoading(liveIsGuest, fired, pending))
            }
        }
    }
}

class ServerSwitchOutcomeTest {
    @Test
    fun everyResultClearsTheBusyState() {
        val busy = ServerConnectionUiState(isSwitching = true)
        assertEquals(busy, ServerSwitchOutcome.after(true, busy), "success: runSwitch owns the state")
        val failed = ServerSwitchOutcome.after(false, busy)
        assertEquals(false, failed.isSwitching)
        assertEquals(ServerSwitchFailure.Restart, failed.switchFailure)
        val reported = ServerConnectionUiState(isSwitching = false, switchFailure = ServerSwitchFailure.SessionClear)
        assertEquals(reported, ServerSwitchOutcome.after(false, reported), "a failure runSwitch reported is kept")
        assertTrue(!ServerSwitchOutcome.after(false, ServerConnectionUiState(isSwitching = true, switchFailure = ServerSwitchFailure.Save)).isSwitching)
    }
}
