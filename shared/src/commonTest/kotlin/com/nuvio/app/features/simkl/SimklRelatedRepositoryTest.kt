package com.nuvio.app.features.simkl

import com.nuvio.app.features.trakt.MoreLikeThisSourcePreference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SimklRelatedRepositoryTest {
    private val body = """
        {
          "users_recommendations": [
            {"title": "Rec Show", "en_title": "Rec Show EN", "year": 2020, "poster": "12/abc", "fanart": "34/def",
             "type": "show", "ids": {"simkl": 1, "imdb": "tt111"}},
            {"title": "No Year", "type": "show", "ids": {"simkl": 2, "imdb": "tt222"}}
          ],
          "similar": [
            {"title": "Dup Of Rec", "year": 2020, "type": "show", "ids": {"simkl": 1, "imdb": "tt111"}},
            {"title": "Similar Movie", "year": 2018, "poster": "56/ghi", "type": "movie", "ids": {"simkl": 3, "tmdb": "999"}},
            {"title": "Anime Movie", "year": 2016, "type": "anime", "anime_type": "movie",
             "ids": {"simkl": 4, "mal": "32", "kitsu": "11", "imdb": "tt444"}}
          ],
          "unknown_field": true
        }
    """.trimIndent()

    private fun previews(pref: SimklAnimeIdPreference = SimklAnimeIdPreference.IMDB) =
        buildRelatedPreviews(SimklRelatedRepository.parseSimklDetail(body)!!, pref)

    @Test
    fun `related items decode with ids artwork and dedup`() {
        val items = previews()
        // Rec first, "No Year" dropped (year required), duplicate similar entry dropped.
        assertEquals(listOf("tt111", "tmdb:999", "tt444"), items.map { it.id })
        val rec = items[0]
        assertEquals("series", rec.type)
        assertEquals("Rec Show EN", rec.name)
        assertEquals("2020", rec.releaseInfo)
        assertEquals("https://wsrv.nl/?url=https://simkl.in/posters/12/abc_m.webp&q=90", rec.poster)
        assertEquals("https://wsrv.nl/?url=https://simkl.in/fanart/34/def_w.webp&q=90", rec.banner)
        assertEquals("movie", items[1].type)
        // No fanart: banner falls back to the poster's _w landscape crop.
        assertEquals("https://wsrv.nl/?url=https://simkl.in/posters/56/ghi_w.webp&q=90", items[1].banner)
        assertNull(items[2].poster)
        assertNull(items[2].banner)
        assertEquals("movie", items[2].type)
    }

    @Test
    fun `anime id preference picks the canonical id`() {
        assertEquals("mal:32", previews(SimklAnimeIdPreference.MAL).last().id)
        assertEquals("kitsu:11", previews(SimklAnimeIdPreference.KITSU).last().id)
        // TVDB preference with no tvdb id falls through to the standard chain (imdb).
        assertEquals("tt444", previews(SimklAnimeIdPreference.TVDB).last().id)
    }

    @Test
    fun `empty or malformed responses give no items`() {
        assertNull(SimklRelatedRepository.parseSimklDetail("not json"))
        assertNull(SimklRelatedRepository.parseSimklDetail("[]"))
        val empty = SimklRelatedRepository.parseSimklDetail("{}")
        assertNotNull(empty)
        assertTrue(buildRelatedPreviews(empty, SimklAnimeIdPreference.IMDB).isEmpty())
    }

    @Test
    fun `result is capped at twenty items`() {
        val many = (1..30).joinToString(",") {
            """{"title": "T$it", "year": 2000, "type": "movie", "ids": {"simkl": $it, "imdb": "tt$it"}}"""
        }
        val detail = SimklRelatedRepository.parseSimklDetail("""{"similar": [$many]}""")!!
        assertEquals(20, buildRelatedPreviews(detail, SimklAnimeIdPreference.IMDB).size)
    }

    @Test
    fun `redirect param parsing accepts known prefixes only`() {
        assertEquals("imdb" to "tt123", parseSimklRedirectParam("tt123:1:2"))
        assertEquals("tmdb" to "55", parseSimklRedirectParam("TMDB:55"))
        assertEquals("mal" to "9", parseSimklRedirectParam("mal:9"))
        assertNull(parseSimklRedirectParam("custom:9"))
        assertNull(parseSimklRedirectParam(" "))
        assertNull(parseSimklRedirectParam(null))
    }

    @Test
    fun `simkl more like this gate needs connection and preference`() {
        assertTrue(shouldUseSimklMoreLikeThis(true, MoreLikeThisSourcePreference.SIMKL))
        assertFalse(shouldUseSimklMoreLikeThis(false, MoreLikeThisSourcePreference.SIMKL))
        assertFalse(shouldUseSimklMoreLikeThis(true, MoreLikeThisSourcePreference.TRAKT))
        assertFalse(shouldUseSimklMoreLikeThis(true, MoreLikeThisSourcePreference.TMDB))
    }

    @Test
    fun `preference storage parses simkl and falls back safely`() {
        assertEquals(MoreLikeThisSourcePreference.SIMKL, MoreLikeThisSourcePreference.fromStorage("SIMKL"))
        assertEquals(MoreLikeThisSourcePreference.TRAKT, MoreLikeThisSourcePreference.fromStorage("bogus"))
    }

    @Test
    fun relatedCacheKeyVariesWithAnimeIdPreference() {
        val imdb = relatedCacheKey("anime", 42L, SimklAnimeIdPreference.IMDB)
        val mal = relatedCacheKey("anime", 42L, SimklAnimeIdPreference.MAL)
        assertTrue(imdb != mal)
        assertEquals(imdb, relatedCacheKey("anime", 42L, SimklAnimeIdPreference.IMDB))
    }
}
