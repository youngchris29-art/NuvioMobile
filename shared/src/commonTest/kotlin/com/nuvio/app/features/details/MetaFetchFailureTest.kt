package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** BUG-239: an add-on meta body without a meta object is a named warning, never a URL. */
class MetaFetchFailureTest {

    @Test
    fun `response without meta throws the missing meta type`() {
        assertFailsWith<MissingMetaObjectException> {
            MetaDetailsParser.parse("""{"metas":[],"cacheMaxAge":3600}""")
        }
        assertFailsWith<MissingMetaObjectException> {
            MetaDetailsParser.parse("""{"err":"not found"}""")
        }
    }

    @Test
    fun `missing meta stays an IllegalStateException`() {
        assertFailsWith<IllegalStateException> { MetaDetailsParser.parse("""{"meta":null}""") }
    }

    @Test
    fun `missing meta is logged as a warning naming the add-on`() {
        val error = runCatching { MetaDetailsParser.parse("{}") }.exceptionOrNull()!!
        assertTrue(MetaFetchFailureLog.isAddonAnswer(error))
        assertEquals(
            "Add-on \"Some Addon\" returned no meta object for type=movie id=tt1745960; trying the next source",
            MetaFetchFailureLog.message("Some Addon", "movie", "tt1745960", error),
        )
    }

    @Test
    fun `other failures stay errors and carry no url`() {
        val error = IllegalArgumentException("boom")
        assertFalse(MetaFetchFailureLog.isAddonAnswer(error))
        val message = MetaFetchFailureLog.message("Some Addon", "movie", "tt1745960", error)
        assertEquals("Failed to fetch/parse meta from add-on \"Some Addon\" for type=movie id=tt1745960: boom", message)
        assertFalse(message.contains("://"))
    }
}
