package com.nuvio.app.core.identity

import com.nuvio.app.features.profiles.ProfileLifecycleCoordinator
import com.nuvio.app.features.profiles.ProfileLifecycleProvider
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.TimeSource

/* W2 (spec 8.0.2, 8.0.5): the checked profile apply and the apply dispatcher. */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

/** A fan-out with the real step runner: [steps] in order, each (name, best-effort, throws?). */
private class FakeFanOut(var steps: List<Triple<String, Boolean, Boolean>>) : ProfileLifecycleCoordinator {
    val ran = mutableListOf<String>()
    override fun onProfileSelected(profileIndex: Int) { onProfileSelectedChecked(profileIndex) }
    override fun onProfileSelectedChecked(profileIndex: Int): List<String> {
        val fanOut = CheckedFanOut { _, _, _ -> }
        for ((name, bestEffort, throws) in steps) {
            fanOut.step(name, bestEffort) {
                ran += name
                if (throws) error("$name failed")
            }
        }
        return fanOut.failedSteps
    }
    override fun onProfilesCached() {}
}

class CheckedProfileApplyTest {
    private val originalCoordinator = ProfileLifecycleProvider.coordinator

    @BeforeTest fun setUp() {
        resetIdentityForTest(serial = 1, activeSlot = { ProfileRepository.activeProfileId })
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(EventLog()))
        IdentityBarrier.profileOps = ProfileRepositoryOps
        seedProfiles("user-a", active = 1, slots = listOf(1, 2, 3))
    }

    @AfterTest fun tearDown() {
        ProfileLifecycleProvider.coordinator = originalCoordinator
        resetProfilesForTest()
        resetIdentityForTest()
    }

    @Test
    fun fanOutFailureAfterSlotChangeEntersRecovery() = real {
        val fanOut = FakeFanOut(listOf(Triple("watched", false, true), Triple("addons", false, false)))
        ProfileLifecycleProvider.coordinator = fanOut
        val failed = assertIs<TransitionResult.Failed>(IdentityBarrier.selectProfile(2))
        assertTrue("watched" in failed.error)
        assertEquals(listOf("watched", "addons"), fanOut.ran, "every step runs whatever the others did")
        assertEquals(2, ProfileRepository.activeProfileId, "the slot had changed before the step failed")
        assertIs<IdentityPhase.Recovery>(failed.final.phase)
        assertEquals(RecoveryReason.FailedApply, failed.final.recovery)
        assertNull(IdentityGate.currentToken())

        fanOut.steps = listOf(Triple("watched", false, false))
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(3))
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
        assertNotNull(IdentityGate.currentToken())
        assertEquals(3, IdentityGate.state.value.scope.slot)
    }

    @Test
    fun bestEffortStepFailureStillOpens() = real {
        val fanOut = FakeFanOut(listOf(Triple("watched", false, false), Triple("downloads", true, true), Triple("profileSettingsSync", false, false)))
        ProfileLifecycleProvider.coordinator = fanOut
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(listOf("watched", "downloads", "profileSettingsSync"), fanOut.ran)
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
        assertEquals(2, IdentityGate.state.value.scope.slot)
    }

    @Test
    fun legacySelectStillSwallows() {
        ProfileIdentityRouterProvider.router = DefaultProfileIdentityRouter
        ProfileLifecycleProvider.coordinator = object : ProfileLifecycleCoordinator {
            override fun onProfileSelected(profileIndex: Int) = error("simulated repository failure")
            override fun onProfilesCached() {}
        }
        ProfileRepository.selectProfile(3)
        assertEquals(3, ProfileRepository.activeProfileId)
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase, "the legacy path never touches the barrier")
    }

    @Test
    fun defaultCheckedMemberReportsNothing() {
        var ran = 0
        val legacy = object : ProfileLifecycleCoordinator {
            override fun onProfileSelected(profileIndex: Int) { ran++ }
            override fun onProfilesCached() {}
        }
        assertEquals(emptyList(), legacy.onProfileSelectedChecked(2))
        assertEquals(1, ran)
    }
}

class CheckedFanOutTest {
    @Test
    fun mustSucceedFailuresAreReportedBestEffortOnesAreNot() {
        val reported = mutableListOf<String>()
        val fanOut = CheckedFanOut { name, bestEffort, _ -> reported += "$name:$bestEffort" }
        fanOut.step("a") { error("a") }
        fanOut.step("b", bestEffort = true) { error("b") }
        fanOut.step("c") {}
        assertEquals(listOf("a"), fanOut.failedSteps)
        assertEquals(listOf("a:false", "b:true"), reported)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ApplyDispatcherTest {
    private val log = EventLog()

    @BeforeTest fun setUp() { installDriverFakes(log, deadlineMs = 2_000) }

    @AfterTest fun tearDown() = resetIdentityForTest()

    /**
     * 8.0.5: a window body holds the apply lock for 1 s while a select's apply body waits for that
     * lock. With tvOS's apply dispatcher (Default) the "main" probe keeps running every 10 ms.
     * ("Main" is a one-thread view of Default: commonTest has no Main dispatcher.)
     */
    @Test
    fun profileApplyRacingStalledWindowBodyKeepsMainFree() = real {
        val main = Dispatchers.Default.limitedParallelism(1)
        IdentityBarrier.applyDispatcher = Dispatchers.Default // what TvOsProviderInstaller sets
        val inWindowBody = MutableStateFlow(false)
        val ticks = MutableStateFlow(0)
        var windowOpened = false
        IdentityBarrier.beforeApplyLock = {
            if (!windowOpened) {
                windowOpened = true
                CoroutineScope(Dispatchers.Default).launch {
                    IdentityImmediate.accountWipe {
                        inWindowBody.value = true
                        // Ordering, not timing: the body (holding the apply lock) ends only after
                        // the "main" probe ran 5 more times; were main blocked on the apply lock,
                        // this would never happen (spinUntil's 30 s is a hang guard, not a margin).
                        val ticksAtStart = ticks.value
                        spinUntil(30_000) { ticks.value >= ticksAtStart + 5 }
                    }
                    IdentityImmediate.chainEnded()
                }
                spinUntil { inWindowBody.value }
            }
        }
        val probe = launch(main) {
            while (isActive) {
                delay(10)
                ticks.value += 1
            }
        }
        val select = async { IdentityBarrier.selectProfile(2) }
        val result = select.await()
        probe.cancel()
        // The window opened after the drain ended and before the apply lock: nothing applied (B6).
        assertIs<TransitionResult.Preempted>(result)
        assertEquals(0, log.count("apply 2"))
        // After the window, a select applies.
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(1, log.count("apply 2"))
    }
}
