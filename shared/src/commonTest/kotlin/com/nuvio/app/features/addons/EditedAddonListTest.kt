package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

/** Add-ons hub v2 C1 review r3: the list the Remote Setup phone page edited, applied in one step. */
class EditedAddonListTest {
    private fun list(vararg urls: String) = urls.map { ManagedAddon(manifestUrl = it) }

    @Test
    fun reordersRemovesAndFlipsFlags() {
        val edited = editedAddonList(list("A", "B", "C"), listOf("C", "A"), mapOf("A" to false))
        assertEquals(listOf("C", "A"), edited.map { it.manifestUrl })
        assertEquals(listOf(true, false), edited.map { it.enabled })
    }

    @Test
    fun unknownUrlsAndLaterDuplicatesAreIgnored() {
        val edited = editedAddonList(list("A", "B"), listOf("B", "Z", "B", "A"), emptyMap())
        assertEquals(listOf("B", "A"), edited.map { it.manifestUrl })
    }

    @Test
    fun anUnchangedAddonIsTheSameInstance() {
        val addons = list("A")
        assertSame(addons[0], editedAddonList(addons, listOf("A"), mapOf("A" to true))[0])
    }

    @Test
    fun aListThatMovedUnderThePageIsRefused() {
        val current = list("B", "A")
        assertEquals(EditedListOutcome.Refused, editedListOutcome(current, listOf("A", "B"), listOf("A"), emptyMap(), readOnly = false))
    }

    @Test
    fun aMatchingListIsEditedOrLeftAlone() {
        val current = list("A", "B")
        assertEquals(
            listOf("B"),
            (editedListOutcome(current, listOf("A", "B"), listOf("B"), emptyMap(), readOnly = false) as EditedListOutcome.Edited)
                .addons.map { it.manifestUrl },
        )
        assertEquals(EditedListOutcome.Unchanged, editedListOutcome(current, listOf("A", "B"), listOf("A", "B"), emptyMap(), readOnly = false))
    }

    @Test
    fun aReadOnlyListRefusesAnyChangeButAcceptsANoOp() {
        val current = list("A", "B")
        assertEquals(EditedListOutcome.Refused, editedListOutcome(current, listOf("A", "B"), listOf("B", "A"), emptyMap(), readOnly = true))
        assertEquals(EditedListOutcome.Unchanged, editedListOutcome(current, listOf("A", "B"), listOf("A", "B"), mapOf("A" to true), readOnly = true))
    }
}
