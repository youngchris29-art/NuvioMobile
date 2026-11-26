package com.nuvio.app.core.identity

import com.nuvio.app.core.auth.AuthState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.concurrent.Volatile
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals

/* W2 review r1 #3: a profile pull asked for inside an identity window is owed and served once. */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

class OwedPullRuleTest {
    @Test
    fun everyCase() {
        val accounts = listOf<AccountKey?>(null, accountA, accountB)
        for (owed in accounts) for (open in listOf(true, false)) for (openAccount in listOf(accountA, accountB, AccountKey.None)) {
            val expected = when {
                owed == null || !open -> OwedPullAction.Keep
                openAccount == owed -> OwedPullAction.Pull
                else -> OwedPullAction.Drop
            }
            assertEquals(expected, OwedPullRule.decide(owed, open, openAccount), "owed=$owed open=$open account=$openAccount")
        }
    }
}

class OwedProfilePullTest {
    @Volatile private var pulls = 0

    @BeforeTest fun setUp() {
        resetIdentityForTest()
        OwedProfilePull.resetForTest()
        OwedProfilePull.pull = { pulls++ }
    }

    @AfterTest fun tearDown() {
        OwedProfilePull.resetForTest()
        resetIdentityForTest()
    }

    private fun signInWindow(user: String) {
        IdentityImmediate.serialChanging()
        IdentityImmediate.publishAuth(AuthState.Authenticated(user, null, isAnonymous = false)) {}
    }

    @Test
    fun pullAskedInsideTheWindowRunsOnceAfterItCloses() = real {
        signInWindow("user-a")
        OwedProfilePull.owe(accountA)
        OwedProfilePull.owe(accountA) // asked twice: still one owed pull
        delay(100)
        assertEquals(0, pulls, "not while the window holds")
        IdentityImmediate.chainEnded()
        eventually { pulls == 1 }
        delay(200)
        assertEquals(1, pulls, "exactly one")
    }

    @Test
    fun anOpenOnAnotherAccountDropsIt() = real {
        signInWindow("user-b")
        OwedProfilePull.owe(accountA)
        IdentityImmediate.chainEnded()
        delay(300)
        assertEquals(0, pulls)
    }

    /** Review r2 #2: a wake-up that saw A open, delayed past B's debt, keeps B's debt. */
    @Test
    fun staleWakeUpKeepsALaterDebt() = real {
        signInWindow("user-a")
        IdentityImmediate.chainEnded() // Open on A
        val paused = kotlinx.coroutines.flow.MutableStateFlow(false)
        val release = kotlinx.coroutines.flow.MutableStateFlow(false)
        var once = true
        OwedProfilePull.beforeLockForTest = {
            if (once) {
                once = false
                paused.value = true
                spinUntil(5_000) { release.value }
            }
        }
        val stale = CoroutineScope(Dispatchers.Default).launch { OwedProfilePull.wake() } // woken by A's Open
        eventually { paused.value }
        IdentityRuntime.authSerial = { 1 }
        signInWindow("user-b") // B's window holds
        OwedProfilePull.owe(accountB)
        release.value = true
        stale.join()
        assertEquals(0, pulls)
        IdentityImmediate.chainEnded() // B opens
        eventually { pulls == 1 }
        delay(200)
        assertEquals(1, pulls, "B's debt survived the stale wake-up and was served once")
    }

    @Test
    fun alreadyOpenServesAtOnce() = real {
        signInWindow("user-a")
        IdentityImmediate.chainEnded()
        delay(100) // the watcher has nothing owed yet
        OwedProfilePull.owe(accountA)
        eventually { pulls == 1 }
    }
}
