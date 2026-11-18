import XCTest

/// W5 (upstream ports, Library filters): the Library filter bar, one row of menus (the owner's
/// pick, decision G: List · Type · Genre · Year · Show · Sort · Clear Filters; Refresh sits in the
/// header beside the count line, the owner's call in review r1), on the
/// canned libraries `-debug.libraryFixture provider|local` (no repository reads or writes). Spec:
/// `docs/batch-upstream-ports-spec-w5.md` 4.3 and 6.3 in the outer repo.
///
/// Oracle: the DEBUG probe `debug_library_bar` (`-debug.libraryBarGeometry YES`):
/// `pane= pill= row1= row2= row1w= bar= count= content= list= type= genre= year= show= focus=
/// fminx= fmaxx= panegx= bary= cminx= cmaxx= cideal= hdry= widths=`. Sizes are laid-out values from `onGeometryChange` (never accessibility
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

    private static func arguments(fixture: String = "provider", navigation: String = "tabs", countLine: String? = nil,
                                  oneTitleList: Bool = false) -> [String] {
        (countLine.map { ["-debug.libraryCountLine", $0] } ?? []) +
        (oneTitleList ? ["-debug.libraryOneTitleList", "YES"] : []) +
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
        // Down from the tab bar can stop on Refresh (the header's focus section) first.
        for _ in 0..<2 where barFocus(app) == "refresh" {
            remote.press(.down)
            pause(0.8)
        }
        guard barFocus(app) != "-", barFocus(app) != "refresh" else {
            throw HarnessAbort("focus never reached the bar's row — \(probe(app)) | \(focusedSummary(app))")
        }
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

    // MARK: - Header and edges

    /// The header holds the title, the count line and (provider sources) Refresh: the count line is
    /// never truncated (laid-out width = its ideal width) and Refresh ends inside the pane, after it.
    private func assertHeaderFits(_ app: XCUIApplication, tag: String) {
        let line = probe(app)
        guard let cMin = Self.int(line, "cminx"), let cMax = Self.int(line, "cmaxx"),
              let ideal = Self.int(line, "cideal"), let pane = Self.int(line, "pane") else {
            XCTFail("\(tag): no header numbers — \(line)")
            return
        }
        XCTAssertGreaterThanOrEqual(cMax - cMin, ideal - 1, "\(tag): the count line is truncated — \(line)")
        guard let refresh = Self.widths(line)["refresh"], let rMax = Self.refreshMaxX(line) else {
            XCTFail("\(tag): no Refresh in the header — \(line)")
            return
        }
        XCTAssertLessThanOrEqual(rMax, pane + 1, "\(tag): Refresh overflows the pane — \(line)")
        XCTAssertGreaterThanOrEqual(rMax - refresh, cMax, "\(tag): Refresh overlaps the count line — \(line)")
    }

    private static func widths(_ line: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for pair in (token(line, "widths") ?? "").split(separator: ",") {
            let kv = pair.split(separator: ":")
            if kv.count == 2, let v = Int(kv[1]) { out[String(kv[0])] = v }
        }
        return out
    }

    /// Refresh's right edge: the probe's `fmaxx` while it holds focus, else pane width when it is
    /// trailing-aligned (read by focusing it).
    private static func refreshMaxX(_ line: String) -> Int? {
        token(line, "focus") == "refresh" ? int(line, "fmaxx") : nil
    }

    /// Focus Refresh from the row (Up from Sort) and read the header numbers there.
    private func focusRefresh(_ app: XCUIApplication) -> Bool {
        if barFocus(app) == "refresh" { return true }
        moveBar(app, to: "sort", .right, max: 8)
        for _ in 0..<2 where barFocus(app) != "refresh" {
            remote.press(.up)
            pause(0.8)
        }
        return barFocus(app) == "refresh"
    }

    /// Mean luminance of a screen strip `x0..<x1` (points) at row `y` (points), from a screenshot.
    private func luminance(_ image: CGImage, x0: Int, x1: Int, y: Int, screenWidth: CGFloat = 1920) -> (mean: Double, max: Double) {
        let scale = CGFloat(image.width) / screenWidth
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let py = min(height - 1, max(0, Int(CGFloat(y) * scale)))
        var total = 0.0, peak = 0.0, n = 0.0
        for px in stride(from: Int(CGFloat(x0) * scale), to: Int(CGFloat(x1) * scale), by: 1) where px >= 0 && px < width {
            // CGContext rows run bottom-up.
            let i = ((height - 1 - py) * width + px) * 4
            let l = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
            total += l; peak = max(peak, l); n += 1
        }
        return (n > 0 ? total / n : 0, peak)
    }

    /// After the row has scrolled, nothing of it draws in the strip just left of the pane: that strip
    /// at the bar's height reads like the same strip at the header's height (plain background).
    private func assertNothingLeftOfPane(_ app: XCUIApplication, tag: String) {
        let line = probe(app)
        guard let paneX = Self.int(line, "panegx"), let hdrY = Self.int(line, "hdry"),
              let bary = Self.token(line, "bary")?.split(separator: "-").compactMap({ Int($0) }), bary.count == 2,
              let image = XCUIScreen.main.screenshot().image.cgImage else {
            XCTFail("\(tag): no screen numbers — \(line)")
            return
        }
        let barMid = (bary[0] + bary[1]) / 2
        let strip = luminance(image, x0: paneX - 40, x1: paneX - 2, y: barMid)
        let reference = luminance(image, x0: paneX - 40, x1: paneX - 2, y: hdrY)
        note("\(tag)-edge", "strip mean=\(strip.mean) max=\(strip.max) | reference mean=\(reference.mean) max=\(reference.max)\n\(line)")
        XCTAssertLessThan(abs(strip.mean - reference.mean), 4, "\(tag): something draws left of the pane at the bar — \(line)")
        XCTAssertLessThan(strip.max, reference.max + 12, "\(tag): something draws left of the pane at the bar — \(line)")
    }

    // MARK: - Geometry (spec 4.3, review r1)

    /// The bar keeps today's height: one row, `row = pill + 16`, `bar = row`, no row 2. With Refresh
    /// in the header the row fits the pane at rest for the local library and the provider fixture,
    /// in both placements; the header fits too, with a long count line. With a filter set the row may
    /// scroll; its last control stays reachable and visible.
    func testOneRowBarGeometry() throws {
        do {
            let app = launch(Self.arguments(fixture: "local"))
            defer { app.terminate() }
            try openLibrary(app, rail: false)
            let line = probe(app)
            note("geometry-local", line)
            let pill = try XCTUnwrap(Self.int(line, "pill")), row1 = try XCTUnwrap(Self.int(line, "row1"))
            let bar = try XCTUnwrap(Self.int(line, "bar")), pane = try XCTUnwrap(Self.int(line, "pane"))
            XCTAssertEqual(Double(row1), Double(pill + 16), accuracy: 1, line)
            XCTAssertEqual(Self.int(line, "row2"), 0, line)
            XCTAssertEqual(Double(bar), Double(row1), accuracy: 1, line)
            XCTAssertLessThanOrEqual(try XCTUnwrap(Self.int(line, "row1w")), pane, "the local library's row must fit: \(line)")
            XCTAssertNil(Self.widths(line)["refresh"], "no Refresh for the local library: \(line)")
            shot("geometry-local")
        }
        for rail in [false, true] {
            let tag = rail ? "rail" : "tabs"
            let long = "1,234 movies \u{00B7} 567 series \u{00B7} 89 anime \u{00B7} 12 other titles"
            let app = launch(Self.arguments(fixture: "provider", navigation: rail ? "rail" : "tabs", countLine: rail ? long : nil))
            defer { app.terminate() }
            try openLibrary(app, rail: rail)
            let line = probe(app)
            note("geometry-provider-\(tag)", line)
            let pill = try XCTUnwrap(Self.int(line, "pill")), row1 = try XCTUnwrap(Self.int(line, "row1"))
            let pane = try XCTUnwrap(Self.int(line, "pane"))
            XCTAssertEqual(Double(row1), Double(pill + 16), accuracy: 1, line)
            XCTAssertEqual(Self.int(line, "row2"), 0, line)
            XCTAssertEqual(Double(try XCTUnwrap(Self.int(line, "bar"))), Double(row1), accuracy: 1, line)
            XCTAssertLessThanOrEqual(try XCTUnwrap(Self.int(line, "row1w")), pane, "\(tag): the provider row must fit at rest: \(line)")
            shot("geometry-provider-\(tag)-rest")
            try enterBar(app)
            let tokens = walkRow(app, tag: "geometry-\(tag)")
            XCTAssertEqual(tokens.last, "sort", "\(tag): \(tokens)")
            XCTAssertTrue(focusRefresh(app), "\(tag): Up from Sort must reach Refresh — \(probe(app))")
            note("geometry-provider-\(tag)-refresh", probe(app))
            assertHeaderFits(app, tag: "geometry-\(tag)")
            shot("geometry-provider-\(tag)-refresh")
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
            XCTAssertEqual(tokens, ["list", "type", "genre", "year", "watch", "sort"], "\(tag): \(probe(app))")

            // Refresh: Up from the row, Down back into it.
            XCTAssertTrue(focusRefresh(app), "\(tag): Up must reach Refresh — \(probe(app))")
            log.append("refresh: \(probe(app))")
            remote.press(.down)
            pause(0.8)
            XCTAssertNotEqual(barFocus(app), "refresh", "\(tag): Down from Refresh must return to the row — \(probe(app))")
            XCTAssertNotEqual(barFocus(app), "-", "\(tag): Down from Refresh must land in the row — \(probe(app))")

            // Genre Comedy, year 2022.
            XCTAssertTrue(moveBar(app, to: "genre", .left) || moveBar(app, to: "genre", .right), "\(tag): \(probe(app))")
            XCTAssertTrue(focusedControlVisible(app), "\(tag): Genre must be on screen — \(probe(app))")
            remote.press(.select)
            XCTAssertTrue(pick(app, "Comedy", step: "traversal-\(tag)-genre"))
            log.append("comedy: \(probe(app))")
            XCTAssertEqual(value(app, "genre"), "Comedy")
            XCTAssertEqual(number(app, "count"), 5, probe(app))
            XCTAssertTrue(moveBar(app, to: "year", .right), "\(tag): \(probe(app))")
            remote.press(.select)
            XCTAssertTrue(pick(app, "2022", step: "traversal-\(tag)-year"))
            log.append("2022: \(probe(app))")
            XCTAssertEqual(value(app, "year"), "2022")
            XCTAssertEqual(number(app, "count"), 1, probe(app))

            // Show Watched while Comedy + 2022 leaves one title: not offered (counts honour it).
            // Clear Filters at the far end: on screen when focused.
            XCTAssertTrue(moveBar(app, to: "clear", .right, max: 12), "\(tag): \(probe(app))")
            XCTAssertTrue(focusedControlVisible(app), "\(tag): Clear Filters must be on screen — \(probe(app))")
            if rail { assertNothingLeftOfPane(app, tag: "traversal-rail-scrolled") }
            shot("traversal-\(tag)-2-clear-focused")
            remote.press(.select)
            pause(1.5)
            log.append("cleared: \(probe(app))")
            XCTAssertEqual(value(app, "genre"), "-", probe(app))
            XCTAssertEqual(value(app, "year"), "-", probe(app))
            XCTAssertEqual(value(app, "show"), "all", probe(app))
            XCTAssertEqual(number(app, "count"), 14, probe(app))
            XCTAssertEqual(barFocus(app), "genre", probe(app))
            XCTAssertTrue(focusedControlVisible(app), "\(tag): Genre must be on screen after Clear Filters — \(probe(app))")
            shot("traversal-\(tag)-3-cleared")

            // A filter that widens the row past the pane: Show Watched (+ Clear Filters), scrolled to
            // the end and back, every pill visible; in the rail placement nothing left of the pane.
            XCTAssertTrue(moveBar(app, to: "watch", .right), "\(tag): \(probe(app))")
            remote.press(.select)
            XCTAssertTrue(pick(app, "Watched", step: "traversal-\(tag)-watched"))
            log.append("watched: \(probe(app))")
            XCTAssertEqual(number(app, "count"), 2, probe(app))
            let wide = walkRow(app, tag: "\(tag)-watched")
            log.append("walk watched: \(wide.joined(separator: " → ")) | \(probe(app))")
            XCTAssertEqual(wide.last, "clear", "\(tag): \(wide)")
            if rail { assertNothingLeftOfPane(app, tag: "traversal-rail-watched") }
            shot("traversal-\(tag)-4-watched-end")

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

    // MARK: - Menus

    /// A list change resetting the type, the Genre menu's two science-fiction rows, the counts under
    /// Show = Watched (review r1 finding 3), and the pill widths with filters set.
    func testListResetAndMenuRows() throws {
        let app = launch(Self.arguments(fixture: "provider"))
        defer { app.terminate() }
        try openLibrary(app, rail: false)
        try enterBar(app)
        note("widths-rest", probe(app))

        // Re-picking the row a menu already shows: does the tvOS Picker call the setter (a pin)?
        // Read from the probe's write count; recorded, not asserted (platform behaviour).
        let writesBefore = Self.int(probe(app), "writes") ?? -1
        XCTAssertTrue(moveBar(app, to: "type", .right, max: 4) || moveBar(app, to: "type", .left, max: 4), probe(app))
        remote.press(.select)
        XCTAssertTrue(pick(app, "All types", step: "type-repick"))
        let writesAfter = Self.int(probe(app), "writes") ?? -1
        note("type-repick", "writes before=\(writesBefore) after=\(writesAfter) setterCalled=\(writesAfter > writesBefore)\n\(probe(app))")

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

        // Show Watched: the Type and Genre menus count the two watched titles only.
        XCTAssertTrue(moveBar(app, to: "watch", .right), probe(app))
        remote.press(.select)
        XCTAssertTrue(pick(app, "Watched", step: "watched"))
        note("widths-show-watched", probe(app))
        XCTAssertEqual(number(app, "count"), 2, probe(app))
        XCTAssertTrue(moveBar(app, to: "type", .left), probe(app))
        remote.press(.select)
        pause(1.5)
        let allTypes = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "All types (")).firstMatch
        note("type-rows-watched", allTypes.exists ? allTypes.label : "missing")
        XCTAssertTrue(allTypes.exists && allTypes.label.hasPrefix("All types (2)"), allTypes.exists ? allTypes.label : "missing")
        remote.press(.menu)
        pause(1.0)
        XCTAssertTrue(moveBar(app, to: "genre", .right), probe(app))
        remote.press(.select)
        pause(1.5)
        let horror = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Horror")).firstMatch
        XCTAssertFalse(horror.exists, "Horror has no watched title, so it must not be offered")
        XCTAssertTrue(pick(app, "Crime", step: "genre-crime"))
        note("widths-genre-and-show", probe(app))
        XCTAssertEqual(number(app, "count"), 1, probe(app))
        // Clear Filters from the row.
        XCTAssertTrue(moveBar(app, to: "clear", .right, max: 12), probe(app))
        remote.press(.select)
        pause(1.5)
        XCTAssertEqual(number(app, "count"), 14, probe(app))

        // Type Series, then another list: the type goes back to All.
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

    // MARK: - The menu the viewer is on (device pass attempt 3)

    /// Waits until the probe reads the same for `quiet` seconds (the bar has settled); returns it.
    @discardableResult
    private func settle(_ app: XCUIApplication, quiet: TimeInterval = 1.0, timeout: TimeInterval = 10) -> String {
        var last = probe(app)
        var since = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pause(0.2)
            let now = probe(app)
            if now != last {
                last = now
                since = Date()
            } else if Date().timeIntervalSince(since) >= quiet {
                return now
            }
        }
        return last
    }

    /// Settle, then press.
    private func press(_ app: XCUIApplication, _ button: XCUIRemote.Button) {
        settle(app)
        remote.press(button)
    }

    /// Moves bar focus to `token` one settled press at a time.
    @discardableResult
    private func moveSettled(_ app: XCUIApplication, to token: String, _ direction: XCUIRemote.Button, max: Int = 10) -> Bool {
        for _ in 0..<max {
            settle(app)
            if barFocus(app) == token { return true }
            remote.press(direction)
        }
        settle(app)
        return barFocus(app) == token
    }

    /// Opens the focused menu and picks the row matching `predicate` (rows: label, never a pill),
    /// one settled press at a time. Records the probe while the picker is up (`openNote`).
    private func pickRow(_ app: XCUIApplication, _ predicate: NSPredicate, step: String, openNote: String? = nil) -> Bool {
        press(app, .select)
        let row = app.descendants(matching: .any)
            .matching(NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, NSPredicate(format: "NOT identifier BEGINSWITH 'library.'")]))
            .firstMatch
        guard row.waitForExistence(timeout: 6) else {
            shot("\(step)-no-row")
            remote.press(.menu)
            return false
        }
        if let openNote { note(openNote, "picker open: \(settle(app)) | focused: \(focusedSummary(app))") }
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<14 where !hasFocusByFrame(app, row) {
                settle(app, quiet: 0.6)
                remote.press(direction)
            }
        }
        settle(app, quiet: 0.6)
        guard hasFocusByFrame(app, row) else {
            shot("\(step)-unfocused")
            remote.press(.menu)
            return false
        }
        remote.press(.select)
        return true
    }

    private func rowStarting(_ prefix: String) -> NSPredicate { NSPredicate(format: "label BEGINSWITH %@", prefix) }
    private func control(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The device case: Type Series, Genre Drama, Show In Progress leaves one series; "All types"
    /// in the Type menu keeps the menu and focus on it; Right moves to Genre, the Type menu then
    /// hides and focus stays on Genre. Then the same for Year (Anime, 2016, Comedy, "All years" in Year),
    /// and Down from the kept Year menu releases it.
    func testAPickNeverRemovesTheMenuUnderFocus() throws {
        let app = launch(Self.arguments(fixture: "provider"))
        defer { app.terminate() }
        try openLibrary(app, rail: false)
        try enterBar(app)
        var log: [String] = ["start: \(settle(app))"]

        // Narrow: Series, Drama, In Progress (Severance).
        XCTAssertTrue(moveSettled(app, to: "type", .right) || moveSettled(app, to: "type", .left), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("Series"), step: "keep-series"))
        XCTAssertTrue(poll(8) { value(app, "type") == "series" }, probe(app))
        XCTAssertTrue(moveSettled(app, to: "genre", .right), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("Drama"), step: "keep-drama"))
        XCTAssertTrue(poll(8) { value(app, "genre") == "Drama" }, probe(app))
        XCTAssertTrue(moveSettled(app, to: "watch", .right), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("In Progress"), step: "keep-inprogress"))
        XCTAssertTrue(poll(8) { value(app, "show") == "inProgress" }, probe(app))
        log.append("narrowed: \(settle(app))")
        XCTAssertEqual(number(app, "count"), 1, probe(app))

        // "All types" in the Type menu: the menu stays and keeps focus.
        XCTAssertTrue(moveSettled(app, to: "type", .left), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("All types"), step: "keep-alltypes", openNote: "type-picker-open"))
        XCTAssertTrue(poll(8) { value(app, "type") == "-" }, probe(app))
        let afterAll = settle(app)
        log.append("all types: \(afterAll) | \(focusedSummary(app))")
        shot("keep-1-all-types")
        XCTAssertEqual(Self.token(afterAll, "focus"), "type", "focus must stay on the Type menu — \(afterAll) | \(focusedSummary(app))")
        XCTAssertEqual(Self.token(afterAll, "keep"), "type", afterAll)
        XCTAssertTrue(control(app, "library.typePicker").exists, "the Type menu must still be drawn")
        XCTAssertFalse(tabBarFocused(app), "focus must not leave for the tab bar — \(focusedSummary(app))")
        XCTAssertEqual(Self.int(afterAll, "count"), 1, afterAll)

        // Right: Genre takes focus, the Type menu (left of it) hides, focus stays on Genre.
        press(app, .right)
        XCTAssertTrue(poll(8) { barFocus(app) == "genre" }, probe(app))
        let moved = settle(app)
        log.append("right: \(moved)")
        XCTAssertEqual(Self.token(moved, "focus"), "genre", moved)
        XCTAssertEqual(Self.token(moved, "keep"), "-", moved)
        XCTAssertFalse(control(app, "library.typePicker").exists, "the Type menu hides once the viewer has left it")
        XCTAssertTrue(focusedControlVisible(app), moved)

        // Clear Filters: Genre, Year and Show are all drawn again; focus lands on Genre.
        XCTAssertTrue(moveSettled(app, to: "clear", .right, max: 8), probe(app))
        press(app, .select)
        XCTAssertTrue(poll(8) { value(app, "genre") == "-" && value(app, "show") == "all" }, probe(app))
        let cleared = settle(app)
        log.append("cleared: \(cleared)")
        XCTAssertEqual(Self.token(cleared, "focus"), "genre", cleared)

        // Year: Anime, 2016, Comedy (Mob Psycho 100), then "All" in Year.
        XCTAssertTrue(moveSettled(app, to: "type", .left), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("Anime"), step: "keep-anime"))
        XCTAssertTrue(poll(8) { value(app, "type") == "anime" }, probe(app))
        XCTAssertTrue(moveSettled(app, to: "year", .right), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("2016"), step: "keep-2016"))
        XCTAssertTrue(poll(8) { value(app, "year") == "2016" }, probe(app))
        XCTAssertTrue(moveSettled(app, to: "genre", .left), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("Comedy"), step: "keep-comedy"))
        XCTAssertTrue(poll(8) { value(app, "genre") == "Comedy" }, probe(app))
        XCTAssertTrue(moveSettled(app, to: "year", .right), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("All years"), step: "keep-allyears", openNote: "year-picker-open"))
        XCTAssertTrue(poll(8) { value(app, "year") == "-" }, probe(app))
        let allYears = settle(app)
        log.append("all years: \(allYears) | \(focusedSummary(app))")
        shot("keep-2-all-years")
        XCTAssertEqual(Self.token(allYears, "focus"), "year", "focus must stay on the Year menu — \(allYears)")
        XCTAssertEqual(Self.token(allYears, "keep"), "year", allYears)
        XCTAssertTrue(control(app, "library.yearPicker").exists, "the Year menu must still be drawn")

        // Down into the grid releases it.
        press(app, .down)
        XCTAssertTrue(poll(8) { barFocus(app) == "-" }, probe(app))
        let down = settle(app)
        log.append("down: \(down) | \(focusedSummary(app))")
        XCTAssertEqual(Self.token(down, "keep"), "-", down)
        XCTAssertFalse(control(app, "library.yearPicker").exists, "the Year menu hides once focus has left the bar")
        note("keep-log", log.joined(separator: "\n"))
    }

    /// Clear Filters on a list where every menu has one value (`-debug.libraryOneTitleList`: only
    /// Nope): Genre, Year, Show and Type all hide and Clear Filters goes, so focus lands on Sort.
    func testClearFiltersLandsOnAControlThatStays() throws {
        let app = launch(Self.arguments(fixture: "provider", oneTitleList: true))
        defer { app.terminate() }
        try openLibrary(app, rail: false)
        try enterBar(app)
        var log: [String] = ["start: \(settle(app))"]
        XCTAssertTrue(moveSettled(app, to: "genre", .right) || moveSettled(app, to: "genre", .left), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("Horror"), step: "clear-horror"))
        XCTAssertTrue(poll(8) { value(app, "genre") == "Horror" }, probe(app))
        XCTAssertTrue(moveSettled(app, to: "list", .left), probe(app))
        XCTAssertTrue(pickRow(app, rowStarting("One Title"), step: "clear-list"))
        XCTAssertTrue(poll(8) { value(app, "list") == "fx-list-one" }, probe(app))
        let before = settle(app)
        log.append("one title + Horror: \(before)")
        XCTAssertEqual(Self.int(before, "count"), 1, before)
        XCTAssertEqual(Self.token(before, "genre"), "Horror", before)
        XCTAssertTrue(moveSettled(app, to: "clear", .right, max: 8), probe(app))
        press(app, .select)
        XCTAssertTrue(poll(8) { value(app, "genre") == "-" }, probe(app))
        let after = settle(app)
        log.append("cleared: \(after) | \(focusedSummary(app))")
        shot("clear-fallback-sort")
        XCTAssertEqual(Self.token(after, "focus"), "sort", "Clear Filters must hand focus to Sort — \(after) | \(focusedSummary(app))")
        XCTAssertFalse(control(app, "library.clearFilters").exists, "nothing left to clear")
        for id in ["library.typePicker", "library.genrePicker", "library.yearPicker", "library.watchPicker"] {
            XCTAssertFalse(control(app, id).exists, "\(id) has one value here and must hide")
        }
        XCTAssertTrue(focusedControlVisible(app), after)
        note("clear-fallback-log", log.joined(separator: "\n"))
    }
}
