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

/// S1 W2: stops a redirect loop without blocking the next Menu.
///
/// When a reveal can't take focus and resets focus out of the hidden bar, that reset can land
/// straight back in the bar and fire the redirect again (review r1 P3-3). Only a FAILED rescue
/// suppresses the redirect, for `window` seconds; a successful one never does, so a second Menu
/// soon after a first opens the sidebar again (review r2 P2-1: stamping every redirect stranded
/// that Menu on the hidden bar).
struct StrandedRescueGuard {
    static let window: TimeInterval = 1.5
    private var lastFailure: TimeInterval = -.greatestFiniteMagnitude

    /// Whether a landing in the hidden bar at `now` may reveal the sidebar.
    func allowsReveal(now: TimeInterval) -> Bool {
        now - lastFailure > Self.window
    }

    /// A reveal could not take focus and left it in the hidden bar.
    mutating func rescueFailed(now: TimeInterval) {
        lastFailure = now
    }
}

/// S1 W2: when the sidebar's post-select hand-off re-runs default focus placement, in seconds
/// after it starts. The panel re-arms at the last check if focus is still nowhere. While nothing
/// holds focus a press can fall through to the system (the BUG-47 dead end), so the ladder stays
/// short (review r3 P3-3) except on Search: its system keyboard arrives 1–2 s after the tab opens
/// and its page can have nothing focusable until then, so a 1.0 s give-up re-armed the panel over
/// a Search page that was about to take focus (r2 gate, test93).
enum SidebarHandOffLadder {
    static let standard: [TimeInterval] = [0.35, 1.0]
    static let search: [TimeInterval] = [0.35, 1.0, 1.75, 2.5]

    /// The checks for the tab the hand-off is going to, by its `SidebarItem.title`.
    static func checks(forTabTitled title: String?) -> [TimeInterval] {
        title == "Search" ? search : standard
    }
}
