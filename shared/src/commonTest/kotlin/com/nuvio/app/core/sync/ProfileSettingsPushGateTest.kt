package com.nuvio.app.core.sync

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Pure-function coverage for ProfileSettingsSync's addon-wipe class guard (see
// docs/addon-wipe-investigation-2026-08-28.md). Deliberately does not touch ProfileSettingsSync
// itself — it's a singleton with network/platform dependencies — so this only exercises the
// top-level decision functions the observer delegates to (the pull gate, and the fork's
// echo-marker consumption below).
class ProfileSettingsPushGateTest {
    private val userA = SettingsPullToken(userId = "user-a", profileId = 1)
    private val userAOtherProfile = SettingsPullToken(userId = "user-a", profileId = 2)
    private val userB = SettingsPullToken(userId = "user-b", profileId = 1)

    @Test
    fun `blocks push when neither token exists`() {
        assertFalse(settingsPushAllowed(settledToken = null, currentToken = null))
    }

    @Test
    fun `blocks push when current token is null`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = null))
    }

    @Test
    fun `blocks push when settled token is null`() {
        assertFalse(settingsPushAllowed(settledToken = null, currentToken = userA))
    }

    @Test
    fun `allows push when settled and current tokens match`() {
        assertTrue(settingsPushAllowed(settledToken = userA, currentToken = userA))
    }

    @Test
    fun `blocks push when same user but different profileId`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = userAOtherProfile))
    }

    @Test
    fun `blocks push when same profileId but different userId`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = userB))
    }

    // Fork: the echo marker must suppress the very next emission only — see
    // consumeSettingsSkipMarker's doc for the profile-reselect sequence that left the server stuck
    // on a superseded value when a mismatched marker survived.
    @Test
    fun `no marker never suppresses a push`() {
        val decision = consumeSettingsSkipMarker(marker = null, signature = "S")
        assertFalse(decision.skipPush)
        assertNull(decision.remainingMarker)
    }

    @Test
    fun `a matching marker suppresses one push and then expires`() {
        val decision = consumeSettingsSkipMarker(marker = "S", signature = "S")
        assertTrue(decision.skipPush)
        assertNull(decision.remainingMarker)
    }

    @Test
    fun `a mismatched marker pushes and still expires`() {
        val first = consumeSettingsSkipMarker(marker = "S", signature = "T")
        assertFalse(first.skipPush)
        assertNull(first.remainingMarker)

        // The S that follows must push: with the marker expired it is an ordinary emission, not
        // the echo of a profile reselect that happened two edits ago.
        val second = consumeSettingsSkipMarker(marker = first.remainingMarker, signature = "S")
        assertFalse(second.skipPush)
        assertNull(second.remainingMarker)
    }

    // Fork: the deferred-push path (maybeRetryGatedPush) consumes the marker through the same
    // helper, so a gated push that runs while the marker is armed for some other state cannot
    // leave it behind to swallow the next genuine push.
    @Test
    fun `a deferred push drops a marker armed for a state the settle moved past`() {
        // An edit before the first pull settles is held; the pull then applies a blob that leaves
        // the state at T while the marker is still armed with the reselect's S.
        val deferred = consumeSettingsSkipMarker(marker = "S", signature = "T")
        assertFalse(deferred.skipPush)
        assertNull(deferred.remainingMarker)

        // The user now edits back to S. With the stale marker gone this is an ordinary emission
        // and pushes; left armed it would have been read as the echo and dropped, stranding the
        // server on T.
        val restored = consumeSettingsSkipMarker(marker = deferred.remainingMarker, signature = "S")
        assertFalse(restored.skipPush)
        assertNull(restored.remainingMarker)
    }

    @Test
    fun `a deferred push is suppressed when the settle left the state at the marker`() {
        // The pull applied exactly the state the held emission wanted to push — the server has it
        // already, so the owed push is a redundant rewrite...
        val deferred = consumeSettingsSkipMarker(marker = "S", signature = "S")
        assertTrue(deferred.skipPush)
        assertNull(deferred.remainingMarker)

        // ...and the marker is spent on it, so a later edit that lands on S again still pushes.
        val later = consumeSettingsSkipMarker(marker = deferred.remainingMarker, signature = "S")
        assertFalse(later.skipPush)
    }
}
