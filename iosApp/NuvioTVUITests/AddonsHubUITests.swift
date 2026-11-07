import XCTest

/// Add-ons hub C (H2 seed of H5's `AddonsHubUITests`): the hub is up with its summary and action
/// cards and the installed list on the FA87 fixture (Chris, which has add-ons), the first add-on
/// card takes focus and its four controls are reachable by Right. Prints `[HubLeg]` lines and
/// dwells 2 s per state so a screenshot from outside the runner can read each one.
///
/// Launch: `-home_layout classic -debug.rememberLastProfile NO -debug.trailerForceNoTrailer YES`;
/// the Chris tile is the shared verified step. No Select on a card control (nothing is changed on
/// the fixture: no toggle, no move, no remove, no install).
final class AddonsHubUITests: XCTestCase {
    let remote = XCUIRemote.shared

    /// Add-ons hub v2 (A2): the v1 hub page these legs drive (summary/action cards, the card list
    /// root) is gone; `AddonsSplitUITests` covers the split shell, and A8 rewrites these six legs
    /// onto the final panes.
    override func setUpWithError() throws {
        throw XCTSkip("Add-ons hub v2: v1 hub page replaced by the split view; A8 rewrites these legs.")
    }

    private func pause(_ s: TimeInterval) { Thread.sleep(forTimeInterval: s) }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func say(_ text: String) { print("[HubLeg] \(text)") }

    /// Identifiers only: a card's label carries the add-on host, which stays out of the logs.
    private func focusDump(_ app: XCUIApplication) -> String {
        let nodes = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        return nodes.isEmpty ? "<none>" : nodes.map { "[id=\($0.identifier)]" }.joined(separator: " ")
    }

    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, until target: XCUIElement, max: Int) -> Bool {
        for _ in 0..<max {
            if target.exists && target.hasFocus { return true }
            remote.press(direction)
            pause(0.4)
        }
        return target.exists && target.hasFocus
    }

    private func openTab(_ app: XCUIApplication, named title: String) {
        let tabNames = ["Home", "Search", "Discover", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.35)
        }
        let tab = app.buttons[title]
        if !moveFocus(.right, until: tab, max: 7) { _ = moveFocus(.left, until: tab, max: 8) }
        XCTAssertTrue(tab.hasFocus, "the \(title) tab never took focus; focused: \(focusDump(app))")
        remote.press(.select)
        pause(2)
    }

    func testHubCardsAndFirstAddonCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-home_layout", "classic", "-debug.rememberLastProfile", "NO",
                               "-debug.trailerForceNoTrailer", "YES", "-detail_trailer_autoplay", "NO"]
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists { DetailEntryRoute.selectChrisTile(self, app, timeout: 5) }
        pause(10)

        openTab(app, named: "Add-ons")
        XCTAssertTrue(element(app, "addons_hub_root").waitForExistence(timeout: 10), "addons_hub_root never appeared; focused: \(focusDump(app))")
        for id in ["addons_hub_summary_addons", "addons_hub_summary_catalogs", "addons_hub_summary_debrid",
                   "addons_hub_action_install", "addons_hub_action_refresh", "addons_hub_installed_title"] {
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 5), "\(id) missing")
        }
        say("hub up; plugins card: \(element(app, "addons_hub_summary_plugins").exists); phone card: \(element(app, "addons_hub_action_phone").exists)")
        pause(2)

        // Focus into the page: the first summary card, then the action row, then card 0.
        if !element(app, "addons_hub_summary_addons").hasFocus { remote.press(.down); pause(0.8) }
        say("after Down: \(focusDump(app))")
        pause(2)
        remote.press(.down); pause(0.8)
        say("action row: \(focusDump(app))")
        pause(2)
        let card0 = element(app, "addons_hub_card_0")
        XCTAssertTrue(card0.waitForExistence(timeout: 15), "no addons_hub_card_0 on the fixture (does Chris have add-ons?); empty=\(element(app, "addons_hub_empty").exists)")
        remote.press(.down); pause(0.8)
        XCTAssertTrue(moveFocus(.down, until: card0, max: 3), "card 0 never took focus; focused: \(focusDump(app))")
        say("card 0: exists=\(card0.exists) hasFocus=\(card0.hasFocus) enabled=\(card0.isEnabled)")
        pause(2)
        // The single-card fixture: Up and Down are disabled (no neighbour) and so skipped by
        // focus; Right from Toggle lands on Remove.
        for control in ["toggle", "remove"] {
            remote.press(.right); pause(0.6)
            let node = element(app, "addons_hub_card_0_\(control)")
            say("Right -> \(control): exists=\(node.exists) enabled=\(node.isEnabled) hasFocus=\(node.hasFocus)")
            XCTAssertTrue(node.exists && node.hasFocus, "\(control) never took focus; focused: \(focusDump(app))")
            pause(1.5)
        }
        for control in ["up", "down"] {
            let node = element(app, "addons_hub_card_0_\(control)")
            XCTAssertTrue(node.exists, "\(control) control missing")
            XCTAssertFalse(node.isEnabled, "\(control) should be disabled on the single-card fixture")
        }
        // Up on the remove control must stay inside the installed list or go to the action row,
        // never leave the hub.
        remote.press(.up); pause(0.8)
        let actions = ["addons_hub_action_install", "addons_hub_action_refresh", "addons_hub_action_phone"]
        let focusedAction = actions.first { element(app, $0).exists && element(app, $0).hasFocus }
        say("Up from controls: focused action card: \(focusedAction ?? "<none>")")
        XCTAssertNotNil(focusedAction, "focus after the final Up is not an addons_hub_action_* card; focused: \(focusDump(app))")
        XCTAssertTrue(element(app, "addons_hub_root").exists, "the hub went away")
        pause(2)
    }

    /// H3: the Install action card opens the install sheet with the URL field focused, and Menu
    /// closes the sheet with focus back on the Install card. No URL is typed; nothing installs.
    func testInstallSheetOpensAndCancels() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-home_layout", "classic", "-debug.rememberLastProfile", "NO",
                               "-debug.trailerForceNoTrailer", "YES", "-detail_trailer_autoplay", "NO"]
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists { DetailEntryRoute.selectChrisTile(self, app, timeout: 5) }
        pause(10)

        openTab(app, named: "Add-ons")
        XCTAssertTrue(element(app, "addons_hub_root").waitForExistence(timeout: 10), "addons_hub_root never appeared; focused: \(focusDump(app))")
        let install = element(app, "addons_hub_action_install")
        XCTAssertTrue(install.waitForExistence(timeout: 5), "addons_hub_action_install missing")

        remote.press(.down); pause(0.8)
        if !moveFocus(.down, until: install, max: 3) {
            if !moveFocus(.left, until: install, max: 3) { _ = moveFocus(.right, until: install, max: 3) }
        }
        XCTAssertTrue(install.hasFocus, "the Install action card never took focus; focused: \(focusDump(app))")
        say("install card focused")
        pause(2)

        remote.press(.select); pause(1.5)
        let field = element(app, "addons_hub_install_field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the install sheet did not open; focused: \(focusDump(app))")
        XCTAssertTrue(field.hasFocus, "the URL field does not hold focus; focused: \(focusDump(app))")
        say("sheet open: \(focusDump(app))")
        pause(2)

        remote.press(.menu); pause(1.5)
        XCTAssertFalse(element(app, "addons_hub_install_field").exists, "the sheet is still up after Menu")
        XCTAssertTrue(install.exists && install.hasFocus, "focus did not return to the Install card; focused: \(focusDump(app))")
        say("sheet closed: \(focusDump(app))")
        pause(2)
    }

    /// H4: the Catalogs summary card opens the catalogs page; the first row's name area, On/Off,
    /// Up (disabled on the first row) and Down are reachable by Right; Menu returns to the hub with the
    /// Catalogs card focused. Never Select on a control: nothing changes on the fixture.
    func testCatalogsPageOpensFromTheHub() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-home_layout", "classic", "-debug.rememberLastProfile", "NO",
                               "-debug.trailerForceNoTrailer", "YES", "-detail_trailer_autoplay", "NO"]
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists { DetailEntryRoute.selectChrisTile(self, app, timeout: 5) }
        pause(10)

        openTab(app, named: "Add-ons")
        XCTAssertTrue(element(app, "addons_hub_root").waitForExistence(timeout: 10), "addons_hub_root never appeared; focused: \(focusDump(app))")
        let card = element(app, "addons_hub_summary_catalogs")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "addons_hub_summary_catalogs missing")
        // Run 1: the page's default focus can already sit on the Add-ons summary card after the tab
        // Select, so an unconditional Down fell through to the action row. Go Down only while no
        // summary card has focus, then Right along the row.
        let summaryIds = ["addons_hub_summary_addons", "addons_hub_summary_catalogs", "addons_hub_summary_debrid", "addons_hub_summary_plugins"]
        for _ in 0..<4 where !summaryIds.contains(where: { element(app, $0).hasFocus }) {
            remote.press(.down); pause(0.8)
        }
        if !moveFocus(.right, until: card, max: 3) { _ = moveFocus(.left, until: card, max: 4) }
        XCTAssertTrue(card.hasFocus, "the Catalogs summary card never took focus; focused: \(focusDump(app))")
        pause(1)

        remote.press(.select); pause(1.5)
        XCTAssertTrue(element(app, "addons_hub_catalogs_root").waitForExistence(timeout: 5), "the catalogs page did not open; focused: \(focusDump(app))")
        XCTAssertTrue(element(app, "addons_hub_catalogs_title").exists, "catalogs title missing")
        let row0 = element(app, "addons_hub_catalog_0")
        XCTAssertTrue(row0.waitForExistence(timeout: 10), "no addons_hub_catalog_0 on the fixture; empty=\(element(app, "addons_hub_catalogs_empty").exists)")
        XCTAssertTrue(moveFocus(.down, until: row0, max: 4), "catalog row 0 never took focus; focused: \(focusDump(app))")
        let rowCount = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", "addons_hub_catalog_[0-9]+")).count
        say("catalogs page shows \(rowCount) rows")
        say("catalog row 0 focused")
        pause(1.5)

        remote.press(.right); pause(0.6)
        let toggle = element(app, "addons_hub_catalog_0_toggle")
        XCTAssertTrue(toggle.exists && toggle.hasFocus, "the toggle never took focus; focused: \(focusDump(app))")
        remote.press(.right); pause(0.6)
        let up = element(app, "addons_hub_catalog_0_up")
        let down = element(app, "addons_hub_catalog_0_down")
        XCTAssertTrue(up.exists, "up control missing")
        XCTAssertFalse(up.isEnabled, "up should be disabled on the first row")
        XCTAssertTrue(down.exists, "down control missing")
        if down.isEnabled {
            XCTAssertTrue(down.hasFocus, "down never took focus; focused: \(focusDump(app))")
        } else {
            XCTAssertTrue(toggle.hasFocus, "focus left the toggle on a one-catalog fixture; focused: \(focusDump(app))")
        }
        pause(1.5)

        remote.press(.menu); pause(1.5)
        XCTAssertFalse(element(app, "addons_hub_catalogs_root").exists, "the catalogs page is still up after Menu")
        XCTAssertTrue(element(app, "addons_hub_root").exists, "the hub is not showing")
        XCTAssertTrue(card.exists && card.hasFocus, "focus did not return to the Catalogs card; focused: \(focusDump(app))")
        say("back on the hub: \(focusDump(app))")
        pause(2)
    }

    // MARK: - H5 legs: shared helpers

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.25)
        }
        return condition()
    }

    private func focusDumpLabeled(_ app: XCUIApplication) -> String {
        let nodes = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        return nodes.isEmpty ? "<none>" : nodes.map { "[id=\($0.identifier) label=\($0.label)]" }.joined(separator: " ")
    }

    private static let hubCommon = [
        "-home_layout", "classic", "-debug.rememberLastProfile", "NO",
        "-debug.trailerForceNoTrailer", "YES", "-detail_trailer_autoplay", "NO",
        "-debug.streamAutoPlayModeOverride", "MANUAL",
    ]
    private static let hubStubPrefix = "/hub-zz-"

    @discardableResult
    private func launchHub(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists {
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
            // A Select landed right after launch is sometimes dropped on the FA87 sim (the picker
            // stayed up for 50 s on 2026-10-26); press once more while the tile still reads focused.
            if !waitUntil(timeout: 8, { !chris.exists }) {
                say("profile picker still up after Select; pressing Select again")
                if chris.exists && chris.hasFocus { remote.press(.select) }
                XCTAssertTrue(waitUntil(timeout: 10) { !chris.exists }, "the profile picker never went away; focused: \(focusDump(app))")
            }
        }
        return app
    }

    private func hubManifest(id: String, name: String) -> String {
        """
        {"id":"\(id)","version":"1.0.0","name":"\(name)","description":"Add-ons hub H5 leg","resources":[{"name":"stream","types":["movie"],"idPrefixes":["tt"]}],"types":["movie"],"catalogs":[]}
        """
    }

    private func hubStreams(_ items: [(name: String, title: String, file: String)], prefix: String, media: String) -> String {
        let body = items.map { item in
            "{\"name\":\"\(item.name)\",\"title\":\"\(item.title)\",\"url\":\"\(media)\(prefix)media/\(item.file)\"}"
        }.joined(separator: ",")
        return "{\"streams\":[\(body)]}"
    }

    /// Starts the media stub and the add-on stub (A: two streams, B: one) and registers their
    /// teardown blocks, then the cleanup launch (remove knob alone), all BEFORE any seed launch
    /// (the P5 rule: `continueAfterFailure = false` unwinds past `defer`s, so teardown blocks).
    private func startHubStubs() throws -> DiscoveryStubServer {
        let mediaStub = DiscoveryStubServer()
        try mediaStub.start()
        addTeardownBlock { mediaStub.stop() }
        let media = mediaStub.origin
        let addonStub = DiscoveryStubServer(routes: [
            (prefix: "/hub-zz-a/manifest.json", body: hubManifest(id: "zz.hub.a", name: "ZZ Hub A")),
            (prefix: "/hub-zz-a/stream/movie/", body: hubStreams([
                ("ZZ A\\n1080p", "Dune 2021 1080p WEB-DL", "a1.mp4"),
                ("ZZ A\\n720p", "Dune 2021 720p WEB", "a2.mp4"),
            ], prefix: "/hub-zz-a/", media: media)),
            (prefix: "/hub-zz-b/manifest.json", body: hubManifest(id: "zz.hub.b", name: "ZZ Hub B")),
            (prefix: "/hub-zz-b/stream/movie/", body: hubStreams([
                ("ZZ B\\n2160p", "Dune 2021 2160p", "b1.mp4"),
            ], prefix: "/hub-zz-b/", media: media)),
        ])
        try addonStub.start()
        addTeardownBlock { addonStub.stop() }
        addTeardownBlock { [self] in
            XCUIApplication().terminate()
            let cleanup = launchHub(Self.hubCommon + ["-debug.addonManifestRemoveMatching", Self.hubStubPrefix])
            pause(10)
            cleanup.terminate()
        }
        return addonStub
    }

    /// Seed launch: installs A through the DEBUG knob (the remove knob first, so a stale B goes too).
    private func seedHubAddonA(_ addonStub: DiscoveryStubServer) {
        let seed = launchHub(Self.hubCommon + [
            "-debug.addonManifestRemoveMatching", Self.hubStubPrefix,
            "-debug.addonManifestUrls", "\(addonStub.origin)/hub-zz-a/manifest.json",
        ])
        pause(14)
        seed.terminate()
    }

    private static let summaryIds = ["addons_hub_summary_addons", "addons_hub_summary_catalogs", "addons_hub_summary_debrid", "addons_hub_summary_plugins"]

    /// Down only while no summary card has focus (the page default can already sit on one).
    private func reachSummaryRow(_ app: XCUIApplication) {
        for _ in 0..<4 where !Self.summaryIds.contains(where: { element(app, $0).hasFocus }) {
            remote.press(.down); pause(0.8)
        }
    }

    /// Summary row, one Down to the action row, then along it to `id`.
    private func focusActionCard(_ app: XCUIApplication, _ id: String) {
        let card = element(app, id)
        XCTAssertTrue(card.waitForExistence(timeout: 5), "\(id) missing")
        reachSummaryRow(app)
        remote.press(.down); pause(0.8)
        if !card.hasFocus, !moveFocus(.right, until: card, max: 3) { _ = moveFocus(.left, until: card, max: 4) }
        XCTAssertTrue(card.hasFocus, "\(id) never took focus; focused: \(focusDump(app))")
    }

    private func focusSummaryCard(_ app: XCUIApplication, _ id: String) {
        let card = element(app, id)
        XCTAssertTrue(card.waitForExistence(timeout: 5), "\(id) missing")
        reachSummaryRow(app)
        if !card.hasFocus, !moveFocus(.right, until: card, max: 3) { _ = moveFocus(.left, until: card, max: 4) }
        XCTAssertTrue(card.hasFocus, "\(id) never took focus; focused: \(focusDump(app))")
    }

    /// Index of the installed card whose label contains `text`, nil when none is realized.
    private func cardIndex(_ app: XCUIApplication, containing text: String) -> Int? {
        for index in 0..<30 {
            let card = element(app, "addons_hub_card_\(index)")
            if card.exists, card.label.contains(text) { return index }
        }
        return nil
    }

    private func cardCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", "addons_hub_card_[0-9]+")).count
    }

    private func cardLabels(_ app: XCUIApplication) -> String {
        (0..<30).compactMap { index -> String? in
            let card = element(app, "addons_hub_card_\(index)")
            guard card.exists else { return nil }
            return String(card.label.split(separator: ",").first ?? "")
        }.joined(separator: " | ")
    }

    /// From the action row (or anywhere above the list) down to the installed card at `index`.
    private func focusCard(_ app: XCUIApplication, index: Int) {
        let card = element(app, "addons_hub_card_\(index)")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "addons_hub_card_\(index) missing; cards: \(cardLabels(app))")
        reachSummaryRow(app)
        remote.press(.down); pause(0.8)
        XCTAssertTrue(moveFocus(.down, until: card, max: 12), "card \(index) never took focus; focused: \(focusDump(app))")
    }

    private func detailUp(_ app: XCUIApplication) -> Bool {
        for _ in 0..<90 {
            if element(app, "detail_hero").exists || element(app, "detail_action_play").exists { return true }
            pause(0.5)
        }
        return false
    }

    // MARK: - H5 leg 1: install, reorder, picker order, remove

    func testInstallReorderPickerAndRemove() throws {
        continueAfterFailure = false
        let addonStub = try startHubStubs()
        let manifestB = "\(addonStub.origin)/hub-zz-b/manifest.json"

        // 1. Seed: A installed.
        seedHubAddonA(addonStub)

        // 2. Install B through the prefill seam.
        let app = launchHub(Self.hubCommon + ["-debug.installPrefillUrl", manifestB])
        pause(10)
        openTab(app, named: "Add-ons")
        XCTAssertTrue(element(app, "addons_hub_root").waitForExistence(timeout: 10), "addons_hub_root never appeared; focused: \(focusDump(app))")
        XCTAssertTrue(waitUntil(timeout: 20) { self.cardIndex(app, containing: "ZZ Hub A") != nil },
                      "A never showed on the hub (seed refused?); cards: \(cardLabels(app))")
        focusActionCard(app, "addons_hub_action_install")
        remote.press(.select); pause(1.5)

        let field = element(app, "addons_hub_install_field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the install sheet did not open; focused: \(focusDump(app))")
        XCTAssertTrue(waitUntil(timeout: 5) { field.hasFocus }, "the URL field does not hold focus; focused: \(focusDump(app))")
        let fieldValue = (field.value as? String) ?? ""
        say("prefill contains hub-zz-b (soft): \(fieldValue.contains("hub-zz-b"))")

        let installButton = element(app, "addons_hub_install_button")
        XCTAssertTrue(installButton.exists, "addons_hub_install_button missing")
        if !moveFocus(.down, until: installButton, max: 3) {
            if !moveFocus(.right, until: installButton, max: 3) { _ = moveFocus(.up, until: installButton, max: 2) }
        }
        XCTAssertTrue(installButton.hasFocus, "the Install button never took focus; focused: \(focusDump(app))")
        remote.press(.select)

        let modal = element(app, "addons_hub_install_modal")
        XCTAssertTrue(modal.waitForExistence(timeout: 20), "the install status modal never appeared; focused: \(focusDump(app))")
        XCTAssertTrue(waitUntil(timeout: 20) { modal.exists && modal.label.contains("Installed") },
                      "the modal never said Installed; label: \(modal.exists ? modal.label : "<gone>"); focused: \(focusDump(app))")
        let done = element(app, "addons_hub_install_done")
        XCTAssertTrue(done.waitForExistence(timeout: 5), "addons_hub_install_done missing")
        XCTAssertTrue(waitUntil(timeout: 5) { done.hasFocus }, "Done does not hold focus; focused: \(focusDump(app))")
        remote.press(.select)
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(app, "addons_hub_install_field").exists }, "the sheet is still up after Done")

        var bIndex = -1
        XCTAssertTrue(waitUntil(timeout: 15) {
            if let found = self.cardIndex(app, containing: "ZZ Hub B") { bIndex = found; return true }
            return false
        }, "no card labelled ZZ Hub B after install; cards: \(cardLabels(app))")
        let bCard = element(app, "addons_hub_card_\(bIndex)")
        XCTAssertTrue(waitUntil(timeout: 5) { bCard.hasFocus }, "focus did not land on the new B card (index \(bIndex)); focused: \(focusDump(app))")
        say("installed B at card \(bIndex) of \(cardCount(app))")
        pause(1)

        // 3. Reorder: B up one.
        XCTAssertGreaterThan(bIndex, 0, "B is the first card, nothing to move up; cards: \(cardLabels(app))")
        let upB = element(app, "addons_hub_card_\(bIndex)_up")
        XCTAssertTrue(moveFocus(.right, until: upB, max: 4), "B's Up control never took focus; focused: \(focusDump(app))")
        XCTAssertTrue(upB.isEnabled, "B's Up control is disabled")
        remote.press(.select)
        let newIndex = bIndex - 1
        XCTAssertTrue(waitUntil(timeout: 10) { self.cardIndex(app, containing: "ZZ Hub B") == newIndex },
                      "B did not move to card \(newIndex); cards: \(cardLabels(app))")
        // H2 focus-return rule: the same control follows the card; at the very top it is the name area.
        let landing = element(app, newIndex == 0 ? "addons_hub_card_0" : "addons_hub_card_\(newIndex)_up")
        XCTAssertTrue(waitUntil(timeout: 5) { landing.exists && landing.hasFocus },
                      "focus did not follow B to \(landing.identifier); focused: \(focusDump(app))")
        say("order after move: \(cardLabels(app))")
        pause(1.5)

        // 4. The picker follows the order: B's chip before A's.
        app.terminate()
        let detailApp = launchHub(Self.hubCommon + [
            "-debug.openDeepLink", "nuviotv://title?id=tt1160419&type=movie&name=Dune",
            "-detail_layout", "cinematic", "-home_upcoming_row_enabled", "NO",
        ])
        if !detailUp(detailApp) { throw XCTSkip("the deep link never produced a Detail page — network or fixture, not the hub") }
        var playFocused = false
        for _ in 0..<60 {
            let focused = detailApp.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let label = focused.exists ? focused.label : ""
            if label.hasPrefix("Play") || label.hasPrefix("Resume") { playFocused = true; break }
            pause(0.25)
        }
        XCTAssertTrue(playFocused, "focus never reached Play/Resume on Detail; focused: \(focusDumpLabeled(detailApp))")
        remote.press(.select)
        XCTAssertTrue(element(detailApp, "stream_picker_source_panel").waitForExistence(timeout: 20),
                      "stream_picker_source_panel never appeared; focused: \(focusDump(detailApp))")
        // The fixture has three add-ons (Cinemeta, A, B), so every chip is realized and under 10.
        func chipLabels() -> [String] {
            (0..<10).compactMap { i in
                let chip = self.element(detailApp, "stream_picker_chip_\(i)")
                return chip.exists ? chip.label : nil
            }
        }
        func position(_ name: String) -> Int? { chipLabels().firstIndex { $0.hasPrefix(name) } }
        XCTAssertTrue(waitUntil(timeout: 30) {
            guard let b = position("ZZ Hub B"), let a = position("ZZ Hub A") else { return false }
            let labels = chipLabels()
            return labels[b] == "ZZ Hub B, 1 source" && labels[a] == "ZZ Hub A, 2 sources"
        }, "the stub chips never settled to their counts; chips: \(chipLabels())")
        let chipB = position("ZZ Hub B") ?? -1
        let chipA = position("ZZ Hub A") ?? -1
        say("chip positions: B=\(chipB) A=\(chipA)")
        XCTAssertLessThan(chipB, chipA, "B's chip must come before A's after the move; chips: \(chipLabels())")
        remote.press(.menu); pause(1.5)
        detailApp.terminate()

        // 5. Remove B from the hub (relaunch: a clean path to the tab bar).
        let hubApp = launchHub(Self.hubCommon)
        pause(10)
        openTab(hubApp, named: "Add-ons")
        XCTAssertTrue(element(hubApp, "addons_hub_root").waitForExistence(timeout: 10), "addons_hub_root never appeared; focused: \(focusDump(hubApp))")
        var bNow = -1
        XCTAssertTrue(waitUntil(timeout: 20) {
            if let found = self.cardIndex(hubApp, containing: "ZZ Hub B") { bNow = found; return true }
            return false
        }, "ZZ Hub B is not on the hub after the relaunch; cards: \(cardLabels(hubApp))")
        focusCard(hubApp, index: bNow)
        let removeB = element(hubApp, "addons_hub_card_\(bNow)_remove")
        XCTAssertTrue(moveFocus(.right, until: removeB, max: 5), "B's Remove control never took focus; focused: \(focusDump(hubApp))")
        remote.press(.select)

        // The alert exposes its Remove button twice on the FA87 sim (one snapshot matched two
        // elements), so focus is read across every match rather than through a single element.
        let removeMatches = hubApp.alerts.buttons.matching(NSPredicate(format: "label == %@", "Remove"))
        XCTAssertTrue(removeMatches.firstMatch.waitForExistence(timeout: 5), "the Remove confirmation never appeared; focused: \(focusDump(hubApp))")
        XCTAssertTrue(hubApp.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Remove ZZ Hub B")).firstMatch.exists
                      || hubApp.alerts.firstMatch.label.contains("ZZ Hub B"),
                      "the alert does not name ZZ Hub B; alert: \(hubApp.alerts.firstMatch.label)")
        func removeHasFocus() -> Bool { removeMatches.allElementsBoundByIndex.contains { $0.hasFocus } }
        // Verified-focus rule: read focus, step to Remove only if it is not already there.
        if !waitUntil(timeout: 3, removeHasFocus) {
            // Cancel holds the default focus; the two buttons sit side by side on the FA87 sim.
            for direction in [XCUIRemote.Button.left, .right, .up, .down] where !removeHasFocus() {
                for _ in 0..<2 where !removeHasFocus() { remote.press(direction); pause(0.4) }
            }
        }
        XCTAssertTrue(removeHasFocus(), "the alert's Remove button does not hold focus; focused: \(focusDump(hubApp))")
        remote.press(.select)

        XCTAssertTrue(waitUntil(timeout: 10) { self.cardIndex(hubApp, containing: "ZZ Hub B") == nil },
                      "ZZ Hub B still on the hub; cards: \(cardLabels(hubApp))")
        let toast = element(hubApp, "addons_hub_toast")
        XCTAssertTrue(waitUntil(timeout: 10) { toast.exists && toast.label.contains("Removed ZZ Hub B") },
                      "the removal toast never said \"Removed ZZ Hub B.\"; toast: \(toast.exists ? toast.label : "<none>")")
        say("after remove, focused: \(focusDump(hubApp))")
        pause(2)
    }

    // MARK: - H5 leg 2: catalog toggle

    /// Toggles the first catalog off or on, reads "Disabled on Home", then restores it. The
    /// restore Select runs before the assertions on the flipped state, so a failed assertion still
    /// leaves the fixture as it was (unless the first Select itself never registered).
    func testCatalogToggleShowsDisabledOnHome() throws {
        continueAfterFailure = false
        let app = launchHub(Self.hubCommon)
        pause(10)
        openTab(app, named: "Add-ons")
        XCTAssertTrue(element(app, "addons_hub_root").waitForExistence(timeout: 10), "addons_hub_root never appeared; focused: \(focusDump(app))")
        focusSummaryCard(app, "addons_hub_summary_catalogs")
        remote.press(.select); pause(1.5)
        XCTAssertTrue(element(app, "addons_hub_catalogs_root").waitForExistence(timeout: 5), "the catalogs page did not open; focused: \(focusDump(app))")
        let row0 = element(app, "addons_hub_catalog_0")
        XCTAssertTrue(row0.waitForExistence(timeout: 10), "no addons_hub_catalog_0 on the fixture")
        XCTAssertTrue(moveFocus(.down, until: row0, max: 4), "catalog row 0 never took focus; focused: \(focusDump(app))")
        let toggle = element(app, "addons_hub_catalog_0_toggle")
        remote.press(.right); pause(0.6)
        XCTAssertTrue(toggle.exists && toggle.hasFocus, "the toggle never took focus; focused: \(focusDump(app))")

        func value() -> String { (toggle.value as? String) ?? "" }
        let before = value()
        XCTAssertTrue(before == "enabled" || before == "disabled", "unexpected toggle value \"\(before)\"")
        let flipped = before == "enabled" ? "disabled" : "enabled"
        say("catalog 0 toggle: \(before)")

        remote.press(.select)
        let didFlip = waitUntil(timeout: 5) { value() == flipped }
        let labelWhenFlipped = row0.label
        // Restore first, keyed on the VALUE (a dropped Select followed by a restore press would
        // leave the Chris fixture flipped with nothing to undo it), up to two presses in case the
        // restore press itself is dropped; focus is still on the toggle after Select.
        var restored = value() == before
        for _ in 0..<2 where !restored {
            remote.press(.select)
            restored = waitUntil(timeout: 5) { value() == before }
        }

        XCTAssertTrue(didFlip, "the toggle value never flipped to \(flipped)")
        if flipped == "disabled" {
            XCTAssertTrue(labelWhenFlipped.contains("Disabled on Home"), "row 0 lacks \"Disabled on Home\" when disabled; label: \(labelWhenFlipped)")
        } else {
            XCTAssertFalse(labelWhenFlipped.contains("Disabled on Home"), "row 0 still says \"Disabled on Home\" after enabling; label: \(labelWhenFlipped)")
        }
        XCTAssertTrue(restored, "the toggle did not return to \(before)")
        XCTAssertEqual(row0.label.contains("Disabled on Home"), before == "disabled", "row 0's label does not match the restored state")
        say("catalog 0 toggle restored: \(value())")

        remote.press(.menu); pause(1.5)
        XCTAssertFalse(element(app, "addons_hub_catalogs_root").exists, "the catalogs page is still up after Menu")
    }

    // MARK: - H5 leg 3: Refresh all

    func testRefreshAllTogglesTheSpinnerAndStamps() throws {
        continueAfterFailure = false
        let addonStub = try startHubStubs()
        seedHubAddonA(addonStub)

        let app = launchHub(Self.hubCommon)
        pause(10)
        openTab(app, named: "Add-ons")
        XCTAssertTrue(element(app, "addons_hub_root").waitForExistence(timeout: 10), "addons_hub_root never appeared; focused: \(focusDump(app))")
        XCTAssertTrue(waitUntil(timeout: 20) { self.cardIndex(app, containing: "ZZ Hub A") != nil },
                      "A never showed on the hub (seed refused?); cards: \(cardLabels(app))")
        let refresh = element(app, "addons_hub_action_refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), "addons_hub_action_refresh missing")
        say("refresh card before: stamped=\(refresh.label.contains("Updated")) neverRefreshed=\(refresh.label.contains("Not refreshed yet"))")
        // The stamp is in-memory and only `refreshAll()` writes it, so a fresh launch always
        // starts unstamped; the Select below is then the only way to "Updated".
        XCTAssertTrue(refresh.label.contains("Not refreshed yet"), "the Refresh card is already stamped on a fresh launch; label: \(refresh.label)")
        focusActionCard(app, "addons_hub_action_refresh")
        remote.press(.select)

        let toast = element(app, "addons_hub_toast")
        XCTAssertTrue(waitUntil(timeout: 15) { toast.exists && (toast.label.contains("Refreshing") || toast.label.contains("Refreshed")) },
                      "no Refreshing/Refreshed toast; toast: \(toast.exists ? toast.label : "<none>")")
        XCTAssertTrue(waitUntil(timeout: 20) { refresh.exists && refresh.label.contains("Updated") && !refresh.label.contains("Not refreshed yet") },
                      "the Refresh card never showed Updated; label: \(refresh.exists ? refresh.label : "<gone>")")
        say("refresh card after: stamped")
        pause(2)
    }
}
