package com.nuvio.app.features.home

import com.nuvio.app.core.poster.CustomPosterScreen
import com.nuvio.app.core.poster.CustomPosterUrlRepository
import com.nuvio.app.core.poster.CustomPosterUrlStorage
import com.nuvio.app.core.poster.reapplyCustomPosterUrls
import com.nuvio.app.core.poster.withCustomPosterUrls
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.library.LibraryItem
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

/**
 * The repositories that publish posters (Catalog/Home/Search/Details/Collections/Library) are
 * network-coupled singletons with no fake seam, so this pins the exact sequence each of them runs:
 * `ensureLoaded()` -> `patternForScreen(<screen>)` -> overlay on the result items. Home's
 * `applyCurrentSettings` path uses `reapplyCustomPosterUrls` so a pattern change re-resolves from
 * `rawPosterUrl` instead of compounding.
 */
class CustomPosterRepositoryOverlayTest {
    private val pattern = "https://p.example/{imdb_id}.jpg"
    private val original = "https://orig.example/a.jpg"

    @BeforeTest
    fun reset() {
        CustomPosterUrlStorage.savePattern(null)
        CustomPosterUrlStorage.saveEnabledScreens(null)
        CustomPosterUrlRepository.clearLocalState()
    }

    @AfterTest
    fun cleanup() = reset()

    private fun preview() = MetaPreview(id = "tt1", type = "movie", name = "A", poster = original)

    @Test
    fun `enabled screen publishes resolved url and keeps rawPosterUrl`() {
        CustomPosterUrlRepository.clearLocalState()
        CustomPosterUrlRepository.setPattern(pattern)
        listOf(CustomPosterScreen.HOME, CustomPosterScreen.SEARCH, CustomPosterScreen.COLLECTIONS).forEach { screen ->
            val item = listOf(preview()).withCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(screen)).single()
            assertEquals("https://p.example/tt1.jpg", item.poster, screen.key)
            assertEquals(original, item.rawPosterUrl, screen.key)
        }
    }

    @Test
    fun `disabled screen leaves items unchanged`() {
        CustomPosterUrlRepository.clearLocalState()
        CustomPosterUrlRepository.setPattern(pattern)
        CustomPosterUrlRepository.setScreenEnabled(CustomPosterScreen.SEARCH, false)
        val item = listOf(preview())
            .withCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.SEARCH))
            .single()
        assertEquals(original, item.poster)
        assertNull(item.rawPosterUrl)
    }

    @Test
    fun `home reapply follows a pattern change and clears when disabled`() {
        CustomPosterUrlRepository.clearLocalState()
        CustomPosterUrlRepository.setPattern(pattern)
        val cached = listOf(preview()).withCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.HOME))

        CustomPosterUrlRepository.setPattern("https://q.example/{imdb_id}.png")
        val changed = cached.reapplyCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.HOME)).single()
        assertEquals("https://q.example/tt1.png", changed.poster)
        assertEquals(original, changed.rawPosterUrl)

        CustomPosterUrlRepository.clearPattern()
        val cleared = cached.reapplyCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.HOME)).single()
        assertEquals(original, cleared.poster)
    }

    @Test
    fun `home signature inputs change with pattern and enabled screens`() {
        CustomPosterUrlRepository.clearLocalState()
        CustomPosterUrlRepository.ensureLoaded()
        val a = CustomPosterUrlRepository.pattern.value to CustomPosterUrlRepository.enabledScreens.value
        CustomPosterUrlRepository.setPattern(pattern)
        val b = CustomPosterUrlRepository.pattern.value to CustomPosterUrlRepository.enabledScreens.value
        CustomPosterUrlRepository.setScreenEnabled(CustomPosterScreen.HOME, false)
        val c = CustomPosterUrlRepository.pattern.value to CustomPosterUrlRepository.enabledScreens.value
        CustomPosterUrlRepository.setPattern(pattern) // same pattern again: no change
        val d = CustomPosterUrlRepository.pattern.value to CustomPosterUrlRepository.enabledScreens.value
        assertNotEquals(a, b)
        assertNotEquals(b, c)
        assertEquals(c, d)
    }

    @Test
    fun `details and library overlays use their own screen`() {
        CustomPosterUrlRepository.clearLocalState()
        CustomPosterUrlRepository.setPattern(pattern)
        val meta = MetaDetails(id = "tt9", type = "movie", name = "M", moreLikeThis = listOf(preview()))
        val overlaid = meta.withCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.DETAILS))
        assertEquals("https://p.example/tt1.jpg", overlaid.moreLikeThis.single().poster)

        val lib = LibraryItem(id = "tt2", type = "movie", name = "L", poster = original, savedAtEpochMs = 1L)
        val libOut = listOf(lib).withCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.LIBRARY)).single()
        assertEquals("https://p.example/tt2.jpg", libOut.poster)
        assertEquals(original, libOut.rawPosterUrl)
    }
}
