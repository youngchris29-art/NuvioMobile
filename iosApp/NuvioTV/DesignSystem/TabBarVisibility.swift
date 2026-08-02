import Combine
import SwiftUI

/// Shared visibility state for the floating glass tab bar, combining two independent signals:
///
///   - `scrolledAway`: the currently-selected tab's root content has scrolled far enough down that
///     the bar should get out of the way. Tab roots report this from their main `ScrollView` via
///     `setScrolled(_:)`, applying hysteresis at the call site (hide past one threshold, show back
///     below a lower one) so the bar doesn't flicker right at the boundary.
///   - `detailDepth`: count of "immersive" pushed screens (currently just `DetailView`) stacked on
///     top of the active tab's `NavigationStack`. A depth counter rather than a `Bool` because
///     Detail → More Like This → Detail nests — the bar should only reappear once every pushed
///     immersive screen has been popped, not after the first one.
///
/// The bar is hidden whenever either signal holds. Owned as a single `@StateObject` in
/// `MainTabView` and read/written by descendants via `@Environment(\.tabBarVisibility)` — a custom
/// environment key (not `@EnvironmentObject`) so views that can be presented *outside* the tab
/// shell (e.g. `DetailView` reached through `DeepLinkTitleView`'s own standalone `NavigationStack`,
/// pushed from a Top Shelf deep link with no tab bar in play at all) fall back to a harmless
/// unconnected default instance instead of crashing for a missing environment object.
@MainActor
final class TabBarVisibility: ObservableObject {
    @Published private(set) var hidden: Bool = false

    private var scrolledAway = false {
        didSet { recompute() }
    }
    private var detailDepth = 0 {
        didSet { recompute() }
    }

    /// Tab roots call this from their main scroll view's geometry-change hysteresis (see each
    /// screen's `.onScrollGeometryChange`), not on every scroll tick — only when crossing a
    /// hide/show threshold.
    func setScrolled(_ scrolled: Bool) {
        guard scrolledAway != scrolled else { return }
        scrolledAway = scrolled
    }

    /// Called from an immersive pushed screen's `.onAppear` (currently `DetailView`).
    func pushImmersive() {
        detailDepth += 1
    }

    /// Called from the same screen's `.onDisappear`. Clamped at 0 so an unmatched call (shouldn't
    /// happen, but SwiftUI view lifecycle edge cases are never fully guaranteed) can't go negative
    /// and require two pops to recover.
    func popImmersive() {
        detailDepth = max(0, detailDepth - 1)
    }

    private func recompute() {
        hidden = scrolledAway || detailDepth > 0
    }

    /// Device pass round 4 (2026-08-02): the toolbar drives off THIS, not `hidden`. Toggling
    /// `.toolbarVisibility(.hidden)` on scroll and re-showing it later left the system bar
    /// frozen mid-slide on real hardware — clipped at the top until focus moved within it —
    /// through three rounds of transition fixes (.automatic→.visible, dropping the custom
    /// animation). The cure is structural: never toggle visibility for scrolling at all; the
    /// tvOS 26 system bar already minimizes/expands natively as content scrolls (`.automatic`),
    /// so there is no hidden→shown transition left to get stuck. Only the immersive detail
    /// push still force-hides. `hidden`/`scrolledAway` remain for the BUG-27 Menu-to-top
    /// hysteresis, which is unrelated to bar presentation.
    var immersiveHidden: Bool { detailDepth > 0 }
}

private struct TabBarVisibilityKey: EnvironmentKey {
    static let defaultValue = TabBarVisibility()
}

extension EnvironmentValues {
    var tabBarVisibility: TabBarVisibility {
        get { self[TabBarVisibilityKey.self] }
        set { self[TabBarVisibilityKey.self] = newValue }
    }
}

/// Reports a tab root's main scroll view position to the shared `TabBarVisibility`, with
/// hysteresis so the bar doesn't flicker right at one boundary: hide once scrolled comfortably
/// past the top (> 60pt), only show again once scrolled almost all the way back (< 8pt). `hidesBar`
/// mirrors the last state actually reported, so `setScrolled` is only called on a real crossing —
/// not once per scroll tick.
private struct TabBarScrollAutoHide: ViewModifier {
    @Environment(\.tabBarVisibility) private var tabBarVisibility
    @State private var hidesBar = false
    /// Optional mirror of `hidesBar` for the attaching screen's own use (BUG-27: Home keys its
    /// Menu-to-top shortcut off the same hysteresis the bar uses, so the two never disagree).
    var isScrolledDown: Binding<Bool>?

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self, of: { geo in
            geo.contentOffset.y - geo.contentInsets.top
        }, action: { _, offset in
            if !hidesBar, offset > 60 {
                hidesBar = true
                tabBarVisibility.setScrolled(true)
                isScrolledDown?.wrappedValue = true
            } else if hidesBar, offset < 8 {
                hidesBar = false
                tabBarVisibility.setScrolled(false)
                isScrolledDown?.wrappedValue = false
            }
        })
    }
}

extension View {
    /// Attach to a tab root's main (vertical) `ScrollView` so its position drives the floating tab
    /// bar's scroll-driven auto-hide. Screens that don't meaningfully scroll (Settings, Profile)
    /// should not attach this. Pass `isScrolledDown` to also receive the same hysteresis-filtered
    /// signal locally (crossings only, never per scroll tick).
    func reportsScrollToTabBar(isScrolledDown: Binding<Bool>? = nil) -> some View {
        modifier(TabBarScrollAutoHide(isScrolledDown: isScrolledDown))
    }
}
