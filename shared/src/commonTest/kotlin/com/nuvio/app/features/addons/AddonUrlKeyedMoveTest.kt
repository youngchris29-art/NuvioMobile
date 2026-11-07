package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Add-ons hub v2 A4 review r3: the URL-keyed reorders behind Move mode. */
class AddonUrlKeyedMoveTest {
    private fun list(vararg urls: String) = urls.map { ManagedAddon(manifestUrl = it) }
    private fun urls(addons: List<ManagedAddon>?) = addons?.map { it.manifestUrl }

    @Test
    fun aStepMovesTheNamedAddonEvenAfterTheListChanged() {
        // The caller saw [A, B, C] and asked to move B up; a sync made it [X, A, B, C] first.
        assertEquals(listOf("X", "B", "A", "C"), urls(steppedOrder(list("X", "A", "B", "C"), "B", -1)))
    }

    @Test
    fun aStepAtTheEndOrForAnAbsentAddonIsNull() {
        assertNull(steppedOrder(list("A", "B"), "A", -1))
        assertNull(steppedOrder(list("A", "B"), "B", 1))
        assertNull(steppedOrder(list("A", "B"), "Z", 1))
    }

    @Test
    fun restoreGoesRightAfterTheLastSurvivingPredecessor() {
        // [A, B, C, D], D moved to the top, then A removed by sync: [D, B, C] → after B and C.
        assertEquals(listOf("B", "C", "D"), urls(restoredOrder(list("D", "B", "C"), "D", setOf("A", "B", "C"))))
        // A new add-on N arrived at the top meanwhile: C goes back after A and B, below N.
        assertEquals(listOf("N", "A", "B", "C"), urls(restoredOrder(list("N", "C", "A", "B"), "C", setOf("A", "B"))))
    }

    @Test
    fun restoreWithNoSurvivingPredecessorGoesFirst() {
        assertEquals(listOf("B", "A"), urls(restoredOrder(list("A", "B"), "B", emptySet())))
        assertNull(restoredOrder(list("A"), "Z", emptySet()))
    }
}
