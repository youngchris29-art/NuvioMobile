package com.nuvio.app.core.identity

/** Puts every identity singleton back to a fresh Open state (the objects are process-wide). */
internal fun resetIdentityForTest(slot: Int = 1, serial: Long = 0, activeSlot: (() -> Int)? = null) {
    IdentityWork.resetForTest()
    IdentityRuntime.resetForTest(slot = slot, serial = serial, activeSlot = activeSlot)
    IdentityGate.resetForTest()
    IdentityBarrier.resetForTest()
    IdentityImmediate.resetForTest()
    IdentityRevocation.revoker = null
    IdentityRevocation.required = false
    IdentityLocks.strictLockOrder = true
}

internal val accountA = AccountKey.Account("user-a")
internal val accountB = AccountKey.Account("user-b")
