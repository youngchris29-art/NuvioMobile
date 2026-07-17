package com.nuvio.app.core.sync

import co.touchlab.kermit.Logger
import com.nuvio.app.core.network.SupabaseProvider
import io.github.jan.supabase.postgrest.query.filter.FilterOperator
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

private const val REALTIME_INVALIDATION_COALESCE_MS = 500L
private const val REALTIME_SUBSCRIBE_TIMEOUT_MS = 15_000L

object RealtimeSyncInvalidationService {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val log = Logger.withTag("RealtimeSyncInvalidation")
    private val pendingMutex = Mutex()
    private val pendingSurfaces = mutableSetOf<String>()

    private var subscriptionJob: Job? = null
    private var drainJob: Job? = null
    private var activeUserId: String? = null
    private var activeProfileId: Int? = null

    fun start(userId: String, profileId: Int) {
        if (
            subscriptionJob?.isActive == true &&
            activeUserId == userId &&
            activeProfileId == profileId
        ) {
            log.d { "Realtime sync already active for profile $profileId" }
            return
        }

        stop()
        activeUserId = userId
        activeProfileId = profileId
        subscriptionJob = scope.launch {
            val channelName = "sync-invalidations:$userId:$profileId"
            var consecutiveFailures = 0
            while (isActive) {
                // Gate on a cheap plain-HTTP probe before touching supabase-kt: once its
                // realtime plugin sees a failed connect it schedules an internal reconnect
                // loop that retries forever, so against a down endpoint it must never engage.
                val unhealthyReason = RealtimeEndpointProbe.unhealthyReason()
                if (unhealthyReason != null) {
                    consecutiveFailures += 1
                    val retryDelay = RealtimeSyncRetryPolicy.delayMs(consecutiveFailures)
                    if (consecutiveFailures == 1) {
                        log.w {
                            "Realtime endpoint unavailable ($unhealthyReason); live sync paused, " +
                                "probing again in ${retryDelay}ms (periodic/foreground pulls still run)"
                        }
                    } else {
                        log.d {
                            "Realtime endpoint still unavailable ($unhealthyReason) " +
                                "failures=$consecutiveFailures nextProbeIn=${retryDelay}ms"
                        }
                    }
                    delay(retryDelay)
                    continue
                }

                val channel = SupabaseProvider.client.channel(channelName)
                val realtime = channel.realtime
                val realtimeStatusJob = launch {
                    realtime.status
                        .collect { status ->
                            log.i { "Realtime client status=$status channel=$channelName" }
                        }
                }
                val channelStatusJob = launch {
                    channel.status
                        .collect { status ->
                            log.i { "Realtime channel status=$status channel=$channelName" }
                        }
                }
                val changesJob = channel.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
                    table = "sync_invalidations"
                    filter("user_id", FilterOperator.EQ, userId)
                }.onEach { action ->
                    handleInsert(profileId, action.record)
                }.launchIn(this)

                var failure: Throwable? = null
                try {
                    log.i { "Subscribing to sync invalidations channel=$channelName user=$userId profile=$profileId" }
                    withTimeout(REALTIME_SUBSCRIBE_TIMEOUT_MS) {
                        channel.subscribe(blockUntilSubscribed = true)
                    }
                    consecutiveFailures = 0
                    log.i { "Subscribed to sync invalidations channel=$channelName profile=$profileId" }
                    awaitCancellation()
                } catch (error: TimeoutCancellationException) {
                    failure = error
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    failure = error
                } finally {
                    changesJob.cancel()
                    realtimeStatusJob.cancel()
                    channelStatusJob.cancel()
                    // Evict the channel from the client's registry — a bare unsubscribe() would
                    // leave it cached there and every later reconnect would try to rejoin it.
                    // With no subscriptions left the client also closes the websocket instead of
                    // holding an idle connection between retries.
                    withContext(NonCancellable) {
                        runCatching { realtime.removeChannel(channel) }
                            .onFailure { error ->
                                log.d { "Failed to remove realtime channel $channelName: ${error.message}" }
                            }
                    }
                }

                if (failure != null && isActive) {
                    consecutiveFailures += 1
                    val retryDelay = RealtimeSyncRetryPolicy.delayMs(consecutiveFailures)
                    val reason = describeFailure(failure)
                    // Routine failures log as a single line; the throwable (which the Apple log
                    // writer prints as a full stack trace) is only attached to the first
                    // unexpected failure of a streak.
                    if (consecutiveFailures == 1 && failure !is TimeoutCancellationException) {
                        log.w(failure) {
                            "Realtime subscribe failed ($reason) channel=$channelName; retrying in ${retryDelay}ms"
                        }
                    } else {
                        log.w {
                            "Realtime subscribe failed ($reason) channel=$channelName " +
                                "failures=$consecutiveFailures; retrying in ${retryDelay}ms"
                        }
                    }
                    delay(retryDelay)
                }
            }
        }
    }

    fun stop() {
        if (subscriptionJob != null || drainJob != null) {
            log.i { "Stopping realtime sync invalidation service for profile $activeProfileId" }
        }
        subscriptionJob?.cancel()
        drainJob?.cancel()
        subscriptionJob = null
        drainJob = null
        activeUserId = null
        activeProfileId = null
        pendingSurfaces.clear()
    }

    private fun describeFailure(error: Throwable): String = when (error) {
        is TimeoutCancellationException ->
            "timed out after ${REALTIME_SUBSCRIBE_TIMEOUT_MS}ms waiting for subscription"
        else -> listOfNotNull(error::class.simpleName ?: "error", error.message?.take(160))
            .joinToString(": ")
    }

    private fun handleInsert(profileId: Int, record: JsonObject) {
        val eventId = record["id"]?.jsonPrimitive?.contentOrNull
        val createdAt = record["created_at"]?.jsonPrimitive?.contentOrNull
        val originClientId = record["origin_client_id"]?.jsonPrimitive?.contentOrNull
        if (originClientId != null && originClientId == SyncClientIdentity.currentClientId()) {
            log.d { "Ignoring self-originated sync invalidation id=$eventId originClientId=$originClientId" }
            return
        }
        val surface = record["surface"]?.jsonPrimitive?.contentOrNull ?: run {
            log.w { "Received sync invalidation without surface id=$eventId createdAt=$createdAt keys=${record.keys}" }
            return
        }
        val eventProfileId = record["profile_id"]?.jsonPrimitive?.intOrNull
        log.i {
            "Received sync invalidation id=$eventId surface=$surface eventProfile=$eventProfileId " +
                "activeProfile=$profileId originClientId=$originClientId createdAt=$createdAt"
        }
        if (surface != "profiles" && eventProfileId != null && eventProfileId != profileId) {
            log.d { "Ignoring sync invalidation id=$eventId for inactive profile $eventProfileId" }
            return
        }
        enqueue(surface, profileId)
    }

    private fun enqueue(surface: String, profileId: Int) {
        scope.launch {
            pendingMutex.withLock {
                pendingSurfaces += surface
                log.d { "Queued realtime surface pull surface=$surface profile=$profileId pending=${pendingSurfaces.size}" }
                if (drainJob?.isActive == true) return@withLock
                drainJob = scope.launch {
                    delay(REALTIME_INVALIDATION_COALESCE_MS)
                    val surfaces = pendingMutex.withLock {
                        pendingSurfaces.toList().also {
                            pendingSurfaces.clear()
                        }
                    }
                    log.i { "Draining realtime surface pulls profile=$profileId surfaces=$surfaces" }
                    surfaces.forEach { pendingSurface ->
                        SyncManager.requestRealtimeSurfacePull(profileId, pendingSurface)
                    }
                }
            }
        }
    }
}
