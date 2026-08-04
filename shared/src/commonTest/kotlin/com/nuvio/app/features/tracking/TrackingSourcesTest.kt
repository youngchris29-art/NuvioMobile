package com.nuvio.app.features.tracking

import com.nuvio.app.features.library.LibrarySourceMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Ported from upstream `TrackingSourcesTest`, widened to cover both registered providers. The
 * load-bearing assertion for this port is the first one: profiles that already stored `TRAKT` or
 * `SIMKL` must keep resolving to the same provider after the enums moved packages.
 */
class TrackingSourcesTest {
    @Test
    fun `stored legacy source names retain their meaning`() {
        assertEquals(WatchProgressSource.TRAKT, WatchProgressSource.fromStorage("TRAKT"))
        assertEquals(WatchProgressSource.SIMKL, WatchProgressSource.fromStorage("SIMKL"))
        assertEquals(WatchProgressSource.NUVIO_SYNC, WatchProgressSource.fromStorage("NUVIO_SYNC"))
        assertEquals(LibrarySourceMode.TRAKT, librarySourceModeFromStorage("TRAKT"))
        assertEquals(LibrarySourceMode.SIMKL, librarySourceModeFromStorage("SIMKL"))
        assertEquals(LibrarySourceMode.LOCAL, librarySourceModeFromStorage("LOCAL"))
    }

    @Test
    fun `unknown stored names fall back to the shipped defaults`() {
        assertEquals(DEFAULT_WATCH_PROGRESS_SOURCE, WatchProgressSource.fromStorage(null))
        assertEquals(DEFAULT_WATCH_PROGRESS_SOURCE, WatchProgressSource.fromStorage("not-a-source"))
        assertEquals(DEFAULT_LIBRARY_SOURCE_MODE, librarySourceModeFromStorage(null))
        assertEquals(DEFAULT_LIBRARY_SOURCE_MODE, librarySourceModeFromStorage("not-a-source"))
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
        assertEquals(
            WatchProgressSource.NUVIO_SYNC,
            effectiveWatchProgressSource(WatchProgressSource.SIMKL) { false },
        )
        assertEquals(
            WatchProgressSource.SIMKL,
            effectiveWatchProgressSource(WatchProgressSource.SIMKL) { it == TrackingProviderId.SIMKL },
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
        assertEquals(
            LibrarySourceMode.LOCAL,
            effectiveLibrarySourceMode(LibrarySourceMode.SIMKL) { false },
        )
        assertEquals(
            LibrarySourceMode.SIMKL,
            effectiveLibrarySourceMode(LibrarySourceMode.SIMKL) { it == TrackingProviderId.SIMKL },
        )
    }

    @Test
    fun `local sources have no remote provider`() {
        assertNull(WatchProgressSource.NUVIO_SYNC.providerId)
        assertNull(LibrarySourceMode.LOCAL.providerId)
        assertEquals(TrackingProviderId.TRAKT, WatchProgressSource.TRAKT.providerId)
        assertEquals(TrackingProviderId.TRAKT, LibrarySourceMode.TRAKT.providerId)
        assertEquals(TrackingProviderId.SIMKL, WatchProgressSource.SIMKL.providerId)
        assertEquals(TrackingProviderId.SIMKL, LibrarySourceMode.SIMKL.providerId)
    }

    @Test
    fun `provider ids parse from their storage form`() {
        assertEquals(TrackingProviderId.TRAKT, TrackingProviderId.fromStorage("trakt"))
        assertEquals(TrackingProviderId.TRAKT, TrackingProviderId.fromStorage("TRAKT"))
        assertEquals(TrackingProviderId.SIMKL, TrackingProviderId.fromStorage("simkl"))
        assertEquals(TrackingProviderId.SIMKL, TrackingProviderId.fromStorage("SIMKL"))
        assertNull(TrackingProviderId.fromStorage("nope"))
        assertNull(TrackingProviderId.fromStorage(null))
    }
}
