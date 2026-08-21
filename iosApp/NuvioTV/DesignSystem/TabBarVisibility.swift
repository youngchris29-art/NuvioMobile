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

    /// Called from the same screen's `.onDisappear`. An unmatched call (shouldn't happen, but
    /// SwiftUI view lifecycle edge cases are never fully guaranteed) is a full no-op: the early
    /// return both keeps the depth from going negative (which would take two pops to recover) and
    /// keeps the probe from logging a push/pop cycle that never occurred — the cycle counter
    /// exists to diagnose BUG-66, so a phantom count is worse than none (Codex beta.14 r4).
    func popImmersive() {
        guard detailDepth > 0 else { return }
        detailDepth -= 1
        TabBarProbe.recordPop(depthAfter: detailDepth)
    }

    /// BUG-30/66/62 diagnostics only — read-only surface of the depth `immersiveHidden` is
    /// computed from, for the About pane's live tab-bar readout.
    var immersiveDepth: Int { detailDepth }

    /// FEAT-25 (device pass 2026-08-21): whether the HOME tab's root content is the frontmost
    /// surface — false while another tab is selected or an immersive screen is pushed over it.
    /// Exists because neither event fires `onDisappear` on Home's subtree (each tab keeps its
    /// NavigationStack alive across a switch, and a push keeps the stack root mounted), so the
    /// hero's autoplaying trailer kept making sound under Detail pages and in Settings. Published
    /// so `HomeHeroBackdrop` can subscribe imperatively (`onReceive`) — the covered subtree is
    /// still hierarchy-resident (that's the bug) but may not re-render while hidden, so a
    /// render-driven gate could defer teardown exactly when it matters.
    @Published private(set) var homeSurfaceCovered = false

    private var homeTabSelected = true {
        didSet { recomputeHomeCovered() }
    }

    /// MainTabView reports selection changes here (Home is tab value 0).
    func setHomeTabSelected(_ selected: Bool) {
        guard homeTabSelected != selected else { return }
        homeTabSelected = selected
    }

    private func recomputeHomeCovered() {
        let covered = !homeTabSelected || detailDepth > 0
        if homeSurfaceCovered != covered { homeSurfaceCovered = covered }
    }

    private func recompute() {
        hidden = scrolledAway || detailDepth > 0
        recomputeHomeCovered()
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
    /// BUG-30/66/62: which tab root this is, for the About-pane diagnostics readout.
    let tab: String
    /// Optional mirror of `hidesBar` for the attaching screen's own use (BUG-27: Home keys its
    /// Menu-to-top shortcut off the same hysteresis the bar uses, so the two never disagree).
    var isScrolledDown: Binding<Bool>?

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self, of: { geo in
            geo.contentOffset.y - geo.contentInsets.top
        }, action: { _, offset in
            TabBarProbe.recordScrollFire(tab: tab, offset: offset)
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
    /// should not attach this. `tab` names the tab root for the BUG-30/66/62 diagnostics readout
    /// (e.g. "Home", "Search"). Pass `isScrolledDown` to also receive the same hysteresis-filtered
    /// signal locally (crossings only, never per scroll tick).
    func reportsScrollToTabBar(tab: String, isScrolledDown: Binding<Bool>? = nil) -> some View {
        modifier(TabBarScrollAutoHide(tab: tab, isScrolledDown: isScrolledDown))
    }
}

/// BUG-30/66/62 (beta.14): release-safe diagnostics for the tvOS 26 system tab bar's scroll-edge
/// state. Same house pattern as `HomeHeroProbe` (deliberately not `#if DEBUG` — this bar has only
/// ever been seen stuck on a device pass, never in sim) but the readout is a live counter
/// snapshot rather than an event log: `.onScrollGeometryChange` can fire many times a second while
/// scrolling, and a line per fire would spam both the console and whatever ring buffer held it.
/// Everything here is in-memory only for the running process — the BUG-30/66 protocol (walk Home
/// down/up, then run Detail push/pop cycles, then check Settings → About) never spans a
/// relaunch — so nothing here touches UserDefaults or feeds back into the bar's own state.
@MainActor
enum TabBarProbe {
    /// Live read, not the other probes' latched `static let`: those pair with a relaunch-based
    /// capture protocol, while this toggle must take effect in the same session it is flipped in.
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.tabBarProbe") }

    /// Stable display order for the About pane — dictionary iteration order isn't.
    static let tabNames = ["Home", "Search", "Library", "Add-ons"]

    struct ScrollState {
        var fireCount = 0
        var lastFireMs = 0
        var lastOffset: CGFloat = 0
    }

    private(set) static var scrollStates: [String: ScrollState] = [:]
    /// Counts full push→pop round trips (depth back to 0), not raw push/pop calls — the BUG-30/66
    /// hypothesis is stated in terms of "N push/pop cycles", not a raw event tally.
    private(set) static var pushPopCycles = 0

    static func recordScrollFire(tab: String, offset: CGFloat) {
        guard enabled else { return }
        var state = scrollStates[tab, default: ScrollState()]
        state.fireCount += 1
        state.lastFireMs = HomeHeroProbe.sinceLaunchMs
        state.lastOffset = offset
        scrollStates[tab] = state
    }

    static func recordPop(depthAfter: Int) {
        guard enabled, depthAfter == 0 else { return }
        pushPopCycles += 1
    }
}
