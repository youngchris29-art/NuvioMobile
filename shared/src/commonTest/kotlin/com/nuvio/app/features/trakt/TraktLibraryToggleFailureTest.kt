package com.nuvio.app.features.trakt

import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingLibraryTabKind
import com.nuvio.app.features.tracking.TrackingProviderId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Issue #17: the library + no longer fails silently on the Trakt path. */
class TraktLibraryToggleFailureTest {

    private val item = LibraryItem(id = "tt0111161", type = "movie", name = "The Shawshank Redemption")

    private val watchlistTab = TrackingLibraryTab(
        key = "trakt:watchlist",
        title = "Watchlist",
        providerId = TrackingProviderId.TRAKT,
        kind = TrackingLibraryTabKind.WATCHLIST,
    )
    private val personalTab = TrackingLibraryTab(
        key = "trakt:list:42",
        title = "Favourites",
        providerId = TrackingProviderId.TRAKT,
        kind = TrackingLibraryTabKind.PERSONAL,
    )

    // Exit 1: no token (signed out, or the refresh failed).

    @Test
    fun `applying membership without a token throws the sign-in error instead of returning`() = runTest {
        val previous = TraktLibraryRepository.authorizedHeadersSource
        TraktLibraryRepository.authorizedHeadersSource = { null }
        try {
            val error = assertFailsWith<TraktSessionExpiredException> {
                TraktLibraryRepository.applyMembershipChanges(
                    item = item,
                    changes = TraktMembershipChanges(desiredMembership = mapOf("trakt:watchlist" to true)),
                )
            }
            assertFalse(error is CancellationException, "the caller must see it, not drop it as a cancellation")
            assertTrue(error.message.orEmpty().contains("Trakt"), error.message)
            assertTrue(error.message.orEmpty().contains("Settings"), error.message)
        } finally {
            TraktLibraryRepository.authorizedHeadersSource = previous
        }
    }

    // Exit 2: the watchlist tab is not loaded.

    @Test
    fun `membership loads the list tabs when the watchlist tab is missing`() = runTest {
        var tabs = emptyList<TrackingLibraryTab>()
        var loads = 0
        val membership = traktMembershipWithListTabs(
            hasWatchlistTab = { tabs.any { it.kind == TrackingLibraryTabKind.WATCHLIST } },
            readMembership = { tabs.associate { it.key to false } },
            loadListTabs = {
                loads += 1
                tabs = listOf(watchlistTab, personalTab)
            },
        )
        assertEquals(1, loads)
        assertEquals(mapOf("trakt:watchlist" to false, "trakt:list:42" to false), membership)
    }

    @Test
    fun `membership does not reload when the watchlist tab is already there`() = runTest {
        var loads = 0
        val membership = traktMembershipWithListTabs(
            hasWatchlistTab = { true },
            readMembership = { mapOf("trakt:watchlist" to true) },
            loadListTabs = { loads += 1 },
        )
        assertEquals(0, loads)
        assertEquals(mapOf("trakt:watchlist" to true), membership)
    }

    @Test
    fun `ensureListTabs runs the loader and swallows its failure`() = runTest {
        val previous = TraktLibraryRepository.listTabsLoader
        var loads = 0
        TraktLibraryRepository.listTabsLoader = {
            loads += 1
            error("offline")
        }
        try {
            if (TraktLibraryRepository.currentListTabs().isEmpty()) {
                TraktLibraryRepository.ensureListTabs()
                assertEquals(1, loads)
            }
        } finally {
            TraktLibraryRepository.listTabsLoader = previous
        }
    }

    @Test
    fun `toggle without a watchlist tab fails loudly`() {
        assertFailsWith<TraktWatchlistUnavailableException> {
            toggledTraktDefaultMembership(emptyMap(), listOf(personalTab), isSignedIn = true)
        }
        assertFailsWith<TraktSessionExpiredException> {
            toggledTraktDefaultMembership(emptyMap(), emptyList(), isSignedIn = false)
        }
    }

    @Test
    fun `toggle with a watchlist tab flips only the watchlist`() {
        val toggled = toggledTraktDefaultMembership(
            currentMembership = mapOf("trakt:watchlist" to false, "trakt:list:42" to true),
            tabs = listOf(watchlistTab, personalTab),
            isSignedIn = true,
        )
        assertEquals(mapOf("trakt:watchlist" to true, "trakt:list:42" to true), toggled)
    }

    @Test
    fun `missing ids message says the title has no IMDb or TMDB id`() {
        val message = traktMissingIdsMessage()
        assertTrue(message.contains("IMDb") && message.contains("TMDB"), message)
    }
}
