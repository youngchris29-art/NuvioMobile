import XCTest

/// Scope identity W2 (spec 8.3, 8.0.6): the identity cover during profile switches, on the guest
/// fixture ("Chris", no PIN). The cover is its own window; its DEBUG `accessibilityValue` carries the
/// laid-out frame ("x,y,w,h") written by a GeometryReader inside it (never `element.frame`).
///
/// `testCoverAppearsAndClearsAcrossTwoSwitches`: create "Barrier B", select Chris (cover, full
/// screen, then Home), Switch Profile → "Barrier B" (cover again, then the rail's profile item names
/// "Barrier B"), then delete "Barrier B" so the picker lists only Chris.
/// `testCoverClearsWhenSelectFailsBeforeBegin`: `-debug.identityFailBeforeBegin 1`.
/// `testTeardownUnconfirmedReturnsToPicker`: `-debug.identitySuppressTeardown 1` plus the mpv smoke
/// player presented while an auto-entered select is held: the drain deadline fails it closed, the
/// cover and the player go and the picker has focus.
///
/// Helpers are this file's own (the harness's duplication rule).
final class ProfileSwitchBarrierUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Basics

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func poll(_ timeout: TimeInterval, step: TimeInterval = 0.05, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(step)
        }
        return condition()
    }

    /// The base arguments of `AddonsSplitUITests` in Rail mode (the rail's profile item names the
    /// active profile).
    private static let baseArguments = ["-home_layout", "classic", "-debug.rememberLastProfile", "NO",
                                        "-debug.trailerForceNoTrailer", "YES", "-detail_trailer_autoplay", "NO",
                                        "-sidebar_style", "rail", "-rail_visibility", "always", "-discover_placement", "off"]

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.baseArguments + extra
        app.launch()
        return app
    }

    private func cover(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["identity.cover"].firstMatch
    }

    private func tile(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 8) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.6)
        }
        return element.exists && element.hasFocus
    }

    /// Focus [name]'s tile on the picker (Left first: the profiles precede Add Profile), then Select.
    private func selectTile(_ app: XCUIApplication, _ name: String) {
        let target = tile(app, name)
        XCTAssertTrue(target.waitForExistence(timeout: 60), "no '\(name)' tile on the picker")
        pause(1)
        guard moveFocus(.left, until: target, max: 6) || moveFocus(.right, until: target, max: 8) else {
            shot("tile_unfocused_\(name)")
            XCTFail("the '\(name)' tile never read focused")
            return
        }
        remote.press(.select)
    }

    /// The cover appears within 1.0 s of the tap and is laid out full screen.
    private func assertCoverShownFullScreen(_ app: XCUIApplication, _ label: String) {
        let element = cover(app)
        XCTAssertTrue(poll(1.0) { element.exists }, "\(label): the identity cover did not appear within 1.0 s")
        var frame = ""
        _ = poll(1.0) {
            frame = (element.value as? String) ?? ""
            return !frame.isEmpty
        }
        shot("\(label)_cover")
        XCTAssertEqual(frame, "0,0,1920,1080", "\(label): the cover's laid-out frame")
    }

    private func railState(_ app: XCUIApplication) -> String {
        let probe = app.descendants(matching: .any)["rail_state"].firstMatch
        return probe.exists ? probe.label : ""
    }

    private func railToken(_ app: XCUIApplication, _ key: String) -> String? {
        for part in railState(app).split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, pair[0] == Substring(key) { return String(pair[1]) }
        }
        return nil
    }

    /// Opens the rail by Left (never Menu) and selects the Profile item (id 5, last in the pill).
    private func openProfileTab(_ app: XCUIApplication) {
        var expanded = railToken(app, "expanded") == "1"
        for attempt in 0..<2 where !expanded {
            for _ in 0..<15 where !expanded {
                remote.press(.left)
                pause(0.4)
                expanded = railToken(app, "expanded") == "1"
            }
            if attempt == 0 && !expanded { remote.press(.down); pause(1) }
        }
        XCTAssertTrue(expanded, "the rail never opened: \(railState(app))")
        for _ in 0..<10 where railToken(app, "focused") != "5" {
            remote.press(.down)
            pause(0.5)
        }
        XCTAssertEqual(railToken(app, "focused"), "5", "rail focus never reached Profile: \(railState(app))")
        remote.press(.select)
        pause(2.5)
    }

    private func switchProfile(_ app: XCUIApplication) {
        openProfileTab(app)
        let button = app.buttons["Switch Profile"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no Switch Profile button")
        if !button.hasFocus { _ = moveFocus(.down, until: button, max: 4) }
        remote.press(.select)
        XCTAssertTrue(tile(app, "Chris").waitForExistence(timeout: 10), "Switch Profile did not reach the picker")
    }

    private func createProfile(_ app: XCUIApplication, named name: String) {
        guard !tile(app, name).exists else { return } // left over from an earlier failed run
        let add = tile(app, "Add Profile")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(moveFocus(.right, until: add, max: 8), "Add Profile never read focused")
        remote.press(.select)
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the editor's Name field")
        if !field.hasFocus { _ = moveFocus(.down, until: field, max: 4) || moveFocus(.up, until: field, max: 4) }
        remote.press(.select)
        pause(1.5)
        app.typeText(name)
        pause(0.5)
        remote.press(.menu) // keyboard closes, the text stays
        pause(1)
        let save = app.buttons["profileEdit.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(moveFocus(.down, until: save, max: 10), "Save never read focused")
        remote.press(.select)
        XCTAssertTrue(tile(app, name).waitForExistence(timeout: 10), "'\(name)' never appeared on the picker")
    }

    private func deleteProfile(_ app: XCUIApplication, named name: String) {
        let target = tile(app, name)
        guard target.waitForExistence(timeout: 5) else { return }
        XCTAssertTrue(moveFocus(.right, until: target, max: 8) || moveFocus(.left, until: target, max: 8))
        remote.press(.select, forDuration: 1.5) // the context menu
        // tvOS context-menu items are not always Buttons in the tree: match any element by label.
        let delete = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Delete Profile")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no Delete Profile in the context menu")
        _ = moveFocus(.down, until: delete, max: 4)
        remote.press(.select)
        XCTAssertTrue(poll(10) { !target.exists }, "'\(name)' is still on the picker")
    }

    // MARK: - Legs

    func testCoverAppearsAndClearsAcrossTwoSwitches() {
        let app = launch(["-debug.identityHoldMs", "1500"])
        XCTAssertTrue(tile(app, "Chris").waitForExistence(timeout: 90), "profile picker never appeared — is the guest fixture set up?")
        createProfile(app, named: "Barrier B")

        selectTile(app, "Chris")
        assertCoverShownFullScreen(app, "chris")
        XCTAssertTrue(poll(5) { !cover(app).exists }, "the cover stayed up past 5 s")
        XCTAssertTrue(poll(5) { !railState(app).isEmpty }, "Home never appeared after the cover")

        switchProfile(app)
        selectTile(app, "Barrier B")
        assertCoverShownFullScreen(app, "barrier_b")
        XCTAssertTrue(poll(5) { !cover(app).exists }, "the cover stayed up past 5 s")
        let profileItem = app.descendants(matching: .any)["rail_item_Profile"].firstMatch
        XCTAssertTrue(poll(5) { profileItem.exists && profileItem.label.contains("Barrier B") },
                      "the rail's profile item does not name Barrier B: '\(profileItem.exists ? profileItem.label : "missing")'")
        shot("barrier_b_entered")

        switchProfile(app)
        deleteProfile(app, named: "Barrier B")
        let profiles = app.buttons.allElementsBoundByIndex.map(\.label).filter { $0 != "Add Profile" && !$0.isEmpty }
        XCTAssertFalse(profiles.contains("Barrier B"))
        XCTAssertTrue(tile(app, "Chris").exists)
    }

    func testCoverClearsWhenSelectFailsBeforeBegin() {
        let app = launch(["-debug.identityFailBeforeBegin", "1"])
        XCTAssertTrue(tile(app, "Chris").waitForExistence(timeout: 90), "profile picker never appeared")
        selectTile(app, "Chris")
        XCTAssertTrue(poll(1.0) { !cover(app).exists }, "the cover is still up 1 s after a select that failed before Begin")
        pause(1)
        XCTAssertTrue(railState(app).isEmpty, "a failed select must not enter the shell")
        let chris = tile(app, "Chris")
        XCTAssertTrue(chris.exists && chris.hasFocus, "the picker's first profile does not have focus")
        shot("fail_before_begin_picker")
    }

    func testTeardownUnconfirmedReturnsToPicker() {
        let env = ProcessInfo.processInfo.environment
        let smokeURL = env["PLAYER_SMOKE_URL"] ?? "http://127.0.0.1:9/identity-teardown.mp4"
        // Auto-enter starts the select at launch; the 4 s hold keeps its transition open while the
        // smoke player presents (2 s) under the cover; no teardownDone is ever sent.
        let app = launch(["-debug.rememberLastProfile", "YES", "-debug.identitySuppressTeardown", "1",
                          "-debug.identityHoldMs", "4000", "-debug.mpvSmokeURL", smokeURL])
        let element = cover(app)
        XCTAssertTrue(element.waitForExistence(timeout: 60), "the auto-enter select never raised the cover")
        let player = app.otherElements["player.mpv"]
        _ = player.waitForExistence(timeout: 6)
        shot("teardown_cover_over_player")
        // Hold 4 s + the 2.0 s drain deadline: the select fails closed (B3a).
        XCTAssertTrue(poll(10) { !element.exists }, "the cover is still up after the drain deadline")
        pause(2.0)
        XCTAssertFalse(player.exists, "the player is still presented after the cover hid")
        XCTAssertTrue(railState(app).isEmpty, "a failed-closed select must not enter the shell")
        let chris = tile(app, "Chris")
        XCTAssertTrue(chris.waitForExistence(timeout: 5) && poll(3) { chris.hasFocus }, "the picker does not have focus")
        shot("teardown_unconfirmed_picker")
    }
}
