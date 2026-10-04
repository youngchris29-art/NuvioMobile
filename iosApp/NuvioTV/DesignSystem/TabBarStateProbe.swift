import SwiftUI
import UIKit

/// BUG-66 (u/mrStevenx3, open since beta.13): on his Apple TV the system tab bar never minimizes
/// when Home scrolls; the simulator's does. `.tabBarMinimizeBehavior` is unavailable on tvOS and
/// nothing in the app has ever captured the bar's actual state on hardware — the existing
/// `TabBarProbe` (`TabBarVisibility.swift`, the About pane's "Tab Bar Diagnostics" toggle) only
/// ever read a scroll-view's own offset/inset, which tracks the HYSTERESIS this app applies, not
/// whether the SYSTEM bar itself visually minimized. This probe records the bar's own GEOMETRY
/// over time — read straight off the live `UITabBar`, the way `SidebarOverlay`'s
/// `HiddenTabBarFocusBlocker` locates it — so a photo of the About pane answers, for the first
/// time, whether the bar ever minimizes on the device and what Home's scroll state was when it
/// did or did not. Diagnostics only: it installs nothing that changes layout or focus.
///
/// Deliberately its own type, key, and toggle rather than folding into `TabBarProbe` above:
/// that probe's contract is a live in-memory counter snapshot with no persistence (see its own
/// doc comment — "nothing here touches UserDefaults"), while this one needs the exact
/// `PinnedRowSettleProbe` head-preserving persisted-buffer shape (armed at launch, survives a
/// backgrounding between the walk and reaching Settings, paged for the same clipped-`List`-row
/// reason BUG-100/102 fixed there). Mixing the two shapes into one type would have meant either
/// persisting the live counters (a contract `TabBarProbe`'s own doc comment explicitly says it
/// does not have) or losing this probe's relaunch-survivable buffer.
///
/// NAMING NOTE (implementer's judgment call, 2026-09-10): the About pane already has a toggle
/// titled "Tab Bar Diagnostics" bound to the persisted key `debug.tabBarProbe` (driving
/// `TabBarProbe` above), and `Localizable.xcstrings` already carries fr/de/es/it/vi translations
/// for that exact string. This probe therefore uses a distinct toggle title ("Tab Bar Geometry
/// Diagnostics") and a distinct persisted key (`debug.tabBarStateProbe`) so the two features never
/// collide — same About pane, two different rows, two different photographable protocols.
///
/// Line format (beta.18 verdict, BUG-66 — short keys; T1, Steven beta.19-rc1 verdict, 2026-10-03,
/// added `off=`/`ins=` and the pane now wraps each line on two lines). Worst case with the
/// `<N>ms ` stamp:
/// `12345ms y=-9999 h=999 a=1.00 hid=1 tbh=1 st=part off=-9999 ins=-999 sel=5 trk=other sd=1 sdt=1111 m=cls r=attach`
/// is 112 characters (`maxStampedLineLength`); `composeLine` clamps `y`/`h`/`off`/`ins`/`sel`, so
/// it cannot grow past that whatever UIKit reports:
///     y=<bar minY in window> h=<height> a=<alpha> hid=<isHidden 0/1> tbh=<isTabBarHidden 0/1>
///     st=<exp|min|part|unk> off=<rows contentOffset.y|-> ins=<rows adjustedContentInset.top|->
///     sel=<selectedIndex> trk=<rows|none|other|novc> sd=<selected tab's latch 0/1>
///     sdt=<Home/Search/Library/Add-ons latches, 0/1/- each> m=<cls|sb> r=<reason>
/// Reasons: `arm`, `tick` (2 s, duplicates dropped), `down`/`up` (a tab's hysteresis crossing),
/// `attach` (`TabBarContentScrollLink` made its first link for a mount), `tab` (selection change)
/// and `tab2` (0.6 s later, once the switch has settled), `pop` (immersive depth back to 0),
/// `relink` (T1 leg 1 dropped and remade the link after the first rest).
/// `trk` is what the SELECTED tab's controller reports for `contentScrollView(for: .top)` (its
/// `topViewController`'s when it is a navigation controller and reports nil itself), compared by
/// identity with `TabBarContentScrollLink.homeRowsScrollView`; `novc` = no selected controller.
/// `off`/`ins` (T1) are read off `TabBarContentScrollLink.homeRowsScrollView`, raw (not
/// inset-corrected), and are `-` while Home's rows are not linked (another tab, a pushed page,
/// sidebar mode). A linked bar moves 1:1 with the tracked offset, so `st=part off=13` reads "the
/// rows rested 13 pt deep" (H1) and `st=part off=0` reads "the baseline itself is off" (H2).
/// Because the tick dedupe below compares the whole line minus `r=`, a tick now also logs when the
/// rows' offset changed since the last logged line; at rest nothing changes and ticks stay quiet.
/// NSLog-only extra per logged sample: `svh=` (the rows scroll view's height); one NSLog on the
/// first sample carries the controller chain and the legacy `tabBarObservedScrollView`.
/// `t=<ms since arm>` is realized as the standard `<N>ms ` prefix `log(_:)` stamps on every line —
/// the same convention `PinnedRowSettleProbe.log` uses.
///
/// `st` is derived against the TOP edge — this app's tab bar sits at the top of the screen, not
/// the bottom, so "minimized" here means the bar has moved UP out of view, not down. `exp`:
/// the bar's frame (converted to window coordinates) is fully on screen at the top (`minY >= -1`
/// and `maxY > 0`), visible (`alpha > 0.5`) and not hidden. `min`: the bar has moved up out
/// of view or collapsed (`maxY <= h * 0.5`, or `alpha < 0.05`, or `isHidden`). `unk`: this is a
/// sample taken before the bar has ever reported a nonzero frame (a missing bar logs a `NOT-FOUND`
/// line instead). Anything else is `part` — a bar mid transition.
enum TabBarStateProbe {

    /// Read ONCE at first access, like every other launch-latched probe knob in this tree
    /// (`HomeHeroProbe`, `PinnedRowSettleProbe`, `TrailerProbe`, `CollectionFocusAB`) — hence the
    /// "relaunch" language in the About pane's subtitle. `UserDefaults.bool(forKey:)` also coerces
    /// the String "YES" a `-debug.tabBarStateProbe YES` launch argument lands in the argument
    /// domain, so the harness can arm it without a `defaults write`.
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.tabBarStateProbe")

    nonisolated static let linesKey = "debug.tabBarStateProbe.lines"

    /// Frozen arm-time head — never evicted. Holds the first few samples (arm + the earliest
    /// crossings). Same sizing as `PinnedRowSettleProbe`: a 6-row walk down and back is a small,
    /// bounded number of crossings plus the 2 s ticks in between, so 12 head / 28 tail (40 total)
    /// covers the same capture protocol shape ("walk down every row and back up").
    nonisolated static let headMaxLines = 12
    /// Rolling recent window. Holds the end of the walk, where the tester's most recent action is.
    nonisolated static let tailMaxLines = 28

    nonisolated(unsafe) private static var headLines: [String] = []
    nonisolated(unsafe) private static var tailLines: [String] = []
    /// Lines dropped from the tail stream once `tailLines` is full. Stays 0 (no marker rendered)
    /// until eviction genuinely begins. Same shape as `PinnedRowSettleProbe.elidedTailCount`.
    nonisolated(unsafe) private static var elidedTailCount = 0
    nonisolated private static let bufferLock = NSLock()

    /// Set once by `arm(in:)`; every stamped line's `<N>ms` prefix is ms since THIS, not process
    /// launch — the spec's line format calls for "ms since arm", and arming can lag launch by a
    /// SwiftUI render pass or two.
    nonisolated(unsafe) private static var armStart: Date?
    /// Weak so the probe can never keep the app's root window alive — the type doc's explicit
    /// requirement.
    nonisolated(unsafe) private static weak var armedWindow: UIWindow?
    nonisolated(unsafe) private static var timer: Timer?
    /// beta.18 verdict (BUG-66): one hysteresis latch PER TAB (keyed by the `TabView` selection
    /// value, Home 0 … Add-ons 3), replacing the single global `lastScrolledDown`, which went stale
    /// across a tab switch (Search's latch was reported while Home was on screen).
    nonisolated(unsafe) private static var scrolledDownByTab: [Int: Bool] = [:]
    /// An `attach` that landed before the armer had a window; replayed right after `arm`.
    nonisolated(unsafe) private static var pendingAttach = false
    /// T1: a `relink` that landed before the armer had a window; replayed right after `arm`.
    nonisolated(unsafe) private static var pendingRelink = false
    nonisolated(unsafe) private static var loggedControllerChain = false
    /// NSLog dedupe for the console line plus its `svh=` extra (the pane line has its own dedupe).
    nonisolated(unsafe) private static var lastNSLogged: String?
    /// Composed state of the last logged bar sample (everything but `reason`), so a `tick` that
    /// repeats it is dropped instead of flooding the ring buffer (device, 2026-09-30: 41 of 41 lines
    /// were identical ticks). Reset on arm so the first tick after arming always logs.
    nonisolated(unsafe) private static var lastLoggedComposed: String?

    nonisolated private static var sinceArmMs: Int {
        guard let armStart else { return 0 }
        return Int(Date().timeIntervalSince(armStart) * 1000)
    }

    /// TEST ONLY, mirrors `PinnedRowSettleProbe.resetForTesting()`: clears the process-global
    /// buffer and its persisted mirror. Never called from app code — the head is frozen by design
    /// for the tester's photo. Does not touch `armStart`/`armedWindow`/`timer`: a test exercising
    /// the buffer shape has no window to arm against and only needs `log`/`lines`.
    nonisolated static func resetForTesting() {
        bufferLock.lock()
        headLines.removeAll()
        tailLines.removeAll()
        elidedTailCount = 0
        bufferLock.unlock()
        UserDefaults.standard.removeObject(forKey: linesKey)
    }

    /// Appends `line`, stamped with its milliseconds-since-arm, to the persisted head-preserving
    /// ring buffer. Identical shape to `PinnedRowSettleProbe.log` — see that function's doc
    /// comment for the write-through-on-every-call rationale (the capture protocol survives a
    /// backgrounding between the walk and reaching Settings).
    nonisolated static func log(_ line: String) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let stamped = "\(sinceArmMs)ms \(line)"
        if headLines.count < headMaxLines {
            headLines.append(stamped)
        } else {
            tailLines.append(stamped)
            if tailLines.count > tailMaxLines {
                tailLines.removeFirst()
                elidedTailCount += 1
            }
        }
        var display = headLines
        if elidedTailCount > 0 {
            display.append("\u{2026} \(elidedTailCount) lines elided \u{2026}")
        }
        display.append(contentsOf: tailLines)
        UserDefaults.standard.set(display, forKey: linesKey)
    }

    /// Persisted lines in the order `log(_:)` wrote them (chronological), for the About pane to
    /// read on `.onAppear` — exactly like `heroProbeLines`/`rowSettleProbeLines` there. Reordering
    /// into newest-first/paged form is `PinnedRowSettleProbe.displayOrder`/`displayPages`, reused
    /// as-is (see this type's own doc comment on why nothing needed duplicating).
    nonisolated static var lines: [String] {
        UserDefaults.standard.stringArray(forKey: linesKey) ?? []
    }

    /// Starts the 2 s sampling timer against `window`. Re-armable — a later call (e.g. the armer
    /// re-attaching to a new window) invalidates any existing timer first and replaces it, rather
    /// than being a no-op forever after the first arm. No-ops entirely when the probe is off, so an
    /// armer mounted unconditionally in the view tree costs nothing beyond the one `enabled` read.
    ///
    /// Must be called on the main thread — `Timer`/`RunLoop.main` and the `UIKit` walk in
    /// `sample(reason:)` both require it, matching every call site this is invoked from
    /// (`TabBarProbeArmer`'s `UIView.didMoveToWindow`, always on main).
    static func arm(in window: UIWindow?) {
        guard enabled, let window else { return }
        timer?.invalidate()
        armedWindow = window
        armStart = Date()
        lastLoggedComposed = nil
        sample(reason: "arm")
        if pendingAttach {
            pendingAttach = false
            sample(reason: "attach")
        }
        if pendingRelink {
            pendingRelink = false
            sample(reason: "relink")
        }
        let ticker = Timer(timeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                TabBarStateProbe.sample(reason: "tick")
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    /// Invalidates and clears the sampling timer and the weak window reference, and logs the
    /// disarm so the pane's trace shows why sampling stopped instead of just trailing off. Called
    /// from `ArmerView.didMoveToWindow` when the armer leaves its window (e.g. torn down between
    /// tab switches) — without this the old timer kept firing against a window the armer no longer
    /// tracks until ARC happened to deinit it.
    static func disarm() {
        timer?.invalidate()
        timer = nil
        armedWindow = nil
        log("NOT-FOUND why=window-removed st=unk r=disarm")
    }

    /// Fed by `TabBarVisibility.swift`'s `TabBarScrollAutoHide` on a real hysteresis crossing
    /// (never per scroll-geometry tick — see that call site's own comment). Records the new state
    /// for every sample taken from here on and immediately takes one, so the pane shows the bar's
    /// geometry AT the moment Home's scroll state actually changed, not just whatever the next 2 s
    /// tick happens to catch.
    /// beta.18 verdict (BUG-66): `tab` is the `TabView` selection value of the tab root that
    /// crossed (nil for a root with no mapping — logged, not latched).
    static func noteScrollState(isScrolledDown: Bool, tab: Int?) {
        guard enabled else { return }
        if let tab { scrolledDownByTab[tab] = isScrolledDown }
        sample(reason: isScrolledDown ? "down" : "up")
    }

    /// beta.18 verdict (BUG-66): `TabBarContentScrollLink` made its first link for a mount. Before
    /// the armer has a window the sample is deferred to `arm` rather than logged as `NOT-FOUND`.
    static func noteAttached() {
        guard enabled else { return }
        guard armedWindow != nil else {
            pendingAttach = true
            return
        }
        sample(reason: "attach")
    }

    /// T1 (Steven beta.19-rc1 verdict, 2026-10-03): leg 1 of `TabBarRestFix` dropped and remade
    /// the link after the first rest. One sample right after, so the pane shows the bar's state
    /// under the fresh link (`r=relink`). Deferred to `arm` like `noteAttached` when no window yet.
    static func noteRelinked() {
        guard enabled else { return }
        guard armedWindow != nil else {
            pendingRelink = true
            return
        }
        sample(reason: "relink")
    }

    /// beta.18 verdict (BUG-66): the shell's `selectedTab` changed (`ContentView`). Samples now and
    /// again 0.6 s later, when UIKit has finished whatever re-search the switch triggered.
    static func noteTabSelected(_ tab: Int) {
        guard enabled else { return }
        sample(reason: "tab")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                TabBarStateProbe.sample(reason: "tab2")
            }
        }
    }

    /// beta.18 verdict (BUG-66): immersive depth returned to 0 (`TabBarVisibility.popImmersive`).
    static func notePop() {
        guard enabled else { return }
        sample(reason: "pop")
    }

    /// Pure: `none` when nothing is tracked, `rows` when it is Home's linked rows scroll view,
    /// `other` for anything else. Identity, never equality.
    nonisolated static func trackedLabel(tracked: AnyObject?, homeRows: AnyObject?) -> String {
        guard let tracked else { return "none" }
        if let homeRows, tracked === homeRows { return "rows" }
        return "other"
    }

    /// Pure: the per-tab latch bits, Home/Search/Library/Add-ons, `-` for a tab that never crossed.
    nonisolated static func latchBits(_ latches: [Int: Bool]) -> String {
        (0...3).map { latches[$0].map { $0 ? "1" : "0" } ?? "-" }.joined()
    }

    /// T1: the longest line `composeLine` can produce, with a five-digit `<N>ms ` stamp in front
    /// (see the type doc). The Developer pane shows each line on up to two lines.
    nonisolated static let maxStampedLineLength = 112

    /// Pure, for the unit test: one pane line (without the `<N>ms ` stamp). `y`, `h`, `off`, `ins`
    /// and `sel` are clamped so the line keeps its length bound whatever UIKit reports. `offset` and
    /// `inset` (T1) are nil while Home's rows are not linked, and print as `-`.
    nonisolated static func composeLine(minY: CGFloat, height: CGFloat, alpha: CGFloat,
                                        isHidden: Bool, tabBarHidden: Bool, state: String,
                                        offset: CGFloat?, inset: CGFloat?,
                                        selectedIndex: Int?, tracked: String,
                                        selectedScrolledDown: Bool, latchBits: String,
                                        sidebar: Bool, reason: String) -> String {
        let y = min(max(Int(minY.rounded()), -9999), 9999)
        let h = min(max(Int(height.rounded()), 0), 999)
        let sel: String
        if let selectedIndex, (0...9).contains(selectedIndex) { sel = "\(selectedIndex)" } else { sel = "-" }
        return "y=\(y) h=\(h) a=\(String(format: "%.2f", min(max(alpha, 0), 1))) "
            + "hid=\(isHidden ? 1 : 0) tbh=\(tabBarHidden ? 1 : 0) st=\(state) "
            + "off=\(clampedField(offset, limit: 9999)) ins=\(clampedField(inset, limit: 999)) "
            + "sel=\(sel) "
            + "trk=\(tracked) sd=\(selectedScrolledDown ? 1 : 0) sdt=\(latchBits) "
            + "m=\(sidebar ? "sb" : "cls") r=\(reason)"
    }

    /// T1: a rounded point value clamped to ±`limit`, or `-` for nil (rows not linked) and for a
    /// non-finite reading. Clamped in floating point before the `Int` conversion, so no reading
    /// can trap the conversion.
    nonisolated static func clampedField(_ value: CGFloat?, limit: Int) -> String {
        guard let value, value.isFinite else { return "-" }
        let bound = CGFloat(limit)
        return String(Int(min(max(value.rounded(), -bound), bound)))
    }

    /// Walks the armed window's controller tree for the first `UITabBar` (same recursive shape as
    /// `SidebarOverlay.HiddenTabBarFocusBlocker.findTabBarController` — children first, presented
    /// controller last), reads its frame in WINDOW coordinates, alpha, and `isHidden`, computes
    /// `minimized`, and logs one line. Logs a `NOT-FOUND` line instead of silently doing nothing
    /// when no `UITabBarController` is found (sidebar mode legitimately has none — the system bar
    /// is force-hidden and unfocusable there, see `HiddenTabBarFocusBlocker`), mirroring that
    /// type's own "say so instead of silently doing nothing" house rule.
    /// A `tick` whose composed state equals the previously logged sample is not logged; every other
    /// reason always logs.
    static func sample(reason: String) {
        guard enabled else { return }
        let sidebar = SidebarChrome.isEnabled()
        let m = sidebar ? "sb" : "cls"
        guard let window = armedWindow else {
            log("NOT-FOUND why=no-window st=unk m=\(m) r=\(reason)")
            return
        }
        guard let root = window.rootViewController,
              let tabController = findTabBarController(from: root) else {
            log("NOT-FOUND why=no-tabbar st=unk m=\(m) r=\(reason)")
            return
        }
        let bar = tabController.tabBar
        let frameInWindow = bar.convert(bar.bounds, to: window)
        let minY = frameInWindow.minY
        let maxY = frameInWindow.maxY
        let h = frameInWindow.height
        let alpha = bar.alpha
        let state: String
        if h <= 0 {
            // No nonzero frame reported yet — too early to classify.
            state = "unk"
        } else if minY >= -1 && maxY > 0 && alpha > 0.5 && !bar.isHidden {
            state = "exp"
        } else if maxY <= h * 0.5 || alpha < 0.05 || bar.isHidden {
            state = "min"
        } else {
            state = "part"
        }

        let selected = tabController.selectedViewController
        let rows = TabBarContentScrollLink.homeRowsScrollView
        let tracked: String
        if let selected {
            var trackedView = selected.contentScrollView(for: .top)
            if trackedView == nil, let nav = selected as? UINavigationController {
                trackedView = nav.topViewController?.contentScrollView(for: .top)
            }
            tracked = trackedLabel(tracked: trackedView, homeRows: rows)
        } else {
            tracked = "novc"
        }
        let selectedIndex: Int? = selected == nil ? nil : tabController.selectedIndex
        let selectedLatch = selectedIndex.flatMap { scrolledDownByTab[$0] } ?? false

        if !loggedControllerChain {
            loggedControllerChain = true
            var path: [String] = []
            var node: UIViewController? = selected
            while let current = node, path.count < 8 {
                path.append(String(describing: type(of: current)))
                node = current.children.first
            }
            let observed = selected?.tabBarObservedScrollView
            NSLog("[TabBarStateProbe] chain root=%@ tab=%@ selected=%@ legacyObserved=%@",
                  String(describing: type(of: root)),
                  String(describing: type(of: tabController)),
                  path.joined(separator: " > "),
                  observed.map { $0 === rows ? "rows" : String(describing: type(of: $0)) } ?? "nil")
        }

        // T1: the rows' raw offset and top inset ride on the pane line now (`off=`/`ins=`).
        let line = composeLine(minY: minY, height: h, alpha: alpha, isHidden: bar.isHidden,
                               tabBarHidden: tabController.isTabBarHidden, state: state,
                               offset: rows?.contentOffset.y, inset: rows?.adjustedContentInset.top,
                               selectedIndex: selectedIndex, tracked: tracked,
                               selectedScrolledDown: selectedLatch,
                               latchBits: latchBits(scrolledDownByTab), sidebar: sidebar,
                               reason: reason)
        // Dedupe key = everything but the reason.
        let composed = line.components(separatedBy: " r=").first ?? line
        // T1: `ins=` moved onto the pane line; the console keeps only the height here.
        let extras = "svh=\(rows.map { Int($0.bounds.height.rounded()) }.map(String.init) ?? "-")"
        if reason != "tick" || composed + extras != lastNSLogged {
            lastNSLogged = composed + extras
            NSLog("[TabBarStateProbe] %@ %@", line, extras)
        }
        if reason == "tick", composed == lastLoggedComposed { return }
        lastLoggedComposed = composed
        log(line)
    }

    /// Children first, presented controllers last — identical precedence to
    /// `SidebarOverlay.HiddenTabBarFocusBlocker.findTabBarController`, duplicated here rather than
    /// shared because that one is `private` inside a `private final class` in a file this task is
    /// not allowed to touch.
    private static func findTabBarController(from controller: UIViewController) -> UITabBarController? {
        if let tab = controller as? UITabBarController { return tab }
        for child in controller.children {
            if let hit = findTabBarController(from: child) { return hit }
        }
        if let presented = controller.presentedViewController {
            return findTabBarController(from: presented)
        }
        return nil
    }
}

/// Zero-sized `UIViewRepresentable` that arms `TabBarStateProbe` once it lands in a window.
/// Mounted on `MainTabView`'s `TabView` in `ContentView.swift` — a host reachable without touching
/// `HomeView.swift`, which this task may not edit. `didMoveToWindow` can fire before the view is
/// fully attached to the responder chain on some SwiftUI/UIKit interleavings, hence the deferred
/// `DispatchQueue.main.async` before reading `window` again, matching the defensive pattern
/// `SidebarOverlay.HiddenTabBarFocusBlocker.BlockerView` uses for the same reason.
struct TabBarProbeArmer: UIViewRepresentable {
    func makeUIView(context: Context) -> ArmerView { ArmerView() }
    func updateUIView(_ uiView: ArmerView, context: Context) {}

    final class ArmerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard TabBarStateProbe.enabled else { return }
            if window == nil {
                TabBarStateProbe.disarm()
                return
            }
            DispatchQueue.main.async { [weak self] in
                TabBarStateProbe.arm(in: self?.window)
            }
        }
    }
}
