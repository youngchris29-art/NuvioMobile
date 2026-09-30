package com.nuvio.app.features.profiles

import com.nuvio.app.features.tracking.TrackingProfileStore
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * `ProfileRepository.deleteProfile` must erase the deleted slot's locally stored tracker data:
 * slots are reused, and a new profile in the same slot otherwise inherits the previous person's
 * connected Trakt/Simkl/MDBList accounts. The Supabase/anonymous branches of `deleteProfile`
 * are not reachable from a unit test (singleton AuthRepository + Supabase client), so this pins
 * the cleanup step both branches call.
 */
class ProfileDeleteTrackerCleanupTest {

    private class RecordingStore : TrackingProfileStore {
        override val providerId = TrackingProviderId.MDBLIST
        val removed = mutableListOf<Int>()
        var failRemovals = false

        override fun onProfileChanged() = Unit
        override fun clearLocalState() = Unit
        override fun removeStoredProfile(profileId: Int) {
            if (failRemovals) error("simulated storage failure")
            removed += profileId
        }
    }

    // The registry is a process-wide singleton with no unregister; one inert store per suite.
    private companion object {
        val sharedStore = RecordingStore().also(TrackingProviderRegistry::registerProfileStore)
    }

    // Instance field so the companion (and its registration) initialises BEFORE any test body
    // calls into the registry.
    private val store = sharedStore

    @AfterTest
    fun reset() {
        store.failRemovals = false
        store.removed.clear()
    }

    @Test
    fun deletedProfileSlotIsRemovedFromEveryRegisteredTrackerStore() {
        ProfileRepository.removeDeletedProfileTrackerData(6)

        assertEquals(listOf(6), store.removed)
    }

    @Test
    fun aFailingTrackerStoreDoesNotEscapeTheDelete() {
        store.failRemovals = true

        ProfileRepository.removeDeletedProfileTrackerData(5)

        assertEquals(emptyList<Int>(), store.removed)
    }
}
