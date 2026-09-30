package com.nuvio.app.features.mdblist

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Fork-only: [MdbListAuthStore.reloadCurrentProfile], the recovery path after a failed read. */
class MdbListAuthStoreReloadTest {
    private class FlakyPersistence : MdbListAuthPersistence {
        val delegate = MdbListTestPersistence()
        var failReads = false
        override fun read(profileId: Int): String? =
            if (failReads) null else delegate.read(profileId)
        override fun write(profileId: Int, value: String?) = delegate.write(profileId, value)
        override fun clear() = delegate.clear()
    }

    @Test
    fun reloadPicksUpCredentialsThatWereUnreadableAtLoad() {
        val persistence = FlakyPersistence()
        val seed = MdbListAuthStore(persistence.delegate, 1)
        assertTrue(seed.authorize(MdbListTokens("access", "refresh", Long.MAX_VALUE), seed.scope()))

        persistence.failReads = true
        val store = MdbListAuthStore(persistence, 1)
        assertFalse(store.state.value.isAuthenticated)
        val generation = store.scope().generation

        persistence.failReads = false
        assertTrue(store.reloadCurrentProfile())
        assertTrue(store.state.value.isAuthenticated)
        assertEquals(generation + 1, store.scope().generation)
    }

    @Test
    fun reloadWithUnchangedCredentialsKeepsTheScope() {
        val store = MdbListAuthStore(MdbListTestPersistence(), 1)
        val scope = store.scope()
        assertFalse(store.reloadCurrentProfile())
        assertEquals(scope, store.scope())
    }
}
