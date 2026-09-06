import Combine
import SwiftUI
import UIKit

// MARK: - Mode

/// FEAT-30: the opt-in "Omni-style" floating sidebar that replaces the tvOS system tab bar.
///
/// The mode is a DEVICE-LOCAL `UserDefaults` string (`sidebar_style`), `"tabs"` (default) or
/// `"sidebar"` — same shape as `Theme.AppFontFamily`'s `ui_font` key, and device-local for the
/// same reason: which chrome a given living-room TV shows is a per-device display preference, not
/// account state.
///
/// EVERY read of this flag must resolve to `false` on an untouched install, and everything the
/// feature adds is structurally absent in that case — the tab shell must stay byte-identical in
/// tabs mode. That is why the call sites below branch STRUCTURALLY (`if enabled { content.modifier
/// } else { content }`) rather than passing an inert value into a modifier that is always applied:
/// a `.onExitCommand(perform: nil)` or a `.safeAreaPadding(.top, 0)` is *probably* a no-op, and
/// "probably" is not the standard this shell is held to (see `TabBarVisibility`'s BUG-66
/// archaeology for what a mid-session preference re-resolution costs).
///
/// Reading it live (a `UserDefaults` lookup) rather than launch-latching it is deliberate and is
/// the counterpart to `ContentView`'s `.id(theme|sidebar|font)` remount: the mode may only change
/// across a remount, and a `static let` would NOT re-run on one (a remount re-creates views, not
/// type storage), so a latched value would leave the shell half-switched until relaunch.
enum SidebarChrome {
    static let defaultsKey = "sidebar_style"
    /// The one value that turns the sidebar on. Anything else — missing key, `"tabs"`, a corrupted
    /// or future string — is tabs mode, never an unknown third state.
    static let sidebarValue = "sidebar"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: defaultsKey) == sidebarValue
    }

    /// See `Theme.Size.sidebarTopCompensation` — the constant itself lives with the rest of the
    /// pinned-hero viewport arithmetic it has to stay consistent with. Surfaced here so every
    /// FEAT-30 call site reads one namespace.
    static var topCompensation: CGFloat { Theme.Size.sidebarTopCompensation }
}

// MARK: - Shared chrome state

/// The sidebar's cross-screen state: which tab roots are scrolled down (so the sidebar can get out
/// of the way while the user browses rows) and the Menu-press reveal request.
///
/// Held as `@State private var sidebarChrome = SidebarChromeModel()` on `MainTabView` — `@State`
/// on a reference type, NOT `@StateObject`, for exactly the reason `MainTabView.tabBarVisibility`
/// is (T3 / BUG-66, see its doc comment): `@State` stores the same instance for the same lifetime
/// but does NOT subscribe the shell to `objectWillChange`. With `@StateObject`, every scroll
/// crossing on any tab would invalidate `MainTabView` and re-evaluate all six `Tab` closures,
/// which is the exact mechanism that re-resolved `.toolbarVisibility` mid-transition and latched
/// the system tab bar mid-slide on hardware. `SidebarOverlay` is the ONLY view that observes this
/// object (via `@ObservedObject`), and it sits in the TabView's `.overlay` — outside every `Tab`
/// closure — so its publishes can only re-render the sidebar itself.
@MainActor
final class SidebarChromeModel: ObservableObject {
    /// Per-tab mirror of `TabBarScrollAutoHide`'s hysteresis latch, keyed by tab VALUE (Home 0 …
    /// Add-ons 3). Per-tab, never one shared slot: T2 retired exactly that design on
    /// `TabBarVisibility` because four independently scrolling tabs make a single slot
    /// last-writer-wins.
    @Published var scrolledDownByTab: [Int: Bool] = [:]
    /// Bumped by a Menu press at a tab root. A counter, not a `Bool`: two consecutive Menu presses
    /// while the sidebar is already revealed-but-unfocused must both be observable, and a `Bool`
    /// would need a reset dance the presses could race.
    @Published var revealRequest: Int = 0
    /// True while the sidebar itself holds focus. Written by `SidebarOverlay`; read by the tab
    /// roots' Menu handlers WITHOUT observation (they hold the model through `@Environment`, which
    /// does not subscribe), so a focus change inside the sidebar never invalidates a tab root.
    @Published var isFocusedChrome: Bool = false

    /// Write-on-change only. `@Published` does not dedupe, and the scroll callback that feeds this
    /// fires on crossings — a same-value write would still broadcast.
    func setScrolledDown(tab: Int, _ value: Bool) {
        guard scrolledDownByTab[tab] != value else { return }
        scrolledDownByTab[tab] = value
    }

    func requestReveal() {
        revealRequest &+= 1
    }

    func setFocusedChrome(_ focused: Bool) {
        guard isFocusedChrome != focused else { return }
        isFocusedChrome = focused
    }
}

/// Same shape as `TabBarVisibilityKey` (TabBarVisibility.swift) and for the same reason: a custom
/// environment key rather than `@EnvironmentObject`, so a screen presented OUTSIDE the tab shell
/// (a Top Shelf deep link's standalone `NavigationStack`) falls back to a harmless unconnected
/// instance instead of crashing for a missing environment object.
private struct SidebarChromeKey: EnvironmentKey {
    static let defaultValue = SidebarChromeModel()
}

extension EnvironmentValues {
    var sidebarChrome: SidebarChromeModel {
        get { self[SidebarChromeKey.self] }
        set { self[SidebarChromeKey.self] = newValue }
    }
}

// MARK: - Items

/// One sidebar row. `id` is the `TabView` selection value, so the sidebar and the (hidden) tab bar
/// address the same six destinations by the same numbers.
struct SidebarItem: Identifiable, Equatable {
    let id: Int
    /// The ENGLISH key, verbatim from the matching `Tab(_:systemImage:value:)` title in
    /// `MainTabView`. Two jobs: it is the localization key (so the sidebar needs NO new strings —
    /// the catalog already carries these six from the `Tab` literals) and it is the stable half of
    /// the accessibility identifier the harness asserts on (`sidebar_item_Home`), which must not
    /// move when the UI language does.
    let title: String
    let systemImage: String

    /// Localized display text. Runtime `LocalizationValue` rather than a literal because the key
    /// is data here; extraction already picked these six up from `MainTabView`'s `Tab` titles.
    var localizedTitle: String { String(localized: String.LocalizationValue(title)) }

    /// The six tab-shell destinations, in tab order — titles and SF Symbols identical to
    /// `MainTabView`'s `Tab` declarations. If a tab is ever added, renamed or reordered there,
    /// this list moves with it.
    static let tabShell: [SidebarItem] = [
        SidebarItem(id: 0, title: "Home", systemImage: "house"),
        SidebarItem(id: 1, title: "Search", systemImage: "magnifyingglass"),
        SidebarItem(id: 2, title: "Library", systemImage: "books.vertical"),
        SidebarItem(id: 3, title: "Add-ons", systemImage: "puzzlepiece.extension"),
        SidebarItem(id: 4, title: "Settings", systemImage: "gearshape"),
        SidebarItem(id: 5, title: "Profile", systemImage: "person.crop.circle"),
    ]
}

// MARK: - Row style

/// FEAT-30 row treatment: focused = white capsule with a dark label, unfocused = plain label with
/// the glyph in a small translucent circle.
///
/// WHY A CUSTOM `ButtonStyle` (HIG hybrid contract, docs/design/hig-hybrid-contract.md line 16 —
/// "Custom `ButtonStyle`s exist only where a system style demonstrably can't express the shape
/// (document why in the style file)"):
///
///  - `.borderless` on tvOS is platter-free: it brightens/scales the label and draws no filled
///    shape at all, so it cannot produce the solid white pill the reference design is built
///    around.
///  - `.bordered`/`.card` DO draw the system near-white platter, but as a rounded RECT sized by
///    the system, inside a container that is itself a glass panel — the platter reads as a second
///    panel stacked on the first, not as a capsule riding inside it.
///  - `.glass` renders glass-on-glass: the row's material and the panel's material composite into
///    an indistinguishable smear, which is the one thing a focus indicator may not be.
///
/// The treatment still SPEAKS the system focus language rather than inventing one — white platter,
/// dark label, no accent ring, no parallax tilt — so this is the same kind of carve-out FEAT-14's
/// accent ring is: opt-in, default OFF (the whole sidebar is), and confined to this one chrome.
///
/// `isFocused` is an explicit parameter, NOT an `@Environment(\.isFocused)` read. That environment
/// read is device-unreliable — BUG-65 (`FlatControlStyles.swift`, lines 23-42): on hardware a
/// focused row rendered its white platter while env-keyed label modifiers still painted the
/// at-rest light colours (white-on-white), and the simulator does not reproduce it, so the sim
/// cannot adjudicate the fix. The parent already knows the answer (`focusedItem == item.id`) from
/// its own `@FocusState` — the mechanism BUG-45's device-verified fix relies on — so passing it in
/// skips the unreliable read entirely instead of layering a fallback on top of it.
struct SidebarItemButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.body)
            .foregroundStyle(isFocused ? Theme.Palette.onFocusPlatter : Theme.Palette.textPrimary)
            .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
            .padding(.vertical, SidebarMetrics.rowVerticalPadding)
            .background {
                if isFocused {
                    Capsule(style: .continuous).fill(Color.white)
                }
            }
            .scaleEffect(configuration.isPressed ? SidebarMetrics.pressScale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Layout numbers for the floating panel. Local to this file on purpose: they describe ONE piece
/// of chrome and nothing else reads them, so they do not belong in the shared `Theme.Size`
/// namespace (the one constant that does — `sidebarTopCompensation` — has to sit next to the
/// pinned-hero viewport budget it is defined against).
private enum SidebarMetrics {
    /// Fixed in BOTH states so the panel grows only DOWNWARD, the way the reference does. Sizing
    /// to content instead would animate the width on every expand/collapse and again whenever the
    /// selected section's label length changed.
    static let panelWidth: CGFloat = 340
    static let iconDiameter: CGFloat = 44
    static let iconLabelGap: CGFloat = Theme.Spacing.md
    static let rowSpacing: CGFloat = Theme.Spacing.xxs
    static let rowHorizontalPadding: CGFloat = Theme.Spacing.sm
    static let rowVerticalPadding: CGFloat = Theme.Spacing.xs
    static let panelPadding: CGFloat = Theme.Spacing.sm
    static let pressScale: CGFloat = 0.97
    /// The reference grows over roughly a fifth of a second.
    static let expandDuration: Double = 0.2
    /// Unfocused glyph disc.
    static let iconDiscOpacity: Double = 0.18
}

// MARK: - The overlay

/// The floating panel itself. Mounted ONCE, in `MainTabView`'s `.overlay(alignment: .topLeading)`
/// on the `TabView` — deliberately outside every `Tab` closure, so it is not part of any tab's
/// kept-alive subtree and cannot be pruned, deferred or duplicated with one.
///
/// Pure overlay: nothing behind it reflows. The tab roots keep the exact geometry they have in
/// tabs mode; the only geometry FEAT-30 may change is the top safe area, and that is handled
/// separately and explicitly by `sidebarTopCompensation()` below rather than by this view's
/// footprint.
struct SidebarOverlay: View {
    @Binding var selectedTab: Int
    var items: [SidebarItem] = SidebarItem.tabShell
    /// FEAT-25's app-root deep-link cover. Passed in (not observed): `MainTabView` already holds
    /// it as a plain `let`, so reading it here costs the shell nothing.
    let rootCoverActive: Bool
    /// `MainTabView`'s `@Namespace`, applied as `.focusScope` on the TabView, so a row press can
    /// re-run default focus placement for the whole shell (see `handOffFocusToContent`).
    let shellFocusScope: Namespace.ID
    @ObservedObject var chrome: SidebarChromeModel
    @Environment(\.resetFocus) private var resetFocus

    /// The immersive-push signal (a pushed `DetailView`) comes through the SAME narrow channel
    /// `TabBarImmersiveHideModifier` uses — `@Environment` for the object plus `onReceive` on the
    /// one publisher — rather than as an initializer parameter. A parameter would force
    /// `MainTabView` to READ `tabBarVisibility.immersiveHidden` in its own body, which re-couples
    /// the shell to that object's `objectWillChange` and restores precisely the T3/BUG-66
    /// invalidation storm `@State`-on-a-reference-type removed.
    @Environment(\.tabBarVisibility) private var tabBarVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var immersiveHidden = false
    /// Latched by a Menu-press reveal; cleared when focus leaves the sidebar again. This is what
    /// lets Menu summon the panel from a scrolled-down page, where the resting rule hides it.
    @State private var revealed = false
    /// The panel is focusable ONLY while revealed (test52 runs 1-6, sim 2026-09-05). Left
    /// focusable at rest it (a) took default focus at cold launch — it sits exactly where initial
    /// placement looks first — and (b) after a row press, releasing `focusedItem` and even
    /// disarming for 0.6 s both ended with focus restored INTO the panel (UIKit focus restoration
    /// hands focus back to a container's last item when it reappears). So: unarmed = the pill is
    /// a plain label the engine cannot land on; a reveal (Menu, or an Up the engine could not
    /// place — the hidden bar is kept unfocusable by `HiddenTabBarFocusBlocker`) arms it and
    /// takes focus programmatically; focus leaving the panel, or a row press, disarms it again.
    /// Entry is therefore always explicit and always the same two gestures.
    @State private var armed = false
    @FocusState private var focusedItem: Int?

    private var isExpanded: Bool { focusedItem != nil }

    /// Resting rule, in precedence order.
    ///
    /// Stated as a guard chain rather than one boolean expression on purpose: focus MUST win over
    /// every hide term. Removing a view that currently holds focus is the BUG-47 class — focus
    /// falls to whatever chrome is left and the next Menu press exits the app — and here it would
    /// additionally be reachable by simply scrolling the page under an open sidebar.
    private var shouldShow: Bool {
        guard SidebarChrome.isEnabled() else { return false }
        if focusedItem != nil { return true }
        if immersiveHidden || rootCoverActive { return false }
        if revealed { return true }
        return !(chrome.scrolledDownByTab[selectedTab] ?? false)
    }

    private var visibleItems: [SidebarItem] {
        isExpanded ? items : items.filter { $0.id == selectedTab }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if shouldShow {
                panel
                    .transition(.opacity)
            }
        }
        // Zero-sized, always mounted in sidebar mode (this view only exists in sidebar mode):
        // keeps the hidden system bar out of the focus engine — see `HiddenTabBarFocusBlocker`.
        .background(alignment: .topLeading) {
            HiddenTabBarFocusBlocker().frame(width: 0, height: 0).allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: SidebarMetrics.expandDuration),
                   value: isExpanded)
        .animation(reduceMotion ? nil : .easeOut(duration: SidebarMetrics.expandDuration),
                   value: shouldShow)
        // Same narrow subscription (and the same payload-not-property rule) as
        // `TabBarImmersiveHideModifier`: `@Published` emits on willSet, and it replays its current
        // value to a new subscriber, so no `onAppear` seed is needed.
        .onReceive(tabBarVisibility.$immersiveHidden) { immersiveHidden = $0 }
        .onChange(of: chrome.revealRequest) { _, _ in
            armed = true
            revealed = true
            takeFocusAfterReveal()
        }
        .onChange(of: focusedItem) { _, newValue in
            chrome.setFocusedChrome(newValue != nil)
            // Focus left the sidebar: drop the reveal latch so the resting rule (scroll position,
            // detail push) governs again, and disarm so the pill is a label again until the next
            // explicit reveal (see `armed`).
            if newValue == nil {
                revealed = false
                armed = false
            }
        }
    }

    private var panel: some View {
        // The probe is attached as an overlay (never a sibling in the stack) so it cannot affect
        // the panel's layout, and it is factored out rather than `#if`-ed inline: a conditional
        // compilation block inside a modifier chain is legal but fragile to read, and a
        // `@ViewBuilder` that resolves to `EmptyView` in release is the same thing with no chain
        // surgery.
        basePanel
            .overlay(alignment: .topLeading) { stateProbe }
    }

    /// Harness-readable state probe, same house pattern as HomeView's `debug_env`/`debug_hero`
    /// (invisible, tiny, non-zero opacity so it is not culled). Present only while the panel is —
    /// its absence IS the "sidebar hidden" reading, which is why `shown` is a constant 1.
    @ViewBuilder
    private var stateProbe: some View {
        #if DEBUG
        Text("sidebar_state expanded=\(isExpanded ? 1 : 0) focused=\(focusedItem ?? -1) revealed=\(revealed ? 1 : 0) armed=\(armed ? 1 : 0) shown=1")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("sidebar_state")
            .allowsHitTesting(false)
        #endif
    }

    private var basePanel: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
            ForEach(visibleItems) { item in
                if armed {
                    Button {
                        selectedTab = item.id
                        // Deviation from the reference (which keeps focus on the pressed row):
                        // our pages start BELOW the panel, so with focus left in an expanded
                        // six-row panel the only way into content was Down past the last row —
                        // test52 found Right went nowhere. Releasing focus alone is not enough
                        // either (test52 run 5: the engine re-resolved to the panel's first row),
                        // so the rows DISARM for a beat — plain labels cannot hold focus, which
                        // forces the engine into the newly selected tab's content — and re-arm
                        // once focus has settled there. The panel collapses to its pill as soon
                        // as `focusedItem` clears.
                        handOffFocusToContent()
                    } label: {
                        row(item)
                    }
                    .buttonStyle(SidebarItemButtonStyle(isFocused: focusedItem == item.id))
                    .focused($focusedItem, equals: item.id)
                    .accessibilityIdentifier("sidebar_item_\(item.title)")
                } else {
                    // Not yet armed (see `armed`): identical geometry and look to an unfocused
                    // row, but nothing here can take focus.
                    row(item)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
                        .padding(.vertical, SidebarMetrics.rowVerticalPadding)
                        .accessibilityIdentifier("sidebar_item_\(item.title)")
                }
            }
        }
        .padding(SidebarMetrics.panelPadding)
        .frame(width: SidebarMetrics.panelWidth, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        // One focus section for the whole panel: D-pad moves inside it stay inside it, and a move
        // out of it hands off to the content underneath in one step rather than row by row.
        .focusSection()
        // `.contain` (not a bare identifier on the stack): an identifier applied to a container
        // can propagate onto its children in SwiftUI and would clobber the per-row
        // `sidebar_item_*` identifiers the harness addresses. Declaring an explicit accessibility
        // CONTAINER gives the panel its own element to name while leaving every row individually
        // addressable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar_overlay")
    }

    private func row(_ item: SidebarItem) -> some View {
        HStack(spacing: SidebarMetrics.iconLabelGap) {
            ZStack {
                // The disc is the UNFOCUSED affordance only — on the white platter the glyph reads
                // on its own, and a translucent disc over white is just a grey smudge.
                if focusedItem != item.id {
                    Circle().fill(Color.white.opacity(SidebarMetrics.iconDiscOpacity))
                }
                Image(systemName: item.systemImage)
            }
            .frame(width: SidebarMetrics.iconDiameter, height: SidebarMetrics.iconDiameter)

            Text(item.localizedTitle)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    /// Post-select hand-off: drop the rows' focusability for a moment so the focus engine must
    /// leave the panel (see the row `Button`'s comment), then restore it.
    private func handOffFocusToContent() {
        armed = false
        focusedItem = nil
        revealed = false
        // With the rows gone, re-run default focus placement for the whole shell scope so the
        // engine lands in the newly selected tab's content (`prefersDefaultFocus` only applies
        // when nothing holds focus — `resetFocus` is the documented way to re-run it). Next
        // runloop turn, so SwiftUI has removed the row buttons first.
        DispatchQueue.main.async {
            resetFocus(in: shellFocusScope)
        }
    }

    /// Programmatic `@FocusState` write after a Menu-press reveal.
    ///
    /// Ordering matters and is not free: `revealed` has only just flipped, so the rows the focus
    /// engine needs do not exist yet on this runloop turn. `DispatchQueue.main.async` lets SwiftUI
    /// insert them first. The single retry mirrors HomeView's Menu-to-top handoff (BUG-27), which
    /// learned on device that a one-shot focus grab issued a hair too early is silently dropped —
    /// here that would leave the panel visible but unfocusable, i.e. collapsed and inert.
    private func takeFocusAfterReveal() {
        let target = selectedTab
        DispatchQueue.main.async {
            guard revealed, focusedItem == nil else { return }
            focusedItem = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard revealed, focusedItem == nil else { return }
                focusedItem = target
            }
        }
    }
}


// MARK: - Hidden tab bar focus blocker

/// In sidebar mode the system tab bar is hidden with `.toolbarVisibility(.hidden, for: .tabBar)`,
/// but hidden is not the same as unfocusable: on the FA87 sim (test52, 2026-09-05) and on the
/// Living Room ATV (Phase 0 spike, "Up from Play did nothing") an Up press from the hero still
/// moved focus INTO the invisible bar — no accessible element reported focus afterwards, further
/// presses went nowhere, and a later Select switched tabs from that unseen bar. The focus engine
/// consumes the press, so no `onMoveCommand` reaches the sidebar's reveal handlers either.
///
/// SwiftUI's tvOS `TabView` is UIKit-backed, so this representable — mounted only in sidebar mode,
/// zero-sized, inside the sidebar overlay — walks the window's controller tree to the
/// `UITabBarController` and clears `isUserInteractionEnabled` on its `tabBar`. Per UIKit's focus
/// rules a view with user interaction disabled is never focusable (see the tvOS skill's UIKit
/// notes: hidden / alpha 0 / interaction disabled / not in hierarchy all disqualify), while the
/// bar's layout contribution — already nil while hidden — is untouched. Re-applied on every
/// SwiftUI update of this view and on a short retry ladder after attaching, because the tab bar
/// controller can be created after this view first lands in the window. Logs what it found once,
/// so a build where the backing controller is not a `UITabBarController` says so instead of
/// silently doing nothing. Tabs mode never mounts it.
struct HiddenTabBarFocusBlocker: UIViewRepresentable {
    func makeUIView(context: Context) -> BlockerView { BlockerView() }
    func updateUIView(_ uiView: BlockerView, context: Context) { uiView.apply() }

    final class BlockerView: UIView {
        private var logged = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            apply()
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            }
        }

        func apply() {
            guard let root = window?.rootViewController else { return }
            guard let tabController = Self.findTabBarController(from: root) else {
                if !logged {
                    logged = true
                    NSLog("[SidebarChrome] no UITabBarController found under %@ — hidden bar stays focusable", String(describing: type(of: root)))
                }
                return
            }
            let bar = tabController.tabBar
            if bar.isUserInteractionEnabled {
                bar.isUserInteractionEnabled = false
                tabController.setNeedsFocusUpdate()
            }
            if !logged {
                logged = true
                NSLog("[SidebarChrome] hidden tab bar made unfocusable (hidden=%d alpha=%.2f frame=%@)",
                      bar.isHidden ? 1 : 0, bar.alpha, NSCoder.string(for: bar.frame))
            }
        }

        private static func findTabBarController(from controller: UIViewController) -> UITabBarController? {
            if let tab = controller as? UITabBarController { return tab }
            if let presented = controller.presentedViewController,
               let hit = findTabBarController(from: presented) { return hit }
            for child in controller.children {
                if let hit = findTabBarController(from: child) { return hit }
            }
            return nil
        }
    }
}

// MARK: - Tab-root Menu grammar

/// Sidebar-mode Menu grammar for a scrolling tab root: Menu summons (and focuses) the sidebar
/// instead of falling through to the system's "suspend the app" default.
///
/// Structurally absent in tabs mode — `.onExitCommand(perform: nil)` is the documented way to
/// leave the default behaviour intact and HomeView already relies on it, but "no modifier at all"
/// is the only form that is provably byte-identical, and the mode cannot flip mid-session
/// (`ContentView`'s `.id` remounts the shell), so the conditional never re-identifies anything.
///
/// The sidebar installs NO exit handler of its own: with focus in the panel, Menu falls through to
/// the system default — the same "focus is on root chrome, Menu exits" behaviour the tab bar has
/// today. So the full grammar is: Menu at a root → sidebar; Menu again → exit.
private struct SidebarMenuRevealModifier: ViewModifier {
    @Environment(\.sidebarChrome) private var chrome

    @ViewBuilder
    func body(content: Content) -> some View {
        if SidebarChrome.isEnabled() {
            content
                .onExitCommand {
                    // Read inside the closure, never as a body dependency: `@Environment` hands
                    // over the object without subscribing, so this is a live read at press time
                    // that costs the tab root no invalidations. If the sidebar already holds focus
                    // this handler is not in its responder chain at all (the panel is a sibling
                    // of the whole TabView, not a descendant of any tab root) — the guard is
                    // belt-and-braces.
                    guard !chrome.isFocusedChrome else { return }
                    chrome.requestReveal()
                }
                // Up with nowhere to go = the sidebar. Device spike + test52 (2026-09-05): with
                // the system bar hidden, the focus engine treats the band it occupied as a dead
                // zone — Up from the hero CTA or a page's first row moves nothing, and it does NOT
                // reach the panel geometrically even though the pill sits right there. Move
                // commands only arrive here when the engine found no focus target for the press
                // (the same contract the hero carousel's Left/Right paging relies on), so an
                // ordinary Up between two rows never comes through this closure.
                .onMoveCommand { direction in
                    guard direction == .up, !chrome.isFocusedChrome else { return }
                    chrome.requestReveal()
                }
        } else {
            content
        }
    }
}

/// Compensates the tab shell's top safe area when the system tab bar is hidden by sidebar mode.
///
/// Ships as 0 (see `Theme.Size.sidebarTopCompensation`), so until the device spike measures the
/// delta this modifier applies literally nothing — in either mode.
private struct SidebarTopCompensationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if SidebarChrome.isEnabled(), SidebarChrome.topCompensation > 0 {
            content.safeAreaPadding(.top, SidebarChrome.topCompensation)
        } else {
            content
        }
    }
}

extension View {
    /// Attach to a scrolling tab root (Search, Library, Add-ons). Home composes the same reveal
    /// by hand instead, because its exit handler already carries BUG-27's Menu-to-top branch.
    func sidebarMenuReveal() -> some View {
        modifier(SidebarMenuRevealModifier())
    }

    /// Attach to the tab shell's `TabView` in `MainTabView`.
    func sidebarTopCompensation() -> some View {
        modifier(SidebarTopCompensationModifier())
    }
}
