package com.nuvio.app.core.identity

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.addons.AddonBootstrapRule
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
    @Test
    fun reserve() {
        assertEquals(BootstrapReserve.Skip, AddonBootstrapRule.reserve(initialized = true, generation = 4))
        assertEquals(BootstrapReserve.Reserve(4), AddonBootstrapRule.reserve(initialized = false, generation = 4))
    }

    @Test
    fun endEveryCase() {
        val g = 4L
        for (holder in listOf(null, g, 9L)) for (current in listOf(g, 9L)) for (token in listOf(true, false)) {
            val expected = when {
                holder != g -> BootstrapEnd.Nothing
                current == g && token -> BootstrapEnd.Publish
                else -> BootstrapEnd.Release
            }
            assertEquals(expected, AddonBootstrapRule.end(g, current, holder, token), "holder=$holder current=$current token=$token")
        }
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
