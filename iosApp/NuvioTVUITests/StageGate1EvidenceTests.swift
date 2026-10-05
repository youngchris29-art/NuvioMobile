import XCTest

/// Home Stage & Strip, Gate 1 (2026-10-05): screenshot harness for Christian's design checkpoint
/// before Wave 2. Not a pass/fail leg: each test launches Home in Stage with one geometry
/// configuration, attaches screenshots and the accessibility tree at row 0 and after each Down,
/// and asserts only that Home came up. Attachments are pulled out of the .xcresult into
/// `docs/research/home-stage-strip-sim-evidence/`.
///
/// Poster Size and Hide Titles are synced profile settings and FA87 is Medium, so the geometry
/// legs use W1-A's DEBUG `-debug.posterSizeOverride` / `-debug.posterHideTitles` knobs (P3 #11).
final class StageGate1EvidenceTests: XCTestCase {

    let remote = XCUIRemote.shared

    /// The P2 §4.3 folder fixture: one pinned collection with one folder over four sources (three
    /// Cinemeta catalogs and one missing add-on). Imported through the guest-only
    /// `-debug.collectionsSeedJsonB64` knob and cleared again with `"[]"` afterwards.
    private static let folderSeedJson = """
    [{"id":"zzfolderrows-collection","title":"ZZFolderRows","pinToTop":true,"showAllTab":true,"folders":[{"id":"zzfolderrows-folder","title":"ZZFolderRowsFolder","hideTitle":false,"heroBackdropUrl":"https://images.metahub.space/background/medium/tt0111161/img","coverImageUrl":"https://images.metahub.space/poster/medium/tt0111161/img","sources":[{"provider":"addon","addonId":"com.linvo.cinemeta","type":"movie","catalogId":"top"},{"provider":"addon","addonId":"com.linvo.cinemeta","type":"series","catalogId":"top"},{"provider":"addon","addonId":"com.linvo.cinemeta","type":"movie","catalogId":"imdbRating"},{"provider":"addon","addonId":"zz.missing.addon","type":"movie","catalogId":"zzmissing"}]}]}]
    """

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

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
    }

    /// The stage and strip probe lines (`debug_stage`, `debug_strip`, `debug_wash`), as text.
    private func probes(_ app: XCUIApplication) -> String {
        ["debug_stage", "debug_strip", "debug_wash"].map { id in
            let element = app.descendants(matching: .any)[id].firstMatch
            return element.exists ? element.label : "\(id) <absent>"
        }.joined(separator: "\n")
    }

    @discardableResult
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists {
            // Default focus is the first profile; Left is a no-op there, Right would hit Add Profile.
            remote.press(.left)
            pause(0.5)
            remote.press(.left)
            pause(0.5)
            remote.press(.select)
        }
        return app
    }

    /// One Stage configuration: row 0 after the launch settles, then `downs` single pages.
    private func stage(_ name: String, _ extra: [String], downs: Int = 1) {
        let app = launch(["-home_layout", "stage"] + extra)
        pause(16)
        XCTAssertEqual(app.state, .runningForeground)
        shot("\(name)-row0")
        note("\(name)-row0-probes", probes(app))
        note("\(name)-row0-tree", app.debugDescription)
        for page in 0..<downs {
            remote.press(.down)
            pause(3)
            shot("\(name)-row\(page + 1)")
            note("\(name)-row\(page + 1)-probes", probes(app))
        }
    }

    private func sized(_ size: String, titles: Bool) -> [String] {
        ["-debug.posterSizeOverride", size, "-debug.posterHideTitles", titles ? "NO" : "YES"]
    }

    // MARK: - Poster sizes × titles

    func testSmallTitlesOn() { stage("small-titles", sized("small", titles: true)) }
    func testSmallTitlesOff() { stage("small-notitles", sized("small", titles: false)) }
    func testMediumTitlesOn() { stage("medium-titles", sized("medium", titles: true), downs: 2) }
    func testMediumTitlesOff() { stage("medium-notitles", sized("medium", titles: false)) }
    func testMediumPlusTitlesOn() { stage("mediumplus-titles", sized("mediumPlus", titles: true)) }
    func testMediumPlusTitlesOff() { stage("mediumplus-notitles", sized("mediumPlus", titles: false)) }
    func testLargeTitlesOn() { stage("large-titles", sized("large", titles: true), downs: 2) }
    func testLargeTitlesOff() { stage("large-notitles", sized("large", titles: false)) }

    // MARK: - No Zoom, Classic reference

    func testMediumNoZoom() {
        stage("medium-nozoom", sized("medium", titles: true) + ["-no_zoom_on_focus", "YES"])
    }

    func testLargeNoZoom() {
        stage("large-nozoom", sized("large", titles: true) + ["-no_zoom_on_focus", "YES"])
    }

    /// Classic, for comparison: today's Home, which must be unchanged.
    func testClassicReference() {
        let app = launch(["-home_layout", "classic", "-debug.posterSizeOverride", "medium"])
        pause(16)
        shot("classic-medium-row0")
        note("classic-medium-row0-tree", app.debugDescription)
    }

    // MARK: - A folder focused

    /// Seeds the P2 §4.3 folder collection, walks Down until the stage reports a folder item, and
    /// captures the stage showing the folder. Clears the seed afterwards.
    func testFolderFocused() {
        let seed = Data(Self.folderSeedJson.utf8).base64EncodedString()
        defer {
            // Leave the FA87 guest fixture with no collections again.
            let app = launch(["-debug.collectionsSeedJsonB64", Data("[]".utf8).base64EncodedString()])
            pause(8)
            app.terminate()
        }
        let app = launch(["-home_layout", "stage", "-debug.collectionsSeedJsonB64", seed])
        pause(16)
        shot("folder-row0")
        note("folder-row0-probes", probes(app))
        var found = probes(app).contains("folder")
        var downs = 0
        while !found && downs < 6 {
            remote.press(.down)
            pause(3)
            downs += 1
            found = probes(app).contains("folder")
        }
        shot("folder-focused")
        note("folder-focused-probes", "downs=\(downs) found=\(found)\n" + probes(app))
        note("folder-focused-tree", app.debugDescription)
    }
}
