package com.nuvio.app.features.plugins.runtime.host

import co.touchlab.kermit.Logger
import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.define
import com.dokar.quickjs.binding.function
import com.nuvio.app.features.tmdb.TmdbSettingsRepository

internal class HostFunctions(
    private val scraperId: String,
    private val onResult: (String) -> Unit
) : HostModule {
    private val log = Logger.withTag("PluginRuntime")

    override fun register(runtime: QuickJs) {
        runtime.define("console") {
            function("log") { args ->
                log.d { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
            function("error") { args ->
                log.e { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
            function("warn") { args ->
                log.w { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
            function("info") { args ->
                log.i { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
            function("debug") { args ->
                log.d { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
        }

        // Upstream 60ee0160 + df589078: scrapers read the effective TMDB key through this host
        // function — the profile's personal override when set, otherwise the bundled key. Fork:
        // the tvOS runtime has no __get_scraper_id / __get_scraper_settings host functions (the
        // polyfill inlines those values), so this is the only one of upstream's three additions
        // that applies here.
        runtime.function("__get_tmdb_api_key") { TmdbSettingsRepository.effectiveApiKey() }
        runtime.function("__capture_result") { args ->
            onResult(args.getOrNull(0)?.toString() ?: "[]")
            null
        }
    }
}
