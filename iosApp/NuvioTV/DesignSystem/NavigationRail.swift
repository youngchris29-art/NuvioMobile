import Combine
import SharedCore
import SwiftUI
import UIKit

// Home Stage & Strip (H9, FEAT-45; P4 spec): the floating pill navigation rail. It replaced FEAT-30's
// Menu-revealed Sidebar mode (`SidebarOverlay.swift`, retired) and applies to every tab.
//
//     MainTabView
//     ├─ TabView                              each Tab closure: `.railTabRoot(index)` (inset, tab index,
//     │                                       the per-tab gate fallback)
//     └─ .overlay { NavigationRail }          the pill, the dim, the hidden-bar blocker, the probe
//
// Focus graph (P4 §2; the Wave 0.5 spike's verdict is binding):
//  - At rest the pill's items are plain labels the engine cannot land on, so the rail never takes
//    launch focus. It ARMS on a Left the engine could not place from the leftmost item of a tab's
//    content (`UIFocusSystem.movementDidFailNotification`, never `.onMoveCommand`, which fires on
//    every press), on Menu at a tab root, and when focus lands on the hidden system tab bar (S1).
//    Armed, the items are native Buttons (`RailItemButtonStyle`: the white focus capsule) and the
//    rail takes focus programmatically.
//  - While a rail item holds focus, tab content is GATED unfocusable (`RailContentGate`): the rail
//    is an overlay, and the engine otherwise leaks out of it. Every exit is app-handled: Right (a
//    failed move with content gated), Select, and Menu when Left opened the rail.
//  - Restoration is SwiftUI-side: `requestFocusUpdate(to:)` on a SwiftUI item did not stick in the
//    spike and a `UIFocusGuide` lost to an off-screen row. Screens that need an exact return register
//    a `RailReturnRoute` (Home Stage and Classic, the folder Rows page, Detail, the Settings root);
//    everything else falls back to its default focus through S1's hand-off ladder.

// MARK: - Shared chrome state

/// The rail's cross-screen state: per-tab scrolled-down mirrors (Hide While Browsing), the reveal
/// request, whether the rail holds focus, the content gate, and the return routes.
///
/// Held as `@State private var navigationChrome = NavigationChromeModel()` on `MainTabView`: `@State`
/// on a reference type, NOT `@StateObject`, for exactly the reason `MainTabView.tabBarVisibility` is
/// (T3 / BUG-66): `@State` keeps the same instance without subscribing the shell to
/// `objectWillChange`. With `@StateObject`, every scroll crossing on any tab would re-evaluate all
/// six `Tab` closures, the mechanism that re-resolved `.toolbarVisibility` mid-transition and latched
/// the system tab bar mid-slide on hardware. `NavigationRail` is the ONLY view that observes it;
/// everything else holds it through `@Environment`, which does not subscribe, and the per-tab gate
/// fallback subscribes to `$contentGated` alone.
@MainActor
final class NavigationChromeModel: ObservableObject {
    /// Per-tab mirror of `TabBarScrollAutoHide`'s hysteresis latch (and of Stage's row index), keyed
    /// by tab VALUE (Home 0 … Add-ons 3). Per tab, never one shared slot: four independently
    /// scrolling tabs make a single slot last-writer-wins (T2).
    @Published var scrolledDownByTab: [Int: Bool] = [:]
    /// Bumped by every reveal request. A counter plus the reason, so two Menu presses in a row are
    /// two observable changes.
    @Published private(set) var revealRequest = RailRevealRequest(generation: 0, reason: .menu)
    /// True while a rail item holds focus. Read by the tab roots' Menu handlers and Stage's trailer
    /// gate WITHOUT observation (they hold the model through `@Environment`), so a focus change
    /// inside the rail never invalidates a tab root.
    @Published var isFocusedChrome: Bool = false
    /// True while tab content is gated unfocusable (`RailContentGate`). Usually equal to
    /// `isFocusedChrome`, except that an exit opens the gate one beat BEFORE focus leaves the rail,
    /// so the restore's focus write can land. The `perTab` gate fallback follows this.
    @Published private(set) var contentGated: Bool = false
    /// Search & Discover B4: focus is inside tvOS's system search keyboard. Written by
    /// `HiddenTabBarFocusBlocker`'s focus observer (Rail mode only); the rail hides its Always
    /// Visible pill on Search while this holds, and the Search tab root's reserved width follows.
    @Published private(set) var searchKeyboardFocused: Bool = false
    /// The motion of each tab's last real `scrolledDownByTab` change (#8). Not published: the rail
    /// reads it when the mirror it observes changes, and it is written just before that change.
    private(set) var motionByTab: [Int: RailMotion] = [:]

    /// Return routes: NOT published. A LIFO stack per tab, keyed by token, so a page pushed over
    /// Home puts its own route on top and a page with no route falls to the default.
    private var routes: [Int: [(token: UUID, route: RailReturnRoute)]] = [:]

    /// `nonisolated`: only literal defaults are assigned, and the environment key's fallback
    /// instance is a lazily initialised static (see `NavigationChromeKey`).
    nonisolated init() {}

    /// Write-on-change only (`@Published` does not dedupe). A same-value write keeps the motion of
    /// the write that actually changed the value: Stage's page write owns the rail, and the scroll
    /// mirror's later crossing to the same value is a no-op (P4 R4).
    func setScrolledDown(tab: Int, _ value: Bool, motion: RailMotion = .scroll) {
        guard scrolledDownByTab[tab] != value else { return }
        motionByTab[tab] = motion
        scrolledDownByTab[tab] = value
    }

    func requestReveal(_ reason: RailOpenReason) {
        revealRequest = RailRevealRequest(generation: revealRequest.generation &+ 1, reason: reason)
    }

    /// Add-ons hub v2 C5: bumped when a screen opened by a programmatic tab switch wants focus while
    /// the rail holds it (the switch can leave focus on the rail, which gates the content). The rail
    /// runs its normal exit to the current tab, so the tab's return route places focus.
    @Published private(set) var exitRequest: Int = 0

    func requestExitToContent() {
        exitRequest &+= 1
    }

    func setFocusedChrome(_ focused: Bool) {
        guard isFocusedChrome != focused else { return }
        isFocusedChrome = focused
    }

    /// Written only by `RailContentGate`.
    func setContentGated(_ gated: Bool) {
        guard contentGated != gated else { return }
        contentGated = gated
    }

    /// Write-on-change (B4).
    func setSearchKeyboardFocused(_ focused: Bool) {
        guard searchKeyboardFocused != focused else { return }
        searchKeyboardFocused = focused
    }

    /// Registers (or re-registers, keeping one entry per token) a screen's return route on top of
    /// its tab's stack.
    func pushReturnRoute(tab: Int, token: UUID, _ route: RailReturnRoute) {
        var stack = routes[tab] ?? []
        stack.removeAll { $0.token == token }
        stack.append((token: token, route: route))
        routes[tab] = stack
    }

    func removeReturnRoute(tab: Int, token: UUID) {
        routes[tab]?.removeAll { $0.token == token }
    }

    func topReturnRoute(tab: Int) -> RailReturnRoute? {
        routes[tab]?.last?.route
    }
}

/// Same shape as `TabBarVisibilityKey`: a custom key rather than `@EnvironmentObject`, so a screen
/// presented OUTSIDE the tab shell (a Top Shelf deep link's standalone `NavigationStack`) falls back
/// to a harmless unconnected instance instead of crashing for a missing environment object.
private struct NavigationChromeKey: EnvironmentKey {
    // The model is `@MainActor` but its `init` is `nonisolated` (literal defaults only), so the lazy
    // static can be built on whichever thread first touches it (r3b P3-2's rule).
    static let defaultValue = NavigationChromeModel()
}

/// Which tab a view lives in (`.railTabRoot` sets it; nil outside the rail and outside the shell),
/// so a pushed page registers its return route on the right tab.
private struct RailTabIndexKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var navigationChrome: NavigationChromeModel {
        get { self[NavigationChromeKey.self] }
        set { self[NavigationChromeKey.self] = newValue }
    }

    var railTabIndex: Int? {
        get { self[RailTabIndexKey.self] }
        set { self[RailTabIndexKey.self] = newValue }
    }
}

// MARK: - Return routes (P4 §2.5)

/// How a screen gets focus back when the rail exits to it. Registered with `.railReturnRoute`.
struct RailReturnRoute {
    /// For the `[NavRail] exit … route=` log line and the probe's `route=` token.
    let name: String
    /// Called when the rail arms from a Left or Menu, while focus is still on the origin.
    let capture: @MainActor () -> Void
    /// Issues a SwiftUI focus write and returns true, or returns false to take the default hand-off.
    /// The rail verifies 0.5 s later and hands off by default if focus never left it.
    let restore: @MainActor () -> Bool
    /// True when an app-handled Left owns this press (Classic's hero carousel pages on it).
    let vetoesLeftArm: @MainActor () -> Bool
}

// MARK: - Items

/// One rail item. `id` is the `TabView` selection value, so the rail and the (hidden) tab bar address
/// the same six destinations by the same numbers.
struct RailItem: Identifiable, Equatable {
    let id: Int
    /// The ENGLISH key, verbatim from the matching `Tab(_:systemImage:value:)` title in `MainTabView`:
    /// the localization key (the catalog already carries these six) and the stable half of the
    /// accessibility identifier the harness asserts on (`rail_item_Home`).
    let title: String
    let systemImage: String

    var localizedTitle: String { String(localized: String.LocalizationValue(title)) }

    /// Always the first item (the Corner rail's resting glyph, FEAT-80).
    static let home = RailItem(id: 0, title: "Home", systemImage: "house")

    /// Search & Discover A6: the Discover tab, selection value 6, shown right after Search when
    /// Discover is placed on its own tab (`DiscoverPlacement.ownTab`).
    static let discover = RailItem(id: 6, title: "Discover", systemImage: "safari")

    /// Home, Search, (Discover), Library, Add-ons, Settings: titles and SF Symbols identical to
    /// `MainTabView`'s `Tab` declarations. If a tab is added, renamed or reordered there, this list
    /// moves with it. Variable length: the pill is a VStack sized by its items (6 items plus the
    /// avatar is ≈ 552 pt), nothing assumes a count.
    static func tabs(showsDiscover: Bool) -> [RailItem] {
        var items: [RailItem] = [
            home,
            RailItem(id: 1, title: "Search", systemImage: "magnifyingglass"),
        ]
        if showsDiscover { items.append(discover) }
        items += [
            RailItem(id: 2, title: "Library", systemImage: "books.vertical"),
            RailItem(id: 3, title: "Add-ons", systemImage: "puzzlepiece.extension"),
            RailItem(id: 4, title: "Settings", systemImage: "gearshape"),
        ]
        return items
    }

    /// The Profile tab, drawn as the profile's avatar at the bottom of the pill.
    static let profile = RailItem(id: 5, title: "Profile", systemImage: "person.crop.circle")

    /// Every id the rail can address, Discover included whatever the placement (a selection value
    /// keeps its title even while its item is hidden).
    static func title(for id: Int) -> String? {
        if id == profile.id { return profile.title }
        return tabs(showsDiscover: true).first { $0.id == id }?.title
    }
}

/// Layout numbers for the pill (P4 §1.2). Local to this file: they describe one piece of chrome.
/// The ones the inset math and the Corner geometry need are mirrored on `NavigationChrome`.
private enum RailMetrics {
    static let bezelInset: CGFloat = NavigationChrome.bezelInset            // 16
    static let collapsedWidth: CGFloat = NavigationChrome.collapsedWidth    // 84
    /// Grows rightward only; the height never changes, so no item moves vertically.
    static let expandedWidth: CGFloat = NavigationChrome.expandedWidth      // 300
    static let innerPadding: CGFloat = NavigationChrome.innerPadding        // 12
    static let verticalPadding: CGFloat = NavigationChrome.verticalPadding  // 22
    /// The circle behind each glyph; the selected tab's is filled.
    static let itemPlatter: CGFloat = NavigationChrome.itemPlatter          // 60
    static let iconSize: CGFloat = 36
    static let itemSpacing: CGFloat = 14
    /// Extra space above the profile avatar.
    static let avatarGap: CGFloat = 18
    static let labelGap: CGFloat = 18
    static let cornerRadius: CGFloat = NavigationChrome.pillRadius          // 42
    static let profileRingWidth: CGFloat = 4
    /// Full screen, behind the pill, only while it is expanded.
    static let dimOpacity: Double = 0.55
    static let expandDuration: Double = 0.2
    /// Hide While Browsing's slide (Stage's page writes use the page's own duration instead).
    static let slideDuration: Double = 0.25
    /// SHOW-edge settle for the scroll mirror (kept from FEAT-30, rc2 feedback: a page running back
    /// to its top re-crosses the show arm more than once). Never for Stage's page writes.
    static let restingShowSettle: TimeInterval = 0.35
    /// How long a route restore gets to move focus out of the rail before the default hand-off.
    static let exitVerifyDelay: TimeInterval = 0.5

    // FEAT-80 Corner (Batch O, Christian's 2026-10-20 mock; W3-11, D1, Steven's 10-19 mock): open,
    // the Corner rail is Centre's column (every number above, the same row widths) at `bezelInset`
    // from the left edge whatever the Rail Style, anchored at the top so the Home cell lands on the
    // top safe-area line at (28, 60). Its glass is NOT Centre's pill: it is flush with the top and
    // the left screen edges, drawn from the screen corner with a bleed past both, rounded at the
    // bottom trailing corner only, as wide as the open column from its first frame, and only its
    // height grows (`NavigationChrome.cornerGlassFrame`). At rest only the Home glyph shows, bare,
    // in that same cell, so nothing jumps when the column unrolls around it (Batch N's flush
    // resting tab stays retired: no glass at rest).
    /// The column's top edge, 60 − 22 = 38 (`NavigationChrome.cornerPillTop`: the top safe-area
    /// line less `verticalPadding`).
    static let cornerTop: CGFloat = NavigationChrome.cornerPillTop
    /// The column's height around the Home cell alone, 60 + 2 × 22 = 104: the glass's first height
    /// when it fades in (a flush top bar, 38 + 104 = 142 on screen) and its last before it fades out.
    static let cornerRestHeight: CGFloat = NavigationChrome.cornerRestHeight
    /// The lower items' fade, staggered top to bottom while the column unrolls.
    static let cornerItemFade: Double = 0.18
    static let cornerItemStagger: Double = 0.035
    /// The glass's own fade: in at the top bar's size before it grows, out once it has shrunk.
    static let cornerGlassFade: Double = 0.12
    /// Opening: the top bar holds this long before it grows down.
    static let cornerGrowDelay: Double = 0.08
    /// Closing: the shrink's spring is about 90 % of the way back to the top bar by now.
    static let cornerGlassFadeOutDelay: Double = 0.22
    /// The resting Home glyph's shadow (on the glyph alone), so the bare icon reads on bright art.
    static let cornerGlyphShadowRadius: CGFloat = 4
    static let cornerGlyphShadowY: CGFloat = 2
    static let cornerGlyphShadowOpacity: Double = 0.55
    /// The unroll: a spring on the glass frame and the mask (never on the items).
    static var cornerUnroll: Animation { .spring(response: 0.36, dampingFraction: 0.86) }
}

// MARK: - Content gate (P4 §2.3)

/// Opens and closes the content gate. The `uikit` mode (primary) flips one interaction flag on the
/// tab controller's view through `HiddenTabBarFocusBlocker`; the `perTab` fallback (`-debug.railGate
/// perTab`) is `.disabled` on every tab root, following `NavigationChromeModel.contentGated`. Both
/// modes publish `contentGated`, which the probe reads. One log line per real change.
@MainActor
enum RailContentGate {
    static func set(_ gated: Bool, chrome: NavigationChromeModel) {
        guard chrome.contentGated != gated else { return }
        chrome.setContentGated(gated)
        let mode = RailGateMode.current
        if mode == .uikit {
            HiddenTabBarFocusBlocker.setContentGated(gated)
        }
        NSLog("[Rail] gate=%@ mode=%@", gated ? "on" : "off", mode.rawValue)
    }
}

// MARK: - The rail

/// The pill itself. Mounted ONCE, in `MainTabView`'s `.overlay` on the `TabView`, outside every `Tab`
/// closure (never part of a tab's kept-alive subtree), and only in Rail mode.
struct NavigationRail: View {
    @Binding var selectedTab: Int
    let activeProfile: NuvioProfile?
    /// FEAT-25's app-root deep-link cover. Passed in (not observed), as `MainTabView` holds it.
    let rootCoverActive: Bool
    /// `MainTabView`'s `@Namespace`, applied as `.focusScope` on the TabView, so a hand-off can re-run
    /// default focus placement for the whole shell.
    let shellFocusScope: Namespace.ID
    @ObservedObject var chrome: NavigationChromeModel
    /// Passed in EXPLICITLY as a plain `let`, never observed: overlay content sits outside the
    /// TabView's `.environment(\.tabBarVisibility,)` (FEAT-30's rc2 bug), and a plain reference
    /// subscribes nobody. The narrow `onReceive($immersiveHidden)` below is the only subscription.
    let tabBarVisibility: TabBarVisibility

    @AppStorage(NavigationChrome.railVisibilityKey) private var visibilityRaw = NavigationChrome.RailVisibility.always.rawValue
    @AppStorage(NavigationChrome.railPositionKey) private var railPositionRaw = NavigationChrome.RailPosition.centre.rawValue
    @AppStorage(NavigationChrome.railLabelsKey) private var railLabelsRaw = NavigationChrome.RailLabels.shown.rawValue
    @AppStorage(NavigationChrome.railStyleKey) private var railStyleRaw = NavigationChrome.RailStyle.floating.rawValue
    /// A6: whether the Discover item is listed. Handed down from `MainTabView.showsDiscoverTab`,
    /// the same once-per-tree value that decides whether `Tab(value: 6)` exists, so the rail never
    /// lists an item without a tab or the reverse (review r1 P2-1). The rail never reads
    /// `DiscoverPlacement` itself.
    let showsDiscover: Bool
    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The items are focusable Buttons ONLY while armed (FEAT-30, test52 runs 1-6): left focusable
    /// at rest an overlay takes default focus at cold launch, and UIKit focus restoration hands
    /// focus back to a container's last item when it reappears.
    @State private var armed = false
    /// Why the rail opened (Menu's meaning inside it, R4). nil while closed.
    @State private var openedBy: RailOpenReason?
    /// Latched by an arm; cleared when focus leaves. Shows the pill over every hide term but the
    /// root cover, so the items exist when the rail takes focus.
    @State private var revealed = false
    @State private var immersiveHidden = false
    /// Settled mirror of the current tab's scroll position (the resting rule). Never read
    /// `chrome.scrolledDownByTab` directly for visibility: that is the raw crossing signal.
    @State private var restingShown = true
    @State private var restingGeneration = 0
    /// Monotonic token for deferred focus work: a check scheduled by an earlier arm, exit or
    /// hand-off must not act on the state of a later one (internal review r3b P2-1).
    @State private var focusGeneration = 0
    /// S1 W2: suppresses the hidden-bar redirect only right after a FAILED rescue.
    @State private var rescueGuard = StrandedRescueGuard()
    /// The animation the next `shown` change uses: Stage's page curve and duration, or the slide.
    @State private var slideAnimation: Animation? = .easeOut(duration: RailMetrics.slideDuration)
    /// The route the last exit used (`route=` in the probe): home, folder, detail, settings, none.
    @State private var lastExitRoute = "-"
    @FocusState private var focusedItem: Int?

    private var expanded: Bool { focusedItem != nil }

    /// FEAT-80: the resolved position (rc8's stored "top" reads as Corner).
    private var position: NavigationChrome.RailPosition {
        NavigationChrome.railPosition(raw: railPositionRaw)
    }

    private var isCorner: Bool { position == .corner }

    /// FEAT-80 Corner: the column is unrolled from the moment the rail ARMS, one turn before
    /// `takeFocusAfterReveal` lands focus, so the item it focuses (the selected tab's, which may be
    /// any of them) is already inside the growing mask. Collapsed means not armed, so every item
    /// is a plain label then, the hidden ones included.
    private var cornerOpen: Bool { armed || expanded }

    /// FEAT-80 Corner (Batch O): at rest, the Home glyph alone, bare: no glass, no selection fill,
    /// no label, a shadow of its own. Never true in Centre.
    private var cornerResting: Bool { isCorner && !cornerOpen }

    /// What the labels, the width and (Corner) the unroll follow: `expanded` in Centre, unchanged;
    /// `cornerOpen` in Corner.
    private var railOpen: Bool { isCorner ? cornerOpen : expanded }

    /// FEAT-80 Corner (Batch O): the unroll's second phase, the grow (see `cornerPanel`). Follows
    /// `cornerOpen` through `updateCornerGrowth`: opening, the next turn; closing, the next turn
    /// (Reduce Motion: once the fade has finished). It holds the glass's frame open through the
    /// close, and drives the grow on its own only for an arm that MOUNTS the panel
    /// (`cornerArmedAtRest` false).
    @State private var cornerGrown = false
    @State private var cornerGrowthGeneration = 0
    /// FEAT-80 Corner (review r1 P3-1): latched by every arm, true when the panel was already on
    /// screen at rest (Always Visible; Hide While Browsing at a page's top). Such an arm lays the
    /// glass's frame out full on the arm turn itself, the turn before the first focus write, so
    /// that write never targets an item outside a not-yet-grown mask; only the drawn grow waits
    /// `cornerGrowDelay`. False when the arm mounts the panel (Hidden, scrolled down, Search's
    /// keyboard): there it must mount at the top bar's size to unroll at all, so it grows on
    /// `cornerGrown`, a turn later.
    @State private var cornerArmedAtRest = false

    /// FEAT-80 Corner: the glass's frame and the mask, open (see `cornerArmedAtRest`).
    private var cornerFrameOpen: Bool {
        cornerGrown || (cornerOpen && cornerArmedAtRest)
    }

    /// The glass's opacity: Centre's always shows; Corner's is 0 at rest (Batch O). The real glass
    /// draws with it, Rail12's DEBUG bounds oracle mounts only while it is above 0, and the probe's
    /// `glass=` token reports it (review r1 P3-2), so "no glass at rest" reads the value the glass
    /// itself uses.
    private var glassOpacity: Double {
        !isCorner || cornerOpen ? 1 : 0
    }

    /// The opacity a rail row is drawn at, by its order (0 = Home, the profile last). Centre draws
    /// every row; Corner's Home always shows, and every row below it is 0 at rest, the selected
    /// tab's included (review r1 P2-1: Search's row starts 8 pt above the bottom of the 104 pt
    /// resting mask, so drawn at rest it showed an accent lens under the bare Home glyph, at rest
    /// and after every close). The probe's `selrow=` token reports the selected tab's.
    private func rowOpacity(order: Int) -> Double {
        !isCorner || order == 0 || cornerOpen ? 1 : 0
    }

    /// The selected tab's row in the column (`rowOpacity`, the probe): the tabs in order, then the
    /// profile.
    private var selectedRowOrder: Int {
        if selectedTab == RailItem.profile.id { return railItems.count }
        return railItems.firstIndex { $0.id == selectedTab } ?? 0
    }

    /// FEAT-80 Corner: the column's full laid-out height, measured once per layout change. 0 until
    /// the first layout, when `cornerOpenHeight` falls back to `cornerDerivedHeight`.
    @State private var cornerColumnHeight: CGFloat = 0

    /// FEAT-80 Corner (Batch N review r1): the open pill's height from the metrics, before the
    /// first measurement. With Hidden the first arm MOUNTS the panel already open; floored at the
    /// resting size, the glass and the mask sat there and then snapped open on the measurement,
    /// with no spring. The rows are one platter tall (the label's line is shorter), so this matches
    /// the measurement and the first unroll animates like every later one. Batch O: the Centre
    /// pill's height, 22 pt of padding above Home and below the avatar.
    private var cornerDerivedHeight: CGFloat {
        let count = CGFloat(railItems.count + 1)  // the tabs + the profile avatar
        return count * RailMetrics.itemPlatter
            + max(count - 1, 0) * RailMetrics.itemSpacing
            + RailMetrics.avatarGap + 2 * RailMetrics.verticalPadding
    }

    private var cornerOpenHeight: CGFloat {
        max(cornerColumnHeight > 0 ? cornerColumnHeight : cornerDerivedHeight, RailMetrics.cornerRestHeight)
    }

    private var visibility: NavigationChrome.RailVisibility {
        NavigationChrome.railVisibility(raw: visibilityRaw)
    }

    private var shown: Bool {
        RailVisibilityRule.shown(RailVisibilityRule.Inputs(
            railMode: NavigationChrome.isRail(),
            holdsFocus: focusedItem != nil,
            revealed: revealed || armed,
            rootCoverActive: rootCoverActive,
            immersive: immersiveHidden,
            scrolledDown: !restingShown,
            visibility: visibility,
            selectedTab: selectedTab,
            keyboardFocused: chrome.searchKeyboardFocused
        ))
    }

    /// B4: the shell's reserved leading safe area right now (36 / 0). See
    /// `RailVisibilityRule.reservedLeadingInset`.
    private var shellInset: CGFloat {
        RailVisibilityRule.reservedLeadingInset(sideSafeArea: PinnedRowGeometry.sideSafeArea,
                                                visibility: visibility,
                                                position: position,
                                                selectedTab: selectedTab,
                                                keyboardFocused: chrome.searchKeyboardFocused,
                                                holdInset: RailSearchInsetHold.current)
    }

    /// R3: what Always Visible adds to every tab root's leading safe area (36; 0 in Corner,
    /// FEAT-80), for the probe.
    private var contentInset: CGFloat {
        NavigationChrome.contentSafeAreaExtra(sideSafeArea: PinnedRowGeometry.sideSafeArea,
                                              reservesWidth: visibility == .always,
                                              position: position)
    }

    /// A6: the item list for this tree's tabs.
    private var railItems: [RailItem] {
        RailItem.tabs(showsDiscover: showsDiscover)
    }

    private var defaultSlide: Animation {
        .easeOut(duration: RailMetrics.slideDuration)
    }

    /// FEAT-80: Corner pins the pill to the top-left; Centre centres the pill on the left edge.
    private var pillAlignment: Alignment {
        isCorner ? .topLeading : .leading
    }

    /// FEAT-80: Icons Only keeps the pill at its collapsed width and never draws labels.
    private var showsLabels: Bool {
        NavigationChrome.railLabels(raw: railLabelsRaw) == .shown
    }

    /// Batch P (P2): Floating pill or Edge (flush left). Centre only: Corner ignores it (W3-11).
    private var style: NavigationChrome.RailStyle {
        NavigationChrome.railStyle(raw: railStyleRaw)
    }

    /// The pill's width: grows only while open AND labels are shown. FEAT-80 Corner (Batch O): the
    /// column's same 84 / 300 as Centre, following `railOpen` (the arm); W3-11: Corner's GLASS
    /// does not follow it, it is as wide as the open column from its first frame
    /// (`NavigationChrome.cornerGlassFrame`).
    private var pillWidth: CGFloat {
        railOpen && showsLabels ? RailMetrics.expandedWidth : RailMetrics.collapsedWidth
    }

    /// One item row's width inside the pill (the glyph, the gap, the label).
    private var itemRowWidth: CGFloat {
        pillWidth - 2 * RailMetrics.innerPadding
    }

    var body: some View {
        ZStack(alignment: pillAlignment) {
            // The dim: always mounted at opacity 0, so it cross-fades with or without Reduce Motion
            // (#20). Behind the pill, never hit-testable, never focusable.
            Color.black
                .opacity(expanded ? RailMetrics.dimOpacity : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(.easeOut(duration: RailMetrics.expandDuration), value: expanded)
            if shown {
                if isCorner {
                    // FEAT-80 (Batch O): Centre's bezel inset, anchored at the top. W3-11 (D1):
                    // the bezel inset whatever the Rail Style, so the Home cell stays at (28, 60);
                    // the glass reaches the screen corner by itself (`cornerPanel`). A fade in and
                    // out (Hidden's reveal, Hide While Browsing's hide): a slide from the leading
                    // edge would drag the resting Home icon across the screen.
                    cornerPanel
                        .padding(.leading, RailMetrics.bezelInset)
                        .padding(.top, RailMetrics.cornerTop)
                        .transition(.opacity)
                } else {
                    pill
                        .padding(.leading, NavigationChrome.pillLeading(style))
                        .transition(reduceMotion ? AnyTransition.opacity
                                    : AnyTransition.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(slideAnimation, value: shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pillAlignment)
        .ignoresSafeArea()
        // Zero-sized, always mounted in Rail mode: keeps the hidden system bar out of the focus
        // engine, redirects a stranded landing into the rail (S1), and carries the UIKit gate.
        .background(alignment: .topLeading) {
            HiddenTabBarFocusBlocker(onFocusLandedInHiddenBar: revealForStrandedFocus,
                                     onKeyboardFocusChanged: { [chrome] focused in
                                         chrome.setSearchKeyboardFocused(focused)
                                     })
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        // R3: Always Visible's reserved width, as UIKit safe area at the shell (see
        // `HiddenTabBarFocusBlocker.setReservedLeadingInset`). Follows the visibility live, and
        // (B4) collapses to 0 while Search's keyboard holds focus unless `-debug.railSearchInsetHold`.
        // Only the keyboard's collapse and restore animate (0.25 s); a visibility change is instant.
        .onChange(of: visibility, initial: true) { _, _ in
            HiddenTabBarFocusBlocker.setReservedLeadingInset(shellInset)
        }
        // FEAT-80: Corner reserves nothing. The position joins `ContentView`'s remount key, so this
        // is belt and braces for the shell half.
        .onChange(of: position) { _, _ in
            HiddenTabBarFocusBlocker.setReservedLeadingInset(shellInset)
        }
        .onChange(of: RailVisibilityRule.keyboardHidesRail(selectedTab: selectedTab,
                                                           keyboardFocused: chrome.searchKeyboardFocused)) { _, _ in
            HiddenTabBarFocusBlocker.setReservedLeadingInset(shellInset, animated: true)
        }
        // ALWAYS mounted (DEBUG): its `shown=` token is the hide test.
        .overlay(alignment: .topLeading) { stateProbe }
        // `@Published` emits on willSet and replays its current value to a new subscriber: use the
        // payload, no `onAppear` seed needed.
        .onReceive(tabBarVisibility.$immersiveHidden) { hidden in
            slideAnimation = defaultSlide
            immersiveHidden = hidden
        }
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.movementDidFailNotification)) { note in
            handleMoveFailed(note)
        }
        .onChange(of: rootCoverActive) { _, active in
            if active { releaseFocusForCover() }
        }
        .onAppear { updateRestingVisibility(seeded: true) }
        // The CURRENT tab's mirror, so a crossing on a background tab cannot move the pill.
        .onChange(of: chrome.scrolledDownByTab[selectedTab]) { _, _ in
            updateRestingVisibility()
        }
        .onChange(of: selectedTab) { _, _ in
            updateRestingVisibility()
        }
        .onChange(of: chrome.revealRequest) { _, request in
            arm(request.reason, origin: "request")
        }
        .onChange(of: chrome.exitRequest) { _, _ in
            guard focusedItem != nil else { return }
            exitRail(to: selectedTab, via: "request")
        }
        .onChange(of: focusedItem) { old, new in
            focusChanged(old: old, new: new)
        }
        .onChange(of: cornerOpen) { _, open in
            updateCornerGrowth(open: open)
        }
    }

    // MARK: Layout

    /// The pill's column, shared by Centre and Corner (Batch O): the tabs, the profile avatar under
    /// its gap, the padding and the width. `row` draws one item from its order (0 = Home, the
    /// profile last).
    private func railColumn<Row: View>(@ViewBuilder row: @escaping (RailItem, Int) -> Row) -> some View {
        VStack(alignment: .leading, spacing: RailMetrics.itemSpacing) {
            ForEach(Array(railItems.enumerated()), id: \.element.id) { order, item in
                row(item, order)
            }
            row(RailItem.profile, railItems.count)
                .padding(.top, RailMetrics.avatarGap)
        }
        .padding(.vertical, RailMetrics.verticalPadding)
        .padding(.horizontal, RailMetrics.innerPadding)
        .frame(width: pillWidth, alignment: .leading)
    }

    /// W3-11 (D1, Steven's 10-19 mock): Corner's glass AND mask, so the two never disagree. Square
    /// at the top leading, bottom leading and top trailing corners (the first three sit off-canvas
    /// or on the top edge), rounded at the bottom trailing corner only. Never `pillShape`, so Corner
    /// ignores the Rail Style.
    private var cornerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomTrailingRadius: NavigationChrome.cornerRadius, style: .continuous)
    }

    /// Floating: the rounded pill. Edge (Batch P): square on the screen-edge side, rounded on the
    /// trailing side. Centre's glass (`pill`); Corner draws `cornerShape` instead.
    private var pillShape: AnyShape {
        switch style {
        case .floating:
            AnyShape(RoundedRectangle(cornerRadius: RailMetrics.cornerRadius, style: .continuous))
        case .edge:
            AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                            bottomTrailingRadius: RailMetrics.cornerRadius,
                                            topTrailingRadius: RailMetrics.cornerRadius, style: .continuous))
        }
    }

    /// The glass is a BACKGROUND behind the buttons, never a `glassEffect` around them: wrapping
    /// focusable content in glass hid it from the focus engine in another tvOS app (the Orivio
    /// trap, `docs/research/orivio-tv-handoff.md`).
    private var pillGlass: some View {
        railGlass(in: pillShape)
    }

    /// The glass in `shape`: Centre's pill (`pillGlass`) or Corner's flush corner (`cornerShape`).
    @ViewBuilder
    private func railGlass<S: Shape>(in shape: S) -> some View {
        if showsLabels {
            shape.fill(Color.clear).glassEffect(.regular, in: shape)
        } else {
            // The device pass of 2026-10-20 picked this tint: regular, clear and a black tint
            // rendered the collapsed 84 pt pill near-black over the Stage's black left margin
            // (BUG-196), and ultraThinMaterial vanished.
            shape.fill(Color.clear).glassEffect(.regular.tint(Color.white.opacity(0.12)), in: shape)
        }
    }

    #if DEBUG
    /// Rail08's and Rail12's oracle: the glass's own frame (Corner: `cornerGlassFrame`, bleed
    /// included, mounted only while `glassOpacity` is above 0, see `cornerPanel`).
    /// `navigation_rail` is a `.contain` container, whose accessibility frame is the union of its
    /// children, and the collapsed pill's
    /// labels (laid out, faded) overflow its 84 pt width.
    private var railBoundsOracle: some View {
        Color.white.opacity(0.001)
            .accessibilityElement()
            .accessibilityLabel("rail bounds")
            .accessibilityIdentifier("navigation_rail_bounds")
    }
    #endif

    /// What both pills end with.
    private func railPillChrome<Content: View>(_ content: Content) -> some View {
        content
            // One focus section: moves inside stay inside, and with content gated a move out fails,
            // which is what the rail's app-handled exits listen for.
            .focusSection()
            // R4: a handler only when Left opened the rail; otherwise nil, the system default.
            .onExitCommand(perform: menuHandler)
            // `.contain`, so the pill has its own element without clobbering the per-item identifiers.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("navigation_rail")
    }

    private var pill: some View {
        railPillChrome(
            railColumn { item, _ in
                itemView(item)
            }
            .background(alignment: .leading) {
                pillGlass
                #if DEBUG
                railBoundsOracle
                #endif
            }
            // #20: Reduce Motion drops the width animation; the labels and the dim still cross-fade
            // (their own animations).
            .animation(reduceMotion ? nil : .easeOut(duration: RailMetrics.expandDuration), value: expanded)
        )
    }

    /// FEAT-80 Corner (Batch O; Batch N's unroll; W3-11, D1): the same column as `pill`, laid out
    /// at its final geometry from the first frame, behind a top-aligned mask. At rest the glass is
    /// invisible (opacity 0) and the mask shows only the Home cell, where the Home glyph sits bare.
    /// The glass and the mask are `cornerShape` at `NavigationChrome.cornerGlassFrame`: drawn from
    /// the screen corner, flush with the top and the left screen edges with `cornerBleed` past
    /// both, as wide as the open column (300 + 16 with labels, 84 + 16 Icons Only) from the first
    /// frame, so they only ever grow DOWNWARD. Opening runs in two phases:
    ///  1. `cornerOpen` (the arm): the Buttons replace the labels, and the glass fades in as a flush
    ///     top bar around Home's row (316 × 142 on screen, 100 × 142 Icons Only), Home's selection
    ///     fill and label with it.
    ///  2. The grow, `cornerGrowDelay` later: only the height of the glass's frame and the mask
    ///     springs, down to the column's height + 38.
    /// Closing reverses it: the glass shrinks back to the top bar at once, then fades out and
    /// Home's row turns back into the bare glyph. Only the glass's frame and opacity and the mask
    /// animate. The bleed and the corner offset live on the background and the mask, never as
    /// padding on the column: padding would grow the column's `.focusSection()` into the corner.
    /// The items never move: no `offset`, no `scaleEffect` on them (the only `offset`s place the
    /// glass and the mask), so a focus frame is where it is drawn from the first turn (the Orivio
    /// trap above, the same reason the glass is a background). Collapsed, the items below Home are
    /// plain labels (not armed), masked off and out of the accessibility tree; they fade in top to
    /// bottom as the mask passes them. Reduce Motion: a fade, no grow (the size is full at once
    /// opening, and snaps back after the fade).
    ///
    /// Review r1 P3-1: the frame follows `cornerFrameOpen`, which (an arm from rest) flips on the
    /// arm turn itself, so the mask is LAID OUT full before the first focus write lands; the grow
    /// is only drawn later, through a delayed animation scoped to the glass's frame and the mask.
    /// Scoped, never on the column: an insertion's transition (a label swapping for its Button)
    /// takes its container's transaction, not the row's own `.animation`, so a delay on one shared
    /// grow also delayed every Button's fade-in, the selected item's included (rail12's recording).
    /// The glass's opacity sits OUTSIDE that scope, so it fades in at once with phase 1.
    private var cornerPanel: some View {
        let open = cornerOpen
        let frameOpen = cornerFrameOpen
        let glass = glassOpacity
        // Screen coordinates; the column's own origin is (bezelInset, cornerTop) on screen, so the
        // shape is drawn back by that much to start at the screen corner (less the bleed).
        let frame = NavigationChrome.cornerGlassFrame(labels: showsLabels, open: frameOpen,
                                                      columnHeight: cornerOpenHeight)
        let shiftX = frame.minX - RailMetrics.bezelInset
        let shiftY = frame.minY - RailMetrics.cornerTop
        let shape = cornerShape
        let grow = cornerGrowAnimation(opening: frameOpen)
        return railPillChrome(
            railColumn { item, order in
                cornerItem(item, order: order)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded() }, action: { measured in
                cornerColumnHeight = measured
            })
            // Before the background, so the glass itself is never masked (it carries its own
            // frame). The glass's own shape, frame and offset, so a label or a focus capsule never
            // shows outside it while it grows (a plain Rectangle cut the capsule square beside the
            // glass's rounded corner). Every row, capsule and avatar sits inside it at rest and open.
            .mask(alignment: .topLeading) {
                shape
                    .frame(width: frame.width, height: frame.height)
                    .animation(grow, value: frameOpen)
                    .offset(x: shiftX, y: shiftY)
            }
            .background(alignment: .topLeading) {
                railGlass(in: shape)
                    .frame(width: frame.width, height: frame.height)
                    .animation(grow, value: frameOpen)
                    .offset(x: shiftX, y: shiftY)
                    .opacity(glass)
                #if DEBUG
                // Rail12: the glass's frame, bleed included, only while the glass draws (out of
                // the tree at rest).
                if glass > 0 {
                    railBoundsOracle
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: shiftX, y: shiftY)
                }
                #endif
            }
            // Phase 1: the glass's opacity and Home's swap (and every row's swap transition).
            .animation(cornerFadeAnimation(opening: open), value: open)
            // Centre's focus capsule fade (`pill`'s animation on `expanded`), for the turn focus
            // lands after the arm and the turn it leaves before the disarm.
            .animation(reduceMotion ? nil : .easeOut(duration: RailMetrics.expandDuration), value: expanded)
        )
    }

    /// FEAT-80 Corner: Home (order 0) always shows: bare at rest, a row of the pill open. Its swap
    /// between the resting label and the armed Button cross-fades with the glass (in with it,
    /// out after the shrink), so the glyph's shadow returns as the glass leaves. Every later item
    /// fades with the unroll, staggered by its order so the column fills top to bottom, and leaves
    /// the accessibility tree while collapsed. It closes in one fade, no stagger.
    ///
    /// Batch N review r1: the selected tab's item is never faded IN. `takeFocusAfterReveal` writes
    /// focus to it the next turn and again at +0.15 s; staggered (Settings, Profile: up to
    /// order × 0.035 s + 0.18 s), both writes landed while it was near opacity 0, which the hardware
    /// focus engine refuses (Batch B: opacity-0 controls are unfocusable), so the rail failed to open
    /// on those tabs. So, whichever row it is (Home included, review r1 P2-2), its Button arrives
    /// with no transition (`insertion: .identity`, `itemView`'s `selectedSwap`), at full opacity on
    /// the first write, and a lower row's own opacity snaps to 1 on the arm turn (no animation
    /// opening). Its label still leaves with `.opacity`; the two look the same (only Home goes bare
    /// at rest). Review r1 P2-1: at rest it is drawn at 0 like every row below Home (`rowOpacity`),
    /// and it fades out with the rest on the close, in both motion modes.
    @ViewBuilder
    private func cornerItem(_ item: RailItem, order: Int) -> some View {
        let open = cornerOpen
        let selected = item.id == selectedTab
        if order == 0 {
            itemView(item, selectedSwap: selected)
        } else if selected {
            itemView(item, collapsedHidden: !open, selectedSwap: true)
                .opacity(rowOpacity(order: order))
                .animation(open ? nil : cornerItemAnimation(order: order, opening: false), value: open)
        } else {
            itemView(item, collapsedHidden: !open)
                .opacity(rowOpacity(order: order))
                .animation(cornerItemAnimation(order: order, opening: open), value: open)
        }
    }

    /// The lower items' fade: opening, from the grow's start, staggered top to bottom.
    private func cornerItemAnimation(order: Int, opening: Bool) -> Animation {
        let fade = Animation.easeOut(duration: RailMetrics.cornerItemFade)
        guard opening, !reduceMotion else { return fade }
        return fade.delay(RailMetrics.cornerGrowDelay + Double(order) * RailMetrics.cornerItemStagger)
    }

    /// Phase 1's animation: the glass fades in at once, and out once the shrink has nearly settled.
    /// Reduce Motion: one fade each way, as long as the items'.
    private func cornerFadeAnimation(opening: Bool) -> Animation {
        if reduceMotion { return .easeOut(duration: RailMetrics.cornerItemFade) }
        let fade = Animation.easeOut(duration: RailMetrics.cornerGlassFade)
        return opening ? fade : fade.delay(RailMetrics.cornerGlassFadeOutDelay)
    }

    /// Phase 2's animation, scoped to the glass's frame and the mask (`cornerPanel`): opening, the
    /// unroll's spring after `cornerGrowDelay`, so the top bar holds first; closing, at once.
    /// Reduce Motion: none (the size is full at once opening, and snaps back after the fade).
    private func cornerGrowAnimation(opening: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return opening ? RailMetrics.cornerUnroll.delay(RailMetrics.cornerGrowDelay) : RailMetrics.cornerUnroll
    }

    /// `cornerGrown` follows `cornerOpen`, always a turn or more later, so the grow never shares
    /// phase 1's transaction: opening, the next turn (an arm from rest has already laid the frame
    /// out full, `cornerFrameOpen`; an arm that mounted the panel grows from here); closing, the
    /// next turn (Reduce Motion: once the fade has finished, unanimated).
    private func updateCornerGrowth(open: Bool) {
        guard isCorner else { return }
        cornerGrowthGeneration &+= 1
        let generation = cornerGrowthGeneration
        let delay: TimeInterval = !open && reduceMotion ? RailMetrics.cornerItemFade : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == cornerGrowthGeneration, cornerOpen == open else { return }
            cornerGrown = open
        }
    }

    /// `collapsedHidden` (FEAT-80 Corner): a masked item below the resting Home cell. It drops its
    /// identifier and its children: an `.accessibilityHidden` outside the `.combine` element left
    /// every masked item in the tree, hittable, and a bare one still exposed its glyph and title
    /// (rail12 at rest, tvOS 27 simulator).
    ///
    /// The swap between the label and the Button when the rail arms or disarms is `.opacity`,
    /// SwiftUI's default, everywhere but one place: `selectedSwap` (Corner's selected tab, Home
    /// included, see `cornerItem`) gives the Button `.asymmetric(insertion: .identity, removal:
    /// .opacity)`, so it is at full opacity for the first focus write (review r1 P2-2: Home's
    /// Button faded in for 0.12 s, 0.18 s under Reduce Motion, and only the +0.15 s retry could
    /// land). The labels keep `.opacity`.
    @ViewBuilder
    private func itemView(_ item: RailItem, collapsedHidden: Bool = false,
                          selectedSwap: Bool = false) -> some View {
        if armed {
            // `RailItemButtonStyle`: the FEAT-30 focus carve-out, carried over (see its doc).
            let focused = focusedItem == item.id
            Button {
                selectItem(item.id)
            } label: {
                itemLabel(item, focused: focused)
            }
            .buttonStyle(RailItemButtonStyle(isFocused: focused))
            .focused($focusedItem, equals: item.id)
            .accessibilityIdentifier("rail_item_\(item.title)")
            .transition(selectedSwap ? .asymmetric(insertion: .identity, removal: .opacity) : .opacity)
        } else if collapsedHidden {
            // Masked under the resting Corner rail: the same look and geometry, out of the tree.
            itemLabel(item, focused: false)
                .accessibilityElement(children: .ignore)
                .accessibilityHidden(true)
                .transition(.opacity)
        } else {
            // Not armed: the same look and geometry, but nothing the engine can land on.
            itemLabel(item, focused: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("rail_item_\(item.title)")
                .transition(.opacity)
        }
    }

    private func itemLabel(_ item: RailItem, focused: Bool) -> some View {
        let selected = item.id == selectedTab
        let width = itemRowWidth
        return HStack(spacing: RailMetrics.labelGap) {
            itemGlyph(item, selected: selected, focused: focused)
                .frame(width: RailMetrics.itemPlatter, height: RailMetrics.itemPlatter)
            // Always mounted at its full width, faded in and out with the expansion (#20); it draws
            // past the collapsed frame only while invisible. FEAT-80: not mounted with Icons Only.
            if showsLabels {
                Text(itemTitle(item))
                    .font(Theme.Font.body)
                    .foregroundStyle(focused ? Theme.Palette.onFocusPlatter : Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(railOpen ? 1 : 0)
                    .animation(.easeOut(duration: RailMetrics.expandDuration), value: railOpen)
            }
        }
        .frame(width: width, alignment: .leading)
        // FEAT-80: VoiceOver and the UI tests still read the title with Icons Only.
        .accessibilityLabel(itemTitle(item))
    }

    /// FEAT-80 Corner (Batch O): at rest (`cornerResting`) the Home glyph is bare, with no selection
    /// fill (the accent text colour is meant for that fill, so the glyph takes the primary colour),
    /// and carries a soft shadow of its own. Only Home: the masked rows keep their look, so the
    /// selected row's swap stays invisible (`cornerItem`). Centre never rests bare and never gets
    /// the shadow.
    @ViewBuilder
    private func itemGlyph(_ item: RailItem, selected: Bool, focused: Bool) -> some View {
        let bare = cornerResting && item.id == RailItem.home.id
        let filled = selected && !bare
        if item.id == RailItem.profile.id, let profile = activeProfile {
            // Contract: profile avatars ring. The ring marks the selected Profile tab.
            ProfileAvatar(profile: profile, size: RailMetrics.itemPlatter)
                .overlay {
                    if selected {
                        Circle().strokeBorder(Theme.Palette.accent, lineWidth: RailMetrics.profileRingWidth)
                    }
                }
        } else {
            ZStack {
                // Selection state, so the brand colour is allowed here.
                Circle().fill(filled ? Theme.Palette.accent : Color.clear)
                Image(systemName: item.systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: RailMetrics.iconSize, height: RailMetrics.iconSize)
                    .foregroundStyle(filled ? Theme.Palette.accentText
                                     : (focused ? Theme.Palette.onFocusPlatter : Theme.Palette.textPrimary))
                    .modifier(RailRestingGlyphShadow(enabled: isCorner, visible: bare))
            }
        }
    }

    private func itemTitle(_ item: RailItem) -> String {
        if item.id == RailItem.profile.id, let profile = activeProfile, !profile.name.isEmpty {
            return profile.name
        }
        return item.localizedTitle
    }

    /// Harness-readable state probe, the house pattern (invisible, tiny, non-zero opacity so it is
    /// not culled). Append-only: existing tokens keep their names, values and order. `focused` is the
    /// `@FocusState` value (-1 = none), readable on the tvOS 27.0 simulator where `hasFocus` is not.
    /// Batch O review r1: `glass=` is `glassOpacity` and `selrow=` the selected tab's
    /// `rowOpacity` (0 or 1; reported whether or not the pill is shown), the values the glass and
    /// that row draw with.
    @ViewBuilder
    private var stateProbe: some View {
        #if DEBUG
        Text(verbatim: "rail_state armed=\(armed ? 1 : 0) expanded=\(expanded ? 1 : 0) focused=\(focusedItem ?? -1) reason=\(openedBy?.rawValue ?? "-") gated=\(chrome.contentGated ? 1 : 0) vis=\(visibility.rawValue) shown=\(shown ? 1 : 0) tab=\(selectedTab) route=\(lastExitRoute) inset=\(Int(contentInset.rounded())) gmode=\(RailGateMode.current.rawValue) kb=\(chrome.searchKeyboardFocused ? 1 : 0) pos=\(position.rawValue) glass=\(Int(glassOpacity)) selrow=\(Int(rowOpacity(order: selectedRowOrder)))")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("rail_state")
            .allowsHitTesting(false)
        #endif
    }

    // MARK: Arming (P4 §2.2)

    /// A move the focus engine could not place. Inside the rail it is Right's exit (or contained);
    /// outside it may arm the rail on a plain Left from the leftmost item of a tab's content.
    private func handleMoveFailed(_ note: Notification) {
        guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
        let heading = context.focusHeading
        if focusedItem != nil {
            switch RailFocusPolicy.moveFailedInRail(heading: heading) {
            case .exitToContent:
                exitRail(to: selectedTab, via: "right")
            case .contained:
                NSLog("[NavRail] contained heading=%@", Self.headingName(heading))
            }
            return
        }
        // Cheap first: most failed moves (Up at the top of a page, Down at the bottom) end here.
        guard heading.contains(.left) else { return }
        let originItem = context.previouslyFocusedItem ?? HiddenTabBarFocusBlocker.currentFocusedItem()
        let origin: UIFocusEnvironment? = originItem.map { $0 as UIFocusEnvironment }
        let route = chrome.topReturnRoute(tab: selectedTab)
        let railMode = NavigationChrome.isRail()
        let holds = armed || chrome.isFocusedChrome
        let inContent = HiddenTabBarFocusBlocker.focusItemIsInTabContent(origin)
        let presented = HiddenTabBarFocusBlocker.isPresentedOverShell()
        let vetoed = route?.vetoesLeftArm() ?? false
        guard RailFocusPolicy.shouldArm(heading: heading, railMode: railMode, railHoldsFocus: holds,
                                        originInTabContent: inContent, presentedOverShell: presented,
                                        vetoed: vetoed) else {
            if vetoed, RailFocusPolicy.shouldArm(heading: heading, railMode: railMode, railHoldsFocus: holds,
                                                  originInTabContent: inContent, presentedOverShell: presented,
                                                  vetoed: false) {
                NSLog("[NavRail] veto origin=%@ route=%@", Self.typeName(origin), route?.name ?? "-")
            } else if railMode, !holds, heading == .left {
                // A plain Left at an edge that did not arm (Probe G / the gate A/B read this): the
                // origin check fails closed, so a hierarchy surprise shows up here, not as silence.
                NSLog("[NavRail] no-arm origin=%@ inContent=%d presented=%d",
                      Self.typeName(origin), inContent ? 1 : 0, presented ? 1 : 0)
            }
            return
        }
        arm(.left, origin: Self.typeName(origin))
    }

    /// Arm sequence (P4 §2.2): capture the return target while focus is still on the origin, make
    /// the items Buttons, show the pill over every hide term, then take focus.
    private func arm(_ reason: RailOpenReason, origin: String) {
        guard NavigationChrome.isRail() else { return }
        // Already open, or an arm in flight: nothing to do (the first reason stands).
        guard focusedItem == nil, !armed else { return }
        // Only a Left or a Menu starts from content; a redirect starts in the hidden bar and a
        // re-arm from nowhere, and capturing then would overwrite a good target with nothing.
        if reason == .left || reason == .menu {
            chrome.topReturnRoute(tab: selectedTab)?.capture()
        }
        slideAnimation = defaultSlide
        // FEAT-80 Corner (review r1 P3-1): read before `armed` flips, which shows the pill over
        // every hide term.
        cornerArmedAtRest = shown
        armed = true
        revealed = true
        openedBy = reason
        NSLog("[NavRail] arm reason=%@ origin=%@ tab=%ld", reason.rawValue, origin, selectedTab)
        takeFocusAfterReveal()
    }

    /// S1 W2: focus landed on the hidden system tab bar (see `HiddenTabBarRedirect`): open the rail
    /// and take focus onto its item, instead of leaving focus on an invisible button.
    private func revealForStrandedFocus() {
        guard HiddenTabBarRedirect.shouldReveal(
            landedInHiddenBar: true,
            railMode: NavigationChrome.isRail(),
            railHoldsFocus: chrome.isFocusedChrome
        ) else { return }
        guard rescueGuard.allowsReveal(now: ProcessInfo.processInfo.systemUptime) else {
            NSLog("[NavRail] focus landed on the hidden tab bar right after a failed rescue; not revealing again")
            return
        }
        NSLog("[NavRail] focus landed on the hidden tab bar; revealing the rail")
        chrome.requestReveal(.hiddenBarRedirect)
    }

    /// Programmatic `@FocusState` write after an arm (ported from FEAT-30's `takeFocusAfterReveal`).
    /// The Buttons do not exist on the turn that arms them, so the first write goes on the next
    /// turn, with one retry 0.15 s later (BUG-27: a one-shot grab a hair too early is silently
    /// dropped). Fail closed: if both writes are dropped, disarm, so the rail never stays armed at
    /// rest (the launch focus steal `armed` exists to prevent). Always the selected tab's item,
    /// shown or slid out: focus wins over every hide term.
    ///
    /// Batch O review r1 P2-2: one `[NavRail] focus write=<1|2> tab=<id> landed=<0|1>` line per
    /// write, every build, read where the next step checks it (write 1 at +0.15 s, write 2 at
    /// +0.45 s), so a device pass can confirm write 1 lands on every tab.
    private func takeFocusAfterReveal() {
        focusGeneration &+= 1
        let generation = focusGeneration
        DispatchQueue.main.async {
            guard generation == focusGeneration, armed, focusedItem == nil else { return }
            let firstTab = selectedTab
            focusedItem = firstTab
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard generation == focusGeneration else { return }
                Self.logFocusWrite(1, tab: firstTab, landed: focusedItem != nil)
                guard armed, focusedItem == nil else { return }
                let secondTab = selectedTab
                focusedItem = secondTab
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard generation == focusGeneration else { return }
                    Self.logFocusWrite(2, tab: secondTab, landed: focusedItem != nil)
                    guard armed, focusedItem == nil else { return }
                    NSLog("[NavRail] arm could not take focus; disarming")
                    slideAnimation = defaultSlide
                    armed = false
                    revealed = false
                    openedBy = nil
                    // r3b P2-2: if nothing holds focus, put default placement back in content rather
                    // than leave the BUG-47 dead end. S1 W2 (review r1 P3-3): the same when focus
                    // sits on the invisible hidden-bar button a stranded reveal was meant to rescue.
                    let strandedInBar = HiddenTabBarFocusBlocker.focusedItemIsInHiddenBar()
                    if strandedInBar { rescueGuard.rescueFailed(now: ProcessInfo.processInfo.systemUptime) }
                    if HiddenTabBarFocusBlocker.focusedItemIsNil() || strandedInBar {
                        resetFocus(in: shellFocusScope)
                    }
                }
            }
        }
    }

    /// The gate's only driver (P4 §2.1 invariant: closed while a rail item holds focus). A cover,
    /// alert or popover that takes focus therefore always reopens content.
    private func focusChanged(old: Int?, new: Int?) {
        if old == nil, new != nil {
            chrome.setFocusedChrome(true)
            RailContentGate.set(true, chrome: chrome)
        } else if new == nil {
            chrome.setFocusedChrome(false)
            RailContentGate.set(false, chrome: chrome)
            slideAnimation = defaultSlide
            armed = false
            revealed = false
            openedBy = nil
        }
    }

    // MARK: Inside the rail (P4 §2.4)

    private func selectItem(_ id: Int) {
        switch RailFocusPolicy.select(item: id, currentTab: selectedTab) {
        case .switchTab(let tab):
            NSLog("[NavRail] select tab=%ld from=%ld", tab, selectedTab)
            selectedTab = tab
            exitRail(to: tab, via: "select")
        case .returnToCurrent:
            exitRail(to: selectedTab, via: "select")
        }
    }

    /// R4: Menu closes a rail that Left opened; anywhere else it is the system default (nil).
    private var menuHandler: (() -> Void)? {
        guard let openedBy, RailFocusPolicy.menuInRail(openedBy: openedBy) == .closeToContent else { return nil }
        return { exitRail(to: selectedTab, via: "menu") }
    }

    // MARK: Exit and restoration (P4 §2.5)

    /// Opens the gate while the rail still holds focus, then, one turn later (the `perTab` gate's
    /// `.disabled` must have re-rendered before a focus write can land), asks the tab's top route to
    /// put focus back. The route's write moves focus off the rail, which disarms it. If focus is
    /// still in the rail 0.5 s later, or there is no route, the default hand-off runs.
    private func exitRail(to tab: Int, via: String) {
        focusGeneration &+= 1
        let generation = focusGeneration
        RailContentGate.set(false, chrome: chrome)
        DispatchQueue.main.async {
            guard generation == focusGeneration else { return }
            let route = chrome.topReturnRoute(tab: tab)
            let name = route?.name ?? "none"
            lastExitRoute = name
            if let route, route.restore() {
                NSLog("[NavRail] exit via=%@ route=%@ result=focus", via, name)
                DispatchQueue.main.asyncAfter(deadline: .now() + RailMetrics.exitVerifyDelay) {
                    guard generation == focusGeneration, focusedItem != nil else { return }
                    NSLog("[NavRail] exit via=%@ route=%@ result=fallback (focus stayed in the rail)", via, name)
                    fallbackHandOff(tab: tab)
                }
            } else {
                NSLog("[NavRail] exit via=%@ route=%@ result=fallback", via, name)
                fallbackHandOff(tab: tab)
            }
        }
    }

    /// The default hand-off (FEAT-30's `handOffFocusToContent`, S1 W2's ladder): drop the items'
    /// focusability so the engine must leave the rail, re-run default focus placement for the whole
    /// shell, and VERIFY — the destination tab may still be building, and a reset issued before
    /// anything focusable exists leaves no focused item (the BUG-47 dead end). Each check but the
    /// last re-issues the reset while focus is still nowhere; at the last, the rail re-arms and takes
    /// focus back. `SidebarHandOffLadder`: 1.0 s, or 2.5 s on Search, whose system keyboard arrives
    /// 1–2 s after the tab opens.
    private func fallbackHandOff(tab: Int) {
        // Internal review r3 (P1-2b): default placement is only safe while the hidden bar cannot be
        // its first candidate. Without the blocker, keep focus in the rail (and gated).
        guard HiddenTabBarFocusBlocker.isBlocking else {
            NSLog("[NavRail] hand-off skipped: hidden bar not blocked; focus stays in the rail")
            if focusedItem != nil { RailContentGate.set(true, chrome: chrome) }
            return
        }
        slideAnimation = defaultSlide
        armed = false
        focusedItem = nil
        revealed = false
        focusGeneration &+= 1
        let generation = focusGeneration
        DispatchQueue.main.async {
            guard generation == focusGeneration else { return }
            let ladderTag = tab == RailVisibilityRule.searchTab ? "[SearchOpen]" : "[NavRail]"
            if SearchOpenProbe.enabled { NSLog("%@ ladder rung 0 reset tab=%ld t=%.3f", ladderTag, tab, ProcessInfo.processInfo.systemUptime) }
            resetFocus(in: shellFocusScope)
            let checks = SidebarHandOffLadder.checks(forTabTitled: RailItem.title(for: tab))
            for (index, delay) in checks.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard generation == focusGeneration else { return }
                    guard focusedItem == nil, !armed else { return }   // an arm took over meanwhile
                    guard HiddenTabBarFocusBlocker.focusedItemIsNil() else {
                        if SearchOpenProbe.enabled { NSLog("%@ ladder rung %ld at %.2fs: focus already landed t=%.3f", ladderTag, index + 1, delay, ProcessInfo.processInfo.systemUptime) }
                        return
                    }
                    if SearchOpenProbe.enabled { NSLog("%@ ladder rung %ld at %.2fs: still nowhere t=%.3f", ladderTag, index + 1, delay, ProcessInfo.processInfo.systemUptime) }
                    if index < checks.count - 1 {
                        resetFocus(in: shellFocusScope)
                    } else {
                        NSLog("[NavRail] hand-off landed nowhere after %.2f s; re-arming the rail", delay)
                        arm(.rearm, origin: "handoff")
                    }
                }
            }
        }
    }

    /// The app-root deep-link cover took the screen while the rail held focus. Focus wins over the
    /// hide terms on purpose (never unmount a focused view), but the rail is now BEHIND a presented
    /// controller and would keep reporting itself focused (internal review r3 P2-6). Release.
    private func releaseFocusForCover() {
        guard focusedItem != nil || armed || revealed else { return }
        focusGeneration &+= 1
        slideAnimation = defaultSlide
        focusedItem = nil
        armed = false
        revealed = false
        openedBy = nil
        chrome.setFocusedChrome(false)
        RailContentGate.set(false, chrome: chrome)
    }

    // MARK: Hide While Browsing (P4 §5.2)

    /// Drives `restingShown` from the current tab's mirror. A scroll crossing hides at once and shows
    /// after `restingShowSettle` of continuously-not-scrolled; a Stage page write moves both edges
    /// with the page's own curve and duration and skips the settle (#8). `seeded` is the first read
    /// on a fresh mount: nothing to absorb there, and a slide at cold launch would be a new
    /// complaint, so it resolves at once, unanimated.
    private func updateRestingVisibility(seeded: Bool = false) {
        let scrolledDown = chrome.scrolledDownByTab[selectedTab] ?? false
        // Retire any settle in flight: whatever it was going to conclude is about to be restated.
        restingGeneration &+= 1
        // FEAT-62: Hidden has nothing to slide. `RailVisibilityRule.shown` ignores the resting
        // mirror for it, so the mirror is parked at its neutral value, unanimated, and no settle
        // is scheduled: a scroll crossing must never retarget `slideAnimation` under a reveal.
        if visibility == .hidden {
            if !restingShown { restingShown = true }
            return
        }
        if seeded {
            slideAnimation = nil
            restingShown = !scrolledDown
            return
        }
        if case .page(let seconds)? = chrome.motionByTab[selectedTab] {
            slideAnimation = seconds > 0 ? .easeOut(duration: seconds) : nil
            restingShown = !scrolledDown
            return
        }
        slideAnimation = defaultSlide
        guard !scrolledDown else {
            restingShown = false                     // HIDE edge: immediate, always.
            return
        }
        guard !restingShown else { return }          // already shown: a re-cross must not blink it
        let generation = restingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + RailMetrics.restingShowSettle) {
            guard generation == restingGeneration else { return }
            // Re-read live: only "still not scrolled down, right now" earns the show.
            guard !(chrome.scrolledDownByTab[selectedTab] ?? false) else { return }
            slideAnimation = defaultSlide
            restingShown = true
        }
    }

    // MARK: Log helpers

    /// `takeFocusAfterReveal`'s per-write line (review r1 P2-2).
    private static func logFocusWrite(_ write: Int, tab: Int, landed: Bool) {
        NSLog("[NavRail] focus write=%ld tab=%ld landed=%d", write, tab, landed ? 1 : 0)
    }

    private static func headingName(_ heading: UIFocusHeading) -> String {
        if heading.contains(.left) { return "left" }
        if heading.contains(.right) { return "right" }
        if heading.contains(.up) { return "up" }
        if heading.contains(.down) { return "down" }
        return "other"
    }

    private static func typeName(_ item: UIFocusEnvironment?) -> String {
        guard let item else { return "nil" }
        return String(describing: type(of: item))
    }
}

// MARK: - Tab roots (P4 §5.1)

/// Applied inside every `Tab {}` closure in `MainTabView`, after `.tabBarImmersiveHide()`. Rail mode
/// only (structural: Tabs mode gets no modifier at all). Launch-constant inputs only (the mode and
/// the visibility change only across `ContentView`'s `.id` remount), so it never re-evaluates a
/// `Tab` closure (T3 / BUG-66).
private struct RailTabRootModifier: ViewModifier {
    let index: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if NavigationChrome.isRail() {
            content
                .environment(\.railTabIndex, index)
                .modifier(RailReservedWidthModifier(index: index))
                .modifier(RailContentGateModifier())
        } else {
            content
        }
    }
}

/// R3: Always Visible reserves the rail's width as extra LEADING SAFE AREA: `ignoresSafeArea()`
/// backgrounds (Home's hero art, Stage's art and wash, Detail's backdrop) still reach x = 0 behind
/// the rail, while content moves 140 → 176 pt from the bezel. The safe area itself is UIKit's, set
/// on the shell's tab controller (`HiddenTabBarFocusBlocker.setReservedLeadingInset`): a SwiftUI
/// `.safeAreaPadding` here never reached past a tab's NavigationStack or into `.searchable`'s
/// container (W3's Rail08 and Probe I). This modifier carries the environment half: Stage and the
/// folder Rows page ignore the safe area by design and read the same 36 pt from
/// `\.railLeadingInset` (R1), and `\.rowEdgeMargins` tells the rows where the visible edge is.
/// Environment values flow into NavigationStack destinations, so pushed pages inherit both.
///
/// B4: on the Search tab the environment half follows the shell's keyboard collapse (36 → 0 while
/// the system keyboard holds focus), through a narrow subscription to `$searchKeyboardFocused` that
/// re-renders this modifier only, never `MainTabView`. Every other tab, and Search under the
/// `-debug.railSearchInsetHold` knob, stays launch-constant.
private struct RailReservedWidthModifier: ViewModifier {
    let index: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if NavigationChrome.reservesWidth() {
            if index == RailVisibilityRule.searchTab, !RailSearchInsetHold.current {
                content.modifier(RailSearchReservedWidth())
            } else {
                content.modifier(RailReservedWidthValues(reserves: true))
            }
        } else {
            content
        }
    }
}

/// The two environment values for a reserved (or, B4, collapsed) width.
private struct RailReservedWidthValues: ViewModifier {
    let reserves: Bool

    func body(content: Content) -> some View {
        let side = PinnedRowGeometry.sideSafeArea
        // FEAT-80: only ever applied in Centre (`reservesWidth()` is false in Corner); the position
        // is passed through anyway, so the two halves cannot disagree.
        let position = NavigationChrome.railPosition()
        content
            .environment(\.railLeadingInset, NavigationChrome.contentSafeAreaExtra(sideSafeArea: side, reservesWidth: reserves,
                                                                                   position: position))
            .environment(\.rowEdgeMargins, NavigationChrome.rowEdgeMargins(sideSafeArea: side, reservesWidth: reserves,
                                                                           position: position))
    }
}

/// B4: the Search tab root's environment half, collapsed while the system keyboard holds focus.
private struct RailSearchReservedWidth: ViewModifier {
    @Environment(\.navigationChrome) private var chrome
    @State private var keyboardFocused = false

    func body(content: Content) -> some View {
        content
            .modifier(RailReservedWidthValues(reserves: !keyboardFocused))
            // Payload, not the property: `@Published` emits on willSet.
            .onReceive(chrome.$searchKeyboardFocused) { keyboardFocused = $0 }
    }
}

/// P4 §2.3's fallback gate, selected by `-debug.railGate perTab` (DEBUG). Absent in the primary mode.
private struct RailContentGateModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if RailGateMode.current == .perTab {
            content.modifier(RailPerTabGate())
        } else {
            content
        }
    }
}

/// `.disabled` on one tab root while the content gate is closed: the spike's device-proven mechanism
/// (`StageStripSpike.swift:273`). A narrow subscription to `$contentGated` alone, so a gate change
/// re-renders this modifier, never `MainTabView`.
private struct RailPerTabGate: ViewModifier {
    @Environment(\.navigationChrome) private var chrome
    @State private var gated = false

    func body(content: Content) -> some View {
        content
            .disabled(gated)
            // Payload, not the property: `@Published` emits on willSet.
            .onReceive(chrome.$contentGated) { gated = $0 }
    }
}

/// Registers a screen's return route on its tab while it is on screen (pushed on appear, removed on
/// disappear, so a push over the screen takes it off the top). Rail mode only, and only inside the
/// shell (`\.railTabIndex` is nil elsewhere, e.g. a Top Shelf deep link's own stack).
private struct RailReturnRouteModifier: ViewModifier {
    let makeRoute: () -> RailReturnRoute
    @Environment(\.navigationChrome) private var chrome
    @Environment(\.railTabIndex) private var tab
    @State private var token = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if NavigationChrome.isRail() {
            content
                .onAppear {
                    guard let tab else { return }
                    chrome.pushReturnRoute(tab: tab, token: token, makeRoute())
                }
                .onDisappear {
                    guard let tab else { return }
                    chrome.removeReturnRoute(tab: tab, token: token)
                }
        } else {
            content
        }
    }
}

// MARK: - Tab-root Menu grammar

/// Rail-mode Menu grammar for a tab root: Menu opens (and focuses) the rail instead of falling
/// through to the system's "suspend the app". Structurally absent in Tabs mode: no modifier at all
/// is the only provably byte-identical form, and the mode never flips mid-session.
///
/// The rail installs a Menu handler of its own only when Left opened it (R4); otherwise Menu in the
/// rail falls through to the system default, the same "focus is on root chrome, Menu exits" the tab
/// bar has. So: Menu at a root → rail; Menu again → exit.
///
/// Up never opens the rail, gated or not (BUG-98, the 2026-09-05 → 09-09 arc): a 0.45 s
/// "deliberate Up" gate could not tell a Siri Remote swipe's momentum from a press, removing the
/// gate made the reveal open "no matter where he is" (rc7 verdict), and Christian's call was Menu
/// only. The rail adds a failed Left, never an Up.
private struct RailMenuRevealModifier: ViewModifier {
    @Environment(\.navigationChrome) private var chrome

    @ViewBuilder
    func body(content: Content) -> some View {
        if NavigationChrome.isRail() {
            content
                .onExitCommand {
                    // Read inside the closure, never as a body dependency: `@Environment` hands over
                    // the object without subscribing. With focus in the rail this handler is not in
                    // its responder chain at all; the guard is belt and braces.
                    guard !chrome.isFocusedChrome else { return }
                    chrome.requestReveal(.menu)
                }
        } else {
            content
        }
    }
}

/// Compensates the tab shell's top safe area when the system tab bar is hidden by Rail mode. Ships as
/// 0 (`Theme.Size.sidebarTopCompensation`), so it applies literally nothing in either mode.
private struct RailTopCompensationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if NavigationChrome.isRail(), NavigationChrome.topCompensation > 0 {
            content.safeAreaPadding(.top, NavigationChrome.topCompensation)
        } else {
            content
        }
    }
}

extension View {
    /// Inside every `Tab {}` closure, after `.tabBarImmersiveHide()`.
    func railTabRoot(_ index: Int) -> some View {
        modifier(RailTabRootModifier(index: index))
    }

    /// On a tab root (Search, Library, Add-ons, the Settings root, Profile). Home composes the same
    /// reveal by hand (Classic's exit handler carries BUG-27's Menu-to-top branch; Stage's strip
    /// pages to row 0 first).
    func railMenuReveal() -> some View {
        modifier(RailMenuRevealModifier())
    }

    /// On the tab shell's `TabView` in `MainTabView`.
    func railTopCompensation() -> some View {
        modifier(RailTopCompensationModifier())
    }

    /// Registers this screen's return route (P4 §2.5). `makeRoute` is called on appear.
    func railReturnRoute(_ makeRoute: @escaping () -> RailReturnRoute) -> some View {
        modifier(RailReturnRouteModifier(makeRoute: makeRoute))
    }
}

// MARK: - Item style

/// The rail's focused-row treatment, carried over from FEAT-30's sidebar: focused = a white capsule
/// behind the whole row (glyph and label) with dark content; unfocused = the plain row.
///
/// WHY A CUSTOM `ButtonStyle` (HIG hybrid contract: custom styles only where a system style
/// demonstrably can't express it, documented in the style file). The rail first shipped with
/// system `.borderless`, and the end-of-Wave-2 simulator walk (2026-10-05) showed why that fails
/// here: `.borderless` draws no platter, only brightens and scales the label. On the glass panel
/// a focused text row looked exactly like an unfocused one (the profile row read as unfocused
/// while it held focus), and the icon rows got a lumpy white blob behind the glyph alone. The
/// other system styles fail for the reasons FEAT-30 recorded: `.bordered`/`.card` draw a
/// system-sized rounded RECT that reads as a second panel stacked on the glass, and `.glass`
/// composites glass-on-glass into a smear. The capsule still speaks the system focus language
/// (white platter, dark label, no accent ring, no tilt), confined to this one chrome.
///
/// `isFocused` is passed in from the rail's own `@FocusState`, never read from
/// `@Environment(\.isFocused)`: that read is device-unreliable (BUG-65, white-on-white on
/// hardware with the simulator unable to reproduce it).
struct RailItemButtonStyle: ButtonStyle {
    let isFocused: Bool
    /// Review r1 (B P3-8): no press scale under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isFocused {
                    Capsule(style: .continuous)
                        .fill(Color.white)
                        .padding(.horizontal, -RailItemButtonStyle.platterOutsetH)
                        .padding(.vertical, -RailItemButtonStyle.platterOutsetV)
                }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed && !reduceMotion)
    }

    /// The capsule reaches a little past the row so the glyph is not flush with its rounded end.
    static let platterOutsetH: CGFloat = 4
    static let platterOutsetV: CGFloat = 2
}

/// FEAT-80 Corner (Batch O): the resting Home glyph's soft shadow, on the glyph alone, so the bare
/// icon reads on bright artwork. `enabled` is the position (launch-constant: it joins
/// `ContentView`'s remount key), so Centre's glyphs carry no shadow modifier at all; `visible` is
/// `cornerResting`, false on every armed Button.
private struct RailRestingGlyphShadow: ViewModifier {
    let enabled: Bool
    let visible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.shadow(color: Color.black.opacity(visible ? RailMetrics.cornerGlyphShadowOpacity : 0),
                           radius: RailMetrics.cornerGlyphShadowRadius,
                           x: 0, y: RailMetrics.cornerGlyphShadowY)
        } else {
            content
        }
    }
}
