import XCTest

/// W5 (upstream ports, Library filters): the Library filter bar, one row of menus (the owner's
/// pick, decision G: List · Type · Genre · Year · Show · Sort · Refresh · Clear Filters), on the
/// canned libraries `-debug.libraryFixture provider|local` (no repository reads or writes). Spec:
/// `docs/batch-upstream-ports-spec-w5.md` 4.3 and 6.3 in the outer repo.
///
/// Oracle: the DEBUG probe `debug_library_bar` (`-debug.libraryBarGeometry YES`):
/// `pane= pill= row1= row2= row1w= bar= count= content= list= type= genre= year= show= focus=
/// fminx= fmaxx= widths=`. Sizes are laid-out values from `onGeometryChange` (never accessibility
/// frames, which carry the focus lift); `focus=` is the bar's own `@FocusState` token and
/// `fminx`/`fmaxx` that control's laid-out extent in the pane's coordinate space, scroll offset
/// included, so "the focused pill is on screen" is `0 <= fminx` and `fmaxx <= pane`.
///
/// Helpers are this file's own (the harness's duplication rule).
final class LibraryFilterBarUITests: XCTestCase {

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
        print("[LibraryFilterBarUITests] \(name): \(text)")
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

    private static func arguments(fixture: String = "provider", navigation: String = "tabs") -> [String] {
        ["-debug.libraryFixture", fixture, "-debug.libraryBarGeometry", "YES",
         "-sidebar_style", navigation, "-rail_visibility", "always", "-discover_placement", "off",
         "-home_upcoming_row_enabled", "NO", "-inline_trailers_enabled", "NO",
         "-debug.rememberLastProfile", "NO"]
    }

    /// Fresh launch, the profile gate ("Chris", selected only once it reads focused), `settle`.
    @discardableResult
    private func launch(_ arguments: [String], settle: TimeInterval = 12) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the fixture set up?")
        if chris.exists {
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        }
        pause(settle)
        return app
    }

    // MARK: - Readouts

    private func label(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        return element.exists ? element.label : ""
    }

    private func probe(_ app: XCUIApplication) -> String { label(app, "debug_library_bar") }
    private func railState(_ app: XCUIApplication) -> String { label(app, "rail_state") }

    private static func token(_ line: String, _ key: String) -> String? {
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == Substring(key) else { continue }
            return String(pair[1])
        }
        return nil
    }

    private static func int(_ line: String, _ key: String) -> Int? { token(line, key).flatMap { Int($0) } }

    private func value(_ app: XCUIApplication, _ key: String) -> String { Self.token(probe(app), key) ?? "?" }
    private func number(_ app: XCUIApplication, _ key: String) -> Int? { Self.int(probe(app), key) }
    private func barFocus(_ app: XCUIApplication) -> String { value(app, "focus") }

    /// The focused bar control lies inside the pane (laid-out extent, scroll offset included).
    private func focusedControlVisible(_ app: XCUIApplication) -> Bool {
        let line = probe(app)
        guard let minX = Self.int(line, "fminx"), let maxX = Self.int(line, "fmaxx"),
              let pane = Self.int(line, "pane") else { return false }
        return minX >= -1 && maxX <= pane + 1
    }

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

    private func focusedSummary(_ app: XCUIApplication) -> String {
        focusedNodes(app).map { "\($0.identifier.isEmpty ? "-" : $0.identifier)|\($0.label)" }.joined(separator: ", ")
    }

    private func tabBarFocused(_ app: XCUIApplication) -> Bool {
        Self.tabTitles.contains { app.buttons[$0].exists && app.buttons[$0].hasFocus }
    }

    /// Whether `element` holds focus, by frame when its own `hasFocus` never reports (menu rows).
    private func hasFocusByFrame(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if element.hasFocus { return true }
        let a = element.frame
        return focusedNodes(app).contains { abs($0.frame.midY - a.midY) < 14 && abs($0.frame.midX - a.midX) < 60 }
    }

    /// Opens Library: the tab bar (walk to "Library", Select) or the rail (Left, item 2, Select,
    /// then Right to close it). Waits for the bar's probe.
    private func openLibrary(_ app: XCUIApplication, rail: Bool) throws {
        if rail {
            for _ in 0..<15 where Self.token(railState(app), "expanded") != "1" {
                remote.press(.left)
                pause(0.6)
            }
            guard Self.token(railState(app), "expanded") == "1" else {
                throw HarnessAbort("the rail never opened from a Left walk — \(railState(app))")
            }
            for _ in 0..<10 {
                guard let current = Self.int(railState(app), "focused") else { break }
                if current == 2 { break }
                if current >= 0 { remote.press(current < 2 ? .down : .up) }
                pause(0.5)
            }
            guard Self.token(railState(app), "focused") == "2" else {
                throw HarnessAbort("the rail's focus never reached Library (2) — \(railState(app))")
            }
            remote.press(.select)
            guard poll(15, { !probe(app).isEmpty }) else { throw HarnessAbort("no debug_library_bar probe (rail)") }
            pause(2)
            for _ in 0..<4 where Self.token(railState(app), "expanded") == "1" {
                remote.press(.right)
                pause(1.0)
            }
        } else {
            for _ in 0..<20 where !tabBarFocused(app) {
                remote.press(.up)
                pause(0.4)
            }
            guard tabBarFocused(app) else { throw HarnessAbort("the tab bar never took focus — \(focusedSummary(app))") }
            let library = app.buttons["Library"]
            for _ in 0..<8 where !library.hasFocus {
                remote.press(.right)
                pause(0.6)
            }
            guard library.hasFocus else { throw HarnessAbort("the Library tab never took focus — \(focusedSummary(app))") }
            remote.press(.select)
            guard poll(15, { !probe(app).isEmpty }) else { throw HarnessAbort("no debug_library_bar probe") }
            pause(2)
        }
    }

    /// Puts focus on a bar control: Down from the tab bar, else Up from the content.
    private func enterBar(_ app: XCUIApplication) throws {
        for _ in 0..<5 where barFocus(app) == "-" {
            remote.press(tabBarFocused(app) ? .down : .up)
            pause(0.8)
        }
        guard barFocus(app) != "-" else { throw HarnessAbort("focus never reached the bar — \(probe(app)) | \(focusedSummary(app))") }
    }

    @discardableResult
    private func moveBar(_ app: XCUIApplication, to token: String, _ direction: XCUIRemote.Button, max: Int = 10) -> Bool {
        for _ in 0..<max where barFocus(app) != token {
            remote.press(direction)
            pause(0.7)
        }
        return barFocus(app) == token
    }

    /// With a picker open: Down (then Up) until the row whose label begins with `prefix` holds
    /// focus, then Select. False (picker closed by Menu) when the row is missing or never focused.
    private func pick(_ app: XCUIApplication, _ prefix: String, step: String) -> Bool {
        pause(1.2)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND NOT identifier BEGINSWITH 'library.'", prefix)).firstMatch
        guard row.waitForExistence(timeout: 4) else {
            shot("\(step)-no-row")
            remote.press(.menu)
            pause(1)
            return false
        }
        for _ in 0..<14 where !hasFocusByFrame(app, row) {
            remote.press(.down)
            pause(0.6)
        }
        for _ in 0..<14 where !hasFocusByFrame(app, row) {
            remote.press(.up)
            pause(0.6)
        }
        guard hasFocusByFrame(app, row) else {
            shot("\(step)-unfocused")
            remote.press(.menu)
            pause(1)
            return false
        }
        remote.press(.select)
        pause(1.5)
        return true
    }

    /// Walks the row from its first control to its last by Right presses, checking at every step
    /// that the focused pill lies inside the pane. Returns the tokens in order.
    private func walkRow(_ app: XCUIApplication, tag: String) -> [String] {
        // Left only until List (the first control): one more Left there would open the rail.
        moveBar(app, to: "list", .left, max: 12)
        var tokens = [barFocus(app)]
        XCTAssertTrue(focusedControlVisible(app), "\(tag): \(tokens[0]) must be on screen — \(probe(app))")
        for _ in 0..<12 {
            remote.press(.right)
            pause(0.8)
            let now = barFocus(app)
            if now == tokens.last { break }
            tokens.append(now)
            XCTAssertTrue(focusedControlVisible(app), "\(tag): \(now) must be on screen — \(probe(app))")
        }
        return tokens
    }

    // MARK: - Geometry (spec 4.3)

    /// Option B keeps today's height: one row, `row = pill + 16`, `bar = row`, no row 2. The local
    /// library (no List, no Refresh) fits the pane; a provider library is expected to scroll, so
    /// there the leg records the widths and checks the last control is reachable by Right presses.
    func testOneRowBarGeometry() throws {
        do {
            let app = launch(Self.arguments(fixture: "local"))
            defer { app.terminate() }
            try openLibrary(app, rail: false)
            let line = probe(app)
            note("geometry-local", line)
            let pill = try XCTUnwrap(Self.int(line, "pill")), row1 = try XCTUnwrap(Self.int(line, "row1"))
            let bar = try XCTUnwrap(Self.int(line, "bar")), pane = try XCTUnwrap(Self.int(line, "pane"))
            let row1w = try XCTUnwrap(Self.int(line, "row1w"))
            XCTAssertEqual(Double(row1), Double(pill + 16), accuracy: 1, line)
            XCTAssertEqual(Self.int(line, "row2"), 0, line)
            XCTAssertEqual(Double(bar), Double(row1), accuracy: 1, line)
            XCTAssertLessThanOrEqual(row1w, pane, "the local library's row must fit the pane: \(line)")
            shot("geometry-local")
        }
        do {
            let app = launch(Self.arguments(fixture: "provider"))
            defer { app.terminate() }
            try openLibrary(app, rail: false)
            let line = probe(app)
            note("geometry-provider", line)
            let pill = try XCTUnwrap(Self.int(line, "pill")), row1 = try XCTUnwrap(Self.int(line, "row1"))
            XCTAssertEqual(Double(row1), Double(pill + 16), accuracy: 1, line)
            XCTAssertEqual(Self.int(line, "row2"), 0, line)
            XCTAssertEqual(Double(try XCTUnwrap(Self.int(line, "bar"))), Double(row1), accuracy: 1, line)
            try enterBar(app)
            let tokens = walkRow(app, tag: "geometry-provider")
            note("geometry-provider-walk", "\(tokens.joined(separator: " → "))\n\(probe(app))")
            XCTAssertEqual(tokens.last, "refresh", "the last control must be reachable by Right presses: \(tokens)")
            shot("geometry-provider-last")
        }
    }

    // MARK: - Focus traversal (spec 6.3, adapted to the one row of menus)

    func testBarFocusTraversal() throws {
        for rail in [false, true] {
            let tag = rail ? "rail" : "tabs"
            let app = launch(Self.arguments(fixture: "provider", navigation: rail ? "rail" : "tabs"))
            defer { app.terminate() }
            do {
                try openLibrary(app, rail: rail)
                try enterBar(app)
            } catch {
                shot("traversal-\(tag)-route-failed")
                XCTFail("\(tag): \(error)")
                continue
            }
            var log: [String] = ["start: \(probe(app))"]

            // The whole row, left to right, every pill on screen as it takes focus.
            let tokens = walkRow(app, tag: tag)
            log.append("walk: \(tokens.joined(separator: " → "))")
            XCTAssertEqual(tokens, ["list", "type", "genre", "year", "watch", "sort", "refresh"], "\(tag): \(probe(app))")
            shot("traversal-\(tag)-1-refresh")

            // Back to Genre (the row scrolls back), pick Comedy.
            XCTAssertTrue(moveBar(app, to: "genre", .left), "\(tag): \(probe(app))")
            XCTAssertTrue(focusedControlVisible(app), "\(tag): Genre must be on screen — \(probe(app))")
            remote.press(.select)
            XCTAssertTrue(pick(app, "Comedy", step: "traversal-\(tag)-genre"))
            log.append("comedy: \(probe(app))")
            XCTAssertEqual(value(app, "genre"), "Comedy")
            XCTAssertEqual(number(app, "count"), 5, probe(app))

            // Year 2022.
            XCTAssertTrue(moveBar(app, to: "year", .right), "\(tag): \(probe(app))")
            remote.press(.select)
            XCTAssertTrue(pick(app, "2022", step: "traversal-\(tag)-year"))
            log.append("2022: \(probe(app))")
            XCTAssertEqual(value(app, "year"), "2022")
            XCTAssertEqual(number(app, "count"), 1, probe(app))

            // Clear Filters, at the far end: on screen when focused, then focus on a visible Genre.
            XCTAssertTrue(moveBar(app, to: "clear", .right, max: 12), "\(tag): \(probe(app))")
            XCTAssertTrue(focusedControlVisible(app), "\(tag): Clear Filters must be on screen — \(probe(app))")
            shot("traversal-\(tag)-2-clear-focused")
            remote.press(.select)
            pause(1.5)
            log.append("cleared: \(probe(app))")
            XCTAssertEqual(value(app, "genre"), "-", probe(app))
            XCTAssertEqual(value(app, "year"), "-", probe(app))
            XCTAssertEqual(value(app, "show"), "all", probe(app))
            XCTAssertEqual(number(app, "count"), 14, probe(app))
            XCTAssertEqual(barFocus(app), "genre", probe(app))
            XCTAssertTrue(focusedControlVisible(app), "\(tag): Genre must be scrolled back on screen — \(probe(app))")
            shot("traversal-\(tag)-3-cleared")

            // Down into the grid, Up back into the bar.
            remote.press(.down)
            pause(1.0)
            let grid = focusedSummary(app)
            log.append("down: \(probe(app)) | \(grid)")
            XCTAssertEqual(barFocus(app), "-", "\(tag): Down must leave the bar — \(probe(app))")
            XCTAssertFalse(grid.isEmpty || grid.contains("library."), "\(tag): a grid card must hold focus — \(grid)")
            remote.press(.up)
            pause(1.0)
            log.append("up: \(probe(app))")
            XCTAssertNotEqual(barFocus(app), "-", "\(tag): Up from the grid must land in the bar — \(probe(app))")
            note("traversal-\(tag)", log.joined(separator: "\n"))
        }
    }

    // MARK: - States and menus

    /// The no-matches state's own Clear Filters, a list change resetting the type, the Genre menu's
    /// two science-fiction rows, and the pill widths with filters set (for the owner's question).
    func testNoMatchesListResetAndMenuRows() throws {
        let app = launch(Self.arguments(fixture: "provider"))
        defer { app.terminate() }
        try openLibrary(app, rail: false)
        try enterBar(app)
        note("widths-rest", probe(app))

        // Genre menu rows: "Sci-Fi" and the Trakt slug "science-fiction" ("Science Fiction") stay two.
        XCTAssertTrue(moveBar(app, to: "genre", .right) || moveBar(app, to: "genre", .left), probe(app))
        remote.press(.select)
        pause(1.5)
        let sciFi = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Sci-Fi")).firstMatch
        let slug = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Science Fiction")).firstMatch
        let rows = "Sci-Fi=\(sciFi.exists ? sciFi.label : "missing") ScienceFiction=\(slug.exists ? slug.label : "missing")"
        note("genre-rows", rows)
        XCTAssertTrue(sciFi.exists && slug.exists, rows)
        remote.press(.menu)
        pause(1.0)

        // Watched, then Horror: nothing matches; the state's own Clear Filters restores the grid.
        XCTAssertTrue(moveBar(app, to: "watch", .right), probe(app))
        remote.press(.select)
        XCTAssertTrue(pick(app, "Watched", step: "nomatch-watched"))
        note("widths-show-watched", probe(app))
        XCTAssertTrue(moveBar(app, to: "genre", .left), probe(app))
        remote.press(.select)
        XCTAssertTrue(pick(app, "Horror", step: "nomatch-horror"))
        note("widths-genre-and-show", probe(app))
        XCTAssertEqual(value(app, "content"), "noMatches", probe(app))
        shot("nomatches")
        let clear = app.descendants(matching: .any)["library.noMatches.clearFilters"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        for _ in 0..<3 where !hasFocusByFrame(app, clear) {
            remote.press(.down)
            pause(0.8)
        }
        XCTAssertTrue(hasFocusByFrame(app, clear), focusedSummary(app))
        remote.press(.select)
        pause(1.5)
        note("nomatches-cleared", probe(app))
        XCTAssertEqual(value(app, "content"), "grid", probe(app))
        XCTAssertEqual(number(app, "count"), 14, probe(app))
        XCTAssertEqual(value(app, "genre"), "-")
        XCTAssertEqual(value(app, "show"), "all")

        // Type Series, then another list: the type goes back to All.
        try enterBar(app)
        XCTAssertTrue(moveBar(app, to: "type", .left, max: 6) || moveBar(app, to: "type", .right, max: 6), probe(app))
        remote.press(.select)
        XCTAssertTrue(pick(app, "Series", step: "type-series"))
        XCTAssertEqual(value(app, "type"), "series", probe(app))
        XCTAssertTrue(moveBar(app, to: "list", .left), probe(app))
        remote.press(.select)
        XCTAssertTrue(pick(app, "Weekend Movies", step: "list-weekend"))
        note("list-reset", probe(app))
        XCTAssertEqual(value(app, "list"), "fx-list-weekend", probe(app))
        XCTAssertEqual(value(app, "type"), "-", "a new list starts on All types: \(probe(app))")
        XCTAssertEqual(number(app, "count"), 8, probe(app))
        shot("list-reset")
    }
}
