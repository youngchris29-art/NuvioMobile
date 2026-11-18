import Foundation

/// Device pass (attempt 3): which filter menu the bar keeps drawn because the viewer is on it, and
/// where focus goes after Clear Filters. Pure; `LibraryViewModel` owns one and feeds it, and the
/// resolver reads `menu` as `Request.keepVisible`.
///
/// The invariant: a pick made in the bar never removes the control the viewer is on, and Clear
/// Filters always leaves focus on a control that exists.
///
/// Events and rules (review of ae4ff1047: one release rule, nothing to latch or race):
/// - `picked(M)` (any row of menu M, All included): keep M. The model applies it before the derive
///   the pick causes, so M's button still exists when the closing picker hands focus back to it.
/// - `focus(control)`: a bar control other than the kept menu (the Saved and Debrid Cloud chips
///   included, pre-cut follow-ups 2.2) releases it (the viewer moved on; the
///   menu may hide now, and focus is identity-based, so a control leaving to the left of the focused
///   one moves it but does not change which control holds focus). Focus on the kept menu keeps it.
/// - `focus(nil)` (focus outside the bar) never releases: a picker opening, a picker closing and
///   Down into the grid all report it and cannot be told apart. A kept menu stays drawn while the
///   viewer is in the grid or the header, until they come back to the bar on another control.
/// - `clearFilters` and `contextChanged` release it (a list or library source change, and the
///   screen stopping: `LibraryViewModel.stop()` sends it).
nonisolated struct LibraryBarKeep: Equatable, Sendable {
    typealias Menu = LibraryBarResolver.Menu

    /// The menu kept drawn (`Request.keepVisible`); nil = none.
    private(set) var menu: Menu?
    /// The last focus reported (nil = outside the bar).
    private(set) var focus: LibraryBarFocus?

    enum Event: Equatable, Sendable {
        case picked(Menu)
        case focus(LibraryBarFocus?)
        case clearFilters
        case contextChanged
    }

    /// The filter menu a bar control is, if it is one.
    static func menu(for control: LibraryBarFocus) -> Menu? {
        switch control {
        case .type: return .type
        case .genre: return .genre
        case .year: return .year
        case .watch: return .show
        case .list, .sort, .refresh, .clear, .savedChip, .cloudChip: return nil
        }
    }

    /// The bar control a filter menu is.
    static func control(for menu: Menu) -> LibraryBarFocus {
        switch menu {
        case .type: return .type
        case .genre: return .genre
        case .year: return .year
        case .show: return .watch
        }
    }

    mutating func apply(_ event: Event) {
        switch event {
        case .picked(let m):
            menu = m
        case .focus(let f):
            focus = f
            if let f, let m = menu, Self.control(for: m) != f { menu = nil }
        case .clearFilters, .contextChanged:
            menu = nil
        }
    }

    func applying(_ event: Event) -> LibraryBarKeep {
        var copy = self
        copy.apply(event)
        return copy
    }

    /// Which menus draw after a Clear Filters, as the resolver decided.
    struct Shown: Equatable, Sendable {
        var type: Bool
        var genre: Bool
        var year: Bool
        var show: Bool
        var sort: Bool
    }

    /// Where Clear Filters puts focus (its pill goes with the filters): Genre, else Year, else Show,
    /// else Type, else Sort (every source has sort options). Nil only when none of them draws.
    static func focusAfterClear(_ shown: Shown) -> LibraryBarFocus? {
        if shown.genre { return .genre }
        if shown.year { return .year }
        if shown.show { return .watch }
        if shown.type { return .type }
        if shown.sort { return .sort }
        return nil
    }
}
