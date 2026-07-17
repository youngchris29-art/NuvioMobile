package com.nuvio.app.core.network

import com.nuvio.app.core.build.AppVersionConfig
import io.github.jan.supabase.annotations.SupabaseInternal
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.logging.LogLevel
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import io.ktor.client.plugins.HttpRequestRetry
import io.ktor.client.plugins.defaultRequest
import io.ktor.http.HttpHeaders
import io.ktor.http.takeFrom
import kotlin.time.Duration.Companion.seconds

object SupabaseProvider {
    @OptIn(SupabaseInternal::class)
    val client by lazy {
        // The realtime plugin logs every failed connect/receive at ERROR *with the throwable*,
        // and Kermit's Apple writer println()s throwable stack traces straight to stdout — so a
        // websocket drop (or a down endpoint) becomes steady multi-screen console churn.
        // Silence the plugin logger; RealtimeSyncInvalidationService logs client/channel status
        // transitions and failure summaries itself.
        Realtime.logger.setLevel(LogLevel.NONE)
        val userAgent = "NuvioMobile/${AppVersionConfig.VERSION_NAME.ifBlank { "dev" }}"
        createSupabaseClient(
            supabaseUrl = SupabaseConfig.URL,
            supabaseKey = SupabaseConfig.ANON_KEY,
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
            install(Realtime) {
                // supabase-kt retries a failed websocket on a fixed cadence forever (no
                // backoff); the 7s default hammers the endpoint during outages. Realtime is
                // best-effort here (periodic/foreground pulls cover sync), so reconnect gently.
                reconnectDelay = 30.seconds
            }
        }
    }
}
