package com.nuvio.app.core.identity

import kotlin.native.concurrent.ThreadLocal

/** Per-thread lock depths for IdentityLocks (spec 5.11): a thread-local object on Kotlin/Native. */
@ThreadLocal
internal actual object IdentityThreadDepth {
    private var commitDepth = 0
    private var applyDepth = 0
    private var registryDepth = 0
    private var handlerDepth = 0
    private var windowBodyDepth = 0

    actual fun commit(): Int = commitDepth
    actual fun setCommit(value: Int) { commitDepth = value }
    actual fun apply(): Int = applyDepth
    actual fun setApply(value: Int) { applyDepth = value }
    actual fun registry(): Int = registryDepth
    actual fun setRegistry(value: Int) { registryDepth = value }
    actual fun handler(): Int = handlerDepth
    actual fun setHandler(value: Int) { handlerDepth = value }
    actual fun inWindowBody(): Int = windowBodyDepth
    actual fun setInWindowBody(value: Int) { windowBodyDepth = value }
}
