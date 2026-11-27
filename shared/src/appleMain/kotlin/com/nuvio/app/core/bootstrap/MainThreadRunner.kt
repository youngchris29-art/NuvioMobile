package com.nuvio.app.core.bootstrap

import kotlin.concurrent.AtomicReference
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSThread
import platform.darwin.DISPATCH_TIME_NOW
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import platform.darwin.dispatch_semaphore_create
import platform.darwin.dispatch_semaphore_signal
import platform.darwin.dispatch_semaphore_wait
import platform.darwin.dispatch_time

/**
 * Fork (scope identity W3b review r1 #4): runs a main-confined clear on the main thread and WAITS
 * for it, so a checked fan-out step neither reports success before the clear ran nor loses its
 * failure. On the main thread it runs inline (no hop, so a fan-out driven from main cannot
 * deadlock). Off main it queues the block and waits at most [timeoutMs]: if main does not run it in
 * time (main held, or main waiting on this thread) the step fails, which the must-succeed fan-out
 * reports, instead of blocking forever. A block that ran late after a timeout is harmless (a clear).
 */
@OptIn(ExperimentalForeignApi::class)
internal object MainThreadRunner {
    const val DEFAULT_TIMEOUT_MS = 5_000L

    fun runAndWait(timeoutMs: Long = DEFAULT_TIMEOUT_MS, block: () -> Unit) {
        if (NSThread.isMainThread) {
            block()
            return
        }
        val failure = AtomicReference<Throwable?>(null)
        val semaphore = dispatch_semaphore_create(0)
        dispatch_async(dispatch_get_main_queue()) {
            try {
                block()
            } catch (t: Throwable) {
                failure.value = t
            } finally {
                dispatch_semaphore_signal(semaphore)
            }
        }
        val waited = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, timeoutMs * 1_000_000))
        if (waited != 0L) error("the main thread did not run the step within $timeoutMs ms")
        failure.value?.let { throw it }
    }
}
