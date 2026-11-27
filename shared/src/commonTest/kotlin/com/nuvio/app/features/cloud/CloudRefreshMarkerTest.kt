package com.nuvio.app.features.cloud

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/* Scope identity W3b review r2: the refreshing marker, every interleaving of two owners. */
class CloudRefreshMarkerTest {
    private sealed interface Ev {
        data class Start(val n: Int) : Ev
        data class Publish(val n: Int) : Ev
        data class Abandon(val n: Int) : Ev
        data object Reset : Ev
    }

    /**
     * Every sequence over two owners: each owner starts (1 before 2), may end once (publish or
     * abandon, only after its start), and a reset may happen anywhere once. The oracle, from the
     * requirements: the latest started owner is the only one that may publish or clear; a publish
     * or abandon ends the marker only for it; a reset supersedes everyone; a superseded owner's
     * publish is refused (its listing is never written) and its abandon changes nothing.
     */
    @Test
    fun everyInterleavingOfTwoOwners() {
        val pool = listOf(
            listOf(Ev.Start(1)), listOf(Ev.Start(2)),
            listOf(null, Ev.Publish(1), Ev.Abandon(1)), listOf(null, Ev.Publish(2), Ev.Abandon(2)),
            listOf(null, Ev.Reset),
        )
        var checked = 0
        fun choices(i: Int, acc: List<Ev>): List<List<Ev>> =
            if (i == pool.size) listOf(acc) else pool[i].flatMap { e -> choices(i + 1, if (e == null) acc else acc + e) }
        for (events in choices(0, emptyList())) {
            for (order in permutations(events)) {
                if (!valid(order)) continue
                checked++
                val marker = CloudRefreshMarker()
                val owners = mutableMapOf<Int, CloudRefreshMarker.Owner>()
                var latest: Int? = null
                var live = false // the latest owner still holds the marker
                for (e in order) {
                    when (e) {
                        is Ev.Start -> { owners[e.n] = marker.start(); latest = e.n; live = true }
                        is Ev.Publish -> {
                            val expected = live && latest == e.n
                            assertEquals(expected, marker.publish(owners.getValue(e.n)), "$order at $e")
                            if (expected) live = false
                        }
                        is Ev.Abandon -> {
                            val expected = live && latest == e.n
                            assertEquals(expected, marker.abandon(owners.getValue(e.n)), "$order at $e")
                            if (expected) live = false
                        }
                        Ev.Reset -> { marker.reset(); live = false }
                    }
                    assertEquals(live, marker.isRefreshing, "$order after $e")
                }
            }
        }
        assertTrue(checked > 100, "enumerated $checked sequences")
    }

    private fun valid(order: List<Ev>): Boolean {
        val pos = order.withIndex().associate { (i, e) -> e to i }
        val s1 = pos.getValue(Ev.Start(1))
        val s2 = pos.getValue(Ev.Start(2))
        if (s1 > s2) return false
        for (n in 1..2) {
            val start = if (n == 1) s1 else s2
            listOf(Ev.Publish(n), Ev.Abandon(n)).forEach { e -> pos[e]?.let { if (it < start) return false } }
        }
        return true
    }

    private fun <T> permutations(items: List<T>): List<List<T>> =
        if (items.size <= 1) listOf(items) else items.indices.flatMap { i ->
            permutations(items.take(i) + items.drop(i + 1)).map { listOf(items[i]) + it }
        }

    @Test
    fun namedCases() {
        // start / start / publish(old) / publish(new): the old one is superseded.
        CloudRefreshMarker().run {
            val a = start(); val b = start()
            assertFalse(publish(a)); assertTrue(isRefreshing)
            assertTrue(publish(b)); assertFalse(isRefreshing)
        }
        // start / start / publish(new) / publish(old): the old one never overwrites.
        CloudRefreshMarker().run {
            val a = start(); val b = start()
            assertTrue(publish(b)); assertFalse(publish(a)); assertFalse(isRefreshing)
        }
        // abandon of an old owner leaves the newer marker.
        CloudRefreshMarker().run {
            val a = start(); start()
            assertFalse(abandon(a)); assertTrue(isRefreshing)
        }
        // cancel before the body ran (abandon on completion), and cancel after it started: the same call.
        CloudRefreshMarker().run { val a = start(); assertTrue(abandon(a)); assertFalse(isRefreshing); assertFalse(abandon(a)) }
        // a refused final commit: no publish was attempted, the completion abandons.
        CloudRefreshMarker().run { val a = start(); assertTrue(abandon(a)); assertFalse(publish(a)) }
        // a publish then the completion's abandon: a no-op.
        CloudRefreshMarker().run { val a = start(); assertTrue(publish(a)); assertFalse(abandon(a)) }
        // a clear supersedes everyone.
        CloudRefreshMarker().run { val a = start(); reset(); assertFalse(publish(a)); assertFalse(isRefreshing) }
    }

    /** Review r3 #1: what a superseded lookup reads after it waited. */
    @Test
    fun publishedSinceAndAwaitIdle() = kotlinx.coroutines.test.runTest {
        CloudRefreshMarker().run {
            val a = start(); val b = start()
            assertFalse(publishedSince(a))
            assertTrue(publish(b))
            assertTrue(publishedSince(a), "a newer listing was published")
            assertFalse(publishedSince(b))
        }
        CloudRefreshMarker().run {
            val a = start(); val b = start()
            assertTrue(abandon(b))
            assertFalse(publishedSince(a), "the newer refresh was abandoned: nothing newer published")
            assertTrue(awaitIdle(10))
        }
        CloudRefreshMarker().run {
            start()
            assertFalse(kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { awaitIdle(50) }, "bounded: still refreshing")
        }
    }
}
