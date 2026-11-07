package com.nuvio.app.features.addons

import kotlinx.coroutines.Job
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AddonRefreshSupersedeTest {
    @Test
    fun aJobIsNotSupersededByItself() {
        val job = Job()
        assertFalse(isSupersededRefresh(registered = job, self = job))
        job.cancel()
    }

    @Test
    fun aJobIsSupersededWhenAnotherIsRegistered() {
        val old = Job()
        val replacement = Job()
        assertTrue(isSupersededRefresh(registered = replacement, self = old))
        old.cancel()
        replacement.cancel()
    }

    @Test
    fun anUnregisteredJobIsNotSuperseded() {
        val job = Job()
        assertFalse(isSupersededRefresh(registered = null, self = job))
        job.cancel()
    }
}
