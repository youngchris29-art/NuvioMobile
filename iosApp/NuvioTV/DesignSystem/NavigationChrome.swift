import Foundation
import UIKit   // UIFocusHeading only

// Home Stage & Strip (H9, FEAT-45; P4 spec §1.1): the navigation chrome's pure half. Everything in
// this file is a value or a function of values, unit-tested by `NavigationChromeTests` and
// `RailFocusPolicyTests`. The view (`NavigationRail`), its model and the shell wiring live in
// `NavigationRail.swift`.

// MARK: - Mode, visibility, migration, inset math

/// Which navigation chrome the tab shell shows: the system's top tab bar (Tabs, the default) or the
/// floating pill rail on the left (Rail). Rail replaced FEAT-30's Menu-revealed Sidebar mode.
///
/// Both keys are DEVICE-LOCAL `UserDefaults` strings, never synced (no reference in `shared/` or in
/// any sync blob): which chrome a living-room TV shows is a per-device display preference.
///
/// EVERY read of the mode must resolve to Tabs on an untouched install, and everything the rail adds
/// is structurally absent then: the call sites branch `if NavigationChrome.isRail() { … } else
/// { content }` rather than passing an inert value into an always-applied modifier, so Tabs mode
/// stays byte-identical. Reads are live (a `UserDefaults` lookup), never launch-latched: the mode
/// changes only across `ContentView`'s `.id(theme|style|visibility|font)` remount, and a remount
/// re-creates views, not type storage, so a latched `static let` would leave the shell half switched.
nonisolated enum NavigationChrome {
    /// Kept from FEAT-30 so the stored choice survives the rename.
    static let styleKey = "sidebar_style"
    /// New with the rail: Always Visible / Hide While Browsing.
    static let railVisibilityKey = "rail_visibility"
    /// FEAT-30's stored value. Reads as Rail, and `migrateLegacy` rewrites it once.
    static let legacySidebarValue = "sidebar"

    enum Style: String, Equatable, Sendable {
        case tabs
        case rail
    }

    enum RailVisibility: String, Equatable, Sendable {
        case always
        case whileBrowsing = "browsing"
    }

    // MARK: Layout numbers the math needs (mirrors of `RailMetrics`, NavigationRail.swift)

    /// The pill's leading edge from the screen edge (P4 R3; kept for this beta, critique Q6).
    static let bezelInset: CGFloat = 16
    /// The collapsed pill's width.
    static let collapsedWidth: CGFloat = 84
    /// The gap the rail keeps from content when it reserves width.
    static let contentGap: CGFloat = 16
    /// `bezelInset + collapsedWidth + contentGap`: what Always Visible reserves from the bezel.
    static let reservedEdge: CGFloat = bezelInset + collapsedWidth + contentGap
    /// The collapsed pill's trailing edge (x = 100 on a 1920 canvas).
    static let pillTrailingEdge: CGFloat = bezelInset + collapsedWidth
    /// The widest focus lift a row card draws past its leading edge: a 500 pt Saga card under the
    /// measured system lift (≈1.1212, `PosterCard.swift`) grows ≈30 pt per side. The clearance test
    /// checks that a lifted first card never reaches under the pill in either visibility.
    static let widestRowLiftOverhang: CGFloat = 30

    // MARK: Resolution

    /// "rail", and FEAT-30's "sidebar", read as Rail; anything else (missing, "tabs", a corrupted
    /// or future string) is Tabs, never an unknown third state. Trimmed and lower-cased so a
    /// hand-typed launch argument (`-sidebar_style Rail`) still resolves.
    static func style(raw: String?) -> Style {
        guard let raw else { return .tabs }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case Style.rail.rawValue, legacySidebarValue: return .rail
        default: return .tabs
        }
    }

    static func style(_ defaults: UserDefaults = .standard) -> Style {
        style(raw: defaults.string(forKey: styleKey))
    }

    static func isRail(_ defaults: UserDefaults = .standard) -> Bool {
        style(defaults) == .rail
    }

    /// "browsing" reads as Hide While Browsing; anything else is Always Visible (the default).
    static func railVisibility(raw: String?) -> RailVisibility {
        guard let raw else { return .always }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == RailVisibility.whileBrowsing.rawValue
            ? .whileBrowsing : .always
    }

    static func railVisibility(_ defaults: UserDefaults = .standard) -> RailVisibility {
        railVisibility(raw: defaults.string(forKey: railVisibilityKey))
    }

    /// Rail mode with the rail Always Visible: the only configuration that moves content.
    static func reservesWidth(_ defaults: UserDefaults = .standard) -> Bool {
        isRail(defaults) && railVisibility(defaults) == .always
    }

    // MARK: Migration (P4 R6, §4.2)

    /// What a PERSISTED `sidebar_style` value migrates to: "rail" for exactly FEAT-30's "sidebar",
    /// nil (leave it alone) for everything else, including a missing key and "rail" itself.
    static func migratedValue(forPersisted raw: Any?) -> String? {
        guard let value = raw as? String, value == legacySidebarValue else { return nil }
        return Style.rail.rawValue
    }

    /// Once per launch from `NuvioTVApp.init`, before any view reads the mode. Reads the PERSISTENT
    /// domain only (`persistentDomain(forName: domain)`), so a `-sidebar_style sidebar` launch
    /// argument, which lives in the argument domain, is never written to disk. Idempotent: it writes
    /// only while the stored value is exactly "sidebar", so a second run is a no-op. Never touches
    /// `rail_visibility`, which an untouched install leaves unset (Always Visible). Returns whether
    /// it wrote.
    @discardableResult
    static func migrateLegacy(_ defaults: UserDefaults, domain: String) -> Bool {
        guard !domain.isEmpty,
              let migrated = migratedValue(forPersisted: defaults.persistentDomain(forName: domain)?[styleKey])
        else { return false }
        defaults.set(migrated, forKey: styleKey)
        NSLog("[NavRail] migrated %@ \"%@\" to \"%@\" (device-local, once)", styleKey, legacySidebarValue, migrated)
        return true
    }

    // MARK: Inset math (P4 R3, §5.1)

    /// How much leading safe area an Always Visible rail adds to every tab root: the reserved edge
    /// beyond the side safe area the content already keeps (116 − 80 = 36 on a 1080p canvas). Never
    /// negative, and 0 when the rail does not reserve width.
    static func contentSafeAreaExtra(sideSafeArea: CGFloat, reservesWidth: Bool) -> CGFloat {
        guard reservesWidth else { return 0 }
        return max(0, reservedEdge - sideSafeArea)
    }

    /// Where a tab root's content starts from the bezel: the side safe area, the rail's extra, then
    /// the 60 pt content margin (`Theme.Spacing.screen`). 176 Always Visible, 140 otherwise.
    static func contentLeading(sideSafeArea: CGFloat, reservesWidth: Bool) -> CGFloat {
        sideSafeArea + contentSafeAreaExtra(sideSafeArea: sideSafeArea, reservesWidth: reservesWidth)
            + Theme.Spacing.screen
    }

    /// The rows' distance to the visible screen edges (`\.rowEdgeMargins`), the rail's edge counting
    /// as the leading one: (176, 140) Always Visible, (140, 140) otherwise. Computed from the passed
    /// side safe area, so production (which passes `PinnedRowGeometry.sideSafeArea`) gets exactly
    /// `RowEdgeMargins.standard` when the rail reserves nothing.
    static func rowEdgeMargins(sideSafeArea: CGFloat, reservesWidth: Bool) -> RowEdgeMargins {
        let margin = Theme.Spacing.screen + sideSafeArea
        return RowEdgeMargins(
            leading: margin + contentSafeAreaExtra(sideSafeArea: sideSafeArea, reservesWidth: reservesWidth),
            trailing: margin
        )
    }

    /// See `Theme.Size.sidebarTopCompensation` (still ships 0, so `.railTopCompensation()` applies
    /// nothing). Main-actor: the constant lives with the pinned-hero budget in `Theme.Size`.
    @MainActor
    static var topCompensation: CGFloat { Theme.Size.sidebarTopCompensation }
}

// MARK: - Rail focus policy (P4 §2)

/// Why the rail opened. Decides what Menu does inside it (`RailFocusPolicy.menuInRail`).
nonisolated enum RailOpenReason: String, Equatable, Sendable {
    /// A Left the focus engine could not place, from the leftmost item of a tab's content.
    case left
    /// Menu at a tab root (or at Stage's row 0).
    case menu
    /// Focus landed on the hidden system tab bar (tvOS's search field does this on Menu, S1 W2).
    case hiddenBarRedirect
    /// A hand-off to content found nothing to focus, so the rail took focus back.
    case rearm
}

/// The rail's focus decisions as pure functions of plain facts (P4 §2.2–§2.4).
nonisolated enum RailFocusPolicy {
    /// A failed move (`UIFocusSystem.movementDidFailNotification`) opens the rail only when every
    /// condition holds: a plain Left (never a diagonal with Up or Down), Rail mode, the rail not
    /// already holding (or taking) focus, the failed move starting inside a tab's content (never the
    /// hidden bar, never the rail itself), nothing presented over the shell (player, stream picker,
    /// trailer cover, alerts) and no app-handled Left owning the press (Classic's hero carousel).
    static func shouldArm(heading: UIFocusHeading,
                          railMode: Bool,
                          railHoldsFocus: Bool,
                          originInTabContent: Bool,
                          presentedOverShell: Bool,
                          vetoed: Bool) -> Bool {
        heading.contains(.left)
            && heading.isDisjoint(with: [.up, .down])
            && railMode
            && !railHoldsFocus
            && originInTabContent
            && !presentedOverShell
            && !vetoed
    }

    enum InRailMove: Equatable, Sendable {
        /// Right: leave the rail for the tab on screen (P4 R1).
        case exitToContent
        /// Up past the top item, Down past the bottom one, Left: nothing happens.
        case contained
    }

    /// A move the engine could not place while the rail holds focus. Content is gated then, so
    /// Right always fails, and the rail turns it into its exit.
    static func moveFailedInRail(heading: UIFocusHeading) -> InRailMove {
        heading.contains(.right) ? .exitToContent : .contained
    }

    enum MenuInRail: Equatable, Sendable {
        /// Close the rail back to the content it opened from.
        case closeToContent
        /// No handler: the system default, which from a tab shell suspends the app.
        case systemDefault
    }

    /// P4 R4 (critique Q2, decided 2026-10-05): Menu closes a rail that Left opened; in a rail that
    /// Menu (or the hidden-bar redirect, or a re-arm) opened it is the system default, so Menu
    /// opens the rail at a tab root and Menu again leaves the app, the remote's normal grammar.
    static func menuInRail(openedBy reason: RailOpenReason) -> MenuInRail {
        reason == .left ? .closeToContent : .systemDefault
    }

    enum SelectAction: Equatable, Sendable {
        case switchTab(Int)
        case returnToCurrent
    }

    /// P4 R1: Select switches to another tab; Select on the current tab's item is the same as Right.
    static func select(item: Int, currentTab: Int) -> SelectAction {
        item == currentTab ? .returnToCurrent : .switchTab(item)
    }
}

// MARK: - Rail visibility (P4 §1.1, §5.2)

/// Whether the pill is on screen, in precedence order. Focus wins over every hide term: removing a
/// view that holds focus is the BUG-47 class (focus falls to whatever is left and the next Menu
/// exits the app).
nonisolated enum RailVisibilityRule {
    struct Inputs: Equatable, Sendable {
        var railMode: Bool
        /// A rail item holds focus.
        var holdsFocus: Bool
        /// A Menu, Left or redirect opened the rail and focus has not left it since.
        var revealed: Bool
        /// The app-root deep-link cover (Top Shelf) is up.
        var rootCoverActive: Bool
        /// An immersive screen (Detail) is pushed.
        var immersive: Bool
        /// The current tab's settled "scrolled down" mirror.
        var scrolledDown: Bool
        var visibility: NavigationChrome.RailVisibility
        var selectedTab: Int
    }

    /// The Search tab's selection value: Hide While Browsing keeps the rail off its keyboard (R7).
    static let searchTab = 1

    /// `!railMode` → hidden; holds focus → shown; root cover → hidden; revealed → shown; Always
    /// Visible → shown; then (Hide While Browsing, R7) immersive → hidden; Search → hidden;
    /// scrolled down → hidden; otherwise shown.
    static func shown(_ i: Inputs) -> Bool {
        guard i.railMode else { return false }
        if i.holdsFocus { return true }
        if i.rootCoverActive { return false }
        if i.revealed { return true }
        if i.visibility == .always { return true }
        if i.immersive { return false }
        if i.selectedTab == searchTab { return false }
        if i.scrolledDown { return false }
        return true
    }
}

/// How a scrolled-down write should move the rail (P4 §1.3, #8). Recorded per tab with the write.
nonisolated enum RailMotion: Equatable, Sendable {
    /// A scroll mirror crossing: the hide edge is immediate, the show edge waits the resting settle.
    case scroll
    /// Stage's strip starting a page: both edges move with the page's own curve and duration, and
    /// no settle (the row index is discrete).
    case page(seconds: TimeInterval)
}

/// A reveal request: a counter, so two Menu presses in a row are two observable changes, plus why.
nonisolated struct RailRevealRequest: Equatable, Sendable {
    var generation: Int
    var reason: RailOpenReason
}

// MARK: - Content gate mode (DEBUG A/B)

/// How the rail makes tab content unfocusable while it holds focus (P4 R2, §2.3). The Wave 0.5
/// spike found the engine otherwise leaks out of the overlay: Down past the bottom item into
/// content, and Right from row 1 to an off-screen row-0 card.
///
///  - `uikit` (the primary): one `isUserInteractionEnabled = false` on the tab controller's view.
///    Covers every tab root, every pushed page and the UIKit-hosted Search keyboard at one site,
///    with no SwiftUI invalidation. Unproven for SwiftUI focus items (Risk 1); Probe G decides.
///  - `perTab` (the specified fallback): `.disabled` on each tab root from the shell-level gate, the
///    spike's device-proven mechanism. May leave the Search keyboard ungated (Q5).
///
/// `-debug.railGate uikit|perTab` picks one for the main session's simulator A/B. DEBUG builds only;
/// Release always runs the primary. Launch-latched: `.railTabRoot` branches on it structurally.
nonisolated enum RailGateMode: String, Equatable, Sendable {
    case uikit
    case perTab

    static let defaultsKey = "debug.railGate"

    /// "perTab" (any case, or "per-tab") picks the fallback; anything else is the primary.
    static func resolve(_ raw: String?) -> RailGateMode {
        guard let raw else { return .uikit }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pertab", "per-tab": return .perTab
        default: return .uikit
        }
    }

    static let current: RailGateMode = {
        #if DEBUG
        return resolve(UserDefaults.standard.string(forKey: defaultsKey))
        #else
        return .uikit
        #endif
    }()
}
