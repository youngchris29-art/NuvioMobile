@file:OptIn(InternalCoroutinesApi::class)

package com.nuvio.app.testing

import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.MainCoroutineDispatcher
import kotlinx.coroutines.internal.MainDispatcherFactory
import kotlin.coroutines.CoroutineContext

/**
 * `:shared:jvmTest` has no `Dispatchers.Main` (no Android/Swing/JavaFX module, and the repo does
 * not depend on kotlinx-coroutines-test), so any common code that hops onto Main — e.g.
 * `MetaDetailsRepository.clear()`, which `TmdbSettingsRepository` calls when the personal TMDB
 * key changes (upstream df589078) — threw "Module with the Main dispatcher is missing" in the JVM
 * tests. The tvOS/iOS test targets have a real main queue and do not load this.
 *
 * Registered through `META-INF/services/kotlinx.coroutines.internal.MainDispatcherFactory` in
 * `src/jvmTest/resources`. Runs every block inline on the calling thread, which is what
 * `Main.immediate` does for a caller already on main.
 */
class JvmTestMainDispatcherFactory : MainDispatcherFactory {
    override val loadPriority: Int = 0

    override fun createDispatcher(allFactories: List<MainDispatcherFactory>): MainCoroutineDispatcher =
        InlineMainDispatcher
}

private object InlineMainDispatcher : MainCoroutineDispatcher() {
    override val immediate: MainCoroutineDispatcher get() = this

    override fun isDispatchNeeded(context: CoroutineContext): Boolean = false

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        block.run()
    }

    override fun toString(): String = "JvmTestInlineMain"
}
