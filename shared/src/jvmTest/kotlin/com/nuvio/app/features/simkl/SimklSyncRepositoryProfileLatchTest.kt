package com.nuvio.app.features.simkl

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.TrackingExternalIds
import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMediaReference
import com.nuvio.app.features.tracking.TrackingMutationResult
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The load latch is per profile: a profile that became active without onProfileChanged loads its own file. */
class SimklSyncRepositoryProfileLatchTest {
    private var originalProfileProvider = ActiveProfileProvider.provider

    private fun addToWatchlist() = SimklMutationReceipt(
        TrackingMutationResult(attemptedCount = 1),
        SimklCommittedMutation.MoveToList(
            listOf(
                SimklResolvedListMutation(
                    request = TrackingMediaReference(
                        TrackingMediaKind.MOVIE, "Watchlist movie", ids = TrackingExternalIds(imdb = "tt7654321"),
                    ),
                    status = SimklListStatus.entries.first(),
                    responseMedia = SimklMedia(title = "Watchlist movie", ids = mapOf("imdb" to JsonPrimitive("tt7654321"))),
                ),
            ),
        ),
    )

    private fun wipe(profile: Int) {
        ProfileRepository.selectProfile(profile)
        SimklSyncRepository.clearLocalState()
    }

    @BeforeTest
    fun install() {
        originalProfileProvider = ActiveProfileProvider.provider
        ActiveProfileProvider.provider = ActiveProfileIdProvider { ProfileRepository.activeProfileId }
        wipe(3)
        wipe(1)
    }

    @AfterTest
    fun restore() {
        wipe(3)
        wipe(1)
        ProfileRepository.clearInMemory()
        ActiveProfileProvider.provider = originalProfileProvider
    }

    @Test
    fun `a profile that became active without onProfileChanged loads its own stored snapshot`() = runBlocking {
        // Profile 3 has a stored snapshot with one entry.
        ProfileRepository.selectProfile(3)
        SimklSyncRepository.onProfileChanged()
        SimklSyncRepository.commitMutation(addToWatchlist())
        assertEquals(1, SimklSyncRepository.state.value.snapshot.entries.size, "seeded profile 3")

        // Boot-time load under the default profile 1 (no file).
        ProfileRepository.selectProfile(1)
        SimklSyncRepository.onProfileChanged()
        assertEquals(0, SimklSyncRepository.state.value.snapshot.entries.size, "profile 1 has nothing")

        // Profile 3 becomes active WITHOUT onProfileChanged (restore / skipped fan-out), then a reader asks.
        ProfileRepository.selectProfile(3)
        SimklSyncRepository.ensureLoaded()
        val loaded = SimklSyncRepository.state.value
        assertTrue(loaded.hasLoaded, "loaded")
        assertEquals(1, loaded.snapshot.entries.size, "profile 3's stored entry is in memory")

        // Already loaded for 3: a second call is a no-op.
        SimklSyncRepository.ensureLoaded()
        assertSame(loaded, SimklSyncRepository.state.value, "no reload when the latch matches")
    }
}
