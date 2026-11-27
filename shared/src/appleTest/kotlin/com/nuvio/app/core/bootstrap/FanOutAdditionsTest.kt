package com.nuvio.app.core.bootstrap

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/*
 * Scope identity W3b (spec 9.1.4, 9.1.5): the seven fan-out additions run in order, after
 * debridSettings and before profileSettingsSync (which stays last), and each is must-succeed.
 * Step bodies are replaced (TvOsProfileLifecycleCoordinator.stepBodyForTest): only the order and
 * the failure report are under test.
 */
class FanOutAdditionsTest {
    private val additions = listOf(
        "cloudLibrary", "streams", "playerStreams", "streamSearchSessions", "metaDetails", "subtitles", "launchStores",
    )

    @AfterTest fun tearDown() {
        TvOsProfileLifecycleCoordinator.stepBodyForTest = null
    }

    private fun run(throwIn: String? = null): Pair<List<String>, List<String>> {
        val ran = mutableListOf<String>()
        TvOsProfileLifecycleCoordinator.stepBodyForTest = { name ->
            ran += name
            if (name == throwIn) error("step $name failed")
        }
        val failed = TvOsProfileLifecycleCoordinator.onProfileSelectedChecked(3)
        return ran to failed
    }

    @Test
    fun theAdditionsRunInOrderBeforeTheSettingsSync() {
        val (ran, failed) = run()
        assertEquals(emptyList(), failed)
        val debrid = ran.indexOf("debridSettings")
        assertTrue(debrid >= 0)
        assertEquals(listOf("debridSettings") + additions + "profileSettingsSync", ran.subList(debrid, ran.size))
        assertEquals("profileSettingsSync", ran.last())
    }

    @Test
    fun aThrowFromAnyAdditionIsReportedMustSucceed() {
        for (step in additions) {
            val (ran, failed) = run(throwIn = step)
            assertEquals(listOf(step), failed, "a throw in $step is a must-succeed failure")
            assertEquals("profileSettingsSync", ran.last(), "every step still runs after $step threw")
        }
    }
}
