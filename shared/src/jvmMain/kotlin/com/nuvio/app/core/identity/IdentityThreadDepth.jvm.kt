package com.nuvio.app.core.identity

/** Per-thread lock depths for IdentityLocks (spec 5.11); plain java.lang.ThreadLocal. */
internal actual object IdentityThreadDepth {
    private val commitDepth = ThreadLocal.withInitial { 0 }
    private val applyDepth = ThreadLocal.withInitial { 0 }
    private val registryDepth = ThreadLocal.withInitial { 0 }
    private val handlerDepth = ThreadLocal.withInitial { 0 }

    actual fun commit(): Int = commitDepth.get()
    actual fun setCommit(value: Int) = commitDepth.set(value)
    actual fun apply(): Int = applyDepth.get()
    actual fun setApply(value: Int) = applyDepth.set(value)
    actual fun registry(): Int = registryDepth.get()
    actual fun setRegistry(value: Int) = registryDepth.set(value)
    actual fun handler(): Int = handlerDepth.get()
    actual fun setHandler(value: Int) = handlerDepth.set(value)
}
