package com.nuvio.app.features.cloud

import com.nuvio.app.core.identity.AccountKey
import com.nuvio.app.core.identity.BarrierState
import com.nuvio.app.core.identity.IdentityEpoch
import com.nuvio.app.core.identity.IdentityRuntime
import com.nuvio.app.core.identity.IdentityScope
import com.nuvio.app.core.identity.eventually
import com.nuvio.app.core.identity.resetIdentityForTest
import com.nuvio.app.features.debrid.DebridProviders
import com.nuvio.app.features.debrid.DebridServiceCredential
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/*
 * Scope identity W3b (spec 9.1.5): every Cloud write, read and return runs on the token captured as
 * the call's first statement. Profile A (slot 1) switches to profile B (slot 2, a new epoch) at the
 * marked point; B's Cloud state in memory is MARKER and must stay untouched; nothing of A reaches
 * the caller.
 */

private fun real(block: suspend CoroutineScope.() -> Unit) = runTest { withContext(Dispatchers.Default) { block() } }

private val guest = AccountKey.Guest("g")
private val keyA = DebridServiceCredential(DebridProviders.Torbox, "key-of-a")
private val keyB = DebridServiceCredential(DebridProviders.Premiumize, "key-of-b")

private val fileA = CloudLibraryFile(id = "f1", name = "a.mkv")
private val itemA = CloudLibraryItem(providerId = DebridProviders.TORBOX_ID, providerName = "Torbox", id = "1", type = CloudLibraryItemType.Torrent, name = "A item", files = listOf(fileA))
private val listingA = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, items = listOf(itemA))))
private val scopeA = IdentityScope(guest, 1)
private val MARKER = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Premiumize)))

/** Per-profile Debrid settings; [profile] flips at the switch. */
private class FakeSettings : CloudLibraryRepository.Settings {
    var profile = 1
    val enabled = mutableMapOf(1 to true, 2 to true)
    val credentials = mutableMapOf(1 to listOf(keyA), 2 to listOf(keyB))
    var afterEnabledRead: () -> Unit = {}
    var afterCredentialsRead: () -> Unit = {}

    override fun load() {}
    override fun enabled(): Boolean = enabled.getValue(profile).also { afterEnabledRead() }
    override fun credentials(): List<DebridServiceCredential> = credentials.getValue(profile).also { afterCredentialsRead() }
}

/** Provider calls with a gate per call, recording the credentials each was handed. */
private class FakeBackend : CloudLibraryRepository.Backend {
    val handed = mutableListOf<List<DebridServiceCredential>>()
    var listing: CloudLibraryUiState = listingA
    var gate: CompletableDeferred<Unit>? = null
    var entered = CompletableDeferred<Unit>()
    /** Per-call gates (call i waits on perCall[i]) and how many refresh calls have started. */
    val perCall = mutableListOf<CompletableDeferred<Unit>>()
    /** Per-call listings (call i returns perCallListing[i]); else [listing]. */
    val perCallListing = mutableListOf<CloudLibraryUiState>()
    val started = MutableStateFlow(0)
    var throwAll = false

    override suspend fun refresh(credentials: List<DebridServiceCredential>): CloudLibraryUiState {
        handed += credentials
        val index = started.value
        started.update { it + 1 }
        entered.complete(Unit)
        perCall.getOrNull(index)?.await() ?: gate?.await()
        if (throwAll) error("provider failed")
        return perCallListing.getOrNull(index) ?: listing
    }

    val resolvedFiles = mutableListOf<CloudLibraryFile>()

    override suspend fun resolvePlayback(item: CloudLibraryItem, file: CloudLibraryFile, credentials: List<DebridServiceCredential>): CloudLibraryPlaybackResult {
        handed += credentials
        resolvedFiles += file
        entered.complete(Unit)
        gate?.await()
        return CloudLibraryPlaybackResult.Success(url = "https://example.invalid/stream")
    }
}

class CloudPublishGateTest {
    private val settings = FakeSettings()
    private val backend = FakeBackend()
    private val lines = MutableStateFlow<List<String>>(emptyList())

    @BeforeTest fun setUp() {
        resetIdentityForTest(slot = 1, serial = 1)
        IdentityRuntime.setForTest(BarrierState.initial(1).copy(scope = IdentityScope(guest, 1), latestAccount = guest))
        CloudLibraryRepository.resetForTest()
        CloudLibraryRepository.settings = settings
        CloudLibraryRepository.backend = backend
        CloudLibraryRepository.logSink = { line -> lines.update { it + line } }
    }

    @AfterTest fun tearDown() {
        CloudLibraryRepository.resetForTest()
        resetIdentityForTest()
    }

    /** Profile B opens (new slot and epoch); its Cloud state in memory is MARKER. */
    private fun switchToB() {
        IdentityRuntime.setForTest(BarrierState.initial(2).copy(scope = IdentityScope(guest, 2), latestAccount = guest, epoch = IdentityEpoch(2)))
        settings.profile = 2
        CloudLibraryRepository.setStateForTest(MARKER)
    }

    private fun state() = CloudLibraryRepository.uiState.value
    private fun lineCount(text: String) = lines.value.count { text in it }

    @Test
    fun wa_disabledDecisionOfAnotherProfileNeverClearsTheNewState() {
        settings.enabled[1] = false
        settings.afterEnabledRead = { settings.afterEnabledRead = {}; switchToB() }
        CloudLibraryRepository.ensureLoaded()
        assertEquals(MARKER, state())
    }

    @Test
    fun wb_sameViaRefresh() {
        settings.enabled[1] = false
        settings.afterEnabledRead = { settings.afterEnabledRead = {}; switchToB() }
        CloudLibraryRepository.refresh()
        assertEquals(MARKER, state())
    }

    @Test
    fun we_lookupReturnsNotFoundNeverDisabled() = real {
        settings.enabled[1] = false
        settings.afterEnabledRead = { settings.afterEnabledRead = {}; switchToB() }
        val result = CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, result)
        assertEquals(MARKER, state())
    }

    @Test
    fun wc_switchBeforeTheStartCommitLaunchesNothing() = real {
        settings.afterCredentialsRead = { settings.afterCredentialsRead = {}; switchToB() }
        CloudLibraryRepository.refresh()
        assertFalse(state().isRefreshing)
        assertEquals(MARKER, state())
        delay(100)
        assertEquals(emptyList(), backend.handed, "nothing launched")
    }

    @Test
    fun wd_switchDuringTheRefreshPublishesNothing() = real {
        backend.gate = CompletableDeferred()
        CloudLibraryRepository.refresh()
        backend.entered.await()
        switchToB()
        backend.gate!!.complete(Unit)
        eventually { lineCount("refused site=cloudRefresh stage=commit") == 1 }
        assertEquals(MARKER, state())
    }

    @Test
    fun wj_notConnectedOfTheOldProfileNeverReturned() = real {
        settings.credentials[1] = emptyList()
        settings.afterCredentialsRead = { settings.afterCredentialsRead = {}; switchToB() }
        val result = CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, result)
    }

    @Test
    fun wf_cachedTargetOfTheOldProfileNeverReturned() = real {
        CloudLibraryRepository.setStateForTest(listingA, scopeA)
        settings.afterCredentialsRead = {
            settings.afterCredentialsRead = {}
            IdentityRuntime.setForTest(BarrierState.initial(2).copy(scope = IdentityScope(guest, 2), latestAccount = guest, epoch = IdentityEpoch(2)))
            settings.profile = 2 // the cache still holds A's listing
        }
        val result = CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, result)
        assertEquals(listingA, state(), "the cache was not touched")
    }

    @Test
    fun wgh_freshLookupRefusedDuringTheRefresh() = real {
        backend.gate = CompletableDeferred()
        val lookup = async {
            CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))
        }
        backend.entered.await()
        switchToB()
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
        assertEquals(MARKER, state())
    }

    @Test
    fun wi_noUrlStoredWhenTheResolveIsRefused() = real {
        CloudLibraryRepository.setStateForTest(listingA, scopeA)
        backend.gate = CompletableDeferred()
        val resolve = async { CloudLibraryRepository.resolvePlayback(itemA, fileA) }
        backend.entered.await()
        switchToB()
        CloudLibraryRepository.setStateForTest(listingA, scopeA) // A's listing back in memory: no URL may join it
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackResult.Failed(), resolve.await())
        assertEquals(listingA, state())
    }

    @Test
    fun credentials_theStoreIsHandedTheCapturedProfilesKey() = real {
        CloudLibraryRepository.beforeStoreCallForTest = { CloudLibraryRepository.beforeStoreCallForTest = {}; switchToB() }
        CloudLibraryRepository.refresh()
        eventually { lineCount("refused site=cloudRefresh stage=commit") == 1 }
        assertEquals(listOf(listOf(keyA)), backend.handed)
        assertEquals(MARKER, state())
    }

    @Test
    fun configuredProviders_refusedAfterTheCapture() {
        assertEquals(listOf(DebridProviders.Torbox), CloudLibraryRepository.configuredProviders())
        settings.afterCredentialsRead = { settings.afterCredentialsRead = {}; switchToB() }
        assertEquals(emptyList(), CloudLibraryRepository.configuredProviders())
    }

    @Test
    fun hold_aCancelledJobStillMakesOneRefusedAttempt() = real {
        CloudLibraryRepository.debugHoldMs = 300
        CloudLibraryRepository.refresh()
        eventually { lineCount("hold begin") == 1 }
        switchToB()
        CloudLibraryRepository.cancelJobsForTest()
        eventually(timeoutMs = 3_000) { lineCount("stale publish refused site=cloudRefresh") == 1 }
        delay(100)
        assertEquals(1, lineCount("refused site=cloudRefresh stage=commit"))
        assertEquals(1, lineCount("stale publish refused"))
        assertEquals(MARKER, state())
    }

    // Review r1 #1: the refreshing marker never outlives the refresh that set it.

    @Test
    fun r1_sameAccountSerialChangeDuringARefreshLeavesNoMarker() = real {
        backend.gate = CompletableDeferred()
        CloudLibraryRepository.refresh()
        backend.entered.await()
        assertTrue(state().isRefreshing)
        IdentityRuntime.authSerial = { 2 } // the session changes; same account and profile, no fan-out
        backend.gate!!.complete(Unit)
        eventually { lineCount("refused site=cloudRefresh stage=commit") == 1 }
        eventually { !state().isRefreshing }
        CloudLibraryRepository.ensureLoaded() // the gate reopened: the listing loads again
        eventually { backend.started.value == 2 }
    }

    @Test
    fun r1_aCancelledRefreshLeavesNoMarker() = real {
        CloudLibraryRepository.setStateForTest(listingA, scopeA) // loaded: no initial-load retry (r3 #2)
        backend.gate = CompletableDeferred()
        CloudLibraryRepository.refresh()
        backend.entered.await()
        CloudLibraryRepository.cancelJobsForTest()
        eventually { !state().isRefreshing }
    }

    @Test
    fun r1_anOlderRefreshNeverClearsANewerMarker() = real {
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        backend.perCall += first
        backend.perCall += second
        CloudLibraryRepository.refresh()
        eventually { backend.started.value == 1 }
        IdentityRuntime.authSerial = { 2 }
        CloudLibraryRepository.refresh() // a newer refresh, under the new session
        eventually { backend.started.value == 2 }
        first.complete(Unit) // the older one ends refused
        eventually { lineCount("refused site=cloudRefresh stage=commit") == 1 }
        delay(100)
        assertTrue(state().isRefreshing, "the newer refresh still owns the marker")
        second.complete(Unit)
        eventually { !state().isRefreshing && state().providers == listingA.providers }
    }

    // Review r2 #1/#2: the marker is owned by CloudRefreshMarker; abandon runs on job completion.

    @Test
    fun r2_cancelBetweenRegistrationAndBodyEntryLeavesNoMarker() = runTest {
        // A paused dispatcher: the registered job is started but its body never runs.
        CloudLibraryRepository.scope = CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.test.StandardTestDispatcher(testScheduler))
        CloudLibraryRepository.refresh()
        assertTrue(state().isRefreshing)
        CloudLibraryRepository.cancelJobsForTest()
        testScheduler.runCurrent() // the cancelled job completes without entering its body
        assertFalse(state().isRefreshing, "the job's completion abandoned its marker")
        assertEquals(0, backend.started.value, "the body never ran")
    }

    private val listing1 = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, items = listOf(itemA.copy(name = "first")))))
    private val listing2 = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, items = listOf(itemA.copy(name = "second")))))

    private suspend fun twoRefreshes(): Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>> {
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, second)
        backend.perCallListing += listOf(listing1, listing2)
        CloudLibraryRepository.refresh()
        eventually { backend.started.value == 1 }
        CloudLibraryRepository.refresh() // same identity: supersedes the first
        eventually { backend.started.value == 2 }
        return first to second
    }

    @Test
    fun r2_olderFinishesFirstUnderOneIdentity() = real {
        val (first, second) = twoRefreshes()
        first.complete(Unit)
        delay(150)
        assertTrue(state().isRefreshing, "the older result never hides the newer loading state")
        assertFalse(state().providers.any { p -> p.items.any { it.name == "first" } }, "and is never written")
        second.complete(Unit)
        eventually { !state().isRefreshing && state().providers == listing2.providers }
    }

    @Test
    fun r2_newerFinishesFirstUnderOneIdentity() = real {
        val (first, second) = twoRefreshes()
        second.complete(Unit)
        eventually { !state().isRefreshing && state().providers == listing2.providers }
        first.complete(Unit)
        delay(150)
        assertEquals(listing2.providers, state().providers, "the older result never overwrites the newer listing")
        assertFalse(state().isRefreshing)
    }

    // Review r3 #1: a superseded lookup never reports a premature miss.

    private val listingWithFile = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, items = listOf(itemA))))

    @Test
    fun r3_supersededLookupAnswersFromTheNewerPublishedListing() = real {
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, second)
        backend.perCallListing += listOf(listingWithFile, listingWithFile)
        val lookup = async { CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA)) }
        eventually { backend.started.value == 1 }
        CloudLibraryRepository.refresh() // supersedes the lookup's refresh
        eventually { backend.started.value == 2 }
        first.complete(Unit) // the lookup's fetch finishes first, while the newer one is pending
        delay(150)
        assertFalse(lookup.isCompleted, "it waits for the newer refresh instead of reporting a miss")
        second.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.Found(CloudLibraryPlaybackTarget(itemA, fileA)), lookup.await())
    }

    @Test
    fun r3_supersededLookupPublishesItsOwnFetchWhenTheNewerIsAbandoned() = real {
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, second)
        backend.perCallListing += listOf(listingWithFile, CloudLibraryUiState(isLoaded = true))
        val lookup = async { CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA)) }
        eventually { backend.started.value == 1 }
        val newer = async { CloudLibraryRepository.findPlaybackTargetForProgressResult("torbox:Torrent:other", "x") }
        eventually { backend.started.value == 2 }
        first.complete(Unit)
        delay(150)
        newer.cancel() // the newer refresh is abandoned
        assertEquals(CloudLibraryPlaybackTargetLookupResult.Found(CloudLibraryPlaybackTarget(itemA, fileA)), lookup.await())
        assertEquals(listingWithFile.providers, state().providers, "its own admitted fetch was published")
        assertFalse(state().isRefreshing)
    }

    @Test
    fun r3_theWaitIsBounded() = real {
        CloudLibraryRepository.supersededLookupWaitMs = 200
        val first = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, CompletableDeferred()) // the newer one never finishes
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA)) }
        eventually { backend.started.value == 1 }
        CloudLibraryRepository.refresh()
        eventually { backend.started.value == 2 }
        first.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
    }

    // Review r3 #2: an abandoned initial load is retried once when the gate reopens, never in a loop.

    @Test
    fun r3_abandonedInitialRefreshLoadsWhenTheGateReopens() = real {
        backend.perCall += CompletableDeferred() // the initial refresh never answers
        CloudLibraryRepository.ensureLoaded()
        eventually { backend.started.value == 1 }
        com.nuvio.app.core.identity.IdentityImmediate.serialChanging() // same account, new session: the gate closes
        IdentityRuntime.authSerial = { 2 }
        CloudLibraryRepository.cancelJobsForTest() // the drain cancels the refresh
        eventually { !state().isRefreshing }
        delay(200)
        assertEquals(1, backend.started.value, "no retry while the gate is closed")
        assertFalse(state().isLoaded)
        com.nuvio.app.core.identity.IdentityImmediate.chainEnded() // Open again
        eventually { state().isLoaded && backend.started.value == 2 }
        assertEquals(listingA.providers, state().providers)
    }

    @Test
    fun r3_noRetryStormWhenTheRetryIsAbandonedToo() = real {
        backend.perCall += listOf(CompletableDeferred(), CompletableDeferred())
        CloudLibraryRepository.ensureLoaded()
        eventually { backend.started.value == 1 }
        CloudLibraryRepository.cancelJobsForTest()
        eventually { backend.started.value == 2 } // the one retry (the gate is open)
        CloudLibraryRepository.cancelJobsForTest()
        eventually { !state().isRefreshing }
        delay(300)
        assertEquals(2, backend.started.value, "no third attempt")
        assertTrue(state().isLoaded, "the loaded-and-empty state: Refresh is shown, no spinner")
    }

    // The refresh matrix (r3): the cells no other test covers.

    @Test
    fun matrix_plainRefreshThatThrowsRetriesOnceThenShowsLoaded() = real {
        backend.throwAll = true
        CloudLibraryRepository.ensureLoaded()
        eventually { backend.started.value == 2 && !state().isRefreshing && state().isLoaded }
        delay(200)
        assertEquals(2, backend.started.value, "one retry, no storm")
        assertTrue(state().providers.isEmpty())
    }

    @Test
    fun matrix_plainRefreshSupersededByALookupNeverOverwritesIt() = real {
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, second)
        backend.perCallListing += listOf(listing1, listingWithFile)
        CloudLibraryRepository.refresh()
        eventually { backend.started.value == 1 }
        val lookup = async { CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA)) }
        eventually { backend.started.value == 2 }
        second.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.Found(CloudLibraryPlaybackTarget(itemA, fileA)), lookup.await())
        first.complete(Unit)
        delay(150)
        assertEquals(listingWithFile.providers, state().providers, "the superseded refresh wrote nothing")
        assertFalse(state().isRefreshing)
    }

    @Test
    fun matrix_clearDuringAPlainRefreshPublishesNothing() = real {
        backend.gate = CompletableDeferred()
        CloudLibraryRepository.refresh()
        backend.entered.await()
        CloudLibraryRepository.clear() // same identity (no switch): the marker is reset
        backend.gate!!.complete(Unit)
        delay(200)
        assertEquals(CloudLibraryUiState(), state())
        assertEquals(1, backend.started.value, "no retry after a clear (nothing is wanted)")
    }

    @Test
    fun matrix_disabledDuringAPlainRefreshPublishesNothing() = real {
        backend.gate = CompletableDeferred()
        CloudLibraryRepository.refresh()
        backend.entered.await()
        settings.enabled[1] = false
        CloudLibraryRepository.ensureLoaded() // writes the disabled state, resets the marker
        backend.gate!!.complete(Unit)
        delay(200)
        assertEquals(CloudLibraryUiState(isLoaded = true, isEnabled = false), state())
    }

    // Review r1 #2: no provider call is made with credentials read after the identity moved.

    @Test
    fun r2_switchBetweenCaptureAndCredentialReadSendsNothing() = real {
        CloudLibraryRepository.setStateForTest(listingA, scopeA)
        settings.afterCredentialsRead = { settings.afterCredentialsRead = {}; switchToB() }
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(itemA, fileA))
        assertEquals(emptyList(), backend.handed, "no provider request")
    }

    // Review r1 #3: a target cannot be resolved under an identity it was not found under.

    @Test
    fun r3_lookupUnderAThenResolveUnderBIsRefused() = real {
        val resolvedA = itemA.copy(files = listOf(fileA.copy(playbackUrl = "https://example.invalid/a")))
        val listing = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, items = listOf(resolvedA))))
        CloudLibraryRepository.setStateForTest(listing, scopeA)
        val lookup = CloudLibraryRepository.findPlaybackTargetForProgressResult(resolvedA.stableKey, resolvedA.playbackVideoId(fileA))
        val target = (lookup as CloudLibraryPlaybackTargetLookupResult.Found).target
        // B opens; even with A's listing still in memory (no fan-out) and B holding the same provider:
        IdentityRuntime.setForTest(BarrierState.initial(2).copy(scope = IdentityScope(guest, 2), latestAccount = guest, epoch = IdentityEpoch(2)))
        settings.profile = 2
        settings.credentials[2] = listOf(DebridServiceCredential(DebridProviders.Torbox, "key-of-b"))
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(target.item, target.file))
        assertEquals(emptyList(), backend.handed)
    }

    @Test
    fun r3_listedItemOfAResolvedAfterTheSwitchIsRefused() = real {
        CloudLibraryRepository.setStateForTest(listingA, scopeA)
        val shown = state().providers.single().items.single() // what the tvOS Library row holds
        switchToB()
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(shown, shown.files.single()))
        assertEquals(emptyList(), backend.handed)
    }

    @Test
    fun r3_aResolveUsesTheListedValuesNotTheCallers() = real {
        CloudLibraryRepository.setStateForTest(listingA, scopeA)
        val forged = fileA.copy(playbackUrl = "https://example.invalid/forged")
        val result = CloudLibraryRepository.resolvePlayback(itemA, forged)
        assertEquals(CloudLibraryPlaybackResult.Success(url = "https://example.invalid/stream"), result, "the provider resolved the listed file")
        assertEquals(listOf(fileA), backend.resolvedFiles, "the provider got the listed file, not the caller's")
    }

    @Test
    fun keys_fullValueNoKeyInTextAndClearResets() {
        // "Aa" and "BB" have equal String hashes: compared by value they still differ.
        assertEquals("Aa".hashCode(), "BB".hashCode())
        val a = CloudLibraryRepository.CloudConnectionKey("torbox", "Aa")
        val b = CloudLibraryRepository.CloudConnectionKey("torbox", "BB")
        assertNotEquals(a, b)
        assertFalse("Aa" in a.toString())
        assertEquals(
            listOf(CloudLibraryRepository.CloudConnectionKey("premiumize", "y"), CloudLibraryRepository.CloudConnectionKey("torbox", "x")),
            CloudLibraryRepository.keysOf(listOf(DebridServiceCredential(DebridProviders.Torbox, "x"), DebridServiceCredential(DebridProviders.Premiumize, "y"))),
        )
        CloudLibraryRepository.setStateForTest(listingA)
        CloudLibraryRepository.clear()
        assertEquals(CloudLibraryUiState(), state())
        assertTrue(state().providers.isEmpty())
    }
}
