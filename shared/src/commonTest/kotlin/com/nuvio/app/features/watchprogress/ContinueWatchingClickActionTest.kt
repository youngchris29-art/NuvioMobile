package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.cloud.CloudLibraryContentType
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Upstream 37e8a5c0e: Continue Watching On Select, the shared rule and the stored preference. */
class ContinueWatchingClickActionTest {
    @BeforeTest
    fun reset() {
        ContinueWatchingPreferencesStorage.savePayload("{}")
        ContinueWatchingPreferencesRepository.clearLocalState()
        ContinueWatchingPreferencesRepository.ensureLoaded()
    }

    @AfterTest
    fun cleanup() = reset()

    private fun item(isNextUp: Boolean, released: String?) = ContinueWatchingItem(
        parentMetaId = "tt1",
        parentMetaType = "series",
        videoId = "tt1:1:1",
        title = "Show",
        subtitle = "S1E1",
        imageUrl = null,
        released = released,
        isNextUp = isNextUp,
        resumePositionMs = 0,
        durationMs = 0,
        progressFraction = 0f,
    )

    private fun entry(
        source: String = WatchProgressSourceLocal,
        contentType: String = "series",
        parentMetaType: String = "series",
    ) = WatchProgressEntry(
        contentType = contentType,
        parentMetaId = "tt1",
        parentMetaType = parentMetaType,
        videoId = "tt1:1:1",
        title = "Show",
        lastPositionMs = 0,
        durationMs = 0,
        lastUpdatedEpochMs = 0,
        source = source,
    )

    @Test
    fun `continueWatchingClickActionOpensDetailsAsChosen`() {
        val now = parseReleaseDateToEpochMs("2026-07-19T12:00:00Z")!!
        val aired = item(isNextUp = true, released = "2026-07-19T11:59:59Z")
        val unknown = item(isNextUp = true, released = null)
        val upcoming = item(isNextUp = true, released = "2026-07-21T00:00:00Z")
        val inProgress = item(isNextUp = false, released = "2026-07-21T00:00:00Z")
        val all = listOf(aired, unknown, upcoming, inProgress)

        assertTrue(all.none { ContinueWatchingClickAction.STREAM.opensDetails(it, now) })
        assertTrue(all.all { ContinueWatchingClickAction.DETAILS.opensDetails(it, now) })
        assertEquals(
            listOf(upcoming),
            all.filter { ContinueWatchingClickAction.DETAILS_FOR_UPCOMING.opensDetails(it, now) },
        )
    }

    @Test
    fun `entryRuleKeepsCloudItemsPlaying`() {
        val now = 1_000L
        assertFalse(
            ContinueWatchingSelect.opensDetails(
                ContinueWatchingClickAction.DETAILS, entry(contentType = CloudLibraryContentType), null, now,
            ),
        )
        assertFalse(
            ContinueWatchingSelect.opensDetails(
                ContinueWatchingClickAction.DETAILS, entry(parentMetaType = CloudLibraryContentType), null, now,
            ),
        )
        assertTrue(
            ContinueWatchingSelect.opensDetails(ContinueWatchingClickAction.DETAILS, entry(), null, now),
        )
    }

    @Test
    fun `entryRuleOpensDetailsForAnUnairedUpNextOnly`() {
        val now = 1_000L
        val upNext = entry(source = WatchProgressSourceNextUp)
        val local = entry()
        val action = ContinueWatchingClickAction.DETAILS_FOR_UPCOMING

        assertTrue(ContinueWatchingSelect.opensDetails(action, upNext, now + 1, now))
        assertFalse(ContinueWatchingSelect.opensDetails(action, upNext, null, now))
        assertFalse(ContinueWatchingSelect.opensDetails(action, upNext, now - 1, now))
        assertFalse(ContinueWatchingSelect.opensDetails(action, local, now + 1, now))
        assertFalse(ContinueWatchingSelect.opensDetails(ContinueWatchingClickAction.STREAM, upNext, now + 1, now))
    }

    @Test
    fun `clickActionDefaultsToStreamAndPersists`() {
        assertEquals(
            ContinueWatchingClickAction.STREAM,
            ContinueWatchingPreferencesRepository.uiState.value.clickAction,
        )

        ContinueWatchingPreferencesRepository.setClickAction(ContinueWatchingClickAction.DETAILS)
        ContinueWatchingPreferencesRepository.clearLocalState()
        ContinueWatchingPreferencesRepository.ensureLoaded()

        assertEquals(
            ContinueWatchingClickAction.DETAILS,
            ContinueWatchingPreferencesRepository.uiState.value.clickAction,
        )
        assertTrue(ContinueWatchingPreferencesStorage.loadPayload().orEmpty().contains("\"click_action\":\"DETAILS\""))
    }

    @Test
    fun `aPayloadWithoutClickActionReadsAsStream`() {
        ContinueWatchingPreferencesStorage.savePayload("""{"sort_mode":"SPLIT_UPCOMING"}""")
        ContinueWatchingPreferencesRepository.clearLocalState()
        ContinueWatchingPreferencesRepository.ensureLoaded()

        val state = ContinueWatchingPreferencesRepository.uiState.value
        assertEquals(ContinueWatchingClickAction.STREAM, state.clickAction)
        assertEquals(ContinueWatchingSortMode.SPLIT_UPCOMING, state.sortMode)
    }

    @Test
    fun `settingTheSameActionAgainDoesNotPersist`() {
        ContinueWatchingPreferencesRepository.setClickAction(ContinueWatchingClickAction.DETAILS)
        val marker = """{"marker":true}"""
        ContinueWatchingPreferencesStorage.savePayload(marker)

        ContinueWatchingPreferencesRepository.setClickAction(ContinueWatchingClickAction.DETAILS)

        assertEquals(marker, ContinueWatchingPreferencesStorage.loadPayload())
    }

    @Test
    fun `anUnknownClickActionFallsBackWithoutLosingTheOtherFields`() {
        ContinueWatchingPreferencesStorage.savePayload(
            """{"click_action":"SOMETHING_NEW","dismissedNextUpKeys":["tt1"]}""",
        )
        ContinueWatchingPreferencesRepository.clearLocalState()
        ContinueWatchingPreferencesRepository.ensureLoaded()

        val state = ContinueWatchingPreferencesRepository.uiState.value
        assertEquals(ContinueWatchingClickAction.STREAM, state.clickAction)
        assertEquals(setOf("tt1"), state.dismissedNextUpKeys)
    }
}
