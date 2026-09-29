package com.nuvio.app.features.plugins.runtime

import com.dokar.quickjs.QuickJs
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.IO

// Upstream 2e244028 + 2d03b258 (composeApp/src/iosFull/.../PluginRuntime.ios.kt): scrapers run on
// a bounded background pool instead of the unbounded Default dispatcher, so a wide scraper fan-out
// cannot starve the rest of the app's Default work.
internal const val MAX_CONCURRENT_PLUGINS = 10
internal const val PLUGIN_TIMEOUT_MS = 60_000L

@OptIn(ExperimentalCoroutinesApi::class)
internal val pluginDispatcher: CoroutineDispatcher =
    Dispatchers.IO.limitedParallelism(MAX_CONCURRENT_PLUGINS)

// Fork: quickjs-kt 1.0.5-tvos has no `evaluationTimeoutMillis` (upstream's Android AAR and
// quickjs-kt 1.0.15 do), so this is a no-op exactly like upstream's iOS actual. A synchronous JS
// busy loop is still bounded only by the outer withTimeout, as before this port.
internal fun QuickJs.configurePluginRuntime() = Unit
