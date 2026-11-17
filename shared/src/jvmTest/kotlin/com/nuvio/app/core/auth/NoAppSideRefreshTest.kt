package com.nuvio.app.core.auth

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Invariant I5 (spec 3g, review finding r6-1): app code never refreshes a session or imports a
 * refreshed one. The only refresher is supabase-kt's own session job, which a newer import cancels.
 * Scans the shared and composeApp main sources (Gradle runs jvmTest from the `shared` module dir).
 * Also pins that the ticket-less `signOutIfSessionInvalid` entry point (r6-3) is gone.
 */
class NoAppSideRefreshTest {
    private val forbidden = listOf("refreshCurrentSession(", "refreshSession(", "importSession(", "signOutIfSessionInvalid(")

    private fun mainSources(): List<File> {
        val roots = listOf(File("src"), File("../composeApp/src"))
            .filter { it.isDirectory }
        return roots.flatMap { root ->
            root.walkTopDown()
                .filter { it.isFile && it.extension == "kt" }
                .filter { file -> file.path.split(File.separatorChar).any { it.endsWith("Main") } }
                .toList()
        }
    }

    @Test
    fun theSourceTreeIsReadable() {
        assertTrue(mainSources().any { it.name == "AuthRepository.kt" }, "shared main sources not found from ${File(".").absolutePath}")
    }

    @Test
    fun noAppCodeRefreshesOrImportsASession() {
        val hits = mainSources().flatMap { file ->
            file.readLines().mapIndexedNotNull { index, line ->
                forbidden.firstOrNull { it in line }?.let { "${file.path}:${index + 1}: $it" }
            }
        }
        assertEquals(emptyList(), hits)
    }
}
