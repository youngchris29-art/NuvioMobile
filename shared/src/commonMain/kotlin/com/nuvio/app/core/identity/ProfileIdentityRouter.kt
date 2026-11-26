package com.nuvio.app.core.identity

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.profiles.NuvioProfile
import com.nuvio.app.features.profiles.ProfileLifecycleProvider
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.concurrent.Volatile

/*
 * Every profile transition ProfileRepository starts goes through this seam (fork-only, W2). The
 * default router is today's behaviour exactly (composeApp, JVM tests); tvOS installs
 * [BarrierProfileIdentityRouter], which routes each one through the identity barrier.
 *
 * Design: docs/batch-scope-identity-spec.md, sections 5.1-5.4, 8.0.1, 8.0.2 and 8.1.
 */

interface ProfileIdentityRouter {
    fun selectProfile(profileIndex: Int, applyNow: (Int) -> Unit)

    /** Publishes a pulled list: [publish] does the state write + persist and returns the active slot if the list lacks it. */
    fun publishPulledProfiles(profiles: List<NuvioProfile>, token: AccountToken?, publish: () -> Int?)

    /** The active slot is not in [profiles]. Return the profile to make active now, or null to leave the slot. */
    fun onActiveSlotMissing(missingSlot: Int, profiles: List<NuvioProfile>, token: AccountToken?): NuvioProfile?

    /** After a successful delete of [slot] (server RPC or guest filter); [remaining] is the list without it. */
    suspend fun afterProfileDeleted(slot: Int, remaining: List<NuvioProfile>, token: AccountToken?)

    /** A changing write of ProfileRepository.activeProfileIndex; false refuses it. */
    fun onSlotWrite(old: Int, new: Int): Boolean
}

object ProfileIdentityRouterProvider {
    @Volatile
    var router: ProfileIdentityRouter = DefaultProfileIdentityRouter
}

/** Today's behaviour, exactly. */
internal object DefaultProfileIdentityRouter : ProfileIdentityRouter {
    override fun selectProfile(profileIndex: Int, applyNow: (Int) -> Unit) =
        ActiveProfileProvider.changing { applyNow(profileIndex) }

    override fun publishPulledProfiles(profiles: List<NuvioProfile>, token: AccountToken?, publish: () -> Int?) {
        publish()
    }

    override fun onActiveSlotMissing(missingSlot: Int, profiles: List<NuvioProfile>, token: AccountToken?): NuvioProfile? =
        profiles.firstOrNull()

    // The guest delete's slot move to remaining.firstOrNull() already ran in onActiveSlotMissing.
    override suspend fun afterProfileDeleted(slot: Int, remaining: List<NuvioProfile>, token: AccountToken?) =
        ProfileRepository.removeDeletedProfileTrackerData(slot)

    override fun onSlotWrite(old: Int, new: Int): Boolean = true
}

/** A barrier profile apply whose must-succeed fan-out steps failed (8.0.2): W1 maps the throw to FailedApply. */
class FanOutFailed(val steps: List<String>) : IllegalStateException("profile fan-out failed: ${steps.joinToString()}")

/**
 * Runs fan-out steps in order; every step runs whatever the others did. A must-succeed step's
 * throwable is reported and its name collected; a best-effort step's throwable is reported only.
 */
class CheckedFanOut(private val report: (name: String, bestEffort: Boolean, error: Throwable) -> Unit) {
    private val failed = mutableListOf<String>()

    val failedSteps: List<String> get() = failed.toList()

    fun step(name: String, bestEffort: Boolean = false, block: () -> Unit) {
        try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            report(name, bestEffort, error)
            if (!bestEffort) failed += name
        }
    }
}

/** The barrier's profile mutations over the real ProfileRepository (installed by tvOS). */
internal object ProfileRepositoryOps : IdentityProfileOps {
    override fun applySelection(slot: Int) {
        val failed = ProfileRepository.applySelectionChecked(slot)
        if (failed.isNotEmpty()) throw FanOutFailed(failed)
    }

    override fun applyActiveRemoved() = ProfileRepository.applyActiveRemoved()

    override fun isListed(slot: Int): Boolean = ProfileRepository.state.value.profiles.any { it.profileIndex == slot }
}

/** What the barrier router calls; real by default, fakes in tests. */
internal interface BarrierRouterPorts {
    /** Fire-and-forget select (no sync caller remains on tvOS; kept so P2 holds for any). */
    fun launchSelect(slot: Int)
    fun requestSlotRemoved(slot: Int, token: AccountToken)
    suspend fun deleteActiveProfile(slot: Int, nextSlot: Int?, token: AccountToken): TransitionResult
    fun activeSlot(): Int
    fun removeTrackers(slot: Int)
}

internal object RealBarrierRouterPorts : BarrierRouterPorts {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ProfileIdentityRouter"))

    override fun launchSelect(slot: Int) {
        scope.launch { IdentityBarrier.selectProfile(slot) }
    }

    override fun requestSlotRemoved(slot: Int, token: AccountToken) = IdentityBarrier.requestSlotRemoved(slot, token)

    override suspend fun deleteActiveProfile(slot: Int, nextSlot: Int?, token: AccountToken): TransitionResult =
        IdentityBarrier.deleteActiveProfile(slot, nextSlot, token)

    override fun activeSlot(): Int = ProfileRepository.activeProfileId

    override fun removeTrackers(slot: Int) = ProfileRepository.removeDeletedProfileTrackerData(slot)
}

/** tvOS: every profile transition goes through the identity barrier. */
internal class BarrierProfileIdentityRouter(
    private val ports: BarrierRouterPorts = RealBarrierRouterPorts,
) : ProfileIdentityRouter {
    private val log = Logger.withTag("Identity")

    override fun selectProfile(profileIndex: Int, applyNow: (Int) -> Unit) {
        // P2: the legacy sync path never writes the slot on tvOS; the barrier does.
        ports.launchSelect(profileIndex)
    }

    override fun publishPulledProfiles(profiles: List<NuvioProfile>, token: AccountToken?, publish: () -> Int?) {
        when (val result = IdentityGate.commitAccount(token, "pullProfiles") { publish() }) {
            // 8.0.1: never inside the commit block (no barrier call there, 5.11); rule E keeps it.
            is CommitResult.Committed -> result.value?.let { missing -> token?.let { ports.requestSlotRemoved(missing, it) } }
            is CommitResult.Rejected -> log.i { "[Identity] pulled profiles refused ${result.reason}" }
        }
    }

    /** Pure on tvOS: reached from inside commit blocks; the slot does not move here (decision L). */
    override fun onActiveSlotMissing(missingSlot: Int, profiles: List<NuvioProfile>, token: AccountToken?): NuvioProfile? = null

    override suspend fun afterProfileDeleted(slot: Int, remaining: List<NuvioProfile>, token: AccountToken?) {
        // 8.0.5: off Main (the tracker removal takes the apply lock).
        withContext(Dispatchers.Default) { afterProfileDeletedNow(slot, remaining, token) }
    }

    private suspend fun afterProfileDeletedNow(slot: Int, remaining: List<NuvioProfile>, token: AccountToken?) {
        if (token == null) {
            log.i { "[Identity] delete of slot $slot: no account token, nothing removed" }
            return
        }
        // 5.3 step 3 (revision 6): the tracker removal belongs to the delete, never to the
        // transition; under the apply lock so a window's wipe cannot interleave (round 4 #1).
        val removed = IdentityLocks.withApply {
            IdentityGate.commitAccount(token, "deleteTrackers") { ports.removeTrackers(slot) }
        }
        if (removed is CommitResult.Rejected) {
            log.i { "[Identity] delete of slot $slot: account changed, trackers kept (${removed.reason})" }
            return
        }
        if (ports.activeSlot() != slot) return
        val result = try {
            ports.deleteActiveProfile(slot, remaining.minOfOrNull { it.profileIndex }, token)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "[Identity] active delete of slot $slot threw" }
            return
        }
        log.i { "[Identity] active delete of slot $slot: ${result::class.simpleName}" }
    }

    override fun onSlotWrite(old: Int, new: Int): Boolean {
        if (IdentityLocks.applyDepth > 0) return true
        val message = "[Identity] slot write refused outside barrier ($old -> $new)"
        log.e { message }
        if (IdentityLocks.strictLockOrder) error(message)
        return false
    }
}

/**
 * The account hook (5.7, revision 6): every account change resets account-scoped memory and fans
 * out, whatever the slot number. Runs inside the auth window under the apply lock.
 */
internal object IdentityAccountHooks {
    var ensureLoaded: (String) -> Unit = { ProfileRepository.ensureLoaded(it) }
    var resetAddons: () -> Unit = { AddonRepository.clearLocalState() }
    var fanOut: (Int) -> List<String> = { ProfileLifecycleProvider.coordinator.onProfileSelectedChecked(it) }
    var activeSlot: () -> Int = { ProfileRepository.activeProfileId }

    fun accountPublished(account: AccountKey) {
        when (account) {
            is AccountKey.Account -> loadAndFanOut(account.userId)
            is AccountKey.Guest -> loadAndFanOut(account.guestId)
            AccountKey.None -> resetAddons()
        }
    }

    private fun loadAndFanOut(ownerId: String) {
        ensureLoaded(ownerId)
        resetAddons()
        val failed = fanOut(activeSlot())
        // Rule B: a must-succeed step failed, so the hook throws and the window recovers.
        if (failed.isNotEmpty()) throw FanOutFailed(failed)
    }

    /** Tests only. */
    internal fun resetForTest() {
        ensureLoaded = { ProfileRepository.ensureLoaded(it) }
        resetAddons = { AddonRepository.clearLocalState() }
        fanOut = { ProfileLifecycleProvider.coordinator.onProfileSelectedChecked(it) }
        activeSlot = { ProfileRepository.activeProfileId }
    }
}
