package com.nuvio.app.features.mdblist

// JVM actual for the :shared jvm test target (fork-only; upstream has no JVM target). In-memory,
// like PlatformMdbListAuthPersistence in MdbListPlatform.jvm.kt: tests that exercise sync storage
// pass their own MdbListSyncStorage fake.

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

internal actual object PlatformMdbListSyncStorage : MdbListSyncStorage {
    private val lock = SynchronizedObject()
    private val payloads = mutableMapOf<Int, String>()

    actual override suspend fun load(profileId: Int): String? = synchronized(lock) { payloads[profileId] }

    actual override suspend fun save(profileId: Int, payload: String, checkScope: () -> Unit) {
        checkScope()
        synchronized(lock) { payloads[profileId] = payload }
    }

    actual override suspend fun remove(profileId: Int, checkScope: () -> Unit) {
        checkScope()
        synchronized(lock) { payloads.remove(profileId) }
    }

    actual fun clearAll() = synchronized(lock) { payloads.clear() }
}
