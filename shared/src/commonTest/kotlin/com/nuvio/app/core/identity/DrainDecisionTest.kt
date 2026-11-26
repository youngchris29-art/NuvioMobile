package com.nuvio.app.core.identity

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/** Spec 4.3a point 3: kind {8} × profileJobs {0,1} × accountJobs {0,1} × ack × teardownRequired × deadline = 256 cases. */
class DrainDecisionTest {

    private val accountKinds = setOf(TransitionKind.SignOut, TransitionKind.DeleteAccount, TransitionKind.ServerSwitch)

    private fun oracle(kind: TransitionKind, p: Int, a: Int, ack: Boolean, required: Boolean, deadline: Boolean): DrainEnd? {
        val waitingFor = if (kind in accountKinds) p + a else p
        val settled = waitingFor == 0 && (ack || !required)
        if (settled) return DrainEnd.Settled
        if (!deadline) return null
        return if (required && !ack) DrainEnd.TeardownUnconfirmed else DrainEnd.JobsDeadline
    }

    @Test
    fun everyCombination() {
        var count = 0
        for (kind in TransitionKind.entries) for (p in 0..1) for (a in 0..1)
            for (ack in listOf(false, true)) for (required in listOf(false, true)) for (deadline in listOf(false, true)) {
                val actual = DrainDecision.decide(kind, DrainView(p, a, ack), required, deadline)
                assertEquals(oracle(kind, p, a, ack, required, deadline), actual, "$kind p=$p a=$a ack=$ack req=$required dl=$deadline")
                if (deadline) assertNotNull(actual)
                count++
            }
        assertEquals(256, count)
    }

    @Test
    fun profileDrainIgnoresAccountJobs() {
        assertEquals(DrainEnd.Settled, DrainDecision.decide(TransitionKind.ProfileSelect, DrainView(0, 3, false), false, false))
        assertEquals(null, DrainDecision.decide(TransitionKind.SignOut, DrainView(0, 3, false), false, false))
    }
}
