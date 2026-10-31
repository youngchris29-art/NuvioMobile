import XCTest

/// BUG-217 (Wave 3b A3 measurement, 2026-10-21): on the Detail page the FIRST Right press inside the
/// studio/network chip row (the `CompanyChip`s) scrolled the whole page 72 pt (the row's top 108 →
/// 180 on screen). A move that stays in the same row must never scroll the page, so these legs read
/// the first card's screen position before and after each horizontal press and assert it stays put.
///
/// The bug shows only when the row was ANCHORED (`DetailRowAnchor`'s own rest): the Cinematic hero
/// exit, or any Up into the row. Down into a row in Classic is the BUG-99 "free" path (the engine's
/// own reveal, the row rests low) and never nudges. So every leg first asserts the anchor actually
/// ran (`debug_ux6` `anchor=<row> … y=` and the card's rest position) and only then presses Right.
///
/// Oracle: the card's `company_artwork` / `cast_artwork` AX box (`-debug.cardGeometryProbe YES`).
/// The card lifts about its centre, so its centre does not move with the lift, only with the page.
///
/// Route: the DEBUG `-debug.openDeepLink` hook straight into a title that carries studio logos (no
/// Home walk, no Select on a Continue Watching card), the shared verified profile-picker step
/// (`DetailEntryRoute.selectChrisTile`), `-debug.rememberLastProfile NO`, and TMDB on for this launch
/// only through `-debug.tmdbEnabledOverride YES` (in memory, never synced; `-tmdb_enabled_1` is a
/// synced key that a launch argument carries into the account's settings payload).
final class DetailChipRowScrollUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Where the chip row's first chip rests on screen when the row is anchored (`DetailRowAnchor
    /// .screenRest(for: .logos)`), and the tolerance on it.
    private static let chipRestMinY: CGFloat = 180
    private static let restTolerance: CGFloat = 8
    /// A Right press inside a row may not move the page by more than this.
    private static let driftTolerance: CGFloat = 4

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
    /// moves to). Dune (2021), as `DetailSynopsisSheetUITests` uses.
    private let titles = ["nuviotv://title?id=tt0468569&type=movie&name=The%20Dark%20Knight",
                          "nuviotv://title?id=tt0903747&type=series&name=Breaking%20Bad",
                          "nuviotv://title?id=tt1160419&type=movie&name=Dune"]

    private func launchToDetail(_ url: String, layout: String) -> XCUIApplication? {
        let app = XCUIApplication()
        app.launchArguments += ["-debug.openDeepLink", url, "-debug.tmdbEnabledOverride", "YES",
                                "-debug.rememberLastProfile", "NO",
                                "-detail_layout", layout, "-detail_trailer_autoplay", "NO",
                                "-accent_focus_ring", "NO", "-no_zoom_on_focus", "NO",
                                "-debug.cardGeometryProbe", "YES", "-debug.detailFocusProbe", "YES",
                                "-debug.detailScrollProbe", "YES",
                                "-debug.trailerProbe", "YES", "-debug.trailerForceNoTrailer", "YES"]
        app.launch()
        guard DetailEntryRoute.selectChrisTile(self, app, timeout: 90) != nil else {
            XCTFail("profile picker never appeared — is the sim session still signed in?")
            return nil
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

    /// Presses `button` until the probe reads `row` (never more than `max` presses).
    private func press(_ button: XCUIRemote.Button, until row: String, in app: XCUIApplication, max: Int = 6) -> Bool {
        for _ in 0..<max {
            if probe(app).row == row { return true }
            press(button)
        }
        return probe(app).row == row
    }

    /// Distinct boxes carrying `identifier`, left to right (the probe can publish each twice; a
    /// focused card's box is scaled about its centre, so boxes are told apart by centre).
    private func boxes(_ app: XCUIApplication, _ identifier: String) -> [CGRect] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [CGRect] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier == identifier { out.append(node.frame) }
            node.children.forEach(walk)
        }
        walk(root)
        var distinct: [CGRect] = []
        for box in out.sorted(by: { $0.minX < $1.minX }) where !distinct.contains(where: { abs($0.midX - box.midX) < 1 }) {
            distinct.append(box)
        }
        return distinct
    }

    /// Attaches a screenshot and, when `TEST_RUNNER_BUG217_SHOT_DIR` is set for the run, also
    /// writes it there as a PNG (the before/after look of the lower rest).
    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["BUG217_SHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func ux6(_ app: XCUIApplication) -> String {
        let label = app.staticTexts["debug_ux6"]
        return label.exists ? label.label : "-"
    }

    /// The `anchor=` token's note (`<row> top=… y=… <how>` or `<row> top=… screen=… free`).
    private func anchorNote(_ app: XCUIApplication) -> String {
        let text = ux6(app)
        guard let start = text.range(of: "anchor="), let end = text.range(of: " geo=") else { return "-" }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// Opens the first title whose chip row has two or more chips in `layout`; the skipped titles
    /// are logged for the gate record.
    private func openWithChips(layout: String, only title: Int? = nil) -> XCUIApplication? {
        for (index, url) in titles.enumerated() where title == nil || title == index {
            guard let app = launchToDetail(url, layout: layout) else { return nil }
            if boxes(app, "company_artwork").count >= 2 {
                attach("\(url): chips ok", "route\(index)")
                return app
            }
            attach("\(url): fewer than two chips (TMDB off or offline?) — next title", "route\(index)_skipped")
            app.terminate()
        }
        return nil
    }

    /// Presses Right three times on the first card of `identifier`, asserting its centre never
    /// moves. Returns the worst drift.
    @discardableResult
    private func assertRightNeverScrolls(_ app: XCUIApplication, identifier: String, row: String, tag: String) -> CGFloat {
        guard let first = boxes(app, identifier).first else {
            XCTFail("\(tag): no \(identifier) box")
            return 0
        }
        let restY = first.midY
        var worst: CGFloat = 0
        for step in 1...3 {
            press(.right, gap: 1.6)
            guard let card = boxes(app, identifier).first else { continue }
            let p = probe(app)
            let drift = card.midY - restY
            worst = max(worst, abs(drift))
            attach(String(format: "%@ after Right %d: midY=%.1f (rest %.1f) drift=%+.1f row=%@ idx=%@",
                          tag, step, card.midY, restY, drift, p.row, p.idx), "\(tag)_right\(step)")
            XCTAssertEqual(p.row, row, "\(tag): Right \(step) left the \(row) row")
        }
        XCTAssertLessThanOrEqual(worst, Self.driftTolerance,
                                 "\(tag): the page scrolled \(worst) pt on a Right press inside the \(row) row")
        return worst
    }

    // MARK: - Chip row

    /// Cinematic: Down out of the hero anchors the chip row (`hero-exit`), then Right ×3 stays put.
    func testCinematicHeroExitChipRowRightNeverScrolls() throws {
        guard let app = openWithChips(layout: "cinematic") else {
            throw XCTSkip("no title with two or more studio chips opened (TMDB off or offline) — nothing to measure")
        }
        guard walkDown(to: "logos", in: app) else { throw XCTSkip("no focusable chip row") }
        pause(2.5)
        let note = anchorNote(app)
        attach(note, "cinematic_anchor")
        XCTAssertTrue(note.hasPrefix("logos") && note.contains("hero-exit"),
                      "the hero exit must have anchored the chip row (anchor=\(note))")
        let rest = boxes(app, "company_artwork").first?.minY ?? -1
        XCTAssertEqual(rest, Self.chipRestMinY, accuracy: Self.restTolerance, "the anchored chip row's rest")
        snap("cinematic_hero_exit_rest")
        assertRightNeverScrolls(app, identifier: "company_artwork", row: "logos", tag: "cinematic_hero_exit")
    }

    /// Up into the chip row anchors it too (`blend-fallback`), in both layouts.
    func testCinematicUpIntoChipRowRightNeverScrolls() throws { try upIntoChipRow(layout: "cinematic") }
    func testClassicUpIntoChipRowRightNeverScrolls() throws { try upIntoChipRow(layout: "classic") }

    private func upIntoChipRow(layout: String) throws {
        guard let app = openWithChips(layout: layout) else {
            throw XCTSkip("no title with two or more studio chips opened (TMDB off or offline) — nothing to measure")
        }
        guard walkDown(to: "logos", in: app) else { throw XCTSkip("no focusable chip row") }
        // One row below the chips, then Up: the Up path anchors unconditionally.
        press(.down, gap: 1.2)
        let below = probe(app).row
        guard below != "logos", below != "-", below != "?" else { throw XCTSkip("no row below the chips") }
        _ = press(.up, until: "logos", in: app, max: 3)
        pause(2.5)
        XCTAssertEqual(probe(app).row, "logos", "Up from \(below) must land back on the chip row")
        let note = anchorNote(app)
        attach("\(layout) up into chips: \(note)", "\(layout)_up_anchor")
        XCTAssertTrue(note.hasPrefix("logos") && note.contains("y="), "Up must have anchored the chip row (anchor=\(note))")
        let rest = boxes(app, "company_artwork").first?.minY ?? -1
        XCTAssertEqual(rest, Self.chipRestMinY, accuracy: Self.restTolerance, "the anchored chip row's rest (\(layout))")
        snap("\(layout)_up_rest")
        assertRightNeverScrolls(app, identifier: "company_artwork", row: "logos", tag: "\(layout)_up")
    }

    // MARK: - Control: a row with a heading, at its ANCHORED rest

    /// The Cast row reached by Up (so anchored, not left at the engine's minimal reveal): its first
    /// card must not move on Right either.
    func testCastRowAtItsAnchoredRestRightNeverScrolls() throws {
        guard let app = openWithChips(layout: "cinematic") else {
            throw XCTSkip("no title with two or more studio chips opened (TMDB off or offline) — nothing to measure")
        }
        guard walkDown(to: "cast", in: app) else { throw XCTSkip("no cast row") }
        // One row below Cast, then Up back into it.
        press(.down, gap: 1.2)
        guard probe(app).row != "cast" else { throw XCTSkip("no row below Cast") }
        _ = press(.up, until: "cast", in: app, max: 3)
        pause(2.5)
        let note = anchorNote(app)
        attach("cast up anchor: \(note)", "cast_up_anchor")
        XCTAssertTrue(note.hasPrefix("cast") && note.contains("y="), "Up must have anchored the Cast row (anchor=\(note))")
        if let first = boxes(app, "cast_artwork").first {
            attach(String(format: "cast first card at the anchored rest: minY=%.1f midY=%.1f", first.minY, first.midY), "cast_rest")
            XCTAssertEqual(first.minY, Self.chipRestMinY, accuracy: Self.restTolerance, "the Cast avatar rests at the engine's margin")
        }
        assertRightNeverScrolls(app, identifier: "cast_artwork", row: "cast", tag: "cast_up")
    }

    // MARK: - Every anchored row at its rest

    /// Section-title candidates (single-line labels at the title size) by label → top, the oracle
    /// `DetailRowAnchorTests` uses; cards' captions are shorter and posters are not staticTexts.
    private func titleTops(_ app: XCUIApplication) -> [String: CGFloat] {
        guard let root = try? app.snapshot() else { return [:] }
        var out: [String: CGFloat] = [:]
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier == "detail_hero" { return }
            if node.elementType == .staticText {
                let f = node.frame
                if f.height >= 30, f.height <= 64, f.width >= 80, f.width <= 900, !node.label.isEmpty { out[node.label] = f.minY }
            }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// The page's shift between two title readings: the median change of the titles present in both.
    private func pageShift(_ before: [String: CGFloat], _ after: [String: CGFloat]) -> CGFloat? {
        let deltas = before.compactMap { key, top in after[key].map { $0 - top } }.sorted()
        guard !deltas.isEmpty else { return nil }
        return deltas[deltas.count / 2]
    }

    /// Every anchored row, reached by Up (so at its anchored rest), then one Right: the page must
    /// not move. Rows the title lacks are simply not visited; each reading is attached.
    func testEveryAnchoredRowRightNeverScrolls() throws { try everyAnchoredRow(title: 0) }
    /// The series (Breaking Bad): the Episodes and Parental Guide rows the movie lacks.
    func testEveryAnchoredRowOfASeriesRightNeverScrolls() throws { try everyAnchoredRow(title: 1) }

    private func everyAnchoredRow(title: Int) throws {
        guard let app = openWithChips(layout: "cinematic", only: title) else {
            throw XCTSkip("no title with two or more studio chips opened (TMDB off or offline) — nothing to measure")
        }
        var visited: [String] = []
        var readings: [String] = []
        for _ in 0..<14 {
            press(.down, gap: 1.0)
            let row = probe(app).row
            guard !["-", "?", "comments", "logos"].contains(row), !visited.contains(row) else { continue }
            visited.append(row)
            // One row on, then Up back: the Up path anchors unconditionally.
            press(.down, gap: 1.2)
            guard probe(app).row != row else { continue }
            guard press(.up, until: row, in: app, max: 3) else { continue }
            pause(2.5)
            let note = anchorNote(app)
            guard note.hasPrefix(row), note.contains("y=") else {
                attach("\(row): Up did not anchor (anchor=\(note))", "row_\(row)_unanchored")
                continue
            }
            let before = titleTops(app)
            press(.right, gap: 1.8)
            let after = titleTops(app)
            let shift = pageShift(before, after)
            let line = String(format: "%@: anchor=%@ shift on first Right=%@", row, note,
                              shift.map { String(format: "%+.1f", $0) } ?? "n/a")
            readings.append(line)
            attach(line, "row_\(row)")
            if let shift { XCTAssertLessThanOrEqual(abs(shift), Self.driftTolerance, "\(row): the page moved \(shift) pt on Right") }
        }
        attach(readings.joined(separator: "\n"), "rows_summary")
        XCTAssertFalse(readings.isEmpty, "no row could be measured at its anchored rest")
    }
}
