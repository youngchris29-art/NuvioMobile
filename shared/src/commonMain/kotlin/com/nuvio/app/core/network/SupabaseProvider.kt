package com.nuvio.app.core.network

import com.nuvio.app.core.auth.DebugExpiredSessionManager
import com.nuvio.app.core.auth.debugAuthNetworkDown
import com.nuvio.app.core.auth.debugAuthSessionExpired
import com.nuvio.app.core.auth.defaultSessionSettingsKey
import com.nuvio.app.core.build.AppVersionConfig
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.annotations.SupabaseInternal
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.SettingsSessionManager
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.postgrest.Postgrest
import io.ktor.client.plugins.HttpRequestRetry
import io.ktor.client.plugins.api.createClientPlugin
import io.ktor.client.plugins.defaultRequest
import io.ktor.http.HttpHeaders
import io.ktor.http.takeFrom
import io.ktor.utils.io.errors.IOException
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

object SupabaseProvider {
    // Guards the cache: concurrent first accesses (startup, or right after reset()) must not each
    // build a client — the loser's client would leak un-closed into long-lived collectors.
    private val clientLock = SynchronizedObject()
    private var cachedClient: SupabaseClient? = null
    private val rateLimitCoordinator = BackendRateLimitCoordinator()

    @OptIn(SupabaseInternal::class)
    val client: SupabaseClient
        get() = synchronized(clientLock) {
            cachedClient ?: createClient().also { cachedClient = it }
        }

    @OptIn(SupabaseInternal::class)
    private fun createClient(): SupabaseClient {
        val configuration = ServerConfigurationRepository.active.value
        val userAgent = "NuvioMobile/${AppVersionConfig.VERSION_NAME.ifBlank { "dev" }}"
        return createSupabaseClient(
            supabaseUrl = configuration.backendUrl,
            supabaseKey = configuration.publishableKey,
        ) {
            httpConfig {
                // Debug builds only (spec C6): the offline device rows without taking the box off Wi-Fi.
                if (debugAuthNetworkDown()) install(DebugNetworkDownPlugin)
                install(BackendRateLimitPlugin) {
                    coordinator = rateLimitCoordinator
                }
                install(HttpRequestRetry) {
                    retryOnExceptionIf(maxRetries = 1) { request, cause ->
                        isSafeBackendRetryRequest(
                            method = request.method.value,
                            encodedPath = request.url.build().encodedPath,
                        ) && SupabaseEndpointConfig.shouldRetryWithFallback(
                            requestUrl = request.url.buildString(),
                            cause = cause,
                        )
                    }
                    retryIf(maxRetries = 1) { request, response ->
                        val safeToRetry = isSafeBackendRetryRequest(
                            method = request.method.value,
                            encodedPath = request.url.encodedPath,
                        )
                        val retryableResponse = isRetryableBackendResponse(response.status.value)
                        val fallbackEligible = SupabaseEndpointConfig.shouldRetryWithFallback(
                            requestUrl = request.url.toString(),
                            statusCode = response.status.value,
                        )
                        safeToRetry && (retryableResponse || fallbackEligible)
                    }
                    modifyRequest { request ->
                        val retryResponse = response
                        val retryCause = cause
                        val shouldUseFallback = when {
                            retryResponse != null && shouldApplyBackendCooldown(
                                retryResponse.status.value,
                                retryResponse.headers[HttpHeaders.RetryAfter],
                            ) -> false
                            retryResponse != null -> SupabaseEndpointConfig.shouldRetryWithFallback(
                                requestUrl = request.url.buildString(),
                                statusCode = retryResponse.status.value,
                            )
                            retryCause != null -> SupabaseEndpointConfig.shouldRetryWithFallback(
                                requestUrl = request.url.buildString(),
                                cause = retryCause,
                            )
                            else -> false
                        }
                        if (shouldUseFallback) {
                            SupabaseEndpointConfig.fallbackUrlFor(request.url.buildString())?.let { fallbackUrl ->
                                request.url.takeFrom(fallbackUrl)
                            }
                        }
                    }
                    delayMillis(respectRetryAfterHeader = false) { retryCount ->
                        val retryResponse = response
                        if (retryResponse != null && isRetryableBackendResponse(retryResponse.status.value)) {
                            backendRetryDelayMillis(
                                retryCount = retryCount,
                                retryAfterHeader = retryResponse.headers[HttpHeaders.RetryAfter],
                            )
                        } else {
                            100L
                        }
                    }
                }
                defaultRequest {
                    headers.append(HttpHeaders.UserAgent, userAgent)
                }
            }
            install(Auth) {
                // Debug builds only (D1b): restore the stored session as if it had expired while the
                // app was closed, in memory only. Same store and key as the library's default.
                if (debugAuthSessionExpired()) {
                    sessionManager = DebugExpiredSessionManager(
                        SettingsSessionManager(key = defaultSessionSettingsKey(configuration.backendUrl)),
                    )
                }
            }
            install(Postgrest)
            install(Functions)
        }
    }

    /**
     * Drops (and closes) the cached client so the next [client] access builds one against the
     * current [ServerConfigurationRepository.active] server. Callers must cancel/re-arm every
     * long-lived collector that captured the previous client (see ServerConnectionController).
     */
    suspend fun reset() {
        val previous = synchronized(clientLock) {
            cachedClient.also { cachedClient = null }
        }
        rateLimitCoordinator.clear()
        previous?.close()
    }
}

/** Fails every request before it is sent, as an offline device would (`-debug.authNetworkDown`). */
private val DebugNetworkDownPlugin = createClientPlugin("DebugNetworkDown") {
    onRequest { request, _ ->
        throw IOException("debug.authNetworkDown: simulated network failure for ${request.url.host}")
    }
}
