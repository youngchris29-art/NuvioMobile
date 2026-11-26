import XCTest

/// Scope identity W2 (spec 8.3, 0.3): a deep-link title cover presented in an entered profile is
/// torn down when the auth gate leaves `.main`. SIM CLONE ONLY, never the FA87 gate: the guest
/// sign-out wipes the fixture guest; tearDown rebuilds it (Continue as Guest, create "Chris").
///
/// Route: `-debug.openDeepLink` (a title link, opened ~1 s after `entered`), `-debug.signOutAfterSec 4`
/// (ContentView signs out once, that many seconds after `entered`). The cover's presence is read
/// from its DEBUG `deeplink_cover` probe. Helpers are this file's own.
final class DeepLinkGateTeardownUITests: XCTestCase {
    private let remote = XCUIRemote.shared
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        guard let app else { return }
        rebuildGuest(app)
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func poll(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.1)
        }
        return condition()
    }

    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 8) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.6)
        }
        return element.exists && element.hasFocus
    }

    private func tile(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    func testSignOutTearsTheDeepLinkCoverDown() {
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["-debug.openDeepLink", "nuviotv://title?id=tt0468569&type=movie&name=The%20Dark%20Knight",
                               "-debug.signOutAfterSec", "4", "-debug.rememberLastProfile", "NO",
                               "-debug.trailerForceNoTrailer", "YES", "-detail_trailer_autoplay", "NO"]
        app.launch()
        let chris = tile(app, "Chris")
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the guest fixture set up?")
        pause(1)
        XCTAssertTrue(moveFocus(.left, until: chris, max: 6) || moveFocus(.right, until: chris, max: 8), "Chris never read focused")
        remote.press(.select)

        let deepLink = app.descendants(matching: .any)["deeplink_cover"].firstMatch
        XCTAssertTrue(deepLink.waitForExistence(timeout: 10), "the title cover never came up")
        shot("deeplink_cover_up")

        let welcome = app.buttons["Continue as Guest"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 15), "Welcome never appeared after the sign-out")
        XCTAssertTrue(poll(3) { !deepLink.exists }, "the title cover is still presented over Welcome")
        shot("welcome_after_signout")
    }

    /// Continue as Guest, then create "Chris" (a fresh guest has no profiles).
    private func rebuildGuest(_ app: XCUIApplication) {
        let guest = app.buttons["Continue as Guest"]
        guard guest.waitForExistence(timeout: 10) else { return }
        if !guest.hasFocus { _ = moveFocus(.down, until: guest, max: 6) || moveFocus(.up, until: guest, max: 6) }
        remote.press(.select)
        let add = tile(app, "Add Profile")
        guard add.waitForExistence(timeout: 20), !tile(app, "Chris").exists else { return }
        _ = moveFocus(.right, until: add, max: 8)
        remote.press(.select)
        let field = app.textFields["Name"]
        guard field.waitForExistence(timeout: 5) else { return }
        if !field.hasFocus { _ = moveFocus(.down, until: field, max: 4) || moveFocus(.up, until: field, max: 4) }
        remote.press(.select)
        pause(1.5)
        app.typeText("Chris")
        pause(0.5)
        remote.press(.menu)
        pause(1)
        let save = app.buttons["profileEdit.save"]
        guard save.waitForExistence(timeout: 5) else { return }
        _ = moveFocus(.down, until: save, max: 10)
        remote.press(.select)
        XCTAssertTrue(tile(app, "Chris").waitForExistence(timeout: 10), "the guest fixture was not rebuilt")
    }
}
