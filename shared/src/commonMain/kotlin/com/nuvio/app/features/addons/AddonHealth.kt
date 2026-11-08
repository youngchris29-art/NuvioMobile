package com.nuvio.app.features.addons

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Add-ons hub v2 (C4): the outcome of an add-on's last manifest fetch. */
data class AddonHealth(
    val latencyMs: Long?,
    val failed: Boolean,
    val checkedAtEpochMs: Long,
)

/**
 * Last manifest-fetch health per add-on, keyed by manifest URL. Written by
 * [AddonRepository]'s refresh job; read by the hub's status dots. A new result replaces the
 * previous one for the same URL.
 */
object AddonHealthTracker {
    private val _health = MutableStateFlow<Map<String, AddonHealth>>(emptyMap())
    val health: StateFlow<Map<String, AddonHealth>> = _health.asStateFlow()

    fun record(
        manifestUrl: String,
        latencyMs: Long?,
        failed: Boolean,
        nowEpochMs: Long = kotlin.time.Clock.System.now().toEpochMilliseconds(),
    ) {
        _health.update { it + (manifestUrl to AddonHealth(latencyMs, failed, nowEpochMs)) }
    }

    /** C4 review r2: an add-on (re)installed starts without the old result for its URL. */
    fun forget(manifestUrl: String) {
        _health.update { it - manifestUrl }
    }

    fun clear() {
        _health.value = emptyMap()
    }
}
