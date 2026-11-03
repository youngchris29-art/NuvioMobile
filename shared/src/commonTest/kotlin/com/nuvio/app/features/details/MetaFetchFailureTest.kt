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
        val error = IllegalStateException("boom")
        assertFalse(MetaFetchFailureLog.isAddonAnswer(error))
        val message = MetaFetchFailureLog.message("Some Addon", "movie", "tt1745960", error)
        assertTrue(
            message.startsWith("Failed to fetch/parse meta from add-on \"Some Addon\" for type=movie id=tt1745960: IllegalStateException: boom at "),
            message,
        )
        assertFalse(message.contains("://"))
    }

    @Test
    fun `network error message with a tokenized url keeps the class and loses the url`() {
        val error = RuntimeException("Request timeout [url=https://addon.example/tok123/meta/movie/tt1.json]")
        val message = MetaFetchFailureLog.message("Some Addon", "movie", "tt1", error)
        assertTrue(message.contains("RuntimeException"), message)
        assertFalse(message.contains("https://"), message)
        assertFalse(message.contains("tok123"), message)
    }

    @Test
    fun `serialization error quoting a tokenized url is scrubbed`() {
        val error = kotlinx.serialization.SerializationException(
            "Unexpected JSON token at offset 12: … {\"poster\":\"https://cdn.example/img.jpg?token=tok123\"}"
        )
        val message = MetaFetchFailureLog.message("Some Addon", "movie", "tt1", error)
        assertTrue(message.contains("Unexpected JSON token"), message)
        assertFalse(message.contains("https://"), message)
        assertFalse(message.contains("tok123"), message)
    }

    @Test
    fun `bare secret query values are scrubbed`() {
        val scrubbed = MetaFetchFailureLog.scrub("path?apikey=abc123&x=1 api_key=def456 token=tok123")
        assertFalse(scrubbed.contains("abc123"), scrubbed)
        assertFalse(scrubbed.contains("def456"), scrubbed)
        assertFalse(scrubbed.contains("tok123"), scrubbed)
        assertTrue(scrubbed.contains("x=1"), scrubbed)
    }

    @Test
    fun `failure line names the app frame that threw`() {
        val error = runCatching { throwFromDetailsPackage() }.exceptionOrNull()!!
        val message = MetaFetchFailureLog.message("Some Addon", "movie", "tt1", error)
        assertTrue(message.contains("com.nuvio.app.features.details"), message)
        assertFalse(message.contains("location unknown"), message)
    }

    @Test
    fun `serialization error quoting a json escaped url is scrubbed`() {
        val error = kotlinx.serialization.SerializationException(
            "Unexpected JSON token at offset 40: {\"poster\":\"https:\\/\\/addon.example\\/tok999\\/poster.jpg\"}"
        )
        val message = MetaFetchFailureLog.message("Some Addon", "movie", "tt1", error)
        assertFalse(message.contains("tok999"), message)
        assertFalse(message.contains("https:"), message)
    }

    @Test
    fun `raw payload excerpt with json escaped url is scrubbed`() {
        val scrubbed = MetaFetchFailureLog.scrub("{\"stream\":\"https:\\/\\/h\\/tokABC\\/x.m3u8?token=zzz\"}")
        assertFalse(scrubbed.contains("tokABC"), scrubbed)
        assertFalse(scrubbed.contains("zzz"), scrubbed)
        assertEquals("{\"stream\":\"<url>\"}", scrubbed)
    }

    @Test
    fun `unicode escaped ampersand cannot smuggle a token past the url match`() {
        val scrubbed = MetaFetchFailureLog.scrub("{\"poster\":\"https://h/image?size=1\\u0026token=SECRET\"}")
        assertFalse(scrubbed.contains("SECRET"), scrubbed)
        assertFalse(scrubbed.contains("&"), scrubbed)
    }

    @Test
    fun `unicode escaped scheme and slashes are still a url`() {
        val scrubbed = MetaFetchFailureLog.scrub("https\\u003A\\u002F\\u002Fh\\u002FtokQ\\u002Fposter.jpg")
        assertFalse(scrubbed.contains("tokQ"), scrubbed)
    }

    @Test
    fun `payload summary never quotes the body`() {
        val payload = "{\"meta\":{\"id\":\"tt1\",\"poster\":\"https:\\/\\/cdn.example\\/tokXYZ\\/p.jpg?token=zzz\"}}"
        val summary = MetaFetchFailureLog.payloadSummary(payload)
        assertEquals("Raw payload length=${payload.length}, hasMetaKey=true", summary)
        for (start in 0..payload.length - 6) {
            val window = payload.substring(start, start + 6)
            assertFalse(summary.contains(window), "summary quotes \"$window\"")
        }
    }

    private fun throwFromDetailsPackage(): Nothing =
        throw IllegalArgumentException("Element class kotlinx.serialization.json.JsonObject is not a JsonPrimitive")
}
