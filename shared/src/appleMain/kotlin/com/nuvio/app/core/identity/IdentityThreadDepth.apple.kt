package com.nuvio.app.core.identity

import kotlin.native.concurrent.ThreadLocal

/** Per-thread lock depths for IdentityLocks (spec 5.11): a thread-local object on Kotlin/Native. */
@ThreadLocal
internal actual object IdentityThreadDepth {
    private var commitDepth = 0
    private var applyDepth = 0

    actual fun commit(): Int = commitDepth
    actual fun setCommit(value: Int) { commitDepth = value }
    actual fun apply(): Int = applyDepth
    actual fun setApply(value: Int) { applyDepth = value }
}
