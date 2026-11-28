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

    private val listingWithFile = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, items = listOf(itemA))))
    private val torboxError = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, errorMessage = "Torbox is down")))
    private val foundA = CloudLibraryPlaybackTargetLookupResult.Found(CloudLibraryPlaybackTarget(itemA, fileA))
    private suspend fun lookupA() = CloudLibraryRepository.findPlaybackTargetForProgressResult(itemA.stableKey, itemA.playbackVideoId(fileA))

    // Review r4 A: a lookup answers from its own fetch; publishing stays owner-only.

    @Test
    fun r4_supersededLookupAnswersFromItsOwnFetchAtOnce() = real {
        val first = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, CompletableDeferred()) // the newer refresh stays pending
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { lookupA() }
        eventually { backend.started.value == 1 }
        CloudLibraryRepository.refresh() // supersedes the lookup's refresh
        eventually { backend.started.value == 2 }
        first.complete(Unit)
        assertEquals(foundA, lookup.await(), "no waiting, no premature miss")
        assertTrue(state().isRefreshing, "the newer refresh still owns the marker")
        assertFalse(state().providers.any { it.items.isNotEmpty() }, "the superseded lookup published nothing")
    }

    @Test
    fun r4_olderLookupSucceedsWhileANewerRefreshPublishesAProviderError() = real {
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, second)
        backend.perCallListing += listOf(listingWithFile, torboxError)
        val lookup = async { lookupA() }
        eventually { backend.started.value == 1 }
        CloudLibraryRepository.refresh()
        eventually { backend.started.value == 2 }
        second.complete(Unit) // the newer one publishes the error state first
        eventually { state() == torboxError }
        first.complete(Unit)
        assertEquals(foundA, lookup.await())
        assertEquals(torboxError, state(), "the superseded lookup did not overwrite the newer listing")
    }

    @Test
    fun r4_aLookupFoundTargetResolvesThroughTheRecord() = real {
        val first = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, CompletableDeferred())
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { lookupA() }
        eventually { backend.started.value == 1 }
        CloudLibraryRepository.refresh() // supersede: the lookup's listing is never published
        eventually { backend.started.value == 2 }
        first.complete(Unit)
        assertEquals(foundA, lookup.await())
        val result = CloudLibraryRepository.resolvePlayback(itemA, fileA.copy(playbackUrl = "https://example.invalid/forged"))
        assertEquals(CloudLibraryPlaybackResult.Success(url = "https://example.invalid/stream"), result)
        assertEquals(listOf(fileA), backend.resolvedFiles, "the recorded file, not the caller's")
    }

    @Test
    fun r4_keyDisconnectedBetweenLookupAndResolve() = real {
        backend.perCallListing += listOf(listingWithFile)
        assertEquals(foundA, lookupA())
        settings.credentials[1] = emptyList() // Torbox disconnected on this profile
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(itemA, fileA))
        assertEquals(emptyList(), backend.resolvedFiles, "the old key's target is not trusted under the new keys: no request")
    }

    @Test
    fun r4_keyReplacedBetweenLookupAndResolveIsRefused() = real {
        backend.perCallListing += listOf(listingWithFile)
        assertEquals(foundA, lookupA())
        settings.credentials[1] = listOf(DebridServiceCredential(DebridProviders.Torbox, "new-key-of-a"))
        // Last focused check #1: the target belongs to the old key's generation.
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(itemA, fileA))
        assertEquals(emptyList(), backend.resolvedFiles)
    }

    @Test
    fun r4_disabledBetweenLookupAndResolve() = real {
        backend.perCallListing += listOf(listingWithFile)
        assertEquals(foundA, lookupA())
        settings.enabled[1] = false
        val result = CloudLibraryRepository.resolvePlayback(itemA, fileA)
        assertTrue(result is CloudLibraryPlaybackResult.Failed && result.message != null, "the existing disabled answer")
        assertEquals(emptyList(), backend.resolvedFiles)
    }

    // Review r4 B: the level-triggered observer serves a wanted, unloaded listing.

    @Test
    fun r4_abandonedInitialRefreshLoadsWhenTheGateReopens() = real {
        backend.perCall += CompletableDeferred() // the initial refresh never answers
        CloudLibraryRepository.ensureLoaded()
        eventually { backend.started.value == 1 }
        com.nuvio.app.core.identity.IdentityImmediate.serialChanging() // same account, new session: the gate closes
        IdentityRuntime.authSerial = { 2 }
        CloudLibraryRepository.cancelJobsForTest() // the drain cancels the refresh
        eventually { !state().isRefreshing }
        delay(200)
        assertEquals(1, backend.started.value, "nothing while the gate is closed")
        assertFalse(state().isLoaded)
        com.nuvio.app.core.identity.IdentityImmediate.chainEnded() // Open again
        eventually { state().isLoaded && backend.started.value == 2 }
        assertEquals(listingA.providers, state().providers)
    }

    @Test
    fun r4_aRefusedFinalCommitAfterTheGateReopenedReloads() = real {
        backend.gate = CompletableDeferred()
        CloudLibraryRepository.ensureLoaded()
        backend.entered.await()
        IdentityRuntime.authSerial = { 2 } // the gate stays Open; the job's token is stale
        backend.gate!!.complete(Unit) // its final commit is refused; no gate emission follows
        eventually { state().isLoaded && backend.started.value == 2 }
    }

    @Test
    fun r4_aFirstCallWhileTheGateIsClosedIsServedOnOpen() = real {
        com.nuvio.app.core.identity.IdentityImmediate.serialChanging()
        CloudLibraryRepository.ensureLoaded() // refused at the start, but wanted
        delay(150)
        assertEquals(0, backend.started.value)
        com.nuvio.app.core.identity.IdentityImmediate.chainEnded()
        eventually { state().isLoaded && backend.started.value == 1 }
    }

    @Test
    fun r4_theGateClosingBetweenAnOpenEmissionAndTheCaptureIsPickedUpLater() = real {
        backend.perCall += CompletableDeferred()
        CloudLibraryRepository.ensureLoaded()
        eventually { backend.started.value == 1 }
        var closedOnce = false
        CloudLibraryRepository.beforeAutoCaptureForTest = {
            if (!closedOnce) { closedOnce = true; com.nuvio.app.core.identity.IdentityImmediate.serialChanging() }
        }
        IdentityRuntime.authSerial = { 2 }
        CloudLibraryRepository.cancelJobsForTest() // the tick re-runs the observer; it closes the gate before capturing
        eventually { closedOnce }
        delay(150)
        assertEquals(1, backend.started.value, "the capture was refused")
        com.nuvio.app.core.identity.IdentityImmediate.chainEnded()
        eventually { state().isLoaded && backend.started.value == 2 }
    }

    /** Every return to Open is a new state (the epoch bumps), so a reopened gate always re-runs the observer. */
    @Test
    fun r4_everyReopenedGateIsADistinctState() {
        val before = IdentityRuntime.state.value
        com.nuvio.app.core.identity.IdentityImmediate.serialChanging()
        com.nuvio.app.core.identity.IdentityImmediate.chainEnded()
        val after = IdentityRuntime.state.value
        assertTrue(after.phase is com.nuvio.app.core.identity.IdentityPhase.Open)
        assertNotEquals(before, after)
    }

    @Test
    fun r4_aRecordedTargetOfAnotherProfileIsRefused() = real {
        backend.perCallListing += listOf(listingWithFile)
        assertEquals(foundA, lookupA()) // fetched and recorded under A
        // B opens with the same provider, and nothing cleared Cloud in between (worst case):
        IdentityRuntime.setForTest(BarrierState.initial(2).copy(scope = IdentityScope(guest, 2), latestAccount = guest, epoch = IdentityEpoch(2)))
        settings.profile = 2
        settings.credentials[2] = listOf(DebridServiceCredential(DebridProviders.Torbox, "key-of-b"))
        CloudLibraryRepository.setStateForTest(CloudLibraryUiState()) // no listing for B
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(itemA, fileA))
        assertEquals(emptyList(), backend.resolvedFiles)
    }

    @Test
    fun r4_clearRacingTheObserverLoadsNothing() = real {
        backend.perCall += CompletableDeferred()
        CloudLibraryRepository.ensureLoaded()
        eventually { backend.started.value == 1 }
        CloudLibraryRepository.beforeAutoCaptureForTest = { CloudLibraryRepository.clear() }
        CloudLibraryRepository.cancelJobsForTest()
        delay(300)
        assertEquals(1, backend.started.value, "nothing is wanted after the clear")
        assertEquals(CloudLibraryUiState(), state())
    }

    @Test
    fun r4_aFailingFetchPublishesBasesFailureStateAndNoStorm() = real {
        backend.throwAll = true
        CloudLibraryRepository.ensureLoaded()
        eventually { state().isLoaded }
        delay(300)
        assertEquals(1, backend.started.value, "a failure is published, not retried")
        assertEquals(listOf("provider failed"), state().providers.map { it.errorMessage })
        assertFalse(state().isRefreshing)
    }

    /** Mobile renders what base rendered: a thrown fetch has the shape base's store gives a failed provider. */
    @Test
    fun r4_theFailureStateIsBasesProviderFailureShape() = real {
        val failing = object : CloudLibraryProviderApi {
            override val provider = DebridProviders.Torbox
            override suspend fun listItems(apiKey: String): Result<List<CloudLibraryItem>> = Result.failure(IllegalStateException("provider failed"))
            override suspend fun resolvePlayback(apiKey: String, item: CloudLibraryItem, file: CloudLibraryFile): CloudLibraryPlaybackResult = CloudLibraryPlaybackResult.Failed()
        }
        val base = CloudLibraryStore(credentialsProvider = { listOf(keyA) }, providerApis = listOf(failing)).refresh()
        backend.throwAll = true
        CloudLibraryRepository.ensureLoaded()
        eventually { state().isLoaded }
        assertEquals(base, state())
    }

    // Focused check: one generation, captured with the token and keys, checked first at the end.

    private fun itemN(n: Int) = CloudLibraryItem(providerId = DebridProviders.TORBOX_ID, providerName = "Torbox", id = "n$n", type = CloudLibraryItemType.Torrent, name = "item $n", files = listOf(CloudLibraryFile(id = "f$n", name = "$n.mkv")))
    private fun listingOf(vararg items: CloudLibraryItem) = CloudLibraryUiState(isLoaded = true, providers = listOf(CloudLibraryProviderState(DebridProviders.Torbox, items = items.toList())))

    @Test
    fun fc_keyReplacedDuringALookupPublishesAndReturnsNothing() = real {
        backend.gate = CompletableDeferred()
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { lookupA() }
        backend.entered.await()
        settings.credentials[1] = listOf(DebridServiceCredential(DebridProviders.Torbox, "replaced-key")) // no repository call
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
        assertFalse(state().providers.any { it.items.isNotEmpty() }, "the old key's listing was not published")
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(itemA, fileA), "nothing was trusted")
    }

    @Test
    fun fc_keyDisconnectedDuringALookupPublishesAndReturnsNothing() = real {
        backend.gate = CompletableDeferred()
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { lookupA() }
        backend.entered.await()
        settings.credentials[1] = emptyList()
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
        assertFalse(state().providers.any { it.items.isNotEmpty() })
    }

    @Test
    fun fc_disabledDuringALookupPublishesAndReturnsNothing() = real {
        backend.gate = CompletableDeferred()
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { lookupA() }
        backend.entered.await()
        settings.enabled[1] = false // no repository call
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
        assertFalse(state().providers.any { it.items.isNotEmpty() }, "no enabled listing left visible")
    }

    private val first = listingOf(itemN(1))
    private val second = listingOf(itemN(2))

    @Test
    fun fc_keyReplacedDuringAPlainRefreshNeverPublishesTheOldKeysListing() = real {
        backend.perCall += listOf(CompletableDeferred())
        backend.perCallListing += listOf(first, second)
        CloudLibraryRepository.refresh()
        eventually { backend.started.value == 1 }
        val replaced = DebridServiceCredential(DebridProviders.Torbox, "replaced-key")
        settings.credentials[1] = listOf(replaced)
        backend.perCall[0].complete(Unit)
        eventually { state() == second } // the observer reloads with the new key
        assertEquals(listOf(replaced), backend.handed[1])
    }

    @Test
    fun fc_keyDisconnectedDuringAPlainRefreshNeverPublishesTheOldKeysListing() = real {
        backend.perCall += listOf(CompletableDeferred())
        backend.perCallListing += listOf(first, CloudLibraryUiState(isLoaded = true))
        CloudLibraryRepository.refresh()
        eventually { backend.started.value == 1 }
        settings.credentials[1] = emptyList()
        backend.perCall[0].complete(Unit)
        eventually { !state().isRefreshing && backend.started.value == 2 }
        delay(100)
        assertNotEquals(first, state())
    }

    @Test
    fun fc_disabledDuringAPlainRefreshNeverPublishesTheListing() = real {
        backend.perCall += listOf(CompletableDeferred())
        backend.perCallListing += listOf(first)
        CloudLibraryRepository.refresh()
        eventually { backend.started.value == 1 }
        settings.enabled[1] = false
        backend.perCall[0].complete(Unit)
        eventually { state() == CloudLibraryUiState(isLoaded = true, isEnabled = false) } // the observer writes disabled
        assertEquals(1, backend.started.value)
    }

    @Test
    fun fc_sameIdentityClearDuringALookupRecordsAndReturnsNothing() = real {
        backend.gate = CompletableDeferred()
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { lookupA() }
        backend.entered.await()
        CloudLibraryRepository.clear() // no identity change
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
        assertEquals(CloudLibraryUiState(), state())
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(itemA, fileA))
    }

    @Test
    fun fc_aLibraryRowDroppedByANewerListingStillResolves() = real {
        backend.perCallListing += listOf(listingWithFile, second)
        CloudLibraryRepository.refresh()
        eventually { state() == listingWithFile }
        val row = state().providers.single().items.single()
        CloudLibraryRepository.refresh()
        eventually { state() == second } // the row is gone from the listing
        assertTrue(CloudLibraryRepository.resolvePlayback(row, row.files.single()) is CloudLibraryPlaybackResult.Success)
    }

    @Test
    fun fc_aCachedLookupHitResolvesAfterTheListingWasReplaced() = real {
        backend.perCallListing += listOf(listingWithFile, second)
        CloudLibraryRepository.refresh()
        eventually { state() == listingWithFile }
        assertEquals(foundA, lookupA()) // a cached hit
        CloudLibraryRepository.refresh()
        eventually { state() == second }
        assertTrue(CloudLibraryRepository.resolvePlayback(itemA, fileA) is CloudLibraryPlaybackResult.Success)
    }

    @Test
    fun fc_manyLookupsNeverEvictTheFirstTarget() = real {
        val items = (1..20).map { itemN(it) }
        backend.perCallListing += items.map { listingOf(it) }
        for (item in items) {
            val file = item.files.single()
            assertTrue(CloudLibraryRepository.findPlaybackTargetForProgressResult(item.stableKey, item.playbackVideoId(file)) is CloudLibraryPlaybackTargetLookupResult.Found)
        }
        assertTrue(CloudLibraryRepository.resolvePlayback(items.first(), items.first().files.single()) is CloudLibraryPlaybackResult.Success)
    }

    @Test
    fun fc_aGenerationBumpEmptiesTheTrustedSet() = real {
        backend.perCall += listOf(CompletableDeferred<Unit>().also { it.complete(Unit) }, CompletableDeferred())
        backend.perCallListing += listOf(listingWithFile)
        CloudLibraryRepository.ensureLoaded()
        eventually { state() == listingWithFile }
        settings.credentials[1] = listOf(DebridServiceCredential(DebridProviders.Torbox, "replaced-key"))
        CloudLibraryRepository.ensureLoaded() // observes the key change: the generation bumps
        eventually { backend.started.value == 2 }
        assertEquals(listOf(itemA), state().items, "the old listing is still on screen while the new one loads")
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(itemA, fileA), "but no longer trusted")
    }

    // Last focused check: the generation is bound to its keys and advances once, at the first sight.

    private val keyB = DebridServiceCredential(DebridProviders.Torbox, "key-b-same-profile")

    @Test
    fun fc2_keyReplacedAfterAStoredUrlNeverReturnsTheOldUrl() = real {
        backend.perCallListing += listOf(listingWithFile, listingWithFile)
        CloudLibraryRepository.refresh()
        eventually { state() == listingWithFile }
        assertTrue(CloudLibraryRepository.resolvePlayback(itemA, fileA) is CloudLibraryPlaybackResult.Success) // A's URL stored
        assertTrue(state().items.single().files.single().playbackUrl != null)
        settings.credentials[1] = listOf(keyB) // replaced, no ensureLoaded in between
        assertEquals(foundA, lookupA(), "answered by a fresh fetch under B, not A's cached listing")
        assertEquals(listOf(keyB), backend.handed.last())
        assertEquals(CloudLibraryPlaybackResult.Success(url = "https://example.invalid/stream"), CloudLibraryRepository.resolvePlayback(itemA, fileA))
        assertEquals(null, backend.resolvedFiles.last().playbackUrl, "B's target, never A's stored URL")
        assertEquals(listOf(keyB), backend.handed.last())
    }

    @Test
    fun fc2_anOldKeyOperationNeverDiscardsANewerKeysRefresh() = real {
        backend.perCall += listOf(CompletableDeferred<Unit>().also { it.complete(Unit) }, CompletableDeferred(), CompletableDeferred())
        backend.perCallListing += listOf(listingWithFile, listingWithFile, second)
        CloudLibraryRepository.refresh()
        eventually { state() == listingWithFile } // a listing on screen
        val oldKeyLookup = async { CloudLibraryRepository.findPlaybackTargetForProgressResult("torbox:Torrent:missing", "x") }
        eventually { backend.started.value == 2 } // in flight with key A
        settings.credentials[1] = listOf(keyB)
        val before = CloudLibraryRepository.generationForTest
        CloudLibraryRepository.refresh() // admitted for B: advances
        eventually { backend.started.value == 3 }
        backend.perCall[1].complete(Unit) // the A-key lookup ends first
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, oldKeyLookup.await())
        backend.perCall[2].complete(Unit)
        eventually { state() == second }
        assertEquals(before + 1, CloudLibraryRepository.generationForTest, "one advance for one key change")
        val row = state().items.single()
        assertTrue(CloudLibraryRepository.resolvePlayback(row, row.files.single()) is CloudLibraryPlaybackResult.Success)
    }

    @Test
    fun fc2_anInvalidatedListingOnScreenReloadsWhenWanted() = real {
        backend.perCallListing += listOf(listingWithFile, second)
        CloudLibraryRepository.ensureLoaded()
        eventually { state() == listingWithFile }
        settings.credentials[1] = listOf(keyB)
        assertEquals(CloudLibraryPlaybackResult.Failed(), CloudLibraryRepository.resolvePlayback(itemA, fileA)) // sees B first
        eventually { state() == second } // the tick: the observer reloaded with B
        assertEquals(listOf(keyB), backend.handed.last())
    }

    @Test
    fun fc2_manyObserversOfOneKeyChangeAdvanceOnce() = real {
        backend.perCallListing += listOf(listingWithFile, listingWithFile)
        CloudLibraryRepository.refresh()
        eventually { state() == listingWithFile }
        val before = CloudLibraryRepository.generationForTest
        settings.credentials[1] = listOf(keyB)
        CloudLibraryRepository.resolvePlayback(itemA, fileA)
        CloudLibraryRepository.resolvePlayback(itemA, fileA)
        lookupA()
        eventually { !state().isRefreshing }
        assertEquals(before + 1, CloudLibraryRepository.generationForTest)
    }

    // The refresh matrix: lookup cells.

    @Test
    fun matrix_lookupThatThrowsAnswersNotFoundAndPublishesTheFailure() = real {
        backend.throwAll = true
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookupA())
        assertEquals(listOf("provider failed"), state().providers.map { it.errorMessage })
        assertFalse(state().isRefreshing)
    }

    @Test
    fun matrix_lookupCancelledDuringItsFetchLeavesNoMarker() = real {
        backend.gate = CompletableDeferred()
        val lookup = async { lookupA() }
        backend.entered.await()
        lookup.cancel()
        eventually { !state().isRefreshing }
        assertFalse(state().isLoaded)
    }

    @Test
    fun matrix_lookupDuringClearAnswersNotFound() = real {
        backend.gate = CompletableDeferred()
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { lookupA() }
        backend.entered.await()
        switchToB() // a switch: the fan-out clears Cloud
        CloudLibraryRepository.clear()
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
        assertEquals(CloudLibraryUiState(), state())
    }

    @Test
    fun matrix_lookupDuringDisableAnswersNotFound() = real {
        backend.gate = CompletableDeferred()
        backend.perCallListing += listOf(listingWithFile)
        val lookup = async { lookupA() }
        backend.entered.await()
        settings.enabled[1] = false
        CloudLibraryRepository.ensureLoaded() // writes the disabled state
        backend.gate!!.complete(Unit)
        assertEquals(CloudLibraryPlaybackTargetLookupResult.NotFound, lookup.await())
        assertEquals(CloudLibraryUiState(isLoaded = true, isEnabled = false), state())
    }

    @Test
    fun matrix_lookupSupersededByALookupAnswersFromItsOwnFetch() = real {
        val first = CompletableDeferred<Unit>()
        backend.perCall += listOf(first, CompletableDeferred())
        backend.perCallListing += listOf(listingWithFile)
        val older = async { lookupA() }
        eventually { backend.started.value == 1 }
        val newer = async { CloudLibraryRepository.findPlaybackTargetForProgressResult("torbox:Torrent:other", "x") }
        eventually { backend.started.value == 2 }
        first.complete(Unit)
        assertEquals(foundA, older.await())
        newer.cancel()
    }

    // The refresh matrix: plain-refresh cells.

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
