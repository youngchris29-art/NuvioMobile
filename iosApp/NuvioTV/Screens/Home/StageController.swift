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
/// their own sources (`swap`, `swap.washFeed`).
///
/// Pipeline (`start()`, Combine sinks delivered on `DispatchQueue.main`, so nothing runs inside a
/// `willSet` and the resolver's 0.3 s commit transaction never leaks downstream):
///
///     report → HomeHeroFocusModel (0.2 s commit) → sticky target (nil keeps it, D5)
///            → HeroArtResolver.present → $presented → StageSwapDriver.receive
///     StripMotionSignal page start/end → StageSwapDriver.notePageStarted/notePageEnded
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

    /// W2-A's Continue-Watching-aware copy (§5). nil = Classic's plain meta line and synopsis.
    var progressLookup: ((MetaPreview) -> WatchProgressEntry?)?
    /// The strip row that owns focus (written by `StripPager`, R2). Rail restores read it.
    var currentRowKey: String?

    /// The title the stage was last asked to show (sticky: a nil commit keeps it, D5).
    private(set) var stageTarget: MetaPreview?
    /// The first real focus commit has happened; seeds are ignored from then on.
    private(set) var hasCommitted = false
    private var seededIdentity: String?
    /// Per-row warm-up dedup, shared by `report` and `rowAppeared` (Classic's
    /// `prefetchedBackdropRows` rule).
    private var warmedRows = Set<String>()
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
        stageTarget = item
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

    /// Focus left the strip (tab bar, rail, sidebar), #17. W2-A tears the background trailer down
    /// here.
    func stripFocusLost() {
        StageStripProbe.shared.log("strip focus lost row=\(currentRowKey ?? "-")")
    }

    // MARK: Private

    private func focusCommitted(_ item: MetaPreview?) {
        // D5: the stage target is sticky. See All, the tab bar and the rail keep the last title.
        guard let item else { return }
        hasCommitted = true
        stageTarget = item
        present(item)
    }

    /// Same identity included: the resolver turns a same-identity payload change (a TMDB gap-fill)
    /// into a silent refresh, exactly as `HomeView.heroPayloadSignature` drives it in Classic.
    private func present(_ item: MetaPreview) {
        resolver.present(item, isFolder: isCollectionHero(item))
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
}
#endif
