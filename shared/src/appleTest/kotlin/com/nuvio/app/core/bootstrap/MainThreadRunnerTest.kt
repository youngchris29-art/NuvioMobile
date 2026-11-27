package com.nuvio.app.core.bootstrap

import kotlin.concurrent.AtomicInt
import kotlin.concurrent.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSDate
import platform.Foundation.NSRunLoop
import platform.Foundation.NSThread
import platform.Foundation.dateWithTimeIntervalSinceNow
import platform.Foundation.runUntilDate
import platform.darwin.DISPATCH_QUEUE_PRIORITY_DEFAULT
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_global_queue
import platform.posix.usleep

/*
 * Scope identity W3b review r1 #4: a fan-out step that clears main-confined state waits for the
 * main thread to run it, reports its failure, and with main held fails instead of returning early.
 */
@OptIn(ExperimentalForeignApi::class)
class MainThreadRunnerTest {
    /** Runs [work] on a background queue; returns its outcome (null: returned normally). */
    private fun offMain(pumpMain: Boolean, work: () -> Unit): Throwable? {
        val done = AtomicInt(0)
        val outcome = AtomicReference<Throwable?>(null)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT.toLong(), 0u)) {
            try { work() } catch (t: Throwable) { outcome.value = t } finally { done.value = 1 }
        }
        var spins = 0
        while (done.value == 0 && spins < 400) {
            if (pumpMain) NSRunLoop.mainRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(0.01)) else usleep(10_000u)
            spins++
        }
        assertEquals(1, done.value, "the background step finished")
        return outcome.value
    }

    private fun drainMain() {
        repeat(20) { NSRunLoop.mainRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(0.01)) }
    }

    @Test
    fun theStepReturnsOnlyAfterMainRanTheClear() {
        assertTrue(NSThread.isMainThread, "tests drive the main thread")
        val ran = AtomicInt(0)
        val ranAtReturn = AtomicInt(-1)
        val failure = offMain(pumpMain = true) {
            MainThreadRunner.runAndWait { ran.value = 1 }
            ranAtReturn.value = ran.value
        }
        assertEquals(null, failure)
        assertEquals(1, ranAtReturn.value, "the clear ran on main before the step returned")
    }

    @Test
    fun withMainHeldTheStepFailsInsteadOfReturningEarly() {
        val ran = AtomicInt(0)
        val failure = offMain(pumpMain = false) { MainThreadRunner.runAndWait(timeoutMs = 200) { ran.value = 1 } }
        assertNotNull(failure, "main held: the step is reported failed, never as done")
        assertEquals(0, ran.value)
        drainMain() // the queued clear runs once main is free (harmless)
        assertEquals(1, ran.value)
    }

    @Test
    fun aFailureOnMainReachesTheStep() {
        val failure = offMain(pumpMain = true) { MainThreadRunner.runAndWait { error("clear failed") } }
        assertEquals("clear failed", failure?.message)
    }

    @Test
    fun onMainItRunsInline() {
        val ran = AtomicInt(0)
        MainThreadRunner.runAndWait { ran.value = 1 }
        assertEquals(1, ran.value)
    }
}
