package com.nuvio.app.features.tracking

import com.nuvio.app.features.library.LibrarySourceMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Ported from upstream `TrackingSourcesTest`, with Simkl swapped for Trakt (the only registered
 * provider in Phase 1). The load-bearing assertion for this port is the first one: profiles that
 * already stored `TRAKT` must keep resolving to Trakt after the enum moved packages.
 */
class TrackingSourcesTest {
    @Test
    fun `stored legacy source names retain their meaning`() {
        assertEquals(WatchProgressSource.TRAKT, WatchProgressSource.fromStorage("TRAKT"))
        assertEquals(WatchProgressSource.NUVIO_SYNC, WatchProgressSource.fromStorage("NUVIO_SYNC"))
        assertEquals(LibrarySourceMode.TRAKT, librarySourceModeFromStorage("TRAKT"))
        assertEquals(LibrarySourceMode.LOCAL, librarySourceModeFromStorage("LOCAL"))
    }

    @Test
    fun `unknown stored names fall back to the shipped defaults`() {
        assertEquals(DEFAULT_WATCH_PROGRESS_SOURCE, WatchProgressSource.fromStorage(null))
        assertEquals(DEFAULT_WATCH_PROGRESS_SOURCE, WatchProgressSource.fromStorage("SIMKL"))
        assertEquals(DEFAULT_LIBRARY_SOURCE_MODE, librarySourceModeFromStorage("SIMKL"))
    }

    @Test
    fun `remote watch source falls back when its provider is disconnected`() {
        assertEquals(
            WatchProgressSource.NUVIO_SYNC,
            effectiveWatchProgressSource(WatchProgressSource.TRAKT) { false },
        )
        assertEquals(
            WatchProgressSource.TRAKT,
            effectiveWatchProgressSource(WatchProgressSource.TRAKT) { it == TrackingProviderId.TRAKT },
        )
    }

    @Test
    fun `remote library source falls back to local when disconnected`() {
        assertEquals(
            LibrarySourceMode.LOCAL,
            effectiveLibrarySourceMode(LibrarySourceMode.TRAKT) { false },
        )
        assertEquals(
            LibrarySourceMode.TRAKT,
            effectiveLibrarySourceMode(LibrarySourceMode.TRAKT) { it == TrackingProviderId.TRAKT },
        )
    }

    @Test
    fun `local sources have no remote provider`() {
        assertNull(WatchProgressSource.NUVIO_SYNC.providerId)
        assertNull(LibrarySourceMode.LOCAL.providerId)
        assertEquals(TrackingProviderId.TRAKT, WatchProgressSource.TRAKT.providerId)
        assertEquals(TrackingProviderId.TRAKT, LibrarySourceMode.TRAKT.providerId)
    }

    @Test
    fun `provider ids parse from their storage form`() {
        assertEquals(TrackingProviderId.TRAKT, TrackingProviderId.fromStorage("trakt"))
        assertEquals(TrackingProviderId.TRAKT, TrackingProviderId.fromStorage("TRAKT"))
        assertNull(TrackingProviderId.fromStorage("nope"))
        assertNull(TrackingProviderId.fromStorage(null))
    }
}
