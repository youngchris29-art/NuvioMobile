package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.features.addons.AddonRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/* W2 (spec 5.7, 8.0.4): the account hook, the add-on reset on every account change, the gated bootstrap. */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

private fun account(id: String) = AuthState.Authenticated(id, null, isAnonymous = false)

class TvOsIdentityHooksTest {
    private val log = EventLog()

    @BeforeTest fun setUp() {
        resetIdentityForTest()
        IdentityAccountHooks.ensureLoaded = { log.add("load $it") }
        IdentityAccountHooks.resetAddons = { log.add("reset addons") }
        IdentityAccountHooks.fanOut = { log.add("fan-out $it"); emptyList() }
        IdentityAccountHooks.activeSlot = { 2 }
    }

    @AfterTest fun tearDown() {
        IdentityAccountHooks.resetForTest()
        resetIdentityForTest()
    }

    @Test
    fun accountLoadsResetsAndFansOut() {
        IdentityAccountHooks.accountPublished(AccountKey.Account("a"))
        assertEquals(listOf("load a", "reset addons", "fan-out 2"), log.all())
    }

    @Test
    fun guestLoadsResetsAndFansOut() {
        IdentityAccountHooks.accountPublished(AccountKey.Guest("g"))
        assertEquals(listOf("load g", "reset addons", "fan-out 2"), log.all())
    }

    @Test
    fun noneOnlyResetsAddons() {
        IdentityAccountHooks.accountPublished(AccountKey.None)
        assertEquals(listOf("reset addons"), log.all())
    }

    @Test
    fun mustSucceedFailureThrowsFromTheHook() {
        IdentityAccountHooks.fanOut = { listOf("watched") }
        val thrown = assertFailsWith<FanOutFailed> { IdentityAccountHooks.accountPublished(AccountKey.Account("a")) }
        assertEquals(listOf("watched"), thrown.steps)
    }

    /** Revision 6: the same slot number under another account still resets and fans out. */
    @Test
    fun everyAccountChangeFansOutWhateverTheSlot() {
        IdentityImmediate.onAccountPublished = IdentityAccountHooks::accountPublished
        IdentityImmediate.publishAuth(account("a")) {}
        IdentityImmediate.chainEnded()
        IdentityImmediate.publishAuth(account("b")) {}
        IdentityImmediate.chainEnded()
        IdentityImmediate.publishAuth(account("b")) {} // no change: no window, no hook
        assertEquals(listOf("load a", "reset addons", "fan-out 2", "load b", "reset addons", "fan-out 2"), log.all())
    }

    /** Rule B: a hook whose fan-out fails part-way never opens the gate on that account. */
    @Test
    fun failingFanOutDuringPublishNeverOpensTheGate() {
        IdentityImmediate.onAccountPublished = IdentityAccountHooks::accountPublished
        IdentityAccountHooks.fanOut = { listOf("watched") }
        assertFailsWith<FanOutFailed> { IdentityImmediate.publishAuth(account("a")) {} }
        IdentityImmediate.chainEnded()
        // The in-window recovery re-ran the hook for the account still shown (None), so the gate
        // opened on None, never on "a".
        assertEquals(AccountKey.None, IdentityGate.state.value.scope.account)
        assertEquals(listOf("load a", "reset addons", "reset addons"), log.all())
    }
}

class AccountChangeResetsAddonsTest {
    private val log = EventLog()

    @BeforeTest fun setUp() {
        resetIdentityForTest()
        AddonRepository.clearLocalState()
        IdentityAccountHooks.ensureLoaded = { log.add("load $it") }
        IdentityAccountHooks.activeSlot = { 1 }
        IdentityAccountHooks.fanOut = { slot ->
            log.add("fan-out $slot initialized=${AddonRepository.initializedState.value}")
            emptyList()
        }
        IdentityImmediate.onAccountPublished = IdentityAccountHooks::accountPublished
        IdentityImmediate.afterAccountOpen = { AddonRepository.initialize() }
    }

    @AfterTest fun tearDown() {
        IdentityAccountHooks.resetForTest()
        AddonRepository.clearLocalState()
        resetIdentityForTest()
    }

    @Test
    fun sameSlotAccountChangeResetsThenReinitializesAfterOpen() = real {
        IdentityImmediate.publishAuth(account("a")) {}
        IdentityImmediate.chainEnded()
        eventually { AddonRepository.initializedState.value }
        assertEquals(IdentityScope(AccountKey.Account("a"), 1), IdentityGate.state.value.scope)

        IdentityImmediate.publishAuth(account("b")) {}
        assertFalse(AddonRepository.initializedState.value, "reset inside the window")
        IdentityImmediate.chainEnded()
        eventually { AddonRepository.initializedState.value }
        assertEquals(
            listOf("load a", "fan-out 1 initialized=false", "load b", "fan-out 1 initialized=false"),
            log.all(),
        )
        assertEquals(IdentityScope(AccountKey.Account("b"), 1), IdentityGate.state.value.scope)
    }

    /** Launch restore: None → A on the same slot. */
    @Test
    fun launchRestoreNoneToAccount() = real {
        AddonRepository.initialize() // None, Open: initializes for slot 1
        assertTrue(AddonRepository.initializedState.value)
        IdentityImmediate.publishAuth(account("a")) {}
        assertFalse(AddonRepository.initializedState.value)
        IdentityImmediate.chainEnded()
        eventually { AddonRepository.initializedState.value }
    }
}

class AddonBootstrapAcrossTransitionTest {
    private val log = EventLog()
    private val paused = MutableStateFlow(false)
    private val release = MutableStateFlow(false)

    @BeforeTest fun setUp() {
        installDriverFakes(log)
        AddonRepository.clearLocalState()
        var once = true
        AddonRepository.afterLocalReadForTest = {
            if (once) {
                once = false
                paused.value = true
                spinUntil(5_000) { release.value }
            }
        }
    }

    @AfterTest fun tearDown() {
        AddonRepository.afterLocalReadForTest = {}
        AddonRepository.clearLocalState()
        resetIdentityForTest()
    }

    private suspend fun pausedBootstrapAcross(transition: suspend () -> Unit) {
        val bootstrap = CoroutineScope(Dispatchers.Default).launch { AddonRepository.initialize() }
        eventually { paused.value }
        transition()
        release.value = true
        bootstrap.join()
        assertFalse(AddonRepository.initializedState.value, "a bootstrap begun under the old identity publishes nothing")
        assertFalse(AddonRepository.uiState.value.isInitialized)

        AddonRepository.initialize() // the next caller initializes under the current token
        assertTrue(AddonRepository.initializedState.value)
        assertTrue(AddonRepository.uiState.value.isInitialized)
    }

    @Test
    fun accountChangeDuringBootstrap() = real {
        pausedBootstrapAcross {
            IdentityImmediate.publishAuth(account("user-b")) {}
            IdentityImmediate.chainEnded()
            assertEquals(accountB, IdentityGate.state.value.scope.account)
        }
    }

    @Test
    fun profileSwitchDuringBootstrap() = real {
        pausedBootstrapAcross {
            assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        }
    }
}
