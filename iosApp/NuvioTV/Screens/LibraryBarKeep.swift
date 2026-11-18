import Foundation

/// Device pass (attempt 3): which filter menu the bar keeps drawn because the viewer is on it, and
/// where focus goes after Clear Filters. Pure; `LibraryViewModel` owns one and feeds it, and the
/// resolver reads `menu` as `Request.keepVisible`.
///
/// The invariant: a pick made in the bar never removes the control the viewer is on, and Clear
/// Filters always leaves focus on a control that exists.
///
/// Events and rules:
/// - `picked(M)` (any row of menu M, All included): keep M. The pick lands while the system picker
///   is still up or closing, before focus is back on M's button, so the keep is applied before the
///   derive the pick causes, and it waits for focus to return: `awaitingReturn` is set unless focus
///   is already reported on M.
/// - `focus(M)` (focus reported on the kept menu): keep M; the picker has closed (`awaitingReturn`
///   off).
/// - `focus(another bar control)`: keep nothing. The menu the viewer left may hide now; focus is
///   identity-based, so a control leaving to the left of the focused one moves it but does not
///   change which control holds focus.
/// - `focus(nil)` (focus outside the bar): keep nothing, unless `awaitingReturn` (the open picker
///   holds focus outside the bar and hands it back to M when it closes).
/// - `clearFilters` and `contextChanged` (a list or library source change): keep nothing.
nonisolated struct LibraryBarKeep: Equatable, Sendable {
    typealias Menu = LibraryBarResolver.Menu

    /// The menu kept drawn (`Request.keepVisible`); nil = none.
    private(set) var menu: Menu?
    /// A pick landed and focus has not been reported back on `menu` yet.
    private(set) var awaitingReturn = false
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
        case .list, .sort, .refresh, .clear: return nil
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
            awaitingReturn = focus != Self.control(for: m)
        case .focus(let f):
            focus = f
            if let f {
                if let m = menu, Self.control(for: m) == f {
                    awaitingReturn = false
                } else {
                    menu = nil
                    awaitingReturn = false
                }
            } else if !awaitingReturn {
                menu = nil
            }
        case .clearFilters, .contextChanged:
            menu = nil
            awaitingReturn = false
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
