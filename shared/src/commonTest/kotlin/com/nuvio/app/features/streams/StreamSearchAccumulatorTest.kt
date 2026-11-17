package com.nuvio.app.features.streams

import com.nuvio.app.features.debrid.DebridSettings
import com.nuvio.app.features.debrid.DebridStreamPresentation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** W4: the receive-loop merge both repositories shared, now one pure reducer. */
class StreamSearchAccumulatorTest {
    private val addonA = SearchFixtures.target("a")
    private val addonB = SearchFixtures.target("b")
    private val pluginGroup = PluginProviderGroup(
        addonId = "plugin-repo:x",
        addonName = "Repo X",
        scrapers = listOf(SearchFixtures.scraper("s1"), SearchFixtures.scraper("s2"), SearchFixtures.scraper("s3")),
    )

    private var presentCalls = 0

    private fun accumulator(
        plugins: List<PluginProviderGroup> = listOf(pluginGroup),
        allStreams: Boolean = false,
    ) = StreamSearchAccumulator(
        installedAddonOrder = listOf("a", "b"),
        pluginProviderGroups = plugins,
        present = { group -> presentCalls++; group },
        debridSettings = DebridSettings(),
        filtersApplyToAllStreams = allStreams,
    )

    private fun initial(plugins: List<PluginProviderGroup> = listOf(pluginGroup)): StreamsUiState {
        val groups = listOf(addonA, addonB).map { AddonStreamGroup(it.addonName, it.addonId, emptyList(), isLoading = true) } +
            plugins.map { AddonStreamGroup(it.addonName, it.addonId, emptyList(), isLoading = true) }
        return StreamsUiState(groups = groups, isAnyLoading = true)
    }

    private fun addon(target: InstalledStreamAddonTarget, vararg labels: String, error: String? = null) =
        StreamLoadCompletion.Addon(
            AddonStreamGroup(target.addonName, target.addonId, labels.map { SearchFixtures.stream(target.addonId, it) }, error = error),
        )

    private fun scraper(vararg labels: String, error: String? = null) =
        StreamLoadCompletion.PluginScraper(pluginGroup.addonId, labels.map { SearchFixtures.stream(pluginGroup.addonId, it) }, error)

    private fun StreamsUiState.group(id: String) = groups.single { it.addonId == id }

    @Test
    fun pluginGroupEndsLoadingAtItsLastScraperAndDropsTheErrorWhenStreamsCame() {
        val accumulator = accumulator()
        var state = initial()
        state = accumulator.apply(state, scraper(error = "s1 broke"))
        assertTrue(state.group(pluginGroup.addonId).isLoading)
        assertNull(state.group(pluginGroup.addonId).error)
        state = accumulator.apply(state, scraper())
        assertTrue(state.group(pluginGroup.addonId).isLoading)
        state = accumulator.apply(state, scraper("p1"))

        val group = state.group(pluginGroup.addonId)
        assertEquals(false, group.isLoading)
        assertNull(group.error)
        assertEquals(listOf("p1"), group.streams.map { it.name })
    }

    @Test
    fun pluginGroupShowsItsFirstErrorWhenNothingCame() {
        val accumulator = accumulator()
        var state = initial()
        state = accumulator.apply(state, scraper())
        state = accumulator.apply(state, scraper(error = "first"))
        state = accumulator.apply(state, scraper(error = "second"))

        assertEquals("first", state.group(pluginGroup.addonId).error)
        assertEquals(false, state.group(pluginGroup.addonId).isLoading)
    }

    @Test
    fun tvOsPresentsPluginStreamsFromTheRawListOncePerCompletion() {
        val accumulator = accumulator(allStreams = true)
        var state = initial()
        state = accumulator.apply(state, scraper("z-two"))
        state = accumulator.apply(state, scraper("a-one"))

        val raw = (scraper("z-two").streams + scraper("a-one").streams).sortedForGroupedDisplay()
        val expected = DebridStreamPresentation.apply(
            groups = listOf(state.group(pluginGroup.addonId).copy(streams = raw)),
            settings = DebridSettings(),
            allStreams = true,
        ).single().streams
        assertEquals(expected, state.group(pluginGroup.addonId).streams)
        assertEquals(2, state.group(pluginGroup.addonId).streams.size, "no stream is presented twice")
    }

    @Test
    fun mobileMergesPluginStreamsIntoTheGroupStreams() {
        val accumulator = accumulator(allStreams = false)
        var state = initial()
        state = accumulator.apply(state, scraper("z-two"))
        state = accumulator.apply(state, scraper("a-one"))

        assertEquals(
            (scraper("z-two").streams + scraper("a-one").streams).sortedForGroupedDisplay(),
            state.group(pluginGroup.addonId).streams,
        )
    }

    @Test
    fun addonCompletionReplacesItsGroupAndKeepsInstalledOrder() {
        val accumulator = accumulator(plugins = emptyList())
        var state = initial(plugins = emptyList())
        state = accumulator.apply(state, addon(addonB, "b1"))
        state = accumulator.apply(state, addon(addonA, "a1"))

        assertEquals(listOf("a", "b"), state.groups.map { it.addonName })
        assertEquals(listOf(listOf("a1"), listOf("b1")), state.groups.map { group -> group.streams.map { it.name } })
        assertEquals(false, state.isAnyLoading)
        assertNull(state.emptyStateReason)
        assertEquals(2, presentCalls)
    }

    @Test
    fun emptyStateReasonFollowsTheGroups() {
        val accumulator = accumulator(plugins = emptyList())
        var state = initial(plugins = emptyList())
        state = accumulator.apply(state, addon(addonA, error = "timeout"))
        assertNull(state.emptyStateReason, "nothing is decided while a source is loading")
        val allFailed = accumulator.apply(state, addon(addonB, error = "offline"))
        assertEquals(StreamsEmptyStateReason.StreamFetchFailed, allFailed.emptyStateReason)
        val oneEmpty = accumulator(plugins = emptyList()).let { fresh ->
            fresh.apply(fresh.apply(initial(plugins = emptyList()), addon(addonA, error = "timeout")), addon(addonB))
        }
        assertEquals(StreamsEmptyStateReason.NoStreamsFound, oneEmpty.emptyStateReason)
    }

    @Test
    fun recordedTransformGivesTheSameStateWhenRetried() {
        // MutableStateFlow.update re-runs its lambda when another writer won the race; the counters
        // must have advanced once, in record, not once per run.
        val accumulator = accumulator()
        var state = initial()
        val first = accumulator.record(scraper("p1"))
        assertEquals(first(state), first(state))
        state = first(state)
        state = accumulator.record(scraper())(state)
        assertTrue(state.group(pluginGroup.addonId).isLoading, "two of three scrapers answered")
        state = accumulator.record(scraper("p2"))(state)
        assertEquals(false, state.group(pluginGroup.addonId).isLoading)

        val addonTransform = accumulator.record(addon(addonA, "a1"))
        addonTransform(state)
        addonTransform(state)
        assertEquals(1, presentCalls, "an add-on group is presented once per completion")
    }
}
