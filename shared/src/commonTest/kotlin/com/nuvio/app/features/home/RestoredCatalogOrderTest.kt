package com.nuvio.app.features.home

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Add-ons hub v2 (Stage A review): Move mode's cancel order for Home catalogs. */
class RestoredCatalogOrderTest {
    @Test
    fun putsTheKeyBackAfterItsLastSurvivingPredecessor() {
        // Moved down two places; cancel puts it back after "a".
        assertEquals(listOf("a", "k", "b", "c"), restoredCatalogOrder(listOf("a", "b", "c", "k"), "k", setOf("a"), emptySet()))
    }

    @Test
    fun skipsPredecessorsThatLeftAndKeepsArrivals() {
        // "a" went away (sync) and "x" arrived: no original predecessor survives, so the key
        // returns to the top (arrivals are not predecessors).
        assertEquals(listOf("k", "x", "b"), restoredCatalogOrder(listOf("x", "b", "k"), "k", setOf("a"), emptySet()))
    }

    @Test
    fun neverLandsAbovePinnedCollections() {
        // A collection pinned during the move: the key stays below it.
        assertEquals(listOf("pin", "k", "b"), restoredCatalogOrder(listOf("pin", "b", "k"), "k", emptySet(), setOf("pin")))
    }

    @Test
    fun leavesAPinnedOrMissingKeyAlone() {
        assertNull(restoredCatalogOrder(listOf("k", "a"), "k", setOf("a"), setOf("k")))
        assertNull(restoredCatalogOrder(listOf("a", "b"), "k", setOf("a"), emptySet()))
    }

    @Test
    fun stepsOnePlaceOnTheOrderItIsGiven() {
        assertEquals(listOf("a", "b", "x", "c"), steppedCatalogOrder(listOf("a", "x", "b", "c"), "x", 1, emptySet()))
        // A synced order is what the step applies to: X moves down within the NEW order.
        assertEquals(listOf("c", "a", "b", "x"), steppedCatalogOrder(listOf("c", "a", "x", "b"), "x", 1, emptySet()))
        assertEquals(listOf("x", "a"), steppedCatalogOrder(listOf("a", "x"), "x", -1, emptySet()))
    }

    @Test
    fun neverStepsPastAnEndOrAPinnedRow() {
        assertNull(steppedCatalogOrder(listOf("x", "a"), "x", -1, emptySet()))
        assertNull(steppedCatalogOrder(listOf("a", "x"), "x", 1, emptySet()))
        assertNull(steppedCatalogOrder(listOf("pin", "x"), "x", -1, setOf("pin")))
        assertNull(steppedCatalogOrder(listOf("pin", "x"), "pin", 1, setOf("pin")))
        assertNull(steppedCatalogOrder(listOf("a"), "missing", 1, emptySet()))
    }
}
