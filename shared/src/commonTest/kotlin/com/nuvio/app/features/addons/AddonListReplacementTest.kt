package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Review whole-stage r1: a replacement of the whole list (a pull, `initialize`, a Remote Setup
 * edit) detaches the departed URLs' jobs and health in the same step. Pure reductions over
 * [detachedByListChange]; the repository applies the result under its job lock.
 */
class AddonListReplacementTest {
    private val u = "https://u.example/manifest.json"
    private val v = "https://v.example/manifest.json"

    private fun addon(url: String) = ManagedAddon(manifestUrl = url)

    @Test
    fun aDepartedUrlsJobAndHealthAreDetached() {
        val detach = detachedByListChange(listOf(addon(u), addon(v)), listOf(addon(v)), setOf(u, v))
        assertEquals(setOf(u), detach.jobUrls)
        assertEquals(setOf(u), detach.healthUrls)
    }

    @Test
    fun aKeptUrlKeepsItsJob() {
        val detach = detachedByListChange(listOf(addon(u), addon(v)), listOf(addon(v), addon(u)), setOf(u, v))
        assertTrue(detach.jobUrls.isEmpty())
        assertTrue(detach.healthUrls.isEmpty())
    }

    @Test
    fun aUrlWithNoJobDetachesNothingButStillLosesHealth() {
        val detach = detachedByListChange(listOf(addon(u)), emptyList(), emptySet())
        assertTrue(detach.jobUrls.isEmpty())
        assertEquals(setOf(u), detach.healthUrls)
    }

    @Test
    fun anAddedUrlDetachesNothing() {
        val detach = detachedByListChange(listOf(addon(v)), listOf(addon(v), addon(u)), setOf(v))
        assertTrue(detach.jobUrls.isEmpty())
        assertTrue(detach.healthUrls.isEmpty())
    }

    @Test
    fun emptyListsDetachNothing() {
        val detach = detachedByListChange(emptyList(), emptyList(), emptySet())
        assertTrue(detach.jobUrls.isEmpty())
        assertTrue(detach.healthUrls.isEmpty())
    }

    /** A job registered for a URL that is in neither list (a stale entry) is detached too. */
    @Test
    fun aStrayJobForAnUnlistedUrlIsDetached() {
        val detach = detachedByListChange(listOf(addon(v)), listOf(addon(v)), setOf(u, v))
        assertEquals(setOf(u), detach.jobUrls)
        assertTrue(detach.healthUrls.isEmpty())
    }

    /**
     * The finding: a pull removes U, another restores it before the watcher ran. Replay with the job
     * map and generations as the repository keeps them. After the removal U holds no job and no
     * generation, so `refreshAddon` finds no active job and can start (and a new generation is current).
     */
    @Test
    fun aRestoreBeforeTheWatcherLetsANewRefreshStart() {
        val jobs = mutableMapOf(u to "job-1", v to "job-2")
        var generations = mapOf(u to 7L, v to 8L)
        var list = listOf(addon(u), addon(v))

        // Pull A removes U.
        val removed = listOf(addon(v))
        val detach = detachedByListChange(list, removed, jobs.keys)
        detach.jobUrls.forEach(jobs::remove)
        generations = generationsForList(generations, removed)
        list = removed
        assertFalse(u in jobs, "the old job no longer blocks a refresh of U")
        assertFalse(isCurrentRefreshGeneration(generations, u, 7L), "and it cannot publish")

        // Pull B restores U before any watcher cleanup: nothing registered for U, so a refresh may start.
        val restored = listOf(addon(v), addon(u))
        val second = detachedByListChange(list, restored, jobs.keys)
        assertTrue(second.jobUrls.isEmpty())
        assertTrue(u !in jobs)
        generations = withRefreshGeneration(generations, u, 9L)
        assertTrue(isCurrentRefreshGeneration(generations, u, 9L))
        assertEquals("job-2", jobs[v], "the kept add-on's job was never touched")
    }
}
