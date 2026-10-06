import Foundation

/// Search & Discover batch 2026-10-06 (B4): whether the focused item sits inside tvOS's system
/// search keyboard, judged from the class names of the focused item's view chain (the item, then
/// its superviews up to the window).
///
/// The S1 spike kit (`docs/research/search-field-spike-2026-10-04/README.md`) names the keyboard
/// views on tvOS 27.2: `UIKeyboard` (the Grid keyboard) and the search controller's band
/// `_UISearchControllerTVKeyboardContainerView` (Linear and Grid). The match is deliberately loose
/// so a renamed private class still counts: any name containing "Keyboard", or starting with
/// "UIKB" (UIKit's keyboard internals, `UIKBKeyView` and friends). Generic parameters are ignored
/// (`_UIHostingView<…SomeKeyboardThing…>` is the app's SwiftUI content, not the system keyboard).
///
/// Fails CLOSED: an empty or unrecognised chain is "not the keyboard", so an unknown build never
/// hides the rail. In DEBUG `HiddenTabBarFocusBlocker` logs the real chain on every change as
/// `[KBFocus] chain=<A>→<B>→…` so a simulator or device walk can confirm the names.
nonisolated enum SystemKeyboardFocus {
    static func isKeyboard(classChain: [String]) -> Bool {
        classChain.contains { isKeyboardClass($0) }
    }

    static func isKeyboardClass(_ name: String) -> Bool {
        let base = name.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("Keyboard") || trimmed.hasPrefix("UIKB")
    }
}
