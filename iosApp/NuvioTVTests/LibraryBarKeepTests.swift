import XCTest
@testable import NuvioTV

/// Device pass (attempt 3): a pick made in the Library filter bar never removes the control the
/// viewer is on, and Clear Filters always leaves focus on a control that exists. Three pure parts:
/// the resolver's `keepVisible`, the `LibraryBarKeep` reducer that sets and clears it, and the
/// Clear Filters focus fallback. Exhaustive where the domain is small.
final class LibraryBarKeepTests: XCTestCase {
    private typealias R = LibraryBarResolver
    private typealias T = LibraryBarResolver.Title
    private typealias State = LibraryGridPolicy.WatchState
    private typealias Keep = LibraryBarKeep
    private typealias Menu = LibraryBarResolver.Menu

    private let fresh = State(isWatched: false, progress: nil)
    private let watched = State(isWatched: true, progress: nil)
    private let halfway = State(isWatched: false, progress: 0.5)

    /// LibraryBarResolverTests' five titles.
    private var titles: [T] {
        [
            T(typeKey: "movie", genres: ["Drama", "Crime"], year: "2001", state: fresh),
            T(typeKey: "movie", genres: ["drama"], year: "2005", state: watched),
            T(typeKey: "series", genres: ["Comedy"], year: "2005", state: halfway),
            T(typeKey: "Series ", genres: [" Drama ", ""], year: nil, state: watched),
            T(typeKey: "anime", genres: [], year: "2010", state: fresh),
        ]
    }

    private func shows(_ out: R.Output, _ menu: Menu) -> Bool {
        switch menu {
        case .type: return out.showsType
        case .genre: return out.showsGenre
        case .year: return out.showsYear
        case .show: return out.showsShow
        }
    }

    private func setShows(_ out: inout R.Output, _ menu: Menu, _ value: Bool) {
        switch menu {
        case .type: out.showsType = value
        case .genre: out.showsGenre = value
        case .year: out.showsYear = value
        case .show: out.showsShow = value
        }
    }

    // MARK: - Resolver: keepVisible

    /// The device case: Type Series, Genre Drama, Show In Progress leaves one series; "All types"
    /// would hide the Type menu, and keeping it draws it with its All row and the one type.
    func testTheDeviceCaseKeepsTheTypeMenu() {
        let picked = R.Request(type: nil, genre: "Drama", year: nil, smartFilters: [.inProgress])
        let fixtureLike = titles + [T(typeKey: "series", genres: ["Drama"], year: "2022", state: halfway)]
        let normal = R.resolve(titles: fixtureLike, request: picked)
        XCTAssertFalse(normal.showsType, "one type left: the rule hides the Type menu")
        var keep = picked
        keep.keepVisible = .type
        let kept = R.resolve(titles: fixtureLike, request: keep)
        XCTAssertTrue(kept.showsType)
        XCTAssertNil(kept.selectedType, "All types")
        XCTAssertEqual(kept.types.map(\.key), ["series"])
        XCTAssertEqual(kept.allTypesCount, 1)
    }

    /// One case per menu where the rule hides it and the keep draws it.
    func testEachMenuIsKeptWhereItWouldHide() {
        let one = [T(typeKey: "movie", genres: ["Drama"], year: "2001", state: fresh),
                   T(typeKey: "movie", genres: ["Drama"], year: "2001", state: fresh)]
        let normal = R.resolve(titles: one, request: .init())
        for menu in Menu.allCases {
            XCTAssertFalse(shows(normal, menu), "\(menu): one value only, the rule hides it")
            let kept = R.resolve(titles: one, request: .init(keepVisible: menu))
            XCTAssertTrue(shows(kept, menu), "\(menu) must stay drawn while kept")
            for other in Menu.allCases where other != menu {
                XCTAssertFalse(shows(kept, other), "\(menu) kept: \(other) still follows the rule")
            }
        }
        // The kept Show menu offers the one choice every title passes (it narrows nothing).
        XCTAssertEqual(R.resolve(titles: one, request: .init(keepVisible: .show)).visibleSmartFilters, [.unwatched])
        XCTAssertEqual(normal.visibleSmartFilters, [])
    }

    /// A kept menu with no option at all is not drawn.
    func testAKeepIsIgnoredWhenTheMenuHasNoOption() {
        let bare = [T(typeKey: "movie", genres: [], year: nil, state: fresh)]
        XCTAssertFalse(R.resolve(titles: bare, request: .init(keepVisible: .genre)).showsGenre, "no genres")
        XCTAssertFalse(R.resolve(titles: bare, request: .init(keepVisible: .year)).showsYear, "no years")
        for menu in Menu.allCases {
            XCTAssertFalse(shows(R.resolve(titles: [], request: .init(keepVisible: menu)), menu), "\(menu): empty list")
        }
    }

    /// Exhaustive: every subset of the five titles, every request over their values (and values the
    /// list lacks), every kept menu. The kept menu draws exactly when the rule draws it or it has an
    /// option; every other field of the output is the rule's, the kept Show menu's choices aside
    /// (the rule's when it has any, else every choice some title passes).
    func testAKeepChangesOnlyTheKeptMenu() {
        let types: [String?] = [nil, "movie", "series", "anime", "documentary"]
        let genres: [String?] = [nil, "drama", "Comedy", "Crime", "Western"]
        let years: [String?] = [nil, "2001", "2005", "2010", "1980"]
        let showSets: [Set<LibraryGridPolicy.SmartFilter>] = [[], [.unwatched], [.inProgress], [.watched]]
        let base = titles
        var bites: [Menu: Int] = [:], ignored: [Menu: Int] = [:]
        for mask in 0..<(1 << base.count) {
            let list = base.indices.filter { mask & (1 << $0) != 0 }.map { base[$0] }
            for type in types { for genre in genres { for year in years { for smart in showSets {
                let request = R.Request(type: type, genre: genre, year: year, smartFilters: smart)
                let normal = R.resolve(titles: list, request: request)
                // The titles the Show menu counts: every effective selection but Show's.
                let showPool = list.filter { t in
                    (normal.selectedType == nil || t.typeKey == normal.selectedType)
                        && (normal.selectedGenre == nil || t.genres.contains { $0.lowercased() == normal.selectedGenre!.lowercased() })
                        && (normal.selectedYear == nil || t.year == normal.selectedYear)
                }
                for menu in Menu.allCases {
                    var keepRequest = request
                    keepRequest.keepVisible = menu
                    let kept = R.resolve(titles: list, request: keepRequest)
                    let hasOption: Bool
                    switch menu {
                    case .type: hasOption = !normal.types.isEmpty
                    case .genre: hasOption = !normal.genres.isEmpty
                    case .year: hasOption = !normal.years.isEmpty
                    case .show: hasOption = !showPool.isEmpty || !normal.smartFilters.isEmpty
                    }
                    let tag = "mask=\(mask) \(request) keep=\(menu)"
                    XCTAssertEqual(shows(kept, menu), shows(normal, menu) || hasOption, tag)
                    if !shows(normal, menu) { if shows(kept, menu) { bites[menu, default: 0] += 1 } else { ignored[menu, default: 0] += 1 } }
                    var rest = kept
                    setShows(&rest, menu, shows(normal, menu))
                    if menu == .show {
                        let expected = normal.visibleSmartFilters.isEmpty
                            ? LibraryGridPolicy.SmartFilter.allCases.filter { f in showPool.contains { LibraryGridPolicy.passes($0.state, filters: [f]) } }
                            : normal.visibleSmartFilters
                        XCTAssertEqual(kept.visibleSmartFilters, expected, tag)
                        rest.visibleSmartFilters = normal.visibleSmartFilters
                    }
                    if rest != normal { XCTFail("the keep changed more than \(menu): \(tag)"); return }
                }
            } } } }
        }
        for menu in Menu.allCases {
            XCTAssertGreaterThan(bites[menu] ?? 0, 0, "\(menu): no case where the keep draws a menu the rule hides")
            XCTAssertGreaterThan(ignored[menu] ?? 0, 0, "\(menu): no case where the keep has nothing to draw")
        }
    }

    // MARK: - LibraryBarKeep: the event table

    private static let foci: [LibraryBarFocus?] = [nil] + LibraryBarFocus.allCases.map { $0 }
    private static let events: [Keep.Event] =
        Menu.allCases.map { .picked($0) } + foci.map { .focus($0) } + [.clearFilters, .contextChanged]

    /// Every state the reducer can reach from a fresh bar (closed under every event).
    private func reachable() -> [Keep] {
        var seen: [Keep] = [Keep()]
        var queue = seen
        while let s = queue.popLast() {
            for e in Self.events {
                let next = s.applying(e)
                if !seen.contains(next) { seen.append(next); queue.append(next) }
            }
        }
        return seen
    }

    /// The full table: every reachable state against every event.
    func testTheEventTable() {
        let states = reachable()
        XCTAssertEqual(states.count, 5 * 9, "every kept menu (or none) with every focus")
        for s in states {
            for e in Self.events {
                let n = s.applying(e)
                let tag = "\(s) + \(e) = \(n)"
                switch e {
                case .picked(let m):
                    XCTAssertEqual(n.menu, m, tag)
                    XCTAssertEqual(n.focus, s.focus, tag)
                case .focus(let f?):
                    XCTAssertEqual(n.focus, f, tag)
                    if let m = s.menu, Keep.control(for: m) == f {
                        XCTAssertEqual(n.menu, m, "focus on the kept menu keeps it: \(tag)")
                    } else {
                        XCTAssertNil(n.menu, "focus on another bar control releases the keep: \(tag)")
                    }
                case .focus(.none):
                    XCTAssertNil(n.focus, tag)
                    XCTAssertEqual(n.menu, s.menu, "focus outside the bar never releases: \(tag)")
                case .clearFilters, .contextChanged:
                    XCTAssertNil(n.menu, tag)
                    XCTAssertEqual(n.focus, s.focus, tag)
                }
            }
        }
    }

    /// No sequence of `focus(nil)` and `focus(M)` events ever releases M: every such sequence up to
    /// length 6 (pickers opening and closing, Down into the grid and back), from every state.
    func testOutsideAndOwnFocusNeverReleaseTheKeptMenu() {
        for s in reachable() {
            for m in Menu.allCases {
                let own: [Keep.Event] = [.focus(nil), .focus(Keep.control(for: m))]
                for length in 0...6 {
                    for code in 0..<(1 << length) {
                        var k = s.applying(.picked(m))
                        for i in 0..<length { k.apply(own[(code >> i) & 1]) }
                        if k.menu != m { XCTFail("\(s) pick \(m), sequence \(code)/\(length) released it"); return }
                    }
                }
                // Then a move to any other bar control releases it.
                for f in LibraryBarFocus.allCases where f != Keep.control(for: m) {
                    XCTAssertNil(s.applying(.picked(m)).applying(.focus(nil)).applying(.focus(f)).menu, "\(m) → \(f)")
                }
            }
        }
    }

    /// The device sequences, in both orders the platform may report focus while a picker is up
    /// (outside the bar, as the sim does, or still on the menu).
    func testTheDeviceSequence() {
        for pickerTakesFocus in [true, false] {
            let open: [Keep.Event] = pickerTakesFocus ? [.focus(nil)] : []
            let close: [Keep.Event] = pickerTakesFocus ? [.focus(.type)] : []
            var k = Keep()
            func run(_ events: [Keep.Event], _ what: String) {
                for e in events { k.apply(e) }
                XCTAssertEqual(k.menu, .type, "\(what) (picker takes focus: \(pickerTakesFocus))")
            }
            k.apply(.focus(.type))
            run(open + [.picked(.type)] + close, "All types")
            // Reopen the kept menu, dismiss with Menu.
            run(open + close, "reopen, Menu")
            // Reopen, pick Series, then reopen and pick All types again.
            run(open + [.picked(.type)] + close, "reopen, Series")
            run(open + [.picked(.type)] + close, "reopen, All types again")
            // Down into the grid and Up back onto the kept menu.
            run([.focus(nil), .focus(.type)], "grid and back")
            k.apply(.focus(.genre))
            XCTAssertNil(k.menu, "Right to Genre releases Type")
            // Down from the kept Year menu: still kept; back to the bar on another control releases it.
            var j = Keep()
            j.apply(.focus(.year))
            j.apply(.picked(.year))
            for e in open + (pickerTakesFocus ? [Keep.Event.focus(.year)] : []) { j.apply(e) }
            j.apply(.focus(nil))
            XCTAssertEqual(j.menu, .year, "Down into the grid keeps Year")
            j.apply(.focus(.watch))
            XCTAssertNil(j.menu, "back on Show releases Year")
        }
    }

    // MARK: - Clear Filters focus

    /// Every combination of what draws after Clear Filters: Genre, Year, Show, Type, Sort in that
    /// order, never a control that is not drawn, nil only when none draws.
    func testClearFiltersFallback() {
        for mask in 0..<32 {
            let shown = Keep.Shown(type: mask & 1 != 0, genre: mask & 2 != 0, year: mask & 4 != 0, show: mask & 8 != 0, sort: mask & 16 != 0)
            let order: [(Bool, LibraryBarFocus)] = [(shown.genre, .genre), (shown.year, .year), (shown.show, .watch), (shown.type, .type), (shown.sort, .sort)]
            XCTAssertEqual(Keep.focusAfterClear(shown), order.first { $0.0 }?.1, "\(shown)")
        }
        XCTAssertEqual(Keep.focusAfterClear(.init(type: true, genre: false, year: false, show: false, sort: true)), .type)
        XCTAssertEqual(Keep.focusAfterClear(.init(type: false, genre: false, year: false, show: false, sort: true)), .sort)
    }

    func testControlsAndMenusMapBothWays() {
        for m in Menu.allCases { XCTAssertEqual(Keep.menu(for: Keep.control(for: m)), m) }
        XCTAssertEqual(LibraryBarFocus.allCases.compactMap(Keep.menu(for:)).count, 4)
    }
}
