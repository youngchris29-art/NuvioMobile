import XCTest

/// GitHub #28: Settings > Home Screen > Collection Header (Standard / Compact) on the Grid folder
/// page. Oracle: the DEBUG `folder_grid_geometry` readout (`pane=<minY>,<maxY> rows=<minY-maxY;...>`),
/// which carries LAID-OUT frames (tile frames in the scroll content's space, the pane in global
/// space), never accessibility frames. Screen y at rest (`scrolled=0`) = pane.minY + row minY.
/// AX frames are used only as a cross-check at rest, and for the Edit controls (padding-placed,
/// no `.offset`/`.scaleEffect`, so their layout frame is what is drawn).
///
/// Fixtures: the project sim clone (FA87's guest plist copied in; see the batch doc's recipe). Every
/// seed uses only Cinemeta and TMDB sources (no stub add-ons), seeded through the guest-only
/// `-debug.collectionsSeedJsonB64` knob and cleared with `"[]"` afterwards. Medium posters with
/// titles on are forced by launch argument so the stored settings never matter.
///
/// Helpers are this file's own (the harness's duplication rule).
final class CollectionHeaderUITests: XCTestCase {

    let remote = XCUIRemote.shared

    private static let oneSource = """
    [{"id":"zzhdr1-collection","title":"ZZHeaderOne","pinToTop":true,"showAllTab":false,"folders":[{"id":"zzhdr1-folder","title":"ZZHeaderOneFolder","hideTitle":false,"heroBackdropUrl":"https://images.metahub.space/background/medium/tt0111161/img","sources":[{"provider":"addon","addonId":"com.linvo.cinemeta","type":"movie","catalogId":"top"}]}]}]
    """
    /// `folderProbeSeedJson` (NuvioTVUITests): two Cinemeta sources plus All = three chips.
    private static let severalSources = """
    [{"id":"zzfolderprobe-collection","title":"ZZFolderProbe","pinToTop":true,"showAllTab":true,"folders":[{"id":"zzfolderprobe-folder","title":"ZZFolderProbeFolder","hideTitle":false,"heroBackdropUrl":"https://images.metahub.space/background/medium/tt0111161/img","sources":[{"provider":"addon","addonId":"com.linvo.cinemeta","type":"movie","catalogId":"top"},{"provider":"addon","addonId":"com.linvo.cinemeta","type":"series","catalogId":"top"}]}]}]
    """
    /// Chips: All, Popular (Movies), Discover Movies. Selecting the Discover chip makes the
    /// folder's selected source editable (Classic: Edit Filters; Stage: the Edit menu).
    private static let editSeed = """
    [{"id":"zzhdre-collection","title":"ZZHeaderEdit","pinToTop":true,"showAllTab":true,"folders":[{"id":"zzhdre-folder","title":"ZZHeaderEditFolder","hideTitle":false,"heroBackdropUrl":"https://images.metahub.space/background/medium/tt0111161/img","sources":[{"provider":"addon","addonId":"com.linvo.cinemeta","type":"movie","catalogId":"top"},{"provider":"tmdb","tmdbSourceType":"DISCOVER","mediaType":"movie","title":"Discover Movies","sortBy":"popularity.desc"}]}]}]
    """

    private static let shells: [String: [String]] = [
        "T": ["-sidebar_style", "tabs"],
        "CA": ["-sidebar_style", "rail", "-rail_position", "centre", "-rail_visibility", "always"],
        "KA": ["-sidebar_style", "rail", "-rail_position", "corner", "-rail_visibility", "always"],
        "CB": ["-sidebar_style", "rail", "-rail_position", "centre", "-rail_visibility", "browsing"],
    ]

    override func setUpWithError() throws { continueAfterFailure = true }

    // MARK: - Helpers (duplicated per file, house rule)

    private func pause(_ s: TimeInterval) { Thread.sleep(forTimeInterval: s) }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        print("[CollectionHeaderUITests] \(name): \(text)")
    }

    private func poll(_ timeout: TimeInterval, step: TimeInterval = 0.3, _ c: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if c() { return true }; pause(step) }
        return c()
    }

    private func label(_ app: XCUIApplication, _ id: String) -> String {
        let e = app.descendants(matching: .any)[id].firstMatch
        return e.exists ? e.label : ""
    }

    private static func token(_ line: String, _ key: String) -> String? {
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, pair[0] == Substring(key) { return String(pair[1]) }
        }
        return nil
    }

    private func clearSeed() {
        let app = XCUIApplication()
        app.launchArguments = ["-debug.collectionsSeedJsonB64", Data("[]".utf8).base64EncodedString()]
        app.launch()
        pause(8)
        app.terminate()
    }

    /// Launches with the shared arguments, gets past Welcome / the profile picker and walks Down to
    /// the seeded folder tile on Home. Returns nil (after recording why) when the tile never shows.
    private func openFolder(style: String, seed: String, shell: String, stage: Bool = false,
                            terminateFirst: XCUIApplication? = nil) -> XCUIApplication? {
        terminateFirst?.terminate()
        let probeId = stage ? "debug_stage" : "debug_hero"
        var args = stage
            ? ["-home_layout", "stage", "-folder_layout_default", "grid", "-sidebar_style", "tabs",
               "-debug.homeScrollProbe", "YES", "-home_upcoming_row_enabled", "NO"]
            : ["-home_layout", "classic", "-folder_layout_default_classic", "grid"] + (Self.shells[shell] ?? [])
        args += ["-inline_trailers_enabled", "NO", "-debug.posterSizeOverride", "medium", "-debug.posterHideTitles", "NO",
                 "-debug.collectionsSeedJsonB64", Data(seed.utf8).base64EncodedString()]
        args += ["-collection_header_style", style]
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()

        let guest = app.buttons["Continue as Guest"]
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        let hero = { app.descendants(matching: .any)[probeId].firstMatch }
        _ = poll(60) { guest.exists || chris.exists || hero().exists }
        if guest.exists {
            for _ in 0..<6 where !guest.hasFocus { remote.press(.down); pause(0.5) }
            remote.press(.select)
            _ = poll(30) { chris.exists || hero().exists }
        }
        if chris.exists, !hero().exists {
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        }
        guard poll(60, { hero().exists }) else {
            XCTFail("[\(style) \(shell)] Home never showed \(probeId) (fixture signed out of the guest profile?)")
            return nil
        }
        pause(12)

        var found = false
        var last = ""
        var stalled = 0
        for _ in 0..<45 {
            remote.press(.down)
            pause(0.5)
            let fitem = Self.token(label(app, probeId), "fitem") ?? ""
            if fitem.contains("nuvio-folder://") { found = true; break }
            if fitem == last { stalled += 1 } else { stalled = 0; last = fitem }
            if stalled >= 6 { break }
        }
        guard found else {
            XCTFail("[\(style) \(shell)] the seeded folder tile never took focus on Home (seed refused on a signed-in account?)")
            return nil
        }
        remote.press(.select)
        let first = app.descendants(matching: .any)["folder_grid_first_tile"]
        guard first.waitForExistence(timeout: 40) else {
            XCTFail("[\(style) \(shell)] folder_grid_first_tile never appeared; nothing-here=\(app.staticTexts["Nothing here yet."].exists)")
            return nil
        }
        _ = poll(5) { Self.token(self.label(app, "folder_header_state"), "reveal") == "1" }
        pause(1.5)
        return app
    }

    private func state(_ app: XCUIApplication) -> String { label(app, "folder_header_state") }
    private func geometry(_ app: XCUIApplication) -> String { label(app, "folder_grid_geometry") }

    private struct Geo {
        var line: String
        var paneMin: CGFloat, paneMax: CGFloat
        var rows: [(min: CGFloat, max: CGFloat)]
        var chips: Bool
        /// Screen top / bottom of row `i` at rest (scrolled = 0).
        func top(_ i: Int) -> CGFloat { paneMin + rows[i].min }
        func bottom(_ i: Int) -> CGFloat { paneMin + rows[i].max }
    }

    private func readGeo(_ app: XCUIApplication, rowsNeeded: Int = 3) -> Geo? {
        var line = ""
        let ok = poll(8) {
            line = self.geometry(app)
            let pane = Self.token(line, "pane") ?? ""
            let rows = Self.token(line, "rows") ?? ""
            return pane.contains(",") && !pane.hasPrefix("0,0") && rows.split(separator: ";").count >= min(rowsNeeded, 2)
        }
        guard ok, let paneTok = Self.token(line, "pane"), let rowsTok = Self.token(line, "rows") else {
            XCTFail("no usable folder_grid_geometry: \(line)")
            return nil
        }
        let pane = paneTok.split(separator: ",").compactMap { Double($0) }
        let rows: [(min: CGFloat, max: CGFloat)] = rowsTok.split(separator: ";").compactMap { r in
            let p = r.split(separator: "-").compactMap { Double($0) }
            return p.count == 2 ? (CGFloat(p[0]), CGFloat(p[1])) : nil
        }
        guard pane.count == 2, !rows.isEmpty else { XCTFail("unparsable folder_grid_geometry: \(line)"); return nil }
        return Geo(line: line, paneMin: CGFloat(pane[0]), paneMax: CGFloat(pane[1]), rows: rows,
                   chips: Self.token(line, "chips") == "1")
    }

    private func firstTileMinY(_ app: XCUIApplication) -> CGFloat {
        app.descendants(matching: .any)["folder_grid_first_tile"].firstMatch.frame.minY
    }

    // MARK: - 1. Standard is unchanged

    func testStandardIsUnchanged() {
        defer { clearSeed() }
        var previous: XCUIApplication?
        for (seedName, seed) in [("one", Self.oneSource), ("several", Self.severalSources)] {
            for shell in ["T", "KA"] {
                guard let app = openFolder(style: "standard", seed: seed, shell: shell, terminateFirst: previous) else { return }
                previous = app
                let tag = "standard-\(seedName)-\(shell)"
                let st = state(app)
                XCTAssertEqual(Self.token(st, "style"), "standard", "\(tag): \(st)")
                XCTAssertEqual(Self.token(st, "phase"), "0", "\(tag): \(st)")
                XCTAssertEqual(Self.token(st, "scrolled"), "0", "\(tag): \(st)")
                guard let g = readGeo(app) else { return }
                XCTAssertEqual(g.rows[0].min, 138, accuracy: 1, "\(tag): \(g.line)")
                XCTAssertEqual(g.paneMin, seedName == "one" ? 285 : 384, accuracy: 1, "\(tag): \(g.line)")
                XCTAssertEqual(g.top(0), seedName == "one" ? 423 : 522, accuracy: 1, "\(tag): \(g.line)")
                // The laid-out pane ends at the bottom safe area (1020); the earlier 1080 was an AX frame.
                XCTAssertEqual(g.paneMax, 1020, accuracy: 1, "\(tag): \(g.line)")
                note(tag, "\(st) | \(g.line)")
                shot("\(tag)-rest")
            }
        }
    }

    // MARK: - 2. Compact, one source

    func testCompactOneSourceShowsTwoFullRows() {
        defer { clearSeed() }
        var previous: XCUIApplication?
        for shell in ["T", "CA", "KA", "CB"] {
            guard let app = openFolder(style: "compact", seed: Self.oneSource, shell: shell, terminateFirst: previous) else { return }
            previous = app
            let tag = "compact-one-\(shell)"
            let st = state(app)
            XCTAssertEqual(Self.token(st, "style"), "compact", "\(tag): \(st)")
            XCTAssertEqual(Self.token(st, "phase"), "4", "\(tag): \(st)")
            XCTAssertEqual(Self.token(st, "scrolled"), "0", "\(tag): \(st)")
            guard let g = readGeo(app) else { return }
            XCTAssertEqual(g.paneMin, 188, accuracy: 1, "\(tag): \(g.line)")
            XCTAssertEqual(g.rows[0].min, 32, accuracy: 1, "\(tag): \(g.line)")
            XCTAssertEqual(g.top(0), 220, accuracy: 1, "\(tag): \(g.line)")
            XCTAssertGreaterThanOrEqual(g.rows.count, 3, "\(tag): fewer than three rows laid out: \(g.line)")
            if g.rows.count >= 3 {
                XCTAssertLessThanOrEqual(g.bottom(1), 1020, "\(tag): row 2 not whole above the fade: \(g.line)")
                XCTAssertGreaterThanOrEqual(1080 - g.top(2), 24, "\(tag): under 24 pt of row 3 on screen: \(g.line)")
            }
            XCTAssertEqual(firstTileMinY(app), 220, accuracy: 2, "\(tag): AX cross-check")
            note(tag, "\(st) | \(g.line)")
            shot("\(tag)-rest")
        }
    }

    // MARK: - 3. Compact, several sources (the documented shortfall; values asserted)

    func testCompactSeveralSources() {
        defer { clearSeed() }
        var previous: XCUIApplication?
        for shell in ["T", "CA", "KA", "CB"] {
            guard let app = openFolder(style: "compact", seed: Self.severalSources, shell: shell, terminateFirst: previous) else { return }
            previous = app
            let tag = "compact-several-\(shell)"
            XCTAssertEqual(Self.token(state(app), "style"), "compact", "\(tag): \(state(app))")
            guard let g = readGeo(app) else { return }
            XCTAssertEqual(g.paneMin, 287, accuracy: 1, "\(tag): \(g.line)")
            XCTAssertEqual(g.top(0), 319, accuracy: 1, "\(tag): \(g.line)")
            XCTAssertLessThanOrEqual(g.bottom(0), 1020, "\(tag): row 1 not whole: \(g.line)")
            XCTAssertEqual(g.top(1), 732.5, accuracy: 1, "\(tag): \(g.line)")
            XCTAssertEqual(g.bottom(1), 1106, accuracy: 1, "\(tag): \(g.line)")
            note(tag, "\(state(app)) | \(g.line)")
            shot("\(tag)-rest")
        }
    }

    // MARK: - 4. Focus and rest in Compact

    /// `rowOneTop`: row 1's screen top at rest for the several-sources fixture (Compact 319,
    /// Standard 522).
    private func keepsFocusAndRest(style: String, rowOneTop: CGFloat) {
        defer { clearSeed() }
        var previous: XCUIApplication?
        for shell in ["T", "KA"] {
            guard let app = openFolder(style: style, seed: Self.severalSources, shell: shell, terminateFirst: previous) else { return }
            previous = app
            let tag = "\(style)-focus-\(shell)"
            XCTAssertNotEqual(Self.token(state(app), "chip"), "-", "\(tag): opens with focus on a chip: \(state(app))")
            guard let g = readGeo(app) else { return }
            let restTop = g.top(0)

            // Left / Right along the chips.
            let startChip = Self.token(state(app), "chip") ?? "-"
            remote.press(.right); pause(1)
            let rightChip = Self.token(state(app), "chip") ?? "-"
            XCTAssertNotEqual(rightChip, "-", "\(tag): Right keeps focus on the chips: \(state(app))")
            XCTAssertNotEqual(rightChip, startChip, "\(tag): Right moves along the chips: \(state(app))")
            remote.press(.left); pause(1)
            XCTAssertEqual(Self.token(state(app), "chip"), startChip, "\(tag): Left moves back along the chips: \(state(app))")

            remote.press(.down); pause(1)
            XCTAssertEqual(Self.token(state(app), "chip"), "-", "\(tag): Down enters the grid: \(state(app))")
            XCTAssertEqual(Self.token(state(app), "scrolled"), "0", "\(tag): Down from a chip lands on row 1, not scrolled: \(state(app))")
            // Up from row 1 at rest reaches the chip row.
            remote.press(.up); pause(1)
            XCTAssertNotEqual(Self.token(state(app), "chip"), "-", "\(tag): Up from row 1 posters reaches the chips: \(state(app))")
            remote.press(.down); pause(1)
            XCTAssertEqual(Self.token(state(app), "chip"), "-", "\(tag): Down re-enters the grid: \(state(app))")
            var scrolled = Self.token(state(app), "scrolled") == "1"
            for _ in 0..<3 where !scrolled {
                remote.press(.down); pause(1)
                scrolled = Self.token(state(app), "scrolled") == "1"
            }
            XCTAssertTrue(scrolled, "\(tag): never scrolled after Down presses: \(state(app))")

            var onChip = false
            for _ in 0..<6 where !onChip {
                remote.press(.up); pause(1)
                onChip = Self.token(state(app), "chip") != "-"
            }
            XCTAssertTrue(onChip, "\(tag): Up never returned to a chip: \(state(app))")
            pause(1)
            XCTAssertEqual(Self.token(state(app), "scrolled"), "0", "\(tag): \(state(app))")
            XCTAssertEqual(firstTileMinY(app), restTop, accuracy: 2, "\(tag): row 1 back at rest")
            XCTAssertEqual(firstTileMinY(app), rowOneTop, accuracy: 2, "\(tag): row 1 back at \(rowOneTop)")

            remote.press(.menu)
            let gone = poll(5) { !app.descendants(matching: .any)["folder_header"].firstMatch.exists }
            XCTAssertTrue(gone, "\(tag): Menu did not pop the folder page")
            let home = poll(5) { app.descendants(matching: .any)["debug_hero"].firstMatch.exists }
            XCTAssertTrue(home, "\(tag): Home's debug_hero never came back")
        }
    }

    func testCompactKeepsFocusAndRest() { keepsFocusAndRest(style: "compact", rowOneTop: 319) }

    func testStandardKeepsFocusAndRest() { keepsFocusAndRest(style: "standard", rowOneTop: 522) }

    // MARK: - 4c. Detail and back keeps the poster

    private struct FocusSnapshot: Equatable {
        var label: String
        var minX: Int, minY: Int
    }

    private func focusSnapshot(_ app: XCUIApplication) -> FocusSnapshot? {
        let e = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard e.exists else { return nil }
        return FocusSnapshot(label: e.label, minX: Int(e.frame.minX.rounded()), minY: Int(e.frame.minY.rounded()))
    }

    /// A row-1 poster that is not the first: Select opens its Detail (Cinemeta, the same route
    /// `BatchAFolderUITests.testClassicGridKeepsTabBarHiddenAfterDetail` uses: `debug_bridge`
    /// appears), Menu returns, and the same poster is focused with the page still at rest. Identity
    /// is the focused element's label and frame (tvOS 26.5 reports `hasFocus`); the laid-out
    /// geometry line and `scrolled=0` prove the page did not move.
    func testDetailReturnKeepsTheThirdPoster() {
        defer { clearSeed() }
        var previous: XCUIApplication?
        for style in ["standard", "compact"] {
            guard let app = openFolder(style: style, seed: Self.severalSources, shell: "T", terminateFirst: previous) else { return }
            previous = app
            let tag = "detailreturn-\(style)"
            for _ in 0..<3 where Self.token(state(app), "chip") != "-" { remote.press(.down); pause(1) }
            XCTAssertEqual(Self.token(state(app), "chip"), "-", "\(tag): focus is in the grid: \(state(app))")
            for _ in 0..<8 { remote.press(.left); pause(0.6) }
            remote.press(.right); pause(0.8)
            remote.press(.right); pause(1.2)
            guard let g = readGeo(app) else { return }
            guard let before = focusSnapshot(app) else { XCTFail("\(tag): no focused element before Detail"); return }
            XCTAssertEqual(CGFloat(before.minY), g.top(0), accuracy: 3, "\(tag): the focused poster is in row 1: \(before) \(g.line)")
            XCTAssertGreaterThan(before.minX, 400, "\(tag): the focused poster is the third, not the first: \(before)")
            XCTAssertEqual(Self.token(state(app), "scrolled"), "0", "\(tag): \(state(app))")
            let geoBefore = g.line

            var detail = false
            for attempt in 0..<2 where !detail {
                remote.press(.select)
                detail = poll(attempt == 0 ? 15 : 20) { app.descendants(matching: .any)["debug_bridge"].firstMatch.exists }
            }
            shot("\(tag)-detail")
            XCTAssertTrue(detail, "\(tag): Select did not open a Detail page (focus=\(before))")
            remote.press(.menu)
            let back = poll(15) { app.descendants(matching: .any)["folder_header"].firstMatch.exists && !app.descendants(matching: .any)["debug_bridge"].firstMatch.exists }
            XCTAssertTrue(back, "\(tag): Menu did not return to the folder page")
            pause(3)
            let after = focusSnapshot(app)
            note(tag, "before=\(before) after=\(String(describing: after)) \(state(app))")
            XCTAssertEqual(after, before, "\(tag): focus is not back on the same poster")
            XCTAssertEqual(Self.token(state(app), "scrolled"), "0", "\(tag): the page scrolled on return: \(state(app))")
            XCTAssertEqual(Self.token(state(app), "chip"), "-", "\(tag): focus fell to a chip on return: \(state(app))")
            XCTAssertEqual(geometry(app), geoBefore, "\(tag): the laid-out geometry changed across Detail")
            shot("\(tag)-back")
        }
    }

    // MARK: - 4b. Poster moves do not re-evaluate the page

    private func bodyCount(_ app: XCUIApplication) -> Int {
        Int(Self.token(state(app), "body") ?? "") ?? -1
    }

    /// GitHub #28 review P1: the page-level FocusState must change only when focus enters or leaves
    /// the grid, so moving between posters evaluates `FolderDetailView.body` zero times.
    /// `body=` is `FolderBodyCounter` (DEBUG static). The Down is reported, not asserted to be 0:
    /// when it scrolls the page, the scroll state may legitimately invalidate.
    func testPosterMovesDoNotInvalidateThePage() {
        defer { clearSeed() }
        var previous: XCUIApplication?
        for style in ["standard", "compact"] {
            guard let app = openFolder(style: style, seed: Self.severalSources, shell: "T", terminateFirst: previous) else { return }
            previous = app
            let tag = "bodycount-\(style)"
            for _ in 0..<3 where Self.token(state(app), "chip") != "-" { remote.press(.down); pause(1) }
            XCTAssertEqual(Self.token(state(app), "chip"), "-", "\(tag): focus is in the grid: \(state(app))")
            for _ in 0..<8 { remote.press(.left); pause(0.6) }
            pause(1)
            func step(_ name: String, _ press: XCUIRemote.Button, _ n: Int) -> Int {
                let before = bodyCount(app)
                for _ in 0..<n { remote.press(press); pause(0.8) }
                pause(1)
                let delta = bodyCount(app) - before
                note("\(tag)-\(name)", "delta=\(delta) \(state(app))")
                return delta
            }
            let right = step("right5", .right, 5)
            let down = step("down1", .down, 1)
            let left = step("left5", .left, 5)
            XCTAssertEqual(Self.token(state(app), "chip"), "-", "\(tag): still in the grid: \(state(app))")
            XCTAssertEqual(right, 0, "\(tag): 5 Right presses re-evaluated the page body")
            XCTAssertEqual(left, 0, "\(tag): 5 Left presses re-evaluated the page body")
            note("\(tag)-summary", "right5=\(right) down1=\(down) left5=\(left)")
        }
    }

    // MARK: - 5. Edit controls in Compact

    func testCompactEditControlsClearTitleAndChips() {
        defer { clearSeed() }

        /// Right until the Discover chip is focused (`chip=2`), Select it.
        func selectDiscoverChip(_ app: XCUIApplication, _ tag: String) {
            _ = poll(5) { Self.token(self.state(app), "chip") != "-" }
            for _ in 0..<4 where Self.token(state(app), "chip") != "2" {
                remote.press(.right); pause(1.2)
            }
            XCTAssertEqual(Self.token(state(app), "chip"), "2", "\(tag): Discover chip never focused: \(state(app))")
            remote.press(.select)
            pause(3)
        }

        func chipTop(_ app: XCUIApplication) -> CGFloat? {
            let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Discover Movies")).firstMatch
            return chip.exists ? chip.frame.minY : nil
        }

        // Classic, Compact
        guard let classic = openFolder(style: "compact", seed: Self.editSeed, shell: "T") else { return }
        selectDiscoverChip(classic, "classic-compact")
        let button = classic.buttons["folder.editFilters"]
        XCTAssertTrue(button.waitForExistence(timeout: 8), "classic-compact: folder.editFilters never rendered (state: \(state(classic)))")
        if button.exists {
            let f = button.frame
            let capsule = chipTop(classic) ?? 164
            note("classic-compact", "editFilters=\(f) chipTop=\(capsule) | \(state(classic))")
            XCTAssertEqual(f.minY, 72, accuracy: 2, "classic-compact: Edit Filters top")
            XCTAssertGreaterThanOrEqual(f.minY, 60, "classic-compact: below the 60 pt line")
            XCTAssertLessThanOrEqual(f.maxY, capsule - 16, "classic-compact: Edit Filters bottom \(f.maxY) vs chip top \(capsule)")
            XCTAssertGreaterThanOrEqual(f.minX, 1400, "classic-compact: Edit Filters is trailing")
        }
        shot("compact-edit-classic")
        assertEditControlTakesFocus(classic, control: button, tag: "classic-compact", downReturnsToChips: true, selectedChip: "2")

        // Classic, Standard (control)
        guard let standard = openFolder(style: "standard", seed: Self.editSeed, shell: "T", terminateFirst: classic) else { return }
        selectDiscoverChip(standard, "classic-standard")
        let sbutton = standard.buttons["folder.editFilters"]
        XCTAssertTrue(sbutton.waitForExistence(timeout: 8), "classic-standard: folder.editFilters never rendered")
        if sbutton.exists {
            note("classic-standard", "editFilters=\(sbutton.frame)")
            XCTAssertEqual(sbutton.frame.minY, 189, accuracy: 2, "classic-standard: Edit Filters top (157 + 32)")
        }
        shot("standard-edit-classic")
        assertEditControlTakesFocus(standard, control: sbutton, tag: "classic-standard", downReturnsToChips: true, selectedChip: "2")

        // Stage Home, Grid page, Compact: the Edit band's pill takes focus on Up.
        guard let stage = openFolder(style: "compact", seed: Self.editSeed, shell: "T", stage: true, terminateFirst: standard) else { return }
        selectDiscoverChip(stage, "stage-compact")
        remote.press(.up); pause(1.5)
        let menu = stage.descendants(matching: .any)["folder.editMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "stage-compact: folder.editMenu never existed")
        if menu.exists {
            let f = menu.frame
            let capsule = chipTop(stage) ?? 164
            note("stage-compact", "editMenu=\(f) hasFocus=\(menu.hasFocus) chipTop=\(capsule) | \(state(stage))")
            XCTAssertEqual(f.minY, 72, accuracy: 2, "stage-compact: Edit menu top")
            XCTAssertGreaterThanOrEqual(f.minY, 60, "stage-compact: below the 60 pt line")
            XCTAssertLessThanOrEqual(f.maxY, capsule - 16, "stage-compact: Edit menu bottom \(f.maxY) vs chip top \(capsule)")
            XCTAssertGreaterThanOrEqual(f.minX, 1400, "stage-compact: Edit menu is trailing")
        }
        shot("compact-edit-stage")
        // Up from the chips already ran above; assert it moved focus, then that Down gives it back.
        assertFocusOnControl(stage, menu, "stage-compact")
        assertEditControlReleasesFocus(stage, control: menu, tag: "stage-compact", returnsToChips: true, selectedChip: "2")

        // Stage Home, Grid page, Standard (control): the engine reaches the chips itself.
        guard let stageStandard = openFolder(style: "standard", seed: Self.editSeed, shell: "T", stage: true, terminateFirst: stage) else { return }
        selectDiscoverChip(stageStandard, "stage-standard")
        remote.press(.up); pause(1.5)
        let smenu = stageStandard.descendants(matching: .any)["folder.editMenu"].firstMatch
        XCTAssertTrue(smenu.waitForExistence(timeout: 8), "stage-standard: folder.editMenu never existed")
        if smenu.exists {
            assertFocusOnControl(stageStandard, smenu, "stage-standard")
            assertEditControlReleasesFocus(stageStandard, control: smenu, tag: "stage-standard", returnsToChips: true, selectedChip: "2")
        }
    }

    private struct FocusNode { let identifier: String; let label: String; let frame: CGRect }

    private func focusedNodes(_ app: XCUIApplication) -> [FocusNode] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [FocusNode] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { out.append(FocusNode(identifier: node.identifier, label: node.label, frame: node.frame)) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Focus signal: the snapshot's `hasFocus` nodes (reliable on this project's 26.5 clone; the
    /// guest-picker walk in `openFolder` relies on it too) matched against the control's frame, because
    /// the Edit menu's identifier sits on a container rather than on the focused pill. The `chip=`
    /// token of `folder_header_state` (`-` when no chip holds focus) backs it up.
    private func controlHasFocus(_ app: XCUIApplication, _ control: XCUIElement) -> Bool {
        let f = control.frame.insetBy(dx: -6, dy: -6)
        return focusedNodes(app).contains { $0.identifier == "folder.editFilters" || $0.identifier == "folder.editMenu"
            || ($0.frame.width > 20 && f.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))) }
    }

    private func assertEditControlTakesFocus(_ app: XCUIApplication, control: XCUIElement, tag: String, downReturnsToChips: Bool, selectedChip: String? = nil) {
        guard control.exists else { return }
        remote.press(.up); pause(1.5)
        assertFocusOnControl(app, control, tag)
        assertEditControlReleasesFocus(app, control: control, tag: tag, returnsToChips: downReturnsToChips, selectedChip: selectedChip)
    }

    private func assertFocusOnControl(_ app: XCUIApplication, _ control: XCUIElement, _ tag: String) {
        let nodes = focusedNodes(app).map { "\($0.identifier)|\($0.label)|\($0.frame)" }
        note(tag, "after Up: focused=\(nodes) | \(state(app))")
        XCTAssertTrue(controlHasFocus(app, control), "\(tag): the Edit control does not hold focus after Up | \(nodes)")
        XCTAssertEqual(Self.token(state(app), "chip"), "-", "\(tag): a chip still holds focus after Up | \(state(app))")
    }

    /// Down from the Edit control returns focus to the chips, in Standard and in Compact (Compact's chip
    /// row is wholly above the grid pane, so the page's focus watcher hands the focus over when the
    /// engine lands on a poster). `selectedChip` is the selected tab's index: the chip that takes
    /// focus is that one, and the grid never scrolled and its pane did not move (a brief poster
    /// focus must not leave a trace).
    private func assertEditControlReleasesFocus(_ app: XCUIApplication, control: XCUIElement, tag: String, returnsToChips: Bool, selectedChip: String? = nil) {
        let paneBefore = Self.token(geometry(app), "pane")
        remote.press(.down); pause(1.5)
        let nodes = focusedNodes(app).map { "\($0.identifier)|\($0.label)|\($0.frame)" }
        note(tag, "after Down: focused=\(nodes) | \(state(app))")
        XCTAssertFalse(controlHasFocus(app, control), "\(tag): Down did not leave the Edit control | \(nodes)")
        if returnsToChips {
            XCTAssertNotEqual(Self.token(state(app), "chip"), "-", "\(tag): Down did not return focus to the chips | \(nodes)")
            if let selectedChip {
                XCTAssertEqual(Self.token(state(app), "chip"), selectedChip, "\(tag): focus is not on the selected chip | \(state(app))")
            }
            XCTAssertEqual(Self.token(state(app), "scrolled"), "0", "\(tag): the grid scrolled | \(state(app))")
            XCTAssertEqual(Self.token(geometry(app), "pane"), paneBefore, "\(tag): the grid pane moved | \(geometry(app))")
        }
    }

    // MARK: - 6. Compact header pixels

    func testCompactHeaderPixels() throws {
        defer { clearSeed() }
        guard let app = openFolder(style: "compact", seed: Self.severalSources, shell: "T") else { return }
        shot("compact-several-T-pixels")
        let image = XCUIScreen.main.screenshot().image
        let window = app.windows.firstMatch.frame.size
        let bg = try pixelRGB(in: image, at: CGPoint(x: 20, y: 20), windowSize: window)

        func ink(_ rect: CGRect) throws -> Double {
            try fractionDiffering(in: image, pointRect: rect, windowSize: window, from: bg, threshold: 40)
        }
        let title = try ink(CGRect(x: 660, y: 72, width: 600, height: 64))
        let gap = try ink(CGRect(x: 80, y: 138, width: 1760, height: 12))
        let chips = try ink(CGRect(x: 80, y: 164, width: 1760, height: 59))
        let top = try ink(CGRect(x: 160, y: 0, width: 1600, height: 60))
        note("pixels", "bg=\(bg) title=\(title) gap=\(gap) chips=\(chips) top=\(top)")
        XCTAssertGreaterThanOrEqual(title, 0.01, "title ink in [72, 136]")
        XCTAssertLessThan(gap, 0.01, "no grid content in the band gap [138, 150]")
        XCTAssertGreaterThanOrEqual(chips, 0.01, "chip ink in [164, 223]")
        XCTAssertLessThan(top, 0.005, "only page colour in [0, 60]")
    }

    // MARK: - Pixel helpers (copied from NuvioTVUITests)

    private func pixelRGB(in image: UIImage, at point: CGPoint, windowSize: CGSize) throws -> [Int] {
        guard let cg = image.cgImage, windowSize.width > 0 else {
            throw XCTSkip("screenshot has no CGImage / zero window size")
        }
        let scale = CGFloat(cg.width) / windowSize.width
        let rect = CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1)
        guard let px = cg.cropping(to: rect.integral) else { throw XCTSkip("pixel \(point) off-screen") }
        var buf = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return [Int(buf[0]), Int(buf[1]), Int(buf[2])]
    }

    private func fractionDiffering(in image: UIImage, pointRect: CGRect, windowSize: CGSize,
                                   from reference: [Int], threshold: Int) throws -> Double {
        guard reference.count >= 3, let cg = image.cgImage, windowSize.width > 0 else {
            throw XCTSkip("no reference colour / CGImage")
        }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(x: pointRect.minX * scale, y: pointRect.minY * scale,
                        width: pointRect.width * scale, height: pointRect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else { throw XCTSkip("rect \(pointRect) is off-screen") }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw XCTSkip("could not build a bitmap context") }
        var hits = 0, total = 0, i = 0
        while i + 2 < buffer.count {
            let d = max(abs(Int(buffer[i]) - reference[0]), abs(Int(buffer[i + 1]) - reference[1]), abs(Int(buffer[i + 2]) - reference[2]))
            if d > threshold { hits += 1 }
            total += 1
            i += 4
        }
        return total == 0 ? 0 : Double(hits) / Double(total)
    }
}
