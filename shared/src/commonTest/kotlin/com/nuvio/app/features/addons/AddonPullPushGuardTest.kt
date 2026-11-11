package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Races item 5: when a hydrated pull must not overwrite the TV's own newer add-on list. */
class AddonPullPushGuardTest {
    @Test
    fun anUnhydratedPullAlwaysApplies() {
        // The wipe fix's direction: before the first pull settles, the pull wins over any edit.
        for (seqMoved in listOf(false, true)) for (pendingStart in listOf(false, true)) for (pendingNow in listOf(false, true)) {
            assertFalse(
                shouldSkipPulledAddons(
                    hydrated = false,
                    seqAtStart = 4L,
                    seqNow = if (seqMoved) 5L else 4L,
                    pushPendingAtStart = pendingStart,
                    pushPendingNow = pendingNow,
                ),
            )
        }
    }

    @Test
    fun aHydratedPullWithAnEditDuringItIsSkipped() {
        assertTrue(shouldSkipPulledAddons(hydrated = true, seqAtStart = 4L, seqNow = 5L, pushPendingAtStart = false, pushPendingNow = false))
    }

    @Test
    fun aHydratedPullWithAPushPendingAtStartIsSkipped() {
        assertTrue(shouldSkipPulledAddons(hydrated = true, seqAtStart = 4L, seqNow = 4L, pushPendingAtStart = true, pushPendingNow = false))
    }

    @Test
    fun aHydratedPullWithAPushPendingAtApplyIsSkipped() {
        assertTrue(shouldSkipPulledAddons(hydrated = true, seqAtStart = 4L, seqNow = 4L, pushPendingAtStart = false, pushPendingNow = true))
    }

    @Test
    fun aHydratedPullWithNoLocalActivityApplies() {
        assertFalse(shouldSkipPulledAddons(hydrated = true, seqAtStart = 4L, seqNow = 4L, pushPendingAtStart = false, pushPendingNow = false))
    }
}
