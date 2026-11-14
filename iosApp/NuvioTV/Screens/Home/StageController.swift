import Combine
import SharedCore
import SwiftUI
import UIKit

/// Home Stage & Strip (P1 §4.1): one stage's whole pipeline — focus commit, sticky target, art
/// resolve, swap timing, the strip's motion signal, per-row focus memory and the pager's external
/// handle — reused by Home (`StageStripHome`) and the folder Rows page (P2 §2.8, #2).
///
/// An `ObservableObject` with NO `@Published` property, held by its host as `@StateObject` for its
/// lifetime only: nothing here ever invalidates the host, so no swap phase, pending change or
/// commit re-evaluates the strip (#5, the BUG-126 class). The text, art and wash leaves observe
/// their own sources (`swap`, `swap.washFeed`, `copySource`, `bgTrailer`).
///
/// Pipeline (`start()`, Combine sinks delivered on `DispatchQueue.main`, so nothing runs inside a
/// `willSet` and the resolver's 0.3 s commit transaction never leaks downstream):
///
///     report → HomeHeroFocusModel (0.2 s commit) → sticky target (nil keeps it, D5)
///            → HeroArtResolver.present → $presented → StageSwapDriver.receive
///     StripMotionSignal page start/end → StageSwapDriver.notePageStarted/notePageEnded
///
/// W2-A adds the Continue Watching copy (`progressLookup` / `copySource`, §5) and the background
/// trailer (`bgTrailer`, §7). The trailer is ARMED only through `syncBackgroundTrailer`, which only
/// `StageStripHome` calls (from its `.onReceive(stage.swap.$output)` and the other trailer gates), so
/// the folder Rows page, which builds its own controller, never plays one.
@MainActor
final class StageController: ObservableObject {
    let focusModel = HomeHeroFocusModel()
    let resolver = HeroArtResolver()
    /// `.output`: the text and art leaves observe it. `.washFeed`: only the wash.
    let swap = StageSwapDriver()
    let signal = StripMotionSignal()
    let memory = StripFocusMemory(drivesDefaultFocus: StageStripTuning.focusMemoryDefaultFocus)
    /// S4: the pager installs its focus-request rungs here.
    let pagerHandle = StripPagerHandle()
    /// W2-A (§5): the stage text's Continue Watching input. Only `StageTextBlock` observes it, so a
    /// Continue Watching change re-renders the text leaf and nothing else.
    let copySource = StageCopySource()
    /// W2-A (§7): the background trailer — the same dwell → resolve → play state machine every
    /// trailer surface runs (resolution cache, single player slot, storm breaker), hosted with
    /// `hostsTile == false` (no tile, no morph stages, `host=hero` in its probe lines). Its dwell
    /// waits on the strip's rest signal, so Trailer Start Delay's Automatic is "strip at rest + 1 s"
    /// (M4). Only `StageBackgroundTrailer` observes it (#5).
    let bgTrailer = InlineTrailerCardModel()

    /// W2-A's Continue-Watching-aware copy (§5). nil = Classic's plain meta line and synopsis.
    /// Stored in `copySource`, so setting it re-renders the stage text (and only the text).
    /// `StageStripHome` installs Home's lookup through `setContinueWatching(_:)`; the folder page
    /// leaves it nil.
    var progressLookup: ((MetaPreview) -> WatchProgressEntry?)? {
        get { copySource.progressLookup }
        set { copySource.setProgressLookup(newValue) }
    }
    /// The strip row that owns focus (written by `StripPager`, R2). Rail restores read it. Kept
    /// after focus leaves the strip: it is the row a rail restore goes back to.
    var currentRowKey: String?

    /// The first real focus commit has happened; seeds are ignored from then on.
    private(set) var hasCommitted = false
    /// W2-A (§7): a strip row owns focus right now (`stripFocusGained` / `stripFocusLost`, #17). The
    /// background trailer arms only while it does.
    private(set) var stripOwnsFocus = false
    /// W2-A (§7): the identity (`"<type>:<id>"`) the background trailer is armed for; nil while idle.
    private(set) var bgTrailerKey: String?
    private var seededIdentity: String?
    /// Per-row warm-up dedup, shared by `report` and `rowAppeared` (Classic's
    /// `prefetchedBackdropRows` rule).
    private var warmedRows = Set<String>()
    /// The entries `progressLookup` was last built from (`setContinueWatching`), so an unchanged
    /// republish of the row costs a comparison and no render.
    private var continueWatchingSnapshot: [WatchProgressEntry]?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// Wires the pipeline. Idempotent; the host calls it from `.onAppear`.
    func start() {
        guard !started else { return }
        started = true
        // The stage art is drawn full screen (aspect-fill 1920×1080), Classic's full-bleed form.
        resolver.setSharpenForm(.classic)
        // The post-commit sharpen waits for the strip to rest, like every other trailer/art reader.
        resolver.restSource = .custom(signal)
        // §7: the background trailer's dwell reads the same rest signal (M3/M4).
        bgTrailer.restSource = .custom(signal)
        signal.onPageStarted = { [weak self] in
            self?.swap.notePageStarted()
        }
        signal.onPageEnded = { [weak self] byTimeout in
            self?.swap.notePageEnded(byTimeout: byTimeout)
        }
        #if DEBUG
        memory.onRemember = { [weak self] rowKey, itemId in
            self?.swap.debug.setFoc(rowKey: rowKey, itemId: itemId)
        }
        #endif
        focusModel.$focusedItem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.focusCommitted(item)
            }
            .store(in: &cancellables)
        resolver.$presented
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presentation in
                self?.swap.receive(presentation)
            }
            .store(in: &cancellables)
        // The `trailer start` probe line. Logging only: arming and teardown never depend on it.
        bgTrailer.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.backgroundTrailerPhaseChanged(phase)
            }
            .store(in: &cancellables)
    }

    /// First paint (§4.3): the item the strip focuses at launch (Home: the first strip row's first
    /// item), or the folder page's synthetic folder preview with its cover as `washFallback` (S2).
    /// The first commit then lands on the same identity as a silent gap-fill, so launch never paints
    /// twice. Ignored once a real commit has happened; a changed seed before that re-presents.
    func seed(_ item: MetaPreview?, washFallback: String? = nil, rowHeading: String? = nil) {
        start()
        guard !hasCommitted, let item else { return }
        // BUG-173: a collection-first Home seeds a folder; its row heading must be known before
        // `swap.seed` paints it.
        copySource.noteRowHeading(rowHeading, for: item)
        let identity = "\(item.type):\(item.id)"
        guard identity != seededIdentity else { return }
        seededIdentity = identity
        ArtworkStore.prefetch(heroArtPrefetchItems(for: item))
        swap.seed(item, washFallback: washFallback)
        present(item)
        StageStripProbe.shared.log("seed id=\(identity) fallback=\(washFallback == nil ? 0 : 1)")
    }

    /// The focus-report funnel (#4): Classic's per-row warm-up (`HomeRowPreviews.warmRow`, once per
    /// row against this controller's dedup set), then the commit pipeline, then the swap model's
    /// activity clock. Every row report counts as activity, a nil one (focus leaving a row) included.
    func report(_ item: MetaPreview?,
                source: String,
                rowHeading: String? = nil,
                logoCandidates: () -> [MetaPreview] = { [] },
                prefetch: () -> [String]) {
        // BUG-173: before the commit, so the text leaf reads it with the new shown item.
        copySource.noteRowHeading(rowHeading, for: item)
        if item != nil {
            HomeRowPreviews.warmRow(source: source, item: item, done: &warmedRows,
                                    logoCandidates: logoCandidates, prefetch: prefetch)
        }
        #if DEBUG
        if let item { swap.debug.setFitem(item.id) }
        #endif
        focusModel.reportFocus(item, from: source)
        swap.noteFocusActivity()
    }

    /// A collection row appeared: warm every folder's hero art (Classic's `prefetchCollectionHeroArt`).
    func rowAppeared(collection: NuvioCollection) {
        HomeRowPreviews.warmCollection(collection, done: &warmedRows)
    }

    /// Freezes the focus model while something covers the page (`HomeView.syncHeroFocusCover`'s rule).
    /// BUG-156 (a): a push or the stream picker (`restoresFocus`) also freezes the strip's per-row
    /// memory (`StripFocusMemory.isFrozen`), so a focus change reported under the cover (the In Row
    /// trailer's card collapsing) cannot replace the card the pop restores. A shell cover alone (a
    /// tab switch) moves no card focus and freezes nothing.
    func setCovered(_ covered: Bool, restoresFocus: Bool) {
        focusModel.setCovered(covered, restoresFocus: restoresFocus)
        memory.setFrozen(covered && restoresFocus)
    }

    /// S4 / R2: put focus on `rowKey` (its card `itemId`, else its remembered card, else its first),
    /// through the pager's retry rungs (§3.3).
    func requestFocus(rowKey: String, itemId: String?, reason: String = "external") {
        pagerHandle.requestFocus(rowKey: rowKey, itemId: itemId, reason: reason)
    }

    // MARK: Pop restore (BUG-156)

    /// The host this controller restores for, in the probe lines (`source=home` for Stage Home,
    /// `source=folder` for the folder Rows page, BUG-156 (b)), so one console log tells them apart.
    var uncoverSource = "home"

    /// BUG-156: stales a pending `restoreAfterUncover` and its deferred re-grabs (a new push went
    /// over the page, the viewer moved, the restore retired).
    private var uncoverRestoreGeneration = 0
    /// The pop (`restoreAfterUncover`) while its request still waits for the pager.
    private var uncoverRequestedAt: TimeInterval?
    /// Batch N (BUG-188 follow-up): the row of that pending pop, the replay's anchor when a viewer
    /// press stands the request down before the pager is back.
    private var uncoverPendingRowKey: String?
    /// Stales a replay still waiting out its beat (a new pop, a newer replay, a cancel: a push, a
    /// retire).
    private var uncoverReplayGeneration = 0
    /// The live restore once its request went to the pager. See `UncoverRestorePolicy`.
    ///
    /// BUG-156 (device pass 2026-10-15, Living Room ATV): on hardware the engine's OWN deferred
    /// restoration landed ~35 ms AFTER our rung 2 had put focus on the right card (`[StageStrip]
    /// focus → …` then `PRESS … src=vfocus-up`): it moved focus to the row above and the strip
    /// paged there. BUG-156 (a) (Steven, rc4 verdict 2026-10-16: still jumps on his box): that window
    /// was counted from the REQUEST (1.2 s), and any second move was taken for the viewer's. Now the
    /// window runs from the LANDING (the first row change to the target), a viewer input
    /// (`ViewerInputClock`) retires the restore at once, and a move with no viewer input since the
    /// pop is the engine's, re-grabbed up to `UncoverRestorePolicy.maxRegrabs`.
    private var uncoverRestoreTarget: UncoverRestorePolicy.Target?
    /// Removed in `deinit` (a popped folder page's controller must leave no observer behind).
    nonisolated(unsafe) private var viewerInputObserver: NSObjectProtocol?
    #if DEBUG
    /// The strip rows seen most recently (newest last), for the `-debug.uncoverStealMs` knob.
    private var recentRowKeys: [String] = []
    #endif

    deinit {
        if let viewerInputObserver { NotificationCenter.default.removeObserver(viewerInputObserver) }
    }

    private var uncoverReason: String { "uncover source=\(uncoverSource)" }

    /// The strip's row changed (the pager's `onRowChange`: Stage Home and, BUG-156 (b), the folder
    /// Rows page). See `uncoverRestoreTarget`.
    func noteStripRowChanged(key: String) {
        #if DEBUG
        recentRowKeys.removeAll { $0 == key }
        recentRowKeys.append(key)
        if recentRowKeys.count > 4 { recentRowKeys.removeFirst() }
        #endif
        handleUncoverMove(key: key)
    }

    /// BUG-156 (Steven, beta.19-rc3 follow-ups 2026-10-09 / 10-14): after a pushed folder page or
    /// Detail pops, put focus back on `rowKey`'s card, through the pager's rungs (reason
    /// `uncover source=<host>` on the `[StageStrip] restore` lines). `itemId` is the card the push
    /// left from (captured at the push edge, BUG-156 (a)); nil reads the row's remembered card when
    /// the request goes out. The pop runs in the same update the strip reappears in, and the pager
    /// re-installs its handle only in its own `.onAppear`, which can come after; so the request
    /// waits for the handle, polling every 0.1 s for up to 1 s, and goes out on the next runloop at
    /// the earliest. The pager's anti-theft guard keeps a row the engine already restored on its card.
    func restoreAfterUncover(rowKey: String, itemId: String? = nil) {
        installViewerInputObserver()
        uncoverRestoreGeneration &+= 1
        uncoverRestoreTarget = nil
        uncoverReplayGeneration &+= 1
        let requestedAt = ProcessInfo.processInfo.systemUptime
        uncoverRequestedAt = requestedAt
        uncoverPendingRowKey = rowKey
        StageStripProbe.shared.log("restore pop row=\(rowKey) item=\(itemId ?? "memory") clock=\(ViewerInputClock.shared.isLive ? 1 : 0) source=\(uncoverSource)")
        attemptUncoverRestore(rowKey: rowKey, itemId: itemId, requestedAt: requestedAt,
                              generation: uncoverRestoreGeneration, attempt: 0)
    }

    /// BUG-156 (B13): whether the strip should NOT page for a row change to `key`, because the live
    /// pop restore will re-grab it (the engine's late restoration, not the viewer's move). Same
    /// decision the restore makes in `handleUncoverMove`, asked before the page instead of after.
    func uncoverHoldsPage(forRowKey key: String) -> Bool {
        guard let target = uncoverRestoreTarget else { return false }
        let clock = ViewerInputClock.shared
        if case .regrab = UncoverRestorePolicy.decide(target, key: key,
                                                      now: ProcessInfo.processInfo.systemUptime,
                                                      viewerInputAt: clock.lastAt,
                                                      clockLive: clock.isLive) {
            return true
        }
        return false
    }

    /// A new push: a pop restore still waiting for the pager must not fire under it.
    ///
    /// Batch N review r1 (BUG-188 follow-up): stales a pending replay too, so one still waiting out
    /// its beat (up to ~1.15 s in the pager poll) cannot fire `requestFocus` on a strip row under a
    /// push. Both retire branches of `noteViewerInput` call this BEFORE `replayViewerMove`, whose own
    /// bump then wins for the replay they start.
    func cancelUncoverRestore() {
        uncoverRestoreGeneration &+= 1
        uncoverReplayGeneration &+= 1
        uncoverRestoreTarget = nil
        uncoverRequestedAt = nil
        uncoverPendingRowKey = nil
        uncoverGateRowKey = nil
        pagerHandle.setUncoverGate(nil)
    }

    /// BUG-188: the row the landed restore's gate holds open, nil while the gate is open (mirrors
    /// what `closeUncoverGate` hands the pager, for `UncoverRestorePolicy.regrabsImmediately`).
    private var uncoverGateRowKey: String?

    /// BUG-156 (B13): from the landing until the re-grab window closes, only the target row can
    /// take focus, so the engine's late restoration has nowhere else to go and the strip never
    /// moves. A viewer input retires the restore (`cancelUncoverRestore` opens the gate).
    private func closeUncoverGate(rowKey: String) {
        uncoverGateRowKey = rowKey
        pagerHandle.setUncoverGate(rowKey)
        StageStripProbe.shared.log("restore gate row=\(rowKey) source=\(uncoverSource)")
        let generation = uncoverRestoreGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(UncoverRestorePolicy.landedWindow))
            guard let self, generation == self.uncoverRestoreGeneration else { return }
            self.uncoverGateRowKey = nil
            self.pagerHandle.setUncoverGate(nil)
            StageStripProbe.shared.log("restore gate open row=\(rowKey) why=window source=\(self.uncoverSource)")
        }
    }

    private func attemptUncoverRestore(rowKey: String, itemId: String?, requestedAt: TimeInterval,
                                       generation: Int, attempt: Int) {
        let delay: TimeInterval = attempt == 0 ? 0 : 0.1
        // A main-actor Task: even with no delay it runs after the current update, never inline.
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, generation == self.uncoverRestoreGeneration else { return }
            // The viewer pressed or swiped before the pager came back: their move, not ours.
            if let input = ViewerInputClock.shared.lastAt, input >= requestedAt {
                self.retireUncover(why: "viewer", rowKey: rowKey, from: nil, cancelsPager: false)
                return
            }
            guard self.pagerHandle.isInstalled else {
                if attempt < 10 {
                    self.attemptUncoverRestore(rowKey: rowKey, itemId: itemId, requestedAt: requestedAt,
                                               generation: generation, attempt: attempt + 1)
                } else {
                    self.uncoverRequestedAt = nil
                    StageStripProbe.shared.log("restore row=\(rowKey) rung=0 landed=0 reason=\(self.uncoverReason) nopager")
                }
                return
            }
            let card = itemId ?? self.memory.itemId(for: rowKey)
            let now = ProcessInfo.processInfo.systemUptime
            // The engine may have restored the row already (its row change came before this).
            let alreadyOn = self.stripOwnsFocus && self.currentRowKey == rowKey
            self.uncoverRequestedAt = nil
            self.uncoverRestoreTarget = UncoverRestorePolicy.Target(rowKey: rowKey, itemId: card,
                                                                    requestedAt: requestedAt, issuedAt: now,
                                                                    landedAt: alreadyOn ? now : nil)
            if alreadyOn {
                StageStripProbe.shared.log("restore landed row=\(rowKey) item=\(card ?? "-") after=\(Int((now - requestedAt) * 1000)) via=engine source=\(self.uncoverSource)")
                self.closeUncoverGate(rowKey: rowKey)
            }
            self.requestFocus(rowKey: rowKey, itemId: card, reason: self.uncoverReason)
            #if DEBUG
            if alreadyOn { self.scheduleDebugSteal(rowKey: rowKey, generation: generation) }
            #endif
        }
    }

    /// One row change (or, `key == nil`, focus leaving the strip) against the live restore.
    private func handleUncoverMove(key: String?) {
        guard var target = uncoverRestoreTarget else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let clock = ViewerInputClock.shared
        switch UncoverRestorePolicy.decide(target, key: key, now: now,
                                           viewerInputAt: clock.lastAt, clockLive: clock.isLive) {
        case .land:
            target.landedAt = now
            uncoverRestoreTarget = target
            StageStripProbe.shared.log("restore landed row=\(target.rowKey) item=\(target.itemId ?? "-") after=\(Int((now - target.requestedAt) * 1000)) via=request source=\(uncoverSource)")
            closeUncoverGate(rowKey: target.rowKey)
            #if DEBUG
            scheduleDebugSteal(rowKey: target.rowKey, generation: uncoverRestoreGeneration)
            #endif
        case .keep:
            break
        case .retire(let why):
            retireUncover(why: why, rowKey: target.rowKey, from: key, cancelsPager: why == "viewer")
        case .regrab(let age, let from):
            // BUG-188: what the engine put focus on when it left the strip, read in every build (the
            // immediate re-grab below needs it; the DEBUG diagnostic logs it).
            let window = key == nil
                ? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
                : nil
            let focused = window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
            let item = focused.map { String(describing: type(of: $0)) } ?? "-"
            #if DEBUG
            // BUG-176 (Steven rc7) diagnostic: on the Living Room ATV the engine's late restoration
            // after a pop lands on SwiftUI's `UIKitFocusableFillerItem` (a lazy row's stand-in),
            // which scrolls the strip a row up before this regrab glides it back (4/4 runs, 10-18).
            if key == nil {
                let frame: CGRect = {
                    guard let focused, let window,
                          let space = focused.parentFocusEnvironment?.focusItemContainer?.coordinateSpace else { return .null }
                    return space.convert(focused.frame, to: window.coordinateSpace)
                }()
                let parent = focused?.parentFocusEnvironment.map { String(describing: type(of: $0)) } ?? "-"
                StageStripProbe.shared.log("restore outside focused=\(item) parent=\(parent) frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
            }
            #endif
            target.regrabs += 1
            uncoverRestoreTarget = target
            let generation = uncoverRestoreGeneration
            let n = target.regrabs
            // BUG-188: the engine parked focus on a filler while the gate is closed. Nothing the
            // viewer did put it there (`regrabsImmediately`), so re-grab in this turn instead of a
            // beat later: the ~195 ms out-and-back was the landed card's flicker. The strip stays
            // `scrollDisabled` meanwhile (BUG-176), so the filler never scrolls it.
            let inputSinceLanding = clock.lastAt.map { $0 >= (target.landedAt ?? target.requestedAt) } ?? false
            if key == nil,
               UncoverRestorePolicy.regrabsImmediately(
                   fillerFocused: UncoverRestorePolicy.isFocusableFiller(typeName: item),
                   gateClosed: uncoverGateRowKey == target.rowKey,
                   viewerInputSinceLanding: inputSinceLanding) {
                StageStripProbe.shared.log("restore regrab row=\(target.rowKey) item=\(target.itemId ?? "-") from=outside age=\(Int(age * 1000)) since=\(from) n=\(n) immediate=filler reason=uncover source=\(uncoverSource)")
                requestFocus(rowKey: target.rowKey, itemId: target.itemId,
                             reason: "uncover-regrab source=\(uncoverSource)")
                return
            }
            // Deferred one beat, then re-checked: the press behind a row change can reach the
            // window's recognizer just after the move it caused (`UncoverRestorePolicy.regrabDefer`).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(UncoverRestorePolicy.regrabDefer))
                guard let self, generation == self.uncoverRestoreGeneration,
                      let live = self.uncoverRestoreTarget else { return }
                if UncoverRestorePolicy.viewerMoved(live, viewerInputAt: ViewerInputClock.shared.lastAt) {
                    self.retireUncover(why: "viewer", rowKey: live.rowKey, from: key, cancelsPager: true)
                    return
                }
                StageStripProbe.shared.log("restore regrab row=\(live.rowKey) item=\(live.itemId ?? "-") from=\(key ?? "outside") age=\(Int(age * 1000)) since=\(from) n=\(n) reason=uncover source=\(self.uncoverSource)")
                self.requestFocus(rowKey: live.rowKey, itemId: live.itemId,
                                  reason: "uncover-regrab source=\(self.uncoverSource)")
            }
        }
    }

    /// BUG-176 (Steven rc7; device pass 2026-10-18): an Up or Down pressed while the landed
    /// restore's gate was closed went nowhere (every other row was disabled), so the viewer needed
    /// a second press. Batch N (BUG-188 follow-up; Steven rc9): the same press lost before the
    /// restore landed, or before the pager was back (`pending`), and the rig log showed the engine
    /// sometimes making the move itself. After the retire, wait one `regrabDefer` beat (the press
    /// reaches the window's recognizer after the engine's own move), then ask
    /// `UncoverReplayPolicy` for the destination: nil when the engine moved or the strip ends there.
    /// `waitsForPager`: the pending branch, whose pager may not be installed yet (the short poll
    /// `attemptUncoverRestore` uses).
    private func replayViewerMove(restoreRowKey: String, waitsForPager: Bool) {
        let clock = ViewerInputClock.shared
        guard let kind = clock.lastKind, kind == .up || kind == .down, let pressAt = clock.lastAt else { return }
        uncoverReplayGeneration &+= 1
        let generation = uncoverReplayGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(UncoverRestorePolicy.regrabDefer))
            guard let self, generation == self.uncoverReplayGeneration else { return }
            if waitsForPager {
                var attempt = 0
                while !self.pagerHandle.isInstalled, attempt < 10 {
                    attempt += 1
                    try? await Task.sleep(for: .seconds(0.1))
                    guard generation == self.uncoverReplayGeneration else { return }
                }
                guard self.pagerHandle.isInstalled else { return }
            }
            // Batch N review r1: a newer press since this one is the viewer's own (a second Up must
            // not move twice, a Select may be pushing Detail), and a push over the page freezes the
            // strip's memory (`setCovered`): either way the replay stands down.
            // Review r2: a clickpad thumb roll after the arrow click records a `.swipe` (the
            // "clickpad roll = fake swipe" rule); only a newer real press stands the replay down.
            let clock = ViewerInputClock.shared
            let newerPress = clock.lastAt != pressAt && clock.lastKind != .swipe
            guard !newerPress, !self.memory.isFrozen else { return }
            // Batch N device pass: the restore row is the row the viewer pressed from, in both
            // branches; `decide` compares positions, so the engine's own late (often wrong-way)
            // landing can't masquerade as the viewer's move.
            guard let key = UncoverReplayPolicy.decide(kind: kind,
                                                       currentRowKey: self.stripOwnsFocus ? self.currentRowKey : nil,
                                                       restoreRowKey: restoreRowKey,
                                                       rowKeys: self.pagerHandle.rowKeys) else { return }
            StageStripProbe.shared.log("restore replay \(kind.rawValue) \u{2192} \(key) source=\(self.uncoverSource)")
            self.requestFocus(rowKey: key, itemId: self.memory.itemId(for: key), reason: "uncover-replay")
        }
    }

    /// The restore is over. `cancelsPager`: the viewer moved, so an in-flight request's later rungs
    /// must not pull focus back to the origin row (the BUG-112 F1/F5 stale-request class).
    private func retireUncover(why: String, rowKey: String, from key: String?, cancelsPager: Bool) {
        let input = ViewerInputClock.shared.lastKindLabel
        cancelUncoverRestore()
        if cancelsPager { pagerHandle.cancelRequest(reason: "uncover-\(why)") }
        // A page held for this restore must not leave the strip off the focused row.
        pagerHandle.syncPageToFocus(reason: "uncover-\(why)")
        StageStripProbe.shared.log("restore retired row=\(rowKey) why=\(why) from=\(key ?? "-") input=\(why == "viewer" ? input : "-") source=\(uncoverSource)")
    }

    /// A viewer press or swipe (`ViewerInputClock`) while a pop restore is live retires it at once.
    private func installViewerInputObserver() {
        guard viewerInputObserver == nil else { return }
        viewerInputObserver = NotificationCenter.default.addObserver(
            forName: ViewerInputClock.didRecord, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteViewerInput()
            }
        }
    }

    private func noteViewerInput() {
        if let target = uncoverRestoreTarget {
            guard UncoverRestorePolicy.viewerMoved(target, viewerInputAt: ViewerInputClock.shared.lastAt) else { return }
            // A restore that landed and saw no move inside its window is long over: retire it
            // quietly, with no pager cancel (the press may be starting a request of its own).
            let now = ProcessInfo.processInfo.systemUptime
            let windowOver = target.landedAt.map { now - $0 >= UncoverRestorePolicy.landedWindow }
                ?? (now - target.issuedAt >= UncoverRestorePolicy.unlandedWindow)
            retireUncover(why: windowOver ? "expired" : "viewer", rowKey: target.rowKey, from: nil,
                          cancelsPager: !windowOver)
            if !windowOver { replayViewerMove(restoreRowKey: target.rowKey, waitsForPager: false) }
        } else if let requestedAt = uncoverRequestedAt,
                  let input = ViewerInputClock.shared.lastAt, input >= requestedAt {
            // Not issued yet (the pager is not back): stand the attempt down, and replay an Up or
            // Down once the pager is (Batch N, BUG-188 follow-up).
            let pendingRow = uncoverPendingRowKey
            cancelUncoverRestore()
            if let pendingRow { replayViewerMove(restoreRowKey: pendingRow, waitsForPager: true) }
            StageStripProbe.shared.log("restore retired row=- why=viewer from=- input=\(ViewerInputClock.shared.lastKindLabel) pending=1 source=\(uncoverSource)")
        }
    }

    #if DEBUG
    /// `-debug.uncoverStealMs <ms>` (DEBUG only): the simulator's focus engine never makes the late
    /// restoration the Apple TV makes, so this stands in for it. `ms` after the restore lands, focus
    /// is sent to the most recently seen other strip row (`reason=debug-steal`), the way the engine's
    /// default candidate took it on the device; the policy must then re-grab the target.
    private func scheduleDebugSteal(rowKey: String, generation: Int) {
        let ms = UserDefaults.standard.integer(forKey: "debug.uncoverStealMs")
        guard ms > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard let self, generation == self.uncoverRestoreGeneration,
                  let live = self.uncoverRestoreTarget, live.regrabs == 0, live.rowKey == rowKey,
                  let steal = self.recentRowKeys.last(where: { $0 != rowKey }) else { return }
            StageStripProbe.shared.log("restore debug-steal row=\(steal) from=\(rowKey) source=\(self.uncoverSource)")
            self.requestFocus(rowKey: steal, itemId: nil, reason: "debug-steal")
        }
    }
    #endif

    /// A strip row took focus (Home: the pager's `onRowChange`, which also fires when focus comes
    /// back into the strip). The background trailer may arm again at the next rest.
    func stripFocusGained() {
        stripOwnsFocus = true
    }

    /// Focus left the strip (tab bar, rail, sidebar, Edit band), #17: the background trailer stops at
    /// once.
    func stripFocusLost() {
        stripOwnsFocus = false
        // BUG-156 (review r2 P3-6): focus that left the strip on the viewer's own move (tab bar,
        // rail) must not be pulled back by a pop restore. BUG-156 (a): with the viewer-input clock
        // live, the policy tells that move (an input since the pop: retire) from the engine's late
        // restoration landing outside the strip (the tab bar, the folder's Edit band: re-grab).
        // Without the clock, any loss retires, as before.
        if ViewerInputClock.shared.isLive {
            handleUncoverMove(key: nil)
        } else {
            cancelUncoverRestore()
        }
        StageStripProbe.shared.log("strip focus lost row=\(currentRowKey ?? "-")")
        stopBackgroundTrailer(reason: "focusLost")
    }

    // MARK: Continue Watching copy (W2-A, §5)

    /// Home's Continue Watching row, as the stage's copy lookup: the in-progress title, focused in
    /// any Home row, reads "S1 E3 · Episode · 45m left" and the episode's own synopsis. An unchanged
    /// republish of the same entries does nothing; a real change re-renders the stage text only.
    func setContinueWatching(_ entries: [WatchProgressEntry]) {
        guard continueWatchingSnapshot != entries else { return }
        continueWatchingSnapshot = entries
        progressLookup = StageCopy.progressLookup(entries)
    }

    // MARK: Background trailer (W2-A, §7)

    /// Brings the background trailer in line with the stage. `StageStripHome` is the only caller,
    /// from every gate it watches (the swap output's rest, the focus commit, the covers, the scene,
    /// the setting, the system autoplay preference, the chrome), each handing in the value its
    /// publisher delivered.
    ///
    /// Arms (`reset()` then `focusChanged(true, item:)`, so the dwell starts fresh from the stage's
    /// rest) when `gate.armedIdentity` names a title; tears down on nil. Write-on-change: the same
    /// answer twice is a no-op, so a repeated delivery never restarts a playing trailer.
    func syncBackgroundTrailer(_ gate: StageTrailerGate,
                               output: StageSwapOutput,
                               focused: MetaPreview?,
                               reason: String) {
        let shown = output.shown
        let target = gate.armedIdentity(
            restingKey: output.restingKey,
            shownIdentity: shown?.identity,
            shownIsFolder: shown.map { isCollectionHero($0.item) } ?? false,
            focusedIdentity: focused.map { TrailerResolutionCache.key(type: $0.type, id: $0.id) })
        guard target != bgTrailerKey else { return }
        stopBackgroundTrailer(reason: reason)
        guard let target, let item = shown?.item else { return }
        bgTrailerKey = target
        bgTrailer.reset()
        bgTrailer.focusChanged(true, item: item)
        StageStripProbe.shared.log("trailer arm key=\(target) via=\(reason)")
        #if DEBUG
        InlineTrailerDebugLog.shared.note("event=arm host=hero key=\(target) via=\(reason)")
        swap.debug.noteTrailerArm(key: target, reason: reason)
        #endif
    }

    /// Tears the background trailer down (a no-op while it is idle): the player slot goes back, the
    /// dwell and any in-flight attempt are dropped, and the art shows alone again.
    func stopBackgroundTrailer(reason: String) {
        guard let key = bgTrailerKey else { return }
        bgTrailerKey = nil
        bgTrailer.reset()
        StageStripProbe.shared.log("trailer reset key=\(key) via=\(reason)")
        #if DEBUG
        InlineTrailerDebugLog.shared.note("event=reset host=hero key=\(key) via=\(reason)")
        swap.debug.noteTrailerReset(reason: reason)
        #endif
    }

    // MARK: Private

    private func focusCommitted(_ item: MetaPreview?) {
        // D5: the stage target is sticky. See All, the tab bar and the rail keep the last title.
        guard let item else { return }
        hasCommitted = true
        present(item)
    }

    /// Same identity included: the resolver turns a same-identity payload change (a TMDB gap-fill)
    /// into a silent refresh, exactly as `HomeView.heroPayloadSignature` drives it in Classic.
    private func present(_ item: MetaPreview) {
        resolver.present(item, isFolder: isCollectionHero(item))
    }

    /// `[StageStrip] trailer start key= via=`: the background trailer began playing. `via` is the
    /// dwell gate's own verdict in DEBUG builds (`rest` / `ceiling`), `gate` in release.
    private func backgroundTrailerPhaseChanged(_ phase: InlineTrailerCardModel.Phase) {
        guard case .playing = phase, let key = bgTrailerKey else { return }
        #if DEBUG
        let via = bgTrailer.gateVia ?? "-"
        #else
        let via = "gate"
        #endif
        StageStripProbe.shared.log("trailer start key=\(key) via=\(via)")
    }
}

// MARK: - Stage copy source (W2-A, §5)

/// The stage text's Continue Watching input, kept OFF `StageSwapDriver.output` so a Continue
/// Watching change re-renders the text leaf alone and never the art, the wash or the strip (#5).
/// Only `StageTextBlock` observes it.
@MainActor
final class StageCopySource: ObservableObject {
    /// nil = Classic's plain copy (`StageCopy.make` with no progress).
    @Published private(set) var progressLookup: ((MetaPreview) -> WatchProgressEntry?)?

    init(progressLookup: ((MetaPreview) -> WatchProgressEntry?)? = nil) {
        _progressLookup = Published(wrappedValue: progressLookup)
    }

    /// Publishes on every call (closures cannot be compared): callers set it only when its input
    /// changed (`StageController.setContinueWatching`).
    func setProgressLookup(_ lookup: ((MetaPreview) -> WatchProgressEntry?)?) {
        progressLookup = lookup
    }

    /// BUG-173: the heading of the row each item was reported from, by `"<type>:<id>"`, for
    /// `StageCopy.make(rowHeading:)`. NOT published: a report always lands before its commit (the
    /// 0.2 s focus model, or `seed`'s synchronous present), so the text leaf already re-renders for
    /// the new shown item and reads the heading then; a focus move costs no extra render. Only
    /// reports that name a heading are kept (Home's collection rows), a few dozen folders at most.
    private var rowHeadings: [String: String] = [:]

    func noteRowHeading(_ heading: String?, for item: MetaPreview?) {
        guard let heading, let item else { return }
        rowHeadings["\(item.type):\(item.id)"] = heading
    }

    func rowHeading(for item: MetaPreview) -> String? {
        rowHeadings["\(item.type):\(item.id)"]
    }
}

// MARK: - Background trailer gate (W2-A, §7)

/// When the stage's background trailer may play, as plain facts the host reads at evaluation time
/// (pure; `StageTrailerGateTests` in `StageCopyTests.swift`).
nonisolated struct StageTrailerGate: Equatable, Sendable {
    /// Trailers on Focus on, and Trailer Location set to Background (`"hero"`).
    var modeOn: Bool
    /// tvOS Accessibility ▸ Motion ▸ Auto-Play Video Previews.
    var autoplayAllowed: Bool
    /// `scenePhase == .active`.
    var sceneActive: Bool
    /// A push over Home, the Continue Watching stream picker, or the shell (a tab switch, a
    /// cross-stack cover).
    var covered: Bool
    /// A strip row owns focus (#17).
    var stripOwnsFocus: Bool
    /// The navigation chrome (the sidebar today, the rail after W2-D) holds focus.
    var chromeHoldsFocus: Bool

    /// Every condition that is not about WHICH title is met.
    var isOpen: Bool {
        modeOn && autoplayAllowed && sceneActive && !covered && stripOwnsFocus && !chromeHoldsFocus
    }

    /// The identity to arm the trailer for, or nil. Beyond `isOpen`: the stage has come to rest
    /// (`restingKey`, the swap core's "settled at or after the gate") on the title it shows, that
    /// title is not a collection folder, and it is the title focus has committed to
    /// (`HomeHeroFocusModel.focusedItem`). The last rule keeps a trailer off the stage while focus
    /// sits on a See All tile or an art-less folder (the stage keeps the previous title, D5), and
    /// while a cold resolve of the newly focused title has not reached the stage yet (the stage
    /// still rests on the previous title).
    func armedIdentity(restingKey: String?,
                       shownIdentity: String?,
                       shownIsFolder: Bool,
                       focusedIdentity: String?) -> String? {
        guard isOpen, let restingKey, restingKey == shownIdentity, !shownIsFolder,
              focusedIdentity == restingKey else { return nil }
        return restingKey
    }
}

#if DEBUG
/// The DEBUG readouts' own source (`debug_stage`, `debug_strip`): written by the swap driver, the
/// controller and the pager, observed only by the two invisible labels, so a readout change never
/// re-renders a stage leaf or a row. Every setter writes on change only.
@MainActor
final class StageDebugState: ObservableObject {
    @Published private(set) var swapLine = "phase=idle shown=- pending=- swaps=0"
    @Published private(set) var rest = "-"
    @Published private(set) var disp = "-"
    @Published private(set) var row = 0
    @Published private(set) var rowKey = "-"
    @Published private(set) var fitem = "-"
    @Published private(set) var foc = "-"
    @Published private(set) var atTop = true
    /// The row key the strip last paged to (BUG-156 B13: a held page leaves it on the restored row).
    @Published private(set) var page = "-"

    func setPage(_ key: String) {
        if page != key { page = key }
    }

    /// D10 r1: row-list re-pins (`why=rows`) left to the strip's rest because it was moving, and
    /// re-pins at rest that ran (`debug_strip deferred= settles=`).
    @Published private(set) var deferred = 0
    @Published private(set) var settles = 0

    func noteDeferred() { deferred += 1 }
    func noteSettle() { settles += 1 }

    /// BUG-191: the fit pages, for `debug_strip_fit` only (see `StripPager.noteFitDebug`).
    @Published private(set) var fit = "-"

    func setFit(_ line: String) {
        if fit != line { fit = line }
    }

    func setSwap(line: String, rest: String, disp: String) {
        if swapLine != line { swapLine = line }
        if self.rest != rest { self.rest = rest }
        if self.disp != disp { self.disp = disp }
    }

    func setRow(_ index: Int, key: String) {
        if row != index { row = index }
        if rowKey != key { rowKey = key }
    }

    func setFitem(_ id: String) {
        if fitem != id { fitem = id }
    }

    /// The See All sentinel id starts with a NUL; drop it so the label stays readable.
    func setFoc(rowKey: String, itemId: String) {
        let value = "\(rowKey)/\(itemId.replacingOccurrences(of: "\u{0}", with: ""))"
        if foc != value { foc = value }
    }

    func setAtTop(_ value: Bool) {
        if atTop != value { atTop = value }
    }

    // W2-A (§7): the background trailer's arming record, for `debug_stageTrailer` only (the S7
    // `debug_stage` line is left exactly as it is). Each arm or reset is a real change.
    @Published private(set) var trailerArmed = "-"
    @Published private(set) var trailerArms = 0
    @Published private(set) var trailerResets = 0
    @Published private(set) var trailerLast = "-"

    func noteTrailerArm(key: String, reason: String) {
        trailerArmed = key
        trailerArms += 1
        trailerLast = "arm/\(reason)"
    }

    func noteTrailerReset(reason: String) {
        trailerArmed = "-"
        trailerResets += 1
        trailerLast = "reset/\(reason)"
    }
}
#endif
