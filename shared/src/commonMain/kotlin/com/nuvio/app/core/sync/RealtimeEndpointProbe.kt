package com.nuvio.app.core.sync

import com.nuvio.app.core.network.SupabaseConfig
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.get
import kotlinx.coroutines.CancellationException

/**
 * Cheap health probe for the Supabase realtime endpoint.
 *
 * supabase-kt's realtime plugin retries a failed websocket connect on a fixed interval forever
 * (no backoff, no cap), and every attempt it makes is logged with a full stack trace — so
 * [RealtimeSyncInvalidationService] never engages the plugin until this probe says the endpoint
 * can plausibly serve a websocket. A plain (non-upgrade) GET on the websocket path is answered
 * with a 4xx by a live realtime service, while gateway/origin failures answer 5xx or fail at
 * the network layer — e.g. the Kong "name resolution failed" 503 seen when the realtime
 * upstream is down while REST/Auth still work.
 */
internal object RealtimeEndpointProbe {
    private const val PROBE_TIMEOUT_MS = 10_000L

    private val httpClient by lazy {
        HttpClient {
            install(HttpTimeout) {
                requestTimeoutMillis = PROBE_TIMEOUT_MS
                connectTimeoutMillis = PROBE_TIMEOUT_MS
            }
        }
    }

    /** Returns null when the endpoint looks serviceable, else a compact reason string. */
    suspend fun unhealthyReason(): String? {
        val url = "${SupabaseConfig.URL.trimEnd('/')}/realtime/v1/websocket" +
            "?apikey=${SupabaseConfig.ANON_KEY}&vsn=1.0.0"
        return try {
            val status = httpClient.get(url).status
            if (status.value < 500) null else "HTTP ${status.value}"
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            listOfNotNull(error::class.simpleName ?: "error", error.message?.take(160))
                .joinToString(": ")
        }
    }
}
