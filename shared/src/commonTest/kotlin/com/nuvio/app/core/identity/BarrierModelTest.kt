package com.nuvio.app.core.identity

import com.nuvio.app.core.identity.BarrierEffect.CancelJobs
import com.nuvio.app.core.identity.BarrierEffect.EndFailed
import com.nuvio.app.core.identity.BarrierEffect.EndPreempted
import com.nuvio.app.core.identity.BarrierEffect.Proceed
import com.nuvio.app.core.identity.BarrierEffect.RunApply
import com.nuvio.app.core.identity.BarrierEffect.SignalPreempted
import com.nuvio.app.core.identity.BarrierEvent.Abandoned
import com.nuvio.app.core.identity.BarrierEvent.ApplyFinished
import com.nuvio.app.core.identity.BarrierEvent.ApplyGate
import com.nuvio.app.core.identity.BarrierEvent.ApplyThrew
import com.nuvio.app.core.identity.BarrierEvent.Begin
import com.nuvio.app.core.identity.BarrierEvent.DrainEnded
import com.nuvio.app.core.identity.BarrierEvent.WindowAccount
import com.nuvio.app.core.identity.BarrierEvent.WindowClosed
import com.nuvio.app.core.identity.BarrierEvent.WindowOpened
import com.nuvio.app.core.identity.TransitionKind.AccountPublished
import com.nuvio.app.core.identity.TransitionKind.AccountWipe
import com.nuvio.app.core.identity.TransitionKind.ActiveProfileDelete
import com.nuvio.app.core.identity.TransitionKind.ProfileSelect
import com.nuvio.app.core.identity.TransitionKind.SignOut
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Spec 3.4 (revision 7): one test per row, the named sequences, and the finite-abstraction search. */
class BarrierModelTest {

    private fun open(slot: Int = 1, account: AccountKey = accountA): BarrierState =
        BarrierState.initial(slot).copy(scope = IdentityScope(account, slot), latestAccount = account, epoch = IdentityEpoch(4))

    /** Runs [events] from [start], checking the step invariants after each. */
    private fun run(start: BarrierState, vararg events: BarrierEvent): List<BarrierStep> {
        var state = start
        return events.map { event ->
            val step = BarrierModel.reduce(state, event)
            checkStepInvariants(state, event, step)
            state = step.state
            step
        }
    }

    private fun BarrierStep.has(effect: BarrierEffect) = effect in effects
    private inline fun <reified T : BarrierEffect> BarrierStep.hasType() = effects.any { it is T }
    private fun BarrierStep.onlyLogs() = effects.all { it is BarrierEffect.Log }

    // ---- one test per row ----

    @Test
    fun b1BeginDrains() {
        val s = open()
        val step = run(s, Begin(ProfileSelect)).single()
        assertEquals(DrainedOp(ProfileSelect, DrainedStage.Draining, s.windowsOpened, transitionId = 1), step.state.drained)
        assertEquals(1, step.state.transitionsBegun)
        assertEquals(1, step.published?.transitionId)
        assertIs<IdentityPhase.Draining>(step.state.phase)
        assertTrue(step.hasType<BarrierEffect.Revoke>())
        assertTrue(step.has(BarrierEffect.AwaitDrain(1)))
        assertEquals(ProfileSelect, step.published?.kind)
    }

    @Test
    fun b2SettledApplies() {
        val step = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled)).last()
        assertEquals(DrainedStage.Applying, step.state.drained?.stage)
        assertEquals(listOf(CancelJobs(ProfileSelect, false), RunApply), step.effects)
    }

    @Test
    fun b3JobsDeadlineCancelsLoudlyAndApplies() {
        val step = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.JobsDeadline)).last()
        assertEquals(DrainedStage.Applying, step.state.drained?.stage)
        assertTrue(step.has(CancelJobs(ProfileSelect, true)))
        assertTrue(step.has(RunApply))
        assertTrue(step.hasType<BarrierEffect.Log>())
    }

    @Test
    fun b3aTeardownUnconfirmedFailsProfile() {
        listOf(ProfileSelect, ActiveProfileDelete, TransitionKind.SlotRemoved).forEach { kind ->
            val s = open()
            val step = run(s, Begin(kind), DrainEnded(DrainEnd.TeardownUnconfirmed)).last()
            assertNull(step.state.drained)
            assertEquals(IdentityPhase.Open, step.state.phase)
            assertEquals(s.epoch, step.state.epoch)
            assertEquals(s.scope, step.state.scope)
            assertTrue(step.has(EndFailed))
            assertFalse(step.has(RunApply))
            assertFalse(step.hasType<CancelJobs>())
        }
    }

    @Test
    fun b3bTeardownUnconfirmedLetsAccountKindsApply() {
        listOf(SignOut, TransitionKind.DeleteAccount, TransitionKind.ServerSwitch).forEach { kind ->
            val step = run(open(), Begin(kind), DrainEnded(DrainEnd.TeardownUnconfirmed)).last()
            assertEquals(DrainedStage.Applying, step.state.drained?.stage)
            assertTrue(step.has(RunApply))
            assertTrue(step.has(CancelJobs(kind, true)))
        }
    }

    @Test
    fun b4PreemptedProfileEndsWithoutApply() {
        DrainEnd.entries.forEach { how ->
            val steps = run(open(), Begin(ProfileSelect), WindowOpened(AccountWipe), DrainEnded(how))
            val last = steps.last()
            assertNull(last.state.drained)
            assertEquals(listOf<BarrierEffect>(EndPreempted), last.effects)
            assertIs<IdentityPhase.Closed>(last.state.phase) // the window still holds
        }
    }

    @Test
    fun b5PreemptedAccountKindApplies() {
        DrainEnd.entries.forEach { how ->
            val last = run(open(), Begin(SignOut), WindowOpened(AccountWipe), DrainEnded(how)).last()
            assertEquals(DrainedStage.Applying, last.state.drained?.stage)
            assertEquals(listOf<BarrierEffect>(RunApply), last.effects)
        }
    }

    @Test
    fun b6GateProceedsOrPreempts() {
        val proceed = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), ApplyGate()).last()
        assertTrue(proceed.has(Proceed))
        assertEquals(true, proceed.state.drained?.gated)

        val pre = run(
            open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), WindowOpened(AccountWipe), WindowClosed(1), ApplyGate(2),
        ).last()
        assertTrue(pre.has(EndPreempted))
        assertNull(pre.state.drained)
        assertEquals(IdentityPhase.Open, pre.state.phase)
        assertEquals(IdentityEpoch(5), pre.state.epoch)
        assertEquals(2, pre.state.scope.slot)
    }

    @Test
    fun b7FinishSettles() {
        val last = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), ApplyGate(), ApplyFinished(3)).last()
        assertEquals(IdentityPhase.Open, last.state.phase)
        assertEquals(IdentityEpoch(5), last.state.epoch)
        assertEquals(IdentityScope(accountA, 3), last.state.scope)
        assertEquals(IdentityState(IdentityScope(accountA, 3), IdentityEpoch(5), IdentityPhase.Open, null), last.published)
    }

    @Test
    fun b7RefusedForUngatedProfile() {
        val last = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), ApplyFinished(3)).last()
        assertTrue(last.onlyLogs())
        assertNotNull(last.state.drained)
    }

    @Test
    fun b8ThrewSettlesAndLogs() {
        val last = run(open(), Begin(SignOut), DrainEnded(DrainEnd.Settled), ApplyThrew(1, "boom")).last()
        assertEquals(IdentityPhase.Open, last.state.phase)
        assertEquals(IdentityEpoch(5), last.state.epoch)
        assertTrue(last.effects.any { it is BarrierEffect.Log && "boom" in it.line })
    }

    @Test
    fun b9AbandonedFromEachStage() {
        val prefixes: List<List<BarrierEvent>> = listOf(
            listOf(Begin(ProfileSelect)),
            listOf(Begin(ProfileSelect), DrainEnded(DrainEnd.Settled)),
            listOf(Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), ApplyGate()),
            listOf(Begin(SignOut), WindowOpened(AccountWipe), WindowClosed(1)), // Preempted, no window
        )
        prefixes.forEach { prefix ->
            val last = run(open(), *(prefix + Abandoned(2)).toTypedArray()).last()
            assertNull(last.state.drained)
            assertEquals(IdentityPhase.Open, last.state.phase)
            assertEquals(IdentityEpoch(5), last.state.epoch, "prefix $prefix")
            assertTrue(last.effects.any { it is CancelJobs && it.logNames && it.kind == prefix.filterIsInstance<Begin>().single().kind })
        }
    }

    @Test
    fun b10WindowOpensFromOpenAndPreemptsADrain() {
        val fromOpen = run(open(), WindowOpened(AccountPublished)).single()
        assertEquals(AccountPublished, fromOpen.state.window)
        assertEquals(1, fromOpen.state.windowsOpened)
        assertTrue(fromOpen.hasType<BarrierEffect.Revoke>())
        assertTrue(fromOpen.has(CancelJobs(AccountPublished, false)))
        assertFalse(fromOpen.has(SignalPreempted))

        val draining = run(open(), Begin(ProfileSelect), WindowOpened(AccountWipe)).last()
        assertEquals(DrainedStage.Preempted, draining.state.drained?.stage)
        assertTrue(draining.has(SignalPreempted))
        assertTrue(draining.hasType<BarrierEffect.Revoke>())

        val applying = run(open(), Begin(SignOut), DrainEnded(DrainEnd.Settled), WindowOpened(AccountWipe)).last()
        assertEquals(DrainedStage.Applying, applying.state.drained?.stage)
        assertFalse(applying.hasType<BarrierEffect.Revoke>()) // already revoked
        assertFalse(applying.has(SignalPreempted))
    }

    @Test
    fun b11WindowAccountRecordsTheAccount() {
        val last = run(open(), WindowOpened(AccountPublished), WindowAccount(accountB)).last()
        assertEquals(accountB, last.state.latestAccount)
        assertEquals(accountA, last.state.scope.account)
        assertNull(last.published)
    }

    @Test
    fun b12WindowCloseSettlesWithTheNewAccount() {
        val last = run(open(), WindowOpened(AccountPublished), WindowAccount(accountB), WindowClosed(2)).last()
        assertEquals(IdentityPhase.Open, last.state.phase)
        assertEquals(IdentityScope(accountB, 2), last.state.scope)
        assertEquals(IdentityEpoch(5), last.state.epoch)
    }

    @Test
    fun b13BeginRefusedWhileHeld() {
        listOf(listOf<BarrierEvent>(Begin(ProfileSelect)), listOf<BarrierEvent>(WindowOpened(AccountWipe))).forEach { prefix ->
            val steps = run(open(), *(prefix + Begin(SignOut)).toTypedArray())
            assertEquals(steps[0].state, steps[1].state)
            assertTrue(steps[1].effects.any { it is BarrierEffect.Log && "begin refused" in it.line })
        }
    }

    @Test
    fun b14NestedWindowRefused() {
        val steps = run(open(), WindowOpened(AccountWipe), WindowOpened(AccountPublished))
        assertEquals(steps[0].state, steps[1].state)
        assertTrue(steps[1].effects.any { it is BarrierEffect.Log && "nested" in it.line })
    }

    @Test
    fun b15OutOfOrderLeavesStateUnchanged() {
        val s = open()
        listOf(
            DrainEnded(DrainEnd.Settled), ApplyGate(), ApplyFinished(1), ApplyThrew(1, "x"), Abandoned(1),
            WindowAccount(accountB), WindowClosed(1),
        ).forEach { event ->
            val step = run(s, event).single()
            assertEquals(s, step.state, "$event")
            assertTrue(step.effects.single().let { it is BarrierEffect.Log && "out-of-order" in it.line })
        }
        val draining = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Preempted)).last()
        assertEquals(DrainedStage.Draining, draining.state.drained?.stage)
        assertTrue(draining.onlyLogs())
    }

    @Test
    fun b16WrongLaneRefused() {
        val s = open()
        listOf(Begin(AccountWipe), Begin(AccountPublished), WindowOpened(ProfileSelect), WindowOpened(SignOut)).forEach { event ->
            val step = run(s, event).single()
            assertEquals(s, step.state)
            assertTrue(step.effects.single().let { it is BarrierEffect.Log && "wrong lane" in it.line })
        }
    }

    // ---- named sequences ----

    @Test
    fun selectInOrder() {
        val steps = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), ApplyGate(), ApplyFinished(2))
        assertTrue(steps[2].has(Proceed))
        assertEquals(IdentityState(IdentityScope(accountA, 2), IdentityEpoch(5), IdentityPhase.Open, null), steps[3].published)
    }

    @Test
    fun teardownUnconfirmedFailsProfileClosed() {
        val s = open()
        val steps = run(s, Begin(ProfileSelect), DrainEnded(DrainEnd.TeardownUnconfirmed))
        assertFalse(steps.any { it.has(RunApply) })
        assertFalse(steps[1].hasType<CancelJobs>())
        assertTrue(steps[1].has(EndFailed))
        assertEquals(IdentityState(s.scope, s.epoch, IdentityPhase.Open, null), steps[1].published)
    }

    /** Revision 8: B1→B10→DrainEnded(TeardownUnconfirmed) hits B4 (the op is Preempted), Closed until B12, one bump. */
    @Test
    fun teardownUnconfirmedAfterWindowIsPreempted() {
        val s = open()
        val steps = run(s, Begin(ProfileSelect), WindowOpened(AccountWipe), DrainEnded(DrainEnd.TeardownUnconfirmed), WindowClosed(1))
        assertEquals(listOf<BarrierEffect>(EndPreempted), steps[2].effects)
        assertFalse(steps.any { it.has(RunApply) || it.has(EndFailed) })
        assertIs<IdentityPhase.Closed>(steps[2].state.phase)
        assertEquals(IdentityPhase.Open, steps[3].state.phase)
        assertEquals(s.epoch.next(), steps[3].state.epoch)
    }

    @Test
    fun transitionIdIncrementsPerBegin() {
        val steps = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.TeardownUnconfirmed), Begin(ProfileSelect))
        val first = steps[0].state.drained!!.transitionId
        val second = steps[2].state.drained!!.transitionId
        assertEquals(steps[0].state.epoch, steps[2].state.epoch) // B3a kept the epoch
        assertTrue(second != first)
        assertEquals(first + 1, second)
        assertEquals(0, steps[1].published?.transitionId) // Open carries no id
        assertEquals(second, steps[2].published?.transitionId)
    }

    @Test
    fun teardownUnconfirmedLetsAccountProceed() {
        val steps = run(open(), Begin(SignOut), DrainEnded(DrainEnd.TeardownUnconfirmed), ApplyFinished(1))
        assertTrue(steps[1].has(RunApply))
        assertEquals(IdentityPhase.Open, steps[2].state.phase)
        assertEquals(IdentityEpoch(5), steps[2].state.epoch)
    }

    @Test
    fun windowBeforeGateAborts() {
        val steps = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), WindowOpened(AccountWipe), ApplyGate(), WindowClosed(1))
        assertTrue(steps[3].has(EndPreempted))
        assertIs<IdentityPhase.Closed>(steps[3].state.phase)
        assertEquals(IdentityEpoch(4), steps[3].state.epoch)
        assertEquals(IdentityPhase.Open, steps[4].state.phase)
        assertEquals(IdentityEpoch(5), steps[4].state.epoch)
    }

    @Test
    fun windowAfterGateHoldsGate() {
        val steps = run(
            open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), ApplyGate(), WindowOpened(AccountWipe), ApplyFinished(2), WindowClosed(2),
        )
        assertTrue(steps[2].has(Proceed))
        assertIs<IdentityPhase.Closed>(steps[4].state.phase)
        assertEquals(IdentityEpoch(4), steps[4].state.epoch)
        assertEquals(IdentityPhase.Open, steps[5].state.phase)
        assertEquals(IdentityEpoch(5), steps[5].state.epoch)
    }

    @Test
    fun windowDuringDrainAbortsProfile() {
        val steps = run(open(), Begin(ProfileSelect), WindowOpened(AccountWipe), DrainEnded(DrainEnd.Preempted))
        assertTrue(steps[2].has(EndPreempted))
        assertFalse(steps.any { it.has(RunApply) })
    }

    @Test
    fun windowDuringDrainLetsAccountApply() {
        val steps = run(
            open(), Begin(SignOut), WindowOpened(AccountWipe), WindowAccount(AccountKey.None), WindowClosed(1),
            DrainEnded(DrainEnd.Preempted), ApplyFinished(1),
        )
        assertIs<IdentityPhase.Closed>(steps[3].state.phase) // drained still holds
        assertTrue(steps[4].has(RunApply))
        assertEquals(IdentityState(IdentityScope(AccountKey.None, 1), IdentityEpoch(5), IdentityPhase.Open, null), steps[5].published)
    }

    @Test
    fun applyThrows() {
        val steps = run(open(), Begin(ProfileSelect), DrainEnded(DrainEnd.Settled), ApplyGate(), ApplyThrew(1, "bad"))
        assertEquals(IdentityPhase.Open, steps[3].state.phase)
        assertEquals(IdentityEpoch(5), steps[3].state.epoch)
    }

    @Test
    fun drainEndedSlotFillsThePreemptedSettle() {
        // B4 settles without an apply; the slot is the one the runtime passes (a window body may move it).
        val last = run(open(slot = 1), Begin(ProfileSelect), WindowOpened(AccountWipe), WindowClosed(2), DrainEnded(DrainEnd.Settled, slotAfter = 3)).last()
        assertEquals(IdentityScope(accountA, 3), last.state.scope)
    }

    // ---- invariants checked on every step ----

    private fun checkStepInvariants(before: BarrierState, event: BarrierEvent, step: BarrierStep) {
        val after = step.state
        val delta = after.epoch.value - before.epoch.value
        assertTrue(delta == 0L || delta == 1L, "epoch moved by $delta on $event")
        val settled = before.phase !is IdentityPhase.Open && after.phase is IdentityPhase.Open
        val b3aNoWindow = event is DrainEnded && event.how == DrainEnd.TeardownUnconfirmed &&
            before.drained?.kind?.isProfileKind == true && before.drained.stage == DrainedStage.Draining && before.window == null
        assertEquals(if (settled && !b3aNoWindow) 1L else 0L, delta, "epoch delta on $event from $before")
        assertEquals(after.phase is IdentityPhase.Open, after.drained == null && after.window == null)
        if (before.drained?.stage == DrainedStage.Preempted) assertTrue(after.drained?.stage != DrainedStage.Draining)
        if (Proceed in step.effects) assertIs<ApplyGate>(event)
        // Revision 8: CancelJobs names the window kind at B10, else the drained op's kind; B3a cancels nothing.
        step.effects.filterIsInstance<CancelJobs>().forEach {
            val expected = if (event is WindowOpened) event.kind else before.drained?.kind
            assertEquals(expected, it.kind, "CancelJobs kind on $event")
        }
        if (b3aNoWindow) assertTrue(step.effects.none { it is CancelJobs })
        step.state.drained?.let { op ->
            if (before.drained == null) assertEquals(before.transitionsBegun + 1, op.transitionId) else assertEquals(before.drained.transitionId, op.transitionId)
        }
        if (b3aNoWindow || (event is DrainEnded && event.how == DrainEnd.TeardownUnconfirmed && before.drained?.kind?.isProfileKind == true)) {
            assertFalse(RunApply in step.effects, "RunApply after TeardownUnconfirmed for a profile kind")
        }
        step.published?.let { published ->
            assertEquals(published.phase !is IdentityPhase.Open, published.kind != null)
            assertEquals(after.toPublic(), published)
            assertEquals(before.version + 1, after.version)
        } ?: run {
            assertEquals(before.toPublic(), after.toPublic())
            assertEquals(before.version, after.version)
        }
    }

    // ---- finite abstraction (round 4 #5) ----

    private data class AbsDrained(val kind: TransitionKind, val stage: DrainedStage, val gated: Boolean)

    private data class Abs(
        val drained: AbsDrained?,
        val window: TransitionKind?,
        val latest: AccountKey,
        val scopeAccount: AccountKey,
        val slot: Int,
        val windowSinceBegin: Boolean,
    )

    private fun alpha(s: BarrierState) = Abs(
        drained = s.drained?.let { AbsDrained(it.kind, it.stage, it.gated) },
        window = s.window,
        latest = s.latestAccount,
        scopeAccount = s.scope.account,
        slot = s.scope.slot,
        windowSinceBegin = s.drained != null && s.windowsOpened != s.drained.windowsAtBegin,
    )

    private fun concrete(a: Abs) = BarrierState(
        epoch = IdentityEpoch(10),
        scope = IdentityScope(a.scopeAccount, a.slot),
        drained = a.drained?.let { DrainedOp(it.kind, it.stage, windowsAtBegin = 3, transitionId = 7, gated = it.gated) },
        window = a.window,
        windowsOpened = if (a.drained != null && a.windowSinceBegin) 4 else 3,
        transitionsBegun = 7,
        latestAccount = a.latest,
        version = 100,
    )

    private val accounts = listOf(AccountKey.None, accountA, accountB)
    private val slots = listOf(1, 2)

    private val alphabet: List<BarrierEvent> = buildList {
        TransitionKind.entries.forEach { add(Begin(it)); add(WindowOpened(it)) }
        for (how in DrainEnd.entries) for (s in slots) add(DrainEnded(how, s))
        slots.forEach { s -> add(ApplyGate(s)); add(ApplyFinished(s)); add(ApplyThrew(s, "e")); add(Abandoned(s)); add(WindowClosed(s)) }
        accounts.forEach { add(WindowAccount(it)) }
    }

    private data class Expect(val after: Abs, val controls: Set<String>, val bump: Boolean)

    /** The oracle over α, written independently of BarrierModel: event first, then the row. */
    private fun oracle(a: Abs, e: BarrierEvent): Expect {
        val same = Expect(a, emptySet(), bump = false)
        val d = a.drained
        val profile = d != null && d.kind in setOf(ProfileSelect, ActiveProfileDelete, TransitionKind.SlotRemoved)
        fun released(slot: Int): Expect {
            val cleared = a.copy(drained = null, windowSinceBegin = false)
            return if (a.window == null) Expect(cleared.copy(scopeAccount = a.latest, slot = slot), emptySet(), true)
            else Expect(cleared, emptySet(), false)
        }
        return when (e) {
            is Begin -> when {
                e.kind == AccountWipe || e.kind == AccountPublished -> same
                d != null || a.window != null -> same
                else -> Expect(a.copy(drained = AbsDrained(e.kind, DrainedStage.Draining, false), windowSinceBegin = false), setOf("Revoke", "AwaitDrain"), false)
            }
            is DrainEnded -> when {
                d == null -> same
                d.stage == DrainedStage.Draining -> when (e.how) {
                    DrainEnd.Settled, DrainEnd.JobsDeadline ->
                        Expect(a.copy(drained = d.copy(stage = DrainedStage.Applying)), setOf("CancelJobs", "RunApply"), false)
                    DrainEnd.TeardownUnconfirmed -> if (profile) {
                        Expect(a.copy(drained = null, windowSinceBegin = false), setOf("EndFailed"), false)
                    } else {
                        Expect(a.copy(drained = d.copy(stage = DrainedStage.Applying)), setOf("CancelJobs", "RunApply"), false)
                    }
                    DrainEnd.Preempted -> same
                }
                d.stage == DrainedStage.Preempted -> if (profile) released(e.slotAfter).let { it.copy(controls = setOf("EndPreempted")) }
                else Expect(a.copy(drained = d.copy(stage = DrainedStage.Applying)), setOf("RunApply"), false)
                else -> same
            }
            is ApplyGate -> if (d != null && profile && d.stage == DrainedStage.Applying && !d.gated) {
                if (!a.windowSinceBegin) Expect(a.copy(drained = d.copy(gated = true)), setOf("Proceed"), false)
                else released(e.slotAfter).copy(controls = setOf("EndPreempted"))
            } else same
            is ApplyFinished -> if (d != null && d.stage == DrainedStage.Applying && (!profile || d.gated)) released(e.slotAfter) else same
            is ApplyThrew -> if (d != null && d.stage == DrainedStage.Applying && (!profile || d.gated)) released(e.slotAfter) else same
            is Abandoned -> if (d != null) released(e.slotAfter).copy(controls = setOf("CancelJobs")) else same
            is WindowOpened -> when {
                e.kind != AccountWipe && e.kind != AccountPublished -> same
                a.window != null -> same
                else -> {
                    val wasDraining = d?.stage == DrainedStage.Draining
                    val controls = buildSet {
                        add("CancelJobs")
                        if (d == null || wasDraining) add("Revoke")
                        if (wasDraining) add("SignalPreempted")
                    }
                    Expect(
                        a.copy(
                            window = e.kind,
                            drained = if (wasDraining) d!!.copy(stage = DrainedStage.Preempted) else d,
                            windowSinceBegin = d != null,
                        ),
                        controls,
                        false,
                    )
                }
            }
            is WindowAccount -> if (a.window != null) Expect(a.copy(latest = e.account), emptySet(), false) else same
            is WindowClosed -> if (a.window == null) same else if (d == null) {
                Expect(a.copy(window = null, scopeAccount = a.latest, slot = e.slotAfter), emptySet(), true)
            } else {
                Expect(a.copy(window = null), emptySet(), false)
            }
        }
    }

    private fun controlsOf(step: BarrierStep): Set<String> = step.effects.mapNotNull {
        when (it) {
            is BarrierEffect.Revoke -> "Revoke"
            is BarrierEffect.AwaitDrain -> "AwaitDrain"
            is CancelJobs -> "CancelJobs"
            RunApply -> "RunApply"
            Proceed -> "Proceed"
            EndPreempted -> "EndPreempted"
            EndFailed -> "EndFailed"
            SignalPreempted -> "SignalPreempted"
            is BarrierEffect.Log -> null
        }
    }.toSet()

    private fun reachable(): Set<Abs> {
        val start = accounts.flatMap { acc -> slots.map { Abs(null, null, acc, acc, it, false) } }
        val seen = start.toMutableSet()
        val queue = ArrayDeque(start)
        while (queue.isNotEmpty()) {
            val a = queue.removeFirst()
            for (e in alphabet) {
                val next = alpha(BarrierModel.reduce(concrete(a), e).state)
                if (seen.add(next)) queue.addLast(next)
            }
        }
        return seen
    }

    @Test
    fun exhaustive() {
        val states = reachable()
        assertTrue(states.size in 10..10_000, "reachable abstract states: ${states.size}")
        println("BarrierModelTest.exhaustive: ${states.size} reachable abstract states x ${alphabet.size} events")
        var pairs = 0
        for (a in states) for (e in alphabet) {
            val before = concrete(a)
            val step = BarrierModel.reduce(before, e)
            checkStepInvariants(before, e, step)
            val expect = oracle(a, e)
            assertEquals(expect.after, alpha(step.state), "state after $e from $a")
            assertEquals(expect.controls, controlsOf(step), "effects of $e from $a")
            assertEquals(if (expect.bump) 1L else 0L, step.state.epoch.value - before.epoch.value, "bump on $e from $a")
            pairs++
        }
        assertEquals(states.size * alphabet.size, pairs)
    }

    /** The closing event a well-behaved driver/auth lane would send next, or null when Open. */
    private fun closer(a: Abs): BarrierEvent? {
        val d = a.drained
        return when {
            a.window != null -> WindowClosed(1)
            d == null -> null
            d.stage != DrainedStage.Applying -> DrainEnded(DrainEnd.Settled, 1)
            d.kind.isProfileKind && !d.gated -> ApplyGate(1)
            else -> ApplyFinished(1)
        }
    }

    @Test
    fun openReachable() {
        for (a in reachable()) {
            var state = concrete(a)
            var events = 0
            while (true) {
                val e = closer(alpha(state)) ?: break
                state = BarrierModel.reduce(state, e).state
                events++
                assertTrue(events <= 4, "not Open within 4 events from $a")
            }
            assertEquals(IdentityPhase.Open, state.phase)
        }
    }
}
