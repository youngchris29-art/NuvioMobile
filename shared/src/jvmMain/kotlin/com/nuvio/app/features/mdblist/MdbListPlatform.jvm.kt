package com.nuvio.app.features.mdblist

// JVM actuals for shared/src/jvmMain (the :shared jvm test target — neither app ships it; see
// docs/issue-triage-plan-2026-08-21.md §6.1). Fork-only: upstream has no JVM target.
//
// Token persistence is an in-memory map: the JVM target backs unit tests only, and tests that
// exercise the store pass their own MdbListTestPersistence anyway.
//
// There is no Ktor engine on the JVM test classpath, so createMdbListHttpClient() fails loudly
// instead of guessing one. Nothing reaches it at construction time: MdbListTracker builds its
// MdbListNetworkEngine lazily (first real request), and tests drive MdbListHttpClient with
// MdbListTestEngine instead of the network engine.

import io.ktor.client.HttpClient
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

internal actual object PlatformMdbListAuthPersistence : MdbListAuthPersistence {
    private val lock = SynchronizedObject()
    private val profiles = mutableMapOf<Int, String>()

    actual override fun read(profileId: Int): String? = synchronized(lock) { profiles[profileId] }

    actual override fun write(profileId: Int, value: String?) = synchronized(lock) {
        if (value == null) profiles.remove(profileId) else profiles[profileId] = value
        Unit
    }

    actual override fun clear() = synchronized(lock) { profiles.clear() }
}

internal actual fun createMdbListHttpClient(): HttpClient =
    throw UnsupportedOperationException(
        "The :shared JVM target has no Ktor engine; drive MdbListHttpClient with a test MdbListHttpEngine",
    )
