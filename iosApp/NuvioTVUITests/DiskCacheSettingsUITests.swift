import XCTest

/// GitHub #29: Settings › Player › Buffering › Disk Cache. The row shows only while Experimental
/// engine: Aether is On, its explainer fits the laid-out column (the DEBUG probe
/// `debug_settings_explainer … desc_truncated=0`, read from the laid-out view like `test82`), the
/// last menu item (Maximum) reads "Up to G GB" (or "Not enough free space" when the Mac's disk, which
/// is the simulator's tmp volume, is that full; no exact G is asserted), and the choice persists
/// across a relaunch. Ends by setting Off through the picker (a `-player.diskCacheGB -1` launch
/// argument may misparse, so the leg never seeds Maximum that way).
///
/// The fixture profile is the signed-out local guest "Chris"; nothing here signs in. Every Select is
/// pressed only once focus is verified on the intended element. House rule: this file owns its helpers.
final class DiskCacheSettingsUITests: XCTestCase {
    private let remote = XCUIRemote.shared
    private static let rowTitle = "Disk Cache"
    private static let maximumValue = try! NSRegularExpression(pattern: "^(Up to \\d+ GB|Not enough free space)$")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDiskCacheRowFollowsAetherAndExplainerFits() throws {
        // 1. Aether Off: no Disk Cache row anywhere in the Player pane.
        let off = launch(["-player.aetherEngine", "NO", "-player.diskCacheGB", "0"])
        try openPlayerPane(off)
        let offWalk = walkToExplainerRow(off, title: "Preload Next Episode Sources")
        shot(off, "dc1_aether_off_pane_end")
        XCTAssertTrue(offWalk.reached, "never reached the Next Episode section walking the Player pane — rows seen: \(offWalk.rows)")
        XCTAssertTrue(offWalk.rows.contains("Network Readahead"), "the walk never passed Network Readahead — rows seen: \(offWalk.rows)")
        XCTAssertFalse(offWalk.rows.contains(Self.rowTitle), "Disk Cache shows while Aether is Off — rows seen: \(offWalk.rows)")
        XCTAssertFalse(off.descendants(matching: .any)
                        .matching(NSPredicate(format: "label BEGINSWITH %@", Self.rowTitle)).firstMatch.exists,
                       "an element labelled Disk Cache exists while Aether is Off")

        // 2. Aether On: the row exists, reads Off, and its explainer fits the laid-out column.
        let on = launch(["-player.aetherEngine", "YES", "-player.diskCacheGB", "0"])
        try openPlayerPane(on)
        let onWalk = walkToExplainerRow(on, title: Self.rowTitle)
        shot(on, "dc2_disk_cache_row")
        XCTAssertTrue(onWalk.reached, "never reached Disk Cache with Aether On — rows seen: \(onWalk.rows)")
        XCTAssertEqual(onWalk.rows.firstIndex(of: Self.rowTitle).map { $0 - 1 }.map { onWalk.rows[$0] }, "Network Readahead",
                       "Disk Cache must sit right after Network Readahead — rows seen: \(onWalk.rows)")
        XCTAssertTrue(onWalk.probe.contains("desc_truncated=0"), "the Disk Cache explainer must fit its column, got: '\(onWalk.probe)'")
        XCTAssertTrue(waitForRowValue(on, timeout: 3) { $0 == "Off" }, "the row must read Off, got '\(rowValue(on))' — \(rowDump(on))")

        // 3. Pick the last item (Maximum): the row reads "Up to G GB" once the free-space probe returns.
        try pickMenuItem(on, last: true)
        shot(on, "dc3_maximum_picked")
        XCTAssertTrue(waitForRowValue(on, timeout: 6) { Self.matchesMaximum($0) },
                      "after picking Maximum the row must read 'Up to G GB' (or 'Not enough free space'), got '\(rowValue(on))' — \(rowDump(on))")
        let picked = rowValue(on)

        // 4. Relaunch without the diskCacheGB argument: the choice persisted. Then back to Off.
        let again = launch(["-player.aetherEngine", "YES"])
        try openPlayerPane(again)
        let againWalk = walkToExplainerRow(again, title: Self.rowTitle)
        XCTAssertTrue(againWalk.reached, "never reached Disk Cache after the relaunch — rows seen: \(againWalk.rows)")
        XCTAssertTrue(waitForRowValue(again, timeout: 6) { Self.matchesMaximum($0) },
                      "the Maximum choice did not persist across a relaunch (was '\(picked)', now '\(rowValue(again))')")
        shot(again, "dc4_persisted")
        try pickMenuItem(again, last: false)
        XCTAssertTrue(waitForRowValue(again, timeout: 3) { $0 == "Off" }, "setting Off through the picker failed, got '\(rowValue(again))'")
        shot(again, "dc5_back_to_off")
    }

    // MARK: - Launch and navigation

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-home_layout", "classic"] + arguments
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "the profile picker never appeared")
        DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        pause(8)
        return app
    }

    /// Settings tab, root list, then the Player category, each Select only on verified focus.
    private func openPlayerPane(_ app: XCUIApplication) throws {
        let tabNames = ["Home", "Search", "Discover", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.35)
        }
        let settings = app.buttons["Settings"]
        if !moveFocus(.right, until: settings, max: 6) { _ = moveFocus(.left, until: settings, max: 8) }
        try selectIfFocused(app, "settings_tab") { settings.exists && settings.hasFocus }
        pause(2)
        remote.press(.down)
        pause(1)
        // A persisted path may have left a pane open: Menu back only while no root list shows.
        for _ in 0..<3 where !rootPresent(app) {
            remote.press(.menu)
            pause(1.2)
        }
        XCTAssertTrue(rootPresent(app), "the Settings root list never appeared")
        var onPlayer = focusedRootIsPlayer(app)
        for _ in 0..<10 where !onPlayer { remote.press(.down); pause(0.6); onPlayer = focusedRootIsPlayer(app) }
        for _ in 0..<12 where !onPlayer { remote.press(.up); pause(0.6); onPlayer = focusedRootIsPlayer(app) }
        try selectIfFocused(app, "settings_category_player") { focusedRootIsPlayer(app) }
        pause(1.5)
        XCTAssertTrue(app.descendants(matching: .any)["settings_pane_player"].waitForExistence(timeout: 4),
                      "the Player pane did not push")
    }

    private func rootPresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_root_list"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_category_'")).firstMatch.exists
    }

    /// The focused root row is Player: by identifier inside the focused subtree, or by its label.
    private func focusedRootIsPlayer(_ app: XCUIApplication) -> Bool {
        guard let root = try? app.snapshot() else { return false }
        var focused: [XCUIElementSnapshot] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { focused.append(node) }
            node.children.forEach(walk)
        }
        walk(root)
        func hasPlayerID(_ node: XCUIElementSnapshot) -> Bool {
            node.identifier == "settings_category_player" || node.children.contains(where: hasPlayerID)
        }
        return focused.contains { hasPlayerID($0) || $0.label.hasPrefix("Player") }
    }

    // MARK: - The explainer walk

    /// From the pane's current row, presses Down until the explainer names `title`, recording each
    /// row's explainer title. Returns the fit probe read on the last row.
    private func walkToExplainerRow(_ app: XCUIApplication, title: String, maxPresses: Int = 50)
        -> (reached: Bool, probe: String, rows: [String]) {
        let explainerTitle = app.staticTexts["settings_explainer_title"]
        func read() -> String {
            pause(0.4)
            return explainerTitle.exists ? explainerTitle.label : ""
        }
        var current = read()
        var rows = [current]
        var presses = 0
        while current != title && presses < maxPresses {
            remote.press(.down)
            presses += 1
            pause(0.5)
            current = read()
            if rows.last != current { rows.append(current) }
        }
        return (current == title, explainerProbe(app), rows)
    }

    private func explainerProbe(_ app: XCUIApplication) -> String {
        let probe = app.staticTexts["debug_settings_explainer"]
        if probe.exists { return probe.label }
        guard let root = try? app.snapshot() else { return "" }
        func find(_ node: XCUIElementSnapshot) -> String? {
            if node.identifier == "debug_settings_explainer" { return node.label }
            for child in node.children { if let hit = find(child) { return hit } }
            return nil
        }
        return find(root) ?? ""
    }

    // MARK: - The row and its menu

    private static func matchesMaximum(_ value: String) -> Bool {
        maximumValue.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// The row's trailing value, from one snapshot: the node tagged `player_row_disk_cache` (or the
    /// focused node whose label starts with the title), then its accessibility value, its label after
    /// the title, or the first text in its subtree that is not the title.
    private func rowValue(_ app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return "" }
        func find(_ node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if node.identifier == "player_row_disk_cache" { return node }
            for child in node.children { if let hit = find(child) { return hit } }
            return nil
        }
        func findFocused(_ node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if node.hasFocus, node.label.hasPrefix(Self.rowTitle) { return node }
            for child in node.children { if let hit = findFocused(child) { return hit } }
            return nil
        }
        guard let row = find(root) ?? findFocused(root) else { return "" }
        if let value = row.value as? String, !value.isEmpty { return value }
        let label = row.label
        for prefix in [Self.rowTitle + ", ", Self.rowTitle] where label.hasPrefix(prefix) && label.count > prefix.count {
            return String(label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        func texts(_ node: XCUIElementSnapshot) -> [String] {
            var out: [String] = []
            if node.elementType == .staticText, !node.label.isEmpty, node.label != Self.rowTitle { out.append(node.label) }
            for child in node.children { out += texts(child) }
            return out
        }
        return texts(row).first ?? ""
    }

    /// For failure messages: every focused node and the tagged row, with identifier, label and value.
    private func rowDump(_ app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return "<no snapshot>" }
        var out: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus || node.identifier == "player_row_disk_cache" || node.label.hasPrefix(Self.rowTitle) {
                out.append("[\(node.elementType.rawValue) id=\(node.identifier) label=\(node.label) value=\(String(describing: node.value)) focus=\(node.hasFocus)]")
            }
            node.children.forEach(walk)
        }
        walk(root)
        return out.joined(separator: " ")
    }

    private func waitForRowValue(_ app: XCUIApplication, timeout: TimeInterval, _ ok: (String) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok(rowValue(app)) { return true }
            pause(0.3)
        }
        return ok(rowValue(app))
    }

    /// With the Disk Cache row focused (verified by the explainer), opens its menu and picks the last
    /// item (`last`) or the first (Off). The tvOS menu popover is drawn outside the app's accessibility
    /// tree (2026-11-21 run: the snapshot holds only the row's own "Off" while the popover shows Off /
    /// 5 GB / 10 GB / Up to 12 GB), so the item's focus cannot be read. The walk is deterministic
    /// instead: the menu has at most five items and Down past the last (Up past the first) does
    /// nothing, so eight presses always land on the end. The pick is then verified by the row value.
    private func pickMenuItem(_ app: XCUIApplication, last: Bool) throws {
        try selectIfFocused(app, "disk_cache_row") {
            app.staticTexts["settings_explainer_title"].exists && app.staticTexts["settings_explainer_title"].label == Self.rowTitle
        }
        pause(1.5)
        for _ in 0..<8 {
            remote.press(last ? .down : .up)
            pause(0.4)
        }
        shot(app, last ? "dc_menu_on_last" : "dc_menu_on_off")
        remote.press(.select)
        pause(1.5)
    }

    // MARK: - Focus and remote

    private func focusedLabels(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus, !node.label.isEmpty { out.append(node.label) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    private func selectIfFocused(_ app: XCUIApplication, _ what: String, when isTarget: () -> Bool) throws {
        guard isTarget() else {
            shot(app, "unverified_\(what)")
            let focused = focusedLabels(app)
            if focused.isEmpty { throw XCTSkip("\(what): no element reports focus on this runtime — not pressing Select blind") }
            XCTFail("\(what): focus is not on the intended element (focused: \(focused)) — not pressing Select")
            return
        }
        remote.press(.select)
    }

    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.7)
        }
        return element.exists && element.hasFocus
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
