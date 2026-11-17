import XCTest

/// W5 (upstream ports, Library filters): the Library filter bar's two candidate layouts, behind the
/// DEBUG switch `-debug.libraryBarLayout A|B`, on the canned library `-debug.libraryFixture provider`
/// (a Trakt-shaped library with two lists, 14 titles, genres and years; no repository reads or
/// writes). Spec: `docs/batch-upstream-ports-spec-w5.md` 4.5 and 6.3 in the outer repo.
///
/// Oracle: the DEBUG probe `debug_library_bar` (`-debug.libraryBarGeometry YES`):
/// `layout= pane= pill= row1= row2= row1w= row2w= bar= gap= count= genre= year= focus=`, all laid-out
/// sizes from `onGeometryChange` (never accessibility frames, which carry the focus lift); `focus=`
/// is the bar's own `@FocusState` token (`genre`, `year`, `watch`, `clear`, `smart.<filter>`, `-`).
///
/// Only the mockup leg for now (decision G picks the layout from its six shots); the geometry and
/// focus legs follow the pick. Helpers are this file's own (the harness's duplication rule).
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

    private static func arguments(layout: String, navigation: String = "tabs") -> [String] {
        ["-debug.libraryFixture", "provider", "-debug.libraryBarLayout", layout, "-debug.libraryBarGeometry", "YES",
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

    private func barFocus(_ app: XCUIApplication) -> String { Self.token(probe(app), "focus") ?? "?" }

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

    /// Tabs mode: climb to the tab bar, walk to "Library" (the tab switches on focus), then wait for
    /// the bar's probe.
    private func openLibraryTab(_ app: XCUIApplication) throws {
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
        guard poll(15, { !probe(app).isEmpty }) else { throw HarnessAbort("no debug_library_bar probe on Library") }
        pause(2)
    }

    /// Rail mode: Left until the rail opens, move to Library (item 2 with Discover off), Select.
    private func openLibraryRail(_ app: XCUIApplication) throws {
        for _ in 0..<15 where Self.token(railState(app), "expanded") != "1" {
            remote.press(.left)
            pause(0.6)
        }
        guard Self.token(railState(app), "expanded") == "1" else {
            throw HarnessAbort("the rail never opened from a Left walk — \(railState(app))")
        }
        for _ in 0..<10 {
            guard let current = Self.token(railState(app), "focused").flatMap({ Int($0) }) else { break }
            if current == 2 { break }
            if current >= 0 { remote.press(current < 2 ? .down : .up) }
            pause(0.5)
        }
        guard Self.token(railState(app), "focused") == "2" else {
            throw HarnessAbort("the rail's focus never reached Library (2) — \(railState(app))")
        }
        remote.press(.select)
        guard poll(15, { !probe(app).isEmpty }) else { throw HarnessAbort("no debug_library_bar probe on Library (rail)") }
        pause(2.5)
    }

    /// Down from the tab bar (or the rail hand-off) until a grid card holds focus: past the bar's
    /// rows (A: two rows, B: one), checked by the focused node sitting below the bar's last pill.
    private func focusGrid(_ app: XCUIApplication, rows: Int) {
        let sort = app.descendants(matching: .any)["library.sortPicker"].firstMatch
        let lowestBarY: CGFloat = {
            let genre = app.descendants(matching: .any)["library.genrePicker"].firstMatch
            let candidates = [sort, genre].filter(\.exists).map(\.frame.maxY)
            return candidates.max() ?? 0
        }()
        for _ in 0..<(rows + 3) {
            let nodes = focusedNodes(app)
            if let node = nodes.first, node.frame.minY > lowestBarY + 10, !Self.tabTitles.contains(node.label) {
                return
            }
            remote.press(.down)
            pause(0.8)
        }
    }

    // MARK: - Mockups (spec 4.5)

    /// Evidence only, both layouts until decision G: for each, the bar at rest (focus in the grid),
    /// with focus on the Genre pill, and with the Genre picker open. Attaches six screenshots
    /// (`library-bar-<A|B>-rest`, `-genre-focus`, `-genre-open`) and the probe line of each; then
    /// one more rest shot per layout with the navigation rail Always Visible (`-rail-rest`).
    func testMockupShots() throws {
        for layout in ["A", "B"] {
            let app = launch(Self.arguments(layout: layout))
            defer { app.terminate() }
            do {
                try openLibraryTab(app)
            } catch {
                shot("library-bar-\(layout)-route-failed")
                XCTFail("layout \(layout): \(error)")
                continue
            }
            XCTAssertEqual(Self.token(probe(app), "layout"), layout, "the probe must report layout \(layout): \(probe(app))")

            // 1. Rest: focus on the grid's first card, nothing in the bar focused.
            focusGrid(app, rows: layout == "A" ? 2 : 1)
            pause(1.5)
            note("library-bar-\(layout)-rest.probe", "\(probe(app))\nfocused=\(focusedSummary(app))")
            shot("library-bar-\(layout)-rest")
            XCTAssertEqual(barFocus(app), "-", "rest: nothing in the bar may hold focus: \(probe(app))")

            // 2. Genre pill focused. A: Up into row 2, then Left to its first pill. B: Up into the one
            // row, then Left to its start and Right to Genre (List, Type, Genre).
            for _ in 0..<4 where barFocus(app) != "genre" {
                remote.press(.up)
                pause(0.8)
                if layout == "A", barFocus(app) != "-" { break }
                if layout == "B" { break }
            }
            if barFocus(app) != "genre" {
                for _ in 0..<8 where barFocus(app) != "genre" {
                    remote.press(.left)
                    pause(0.6)
                }
            }
            if barFocus(app) != "genre" {
                for _ in 0..<8 where barFocus(app) != "genre" {
                    remote.press(.right)
                    pause(0.6)
                }
            }
            pause(1.0)
            note("library-bar-\(layout)-genre-focus.probe", "\(probe(app))\nfocused=\(focusedSummary(app))")
            shot("library-bar-\(layout)-genre-focus")
            guard barFocus(app) == "genre" else {
                XCTFail("layout \(layout): focus never reached the Genre pill — \(probe(app)) focused=\(focusedSummary(app))")
                continue
            }

            // 3. The Genre picker open.
            remote.press(.select)
            let comedy = app.descendants(matching: .any)
                // The rows carry their VoiceOver label ("Comedy, 5 titles"), so match the name only.
                .matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier != 'library.genrePicker'", "Comedy")).firstMatch
            let opened = comedy.waitForExistence(timeout: 5)
            pause(1.5)
            note("library-bar-\(layout)-genre-open.probe", "\(probe(app))\npicker=\(opened ? "open" : "NOT FOUND")\nfocused=\(focusedSummary(app))")
            shot("library-bar-\(layout)-genre-open")
            XCTAssertTrue(opened, "layout \(layout): the Genre picker never showed a Comedy row")
            remote.press(.menu)
            pause(1.0)
        }

        // Second placement (spec 4.1): the navigation rail Always Visible, rest shot only.
        for layout in ["A", "B"] {
            let app = launch(Self.arguments(layout: layout, navigation: "rail"))
            defer { app.terminate() }
            do {
                try openLibraryRail(app)
            } catch {
                shot("library-bar-\(layout)-rail-route-failed")
                XCTFail("layout \(layout) (rail): \(error)")
                continue
            }
            // Select on the rail item can leave the rail open; Right closes it into the content.
            for _ in 0..<4 where Self.token(railState(app), "expanded") == "1" {
                remote.press(.right)
                pause(1.0)
            }
            focusGrid(app, rows: layout == "A" ? 2 : 1)
            pause(1.5)
            note("library-bar-\(layout)-rail-rest.probe", "\(probe(app))\nrail=\(railState(app))\nfocused=\(focusedSummary(app))")
            shot("library-bar-\(layout)-rail-rest")
        }
    }

}
