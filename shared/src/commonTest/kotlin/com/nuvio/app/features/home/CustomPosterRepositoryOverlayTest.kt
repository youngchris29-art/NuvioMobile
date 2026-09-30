package com.nuvio.app.features.home

import com.nuvio.app.core.poster.CustomPosterScreen
import com.nuvio.app.core.poster.CustomPosterUrlRepository
import com.nuvio.app.core.poster.CustomPosterUrlStorage
import com.nuvio.app.core.poster.reapplyCustomPosterUrls
import com.nuvio.app.core.poster.withCustomPosterUrls
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.library.libraryPosterPatternKey
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

/**
 * Overlay contract used by the poster-publishing repositories. The repositories themselves
 * (Catalog/Home/Search/Details/Collections/Library) are network-coupled singletons with no fake
 * seam, so these tests call the overlay extensions on hand-built lists with the pattern read
 * through [CustomPosterUrlRepository.patternForScreen]; they do NOT drive a repository. The
 * Library republish collector itself is untested: only its key mapping
 * ([libraryPosterPatternKey]) is.
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
    fun `overlay on enabled screens resolves url and keeps rawPosterUrl`() {
        CustomPosterUrlRepository.setPattern(pattern)
        listOf(CustomPosterScreen.HOME, CustomPosterScreen.SEARCH, CustomPosterScreen.COLLECTIONS).forEach { screen ->
            val item = listOf(preview()).withCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(screen)).single()
            assertEquals("https://p.example/tt1.jpg", item.poster, screen.key)
            assertEquals(original, item.rawPosterUrl, screen.key)
        }
    }

    @Test
    fun `overlay on a disabled screen leaves items unchanged`() {
        CustomPosterUrlRepository.setPattern(pattern)
        CustomPosterUrlRepository.setScreenEnabled(CustomPosterScreen.SEARCH, false)
        val item = listOf(preview())
            .withCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.SEARCH))
            .single()
        assertEquals(original, item.poster)
        assertNull(item.rawPosterUrl)
    }

    @Test
    fun `home reapply follows a pattern change and restores originals when home is disabled`() {
        CustomPosterUrlRepository.setPattern(pattern)
        val cached = listOf(preview()).withCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.HOME))

        CustomPosterUrlRepository.setPattern("https://q.example/{imdb_id}.png")
        val changed = cached.reapplyCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.HOME)).single()
        assertEquals("https://q.example/tt1.png", changed.poster)
        assertEquals(original, changed.rawPosterUrl)

        CustomPosterUrlRepository.setScreenEnabled(CustomPosterScreen.HOME, false)
        val disabled = changed.let { listOf(it) }
            .reapplyCustomPosterUrls(CustomPosterUrlRepository.patternForScreen(CustomPosterScreen.HOME)).single()
        assertEquals(original, disabled.poster)
    }

    @Test
    fun `repository pattern and enabled-screens values change with setPattern and toggles`() {
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
    fun `libraryPosterPatternKey changes with the pattern and the library toggle only`() {
        val all = CustomPosterScreen.ALL
        val base = libraryPosterPatternKey(pattern, all)
        assertEquals(pattern, base)
        assertNotEquals(base, libraryPosterPatternKey("https://q.example/{imdb_id}.png", all))
        assertNotEquals(base, libraryPosterPatternKey(pattern, all - CustomPosterScreen.LIBRARY))
        assertEquals("", libraryPosterPatternKey(pattern, emptySet()))
        // Toggling an unrelated screen must not republish the library.
        assertEquals(base, libraryPosterPatternKey(pattern, all - CustomPosterScreen.HOME))
        // Clearing the pattern is a change too.
        assertNotEquals(base, libraryPosterPatternKey("", all))
    }

    @Test
    fun `details and library overlays use their own screen`() {
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
