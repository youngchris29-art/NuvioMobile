package com.nuvio.app.features.player

import com.nuvio.app.features.streams.StreamItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/**
 * Decision BC: the next-episode walk waits for new sources while its search is still open, up to
 * the search deadline. The policy alone, then event sequences of the walk driven the way Swift's
 * `NextEpisodeEngine.play` drives it: a fake clock, add-ons answering at given times, the search
 * settling, a viewer action.
 */
class PlayerSourceFallbackWaitPolicyTest {
    private fun source(name: String, addon: String = "A") =
        StreamItem(name = name, url = "https://example.com/$name.mkv", addonName = addon, addonId = "addon:$addon")

    // MARK: the decision

    @Test
    fun aKnownSourceIsTriedAtOnce() {
        val next = source("next")
        val step = PlayerSourceFallbackWaitPolicy.decide(next, hasBudget = true, searchOpen = true, millisToDeadline = 5_000, cancelled = false)
        assertEquals(PlayerSourceFallbackStep.Try(next), step)
    }

    @Test
    fun anOpenSearchIsWaitedForUpToTheDeadline() {
        val step = PlayerSourceFallbackWaitPolicy.decide(null, hasBudget = true, searchOpen = true, millisToDeadline = 7_500, cancelled = false)
        assertEquals(PlayerSourceFallbackStep.Wait(7_500), step)
    }

    @Test
    fun aSettledSearchEndsAtOnce() {
        val step = PlayerSourceFallbackWaitPolicy.decide(null, hasBudget = true, searchOpen = false, millisToDeadline = 7_500, cancelled = false)
        assertEquals(PlayerSourceFallbackStep.End, step)
    }

    @Test
    fun noWaitPastTheDeadline() {
        for (left in listOf(0L, -1L)) {
            val step = PlayerSourceFallbackWaitPolicy.decide(null, hasBudget = true, searchOpen = true, millisToDeadline = left, cancelled = false)
            assertEquals(PlayerSourceFallbackStep.End, step)
        }
    }

    @Test
    fun aViewerActionEndsEvenWithASourceKnown() {
        val step = PlayerSourceFallbackWaitPolicy.decide(source("next"), hasBudget = true, searchOpen = true, millisToDeadline = 5_000, cancelled = true)
        assertEquals(PlayerSourceFallbackStep.End, step)
    }

    @Test
    fun noWaitWithTheBudgetUsedUp() {
        val step = PlayerSourceFallbackWaitPolicy.decide(null, hasBudget = false, searchOpen = true, millisToDeadline = 5_000, cancelled = false)
        assertEquals(PlayerSourceFallbackStep.End, step)
    }

    // MARK: the walk as Swift drives it

    /** What arrives when, the search's state, and the outcome of a scripted walk. */
    private class World(
        val arrivals: Map<Long, List<StreamItem>>,
        val settlesAt: Long,
        val deadline: Long,
        val cancelAt: Long? = null,
        val resolves: Set<String> = emptySet(),
    ) {
        var now = 0L
        val known = mutableListOf<StreamItem>()
        val tried = mutableListOf<String>()
        var played: String? = null
        var endedAt: Long? = null
        var waits = 0

        fun arrive() { arrivals.filterKeys { it <= now }.values.flatten().forEach { if (it !in known) known += it } }
        val searchOpen get() = now < settlesAt
        val cancelled get() = cancelAt != null && now >= cancelAt
    }

    /** One walk: resolve, and on a failure move on, waiting by the policy (1 s polling, like Swift's). */
    private fun drive(first: StreamItem, maxSources: Int, world: World) {
        world.arrive()
        val walk = PlayerSourceFallbackWalk(first, maxSources)
        val picker: (StreamItem, Set<String>) -> StreamItem? = { failed, keys ->
            world.known.firstOrNull {
                !PlayerSourceFallback.isExcluded(it, keys, failed.addonId, failed.p2pInfoHash)
            }
        }
        while (true) {
            world.tried += walk.candidate.name.orEmpty()
            if (walk.candidate.name in world.resolves) { world.played = walk.candidate.name; return }
            var next = walk.failed(picker)
            while (true) {
                when (val step = PlayerSourceFallbackWaitPolicy.decide(
                    next, walk.hasBudget, world.searchOpen, world.deadline - world.now, world.cancelled,
                )) {
                    is PlayerSourceFallbackStep.Try -> break
                    is PlayerSourceFallbackStep.End -> { world.endedAt = world.now; return }
                    is PlayerSourceFallbackStep.Wait -> {
                        world.waits++
                        world.now += minOf(1_000, step.atMostMillis)
                        world.arrive()
                        next = walk.moveOn(picker)
                    }
                }
            }
        }
    }

    @Test
    fun aLateSourceThatArrivesInsideTheDeadlineIsTried() {
        val first = source("first")
        val late = source("late", addon = "Late")
        val world = World(arrivals = mapOf(0L to listOf(first), 12_000L to listOf(late)), settlesAt = 12_000,
                          deadline = 15_000, resolves = setOf("late"))
        drive(first, maxSources = 3, world = world)
        assertEquals(listOf("first", "late"), world.tried)
        assertEquals("late", world.played)
        assertEquals(12_000L, world.now, "the walk waited for the add-on that answered at 12 s")
    }

    @Test
    fun nothingArrivingEndsTheWalkAtTheDeadline() {
        val first = source("first")
        val world = World(arrivals = mapOf(0L to listOf(first)), settlesAt = 60_000, deadline = 15_000)
        drive(first, maxSources = 3, world = world)
        assertEquals(listOf("first"), world.tried)
        assertEquals(15_000L, world.endedAt, "never past the deadline")
    }

    @Test
    fun aSettledSearchEndsTheWalkWithoutWaiting() {
        val first = source("first")
        val world = World(arrivals = mapOf(0L to listOf(first)), settlesAt = 0, deadline = 15_000)
        drive(first, maxSources = 3, world = world)
        assertEquals(0L, world.endedAt)
        assertEquals(0, world.waits)
    }

    @Test
    fun theSearchSettlingDuringTheWaitEndsIt() {
        val first = source("first")
        val world = World(arrivals = mapOf(0L to listOf(first)), settlesAt = 4_000, deadline = 15_000)
        drive(first, maxSources = 3, world = world)
        assertEquals(4_000L, world.endedAt)
    }

    @Test
    fun aViewerActionDuringTheWaitEndsItAtOnce() {
        val first = source("first")
        val late = source("late", addon = "Late")
        val world = World(arrivals = mapOf(0L to listOf(first), 9_000L to listOf(late)), settlesAt = 12_000,
                          deadline = 15_000, cancelAt = 3_000, resolves = setOf("late"))
        drive(first, maxSources = 3, world = world)
        assertEquals(3_000L, world.endedAt)
        assertEquals(listOf("first"), world.tried, "the late source is never tried after the viewer acted")
    }

    @Test
    fun sourcesToTryStillCapsTheWalkAcrossTheWait() {
        val first = source("first")
        val second = source("second", addon = "B")
        val third = source("third", addon = "C")
        val world = World(arrivals = mapOf(0L to listOf(first, second), 5_000L to listOf(third)), settlesAt = 10_000,
                          deadline = 15_000)
        drive(first, maxSources = 1, world = world)
        assertEquals(listOf("first", "second"), world.tried, "one further source, then no wait for more")
        assertEquals(0L, world.endedAt)
        assertEquals(0, world.waits)
    }

    @Test
    fun theWaitDoesNotUseTheBudgetButASourceFoundAfterItDoes() {
        val first = source("first")
        val late = source("late", addon = "Late")
        val later = source("later", addon = "Later")
        val world = World(arrivals = mapOf(0L to listOf(first), 2_000L to listOf(late), 4_000L to listOf(later)),
                          settlesAt = 10_000, deadline = 15_000)
        drive(first, maxSources = 1, world = world)
        assertEquals(listOf("first", "late"), world.tried, "the late source is the one further source")
        assertEquals(2_000L, world.endedAt, "its failure ends the walk at once: the budget is used up")
    }

    @Test
    fun moveOnNeverPicksATriedSource() {
        val first = source("first")
        val walk = PlayerSourceFallbackWalk(first, maxSources = 3)
        assertEquals(null, walk.failed { _, _ -> null })
        val again = walk.moveOn { failed, keys -> listOf(first).firstOrNull { !PlayerSourceFallback.isExcluded(it, keys, failed.addonId, failed.p2pInfoHash) } }
        assertEquals(null, again)
        assertEquals(0, walk.attempts)
        assertIs<PlayerSourceFallbackStep.Wait>(
            PlayerSourceFallbackWaitPolicy.decide(again, walk.hasBudget, searchOpen = true, millisToDeadline = 1, cancelled = false),
        )
    }
}
