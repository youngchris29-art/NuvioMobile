package com.nuvio.app.core.sync

import co.touchlab.kermit.Logger
import com.nuvio.app.core.poster.CustomPosterScreen
import com.nuvio.app.core.poster.CustomPosterUrlRepository
import com.nuvio.app.core.poster.CustomPosterUrlStorage
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Custom poster URL pattern + enabled screens in the profile settings blob (upstream cf59d255 /
 * 92968510, blob v4). Blobs go through the real serializer; the apply side is exercised via
 * [applyRemoteCustomPosterSettings], the helper `applyRemoteBlob()` delegates the two fields to,
 * with the Home re-application injected as a counter.
 */
class ProfileSettingsSyncCustomPosterTest {
    private val log = Logger.withTag("ProfileSettingsSyncCustomPosterTest")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    private val rpdbPattern = "https://api.ratingposterdb.com/KEY/imdb/poster-default/{imdb_id}.jpg"

    @BeforeTest
    fun reset() {
        CustomPosterUrlStorage.savePattern(null)
        CustomPosterUrlStorage.saveEnabledScreens(null)
        CustomPosterUrlRepository.clearLocalState()
    }

    @AfterTest
    fun cleanup() = reset()

    private fun decode(raw: String): Pair<MobileProfileSettingsBlob, JsonObject> {
        val element = json.parseToJsonElement(raw).jsonObject
        return json.decodeFromJsonElement(MobileProfileSettingsBlob.serializer(), element) to
            element["features"]!!.jsonObject
    }

    private fun applyBlob(raw: String, homeCalls: IntArray): Boolean {
        val (blob, rawFeatures) = decode(raw)
        return applyRemoteCustomPosterSettings(
            log = log,
            rawFeatures = rawFeatures,
            incomingPattern = blob.features.customPosterUrlPattern,
            incomingScreens = blob.features.customPosterEnabledScreens,
            reapplyHome = { homeCalls[0]++ },
        )
    }

    @Test
    fun `export encodes pattern and comma-joined screen keys at version 4`() {
        val blob = MobileProfileSettingsBlob(
            features = MobileProfileSettingsFeatures(
                customPosterUrlPattern = rpdbPattern,
                customPosterEnabledScreens = encodeCustomPosterScreenKeys(setOf("search", "home")),
            ),
        )
        val encoded = json.encodeToJsonElement(MobileProfileSettingsBlob.serializer(), blob).jsonObject
        assertEquals(4, encoded["version"]!!.jsonPrimitive.content.toInt())
        val features = encoded["features"]!!.jsonObject
        assertEquals(rpdbPattern, features["custom_poster_url_pattern"]!!.jsonPrimitive.content)
        assertEquals("home,search", features["custom_poster_enabled_screens"]!!.jsonPrimitive.content)
    }

    @Test
    fun `export helpers read local storage`() {
        CustomPosterUrlStorage.savePattern("  $rpdbPattern  ")
        CustomPosterUrlStorage.saveEnabledScreens(setOf("library", "details"))
        assertEquals(rpdbPattern, currentCustomPosterPatternForSync())
        assertEquals("details,library", encodeCustomPosterScreenKeys(CustomPosterUrlStorage.loadEnabledScreens()))
        CustomPosterUrlStorage.saveEnabledScreens(null)
        assertEquals("", encodeCustomPosterScreenKeys(CustomPosterUrlStorage.loadEnabledScreens()))
    }

    @Test
    fun `v3 blob without poster keys leaves local poster values untouched`() {
        CustomPosterUrlStorage.savePattern(rpdbPattern)
        CustomPosterUrlStorage.saveEnabledScreens(setOf("home"))
        val homeCalls = intArrayOf(0)

        val changed = applyBlob(
            """{"version":3,"features":{"poster_card_style_settings_payload":"x"}}""",
            homeCalls,
        )

        assertFalse(changed)
        assertEquals(0, homeCalls[0])
        assertEquals(rpdbPattern, CustomPosterUrlStorage.loadPattern())
        assertEquals(setOf("home"), CustomPosterUrlStorage.loadEnabledScreens())
    }

    @Test
    fun `unknown future version decodes and is presence gated the same way`() {
        CustomPosterUrlStorage.savePattern(rpdbPattern)
        val homeCalls = intArrayOf(0)
        val changed = applyBlob("""{"version":99,"features":{"some_future_key":1}}""", homeCalls)
        assertFalse(changed)
        assertEquals(rpdbPattern, CustomPosterUrlStorage.loadPattern())
    }

    @Test
    fun `v4 blob with a new pattern applies it and reapplies Home exactly once`() {
        val homeCalls = intArrayOf(0)
        val changed = applyBlob(
            """{"version":4,"features":{"custom_poster_url_pattern":"$rpdbPattern","custom_poster_enabled_screens":"home,search"}}""",
            homeCalls,
        )

        assertTrue(changed)
        assertEquals(1, homeCalls[0], "pattern + screens changed together must reapply Home once, not per field")
        assertEquals(rpdbPattern, CustomPosterUrlStorage.loadPattern())
        assertEquals(rpdbPattern, CustomPosterUrlRepository.pattern.value, "repository must be reloaded")
        assertEquals(
            setOf(CustomPosterScreen.HOME, CustomPosterScreen.SEARCH),
            CustomPosterUrlRepository.enabledScreens.value,
        )
    }

    @Test
    fun `v4 blob identical to local state applies nothing and never touches Home`() {
        CustomPosterUrlStorage.savePattern(rpdbPattern)
        CustomPosterUrlStorage.saveEnabledScreens(setOf("search", "home"))
        val homeCalls = intArrayOf(0)

        val changed = applyBlob(
            """{"version":4,"features":{"custom_poster_url_pattern":"$rpdbPattern","custom_poster_enabled_screens":"home,search"}}""",
            homeCalls,
        )

        assertFalse(changed)
        assertEquals(0, homeCalls[0])
    }

    @Test
    fun `blank incoming pattern clears the local one`() {
        CustomPosterUrlStorage.savePattern(rpdbPattern)
        CustomPosterUrlRepository.onProfileChanged()
        val homeCalls = intArrayOf(0)

        val changed = applyBlob(
            """{"version":4,"features":{"custom_poster_url_pattern":"","custom_poster_enabled_screens":""}}""",
            homeCalls,
        )

        assertTrue(changed)
        assertEquals(1, homeCalls[0])
        assertNull(CustomPosterUrlStorage.loadPattern())
        assertEquals("", CustomPosterUrlRepository.pattern.value)
    }

    @Test
    fun `enabled screens round trip through the comma-joined form`() {
        val screens = setOf(CustomPosterScreen.CONTINUE_WATCHING, CustomPosterScreen.LIBRARY, CustomPosterScreen.DETAILS)
        val encoded = encodeCustomPosterScreenKeys(CustomPosterScreen.toKeys(screens))
        assertEquals("continue_watching,details,library", encoded)
        assertEquals(screens, CustomPosterScreen.fromKeys(decodeCustomPosterScreenKeys(encoded)))
        // Blank = no explicit selection = every screen.
        assertNull(decodeCustomPosterScreenKeys(""))
        assertEquals(CustomPosterScreen.ALL, CustomPosterScreen.fromKeys(decodeCustomPosterScreenKeys("")))
        // Tolerant of whitespace and duplicates from other writers.
        assertEquals(setOf("home", "search"), decodeCustomPosterScreenKeys(" home , search,home,"))
    }

    @Test
    fun `order-only difference in screens is not a change`() {
        CustomPosterUrlStorage.saveEnabledScreens(setOf("search", "home"))
        val homeCalls = intArrayOf(0)
        val changed = applyBlob(
            """{"version":4,"features":{"custom_poster_enabled_screens":"search,home"}}""",
            homeCalls,
        )
        assertFalse(changed)
        assertEquals(0, homeCalls[0])
    }
}
