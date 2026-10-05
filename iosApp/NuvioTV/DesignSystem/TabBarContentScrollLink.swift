import SwiftUI
import UIKit

/// beta.18 verdict (BUG-66): tells UIKit, explicitly, which scroll view the top tab bar follows on
/// Home.
///
/// The tester's two Tab Bar Geometry pane photos showed two regimes on ONE device: (A) the bar's
/// frame never moves (minY 46 the whole walk; `isHidden` flips 1 and back 0 while scrolled down —
/// UIKit's own auto-hide, undone by SwiftUI re-applying `.automatic`), and (B) the bar follows
/// Home's rows ScrollView 1:1 (minY → −1431 and back). The reading: nothing in the app ever called
/// `setContentScrollView(_:for:)`, so UIKit falls back to its heuristic ("when no content scroll
/// view is set for an edge, UIKit uses a heuristic to search for a UIScrollView to track",
/// `UIViewController.h`). At a cold launch that search runs BEFORE the pinned hero header mounts
/// and finds the rows scroll view; after a tab switch it re-searches, the rows scroll view now sits
/// below the hero and is not found, and the bar stays pinned. Christian's own Apple TV (hero items
/// cached before Home appears) is always pinned.
///
/// So the association is made explicit and deterministic here, behind an About A/B knob that is ON
/// by default, and `TabBarStateProbe` reports what is tracked (`trk=`) so one pane photo settles
/// whether this was the mechanism.
///
/// What this deliberately does NOT do (the bans in `docs/traces-2026-08-27-bug66-upcoming.md`):
/// no scroll-driven `.toolbarVisibility`, no `.safeAreaInset` hero, no hero-refocus completion
/// scroll. It writes nothing into SwiftUI state, it does not set the deprecated
/// `tabBarObservedScrollView` (read only, for the log), and the only geometry it touches is the
/// pinned container's `contentInsetAdjustmentBehavior` (`.never`; the pinned rows already carry
/// `contentInsets.top == 0`, which the settle corrector depends on — classic is never touched).
enum TabBarContentScrollLink {
    nonisolated static let defaultsKey = "debug.bug66ContentScrollView"

    /// Launch-latched, DEFAULT ON: a missing key is ON; `NO` (the launch-argument String, which
    /// `bool(forKey:)` coerces) or `false` is OFF. Same latch shape as every other probe knob.
    nonisolated static let enabled: Bool = resolveEnabled(UserDefaults.standard)

    nonisolated static func resolveEnabled(_ defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }

    /// review r1 (P2-1): the controllers that actually receive `setContentScrollView`. Every
    /// `UINavigationController` in the chain is dropped (order preserved): Home sits inside a
    /// `NavigationStack`, and a link set on the navigation controller sticks for the session, so
    /// pages pushed from Home that keep the tab bar (See All, folder, person, entity browse) would
    /// inherit Home's off-screen rows as the tracked scroll view. The SDK says containing
    /// navigation/tab controllers observe the value set on their child, so Home's own hosting
    /// controller is enough.
    nonisolated static func linkTargets(in chain: [UIViewController]) -> [UIViewController] {
        chain.filter { !($0 is UINavigationController) }
    }

    /// The rows `UIScrollView` last linked (weak). Read by `TabBarStateProbe` to label `trk=`.
    nonisolated(unsafe) static weak var homeRowsScrollView: UIScrollView?
}

/// T1 (Steven beta.19-rc1 verdict, 2026-10-03; BUG-66 residual): his Tab Bar Geometry pane read
/// `y=-13 st=part` at rest after launch, the bar parked 13 pt up and half on screen. UIKit moves a
/// linked bar 1:1 with the tracked scroll view's offset, so the rows rested 13 pt away from the
/// baseline UIKit holds for them. There are two readings of that, and one candidate fix for each:
///
/// - Leg 1, relink (H2, a skewed baseline). `apply()` used to link BEFORE it switched the pinned
///   rows to `.never`, so UIKit may have taken its baseline against the automatic inset. Leg 1
///   sets `.never` first, and once per mount, after the first focus and the first decided rest,
///   drops the link and makes it again, so the baseline is taken at a real rest.
/// - Leg 2, top-rest snap (H1, the first row resting a few points deep). `PinnedRowSettle` scrolls
///   the first row back to offset 0 as an ordinary settle correction (`topSnapApplies`).
///
/// Both legs ship OFF (Christian, 2026-10-03): leg 0 is today's behaviour, and the device session
/// (three cold launches, `-debug.tabBarRestFix 0|1|2`, two pane photos each) picks the winner,
/// which then becomes the default in a one-constant follow-up. Any value other than 1 or 2 reads
/// as 0. Not `#if DEBUG`: the device session and Steven run the same Release-shaped binary with a
/// launch argument, exactly like `TabBarStateProbe.enabled`.
///
/// Neither leg adds what the 08-27 trace banned (`docs/traces-2026-08-27-bug66-upcoming.md`): no
/// scroll-driven `.toolbarVisibility`, no `.safeAreaInset` hero, no hero-refocus completion scroll.
/// Leg 1 writes only the link UIKit already holds; leg 2 is a settle decision on a focused row,
/// never a scroll fired by a focus change.
nonisolated enum TabBarRestFix {
    static let defaultsKey = "debug.tabBarRestFix"

    /// Launch-latched, read once. 0 = today (default), 1 = relink, 2 = top-rest snap.
    static let leg: Int = resolveLeg(UserDefaults.standard)

    /// `integer(forKey:)` also converts the String "2" that `-debug.tabBarRestFix 2` lands in the
    /// argument domain. Out-of-range values fall back to 0, so a typo can never enable a leg.
    static func resolveLeg(_ defaults: UserDefaults) -> Int {
        let raw = defaults.integer(forKey: defaultsKey)
        return (1...2).contains(raw) ? raw : 0
    }

    /// Leg 1's wait before the relink: one poll every 0.25 s.
    static let pollInterval: TimeInterval = 0.25
    /// How long the relink waits for the first focus before it moves on without one. A cold launch
    /// normally lands focus on the hero within a second; this cap only keeps a launch that never
    /// gets focus (a covered Home, a sheet) from waiting forever.
    static let focusWaitCap: TimeInterval = 4
    /// The spec's 6 s ceiling on the rest wait. Reached only when the settle corrector stays busy
    /// for 6 s straight; the relink then runs anyway and says so (`reason=restTimeout`).
    static let restWaitCap: TimeInterval = 6
    /// `PinnedRowSettle.isRestPending` must read false on this many consecutive polls.
    static let quietPollsNeeded = 2

    /// Leg 1's wait, as a value type so the gate is unit-testable without a window. One `poll`
    /// per `pollInterval`: first until focus exists in the window (or `focusWaitCap` passes),
    /// then until two consecutive polls see no rest decision pending (or `restWaitCap` passes).
    /// The poll that first sees focus does not count as a rest poll: the engine's reveal scroll
    /// for that focus may not have armed a settle yet.
    nonisolated struct RelinkWait: Equatable, Sendable {
        nonisolated enum Step: Equatable, Sendable {
            case wait
            case relink(reason: String)
        }

        private(set) var focusSeen = false
        private(set) var focusTimedOut = false
        private(set) var focusWaited: TimeInterval = 0
        private(set) var restWaited: TimeInterval = 0
        private(set) var quietPolls = 0

        mutating func poll(focused: Bool, restPending: Bool, dt: TimeInterval) -> Step {
            if !focusSeen {
                focusWaited += dt
                if focused {
                    focusSeen = true
                } else if focusWaited >= TabBarRestFix.focusWaitCap {
                    focusSeen = true
                    focusTimedOut = true
                }
                return .wait
            }
            restWaited += dt
            quietPolls = restPending ? 0 : quietPolls + 1
            if quietPolls >= TabBarRestFix.quietPollsNeeded {
                return .relink(reason: focusTimedOut ? "firstRestNoFocus" : "firstRest")
            }
            if restWaited >= TabBarRestFix.restWaitCap {
                return .relink(reason: "restTimeout")
            }
            return .wait
        }
    }
}

/// Zero-sized view mounted in the BACKGROUND of Home's rows `LazyVStack` (see
/// `HomeView.rowsScroll`), so its `UIView` lives inside the rows `UIScrollView` and a `superview`
/// walk finds exactly that scroll view. Mounted unconditionally; the knob is read inside.
struct TabBarContentScrollLinkAttacher: UIViewRepresentable {
    /// The pinned hero container (a per-call-site constant, `settleReveal`), never the header's
    /// load boundary. Only the pinned container gets `contentInsetAdjustmentBehavior = .never`.
    let pinnedContainer: Bool

    func makeUIView(context: Context) -> LinkView {
        let view = LinkView()
        view.pinnedContainer = pinnedContainer
        view.isUserInteractionEnabled = false
        return view
    }

    /// Fires on the header-mount flip (the rows' environment changes), which is exactly when the
    /// geometry UIKit's heuristic was guessing against changes.
    func updateUIView(_ uiView: LinkView, context: Context) {
        uiView.pinnedContainer = pinnedContainer
        uiView.apply()
    }

    static func dismantleUIView(_ uiView: LinkView, coordinator: ()) {
        uiView.tearDown()
    }

    final class LinkView: UIView {
        var pinnedContainer = false
        private weak var linkedScrollView: UIScrollView?
        /// Every controller the link was written on, nearest first. Weak boxes so a torn-down
        /// controller never stays alive through this view.
        private var linkedControllers: [WeakController] = []
        private var focusObserver: NSObjectProtocol?
        private var loggedLink = false
        private var loggedFailure = false
        /// T1 leg 1: the one wait-then-relink task of this mount, and whether it has run. A task
        /// cancelled because the view left the window before it ran is restarted on the next
        /// `didMoveToWindow`; once the relink has run (or been skipped at its moment), never again.
        private var relinkTask: Task<Void, Never>?
        private var relinkDone = false

        private struct WeakController {
            weak var controller: UIViewController?
        }

        /// review r2 (P2-A): Home's rows view leaves the window on a push (See All, folder, person
        /// pages) and on a tab switch. If SwiftUI hosts the tab in its own hosting controller above
        /// the navigation controller, that controller is the tab bar's selected controller and
        /// would keep reporting Home's off-window rows to pushed pages (a hosting controller does
        /// not forward to its child the way navigation and tab containers do). So the link is
        /// withdrawn the moment the view leaves the window: every linked controller that still
        /// reports this scroll view gets `nil` back, and the pushed page falls back to UIKit's own
        /// heuristic. On return, `didMoveToWindow`, the retry ladder and the focus observer re-link.
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            // T1 leg 1: a wait that has not relinked yet stops here; `didMoveToWindow` restarts it.
            if newWindow == nil {
                relinkTask?.cancel()
                relinkTask = nil
            }
            guard newWindow == nil, let linked = linkedScrollView else { return }
            for entry in linkedControllers {
                guard let controller = entry.controller,
                      controller.contentScrollView(for: .top) === linked else { continue }
                controller.setContentScrollView(nil, for: .top)
            }
            if TabBarContentScrollLink.enabled, !linkedControllers.isEmpty {
                NSLog("[TabBarLink] unlinked (left window) controllers=%ld", linkedControllers.count)
            }
            linkedControllers = []
            linkedScrollView = nil
            if TabBarContentScrollLink.homeRowsScrollView === linked {
                TabBarContentScrollLink.homeRowsScrollView = nil
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            guard TabBarContentScrollLink.enabled else { return }
            apply()
            // Same defensive shape as `HiddenTabBarFocusBlocker.BlockerView`:
            // `didMoveToWindow` can land before the hosting controller is parented, so retry on the
            // next turn and on a short ladder.
            DispatchQueue.main.async { [weak self] in self?.apply() }
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            }
            // A tab switch or a pop can make UIKit re-run its scroll-view search; re-assert on every
            // focus move. The identity guard at the top of `apply()` makes this a no-op when the
            // link already holds.
            if focusObserver == nil {
                focusObserver = NotificationCenter.default.addObserver(
                    forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    self?.apply()
                }
            }
            startRelinkWaitIfNeeded()
        }

        deinit {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
            relinkTask?.cancel()
        }

        func tearDown() {
            relinkTask?.cancel()
            relinkTask = nil
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
                self.focusObserver = nil
            }
            if let linked = linkedScrollView, TabBarContentScrollLink.homeRowsScrollView === linked {
                TabBarContentScrollLink.homeRowsScrollView = nil
            }
        }

        /// Idempotent. Cheap when the link already holds: one superview walk plus a few identity
        /// reads, and no writes.
        func apply() {
            guard TabBarContentScrollLink.enabled, !NavigationChrome.isRail() else { return }
            guard window != nil, let scrollView = enclosingScrollView() else { return }

            // Identity guard: same scroll view, and every controller still reports it.
            if scrollView === linkedScrollView, !linkedControllers.isEmpty,
               linkedControllers.allSatisfy({ $0.controller?.contentScrollView(for: .top) === scrollView }),
               !pinnedContainer || scrollView.contentInsetAdjustmentBehavior == .never {
                TabBarContentScrollLink.homeRowsScrollView = scrollView
                return
            }

            let (chain, tabController) = controllerChain()
            guard !chain.isEmpty else {
                if !loggedFailure {
                    loggedFailure = true
                    NSLog("[TabBarLink] no view controller below the tab controller (nearest=%@) — link not made",
                          String(describing: nearestController().map { type(of: $0) }))
                }
                return
            }
            // review r1 (P2-1): navigation controllers are skipped (see `linkTargets`).
            let targets = TabBarContentScrollLink.linkTargets(in: chain)
            guard !targets.isEmpty else { return }
            if TabBarRestFix.leg == 1 {
                // T1 leg 1 (Steven beta.19-rc1 verdict, 2026-10-03): `.never` FIRST, so the link is
                // made against the inset the pinned rows will keep. Linking first and changing the
                // inset after is the skewed-baseline hypothesis (H2) this leg tests.
                if pinnedContainer, scrollView.contentInsetAdjustmentBehavior != .never {
                    scrollView.contentInsetAdjustmentBehavior = .never
                }
                for vc in targets where vc.contentScrollView(for: .top) !== scrollView {
                    vc.setContentScrollView(scrollView, for: .top)
                }
            } else {
                // Legs 0 and 2: today's order, unchanged.
                for vc in targets where vc.contentScrollView(for: .top) !== scrollView {
                    vc.setContentScrollView(scrollView, for: .top)
                }
                if pinnedContainer, scrollView.contentInsetAdjustmentBehavior != .never {
                    scrollView.contentInsetAdjustmentBehavior = .never
                }
            }
            linkedScrollView = scrollView
            linkedControllers = targets.map { WeakController(controller: $0) }
            TabBarContentScrollLink.homeRowsScrollView = scrollView

            if !loggedLink {
                loggedLink = true
                // review r1 (P2-1): full chain, skipped navigation controllers marked.
                let chainDesc = chain.map {
                    String(describing: type(of: $0)) + ($0 is UINavigationController ? "(skip)" : "")
                }.joined(separator: " > ")
                let observed = targets.last.flatMap { $0.tabBarObservedScrollView }
                NSLog("[TabBarLink] linked chain=%@ tab=%@ sv=%@ svh=%ld pinned=%ld legacyObserved=%@ adjBottom=%ld adjTop=%ld restFix=%ld",
                      chainDesc,
                      tabController.map { String(describing: type(of: $0)) } ?? "none",
                      String(describing: type(of: scrollView)),
                      Int(scrollView.bounds.height.rounded()),
                      pinnedContainer ? 1 : 0,
                      observed.map { $0 === scrollView ? "rows" : String(describing: type(of: $0)) } ?? "nil",
                      // review r1 (P3-8): `.never` applies to all edges; if SwiftUI had been
                      // adjusting the bottom inset the last-row floor would move.
                      Int(scrollView.adjustedContentInset.bottom.rounded()),
                      Int(scrollView.adjustedContentInset.top.rounded()),
                      // T1: which leg this launch runs, so a console capture names it.
                      TabBarRestFix.leg)
                TabBarStateProbe.noteAttached()
            }
        }

        /// T1 leg 1 (Steven beta.19-rc1 verdict, 2026-10-03): once per mount, wait for the first
        /// focus and the first decided rest (`TabBarRestFix.RelinkWait`), then relink. Polling
        /// rather than awaiting `UIFocusSystem.didUpdateNotification`: at a cold launch the initial
        /// focus can land before this view reaches the window, and a notification wait would then
        /// sit until the user's first press, after the hero photo the device session takes.
        /// `focusedItem != nil` is the same fact ("the first focus update has happened") either
        /// way. No state is written per poll beyond the task's own local value.
        private func startRelinkWaitIfNeeded() {
            guard TabBarRestFix.leg == 1, !relinkDone, relinkTask == nil else { return }
            relinkTask = Task { [weak self] in
                var gate = TabBarRestFix.RelinkWait()
                while true {
                    try? await Task.sleep(for: .seconds(TabBarRestFix.pollInterval))
                    guard !Task.isCancelled, let self else { return }
                    let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem != nil
                    let step = gate.poll(focused: focused,
                                         restPending: PinnedRowSettle.isRestPending,
                                         dt: TabBarRestFix.pollInterval)
                    if case .relink(let reason) = step {
                        self.relinkTask = nil
                        self.relink(reason: reason)
                        return
                    }
                }
            }
        }

        /// T1 leg 1: drop the link on every controller that still reports this scroll view, then
        /// make it again on the next main-queue turn, so UIKit re-reads the scroll view at a rest
        /// instead of keeping whatever it read at the first link. A focus move between the two
        /// halves can re-link early through `apply()`; the second half then writes the same link
        /// again, which is harmless.
        private func relink(reason: String) {
            relinkDone = true
            guard TabBarContentScrollLink.enabled, !NavigationChrome.isRail(), window != nil,
                  let linked = linkedScrollView else {
                NSLog("[TabBarLink] relink skipped reason=%@ (no live link)", reason)
                return
            }
            let controllers = linkedControllers.compactMap(\.controller)
                .filter { $0.contentScrollView(for: .top) === linked }
            guard !controllers.isEmpty else {
                NSLog("[TabBarLink] relink skipped reason=%@ (no controller reports the rows)", reason)
                return
            }
            for vc in controllers { vc.setContentScrollView(nil, for: .top) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.linkedScrollView === linked else {
                    NSLog("[TabBarLink] relink abandoned reason=%@ (the view left or the link moved)", reason)
                    return
                }
                for entry in self.linkedControllers {
                    entry.controller?.setContentScrollView(linked, for: .top)
                }
                NSLog("[TabBarLink] relinked reason=%@ off=%ld ins=%ld controllers=%ld",
                      reason,
                      Int(linked.contentOffset.y.rounded()),
                      Int(linked.adjustedContentInset.top.rounded()),
                      self.linkedControllers.count)
                TabBarStateProbe.noteRelinked()
            }
        }

        /// The first `UIScrollView` ancestor. Structurally the VERTICAL rows scroll view: this view
        /// is mounted in the background of the rows `LazyVStack`, outside every horizontal shelf.
        private func enclosingScrollView() -> UIScrollView? {
            var node = superview
            while let current = node {
                if let scroll = current as? UIScrollView { return scroll }
                node = current.superview
            }
            return nil
        }

        private func nearestController() -> UIViewController? {
            var responder: UIResponder? = next
            while let current = responder {
                if let vc = current as? UIViewController { return vc }
                responder = current.next
            }
            return nil
        }

        /// The nearest controller and every `parent` above it, up to but EXCLUDING the first
        /// `UITabBarController`. Setting the whole chain removes the guess about which level UIKit
        /// reads (the tab's top-level controller is the documented one).
        private func controllerChain() -> ([UIViewController], UITabBarController?) {
            var chain: [UIViewController] = []
            var node = nearestController()
            while let vc = node {
                if let tab = vc as? UITabBarController { return (chain, tab) }
                chain.append(vc)
                node = vc.parent
            }
            return (chain, nil)
        }
    }
}
