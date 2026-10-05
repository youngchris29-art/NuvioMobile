import Combine
import SwiftUI
import UIKit

// Home Stage & Strip (P1 §3): the strip. One row per page, paged by the Wave 0.5 spike's
// mechanism a2, which measured right on the Living Room Apple TV (one 0.51–0.73 s glide per press,
// exactly on the page boundary, nothing after):
//
//  - a vertical `ScrollView` whose pages are each `pageHeight` tall, row top-aligned, with
//    `.scrollTargetLayout()` + `.scrollTargetBehavior(.viewAligned)` and a trailing `peek` spacer,
//    so the last row can reach the top;
//  - the focus engine moves focus; the app animates `.scrollPosition(id:anchor: .top)` to the
//    focused row (0.5 s ease-out), which overrides the engine's slower scroll.
//
// Content height = n·P + peek and the viewport is P + peek, so row k rests at exactly k·P.
//
// Reused by the folder Rows page (P2 §2.8, S4): `menuPagesToTop: false` installs no exit handler
// (Menu pops there), `reportsTab: nil` writes no tab-bar mirror.

/// S4: the external handle to the pager's focus-request rungs (§3.3). `StageController.requestFocus`
/// forwards here; the pager installs itself on appear and uninstalls itself on disappear.
///
/// Review r1 (P1): the installed closure captures the pager's value, which holds the controller that
/// owns this handle. Left installed, that cycle kept every popped folder Rows page's controller alive,
/// and with it the stage's decoded 3840 px art and the page's view model. The owner check matters
/// because Home's placeholder ↔ pager swap (and any remount) can run the incoming pager's `onAppear`
/// before the outgoing one's `onDisappear`, which must not clear the incoming pager's closure.
@MainActor
final class StripPagerHandle {
    typealias Request = @MainActor (_ rowKey: String, _ itemId: String?, _ reason: String) -> Void

    private var request: Request?
    /// The installed pager's box (one per pager instance).
    private weak var owner: AnyObject?

    /// Whether a pager is mounted and listening.
    var isInstalled: Bool { request != nil }

    func install(owner: AnyObject, _ request: @escaping Request) {
        self.owner = owner
        self.request = request
    }

    /// Clears the closure only if `owner` is still the installed pager.
    func uninstall(owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        request = nil
    }

    func requestFocus(rowKey: String, itemId: String?, reason: String = "external") {
        guard let request else {
            StageStripProbe.shared.log("restore row=\(rowKey) item=\(itemId ?? "-") rung=0 landed=0 reason=\(reason) nopager")
            return
        }
        request(rowKey, itemId, reason)
    }
}

/// The pager's per-hop bookkeeping, in a reference box so a hop writes no view state beyond
/// `positionId` (the BUG-126 rule).
@MainActor
final class StripPagerBox {
    var rowKeys: [String] = []
    var rowIndex = 0
    /// The row that owns focus, or nil while focus is outside the strip.
    var focusedRowKey: String?
    /// Rows currently reporting ownership. Empty one runloop turn after a release = focus left the
    /// strip (#17); a row-to-row move never empties it, in either report order.
    var owners = Set<String>()
    /// A Menu page-to-top or an external request in flight: reports from OTHER rows are ignored
    /// until it lands or `programmaticDeadline` passes (the engine may briefly land elsewhere while
    /// the target row scrolls in).
    var programmaticTarget: String?
    var programmaticDeadline: TimeInterval = 0
    /// Stales every rung of an older focus request.
    var restoreGeneration = 0
    var requestSequence = 0

    // MARK: Mounted window (review r1, A P2-5)
    //
    // Kept here, not in `@State`: the window moves on every Down/Up, and as pager state it re-ran
    // the pager's body on every hop, and with it every mounted row's (their closures never compare
    // equal), in the same update that starts the glide (the BUG-126 class). Each page observes its
    // own `StripPageMount`, so a move re-renders only the pages that mount or unmount.

    /// The index the mounted window is centred on (`StripMountWindow`): the focused row, or the
    /// target of a programmatic request so its row is mounted before the rungs ask it for focus.
    private(set) var windowCenter = 0
    /// Rows a long glide passes (Menu → row 0 from row 5), kept mounted until the page ends so the
    /// glide never runs through empty pages or unmounts the row it leaves.
    private(set) var glideSpan: ClosedRange<Int>?
    private var mounts: [String: StripPageMount] = [:]

    func isMounted(_ index: Int, count: Int) -> Bool {
        StripMountWindow.range(center: windowCenter, count: count).contains(index)
            || glideSpan?.contains(index) == true
    }

    /// Page `key`'s mount flag, created on first use with the window's current answer.
    func mount(for key: String, at index: Int, count: Int) -> StripPageMount {
        if let existing = mounts[key] { return existing }
        let created = StripPageMount(isMounted(index, count: count))
        mounts[key] = created
        return created
    }

    func moveWindow(to index: Int) {
        guard windowCenter != index else { return }
        windowCenter = index
        refreshMounts()
    }

    func setGlideSpan(_ span: ClosedRange<Int>?) {
        guard glideSpan != span else { return }
        glideSpan = span
        refreshMounts()
    }

    /// Re-derives every page's flag from `rowKeys` and the window; only a flag that changes
    /// publishes. Never prunes: the body can create a new row's flag before `rowKeys` catches up.
    func refreshMounts() {
        let count = rowKeys.count
        for (index, key) in rowKeys.enumerated() {
            mounts[key]?.set(isMounted(index, count: count))
        }
    }

    /// Drops the flags of rows that left the strip (`rowKeysChanged`, with the current keys).
    func pruneMounts(keeping live: Set<String>) {
        guard mounts.keys.contains(where: { !live.contains($0) }) else { return }
        mounts = mounts.filter { live.contains($0.key) }
    }
}

/// One strip page's mount flag (review r1, A P2-5), observed only by that page's `StripPageSlot`.
@MainActor
final class StripPageMount: ObservableObject {
    @Published private(set) var isMounted: Bool

    init(_ isMounted: Bool) {
        self.isMounted = isMounted
    }

    func set(_ mounted: Bool) {
        if isMounted != mounted { isMounted = mounted }
    }
}

/// One strip page's content: the row while the page is mounted, an empty page of the same height
/// otherwise. Nothing in an empty page can take focus, and Down/Up only ever move to an adjacent
/// row, which is mounted.
private struct StripPageSlot<Content: View>: View {
    @ObservedObject var mount: StripPageMount
    let content: () -> Content

    var body: some View {
        if mount.isMounted {
            content()
        } else {
            Color.clear
        }
    }
}

private enum StripPagerTuning {
    /// How long a programmatic target holds off other rows' ownership reports (spike rule).
    static let programmaticWindow: TimeInterval = 1.5
    /// The restore rungs after the first (next-runloop) one, in seconds. The last one lands on the
    /// row's first card (§3.3).
    static let rungDelays: [(rung: Int, delay: TimeInterval)] = [(2, 0.3), (3, 0.7), (4, 1.0)]
    static let firstCardRung = 4
    /// How long after the last rung an unlanded request stays live before it expires.
    static let expiryGrace: TimeInterval = 0.3
}

/// See the file header.
struct StripPager<Row: View>: View {
    let rowKeys: [String]
    let geometry: StripGeometry
    /// Signal, memory, pager handle; tells the swap driver about pages.
    let controller: StageController
    /// Tab bar content-scroll link: Home and the folder Rows page (P2, #9).
    let linksTabBar: Bool
    /// "Home" → `.reportsScrollToTabBar` (the probe mirror); nil on the folder page.
    let reportsTab: String?
    /// S4: false → no `.onExitCommand` at all (the folder page pops on Menu).
    let menuPagesToTop: Bool
    /// The host's Menu-at-row-0 handler (nil = the system default).
    let atTopExit: (() -> Void)?
    let onRowChange: (_ index: Int, _ key: String) -> Void
    /// Rail Hide While Browsing (#8, §6): the page's target index and its animation length.
    let onPageStart: (_ toIndex: Int, _ seconds: TimeInterval) -> Void
    /// #17: focus left the strip (tab bar, rail).
    let onStripFocusLost: () -> Void
    private let row: (_ key: String) -> Row

    @State private var positionId: String?
    @State private var focusRequest = PinnedRowFocusRequest.none
    /// Flips only between row 0 and row 1, so the host is not re-rendered per hop.
    @State private var atTop = true
    /// Per-hop bookkeeping, including the mounted window (see `StripPagerBox`).
    @State private var box = StripPagerBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(rowKeys: [String],
         geometry: StripGeometry,
         controller: StageController,
         linksTabBar: Bool,
         reportsTab: String?,
         menuPagesToTop: Bool,
         atTopExit: (() -> Void)?,
         onRowChange: @escaping (_ index: Int, _ key: String) -> Void,
         onPageStart: @escaping (_ toIndex: Int, _ seconds: TimeInterval) -> Void,
         onStripFocusLost: @escaping () -> Void,
         @ViewBuilder row: @escaping (_ key: String) -> Row) {
        self.rowKeys = rowKeys
        self.geometry = geometry
        self.controller = controller
        self.linksTabBar = linksTabBar
        self.reportsTab = reportsTab
        self.menuPagesToTop = menuPagesToTop
        self.atTopExit = atTopExit
        self.onRowChange = onRowChange
        self.onPageStart = onPageStart
        self.onStripFocusLost = onStripFocusLost
        self.row = row
    }

    /// Only the Home strip drives the shared motion probe (the folder page has its own readout).
    private var ownsProbe: Bool { reportsTab != nil && StageStripProbe.enabled }

    var body: some View {
        // Hoisted so the render-time `visualEffect` closure captures plain numbers (no view value).
        let page = geometry.pageHeight
        let leading = geometry.contentLeading
        let trailing = geometry.trailingMargin
        let exitHandler: (() -> Void)? = atTop ? atTopExit : { pageToTop() }
        ScrollView(.vertical) {
            // Not a `LazyVStack`: it recreated the row ABOVE the focused one while focus was landing
            // on it (Up from row i: focus reached row i−1's remembered card, the row was rebuilt as
            // the strip began to scroll, focus dropped to nil, and the engine re-entered the row
            // through its focus section at the card nearest the screen centre; end-of-Wave-2 FA87
            // walk). Every page frame exists eagerly, so `.scrollPosition(id:)` and the view-aligned
            // targets see the whole strip; only the rows inside `StripMountWindow` mount real content,
            // so the row above and the row below the focused one are always stable.
            VStack(alignment: .leading, spacing: 0) {
                pages(page: page, leading: leading, trailing: trailing)
            }
            .scrollTargetLayout()
            .background(alignment: .topLeading) {
                if linksTabBar {
                    // Row 0 rests at offset 0 (bar shown); row k ≥ 1 rests at k·P ≥ 388 pt, far past
                    // the 68 pt bar (fully hidden). Exact rests mean the bar is never half shown.
                    TabBarContentScrollLinkAttacher(pinnedContainer: false)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
            .background(alignment: .topLeading) {
                if ownsProbe {
                    StageStripMarker()
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .scrollPosition(id: $positionId, anchor: .top)
        .scrollTargetBehavior(.viewAligned)
        // D4 / #3: the spike's clip, with its top edge feathered across the stage's 24 pt bottom
        // gutter, so a row leaving upward softens there and never draws over the synopsis. A
        // clip/mask never touches focusability.
        .scrollClipDisabled()
        .mask(alignment: .top) {
            StripEdgeMask(gutter: StripGeometry.stageBottomGap)
        }
        .rowsMotionStamp(.vertical)
        .modifier(StripTabBarReportModifier(tab: reportsTab))
        .modifier(StripExitCommandModifier(installed: menuPagesToTop, handler: exitHandler))
        .environment(\.pinnedRowFocusRequest, focusRequest)
        .environment(\.pinnedRowFocusOwnership, PinnedRowFocusOwnership(report: { key, owns in
            handleOwnership(key, owns: owns)
        }))
        .environment(\.stripFocusMemory, controller.memory)
        .environment(\.rowRestSource, .custom(controller.signal))
        .onAppear {
            controller.pagerHandle.install(owner: box) { key, itemId, reason in
                requestRowFocus(key, itemId: itemId, reason: reason)
            }
            if positionId == nil, let first = rowKeys.first {
                positionId = first
            }
        }
        // Review r1 (P1): see `StripPagerHandle`. A push over the page, a tab switch or a pop
        // uninstalls; coming back installs again before anything can ask for focus (the rail's
        // return routes register on appear too).
        .onDisappear {
            controller.pagerHandle.uninstall(owner: box)
        }
        .onChange(of: rowKeys, initial: true) { _, keys in
            rowKeysChanged(keys)
        }
        .onChange(of: probeConfiguration, initial: true) { _, _ in
            guard ownsProbe else { return }
            StageStripProbe.shared.configure(pageHeight: geometry.pageHeight,
                                             stripHeight: geometry.stripHeight,
                                             rowCount: rowKeys.count)
        }
    }

    @ViewBuilder
    private func pages(page: CGFloat, leading: CGFloat, trailing: CGFloat) -> some View {
        let count = rowKeys.count
        let pagerBox = box
        ForEach(Array(rowKeys.enumerated()), id: \.element) { index, key in
            // Outside the window an empty page of the same height (`StripPageSlot`).
            StripPageSlot(mount: pagerBox.mount(for: key, at: index, count: count)) {
                row(key)
                    .padding(.leading, leading)
                    .padding(.trailing, trailing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: page, alignment: .top)
            // §3.4: render-time only, no state writes. The page at rest is exactly 1, so the
            // focused card's lift renders untouched; the peeking page reads 0.6.
            .visualEffect { content, proxy in
                content.opacity(StripGeometry.pageOpacity(
                    minY: proxy.frame(in: .scrollView(axis: .vertical)).minY,
                    pageHeight: page))
            }
            .id(key)
        }
        Color.clear.frame(height: geometry.peek)
    }

    private var probeConfiguration: String {
        "\(geometry.pageHeight)|\(geometry.stripHeight)|\(rowKeys.count)"
    }

    // MARK: Ownership (§3.1)

    private func handleOwnership(_ key: String, owns: Bool) {
        guard owns else {
            let pagerBox = box
            pagerBox.owners.remove(key)
            // One runloop turn later: a row-to-row move reports the destination's `true` in the same
            // turn (in either order), so only a real exit leaves `owners` empty here.
            DispatchQueue.main.async {
                guard pagerBox.owners.isEmpty, pagerBox.focusedRowKey != nil else { return }
                pagerBox.focusedRowKey = nil
                StageStripProbe.shared.log("focus left the strip from row=\(key)")
                onStripFocusLost()
            }
            return
        }
        box.owners.insert(key)
        // F5: a completed request must not be re-applied by a row that remounts later.
        if focusRequest.rowKey == key {
            focusRequest = PinnedRowFocusRequest(rowKey: nil, generation: focusRequest.generation)
        }
        if let target = box.programmaticTarget {
            if target == key {
                box.programmaticTarget = nil
                // Review r1 (A P2-2): landed, so the later rungs stand down now. A rung that ran
                // after the viewer moved on (a Down at 0.2 s after Menu; a second Menu that sent
                // focus to the tab bar) re-issued the request, and the row pulled focus back.
                box.restoreGeneration &+= 1
            } else if ProcessInfo.processInfo.systemUptime < box.programmaticDeadline {
                StageStripProbe.shared.log("ownership \(key) ignored: programmatic target \(target) in flight")
                return
            } else {
                // The window passed and another row holds focus: the viewer has moved on, so the
                // request must not land later (see `expireRequest`).
                box.programmaticTarget = nil
                dropStaleRequest(keeping: key)
            }
        }
        guard key != box.focusedRowKey else { return }
        box.focusedRowKey = key
        guard let index = rowKeys.firstIndex(of: key) else { return }
        let previous = box.rowIndex
        box.rowIndex = index
        box.moveWindow(to: index)
        controller.currentRowKey = key
        // A frame-time window per hop (no-op unless `debug.collectionFrameProbe` is on).
        CollectionFocusFrameSampler.shared.arm(rowKey: key, gif: false)
        page(to: key, index: index, from: previous)
        let top = index == 0
        if atTop != top { atTop = top }
        if ownsProbe, previous != index {
            StageStripProbe.shared.noteRowChange(from: previous, to: index, key: key)
        }
        #if DEBUG
        controller.swap.debug.setRow(index, key: key)
        controller.swap.debug.setAtTop(top)
        #endif
        onRowChange(index, key)
    }

    // MARK: Paging

    /// `alongside` (W2-A, #16) runs inside the page's own transaction: Menu's first focus rung, so
    /// the focus write and the position animation are one transaction. With no page to run (already
    /// on `key`) it runs at once.
    private func page(to key: String, index: Int, from previous: Int, alongside: (() -> Void)? = nil) {
        guard positionId != key else {
            alongside?()
            return
        }
        let seconds = reduceMotion ? 0 : StageStripTuning.pageSeconds
        // A glide longer than the mounted window keeps every row it passes mounted until it ends.
        let span = min(previous, index)...max(previous, index)
        let longGlide = span.count > StripMountWindow.radius + 1
        let pagerBox = box
        if longGlide { pagerBox.setGlideSpan(span) }
        let signal = controller.signal
        let generation = signal.pageStarted(duration: seconds)
        onPageStart(index, seconds)
        StageStripProbe.shared.log("page to=\(index) key=\(key) seconds=\(seconds) gen=\(generation)")
        if seconds == 0 {
            positionId = key
            alongside?()
            signal.pageEnded(generation: generation)
            if longGlide { pagerBox.setGlideSpan(nil) }
        } else {
            // #15: the page ends at its animation's real completion, not at a nominal 0.5 s.
            withAnimation(.easeOut(duration: seconds), completionCriteria: .logicallyComplete) {
                positionId = key
                alongside?()
            } completion: {
                signal.pageEnded(generation: generation)
                if longGlide, pagerBox.glideSpan == span { pagerBox.setGlideSpan(nil) }
            }
        }
    }

    /// Menu at row > 0 (§6): page to row 0 and put focus on its remembered card.
    ///
    /// W2-A (#16): the page and the first focus rung go out in ONE transaction. The device spike's
    /// Menu → row 0 was one 1.36 s motion, the engine's scroll winning over the app's glide; the
    /// first rung used to follow a runloop after the page, so the focus write and the position
    /// animation were two transactions. Now the request is written inside the page's
    /// `withAnimation`, so row 0 takes focus in the same update the glide starts. The device pass
    /// measures it (the main session's item); the later rungs are unchanged.
    private func pageToTop() {
        guard let first = box.rowKeys.first else { return }
        if ownsProbe { StageStripProbe.shared.notePress("menu") }
        requestRowFocus(first, itemId: controller.memory.itemId(for: first), reason: "menu",
                        firstRungInPage: true)
        controller.swap.noteFocusActivity()
    }

    private func rowKeysChanged(_ keys: [String]) {
        let previousFirst = box.rowKeys.first
        box.rowKeys = keys
        let live = Set(keys)
        box.pruneMounts(keeping: live)
        // Review r1 (A P3-7): a row removed from the data while it holds focus (its last Continue
        // Watching entry removed from the hold menu, Upcoming emptying) never reports `false`. Left
        // in `owners`, it kept `onStripFocusLost` from ever firing again.
        box.owners.formIntersection(live)
        if let focused = box.focusedRowKey, !live.contains(focused) {
            let pagerBox = box
            // One turn later, as in `handleOwnership`: the row that takes focus reports first.
            DispatchQueue.main.async {
                guard pagerBox.owners.isEmpty, let stale = pagerBox.focusedRowKey,
                      !pagerBox.rowKeys.contains(stale) else { return }
                pagerBox.focusedRowKey = nil
                StageStripProbe.shared.log("focus left the strip: row=\(stale) removed")
                onStripFocusLost()
            }
        }
        if positionId == nil, let first = keys.first {
            positionId = first
        }
        guard let key = box.focusedRowKey else {
            followRowsWhileOutside(keys, previousFirst: previousFirst)
            return
        }
        guard let index = keys.firstIndex(of: key), index != box.rowIndex else {
            box.refreshMounts()
            return
        }
        // Rows were inserted or removed above the focused row; `.scrollPosition(id:)` keeps it in
        // place, only its index moved.
        box.rowIndex = index
        box.refreshMounts()
        box.moveWindow(to: index)
        let top = index == 0
        if atTop != top { atTop = top }
        #if DEBUG
        controller.swap.debug.setRow(index, key: key)
        controller.swap.debug.setAtTop(top)
        #endif
        onRowChange(index, key)
    }

    /// Review r1 (A P2-6): rows changed while focus is outside the strip (the tab bar at launch, the
    /// rail). `.scrollPosition(id:)` keeps the shown row anchored, so a row arriving above row 0
    /// (Upcoming, a late Continue Watching) sat hidden above the viewport, the linked tab bar hid,
    /// and the stage showed a title from a row that wasn't on screen. A strip resting on row 0
    /// follows the new first row; one resting further down keeps its row, and its index follows.
    private func followRowsWhileOutside(_ keys: [String], previousFirst: String?) {
        if box.rowIndex == 0, let first = keys.first, first != previousFirst,
           positionId == previousFirst || positionId.map({ !keys.contains($0) }) == true {
            positionId = first
            StageStripProbe.shared.log("rows changed outside the strip: row 0 is now \(first)")
        }
        guard let shown = positionId, let index = keys.firstIndex(of: shown) else {
            box.refreshMounts()
            return
        }
        box.rowIndex = index
        box.refreshMounts()
        box.moveWindow(to: index)
        let top = index == 0
        if atTop != top { atTop = top }
        #if DEBUG
        controller.swap.debug.setRow(index, key: shown)
        controller.swap.debug.setAtTop(top)
        #endif
    }

    // MARK: Focus requests (§3.3)

    /// The rungs: issue at the next runloop, re-issue at 0.3 s and 0.7 s while the row has not taken
    /// focus, then at 1.0 s on the row's FIRST card. Generation-guarded; each rung logs
    /// `[StageStrip] restore row= item= rung= landed=`. A row that is far away is paged to first, so
    /// it is realized before its cards are asked to take focus.
    ///
    /// `firstRungInPage` (Menu, #16): rung 1 is written inside the page's own transaction instead of
    /// on the next runloop. A row that mounts only with this request's window move still takes it
    /// when it mounts (`pinnedRowUpFallbackTarget` re-applies a live request on appear, F5), and the
    /// timed rungs cover the rest.
    private func requestRowFocus(_ key: String, itemId: String?, reason: String,
                                 firstRungInPage: Bool = false) {
        guard let index = box.rowKeys.firstIndex(of: key) else {
            StageStripProbe.shared.log("restore row=\(key) item=\(itemId ?? "-") rung=0 landed=0 reason=\(reason) norow")
            return
        }
        box.restoreGeneration &+= 1
        let generation = box.restoreGeneration
        // A far row (Menu → row 0 from row 5, a rail restore) is outside the mounted window: move
        // the window first, so the row exists when the rungs ask it for focus.
        box.moveWindow(to: index)
        box.programmaticTarget = key
        box.programmaticDeadline = ProcessInfo.processInfo.systemUptime + StripPagerTuning.programmaticWindow
        let from = box.rowIndex
        if firstRungInPage {
            page(to: key, index: index, from: from) {
                runRung(1, key: key, itemId: itemId, reason: reason, generation: generation)
            }
        } else {
            page(to: key, index: index, from: from)
            DispatchQueue.main.async {
                runRung(1, key: key, itemId: itemId, reason: reason, generation: generation)
            }
        }
        for entry in StripPagerTuning.rungDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + entry.delay) {
                runRung(entry.rung, key: key, itemId: itemId, reason: reason, generation: generation)
            }
        }
        let lastDelay = StripPagerTuning.rungDelays.last?.delay ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + lastDelay + StripPagerTuning.expiryGrace) {
            expireRequest(key: key, reason: reason, generation: generation)
        }
    }

    /// A request that never landed must not stay live. The last rung leaves it in the environment,
    /// and a row that remounts later re-applies a live request on appear (F5), so it would take
    /// focus seconds afterwards, in the middle of the viewer's next press. On the folder Rows page
    /// one Down paged twice that way (end-of-Wave-2 FA87 walk): the page's first-focus request for
    /// a row still off screen never landed, and the row re-applied it when Down scrolled it in. So
    /// the request expires after its last rung, and the strip then follows the row that actually
    /// holds focus, whose ownership report the in-flight window had set aside.
    private func expireRequest(key: String, reason: String, generation: Int) {
        guard box.restoreGeneration == generation else { return }   // landed, or a newer request
        box.restoreGeneration &+= 1
        if box.programmaticTarget == key { box.programmaticTarget = nil }
        dropStaleRequest(keeping: nil)
        StageStripProbe.shared.log("restore row=\(key) expired reason=\(reason)")
        if let owner = box.owners.first(where: { $0 != key }), owner != box.focusedRowKey {
            handleOwnership(owner, owns: true)
        }
    }

    /// Clears a live focus request for any row but `keeping`, and stands its remaining rungs down.
    private func dropStaleRequest(keeping key: String?) {
        guard let pending = focusRequest.rowKey, pending != key else { return }
        focusRequest = PinnedRowFocusRequest(rowKey: nil, generation: focusRequest.generation)
        box.restoreGeneration &+= 1
    }

    private func runRung(_ rung: Int, key: String, itemId: String?, reason: String, generation: Int) {
        guard box.restoreGeneration == generation else { return }
        let landed = box.focusedRowKey == key
        if rung > 1, landed {
            StageStripProbe.shared.log("restore row=\(key) item=\(itemId ?? "-") rung=\(rung) landed=1 reason=\(reason)")
            box.restoreGeneration &+= 1   // landed: the later rungs stand down
            return
        }
        let firstCard = rung == StripPagerTuning.firstCardRung
        box.requestSequence &+= 1
        focusRequest = PinnedRowFocusRequest(rowKey: key,
                                             generation: box.requestSequence,
                                             itemId: firstCard ? nil : itemId,
                                             forceFirst: firstCard)
        StageStripProbe.shared.log("restore row=\(key) item=\(firstCard ? "first" : (itemId ?? "-")) rung=\(rung) landed=\(landed ? 1 : 0) reason=\(reason)")
    }
}

/// `.reportsScrollToTabBar(tab:)` without the `isScrolledDown` binding (§6): the strip's own
/// `onRowChange` owns that, and TabBarStateProbe keeps its mirror. Absent when `tab` is nil.
private struct StripTabBarReportModifier: ViewModifier {
    let tab: String?

    func body(content: Content) -> some View {
        if let tab {
            content.reportsScrollToTabBar(tab: tab)
        } else {
            content
        }
    }
}

/// Menu (§6, S4): `installed` is the host's constant (`menuPagesToTop`), so the branch never flips
/// mid-session; the handler itself switches between page-to-top and the host's at-top exit.
private struct StripExitCommandModifier: ViewModifier {
    let installed: Bool
    let handler: (() -> Void)?

    func body(content: Content) -> some View {
        if installed {
            content.onExitCommand(perform: handler)
        } else {
            content
        }
    }
}
