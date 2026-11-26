package com.nuvio.app.core.identity

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.addons.AddonBootstrapRule
import com.nuvio.app.features.addons.BootstrapKey
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.AddonStorage
import com.nuvio.app.features.addons.BootstrapEnd
import com.nuvio.app.features.addons.BootstrapReserve
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
import kotlin.test.assertIs
import kotlin.test.assertTrue

/* W2 review r1 #1 and #2: the add-on bootstrap's slot source and its reservation rule. */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

class AddonBootstrapRuleTest {
    private val k = { id: Long, gen: Long -> BootstrapKey(id, gen) }

    @Test
    fun reserveEveryCase() {
        val current = k(2, 1)
        val keys = listOf(null, k(1, 1), current, k(2, 0))
        for (completed in keys) for (holder in keys) {
            val expected = if (completed == current || holder == current) BootstrapReserve.Skip else BootstrapReserve.Reserve(current)
            assertEquals(expected, AddonBootstrapRule.reserve(completed, holder, current), "completed=$completed holder=$holder")
        }
    }

    @Test
    fun endEveryCase() {
        val reserved = k(2, 1)
        val keys = listOf(null, reserved, k(3, 1), k(3, 2))
        for (holder in keys) for (current in listOf(reserved, k(3, 1), k(3, 2))) for (completed in keys) for (token in listOf(true, false)) {
            val expected = when {
                holder != reserved -> BootstrapEnd.Nothing
                current == reserved && token -> BootstrapEnd.Publish
                else -> BootstrapEnd.Release(resetMirror = completed?.profileGeneration != current.profileGeneration)
            }
            assertEquals(expected, AddonBootstrapRule.end(reserved, current, holder, completed, token), "holder=$holder current=$current completed=$completed token=$token")
        }
    }

    /** The rule's state as AddonRepository holds it, plus the bootstraps still running and the current key. */
    private data class Model(val completed: BootstrapKey?, val holder: BootstrapKey?, val inFlight: Set<BootstrapKey>, val current: BootstrapKey)

    private fun events(m: Model): List<Pair<String, Model>> = buildList {
        // initialize(): reserve under the current key.
        when (val r = AddonBootstrapRule.reserve(m.completed, m.holder, m.current)) {
            BootstrapReserve.Skip -> add("initialize (skip)" to m)
            is BootstrapReserve.Reserve -> add("initialize" to m.copy(holder = r.key, inFlight = m.inFlight + r.key))
        }
        // A running bootstrap ends: its token holds only if its key is still the current one
        // (publish accepted), else it is rejected (publish rejected / release).
        for (r in m.inFlight) {
            val next = when (AddonBootstrapRule.end(r, m.current, m.holder, m.completed, tokenHolds = r == m.current)) {
                BootstrapEnd.Publish -> m.copy(completed = r, holder = null)
                is BootstrapEnd.Release -> m.copy(holder = null)
                BootstrapEnd.Nothing -> m
            }
            add("end $r" to next.copy(inFlight = next.inFlight - r))
        }
        val c = m.current
        // A same-slot select: the identity moves, onProfileChanged keeps the list (early return).
        add("transition same slot" to m.copy(current = BootstrapKey(c.identityEpoch + 1, c.profileGeneration)))
        // Another slot: onProfileChanged bumps the generation and resets.
        add("transition other slot" to m.copy(current = BootstrapKey(c.identityEpoch + 1, c.profileGeneration + 1), completed = null, holder = null))
        // An account wipe: clearLocalState resets; the account change moves the identity too.
        add("reset" to m.copy(current = BootstrapKey(c.identityEpoch + 1, c.profileGeneration + 1), completed = null, holder = null))
    }

    private fun live(m: Model): Boolean =
        m.completed == m.current ||
            (m.holder == m.current && m.current in m.inFlight) ||
            AddonBootstrapRule.reserve(m.completed, m.holder, m.current) is BootstrapReserve.Reserve

    /** Liveness over every state reachable in 7 events from a fresh repository, every event in each. */
    @Test
    fun livenessOverTheFullEnumeration() {
        var frontier = setOf(Model(null, null, emptySet(), BootstrapKey(0, 0)))
        val seen = frontier.toMutableSet()
        repeat(7) {
            val next = mutableSetOf<Model>()
            for (m in frontier) for ((event, after) in events(m)) {
                assertTrue(live(after), "not live after '$event' from $m: $after")
                // No state where the only reservation is one that will be rejected.
                if (after.holder != null && after.holder != after.current) {
                    assertTrue(AddonBootstrapRule.reserve(after.completed, after.holder, after.current) is BootstrapReserve.Reserve || after.completed == after.current, "stale holder blocks: $after")
                }
                if (seen.add(after)) next += after
            }
            frontier = next
        }
        assertTrue(seen.size > 50, "the enumeration reached ${seen.size} states")
    }
}

/** r3: hook load for slot 1 in flight → select slot 1 → Home initialize() before the stale load resumes. */
class SameSlotBootstrapInterleavingTest {
    private val log = EventLog()
    private val paused = MutableStateFlow(false)
    private val release = MutableStateFlow(false)

    @BeforeTest fun setUp() {
        installDriverFakes(log)
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(EventLog()))
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
        ProfileIdentityRouterProvider.router = DefaultProfileIdentityRouter
        resetIdentityForTest()
    }

    @Test
    fun theNewIdentityBootstrapsAndTheStaleOneChangesNothing() = real {
        val hook = CoroutineScope(Dispatchers.Default).launch { AddonRepository.initialize() } // the account-open hook, slot 1
        eventually { paused.value }
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(1)) // the same slot: a new identity epoch
        AddonRepository.onProfileChanged(1) // the fan-out's addons step (same profile: no reset)
        AddonRepository.initialize() // Home
        assertTrue(AddonRepository.initializedState.value, "the new identity's bootstrap ran and published")
        assertTrue(AddonRepository.uiState.value.isInitialized)
        release.value = true
        hook.join()
        assertTrue(AddonRepository.initializedState.value, "the stale load's end did not disturb the new bootstrap")
        assertEquals(1, AddonRepository.currentProfileIdForTest)
    }
}

/** #2: A pauses after its reservation; B switches and completes; A resumes and changes nothing. */
class StaleBootstrapInterleavingTest {
    private val log = EventLog()
    private val paused = MutableStateFlow(false)
    private val release = MutableStateFlow(false)

    @BeforeTest fun setUp() {
        installDriverFakes(log)
        ProfileIdentityRouterProvider.router = BarrierProfileIdentityRouter(FakeRouterPorts(EventLog()))
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
        ProfileIdentityRouterProvider.router = DefaultProfileIdentityRouter
        resetIdentityForTest()
    }

    @Test
    fun newerBootstrapSurvivesAStaleOne() = real {
        val a = CoroutineScope(Dispatchers.Default).launch { AddonRepository.initialize() } // slot 1
        eventually { paused.value }
        assertIs<TransitionResult.Done>(IdentityBarrier.selectProfile(2))
        AddonRepository.onProfileChanged(2) // the fan-out's addons step
        AddonRepository.initialize() // B, under slot 2
        assertTrue(AddonRepository.initializedState.value)
        assertEquals(2, AddonRepository.currentProfileIdForTest)
        release.value = true
        a.join()
        assertTrue(AddonRepository.initializedState.value, "A's end must not undo B's completed bootstrap")
        assertEquals(2, AddonRepository.currentProfileIdForTest, "A must not write its profile id")
    }
}

/** #1: on the default (mobile) router the slot is the active profile; load and persist follow a switch. */
class DefaultRouterAddonSlotTest {
    private var active = 1

    @BeforeTest fun setUp() {
        resetIdentityForTest()
        ProfileIdentityRouterProvider.router = DefaultProfileIdentityRouter
        ActiveProfileProvider.provider = ActiveProfileIdProvider { active }
        AddonRepository.clearLocalState()
        AddonStorage.saveInstalledAddonUrls(1, listOf("https://one.test/manifest.json"))
        AddonStorage.saveAddonEnabledStates(1, mapOf("https://one.test/manifest.json" to false))
        AddonStorage.saveInstalledAddonUrls(2, listOf("https://a.test/manifest.json", "https://b.test/manifest.json"))
        AddonStorage.saveAddonEnabledStates(2, mapOf("https://a.test/manifest.json" to false, "https://b.test/manifest.json" to false))
    }

    @AfterTest fun tearDown() {
        AddonRepository.clearLocalState()
        listOf(1, 2).forEach { AddonStorage.saveInstalledAddonUrls(it, emptyList()); AddonStorage.saveAddonEnabledStates(it, emptyMap()) }
        ActiveProfileProvider.provider = ActiveProfileIdProvider { 1 }
        resetIdentityForTest()
    }

    @Test
    fun profileSwitchLoadsAndPersistsUnderTheActiveProfile() {
        AddonRepository.initialize()
        assertEquals(listOf("https://one.test/manifest.json"), AddonRepository.uiState.value.addons.map { it.manifestUrl })

        active = 2 // a mobile switch: no barrier moves the identity's slot (it stays 1)
        AddonRepository.onProfileChanged(2)
        AddonRepository.initialize()
        assertEquals(1, IdentityGate.state.value.scope.slot)
        assertEquals(listOf("https://a.test/manifest.json", "https://b.test/manifest.json"), AddonRepository.uiState.value.addons.map { it.manifestUrl })

        AddonRepository.moveAddon(0, 1)
        assertEquals(listOf("https://b.test/manifest.json", "https://a.test/manifest.json"), AddonStorage.loadInstalledAddonUrls(2))
        assertEquals(listOf("https://one.test/manifest.json"), AddonStorage.loadInstalledAddonUrls(1), "profile 1's storage untouched")
    }
}
