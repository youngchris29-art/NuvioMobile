import Combine
import SharedCore
import SwiftUI

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
    func seed(_ item: MetaPreview?, washFallback: String? = nil) {
        start()
        guard !hasCommitted, let item else { return }
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
                logoCandidates: () -> [MetaPreview] = { [] },
                prefetch: () -> [String]) {
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
    func setCovered(_ covered: Bool, restoresFocus: Bool) {
        focusModel.setCovered(covered, restoresFocus: restoresFocus)
    }

    /// S4 / R2: put focus on `rowKey` (its card `itemId`, else its remembered card, else its first),
    /// through the pager's retry rungs (§3.3).
    func requestFocus(rowKey: String, itemId: String?) {
        pagerHandle.requestFocus(rowKey: rowKey, itemId: itemId, reason: "external")
    }

    /// A strip row took focus (Home: the pager's `onRowChange`, which also fires when focus comes
    /// back into the strip). The background trailer may arm again at the next rest.
    func stripFocusGained() {
        stripOwnsFocus = true
    }

    /// Focus left the strip (tab bar, rail, sidebar), #17: the background trailer stops at once.
    func stripFocusLost() {
        stripOwnsFocus = false
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
