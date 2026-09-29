package com.nuvio.app.features.details

import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Port of upstream `6fb46976`'s `RatingsSettingsTest` (Robolectric `androidHostTest`) to a
 * platform-neutral `commonTest`. The other-profile case is dropped: it needs the Android
 * SharedPreferences handle directly. Payload keys (`show_overall_ratings`,
 * `episode_ratings_visibility`, `poster_transition_enabled`) must match upstream so a mobile
 * user's choice survives a tvOS re-persist.
 */
class RatingsSettingsTest {
    @BeforeTest
    fun initialize() {
        MetaScreenSettingsStorage.savePayload("")
        MetaScreenSettingsRepository.clearLocalState()
    }

    @AfterTest
    fun clearState() {
        MetaScreenSettingsStorage.savePayload("")
        MetaScreenSettingsRepository.clearLocalState()
    }

    @Test
    fun choicesPersistIndependentlyAndRoundTripThroughTheProfilePayload() {
        MetaScreenSettingsRepository.setShowOverallRatings(false)
        MetaScreenSettingsRepository.setEpisodeRatingsVisibility(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES)
        val payload = MetaScreenSettingsStorage.loadPayload()
        assertNotNull(payload)
        assertTrue(payload.contains("\"show_overall_ratings\":false"))
        assertTrue(payload.contains("\"episode_ratings_visibility\":\"HIDE_UNWATCHED_EPISODES\""))

        MetaScreenSettingsRepository.resetToDefaults()
        assertTrue(MetaScreenSettingsRepository.uiState.value.showOverallRatings)
        assertEquals(EpisodeRatingsVisibility.SHOW_ALL, MetaScreenSettingsRepository.uiState.value.episodeRatingsVisibility)

        MetaScreenSettingsStorage.savePayload(payload)
        MetaScreenSettingsRepository.onProfileChanged()
        assertFalse(MetaScreenSettingsRepository.uiState.value.showOverallRatings)
        assertEquals(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES, MetaScreenSettingsRepository.uiState.value.episodeRatingsVisibility)

        MetaScreenSettingsRepository.setShowOverallRatings(true)
        MetaScreenSettingsRepository.onProfileChanged()
        assertTrue(MetaScreenSettingsRepository.uiState.value.showOverallRatings)
        assertEquals(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES, MetaScreenSettingsRepository.uiState.value.episodeRatingsVisibility)
    }

    @Test
    fun olderAndUnknownPayloadsKeepRatingsVisibleWithoutResettingOtherPreferences() {
        MetaScreenSettingsStorage.savePayload("""{"blur_unwatched_episodes":true}""")
        MetaScreenSettingsRepository.onProfileChanged()
        assertTrue(MetaScreenSettingsRepository.uiState.value.showOverallRatings)
        assertTrue(MetaScreenSettingsRepository.uiState.value.blurUnwatchedEpisodes)
        assertEquals(EpisodeRatingsVisibility.SHOW_ALL, MetaScreenSettingsRepository.uiState.value.episodeRatingsVisibility)

        MetaScreenSettingsStorage.savePayload("""{"episode_ratings_visibility":"future","show_overall_ratings":false}""")
        MetaScreenSettingsRepository.onProfileChanged()
        assertFalse(MetaScreenSettingsRepository.uiState.value.showOverallRatings)
        assertEquals(EpisodeRatingsVisibility.SHOW_ALL, MetaScreenSettingsRepository.uiState.value.episodeRatingsVisibility)
    }

    @Test
    fun mobileOnlyPosterTransitionFlagSurvivesATvosRepersist() {
        MetaScreenSettingsStorage.savePayload("""{"poster_transition_enabled":true,"show_overall_ratings":false}""")
        MetaScreenSettingsRepository.onProfileChanged()
        MetaScreenSettingsRepository.setBlurUnwatchedEpisodes(true)

        val payload = MetaScreenSettingsStorage.loadPayload()
        assertNotNull(payload)
        assertTrue(payload.contains("\"poster_transition_enabled\":true"))
        assertTrue(payload.contains("\"show_overall_ratings\":false"))
    }

    @Test
    fun episodeRatingsVisibilityRules() {
        assertTrue(EpisodeRatingsVisibility.SHOW_ALL.showRating(isWatched = false))
        assertFalse(EpisodeRatingsVisibility.HIDE_EPISODES.showRating(isWatched = true))
        assertFalse(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES.showRating(isWatched = false))
        assertTrue(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES.showRating(isWatched = true))
        assertEquals(EpisodeRatingsVisibility.SHOW_ALL, EpisodeRatingsVisibility.parse("nope"))
    }
}
