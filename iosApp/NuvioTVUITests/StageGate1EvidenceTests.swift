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

    /// The label of the element holding focus (tvOS 26.5 reports `hasFocus`; 27.0 never does).
    private func focusedLabel(_ app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return focused.exists ? "\(focused.elementType.rawValue):\(focused.label)" : "<none>"
    }

    /// Diagnostic for per-row focus memory (P1 §3.3, gate G-F): on Home's strip and on the folder
    /// Rows page, leave a row on its THIRD card, page Down, then Up, and record which card takes
    /// focus at each step. Memory working = the third card again after Up.
    func testFocusMemoryWalk() {
        focusMemoryWalk(extra: [])
    }

    private func focusMemoryWalk(extra: [String]) {
        let seed = Data(Self.folderSeedJson.utf8).base64EncodedString()
        defer {
            let app = launch(["-debug.collectionsSeedJsonB64", Data("[]".utf8).base64EncodedString()])
            pause(8)
            app.terminate()
        }
        let app = launch(["-home_layout", "stage", "-debug.collectionsSeedJsonB64", seed] + extra)
        pause(16)
        var log: [String] = []
        func step(_ name: String, _ button: XCUIRemote.Button?, wait: TimeInterval = 2.5) {
            if let button { remote.press(button); pause(wait) }
            log.append("\(name): \(focusedLabel(app))")
        }
        // Home: row 0 is the pinned folder collection (one tile); row 1 is a catalog row.
        step("home-start", nil)
        step("home-enter-strip", .down)
        step("home-row1", .down, wait: 3)
        step("home-row1-right", .right, wait: 1.2)
        step("home-row1-right2", .right, wait: 1.2)
        step("home-row2", .down, wait: 3)
        step("home-back-up", .up, wait: 3)
        shot("memory-home-after-up")
        // Back to the folder tile and open the folder.
        step("home-up-to-row0", .up, wait: 3)
        step("folder-open", .select, wait: 10)
        step("folder-right", .right, wait: 1.2)
        step("folder-right2", .right, wait: 1.2)
        step("folder-down", .down, wait: 3)
        step("folder-back-up", .up, wait: 3)
        shot("memory-folder-after-up")
        step("folder-up-again", .up, wait: 3)
        note("memory-walk", log.joined(separator: "\n"))
    }

    /// Wave 2 (W2-B): the folder opened from a Stage Home is a stage-and-strip page. Seeds the
    /// P2 §4.3 collection (pinned, so its folder tile is the strip's first card), enters the strip,
    /// opens the folder, pages Down once and back Up, then leaves with Menu. Clears the seed.
    func testFolderRowsPage() {
        let seed = Data(Self.folderSeedJson.utf8).base64EncodedString()
        defer {
            let app = launch(["-debug.collectionsSeedJsonB64", Data("[]".utf8).base64EncodedString()])
            pause(8)
            app.terminate()
        }
        let app = launch(["-home_layout", "stage", "-debug.collectionsSeedJsonB64", seed])
        pause(16)
        remote.press(.down)          // tab bar → the strip's first card (the folder tile)
        pause(2)
        shot("folderpage-0-home-folder-focused")
        note("folderpage-0-probes", probes(app))
        remote.press(.select)        // open the folder
        pause(10)
        func folderProbes() -> String {
            ["folder_rows_state", "debug_stage_folder", "debug_wash_folder"].map { id in
                let element = app.descendants(matching: .any)[id].firstMatch
                return element.exists ? element.label : "\(id) <absent>"
            }.joined(separator: "\n")
        }
        shot("folderpage-1-open")
        note("folderpage-1-probes", folderProbes())
        note("folderpage-1-tree", app.debugDescription)
        remote.press(.down)
        pause(3)
        shot("folderpage-2-down")
        note("folderpage-2-probes", folderProbes())
        remote.press(.down)
        pause(3)
        shot("folderpage-3-down2")
        note("folderpage-3-probes", folderProbes())
        remote.press(.up)
        pause(3)
        shot("folderpage-4-up")
        note("folderpage-4-probes", folderProbes())
        remote.press(.menu)
        pause(4)
        shot("folderpage-5-back-home")
        note("folderpage-5-probes", probes(app))
    }
}
