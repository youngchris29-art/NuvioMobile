package com.nuvio.app.core.network

import com.nuvio.app.core.build.AppVersionConfig
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.annotations.SupabaseInternal
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.postgrest.Postgrest
import io.ktor.client.plugins.HttpRequestRetry
import io.ktor.client.plugins.defaultRequest
import io.ktor.http.HttpHeaders
import io.ktor.http.takeFrom
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

object SupabaseProvider {
    // Guards the cache: concurrent first accesses (startup, or right after reset()) must not each
    // build a client — the loser's client would leak un-closed into long-lived collectors.
    private val clientLock = SynchronizedObject()
    private var cachedClient: SupabaseClient? = null

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
                if (SupabaseEndpointConfig.hasFallback) {
                    install(HttpRequestRetry) {
                        retryOnExceptionIf(maxRetries = 1) { request, cause ->
                            SupabaseEndpointConfig.shouldRetryWithFallback(
                                requestUrl = request.url.buildString(),
                                cause = cause,
                            )
                        }
                        retryIf(maxRetries = 1) { request, response ->
                            SupabaseEndpointConfig.shouldRetryWithFallback(
                                requestUrl = request.url.toString(),
                                statusCode = response.status.value,
                            )
                        }
                        modifyRequest { request ->
                            SupabaseEndpointConfig.fallbackUrlFor(request.url.buildString())?.let { fallbackUrl ->
                                request.url.takeFrom(fallbackUrl)
                            }
                        }
                        constantDelay(millis = 100)
                    }
                }
                defaultRequest {
                    headers.append(HttpHeaders.UserAgent, userAgent)
                }
            }
            install(Auth)
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
        previous?.close()
    }
}
