import XCTest

/// Search & Discover batch (W3, 2026-10-06): the stage Discover page's UI legs, plan A8 D01–D07
/// (`docs/search-discover-stage-plan-2026-10-06.md`). Every leg pins Stage Home, Discover as its own
/// tab and the strip's motion probe (`-home_layout stage -discover_placement tab
/// -debug.homeScrollProbe YES`), plus the navigation chrome (`tabs` unless a leg asks for `rail`),
/// so a stored choice can never change what Up or Menu reaches.
///
/// Oracles are the DEBUG readouts, never frames of moving things (XCUITest frames ignore SwiftUI
/// offsets, scale and opacity):
///   - `discover_rows_state mode=rows rows= removed= row= order= disp= state= type= catalog= loaded=
///     inflight= strip=` (`strip=1` while a strip row holds focus; `row` is the focused row's index
///     among the rows focus can land on, and keeps its last value while the band holds focus);
///   - `debug_stage_discover` (the page's own stage; Home's is `debug_stage`);
///   - `rail_state` in Rail mode.
///
/// Fixture facts (FA87, tvOS 26.5 simulator, guest "Chris" with Cinemeta, Medium posters, Linear
/// keyboard): Cinemeta's `top` catalogs carry the genre extra, so Discover shows one row per genre
/// ("Action · Cinemeta"); `hasFocus` works on 26.5. D1's hand-off note: on the `.tab` host there is
/// NO automatic initial focus (it would yank focus from the system tab bar), so in Tabs mode focus
/// sits on the tab bar after the tab opens, the first Down lands on the pill band and `row=0` holds
/// only after a Down from the band.
///
/// Helpers are this file's own (the harness's duplication rule).
final class StageDiscoverUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private struct HarnessAbort: Error, CustomStringConvertible {
        let description: String
        init(_ reason: String) { description = reason }
    }

    // MARK: - Basics

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[StageDiscoverUITests] \(name): \(text)")
    }

    private func poll(_ timeout: TimeInterval, step: TimeInterval = 0.2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(step)
        }
        return condition()
    }

    // MARK: - Launch

    private static func arguments(placement: String = "tab", navigation: String = "tabs") -> [String] {
        ["-home_layout", "stage", "-discover_placement", placement, "-debug.homeScrollProbe", "YES",
         "-home_upcoming_row_enabled", "NO", "-inline_trailers_enabled", "NO",
         "-sidebar_style", navigation, "-rail_visibility", "always"]
    }

    /// Fresh launch, the profile gate ("Chris" is first and focused; Left, Left, Select), `settle`.
    @discardableResult
    private func launch(_ arguments: [String], settle: TimeInterval = 14) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the FA87 fixture set up?")
        if chris.exists {
            remote.press(.left)
            pause(0.5)
            remote.press(.left)
            pause(0.5)
            remote.press(.select)
        }
        pause(settle)
        return app
    }

    // MARK: - Readouts

    private func label(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        return element.exists ? element.label : ""
    }

    private func discover(_ app: XCUIApplication) -> String { label(app, "discover_rows_state") }
    private func railState(_ app: XCUIApplication) -> String { label(app, "rail_state") }

    private static func token(_ line: String, _ key: String) -> String? {
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == Substring(key) else { continue }
            return String(pair[1])
        }
        return nil
    }

    private static func int(_ line: String, _ key: String) -> Int? {
        token(line, key).flatMap { Int($0) }
    }

    private func row(_ app: XCUIApplication) -> Int? { Self.int(discover(app), "row") }
    private func stripFocused(_ app: XCUIApplication) -> Bool { Self.token(discover(app), "strip") == "1" }

    // MARK: - Focus

    private static let tabTitles = ["Home", "Search", "Discover", "Library", "Add-ons", "Settings", "Profile"]

    private func focusedNodes(_ app: XCUIApplication) -> [(identifier: String, label: String, frame: CGRect)] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [(identifier: String, label: String, frame: CGRect)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { out.append((node.identifier, node.label, node.frame)) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    private func tabBarFocused(_ app: XCUIApplication) -> Bool {
        Self.tabTitles.contains { app.buttons[$0].exists && app.buttons[$0].hasFocus }
    }

    /// Whether `element` holds focus, by frame when its own `hasFocus` never reports (a `Menu`'s
    /// focusable node is not the element that carries its identifier; same centre ±12 / ±40 pt).
    private func hasFocusByFrame(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if element.hasFocus { return true }
        let a = element.frame
        return focusedNodes(app).contains { abs($0.frame.midY - a.midY) < 12 && abs($0.frame.midX - a.midX) < 40 }
    }

    @discardableResult
    private func moveFocus(_ app: XCUIApplication, _ direction: XCUIRemote.Button, untilFrameOf element: XCUIElement, max: Int = 8) -> Bool {
        for _ in 0..<max {
            if hasFocusByFrame(app, element) { return true }
            remote.press(direction)
            pause(0.7)
        }
        return hasFocusByFrame(app, element)
    }

    private func pill(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    // MARK: - Discover

    /// Tabs mode: climb to the tab bar, walk to "Discover", select. Rail mode: open the rail by
    /// Left, walk to the Discover item (id 6, under Search), select. Then waits for the page.
    private func openDiscover(_ app: XCUIApplication) throws {
        if !railState(app).isEmpty {
            for _ in 0..<15 where Self.token(railState(app), "expanded") != "1" {
                remote.press(.left)
                pause(0.5)
            }
            guard Self.token(railState(app), "expanded") == "1" else {
                throw HarnessAbort("the rail never opened from a Left walk — \(railState(app))")
            }
            for _ in 0..<8 where Self.int(railState(app), "focused") != 6 {
                let current = Self.int(railState(app), "focused") ?? -1
                remote.press(current == 0 || current == 1 ? .down : .up)
                pause(0.5)
            }
            guard Self.int(railState(app), "focused") == 6 else {
                throw HarnessAbort("the rail's focus never reached the Discover item — \(railState(app))")
            }
            remote.press(.select)
            pause(2.5)
        } else {
            for _ in 0..<40 where !tabBarFocused(app) {
                remote.press(.up)
                pause(0.35)
            }
            let tab = app.buttons["Discover"]
            guard tab.waitForExistence(timeout: 4) else {
                throw HarnessAbort("no Discover tab in the tab bar (placement tab)")
            }
            for _ in 0..<8 where !(tab.hasFocus) {
                remote.press(.right)
                pause(0.6)
            }
            for _ in 0..<8 where !(tab.hasFocus) {
                remote.press(.left)
                pause(0.6)
            }
            guard tab.hasFocus else { throw HarnessAbort("focus never reached the Discover tab") }
            remote.press(.select)
            pause(2.0)
        }
        try requireRows(app)
    }

    /// Waits for the page to settle on rows (`state=rows` with a loaded row).
    private func requireRows(_ app: XCUIApplication) throws {
        let ready = poll(30, step: 0.5) {
            let line = discover(app)
            return Self.token(line, "state") == "rows" && (Self.int(line, "loaded") ?? 0) >= 1
        }
        guard ready else {
            throw HarnessAbort("the Discover page never settled on rows: '\(discover(app))'")
        }
    }

    /// Down until a strip row holds focus on row 0 (Tabs: tab bar → band → row 0).
    private func requireRow0(_ app: XCUIApplication) throws {
        for _ in 0..<4 {
            if stripFocused(app), row(app) == 0 { return }
            remote.press(.down)
            _ = poll(2.5) { stripFocused(app) && row(app) == 0 }
        }
        guard stripFocused(app), row(app) == 0 else {
            throw HarnessAbort("focus never reached strip row 0: '\(discover(app))' focused=\(focusedNodes(app).map(\.label))")
        }
        pause(1.0)
    }

    /// From strip row 0, Up to the pill band (`strip=0`, a pill holding focus).
    private func upToBand(_ app: XCUIApplication) -> Bool {
        remote.press(.up)
        return poll(3) { !stripFocused(app) }
    }

    // MARK: - D01

    /// D01: the Discover tab sits after Search; opening it settles on rows, and a Down from the band
    /// puts `row=0` on the strip. The page's own stage readout is mounted.
    func testD01_TabOpensOnRows() throws {
        let app = launch(Self.arguments())
        let search = app.buttons["Search"], tab = app.buttons["Discover"], library = app.buttons["Library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 6), "the Discover tab must exist at placement tab")
        if tab.exists, search.exists, library.exists {
            XCTAssertGreaterThan(tab.frame.midX, search.frame.midX, "Discover comes after Search: \(tab.frame) vs \(search.frame)")
            XCTAssertLessThan(tab.frame.midX, library.frame.midX, "Discover comes before Library: \(tab.frame) vs \(library.frame)")
        }
        try openDiscover(app)
        note("D01_opened", discover(app))
        try requireRow0(app)
        let line = discover(app)
        note("D01_row0", "\(line) | stage=\(label(app, "debug_stage_discover"))")
        shot("discover-tab-stage")
        XCTAssertEqual(Self.int(line, "row"), 0, "\(line)")
        XCTAssertEqual(Self.token(line, "state"), "rows", "\(line)")
        XCTAssertFalse(label(app, "debug_stage_discover").isEmpty, "the page's stage readout must be mounted")
    }

    // MARK: - D02

    /// D02: Down from row 0 pages one genre (`row=1`), and the row headings read "<genre> · <add-on>".
    func testD02_DownPagesOneGenre() throws {
        let app = launch(Self.arguments())
        try openDiscover(app)
        try requireRow0(app)
        remote.press(.down)
        XCTAssertTrue(poll(4) { row(app) == 1 && stripFocused(app) }, "one Down must reach row 1: \(discover(app))")
        pause(1.5)
        let headings = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " \u{00B7} ")).allElementsBoundByIndex.map(\.label)
        note("D02_row1", "\(discover(app)) headings=\(headings)")
        shot("discover-row1")
        XCTAssertFalse(headings.isEmpty, "row headings must read '<genre> · <add-on>'")
    }

    // MARK: - D03

    /// D03: Up from row 1 returns to row 0, and Up from row 0 leaves the strip for the pill band
    /// (`strip=0`, `discover.typePicker` on screen). Token-based (no reliance on a pill's own focus).
    func testD03_UpFromRow0ToPills() throws {
        let app = launch(Self.arguments())
        try openDiscover(app)
        try requireRow0(app)
        remote.press(.down)
        _ = poll(4) { row(app) == 1 }
        remote.press(.up)
        XCTAssertTrue(poll(4) { row(app) == 0 && stripFocused(app) }, "Up from row 1 must return to row 0: \(discover(app))")
        pause(1.0)
        XCTAssertTrue(upToBand(app), "Up from row 0 must leave the strip (strip=0): \(discover(app))")
        pause(1.0)
        let type = pill(app, "discover.typePicker")
        note("D03_band", "\(discover(app)) focused=\(focusedNodes(app).map(\.label)) typePicker=\(type.exists ? "\(type.frame)" : "absent") grid=\(pill(app, "discover.gridButton").exists) catalog=\(pill(app, "discover.catalogPicker").exists)")
        shot("discover-pills")
        XCTAssertTrue(type.exists, "the Type pill must be on screen with the band active")
        XCTAssertFalse(tabBarFocused(app), "one Up from row 0 must stop on the band, not the tab bar")
    }

    // MARK: - D04

    /// D04: the Grid pill opens today's `CatalogGridView` for the focused genre (the page's probe
    /// leaves the tree and a grid of posters shows the row's title), and Menu comes back to the page
    /// with the strip still on row 0.
    func testD04_GridPillRoundTrip() throws {
        let app = launch(Self.arguments())
        try openDiscover(app)
        try requireRow0(app)
        // A row heading ("Action · Cinemeta"), not the stage's meta line ("2026 · Action · …").
        let heading = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " \u{00B7} Cinemeta")).firstMatch
        let rowHeading = heading.exists ? heading.label : ""
        XCTAssertTrue(upToBand(app), "Up from row 0 must reach the band: \(discover(app))")
        let grid = pill(app, "discover.gridButton")
        guard grid.waitForExistence(timeout: 3) else { throw HarnessAbort("discover.gridButton missing") }
        guard moveFocus(app, .right, untilFrameOf: grid, max: 4) || moveFocus(app, .left, untilFrameOf: grid, max: 4) else {
            throw HarnessAbort("focus never reached the Grid pill — focused=\(focusedNodes(app).map(\.label))")
        }
        remote.press(.select)
        let opened = poll(6) { app.descendants(matching: .any)["discover_rows_state"].firstMatch.exists == false }
        pause(3.0)
        let gridTitle = rowHeading.split(separator: "\u{00B7}").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let titleShown = !gridTitle.isEmpty && app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", gridTitle)).firstMatch.exists
        let posters = app.buttons.allElementsBoundByIndex.filter { $0.frame.width > 100 && $0.frame.height > 150 }.count
        note("D04_grid", "opened=\(opened) heading='\(rowHeading)' gridTitle='\(gridTitle)' titleShown=\(titleShown) posterButtons=\(posters)")
        shot("discover-grid")
        XCTAssertTrue(opened, "the Grid pill must push the grid over the Discover page")
        XCTAssertGreaterThan(posters, 3, "the grid must show posters")
        remote.press(.menu)
        XCTAssertTrue(poll(6) { !discover(app).isEmpty }, "Menu must pop back to the Discover page")
        pause(1.5)
        note("D04_back", "\(discover(app)) focused=\(focusedNodes(app).map(\.label))")
        XCTAssertEqual(row(app), 0, "back on the page, the strip still reads row 0: \(discover(app))")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - D05

    /// D05 (Tabs): Menu at row 2 pages back to row 0; a second Menu at row 0 goes to the system
    /// default (the tab bar takes focus). Never a third Menu (the next would leave the app).
    func testD05_MenuRow2ToRow0ThenTabBar() throws {
        let app = launch(Self.arguments())
        try openDiscover(app)
        try requireRow0(app)
        for target in 1...2 {
            remote.press(.down)
            _ = poll(4) { row(app) == target }
        }
        XCTAssertEqual(row(app), 2, "two Downs must reach row 2: \(discover(app))")
        remote.press(.menu)
        XCTAssertTrue(poll(4) { row(app) == 0 && stripFocused(app) }, "Menu at row 2 must page to row 0: \(discover(app))")
        XCTAssertEqual(app.state, .runningForeground)
        pause(1.5)
        remote.press(.menu)
        XCTAssertTrue(poll(4) { tabBarFocused(app) }, "Menu at row 0 must hand focus to the tab bar — focused=\(focusedNodes(app).map(\.label)) | \(discover(app))")
        XCTAssertEqual(app.state, .runningForeground, "the second Menu must not leave the app")
        shot("D05_tab_bar")
    }

    /// D05 (Rail): Menu at row 2 pages to row 0 with the rail closed; Menu at row 0 opens the rail
    /// (`reason=menu`). Closed with Right, never Menu (inside a Menu-opened rail Menu suspends).
    func testD05b_MenuRow2ToRow0ThenRail() throws {
        let app = launch(Self.arguments(navigation: "rail"))
        guard poll(10, step: 0.5, { !railState(app).isEmpty }) else {
            throw HarnessAbort("rail_state missing with -sidebar_style rail (DEBUG build?)")
        }
        try openDiscover(app)
        try requireRow0(app)
        for target in 1...2 {
            remote.press(.down)
            _ = poll(4) { row(app) == target }
        }
        XCTAssertEqual(row(app), 2, "two Downs must reach row 2: \(discover(app))")
        remote.press(.menu)
        XCTAssertTrue(poll(4) { row(app) == 0 && stripFocused(app) }, "Menu at row 2 must page to row 0: \(discover(app))")
        XCTAssertEqual(Self.token(railState(app), "expanded"), "0", "the first Menu pages; it must not open the rail: \(railState(app))")
        pause(1.5)
        remote.press(.menu)
        XCTAssertTrue(poll(3) { Self.token(railState(app), "expanded") == "1" }, "Menu at row 0 must open the rail: \(railState(app))")
        note("D05b_rail", railState(app))
        shot("D05b_rail")
        XCTAssertEqual(Self.token(railState(app), "reason"), "menu", "\(railState(app))")
        XCTAssertEqual(Self.token(railState(app), "tab"), "6", "the rail reports the Discover tab: \(railState(app))")
        remote.press(.right)
        pause(1.5)
    }

    // MARK: - D06

    /// D06: placement variants. Off (Tabs): no Discover tab; Off (Rail): no `rail_item_Discover`;
    /// Under Search: no Discover tab, Search's idle page carries the entry row, and a tile pushes
    /// the same stage page (`discover_rows_state`), which Menu pops.
    func testD06_PlacementVariants() throws {
        let offTabs = launch(Self.arguments(placement: "off"))
        XCTAssertTrue(offTabs.buttons["Search"].waitForExistence(timeout: 6))
        XCTAssertFalse(offTabs.buttons["Discover"].exists, "Off: no Discover tab")

        let offRail = launch(Self.arguments(placement: "off", navigation: "rail"))
        XCTAssertTrue(poll(10, step: 0.5) { !railState(offRail).isEmpty }, "rail_state must mount")
        XCTAssertTrue(offRail.descendants(matching: .any)["rail_item_Search"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(offRail.descendants(matching: .any)["rail_item_Discover"].firstMatch.exists, "Off: no rail_item_Discover")

        let under = launch(Self.arguments(placement: "search"))
        XCTAssertFalse(under.buttons["Discover"].exists, "Under Search: no Discover tab")
        for _ in 0..<40 where !tabBarFocused(under) {
            remote.press(.up)
            pause(0.35)
        }
        let search = under.buttons["Search"]
        for _ in 0..<4 where !search.hasFocus {
            remote.press(.right)
            pause(0.6)
        }
        remote.press(.select)
        pause(3.0)
        let entry = under.descendants(matching: .any)["search.discoverEntry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 6), "Under Search: Search's idle page must carry search.discoverEntry")
        shot("search-idle-undersearch")
        // Down from the keyboard: Recent (when the profile has history), then the entry tiles.
        // The focus engine may land on either tile (FA87 landed on Series); both push DiscoverRoute.
        let movies = under.buttons.matching(NSPredicate(format: "label == 'Movies'")).firstMatch
        let series = under.buttons.matching(NSPredicate(format: "label == 'Series'")).firstMatch
        func onTile() -> Bool { hasFocusByFrame(under, movies) || hasFocusByFrame(under, series) }
        for _ in 0..<5 where !onTile() {
            remote.press(.down)
            pause(0.8)
        }
        guard onTile() else {
            XCTFail("focus never reached a Discover entry tile — focused=\(focusedNodes(under).map(\.label))")
            return
        }
        remote.press(.select)
        XCTAssertTrue(poll(8) { !discover(under).isEmpty }, "the Movies tile must push the stage Discover page")
        try requireRows(under)
        note("D06_pushed", discover(under))
        shot("D06_pushed_discover")
        remote.press(.menu)
        pause(1.0)
        if !discover(under).isEmpty { remote.press(.menu); pause(1.0) } // a strip row deeper than 0 pages first
        XCTAssertTrue(poll(4) { discover(under).isEmpty && entry.exists }, "Menu must pop back to Search's idle page")
        XCTAssertEqual(under.state, .runningForeground)
    }

    // MARK: - D07

    /// D07: a Type change through the `discover.typePicker` Menu flips `type=` and rebuilds the rows
    /// (state back to rows with a loaded row of the new type).
    func testD07_TypeChangeRebuildsRows() throws {
        let app = launch(Self.arguments())
        try openDiscover(app)
        try requireRow0(app)
        let before = discover(app)
        let fromType = Self.token(before, "type") ?? "-"
        let toLabel = fromType == "series" ? "Movies" : "Series"
        let toType = fromType == "series" ? "movie" : "series"
        XCTAssertTrue(upToBand(app), "Up from row 0 must reach the band: \(discover(app))")
        let type = pill(app, "discover.typePicker")
        guard type.waitForExistence(timeout: 3) else { throw HarnessAbort("discover.typePicker missing") }
        guard moveFocus(app, .left, untilFrameOf: type, max: 4) || moveFocus(app, .right, untilFrameOf: type, max: 4) else {
            throw HarnessAbort("focus never reached the Type pill — focused=\(focusedNodes(app).map(\.label))")
        }
        remote.press(.select)
        pause(1.5)
        let option = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND identifier != 'discover.typePicker'", toLabel)).firstMatch
        guard option.waitForExistence(timeout: 4) else {
            remote.press(.menu)
            throw HarnessAbort("the Type menu never showed '\(toLabel)'")
        }
        shot("D07_type_menu")
        if !moveFocus(app, .down, untilFrameOf: option, max: 3) { _ = moveFocus(app, .up, untilFrameOf: option, max: 4) }
        guard hasFocusByFrame(app, option) else {
            remote.press(.menu)
            throw HarnessAbort("focus never reached the '\(toLabel)' option — focused=\(focusedNodes(app).map(\.label))")
        }
        remote.press(.select)
        XCTAssertTrue(poll(6) { Self.token(discover(app), "type") == toType }, "type= must flip to \(toType): \(before) → \(discover(app))")
        try requireRows(app)
        pause(1.5)
        let after = discover(app)
        note("D07", "before=\(before)\nafter=\(after)\nfocused=\(focusedNodes(app).map(\.label))")
        shot("D07_after_type_change")
        XCTAssertNotEqual(Self.token(after, "catalog"), Self.token(before, "catalog"), "the catalog must change with the type: \(after)")
        XCTAssertEqual(Self.token(after, "state"), "rows", "\(after)")

        // Restore: the pick is persisted (`discover_catalog_key`), so leave the fixture on its
        // baseline, Movies (the default first catalog), whichever type the leg started from.
        guard toType != "movie" else { return }
        let backLabel = "Movies"
        if !hasFocusByFrame(app, type) {
            for _ in 0..<3 where stripFocused(app) { _ = upToBand(app) }
            if !moveFocus(app, .left, untilFrameOf: type, max: 4) { _ = moveFocus(app, .right, untilFrameOf: type, max: 4) }
        }
        guard hasFocusByFrame(app, type) else {
            XCTFail("restore: focus never returned to the Type pill — the fixture is left on \(toType)")
            return
        }
        remote.press(.select)
        pause(1.5)
        let back = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND identifier != 'discover.typePicker'", backLabel)).firstMatch
        if back.waitForExistence(timeout: 4) {
            if !moveFocus(app, .up, untilFrameOf: back, max: 3) { _ = moveFocus(app, .down, untilFrameOf: back, max: 4) }
            if hasFocusByFrame(app, back) { remote.press(.select) } else { remote.press(.menu) }
        } else {
            remote.press(.menu)
        }
        XCTAssertTrue(poll(6) { Self.token(discover(app), "type") == "movie" }, "restore: type= must return to movie: \(discover(app))")
    }

    // MARK: - Evidence

    /// Evidence only (A7): the Library page's pills on the shared `FilterPills` look.
    func testE01_LibraryPillsEvidence() throws {
        let app = launch(Self.arguments())
        for _ in 0..<40 where !tabBarFocused(app) {
            remote.press(.up)
            pause(0.35)
        }
        let library = app.buttons["Library"]
        for _ in 0..<8 where !library.hasFocus {
            remote.press(.right)
            pause(0.6)
        }
        remote.press(.select)
        pause(4.0)
        note("E01_library", "listPicker=\(app.descendants(matching: .any)["library.listPicker"].firstMatch.exists) sortPicker=\(app.descendants(matching: .any)["library.sortPicker"].firstMatch.exists)")
        shot("library-pills")
    }
}
