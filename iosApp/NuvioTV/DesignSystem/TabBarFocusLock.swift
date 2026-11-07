import SwiftUI
import UIKit

/// Add-ons hub v2 (A4): makes the system tab bar unfocusable while `active`, in Tabs mode only.
///
/// The Installed pane's Move mode turns Up/Down into "move this add-on": the other rows and the
/// sidebar are disabled, so the focus engine has no target and the press reaches `onMoveCommand`.
/// In Tabs mode the visible tab bar is still a target above everything, so an Up press would leave
/// the moving row for the bar. This zero-size representable clears `isUserInteractionEnabled` on the
/// shell's `UITabBar` while active (UIKit's focus rules: interaction disabled ⇒ never focusable,
/// the same mechanism as `HiddenTabBarFocusBlocker`) and restores it when inactive or dismantled.
///
/// Rail mode never touches the bar here: the rail's `HiddenTabBarFocusBlocker` already keeps it
/// unfocusable, and restoring it from here would undo that.
struct TabBarFocusLock: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> LockView { LockView() }

    func updateUIView(_ view: LockView, context: Context) {
        view.setLocked(active && !NavigationChrome.isRail())
    }

    static func dismantleUIView(_ view: LockView, coordinator: ()) {
        view.setLocked(false)
    }

    final class LockView: UIView {
        /// The bar this view disabled, so only that bar is restored.
        private weak var lockedBar: UITabBar?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// The wanted state, re-applied once the view has a window (the first update can run
        /// before it is attached, when no tab bar can be found yet).
        private var wantsLock = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { apply() }
        }

        func setLocked(_ locked: Bool) {
            wantsLock = locked
            apply()
        }

        private func apply() {
            if wantsLock {
                guard lockedBar == nil, let bar = findTabBar(), bar.isUserInteractionEnabled else { return }
                bar.isUserInteractionEnabled = false
                lockedBar = bar
            } else if let bar = lockedBar {
                bar.isUserInteractionEnabled = true
                lockedBar = nil
            }
        }

        private func findTabBar() -> UITabBar? {
            guard let root = window?.rootViewController else { return nil }
            return Self.findTabBarController(from: root)?.tabBar
        }

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
