import SwiftUI
import UIKit

// MARK: - Hidden tab bar focus blocker

/// In Rail mode (FEAT-30's Sidebar mode before it) the system tab bar is hidden with
/// `.toolbarVisibility(.hidden, for: .tabBar)`, but hidden is not the same as unfocusable: on the
/// FA87 sim (test52, 2026-09-05) and on the Living Room ATV (Phase 0 spike, "Up from Play did
/// nothing") an Up press from the hero still moved focus INTO the invisible bar — no accessible
/// element reported focus afterwards, further presses went nowhere, and a later Select switched
/// tabs from that unseen bar. The focus engine consumes the press, so no `onMoveCommand` reaches
/// anything either.
///
/// SwiftUI's tvOS `TabView` is UIKit-backed, so this representable — mounted only in Rail mode,
/// zero-sized, inside the rail overlay — walks the window's controller tree to the
/// `UITabBarController` and clears `isUserInteractionEnabled` on its `tabBar`. Per UIKit's focus
/// rules a view with user interaction disabled is never focusable (see the tvOS skill's UIKit
/// notes: hidden / alpha 0 / interaction disabled / not in hierarchy all disqualify), while the
/// bar's layout contribution — already nil while hidden — is untouched. Re-applied on every
/// SwiftUI update of this view and on a short retry ladder after attaching, because the tab bar
/// controller can be created after this view first lands in the window. Logs what it found once,
/// so a build where the backing controller is not a `UITabBarController` says so instead of
/// silently doing nothing. Tabs mode never mounts it.
///
/// Home Stage & Strip (H9, P4 §2.3): moved here verbatim from the retired `SidebarOverlay.swift`,
/// plus the rail's content gate (`setContentGated`), the failed-move origin check
/// (`focusItemIsInTabContent`) and the presented-cover check (`isPresentedOverShell`).
struct HiddenTabBarFocusBlocker: UIViewRepresentable {
    /// S1 W2: called when focus lands inside the hidden bar anyway (tvOS's system search field
    /// moves it there on Menu; see `HiddenTabBarRedirect`). The rail opens and takes focus.
    var onFocusLandedInHiddenBar: () -> Void = {}

    /// Search & Discover B4: called with `true` when focus enters tvOS's system search keyboard and
    /// `false` when it leaves (only on a change). Judged by `SystemKeyboardFocus` over the focused
    /// item's view-class chain; fails closed (unknown → false).
    var onKeyboardFocusChanged: ((Bool) -> Void)? = nil

    /// True once a backing `UITabBar` has had interaction disabled. Read by the rail's hand-off:
    /// default focus placement is only safe when the invisible bar cannot be its first candidate
    /// (internal review r3 P1-2b).
    nonisolated(unsafe) private(set) static var isBlocking = false
    /// The live blocker view, for `focusedItemIsNil()` (it has a window, hence a focus system).
    nonisolated(unsafe) private static weak var current: BlockerView?

    /// Whether the window's focus system currently has NO focused item (the BUG-47 dead end).
    /// `false` when unknown (no window yet) so callers do not react to a missing probe.
    static func focusedItemIsNil() -> Bool {
        guard let view = current, let window = view.window,
              let system = UIFocusSystem.focusSystem(for: window) else { return false }
        return system.focusedItem == nil
    }

    /// Whether focus sits inside the hidden bar this blocker disabled (S1 W2): the stranded state
    /// tvOS's system search field leaves behind on Menu.
    static func focusedItemIsInHiddenBar() -> Bool {
        guard let view = current, let window = view.window,
              let system = UIFocusSystem.focusSystem(for: window) else { return false }
        return view.isInBlockedBar(system.focusedItem)
    }

    /// The window's focused item right now (nil when unknown). The rail's arming check falls back to
    /// it when a failed move's context carries no `previouslyFocusedItem`.
    static func currentFocusedItem() -> UIFocusItem? {
        guard let view = current, let window = view.window,
              let system = UIFocusSystem.focusSystem(for: window) else { return nil }
        return system.focusedItem
    }

    /// H9 R3 (W3 Rail08 / Probe I, 2026-10-05): Always Visible's reserved width, as UIKit safe area
    /// on the shell's tab controller (`additionalSafeAreaInsets.left`). SwiftUI's `.safeAreaPadding`
    /// at a tab root never reached past the tab's NavigationStack or into `.searchable`'s container
    /// (both UIKit-hosted): Classic Home, Library, Settings and pushed pages kept content at 140 pt
    /// while `\.rowEdgeMargins` said 176. UIKit propagates this inset to every hosted page and to the
    /// search container. Full-bleed backgrounds still reach x = 0 (they ignore the safe area), and
    /// Stage and the folder Rows page ignore it by design and read `\.railLeadingInset` instead.
    /// 0 outside Always Visible. Applied whenever the blocker finds the tab controller.
    /// `animated` (B4): the search keyboard's collapse and restore slide the content with
    /// `UIView.animate(withDuration: 0.25)`; mode and visibility changes stay instant.
    static func setReservedLeadingInset(_ inset: CGFloat, animated: Bool = false) {
        reservedLeadingInset = inset
        #if DEBUG
        // A/B knob for the UI legs: the environment half (`\.railLeadingInset`) stays on.
        if UserDefaults.standard.bool(forKey: "debug.railShellInsetOff") { reservedLeadingInset = 0 }
        #endif
        current?.applyReservedInset(animated: animated)
    }

    nonisolated(unsafe) private static var reservedLeadingInset: CGFloat = 0

    /// P4 §2.3: the rail's content gate. Closed (`gated == true`) while a rail item holds focus, so
    /// the engine can neither leak out of the overlay into content (Down past the bottom item, Right
    /// to an off-screen card whose frame overlaps the rail's beam) nor reach the Grid keyboard, a
    /// geometric neighbour of the centred rail. Returns whether a view was actually gated/ungated
    /// (false when no tab controller has been found yet).
    @discardableResult
    static func setContentGated(_ gated: Bool) -> Bool {
        guard let view = current else {
            NSLog("[NavRail] content gate %@ skipped: no blocker in the window", gated ? "on" : "off")
            return false
        }
        return view.setContentGated(gated)
    }

    /// P4 §2.2: whether a failed move started inside a tab's content. Walks the focus environment
    /// chain up to the first `UIView` (SwiftUI focus items are not views; their chain reaches the
    /// hosting view) and answers whether that view sits under the tab controller's view and outside
    /// the hidden bar. Fails CLOSED (false) when anything is unknown, so an unexplained failure
    /// never opens the rail.
    static func focusItemIsInTabContent(_ environment: UIFocusEnvironment?) -> Bool {
        guard let blocker = current, let tabView = blocker.tabControllerView() else { return false }
        var cursor = environment
        var hops = 0
        while let node = cursor, hops < 64 {
            if let view = node as? UIView {
                return view.isDescendant(of: tabView) && !blocker.isInBlockedBar(view)
            }
            cursor = node.parentFocusEnvironment
            hops += 1
        }
        return false
    }

    /// P4 §2.2: a controller is presented over the shell (player, stream picker, trailer cover,
    /// synopsis sheet, an alert). The rail never arms then, and it is hidden behind it anyway.
    static func isPresentedOverShell() -> Bool {
        current?.window?.rootViewController?.presentedViewController != nil
    }

    func makeUIView(context: Context) -> BlockerView { BlockerView() }
    func updateUIView(_ uiView: BlockerView, context: Context) {
        uiView.onFocusLandedInHiddenBar = onFocusLandedInHiddenBar
        uiView.onKeyboardFocusChanged = onKeyboardFocusChanged
        uiView.apply()
    }
    /// Restore the bar (and open the content gate) if the overlay is ever torn down without the
    /// whole shell being remounted (internal review r3 P2-4): a Tabs-mode shell with a visible,
    /// permanently unfocusable bar and no rail would have no reachable chrome at all.
    static func dismantleUIView(_ uiView: BlockerView, coordinator: ()) {
        uiView.restore()
    }

    final class BlockerView: UIView {
        private var loggedFailure = false
        private var loggedSuccess = false
        private weak var blockedBar: UITabBar?
        /// P4 §2.3: cached alongside `blockedBar` in `apply()`.
        private weak var tabController: UITabBarController?
        /// The view the content gate disabled, so ungating re-enables exactly that view even if the
        /// selected tab changed in between.
        private weak var gatedView: UIView?
        private var focusObserver: NSObjectProtocol?
        var onFocusLandedInHiddenBar: () -> Void = {}
        var onKeyboardFocusChanged: ((Bool) -> Void)?
        /// B4: the last keyboard verdict reported, so the callback fires only on a change.
        private var keyboardFocused = false
        #if DEBUG
        private var lastLoggedChain = ""
        #endif

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            HiddenTabBarFocusBlocker.current = self
            apply()
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            }
            // Re-apply on every focus move (cheap, one notification per move): if UIKit ever
            // re-enables the bar — tab switch, trait change, a `.toolbarVisibility` re-resolution
            // (the BUG-66 class) — it is blocked again before the NEXT move command, instead of
            // whenever SwiftUI happens to re-evaluate this view (internal review r3 P2-4).
            if focusObserver == nil {
                focusObserver = NotificationCenter.default.addObserver(
                    forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
                ) { [weak self] note in
                    self?.apply()
                    self?.redirectIfLandedInBar(note)
                    self?.updateKeyboardFocus(note)
                }
            }
        }

        deinit {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        func apply() {
            // r3b P2-3: this runs on every focus update, so it must not re-walk the controller
            // tree when the cached bar is still in the window and still blocked.
            if let bar = blockedBar, bar.window != nil, !bar.isUserInteractionEnabled, tabController != nil {
                HiddenTabBarFocusBlocker.isBlocking = true
                applyReservedInset()
                return
            }
            guard let root = window?.rootViewController else { return }
            guard let tabController = Self.findTabBarController(from: root) else {
                if !loggedFailure {
                    loggedFailure = true
                    NSLog("[NavRail] no UITabBarController found under %@ — hidden bar stays focusable", String(describing: type(of: root)))
                }
                return
            }
            self.tabController = tabController
            let bar = tabController.tabBar
            blockedBar = bar
            if bar.isUserInteractionEnabled {
                bar.isUserInteractionEnabled = false
                tabController.setNeedsFocusUpdate()
            }
            HiddenTabBarFocusBlocker.isBlocking = true
            if !loggedSuccess {
                loggedSuccess = true
                NSLog("[NavRail] hidden tab bar made unfocusable (hidden=%d alpha=%.2f frame=%@)",
                      bar.isHidden ? 1 : 0, bar.alpha, NSCoder.string(for: bar.frame))
            }
            applyReservedInset()
        }

        /// See `HiddenTabBarFocusBlocker.setReservedLeadingInset`. One comparison when unchanged.
        func applyReservedInset(animated: Bool = false) {
            guard let tab = tabController else { return }
            let inset = HiddenTabBarFocusBlocker.reservedLeadingInset
            guard tab.additionalSafeAreaInsets.left != inset else { return }
            if animated, window != nil {
                UIView.animate(withDuration: 0.25) {
                    tab.additionalSafeAreaInsets.left = inset
                    tab.view.layoutIfNeeded()
                }
            } else {
                tab.additionalSafeAreaInsets.left = inset
            }
            NSLog("[NavRail] reserved leading safe area=%.0f%@", inset, animated ? " (animated)" : "")
        }

        /// B4: whether the newly focused item is inside the system search keyboard. The chain is the
        /// focus environments up to the first `UIView` (SwiftUI items are not views), then that
        /// view's superviews. Reports only a change.
        ///
        /// Review r1 P2-4: this runs on every focus move, so it is gated and cheap. It only looks
        /// while the Search tab is selected (the keyboard lives nowhere else) or while the flag is
        /// set (so a tab switch away from the keyboard still clears it). The walk names classes with
        /// `NSStringFromClass` and stops at the first keyboard class. The full chain (DEBUG
        /// `[KBFocus] chain=`) is built only when the verdict flips, or on every move with
        /// `-debug.kbFocusChain YES`.
        private func updateKeyboardFocus(_ note: Notification) {
            guard keyboardFocused || searchTabSelected else { return }
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            let item: UIFocusEnvironment? = context?.nextFocusedItem
                ?? window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
            let isKeyboard = Self.chainHasKeyboard(item)
            #if DEBUG
            if isKeyboard != keyboardFocused || Self.logsEveryChain {
                let joined = Self.classChain(of: item).joined(separator: "→")
                if joined != lastLoggedChain {
                    lastLoggedChain = joined
                    NSLog("[KBFocus] chain=%@", joined)
                }
            }
            #endif
            guard isKeyboard != keyboardFocused else { return }
            keyboardFocused = isKeyboard
            NSLog("[KBFocus] keyboard=%d", isKeyboard ? 1 : 0)
            onKeyboardFocusChanged?(isKeyboard)
        }

        /// The Search tab is the selected one. Search is always the second tab (Home · Search · …,
        /// `ContentView`), whatever the language, so the index is the test, not the title.
        private var searchTabSelected: Bool {
            guard let tab = tabController else { return false }
            return tab.selectedIndex == 1
        }

        #if DEBUG
        /// `-debug.kbFocusChain YES`: log the chain on every focus move, not only on a flip.
        private static let logsEveryChain = UserDefaults.standard.bool(forKey: "debug.kbFocusChain")
        #endif

        /// The same verdict as `SystemKeyboardFocus.isKeyboard(classChain: classChain(of: item))`,
        /// walking the same chain but stopping at the first keyboard class.
        static func chainHasKeyboard(_ item: UIFocusEnvironment?) -> Bool {
            var cursor = item
            var hops = 0
            var firstView: UIView?
            while let node = cursor, hops < 64 {
                if let view = node as? UIView { firstView = view; break }
                if isKeyboardClass(type(of: node)) { return true }
                cursor = node.parentFocusEnvironment
                hops += 1
            }
            var view = firstView
            hops = 0
            while let current = view, hops < 64 {
                if isKeyboardClass(type(of: current)) { return true }
                view = current.superview
                hops += 1
            }
            return false
        }

        /// `NSStringFromClass` (cheap) for Objective-C names; a Swift-mangled generic name (`_Tt…`)
        /// would carry its generic arguments unbracketed, so those fall back to the demangled
        /// `String(describing:)` form the classifier strips at `<`.
        private static func isKeyboardClass(_ cls: AnyClass) -> Bool {
            let name = NSStringFromClass(cls)
            return SystemKeyboardFocus.isKeyboardClass(name.hasPrefix("_Tt") ? String(describing: cls) : name)
        }

        /// The full chain, for the DEBUG log only.
        static func classChain(of item: UIFocusEnvironment?) -> [String] {
            var names: [String] = []
            var cursor = item
            var hops = 0
            var firstView: UIView?
            while let node = cursor, hops < 64 {
                if let view = node as? UIView { firstView = view; break }
                names.append(String(describing: type(of: node)))
                cursor = node.parentFocusEnvironment
                hops += 1
            }
            var view = firstView
            hops = 0
            while let current = view, hops < 64 {
                names.append(String(describing: type(of: current)))
                view = current.superview
                hops += 1
            }
            return names
        }

        /// The tab controller's view, finding the controller first if this view has not yet.
        func tabControllerView() -> UIView? {
            if tabController == nil { apply() }
            return tabController?.view
        }

        /// P4 §2.3. The rail is an overlay of the TabView, so this blocker (mounted in the rail) is
        /// normally NOT inside `tab.view` and the whole tab controller's view is gated: every tab
        /// root, every pushed page and the UIKit-hosted Search keyboard at once. If this blocker ever
        /// is inside it, gating `tab.view` would gate the rail too, so only the selected tab's view
        /// is gated then. The tab bar keeps its own disabled flag, so ungating `tab.view` never makes
        /// the hidden bar focusable again.
        func setContentGated(_ gated: Bool) -> Bool {
            if gated {
                if tabController == nil { apply() }
                guard let tab = tabController else {
                    NSLog("[NavRail] content gate on skipped: no UITabBarController yet")
                    return false
                }
                let target: UIView? = isDescendant(of: tab.view) ? tab.selectedViewController?.view : tab.view
                guard let target else { return false }
                if let previous = gatedView, previous !== target { previous.isUserInteractionEnabled = true }
                target.isUserInteractionEnabled = false
                gatedView = target
                return true
            }
            guard let view = gatedView else { return false }
            view.isUserInteractionEnabled = true
            gatedView = nil
            return true
        }

        /// S1 W2: the landing check. By hierarchy (the next item is inside the bar this view
        /// blocked), not by UIKit's private button class name.
        private func redirectIfLandedInBar(_ note: Notification) {
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                  isInBlockedBar(context.nextFocusedItem) else { return }
            onFocusLandedInHiddenBar()
        }

        /// Inside the blocked bar by hierarchy, or (review r1 P3-4) a tab-bar button by class name:
        /// the hierarchy check is proven on the 26.5 simulator, the class name on the Apple TV
        /// (S1 Wave 0 run 4b). Only ever true in Rail mode, where this blocker exists.
        func isInBlockedBar(_ item: UIFocusItem?) -> Bool {
            guard let view = item as? UIView else { return false }
            if let bar = blockedBar, view.isDescendant(of: bar) { return true }
            return String(describing: type(of: view)).contains("UITabBarButton")
        }

        func restore() {
            // Review r3 (P3-1): the bar and the reserved width only for the registered blocker. On
            // a remount (a theme, font or visibility change re-identifies the shell) both TabView
            // controllers are briefly children of the root and this blocker may hold the incoming
            // one; clearing it would drop the new shell to 140 pt until its blocker re-applied.
            // Rail → Tabs and a profile exit register no successor, so they still clear.
            if HiddenTabBarFocusBlocker.current === self {
                if let bar = blockedBar, !bar.isUserInteractionEnabled {
                    bar.isUserInteractionEnabled = true
                }
                // A torn-down rail leaves no reserved width behind.
                if let tab = tabController, tab.additionalSafeAreaInsets.left != 0 {
                    tab.additionalSafeAreaInsets.left = 0
                }
            }
            // P4 §2.3: a torn-down rail must never leave content non-interactive.
            if let view = gatedView {
                view.isUserInteractionEnabled = true
                gatedView = nil
            }
            // r3b P3-1: only the registered instance may clear the process-global flags — a
            // replaced blocker's dismantle can run AFTER its successor's attach on a remount.
            if HiddenTabBarFocusBlocker.current === self {
                HiddenTabBarFocusBlocker.current = nil
                HiddenTabBarFocusBlocker.isBlocking = false
            }
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
            focusObserver = nil
            // B4: a torn-down rail never leaves the keyboard flag set.
            // Deferred: dismantle runs inside a SwiftUI update, where a model write would publish
            // from within the update.
            if keyboardFocused {
                keyboardFocused = false
                let callback = onKeyboardFocusChanged
                DispatchQueue.main.async { callback?(false) }
            }
        }

        /// Children first, presented controllers last (internal review r3 P3-11): a presented
        /// controller that contained its own tab bar controller must never win over the shell's.
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
}
