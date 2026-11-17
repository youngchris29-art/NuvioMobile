package com.nuvio.app.core.auth

import io.github.jan.supabase.annotations.SupabaseInternal
import io.github.jan.supabase.auth.createDefaultSettingsKey
import io.github.jan.supabase.createSupabaseClient
import io.ktor.client.engine.HttpClientEngineBase
import io.ktor.client.engine.HttpClientEngineConfig
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.utils.io.InternalAPI
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * D1b: the auth debug knobs are inert outside debug builds, and the expired-session wrapper reads
 * the very store the library's default session manager uses.
 * Gradle runs jvmTest from the `shared` module dir, so sources are read from `src/`.
 */
class AuthDebugKnobsGuardTest {

    /** jvmTest has no Ktor engine on its classpath; this one only lets a client be built. */
    private class NoNetworkEngine : HttpClientEngineBase("no-network") {
        override val config = HttpClientEngineConfig()

        @InternalAPI
        override suspend fun execute(data: HttpRequestData): HttpResponseData = error("no network in this test")
    }

    private fun source(path: String) = File("src/$path").readText()

    @Test
    fun theJvmActualsAreInert() {
        assertFalse(debugAuthSessionExpired())
        assertFalse(debugAuthNetworkDown())
        assertFalse(authSessionTraceEnabled())
        assertNull(debugSessionRestoreStall())
    }

    @Test
    fun theAndroidActualsAreInert() {
        val text = source("androidMain/kotlin/com/nuvio/app/core/auth/AuthDebugKnobs.android.kt")
        assertTrue("internal actual fun debugAuthSessionExpired(): Boolean = false" in text)
        assertTrue("internal actual fun authSessionTraceEnabled(): Boolean = false" in text)
        assertTrue("internal actual fun debugAuthNetworkDown(): Boolean = false" in text)
    }

    /** Every Apple knob returns its inert value first unless the build-time debug const is set. */
    @Test
    fun everyAppleKnobIsCompiledOutOfReleaseBuilds() {
        val text = source("appleMain/kotlin/com/nuvio/app/core/auth/AuthDebugKnobs.apple.kt")
        val bodies = Regex("""internal actual fun (\w+)\(\)[^{=]*(\{[^}]*}|=[^\n]*)""").findAll(text).toList()
        assertEquals(
            setOf("debugSessionRestoreStall", "debugAuthNetworkDown", "debugAuthSessionExpired", "authSessionTraceEnabled"),
            bodies.map { it.groupValues[1] }.toSet(),
        )
        bodies.forEach { match ->
            val body = match.groupValues[2]
            val guarded = body.trimStart('{').trim().startsWith("if (!AppBuildConfig.IS_DEBUG_BUILD) return") ||
                body.trim() == "= AppBuildConfig.IS_DEBUG_BUILD"
            assertTrue(guarded, "${match.groupValues[1]} is not guarded by IS_DEBUG_BUILD: $body")
        }
    }

    @Test
    fun theWrapperIsInstalledOnlyBehindTheKnobAndTheTraceOnlyBehindItsSwitch() {
        val provider = source("commonMain/kotlin/com/nuvio/app/core/network/SupabaseProvider.kt")
        val wrapper = provider.indexOf("DebugExpiredSessionManager(")
        val guard = provider.lastIndexOf("if (debugAuthSessionExpired()) {", wrapper)
        assertTrue(wrapper > 0 && guard > 0 && provider.substring(guard, wrapper).count { it == '}' } == 0)
        val repository = source("commonMain/kotlin/com/nuvio/app/core/auth/AuthRepository.kt")
        assertTrue("if (authSessionTraceEnabled()) println(\"[AuthSession] \$line\")" in repository)
        assertEquals(1, Regex("""\[AuthSession]""").findAll(repository).count())
    }

    @OptIn(SupabaseInternal::class)
    @Test
    fun theWrapperReadsTheLibrarysDefaultSessionKey() {
        listOf(
            "https://abcdefgh.supabase.co",
            "https://abcdefgh.supabase.co/",
            "http://192.168.1.20:54321",
            "https://self-hosted.example.test/auth/",
        ).forEach { url ->
            val client = createSupabaseClient(url, "publishable-key") { httpEngine = NoNetworkEngine() }
            // supabase-kt 3.4.1 createDefaultSessionManager: createDefaultSettingsKey(supabaseUrl) + "-session".
            assertEquals(createDefaultSettingsKey(client.supabaseUrl) + "-session", defaultSessionSettingsKey(url), url)
        }
    }
}
