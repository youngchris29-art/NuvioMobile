import XCTest

/// BUG-217 (Wave 3b A3 measurement, 2026-10-21): on the Detail page the FIRST Right press inside the
/// studio/network chip row (the `CompanyChip`s) scrolled the whole page 72 pt (the row's top 108 →
/// 180 on screen). A move that stays in the same row must never scroll the page, so this leg reads
/// the first chip's screen position before and after each horizontal press and asserts it stays put.
///
/// The oracle is the chip's `company_artwork` AX box (`-debug.cardGeometryProbe YES`): the chip lifts
/// about its centre, so its centre does not move with the lift, only with the page. The row's anchor
/// state comes from `debug_ux6` (`anchor=…`, `-debug.detailScrollProbe YES`) and is attached with each
/// reading, so a regression names the pass that scrolled.
///
/// Route: the DEBUG `-debug.openDeepLink` hook straight into a title that carries studio logos
/// (`DetailLabelLiftMeasureUITests`' route, no Home walk, so no Select on a Continue Watching card),
/// TMDB enrichment from the argument domain only (`-tmdb_enabled_1 YES`: read, never written).
final class DetailChipRowScrollUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
    }

    private func attach(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[BUG217] \(name): \(text)")
    }

    /// Titles with TMDB studio logos, the most chips first (the second chip is what the Right press
    /// moves to).
    private let titles = ["nuviotv://title?id=tt0468569&type=movie&name=The%20Dark%20Knight",
                          "nuviotv://title?id=tt0903747&type=series&name=Breaking%20Bad",
                          "nuviotv://title?id=tt15239678&type=movie&name=Dune"]

    private func launchToDetail(_ url: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-debug.openDeepLink", url, "-tmdb_enabled_1", "YES",
                                "-accent_focus_ring", "NO", "-no_zoom_on_focus", "NO",
                                "-debug.cardGeometryProbe", "YES", "-debug.detailFocusProbe", "YES",
                                "-debug.detailScrollProbe", "YES",
                                "-debug.trailerProbe", "YES", "-debug.trailerForceNoTrailer", "YES"]
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            // Default focus is the first profile; Left is a no-op there, Right would hit Add Profile.
            press(.left, times: 2, gap: 0.5)
            remote.press(.select)
        }
        pause(12)
        var waited: TimeInterval = 0
        while !app.staticTexts["Cast"].exists, waited < 14 {
            pause(1)
            waited += 1
        }
        pause(2)
        return app
    }

    private func probe(_ app: XCUIApplication) -> (row: String, idx: String) {
        let label = app.staticTexts["debug_detail_focus"]
        let text = label.waitForExistence(timeout: 4) ? label.label : ""
        var tokens: [String: String] = [:]
        for part in text.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { tokens[String(kv[0])] = String(kv[1]) }
        }
        return (tokens["row"] ?? "?", tokens["idx"] ?? "?")
    }

    private func walkDown(to row: String, in app: XCUIApplication, maxPresses: Int = 16) -> Bool {
        for _ in 0..<maxPresses {
            if probe(app).row == row { return true }
            press(.down)
        }
        return probe(app).row == row
    }

    /// Distinct boxes carrying `company_artwork`, left to right (the probe can publish each twice;
    /// a focused chip's box is scaled about its centre, so boxes are told apart by centre).
    private func chipBoxes(_ app: XCUIApplication, identifier: String = "company_artwork") -> [CGRect] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [CGRect] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier == identifier { out.append(node.frame) }
            node.children.forEach(walk)
        }
        walk(root)
        var boxes: [CGRect] = []
        for box in out.sorted(by: { $0.minX < $1.minX }) where !boxes.contains(where: { abs($0.midX - box.midX) < 1 }) {
            boxes.append(box)
        }
        return boxes
    }

    private func ux6(_ app: XCUIApplication) -> String {
        let label = app.staticTexts["debug_ux6"]
        return label.exists ? label.label : "-"
    }

    private func openChipRow() -> XCUIApplication? {
        for (index, url) in titles.enumerated() {
            let app = launchToDetail(url)
            guard walkDown(to: "logos", in: app) else {
                attach("\(url) has no focusable logos row", "route\(index)")
                continue
            }
            // Settle the Down press's own anchor/engine motion before the first reading.
            pause(2.5)
            let count = chipBoxes(app).count
            attach("\(url): \(count) chip(s)", "route\(index)")
            if count >= 2 { return app }
        }
        return nil
    }

    /// The first Right press inside the chip row, and the ones after it, never move the page.
    func testChipRowHorizontalMoveNeverScrollsThePage() throws {
        guard let app = openChipRow() else {
            throw XCTSkip("no title with two or more studio chips opened (TMDB off or offline) — nothing to measure")
        }
        let start = chipBoxes(app)
        guard let first = start.first else { throw XCTSkip("no chip box") }
        let restY = first.midY
        attach(String(format: "rest chip0 midY=%.1f minY=%.1f idx=%@ | %@", restY, first.minY, probe(app).idx, ux6(app)), "rest")

        var worst: CGFloat = 0
        for step in 1...3 {
            press(.right, gap: 1.6)
            let boxes = chipBoxes(app)
            guard let chip0 = boxes.first else { continue }
            let p = probe(app)
            let drift = chip0.midY - restY
            worst = max(worst, abs(drift))
            attach(String(format: "after Right %d: chip0 midY=%.1f drift=%+.1f row=%@ idx=%@ | %@",
                          step, chip0.midY, drift, p.row, p.idx, ux6(app)), "right\(step)")
            XCTAssertEqual(p.row, "logos", "Right \(step) left the chip row")
        }
        XCTAssertLessThanOrEqual(worst, 4,
                                 "the page scrolled \(worst) pt on a Right press inside the studio chip row")
    }

    /// Control for the chip leg: the same Right press inside the Cast row (a row with a heading) must not scroll either.
    func testCastRowHorizontalMoveDrift() throws {
        let app = launchToDetail(titles[0])
        guard walkDown(to: "cast", in: app) else { throw XCTSkip("no cast row") }
        pause(2.5)
        guard let first = chipBoxes(app, identifier: "cast_artwork").first else { throw XCTSkip("no cast box") }
        let restY = first.midY
        attach(String(format: "cast rest midY=%.1f | %@", restY, ux6(app)), "cast_rest")
        for step in 1...2 {
            press(.right, gap: 1.6)
            guard let c0 = chipBoxes(app, identifier: "cast_artwork").first else { continue }
            attach(String(format: "cast after Right %d: midY=%.1f drift=%+.1f | %@", step, c0.midY, c0.midY - restY, ux6(app)), "cast_right\(step)")
            XCTAssertLessThanOrEqual(abs(c0.midY - restY), 4, "the Cast row scrolled on Right \(step)")
        }
    }
}
