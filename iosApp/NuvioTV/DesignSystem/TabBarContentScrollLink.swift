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

        private struct WeakController {
            weak var controller: UIViewController?
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            guard TabBarContentScrollLink.enabled else { return }
            apply()
            // Same defensive shape as `SidebarOverlay.HiddenTabBarFocusBlocker.BlockerView`:
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
        }

        deinit {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        func tearDown() {
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
            guard TabBarContentScrollLink.enabled, !SidebarChrome.isEnabled() else { return }
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
            for vc in targets where vc.contentScrollView(for: .top) !== scrollView {
                vc.setContentScrollView(scrollView, for: .top)
            }
            if pinnedContainer, scrollView.contentInsetAdjustmentBehavior != .never {
                scrollView.contentInsetAdjustmentBehavior = .never
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
                NSLog("[TabBarLink] linked chain=%@ tab=%@ sv=%@ svh=%ld pinned=%ld legacyObserved=%@ adjBottom=%ld adjTop=%ld",
                      chainDesc,
                      tabController.map { String(describing: type(of: $0)) } ?? "none",
                      String(describing: type(of: scrollView)),
                      Int(scrollView.bounds.height.rounded()),
                      pinnedContainer ? 1 : 0,
                      observed.map { $0 === scrollView ? "rows" : String(describing: type(of: $0)) } ?? "nil",
                      // review r1 (P3-8): `.never` applies to all edges; if SwiftUI had been
                      // adjusting the bottom inset the last-row floor would move.
                      Int(scrollView.adjustedContentInset.bottom.rounded()),
                      Int(scrollView.adjustedContentInset.top.rounded()))
                TabBarStateProbe.noteAttached()
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
