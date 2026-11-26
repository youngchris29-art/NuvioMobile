import XCTest

/// GitHub #34: Settings › About › Clear Cache. The row is the last one in About, right after Fonts,
/// and its explainer fits the laid-out column (the DEBUG probe `debug_settings_explainer …
/// desc_truncated=0`). Select opens the "Clear Cache?" alert with Clear and Cancel; the leg records
/// which button holds the initial focus (an owner question, not an assertion). Cancel closes it with
/// focus back on the row and no subtitle; Clear makes the row read "Cache cleared" with focus on
/// the row; a repeat Clear and a later Cancel keep that; leaving the pane resets it; a re-entry
/// clears again; then, back on Home, the hero backdrop, a poster and the seeded collection's tile
/// cover have all drawn.
///
/// Collection: one pinned folder seeded through the DEBUG `-debug.collectionsSeedJsonB64` knob (the
/// `CollectionHeaderUITests` mechanism). The knob replaces the profile's collections and the app has
/// no read-out, so the leg first proves a disposable baseline in an unseeded launch (signed-out
/// guest, no collection on Home) and refuses to seed otherwise; a teardown block registered before
/// the seed restores that empty baseline and asserts Home shows no collection. "Drawn" is read
/// from DEBUG signals: `debug_hero … pbd=1` (the presented hero backdrop bitmap) and, under
/// `-debug.cardGeometryProbe YES`, an `artwork_drawn` element inside a `poster_artwork` /
/// `folder_artwork` box (`CachedAsyncImage` publishes it once a decoded image is on screen). The
/// artwork comes from the same image hosts the fixture's Home already loads from.
///
/// The fixture profile is the signed-out local guest "Chris"; nothing here signs in. Every Select is
/// pressed only once focus is verified on the intended element. House rule: this file owns its helpers.
final class ClearCacheSettingsUITests: XCTestCase {
    private let remote = XCUIRemote.shared
    private static let rowTitle = "Clear Cache"
    private static let rowID = "settings_about_clear_cache"
    private static let clearedText = "Cache cleared"
    private static let alertTitle = "Clear Cache?"
    /// One pinned collection with one folder whose tile cover is its backdrop.
    private static let collectionSeed = """
    [{"id":"zzclearcache-collection","title":"ZZClearCache","pinToTop":true,"showAllTab":false,"folders":[{"id":"zzclearcache-folder","title":"ZZClearCacheFolder","hideTitle":false,"heroBackdropUrl":"https://images.metahub.space/background/medium/tt0111161/img","sources":[{"provider":"addon","addonId":"com.linvo.cinemeta","type":"movie","catalogId":"top"}]}]}]
    """

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testClearCacheRowAlertFocusAndFeedback() throws {
        // 0. The seed REPLACES and persists the active profile's collections, and the app offers no
        // way to read them out first. So the leg seeds only a verified disposable baseline: an
        // unseeded launch must show the signed-out guest and no collection on Home. Anything else
        // fails here, before any seed launch.
        let baseline = verifyDisposableBaseline()
        guard baseline.ok else {
            XCTFail("refusing to seed collections: this profile has its own, or is not the signed-out fixture guest — \(baseline.why)")
            return
        }
        // Registered before the seed is applied, so it also runs on every failure path: put the
        // verified-empty baseline back, then check Home shows no collection.
        addTeardownBlock { [weak self] in self?.restoreBaseline() }

        // 1. Launch with the seeded collection, pick the profile, and see Home draw: the hero
        // backdrop, a poster and the collection tile's cover (so the seed is known to be live).
        let app = launch(["-debug.artworkProbe", "YES", "-debug.cardGeometryProbe", "YES",
                          "-inline_trailers_enabled", "NO",
                          "-debug.collectionsSeedJsonB64", Data(Self.collectionSeed.utf8).base64EncodedString()])
        XCTAssertTrue(waitUntil(timeout: 60) { self.heroBackdropDrawn(app) }, "Home never drew its hero backdrop: \(heroProbe(app))")
        shot(app, "cc1_home")
        let before = scanHomeArt(app)
        shot(app, "cc1_home_rows")
        XCTAssertTrue(before.poster, "before the clear no poster drew on Home (scanned \(before.presses) rows)")
        XCTAssertTrue(before.collection, "before the clear the seeded collection tile's cover never drew (scanned \(before.presses) rows) — \(artDump(app))")

        // 2. Settings › About.
        try openAboutPane(app)

        // 3. Walk to the Clear Cache explainer: right after Fonts, and it fits.
        let walk = walkToExplainerRow(app, title: Self.rowTitle)
        shot(app, "cc3_row")
        XCTAssertTrue(walk.reached, "never reached Clear Cache in the About pane — rows seen: \(walk.rows)")
        XCTAssertEqual(walk.rows.firstIndex(of: Self.rowTitle).flatMap { $0 > 0 ? walk.rows[$0 - 1] : nil }, "Fonts",
                       "Clear Cache must sit right after Fonts — rows seen: \(walk.rows)")
        XCTAssertTrue(walk.probe.contains("desc_truncated=0"), "the Clear Cache explainer must fit its column, got: '\(walk.probe)'")
        XCTAssertTrue(rowHasFocus(app), "the Clear Cache row is not focused — \(rowDump(app))")
        XCTAssertFalse(rowLabel(app).contains(Self.clearedText), "the row reads Cache cleared before any clear: '\(rowLabel(app))'")

        // 4. Select: the alert with Clear and Cancel. Record the initial focus.
        try openAlert(app)
        let initial = alertFocusedButton(app)
        let note = XCTAttachment(string: "alert_initial_focus=\(initial ?? "none reported")")
        note.name = "cc4_alert_initial_focus"
        note.lifetime = .keepAlways
        add(note)
        NSLog("[ClearCacheUITest] alert_initial_focus=%@", initial ?? "none")
        shot(app, "cc4_alert")

        // 5. Cancel: the alert closes, focus is back on the row, no subtitle.
        try choose(app, "Cancel")
        XCTAssertTrue(waitUntil(timeout: 4) { !self.alert(app).exists }, "the alert did not close after Cancel")
        XCTAssertTrue(waitUntil(timeout: 4) { self.rowHasFocus(app) }, "focus is not on the row after Cancel — \(rowDump(app))")
        XCTAssertFalse(rowLabel(app).contains(Self.clearedText), "Cancel must not clear: '\(rowLabel(app))'")
        shot(app, "cc5_after_cancel")

        // 6. Clear: within 5 s the row reads Cache cleared and keeps focus.
        try openAlert(app)
        try choose(app, "Clear")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.alert(app).exists && self.rowLabel(app).contains(Self.clearedText) },
                      "the row never read Cache cleared after Clear — \(rowDump(app))")
        XCTAssertTrue(waitUntil(timeout: 3) { self.rowHasFocus(app) }, "focus is not on the row after Clear — \(rowDump(app))")
        shot(app, "cc6_cleared")

        // 7. Repeat Clear at once, then Cancel: still Cache cleared, focus on the row, app alive.
        try openAlert(app)
        try choose(app, "Clear")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.alert(app).exists && self.rowLabel(app).contains(Self.clearedText) },
                      "the row lost Cache cleared after a repeat Clear — \(rowDump(app))")
        XCTAssertTrue(waitUntil(timeout: 3) { self.rowHasFocus(app) }, "focus is not on the row after a repeat Clear — \(rowDump(app))")
        try openAlert(app)
        try choose(app, "Cancel")
        XCTAssertTrue(waitUntil(timeout: 4) { !self.alert(app).exists }, "the alert did not close after the second Cancel")
        XCTAssertTrue(rowLabel(app).contains(Self.clearedText), "Cancel after a clear must keep Cache cleared: '\(rowLabel(app))'")
        XCTAssertEqual(app.state, .runningForeground, "the app stopped after repeat presses")
        shot(app, "cc7_repeat")

        // 8. Leave the pane and come back: no subtitle. Clear once more, then Home.
        remote.press(.menu)
        pause(1.5)
        XCTAssertTrue(rootPresent(app), "Menu did not return to the Settings root")
        try selectAboutCategory(app)
        let back = walkToExplainerRow(app, title: Self.rowTitle)
        XCTAssertTrue(back.reached, "never reached Clear Cache after re-entering About — rows seen: \(back.rows)")
        XCTAssertFalse(rowLabel(app).contains(Self.clearedText), "the row must reset after leaving the pane: '\(rowLabel(app))'")
        try openAlert(app)
        try choose(app, "Clear")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.alert(app).exists && self.rowLabel(app).contains(Self.clearedText) },
                      "the row never read Cache cleared on re-entry — \(rowDump(app))")
        shot(app, "cc8_reentry_cleared")

        try goHome(app)
        XCTAssertTrue(waitUntil(timeout: 30) { self.heroBackdropDrawn(app) },
                      "after the clear the hero backdrop did not draw: \(heroProbe(app))")
        shot(app, "cc8_home_hero_after_clear")
        let after = scanHomeArt(app)
        shot(app, "cc8_home_rows_after_clear")
        XCTAssertTrue(after.poster, "after the clear no poster drew on Home (scanned \(after.presses) rows)")
        XCTAssertTrue(after.collection, "after the clear the collection tile's cover did not draw (scanned \(after.presses) rows)")
        XCTAssertEqual(app.state, .runningForeground, "the app is not running after returning Home")
    }

    // MARK: - Launch and navigation

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-home_layout", "classic"] + arguments
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "the profile picker never appeared")
        DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        XCTAssertTrue(waitUntil(timeout: 60) { app.descendants(matching: .any)["debug_hero"].firstMatch.exists },
                      "Home never appeared after the profile pick")
        return app
    }

    private static let tabNames = ["Home", "Search", "Discover", "Library", "Add-ons", "Settings", "Profile"]

    /// Up until a tab holds focus.
    private func focusTabBar(_ app: XCUIApplication) {
        for _ in 0..<40 {
            if Self.tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { return }
            remote.press(.up)
            pause(0.35)
        }
    }

    private func selectTab(_ app: XCUIApplication, _ name: String) throws {
        focusTabBar(app)
        let tab = app.buttons[name]
        if !moveFocus(.right, until: tab, max: 6) { _ = moveFocus(.left, until: tab, max: 8) }
        try selectIfFocused(app, "\(name)_tab") { tab.exists && tab.hasFocus }
        pause(2)
    }

    /// Settings tab, root list, then the About category, each Select only on verified focus.
    private func openAboutPane(_ app: XCUIApplication) throws {
        try openSettingsRoot(app)
        try selectAboutCategory(app)
    }

    /// Settings tab, then the root list.
    private func openSettingsRoot(_ app: XCUIApplication) throws {
        try selectTab(app, "Settings")
        remote.press(.down)
        pause(1)
        // A persisted path may have left a pane open: Menu back only while no root list shows.
        for _ in 0..<3 where !rootPresent(app) {
            remote.press(.menu)
            pause(1.2)
        }
        XCTAssertTrue(rootPresent(app), "the Settings root list never appeared")
    }

    private func selectAboutCategory(_ app: XCUIApplication) throws {
        try selectCategory(app, "about", labelPrefix: "About")
    }

    /// Moves to the root row `settings_category_<category>` and opens its pane.
    private func selectCategory(_ app: XCUIApplication, _ category: String, labelPrefix: String) throws {
        func on() -> Bool { focusedRootIs(app, category: category, labelPrefix: labelPrefix) }
        var onRow = on()
        for _ in 0..<16 where !onRow { remote.press(.down); pause(0.6); onRow = on() }
        for _ in 0..<16 where !onRow { remote.press(.up); pause(0.6); onRow = on() }
        try selectIfFocused(app, "settings_category_\(category)") { on() }
        XCTAssertTrue(app.descendants(matching: .any)["settings_pane_\(category)"].waitForExistence(timeout: 5),
                      "the \(labelPrefix) pane did not push")
    }

    private func rootPresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_root_list"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_category_'")).firstMatch.exists
    }

    /// The focused root row is `category`: by identifier inside the focused subtree, or by its label.
    private func focusedRootIs(_ app: XCUIApplication, category: String, labelPrefix: String) -> Bool {
        guard let root = try? app.snapshot() else { return false }
        var focused: [XCUIElementSnapshot] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { focused.append(node) }
            node.children.forEach(walk)
        }
        walk(root)
        func hasID(_ node: XCUIElementSnapshot) -> Bool {
            node.identifier == "settings_category_\(category)" || node.children.contains(where: hasID)
        }
        return focused.contains { hasID($0) || $0.label.hasPrefix(labelPrefix) }
    }

    /// Menu back out of Settings to the tab bar, then the Home tab.
    private func goHome(_ app: XCUIApplication) throws {
        for _ in 0..<3 where app.descendants(matching: .any)["settings_pane_about"].exists {
            remote.press(.menu)
            pause(1.2)
        }
        try selectTab(app, "Home")
    }

    // MARK: - Home

    private func heroProbe(_ app: XCUIApplication) -> String {
        let probe = app.descendants(matching: .any)["debug_hero"].firstMatch
        return probe.exists ? probe.label : "<no debug_hero>"
    }

    /// The hero's presented backdrop is a decoded bitmap (`pbd=1`).
    private func heroBackdropDrawn(_ app: XCUIApplication) -> Bool {
        heroProbe(app).split(separator: " ").contains("pbd=1")
    }

    /// Whether some `artwork_drawn` element belongs to some `box` element, from one snapshot: its
    /// centre lies inside the box and it is at most four times the box's area (a `.fill` image
    /// overflows its tile before the clip, so plain containment is too strict; the area cap keeps a
    /// full-screen backdrop behind the rows from counting).
    private func drawnInside(_ box: String, in root: XCUIElementSnapshot) -> Bool {
        var boxes: [CGRect] = []
        var drawn: [CGRect] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier == box, node.frame.width > 1, node.frame.height > 1 { boxes.append(node.frame) }
            if node.identifier == "artwork_drawn", node.frame.width > 1, node.frame.height > 1 { drawn.append(node.frame) }
            node.children.forEach(walk)
        }
        walk(root)
        return drawn.contains { d in
            boxes.contains { b in
                b.insetBy(dx: -2, dy: -2).contains(CGPoint(x: d.midX, y: d.midY))
                    && d.width * d.height <= 4 * b.width * b.height
            }
        }
    }

    /// Presses Down (up to 12 rows, each waiting at most 4 s for art to land) until a drawn poster
    /// and a drawn collection tile cover have both been seen.
    private func scanHomeArt(_ app: XCUIApplication) -> (poster: Bool, collection: Bool, presses: Int) {
        var poster = false
        var collection = false
        var folderSeenDump: String?
        func look() {
            guard let root = try? app.snapshot() else { return }
            poster = poster || drawnInside("poster_artwork", in: root)
            collection = collection || drawnInside("folder_artwork", in: root)
            if !collection, folderSeenDump == nil, app.descendants(matching: .any)["folder_artwork"].firstMatch.exists {
                folderSeenDump = artDump(app)
            }
        }
        defer {
            if !collection, let folderSeenDump {
                let note = XCTAttachment(string: folderSeenDump)
                note.name = "folder_box_seen_without_drawn_art"
                note.lifetime = .keepAlways
                add(note)
                NSLog("[ClearCacheUITest] folder box seen without drawn art: %@", folderSeenDump)
            }
        }
        look()
        var presses = 0
        while !(poster && collection) && presses < 12 {
            remote.press(.down)
            presses += 1
            _ = waitUntil(timeout: 4) { look(); return poster && collection }
        }
        return (poster, collection, presses)
    }

    /// For failure messages: the frames of every artwork box and drawn marker on screen.
    private func artDump(_ app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return "<no snapshot>" }
        var out: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if ["folder_artwork", "folder_card", "poster_artwork", "artwork_drawn"].contains(node.identifier) {
                let f = node.frame
                out.append("\(node.identifier)@\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))")
            }
            node.children.forEach(walk)
        }
        walk(root)
        return out.joined(separator: " ")
    }

    /// Any collection tile on Home, from one snapshot (needs `-debug.cardGeometryProbe YES`).
    private func homeShowsCollection(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(identifier: "folder_card").firstMatch.exists
            || app.descendants(matching: .any).matching(identifier: "folder_artwork").firstMatch.exists
    }

    /// Walks every Home row (Down until the focused row stops changing, at most 15 presses) and
    /// reports whether a collection tile showed anywhere. The walk ends on the last row.
    private func homeHasAnyCollection(_ app: XCUIApplication) -> (found: Bool, presses: Int) {
        var found = homeShowsCollection(app)
        var presses = 0
        var lastFocus = focusedLabels(app)
        var unchanged = 0
        while !found && presses < 15 && unchanged < 2 {
            remote.press(.down)
            presses += 1
            _ = waitUntil(timeout: 2) { self.homeShowsCollection(app) }
            found = homeShowsCollection(app)
            let focus = focusedLabels(app)
            unchanged = focus == lastFocus ? unchanged + 1 : 0
            lastFocus = focus
        }
        return (found, presses)
    }

    /// An unseeded launch: the active profile must be the signed-out guest (Settings › Account &
    /// Profiles offers "Sign In to Nuvio", shown only to a guest) and Home must show no collection.
    private func verifyDisposableBaseline() -> (ok: Bool, why: String) {
        let app = launch(["-debug.cardGeometryProbe", "YES", "-inline_trailers_enabled", "NO"])
        defer { app.terminate() }
        guard waitUntil(timeout: 60, { self.heroBackdropDrawn(app) }) else {
            return (false, "Home never drew on the unseeded launch: \(heroProbe(app))")
        }
        let scan = homeHasAnyCollection(app)
        shot(app, "cc0_baseline_home_end")
        if scan.found { return (false, "Home already shows a collection (row \(scan.presses))") }
        do {
            try openSettingsRoot(app)
            try selectCategory(app, "accountProfiles", labelPrefix: "Account")
        } catch {
            return (false, "could not open Settings › Account & Profiles: \(error)")
        }
        let signIn = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Sign In to Nuvio")).firstMatch
        let guest = signIn.waitForExistence(timeout: 5)
        shot(app, "cc0_baseline_account")
        if !guest { return (false, "Account & Profiles shows no Sign In row, so this is not a guest session") }
        return (true, "")
    }

    /// Puts back the verified-empty baseline (an empty seed), then asserts Home shows no collection.
    private func restoreBaseline() {
        let app = launch(["-debug.cardGeometryProbe", "YES", "-inline_trailers_enabled", "NO",
                          "-debug.collectionsSeedJsonB64", Data("[]".utf8).base64EncodedString()])
        defer { app.terminate() }
        XCTAssertTrue(waitUntil(timeout: 60) { self.heroBackdropDrawn(app) }, "restore: Home never drew: \(heroProbe(app))")
        let scan = homeHasAnyCollection(app)
        shot(app, "cc9_restored_home_end")
        XCTAssertFalse(scan.found, "restore: Home still shows a collection after the empty seed (row \(scan.presses))")
    }

    // MARK: - The explainer walk

    /// From the pane's current row, presses Down until the explainer names `title`, recording each
    /// row's explainer title. Returns the fit probe read on the last row.
    private func walkToExplainerRow(_ app: XCUIApplication, title: String, maxPresses: Int = 20)
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

    // MARK: - The row

    private func rowSnapshot(_ app: XCUIApplication) -> XCUIElementSnapshot? {
        guard let root = try? app.snapshot() else { return nil }
        func find(_ node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if node.identifier == Self.rowID { return node }
            for child in node.children { if let hit = find(child) { return hit } }
            return nil
        }
        return find(root)
    }

    /// The row's label plus every text in its subtree, so the subtitle is found however it is exposed.
    private func rowLabel(_ app: XCUIApplication) -> String {
        guard let row = rowSnapshot(app) else { return "" }
        var parts = [row.label]
        func texts(_ node: XCUIElementSnapshot) {
            if !node.label.isEmpty { parts.append(node.label) }
            if let value = node.value as? String, !value.isEmpty { parts.append(value) }
            node.children.forEach(texts)
        }
        row.children.forEach(texts)
        return parts.joined(separator: " | ")
    }

    /// Focus is on the row when a focused node is the row, inside it, or the list cell that holds
    /// it (tvOS reports focus on the cell, which carries no identifier).
    private func rowHasFocus(_ app: XCUIApplication) -> Bool {
        guard let root = try? app.snapshot() else { return false }
        func containsRow(_ node: XCUIElementSnapshot) -> Bool {
            node.identifier == Self.rowID || node.children.contains(where: containsRow)
        }
        func walk(_ node: XCUIElementSnapshot, insideRow: Bool) -> Bool {
            let inside = insideRow || node.identifier == Self.rowID
            if node.hasFocus && (inside || containsRow(node)) { return true }
            return node.children.contains { walk($0, insideRow: inside) }
        }
        return walk(root, insideRow: false)
    }

    /// For failure messages: every focused node and the tagged row, with identifier, label and value.
    private func rowDump(_ app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return "<no snapshot>" }
        var out: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus || node.identifier == Self.rowID || node.label.hasPrefix(Self.rowTitle) {
                out.append("[\(node.elementType.rawValue) id=\(node.identifier) label=\(node.label) value=\(String(describing: node.value)) focus=\(node.hasFocus)]")
            }
            node.children.forEach(walk)
        }
        walk(root)
        return out.joined(separator: " ")
    }

    // MARK: - The alert

    private func alert(_ app: XCUIApplication) -> XCUIElement {
        app.alerts.matching(NSPredicate(format: "label CONTAINS %@", Self.alertTitle)).firstMatch
    }

    private func alertButtons(_ app: XCUIApplication, _ label: String) -> XCUIElementQuery {
        app.alerts.buttons.matching(NSPredicate(format: "label == %@", label))
    }

    /// The alert's focused button label, read across every match (an alert can expose a button twice).
    private func alertFocusedButton(_ app: XCUIApplication) -> String? {
        _ = waitUntil(timeout: 3) {
            ["Clear", "Cancel"].contains { self.alertButtons(app, $0).allElementsBoundByIndex.contains { $0.hasFocus } }
        }
        return ["Clear", "Cancel"].first { alertButtons(app, $0).allElementsBoundByIndex.contains { $0.hasFocus } }
    }

    /// With the row focused (verified), Select and wait for the alert with both buttons.
    private func openAlert(_ app: XCUIApplication) throws {
        try selectIfFocused(app, "clear_cache_row") { rowHasFocus(app) }
        XCTAssertTrue(alert(app).waitForExistence(timeout: 5) || app.alerts.firstMatch.waitForExistence(timeout: 1),
                      "the Clear Cache? alert never appeared — \(rowDump(app))")
        XCTAssertTrue(app.alerts.firstMatch.label.contains(Self.alertTitle)
                        || app.alerts.staticTexts.matching(NSPredicate(format: "label == %@", Self.alertTitle)).firstMatch.exists,
                      "the alert is not titled Clear Cache? — \(app.alerts.firstMatch.label)")
        XCTAssertTrue(alertButtons(app, "Clear").firstMatch.exists, "the alert has no Clear button")
        XCTAssertTrue(alertButtons(app, "Cancel").firstMatch.exists, "the alert has no Cancel button")
    }

    /// Moves focus to the alert's `label` button (verified), then Select.
    private func choose(_ app: XCUIApplication, _ label: String) throws {
        func focused() -> Bool { alertButtons(app, label).allElementsBoundByIndex.contains { $0.hasFocus } }
        if !waitUntil(timeout: 2, focused) {
            for direction in [XCUIRemote.Button.down, .up, .right, .left] where !focused() {
                for _ in 0..<2 where !focused() { remote.press(direction); pause(0.4) }
            }
        }
        try selectIfFocused(app, "alert_\(label)") { focused() }
        pause(1)
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

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pause(0.3)
        }
        return condition()
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
