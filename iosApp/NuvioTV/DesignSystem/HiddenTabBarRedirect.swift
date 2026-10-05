import Foundation

/// S1 W2 (2026-10-04): what Sidebar mode does when focus lands on the HIDDEN system tab bar.
///
/// `HiddenTabBarFocusBlocker` disables interaction on the hidden bar, which keeps the focus engine's
/// own moves out of it, but tvOS's system search field (`.searchable`, Search since S1) moves focus
/// there itself: Menu from its keyboard focused a `UITabBarButton` 62 ms after the press with the
/// blocker on (S1 Wave 0, Living Room Apple TV), focus then sat on an invisible button, Right did
/// nothing, and a second Menu suspended the app. A consuming Menu recognizer on the window can't
/// win against the search container; redirecting the landing can. So: focus that lands in the
/// hidden bar opens the sidebar, which takes focus onto its row (Wave 0 run 4b).
///
/// The redirect only fires on a landing that would otherwise strand focus; ordinary moves never
/// reach the hidden bar while the blocker holds, so this is not an "any Up reveals" path (BUG-98).
enum HiddenTabBarRedirect {
    /// Whether a focus landing should open the sidebar.
    /// - Parameters:
    ///   - landedInHiddenBar: the next focused item is inside the hidden system tab bar.
    ///   - sidebarMode: Sidebar navigation is on (the bar is only hidden in that mode).
    ///   - sidebarHoldsFocus: the sidebar already has focus (nothing to redirect).
    static func shouldReveal(landedInHiddenBar: Bool, sidebarMode: Bool, sidebarHoldsFocus: Bool) -> Bool {
        landedInHiddenBar && sidebarMode && !sidebarHoldsFocus
    }
}
