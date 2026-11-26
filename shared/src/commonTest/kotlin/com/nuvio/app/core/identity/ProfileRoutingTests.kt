package com.nuvio.app.core.identity

import com.nuvio.app.features.profiles.NuvioProfile
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.profiles.ProfileStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/* W2 (spec 8.0.1, 8.1, 5.2, 5.3): the profile router, the guarded slot setter and launch restore. */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

/** Seeds ProfileRepository through the same path launch restore uses (inside the apply lock). */
internal fun seedProfiles(userId: String, active: Int, slots: List<Int>) {
    val profiles = slots.joinToString(",") { """{"profile_index":$it,"name":"P$it"}""" }
    ProfileStorage.savePayload("""{"userId":"$userId","activeProfileIndex":$active,"hasEverSelectedProfile":true,"profiles":[$profiles]}""")
    IdentityLocks.withApply { ProfileRepository.loadCachedProfiles() }
}

internal fun resetProfilesForTest() {
    ProfileIdentityRouterProvider.router = DefaultProfileIdentityRouter
    ProfileStorage.savePayload("")
    ProfileRepository.clearInMemory()
}

/** Records every port call with the commit depth it was made at. */
internal class FakeRouterPorts(private val log: EventLog) : BarrierRouterPorts {
    var active = 1
    var deleteResult: () -> TransitionResult = { TransitionResult.Done(IdentityRuntime.state.value) }
    val requestDepths = mutableListOf<Int>()

    override fun launchSelect(slot: Int) { log.add("launch select $slot") }

    override fun requestSlotRemoved(slot: Int, token: AccountToken) {
        requestDepths += IdentityLocks.commitDepth
        log.add("request removal $slot")
    }

    override suspend fun deleteActiveProfile(slot: Int, nextSlot: Int?, token: AccountToken): TransitionResult {
        log.add("delete active $slot next $nextSlot")
        return deleteResult()
    }

    override fun activeSlot(): Int = active

    override fun removeTrackers(slot: Int) { log.add("trackers $slot") }
}

class BootRestoreSlotTest {
    @BeforeTest fun setUp() {
        resetIdentityForTest(activeSlot = { ProfileRepository.activeProfileId })
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(EventLog()))
    }

    @AfterTest fun tearDown() {
        resetProfilesForTest()
        resetIdentityForTest()
    }

    @Test
    fun trustedCacheRestoresItsSlotWithNoRefusal() {
        seedProfiles("g", active = 3, slots = listOf(1, 3))
        IdentityRuntime.seedSlot(ProfileRepository.activeProfileId)
        assertEquals(3, ProfileRepository.activeProfileId)
        assertEquals(3, IdentityGate.state.value.scope.slot)
    }

    @Test
    fun restoreOutsideTheApplyLockIsRefused() {
        ProfileStorage.savePayload("""{"userId":"g","activeProfileIndex":3,"profiles":[{"profile_index":3}]}""")
        assertFailsWith<IllegalStateException> { ProfileRepository.loadCachedProfiles() }
        assertEquals(1, ProfileRepository.activeProfileId)
    }
}

class SlotWriteGuardTest {
    private val log = EventLog()

    @BeforeTest fun setUp() {
        resetIdentityForTest(activeSlot = { ProfileRepository.activeProfileId })
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(log))
        IdentityBarrier.profileOps = ProfileRepositoryOps
        seedProfiles("user-a", active = 1, slots = listOf(1, 2, 3))
    }

    @AfterTest fun tearDown() {
        resetProfilesForTest()
        resetIdentityForTest()
    }

    @Test
    fun changingWriteOutsideAnApplyBodyHitsTheGuard() {
        assertFailsWith<IllegalStateException> { ProfileRepository.applySelectionChecked(2) }
        assertEquals(1, ProfileRepository.activeProfileId)
        IdentityLocks.strictLockOrder = false // release builds: refused and logged, no throw
        ProfileRepository.applySelectionChecked(3)
        assertEquals(1, ProfileRepository.activeProfileId)
    }

    @Test
    fun sameValueWriteSkipsTheGuard() {
        ProfileRepository.applySelectionChecked(1)
        assertEquals(1, ProfileRepository.activeProfileId)
    }

    @Test
    fun writeInsideTheBarrierApplyIsAccepted() = real {
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        assertEquals(2, ProfileRepository.activeProfileId)
        assertEquals(2, IdentityGate.state.value.scope.slot)
    }

    @Test
    fun writeInsideAWindowIsAccepted() = real {
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(3))
        IdentityImmediate.accountWipe { ProfileRepository.clearInMemory() }
        IdentityImmediate.chainEnded()
        assertEquals(1, ProfileRepository.activeProfileId)
    }

    @Test
    fun legacySelectOnTvOsStartsABarrierSelectAndWritesNothing() {
        ProfileRepository.selectProfile(2)
        assertEquals(listOf("launch select 2"), log.all())
        assertEquals(1, ProfileRepository.activeProfileId)
    }
}

class ProfileTransitionRoutingTest {
    private val calls = EventLog()

    private inner class RecordingRouter : ProfileIdentityRouter by DefaultProfileIdentityRouter {
        override fun selectProfile(profileIndex: Int, applyNow: (Int) -> Unit) {
            calls.add("select $profileIndex")
            DefaultProfileIdentityRouter.selectProfile(profileIndex, applyNow)
        }

        override fun onActiveSlotMissing(missingSlot: Int, profiles: List<NuvioProfile>, token: AccountToken?): NuvioProfile? {
            calls.add("missing $missingSlot")
            return DefaultProfileIdentityRouter.onActiveSlotMissing(missingSlot, profiles, token)
        }

        override fun onSlotWrite(old: Int, new: Int): Boolean {
            calls.add("slot $old->$new")
            return true
        }
    }

    @BeforeTest fun setUp() {
        resetIdentityForTest()
        ProfileIdentityRouterProvider.router = RecordingRouter()
    }

    @AfterTest fun tearDown() {
        resetProfilesForTest()
        resetIdentityForTest()
    }

    @Test
    fun legacySelectGoesThroughTheRouterAndTheGuardedSetter() {
        ProfileRepository.selectProfile(2)
        assertEquals(listOf("select 2", "slot 1->2"), calls.all())
        assertEquals(2, ProfileRepository.activeProfileId)
    }

    @Test
    fun everySlotWriterGoesThroughTheSetter() {
        seedProfiles("g", active = 3, slots = listOf(1, 3)) // applyStoredPayload
        ProfileRepository.ensureLoaded("other") // a different owner: back to slot 1
        assertEquals(listOf("slot 1->3", "slot 3->1"), calls.all())
    }
}

class TvOsProfileIdentityRouterTest {
    private val log = EventLog()
    private val ports = FakeRouterPorts(log)
    private val router = BarrierProfileIdentityRouter(ports)

    @BeforeTest fun setUp() {
        resetIdentityForTest(serial = 1)
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountA, 1), latestAccount = accountA))
    }

    @AfterTest fun tearDown() = resetIdentityForTest()

    private fun tokenA() = AccountToken(accountA, 1)

    @Test
    fun selectLaunchesTheBarrierAndNeverAppliesInline() {
        var applied = false
        router.selectProfile(2) { applied = true }
        assertFalse(applied)
        assertEquals(listOf("launch select 2"), log.all())
    }

    @Test
    fun pullProfilesRequestsRemovalAfterCommit() {
        var depthInBlock = -1
        router.publishPulledProfiles(emptyList(), tokenA()) {
            depthInBlock = IdentityLocks.commitDepth
            log.add("published")
            3
        }
        assertTrue(depthInBlock > 0, "the publish runs inside the commit section")
        assertEquals(listOf("published", "request removal 3"), log.all())
        assertEquals(listOf(0), ports.requestDepths, "requestSlotRemoved only after the commit section ended")
    }

    @Test
    fun refusedPullPublishesAndRequestsNothing() {
        IdentityRuntime.authSerial = { 2 } // the session changed since the pull started
        router.publishPulledProfiles(emptyList(), tokenA()) { log.add("published"); 3 }
        router.publishPulledProfiles(emptyList(), null) { log.add("published"); 3 }
        assertEquals(emptyList(), log.all())
    }

    @Test
    fun pulledListUnderAnotherAccountIsNotPublished() {
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(accountB, 1), latestAccount = accountB))
        router.publishPulledProfiles(emptyList(), tokenA()) { log.add("published"); null }
        assertEquals(emptyList(), log.all())
    }

    @Test
    fun noMissingSlotRequestsNothing() {
        router.publishPulledProfiles(emptyList(), tokenA()) { log.add("published"); null }
        assertEquals(listOf("published"), log.all())
    }

    @Test
    fun activeSlotMissingIsPure() {
        assertNull(router.onActiveSlotMissing(2, listOf(NuvioProfile(profileIndex = 1)), tokenA()))
        assertEquals(emptyList(), log.all())
    }

    @Test
    fun deleteOfTheActiveProfileRemovesTrackersThenMovesTheProfile() = real {
        ports.active = 2
        router.afterProfileDeleted(2, listOf(NuvioProfile(profileIndex = 3), NuvioProfile(profileIndex = 1)), tokenA())
        assertEquals(listOf("trackers 2", "delete active 2 next 1"), log.all())
    }

    @Test
    fun deleteOfAnotherProfileStartsNoTransition() = real {
        ports.active = 1
        router.afterProfileDeleted(2, listOf(NuvioProfile(profileIndex = 1)), tokenA())
        assertEquals(listOf("trackers 2"), log.all())
    }

    /** Round 4 #1: an A delete whose RPC returns after B is published removes nothing of B's. */
    @Test
    fun deleteUnderAChangedAccountRemovesNothing() = real {
        ports.active = 2
        IdentityRuntime.setForTest(BarrierState.initial(2).copy(scope = IdentityScope(accountB, 2), latestAccount = accountB))
        router.afterProfileDeleted(2, emptyList(), tokenA())
        router.afterProfileDeleted(2, emptyList(), null)
        assertEquals(emptyList(), log.all())
    }

    @Test
    fun queuedRemovalWhoseSlotReappearedAppliesNothing() = real {
        val ops = installDriverFakes(log)
        IdentityBarrier.selectProfile(2)
        ops.listed = setOf(1, 2, 3) // the slot is listed again by the time the removal applies
        IdentityBarrier.requestSlotRemoved(2, AccountToken(accountA, 1))
        kotlinx.coroutines.delay(300)
        assertEquals(0, log.count("removed"))
        assertEquals(IdentityPhase.Open, IdentityGate.state.value.phase)
    }

    @Test
    fun queuedRemovalAcrossAnAccountChangeAppliesNothing() = real {
        val ops = installDriverFakes(log)
        IdentityBarrier.selectProfile(2)
        ops.listed = setOf(1, 3)
        IdentityImmediate.serialChanging() // a window holds, so the removal waits
        IdentityBarrier.requestSlotRemoved(2, AccountToken(accountA, 1))
        IdentityRuntime.authSerial = { 2 }
        IdentityImmediate.publishAuth(com.nuvio.app.core.auth.AuthState.Authenticated("user-b", null, isAnonymous = false)) { }
        IdentityImmediate.chainEnded()
        kotlinx.coroutines.delay(300)
        assertEquals(0, log.count("removed"))
        assertEquals(accountB, IdentityGate.state.value.scope.account)
    }
}

class DeleteTrackerRemovalIndependentTest {
    private val log = EventLog()
    private val ports = FakeRouterPorts(log).apply { active = 2 }
    private val router = BarrierProfileIdentityRouter(ports)
    private val tokenA = AccountToken(accountA, 1)

    @BeforeTest fun setUp() {
        resetIdentityForTest(serial = 1)
        IdentityRuntime.setForTest(BarrierState.initial(2).copy(scope = IdentityScope(accountA, 2), latestAccount = accountA))
    }

    @AfterTest fun tearDown() = resetIdentityForTest()

    private fun assertTrackersFirst() {
        assertEquals(listOf("trackers 2", "delete active 2 next 1"), log.all())
    }

    @Test
    fun teardownDeadlineFailure() = real {
        ports.deleteResult = { TransitionResult.Failed("teardown unconfirmed", IdentityRuntime.state.value) }
        router.afterProfileDeleted(2, listOf(NuvioProfile(profileIndex = 1)), tokenA)
        assertTrackersFirst()
    }

    @Test
    fun windowBeforeTheGatePreempts() = real {
        ports.deleteResult = { TransitionResult.Preempted(IdentityRuntime.state.value) }
        router.afterProfileDeleted(2, listOf(NuvioProfile(profileIndex = 1)), tokenA)
        assertTrackersFirst()
    }

    @Test
    fun throwingTransitionStillLeavesTrackersRemoved() = real {
        ports.deleteResult = { error("barrier threw") }
        router.afterProfileDeleted(2, listOf(NuvioProfile(profileIndex = 1)), tokenA)
        assertTrackersFirst()
    }
}
