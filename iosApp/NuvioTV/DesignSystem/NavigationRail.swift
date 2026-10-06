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

    /// Search & Discover A6: the Discover tab, selection value 6, shown right after Search when
    /// Discover is placed on its own tab (`DiscoverPlacement.ownTab`).
    static let discover = RailItem(id: 6, title: "Discover", systemImage: "safari")

    /// Home, Search, (Discover), Library, Add-ons, Settings: titles and SF Symbols identical to
    /// `MainTabView`'s `Tab` declarations. If a tab is added, renamed or reordered there, this list
    /// moves with it. Variable length: the pill is a VStack sized by its items (6 items plus the
    /// avatar is ≈ 552 pt), nothing assumes a count.
    static func tabs(showsDiscover: Bool) -> [RailItem] {
        var items: [RailItem] = [
            RailItem(id: 0, title: "Home", systemImage: "house"),
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
/// The three the inset math needs are mirrored on `NavigationChrome`.
private enum RailMetrics {
    static let bezelInset: CGFloat = NavigationChrome.bezelInset            // 16
    static let collapsedWidth: CGFloat = NavigationChrome.collapsedWidth    // 84
    /// Grows rightward only; the height never changes, so no item moves vertically.
    static let expandedWidth: CGFloat = 300
    static let innerPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 22
    /// The circle behind each glyph; the selected tab's is filled.
    static let itemPlatter: CGFloat = 60
    static let iconSize: CGFloat = 36
    static let itemSpacing: CGFloat = 14
    /// Extra space above the profile avatar.
    static let avatarGap: CGFloat = 18
    static let labelGap: CGFloat = 18
    static let cornerRadius: CGFloat = 42
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
                                                selectedTab: selectedTab,
                                                keyboardFocused: chrome.searchKeyboardFocused,
                                                holdInset: RailSearchInsetHold.current)
    }

    /// R3: what Always Visible adds to every tab root's leading safe area (36), for the probe.
    private var contentInset: CGFloat {
        NavigationChrome.contentSafeAreaExtra(sideSafeArea: PinnedRowGeometry.sideSafeArea,
                                              reservesWidth: visibility == .always)
    }

    /// A6: the item list for this tree's tabs.
    private var railItems: [RailItem] {
        RailItem.tabs(showsDiscover: showsDiscover)
    }

    private var defaultSlide: Animation {
        .easeOut(duration: RailMetrics.slideDuration)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The dim: always mounted at opacity 0, so it cross-fades with or without Reduce Motion
            // (#20). Behind the pill, never hit-testable, never focusable.
            Color.black
                .opacity(expanded ? RailMetrics.dimOpacity : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(.easeOut(duration: RailMetrics.expandDuration), value: expanded)
            if shown {
                pill
                    .padding(.leading, RailMetrics.bezelInset)
                    .transition(reduceMotion ? AnyTransition.opacity
                                : AnyTransition.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(slideAnimation, value: shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        .onChange(of: focusedItem) { old, new in
            focusChanged(old: old, new: new)
        }
    }

    // MARK: Layout

    /// The glass is a BACKGROUND behind the buttons, never a `glassEffect` around them: wrapping
    /// focusable content in glass hid it from the focus engine in another tvOS app (the Orivio
    /// trap, `docs/research/orivio-tv-handoff.md`).
    private var pill: some View {
        VStack(alignment: .leading, spacing: RailMetrics.itemSpacing) {
            ForEach(railItems) { item in
                itemView(item)
            }
            itemView(RailItem.profile)
                .padding(.top, RailMetrics.avatarGap)
        }
        .padding(.vertical, RailMetrics.verticalPadding)
        .padding(.horizontal, RailMetrics.innerPadding)
        .frame(width: expanded ? RailMetrics.expandedWidth : RailMetrics.collapsedWidth, alignment: .leading)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: RailMetrics.cornerRadius, style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: RailMetrics.cornerRadius, style: .continuous))
            #if DEBUG
            // Rail08's oracle: the pill's own frame. `navigation_rail` is a `.contain` container,
            // whose accessibility frame is the union of its children, and the collapsed pill's
            // labels (laid out, faded) overflow its 84 pt width.
            Color.white.opacity(0.001)
                .accessibilityElement()
                .accessibilityLabel("rail bounds")
                .accessibilityIdentifier("navigation_rail_bounds")
            #endif
        }
        // #20: Reduce Motion drops the width animation; the labels and the dim still cross-fade
        // (their own animations).
        .animation(reduceMotion ? nil : .easeOut(duration: RailMetrics.expandDuration), value: expanded)
        // One focus section: moves inside stay inside, and with content gated a move out fails,
        // which is what the rail's app-handled exits listen for.
        .focusSection()
        // R4: a handler only when Left opened the rail; otherwise nil, the system default.
        .onExitCommand(perform: menuHandler)
        // `.contain`, so the pill has its own element without clobbering the per-item identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navigation_rail")
    }

    @ViewBuilder
    private func itemView(_ item: RailItem) -> some View {
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
        } else {
            // Not armed: the same look and geometry, but nothing the engine can land on.
            itemLabel(item, focused: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("rail_item_\(item.title)")
        }
    }

    private func itemLabel(_ item: RailItem, focused: Bool) -> some View {
        let selected = item.id == selectedTab
        let width = (expanded ? RailMetrics.expandedWidth : RailMetrics.collapsedWidth) - 2 * RailMetrics.innerPadding
        return HStack(spacing: RailMetrics.labelGap) {
            itemGlyph(item, selected: selected, focused: focused)
                .frame(width: RailMetrics.itemPlatter, height: RailMetrics.itemPlatter)
            // Always mounted at its full width, faded in and out with the expansion (#20); it draws
            // past the collapsed frame only while invisible.
            Text(itemTitle(item))
                .font(Theme.Font.body)
                .foregroundStyle(focused ? Theme.Palette.onFocusPlatter : Theme.Palette.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .opacity(expanded ? 1 : 0)
                .animation(.easeOut(duration: RailMetrics.expandDuration), value: expanded)
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func itemGlyph(_ item: RailItem, selected: Bool, focused: Bool) -> some View {
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
                Circle().fill(selected ? Theme.Palette.accent : Color.clear)
                Image(systemName: item.systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: RailMetrics.iconSize, height: RailMetrics.iconSize)
                    .foregroundStyle(selected ? Theme.Palette.accentText
                                     : (focused ? Theme.Palette.onFocusPlatter : Theme.Palette.textPrimary))
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
    @ViewBuilder
    private var stateProbe: some View {
        #if DEBUG
        Text(verbatim: "rail_state armed=\(armed ? 1 : 0) expanded=\(expanded ? 1 : 0) focused=\(focusedItem ?? -1) reason=\(openedBy?.rawValue ?? "-") gated=\(chrome.contentGated ? 1 : 0) vis=\(visibility.rawValue) shown=\(shown ? 1 : 0) tab=\(selectedTab) route=\(lastExitRoute) inset=\(Int(contentInset.rounded())) gmode=\(RailGateMode.current.rawValue) kb=\(chrome.searchKeyboardFocused ? 1 : 0)")
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
    private func takeFocusAfterReveal() {
        focusGeneration &+= 1
        let generation = focusGeneration
        DispatchQueue.main.async {
            guard generation == focusGeneration, armed, focusedItem == nil else { return }
            focusedItem = selectedTab
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard generation == focusGeneration, armed, focusedItem == nil else { return }
                focusedItem = selectedTab
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard generation == focusGeneration, armed, focusedItem == nil else { return }
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
            resetFocus(in: shellFocusScope)
            let checks = SidebarHandOffLadder.checks(forTabTitled: RailItem.title(for: tab))
            for (index, delay) in checks.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard generation == focusGeneration else { return }
                    guard focusedItem == nil, !armed else { return }   // an arm took over meanwhile
                    guard HiddenTabBarFocusBlocker.focusedItemIsNil() else { return }
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
        content
            .environment(\.railLeadingInset, NavigationChrome.contentSafeAreaExtra(sideSafeArea: side, reservesWidth: reserves))
            .environment(\.rowEdgeMargins, NavigationChrome.rowEdgeMargins(sideSafeArea: side, reservesWidth: reserves))
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
