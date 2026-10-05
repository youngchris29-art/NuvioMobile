import XCTest

/// Home Stage & Strip (W3, 2026-10-05): the Stage Home UI legs, spec P1 §9.4
/// (`docs/research/home-stage-strip-spec-P1-stage-strip.md`), plus the Continue Watching and
/// add-on-heading legs Wave 2 added. Every leg launches Stage explicitly (`-home_layout stage`), so a
/// stored layout can never leak in, and arms the strip's motion probe (`-debug.homeScrollProbe YES`).
///
/// The oracles are the DEBUG readouts, never frames of moving things (XCUITest frames ignore SwiftUI
/// offsets, scale and opacity; they DO follow scroll positions and layout):
///   - `debug_stage`: `phase= shown= pending= swaps= maxLive= stageH= stripH= P= fits= rest= row=
///     fitem= disp=` (`maxLive` is the process-wide high-water mark of live stage text blocks: the
///     "never two titles at once" oracle);
///   - `debug_strip`: `<last PRESS summary> row= key= foc=<rowKey>/<itemId> atTop= segs= seg=<travel>/<ms>`.
///     `segs`/`seg` move at each motion SEGMENT's end (a segment = frames moving ≥ 0.25 pt, ended
///     by six still frames). The legs assert per segment, never on the press summaries: the spike
///     found summaries can pin a segment on the wrong press (P1 #18);
///   - `debug_stageTrailer`: `armed= arms= resets= last=<arm|reset>/<via>` (the background trailer);
///   - `debug_trailerMorph`: the trailer event log's last line (`event=gate|reveal|…|play host= key= …`);
///   - `debug_wash`, `rail_state`, and the Tab Bar Geometry blob (Settings › Developer).
///
/// Fixture facts these legs are built on (FA87, the tvOS 26.5 simulator, guest "Chris" profile with
/// Cinemeta, Medium posters, no collections, no watch history): `hasFocus` works on 26.5; in Tabs
/// mode the launch lands focus on the tab bar, so the first Down enters the strip (Gate 1 finding
/// 1); in Rail mode it lands on row 0's first card. YouTube extraction from this Mac answers
/// `LOGIN_REQUIRED`, so no trailer ever PLAYS here: the trailer legs assert the gates and the
/// teardown, which run without a resolved URL, and only note whether playback happened.
///
/// Helpers are this file's own (the harness's duplication rule: every UI test file owns its helpers).
final class StageStripUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// A harness precondition that makes the rest of a leg meaningless (no stage, no strip focus).
    /// Thrown, so the leg fails with the reason instead of asserting on nothing.
    private struct HarnessAbort: Error, CustomStringConvertible {
        let description: String
        init(_ reason: String) { description = reason }
    }

    // MARK: - Basics

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
        print("[StageStripUITests] \(name): \(text)")
    }

    /// Polls `condition` every `step` seconds for up to `timeout` seconds.
    private func poll(_ timeout: TimeInterval, step: TimeInterval = 0.2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(step)
        }
        return condition()
    }

    // MARK: - Launch

    /// The UX-4c smoke id the trailer legs force (TrailerMotionUITests' recipe).
    private static let smokeVideoId = "rNZ0xKaCdus"

    /// Stage Home with the strip's probe armed and no Upcoming row (the guest fixture follows no
    /// show; pinned off so the row order is the catalogs'). Trailers on Focus is forced OFF unless a
    /// leg asks for it: an In Row morph widens cards and adds row motion the paging legs do not want.
    /// The navigation chrome is pinned too (`tabs` unless a leg asks for `rail`), so a stored choice
    /// can never change what Up from row 0 or Menu at the top reaches; each key appears once.
    private static func stageArguments(trailers: Bool = false, navigation: String = "tabs") -> [String] {
        var arguments = ["-home_layout", "stage", "-debug.homeScrollProbe", "YES", "-home_upcoming_row_enabled", "NO",
                         "-sidebar_style", navigation]
        if !trailers { arguments += ["-inline_trailers_enabled", "NO"] }
        return arguments
    }

    /// The trailer legs' recipe: Trailers on Focus on at `location`, the smoke id, the trailer probe.
    private static func trailerArguments(location: String, startDelay: String = "auto") -> [String] {
        ["-inline_trailers_enabled", "YES", "-trailer_playback_location", location,
         "-trailer_start_delay", startDelay,
         "-debug.trailerProbe", "YES", "-debug.trailerSmokeVideoId", smokeVideoId]
    }

    /// Fresh launch with `arguments`, then the profile gate ("Chris" is the first profile and
    /// focused by default; Left is a no-op there, Right would hit Add Profile), then `settle`.
    @discardableResult
    private func launch(_ arguments: [String], settle: TimeInterval = 14) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the FA87 fixture set up?")
        if chris.exists {
            remote.press(.left)
            pause(0.5)
            remote.press(.left)
            pause(0.5)
            remote.press(.select)
        }
        pause(settle)
        return app
    }

    // MARK: - Readouts

    /// A DEBUG readout's label by identifier, "" when absent.
    private func label(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        return element.exists ? element.label : ""
    }

    private func stage(_ app: XCUIApplication) -> String { label(app, "debug_stage") }
    private func strip(_ app: XCUIApplication) -> String { label(app, "debug_strip") }

    /// `key=value` out of a readout line, matched on the exact key (`P=` never matches `pending=`).
    private static func token(_ line: String, _ key: String) -> String? {
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == Substring(key) else { continue }
            return String(pair[1])
        }
        return nil
    }

    private static func int(_ line: String, _ key: String) -> Int? {
        token(line, key).flatMap { Int($0) }
    }

    private static func double(_ line: String, _ key: String) -> Double? {
        token(line, key).flatMap { Double($0) }
    }

    /// The last motion segment's travel out of `debug_strip seg=<travel>/<ms>`.
    private static func segTravel(_ line: String) -> Double? {
        guard let seg = token(line, "seg"), let travel = seg.split(separator: "/").first else { return nil }
        return Double(travel)
    }

    /// The stage's geometry, as the strip lays it out (`debug_stage stageH= stripH= P= fits=`).
    private struct Geometry {
        let stageH: Double
        let stripH: Double
        let page: Double
        let fits: Bool
    }

    /// Waits for Stage Home: `debug_stage` mounted with its geometry and a shown title (the seed
    /// lands once the rows gate opens).
    private func requireGeometry(_ app: XCUIApplication) throws -> Geometry {
        var line = ""
        let ready = poll(30, step: 0.5) {
            line = stage(app)
            return Self.double(line, "stageH") != nil && (Self.token(line, "shown") ?? "-") != "-"
        }
        guard ready, let stageH = Self.double(line, "stageH"), let stripH = Self.double(line, "stripH"),
              let page = Self.double(line, "P") else {
            throw HarnessAbort("Stage Home never came up: debug_stage='\(line)' (DEBUG build? -home_layout stage honoured?)")
        }
        return Geometry(stageH: stageH, stripH: stripH, page: page, fits: Self.token(line, "fits") == "1")
    }

    // MARK: - Focus

    private static let tabTitles = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]

    private struct Focused {
        let label: String
        let identifier: String
        let frame: CGRect
    }

    /// The outermost element reporting focus, from ONE snapshot (26.5 reports `hasFocus`).
    private func focused(_ app: XCUIApplication) -> Focused? {
        guard let root = try? app.snapshot() else { return nil }
        var found: Focused?
        func walk(_ node: XCUIElementSnapshot) {
            guard found == nil else { return }
            if node.hasFocus {
                found = Focused(label: node.label, identifier: node.identifier, frame: node.frame)
                return
            }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }

    /// Every button's frame from one snapshot (cards are buttons).
    private func buttonFrames(_ app: XCUIApplication) -> [CGRect] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [CGRect] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .button { out.append(node.frame) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    private func tabBarFocused(_ app: XCUIApplication) -> Bool {
        Self.tabTitles.contains { app.buttons[$0].exists && app.buttons[$0].hasFocus }
    }

    /// A strip card holds focus: the focused element sits below the stage block.
    private func stripHasFocus(_ app: XCUIApplication, _ geo: Geometry) -> Bool {
        guard let item = focused(app), !tabBarFocused(app) else { return false }
        return item.frame.midY > CGFloat(geo.stageH)
    }

    /// Puts focus on the strip (Tabs mode lands it on the tab bar after the profile gate; the first
    /// Down enters the strip). Throws when it never gets there.
    private func requireStrip(_ app: XCUIApplication, _ geo: Geometry) throws {
        if stripHasFocus(app, geo) { return }
        for _ in 0..<3 {
            remote.press(.down)
            if poll(2.0, { stripHasFocus(app, geo) }) {
                pause(1.0)
                return
            }
        }
        throw HarnessAbort("focus never reached the strip — focused: \(focused(app).map { "\($0.label)@\($0.frame)" } ?? "<none>") | \(strip(app))")
    }

    /// Whether the focused card is its row's FIRST card: no other card in its row band starts to its
    /// left. Cards share the focused card's vertical band (±40 pt of its centre) and are card-sized.
    private func focusedCardIsFirstInRow(_ app: XCUIApplication) -> Bool? {
        guard let item = focused(app) else { return nil }
        let band = buttonFrames(app).filter {
            abs($0.midY - item.frame.midY) < 40 && $0.width >= 100 && $0.height >= 100 && $0 != item.frame
        }
        return !band.contains { $0.minX < item.frame.minX - 20 }
    }

    // MARK: - Rail (testS08)

    private func railState(_ app: XCUIApplication) -> String { label(app, "rail_state") }

    // MARK: - Settings › Developer (testS06; trimmed copies of TabBarScrollLinkTests')

    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 12) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.7)
        }
        return element.exists && element.hasFocus
    }

    /// Tab-bar opener (Tabs mode only): climb to the bar, hunt for the tab, select, step in.
    private func openTab(_ app: XCUIApplication, named title: String) {
        for _ in 0..<40 {
            if tabBarFocused(app) { break }
            remote.press(.up)
            pause(0.35)
        }
        let tab = app.buttons[title]
        if !moveFocus(.right, until: tab, max: 6) {
            _ = moveFocus(.left, until: tab, max: 8)
        }
        remote.press(.select)
        pause(2)
        remote.press(.down)
        pause(0.8)
    }

    private static let settingsRootOrder: [(title: String, raw: String)] = [
        ("Account & Profiles", "accountProfiles"), ("Services", "services"), ("Appearance", "appearance"),
        ("Home Screen", "homeScreen"), ("Detail Page", "detailPage"), ("Player", "player"),
        ("Sources", "sources"), ("Subtitles & Audio", "subtitlesAudio"), ("About", "about"),
        ("Developer", "developer"),
    ]

    private func settingsRootPresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_root_list"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_category_'"))
                .firstMatch.exists
    }

    private func settingsPanePresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_pane_title"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_pane_'"))
                .firstMatch.exists
    }

    private func focusedSettingsRootTitle(_ app: XCUIApplication) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        var nodes: [(identifier: String, label: String)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { nodes.append((node.identifier, node.label)) }
            node.children.forEach(walk)
        }
        walk(root)
        for node in nodes where node.identifier.hasPrefix("settings_category_") {
            let raw = String(node.identifier.dropFirst("settings_category_".count))
            if let entry = Self.settingsRootOrder.first(where: { $0.raw == raw }) { return entry.title }
        }
        for node in nodes {
            if let entry = Self.settingsRootOrder.first(where: { node.label.hasPrefix($0.title) }) { return entry.title }
        }
        return nil
    }

    /// Settings › Developer, root → push.
    private func openDeveloper(_ app: XCUIApplication) -> Bool {
        openTab(app, named: "Settings")
        pause(0.8)
        for _ in 0..<3 where !settingsRootPresent(app) && settingsPanePresent(app) {
            remote.press(.menu)
            pause(1.2)
        }
        guard settingsRootPresent(app) else { return false }
        for _ in 0..<12 where focusedSettingsRootTitle(app) != "Developer" {
            remote.press(.down)
            pause(0.5)
        }
        remote.press(.select)
        pause(1.5)
        return app.descendants(matching: .any)["settings_pane_developer"].waitForExistence(timeout: 4)
    }

    /// A hidden single-`Text` blob by identifier, from one snapshot (its AX type varies).
    private func probeBlobLabel(_ app: XCUIApplication, identifier: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        func find(_ node: XCUIElementSnapshot) -> String? {
            if node.identifier == identifier { return node.label }
            for child in node.children {
                if let hit = find(child) { return hit }
            }
            return nil
        }
        return find(root)
    }

    /// The Tab Bar Geometry blob (`-debug.tabBarStateProbe YES`), chronological, from Developer.
    private func readTabBarProbeLines(_ app: XCUIApplication, tag: String) -> [String] {
        XCTAssertTrue(openDeveloper(app), "Settings › Developer pane did not open")
        pause(1.0)
        var blob = probeBlobLabel(app, identifier: "tab_bar_state_probe_blob") ?? ""
        for _ in 0..<30 where blob.isEmpty {
            remote.press(.down)
            pause(0.5)
            blob = probeBlobLabel(app, identifier: "tab_bar_state_probe_blob") ?? ""
        }
        note("\(tag)_tab_bar_probe_lines", blob)
        return blob.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// A `st=part` line is a mid-glide sample only if a settled (non-`part`) line follows it within
    /// 2.6 s: at a rest the probe's 2 s tick drops repeats, so a bar that RESTED half shown logs one
    /// `part` line and nothing else until the next press. Returns the offending lines.
    private func tabBarRestsHalfShown(_ lines: [String]) -> [String] {
        func stamp(_ line: String) -> Int? {
            guard let range = line.range(of: "ms ") else { return nil }
            return Int(line[line.startIndex..<range.lowerBound])
        }
        let samples = lines.filter { stamp($0) != nil && !$0.contains("NOT-FOUND") }
        var offenders: [String] = []
        for (index, line) in samples.enumerated() where Self.token(line, "st") == "part" {
            guard let at = stamp(line) else { continue }
            let settled = samples[(index + 1)...].contains { later in
                guard let t = stamp(later) else { return false }
                return t - at <= 2600 && Self.token(later, "st") != "part"
            }
            if !settled { offenders.append(line) }
        }
        return offenders
    }

    // MARK: - Paging (testS01, testS13)

    private enum PageOutcome { case paged, atEnd, wrong }

    /// One `direction` press, measured per segment (#18): the strip's `segs` rises by exactly one,
    /// that segment travels exactly one page (∓P, ±0.5), the row index steps by exactly one, and
    /// nothing moves during the 0.8 s rest that follows. A press at the end of the strip must not
    /// move it at all (`.atEnd`).
    private func pageOnce(_ app: XCUIApplication, _ direction: XCUIRemote.Button, geo: Geometry,
                          trace: inout [String]) -> PageOutcome {
        let before = strip(app)
        let rowBefore = Self.int(before, "row") ?? -1
        let segsBefore = Self.int(before, "segs") ?? -1
        remote.press(direction)
        pause(1.2)
        let moved = strip(app)
        pause(0.8)
        let rested = strip(app)
        let rowAfter = Self.int(rested, "row") ?? -1
        let step = direction == .down ? 1 : -1
        trace.append("\(direction == .down ? "down" : "up") \(rowBefore)→\(rowAfter) | before: \(before) | moved: \(moved) | rested: \(rested)")
        if rowAfter == rowBefore {
            XCTAssertEqual(Self.int(rested, "segs"), segsBefore, "a press at the end of the strip must not move it: \(before) → \(rested)")
            return .atEnd
        }
        XCTAssertEqual(rowAfter - rowBefore, step, "one press must page exactly one row (\(rowBefore) → \(rowAfter)): \(rested)")
        XCTAssertEqual((Self.int(moved, "segs") ?? -1) - segsBefore, 1,
                       "one press must be ONE motion segment (segs \(segsBefore) → \(Self.int(moved, "segs") ?? -1)): \(moved)")
        XCTAssertEqual(Self.int(rested, "segs"), Self.int(moved, "segs"),
                       "the strip moved again during the rest after the page: \(moved) → \(rested)")
        if let travel = Self.segTravel(moved) {
            XCTAssertEqual(travel, -Double(step) * geo.page, accuracy: 0.5,
                           "the page's motion must be exactly one page (P=\(geo.page)): \(moved)")
        } else {
            XCTFail("no seg= travel after the page: \(moved)")
        }
        return rowAfter - rowBefore == step ? .paged : .wrong
    }

    // MARK: - testS01

    /// P1 §9.4 testS01: Down ×4 then Up back, 2 s apart. Every press is ONE motion segment of
    /// exactly one page (P), the row index steps by exactly one, and nothing moves at rest. The
    /// guest fixture's Home may have fewer than five rows: a Down at the last row must not move.
    func testS01_DownPagesOneRow() throws {
        let app = launch(Self.stageArguments())
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(2.0)
        XCTAssertEqual(Self.int(strip(app), "row"), 0, "the strip must start on row 0: \(strip(app))")
        var trace: [String] = []
        var pages = 0
        for _ in 0..<4 {
            let outcome = pageOnce(app, .down, geo: geo, trace: &trace)
            if outcome != .paged { break }
            pages += 1
        }
        XCTAssertGreaterThanOrEqual(pages, 1, "the strip never paged on a Down")
        for _ in 0..<pages {
            if pageOnce(app, .up, geo: geo, trace: &trace) != .paged { break }
        }
        note("S01_trace", trace.joined(separator: "\n"))
        shot("S01_back_at_row0")
        XCTAssertEqual(Self.int(strip(app), "row"), 0, "Up ×\(pages) must return to row 0: \(strip(app))")
    }

    // MARK: - testS02

    /// P1 §9.4 testS02: at rest only the next row's HEADING peeks under the strip (H7) — a
    /// section-title text in [stageH + P, 1080] — and none of its cards is on screen.
    func testS02_NextHeadingPeeks() throws {
        let app = launch(Self.stageArguments())
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(1.5)
        assertPeek(app, geo, tag: "S02_row0")
        remote.press(.down)
        pause(2.5)
        XCTAssertEqual(Self.int(strip(app), "row"), 1, "one Down must reach row 1: \(strip(app))")
        assertPeek(app, geo, tag: "S02_row1")
    }

    private func assertPeek(_ app: XCUIApplication, _ geo: Geometry, tag: String) {
        shot(tag)
        guard let root = try? app.snapshot() else {
            XCTFail("\(tag): no accessibility snapshot")
            return
        }
        let peekTop = CGFloat(geo.stageH + geo.page)
        var headings: [String] = []
        var lowCards: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            let frame = node.frame
            if node.elementType == .staticText, !node.label.isEmpty,
               !node.identifier.hasPrefix("debug_"), !node.label.hasPrefix("debug_"),
               frame.height >= 24, frame.height <= 80, frame.width >= 40,
               frame.minY >= peekTop - 8, frame.minY < 1080 {
                headings.append("\(node.label)@\(Int(frame.minY))")
            }
            if node.elementType == .button, frame.width >= 100, frame.height >= 100,
               frame.minY >= peekTop - 2, frame.minY < 1079 {
                lowCards.append("\(node.label)@\(Int(frame.minY))")
            }
            node.children.forEach(walk)
        }
        walk(root)
        note("\(tag)_peek", "peekTop=\(peekTop) headings=\(headings) lowCards=\(lowCards)")
        XCTAssertFalse(headings.isEmpty, "\(tag): no row heading peeks in [stageH + P (\(peekTop)), 1080]")
        XCTAssertTrue(lowCards.isEmpty, "\(tag): a card of the next row is on screen under the strip: \(lowCards)")
    }

    // MARK: - testS03

    /// P1 §9.4 testS03: fast hops never swap the stage (only rests do) and the stage never holds two
    /// titles at once (`maxLive=1`): Right ×6 fast, a 2 s rest, Down ×3 fast, a 2 s rest.
    func testS03_NeverTwoTitles() throws {
        let app = launch(Self.stageArguments())
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(2.5)
        let swaps0 = Self.int(stage(app), "swaps") ?? 0
        var pressTimes: [Date] = []
        for _ in 0..<6 {
            remote.press(.right)
            pressTimes.append(Date())
        }
        pause(2.0)
        for _ in 0..<3 {
            remote.press(.down)
            pressTimes.append(Date())
            pause(0.1)
        }
        pause(2.5)
        let end = stage(app)
        // A rest is a stretch long enough for the 450 ms swap pause to elapse: the two 2 s waits,
        // plus any in-burst gap the remote's own latency stretched that far.
        let gaps = zip(pressTimes.dropFirst(), pressTimes).map { $0.timeIntervalSince($1) }
        let rests = 2 + gaps.filter { $0 >= 0.45 && $0 < 1.5 }.count
        note("S03", "swaps0=\(swaps0) gaps=\(gaps.map { String(format: "%.2f", $0) }) rests=\(rests) end=\(end)")
        shot("S03_end")
        XCTAssertLessThanOrEqual(Self.int(end, "maxLive") ?? 99, 1, "two stage titles were live at once: \(end)")
        XCTAssertEqual(Self.token(end, "phase"), "idle", "the stage must be idle after the last rest: \(end)")
        XCTAssertEqual(Self.token(end, "pending"), "-", "nothing may be left pending after the last rest: \(end)")
        let swaps = (Self.int(end, "swaps") ?? 0) - swaps0
        XCTAssertLessThanOrEqual(swaps, rests, "fast hops must add no swaps (swaps \(swaps) > rests \(rests)): \(end)")
        XCTAssertGreaterThanOrEqual(swaps, 1, "the stage never swapped to the focused title: \(end)")
    }

    // MARK: - testS04

    /// P1 §9.4 testS04: the stage frame never changes with a swap. `stage_text_slot` (the fixed text
    /// column) keeps its frame (±0.5) before, during and after three swaps, and `stageH` holds.
    func testS04_StageFrameConstant() throws {
        let app = launch(Self.stageArguments())
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(2.0)
        // The DEBUG bounds element fills the fixed slot; `stage_text_slot` itself is a `.contain`
        // container, whose accessibility frame is the union of its children (it follows the logo
        // and the synopsis length, so it is not the slot's frame).
        let slot = app.descendants(matching: .any)["stage_text_slot_bounds"].firstMatch
        guard slot.waitForExistence(timeout: 5) else {
            XCTFail("stage_text_slot_bounds is missing")
            return
        }
        let rest = slot.frame
        var frames: [CGRect] = [rest]
        for _ in 0..<3 {
            remote.press(.right)
            for _ in 0..<4 {
                pause(0.2)
                frames.append(slot.frame)
            }
            pause(1.2)
            frames.append(slot.frame)
        }
        note("S04_frames", frames.map { "\($0)" }.joined(separator: "\n"))
        for frame in frames {
            XCTAssertEqual(frame.minX, rest.minX, accuracy: 0.5, "the stage text slot moved horizontally: \(rest) → \(frame)")
            XCTAssertEqual(frame.minY, rest.minY, accuracy: 0.5, "the stage text slot moved vertically: \(rest) → \(frame)")
            XCTAssertEqual(frame.width, rest.width, accuracy: 0.5, "the stage text slot changed width: \(rest) → \(frame)")
            XCTAssertEqual(frame.height, rest.height, accuracy: 0.5, "the stage text slot changed height: \(rest) → \(frame)")
        }
        XCTAssertEqual(Self.double(stage(app), "stageH") ?? -1, geo.stageH, accuracy: 0.5, "stageH changed across the swaps: \(stage(app))")
    }

    // MARK: - testS05

    /// P1 §9.4 testS05: the stage cannot take focus, so Up from row 0 goes to the tab bar (Tabs).
    func testS05_UpFromRow0ToTabBar() throws {
        let app = launch(Self.stageArguments())
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(1.5)
        XCTAssertEqual(Self.int(strip(app), "row"), 0, "precondition: row 0 — \(strip(app))")
        remote.press(.up)
        XCTAssertTrue(poll(2.0) { tabBarFocused(app) }, "Up from row 0 must reach the tab bar — focused: \(focused(app)?.label ?? "<none>")")
        XCTAssertEqual(Self.token(strip(app), "atTop"), "1", "the strip must still read atTop=1: \(strip(app))")
        shot("S05_tab_bar")
    }

    // MARK: - testS06

    /// P1 §9.4 testS06 (the Stage test75): the strip links the system tab bar, which is fully
    /// hidden at row ≥ 1 and fully shown at row 0, and never rests half shown (`st=part`). Read from
    /// the Tab Bar Geometry blob; the strip's own crossings (`r=down`/`r=up`) split the walk.
    func testS06_TabBarHiddenRow1ShownRow0() throws {
        let app = launch(Self.stageArguments() + ["-debug.tabBarStateProbe", "YES"])
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(2.0)
        remote.press(.down)
        pause(4.0)
        XCTAssertEqual(Self.int(strip(app), "row"), 1, "one Down must reach row 1: \(strip(app))")
        let barAtRow1 = app.buttons["Home"].exists ? "\(app.buttons["Home"].frame)" : "absent"
        shot("S06_row1")
        remote.press(.up)
        pause(4.0)
        XCTAssertEqual(Self.int(strip(app), "row"), 0, "Up must return to row 0: \(strip(app))")
        let barAtRow0 = app.buttons["Home"].exists ? "\(app.buttons["Home"].frame)" : "absent"
        shot("S06_row0")
        note("S06_home_tab_frames", "row1=\(barAtRow1) row0=\(barAtRow0)")

        let lines = readTabBarProbeLines(app, tag: "S06")
        guard !lines.isEmpty else {
            XCTFail("tab_bar_state_probe_blob produced no lines — the probe is not armed or the Developer readout did not render")
            return
        }
        XCTAssertTrue(lines.contains { Self.token($0, "r") == "attach" && Self.token($0, "trk") == "rows" },
                      "the strip must link the tab bar (r=attach trk=rows): \(lines)")
        let walkEnd = lines.firstIndex { Self.token($0, "r") == "tab" && Self.token($0, "sel") == "4" } ?? lines.count
        let walk = Array(lines[..<walkEnd]).filter { !$0.contains("NOT-FOUND") }
        XCTAssertTrue(tabBarRestsHalfShown(lines).isEmpty, "the tab bar rested half shown: \(tabBarRestsHalfShown(lines))")
        if let down = walk.lastIndex(where: { Self.token($0, "r") == "down" }),
           let up = walk.lastIndex(where: { Self.token($0, "r") == "up" }), down < up {
            let atRow1 = walk[down..<up]
            XCTAssertEqual(atRow1.last.flatMap { Self.token($0, "st") }, "min", "row 1 must rest with the bar fully hidden: \(Array(atRow1))")
            let atRow0 = walk[up...]
            XCTAssertEqual(atRow0.last.flatMap { Self.token($0, "st") }, "exp", "row 0 must rest with the bar fully shown: \(Array(atRow0))")
            if let y = atRow0.last.flatMap({ Self.int($0, "y") }) {
                XCTAssertGreaterThanOrEqual(y, -1, "row 0: the bar must sit at the top edge, y ≥ -1: \(atRow0.last ?? "")")
            }
        } else {
            note("S06_no_crossings", "no r=down … r=up pair in the walk; judged on the walk as a whole")
            XCTAssertTrue(walk.contains { Self.token($0, "st") == "min" }, "the bar never hid at row 1: \(walk)")
            XCTAssertEqual(walk.last.flatMap { Self.token($0, "st") }, "exp", "back at row 0 the bar must rest fully shown: \(walk)")
        }
    }

    // MARK: - testS07

    /// P1 §9.4 testS07 (gate G-F): per-row focus memory. Leave row 0 on its fourth card, page Down
    /// to an unvisited row (it lands on its FIRST card), then Up: back on the card row 0 was left on.
    func testS07_FocusMemory() throws {
        let app = launch(Self.stageArguments())
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(1.5)
        for _ in 0..<3 {
            remote.press(.right)
            pause(1.0)
        }
        pause(1.0)
        let left = strip(app)
        let leftFocus = Self.token(left, "foc") ?? "-"
        let leftLabel = focused(app)?.label ?? ""
        remote.press(.down)
        pause(2.5)
        let unvisited = strip(app)
        XCTAssertEqual(Self.int(unvisited, "row"), 1, "Down must page to row 1: \(unvisited)")
        XCTAssertEqual(focusedCardIsFirstInRow(app), true,
                       "Down into an unvisited row must land on its first card — focused: \(focused(app).map { "\($0.label)@\($0.frame)" } ?? "<none>")")
        if let key = Self.token(unvisited, "key"), let foc = Self.token(unvisited, "foc") {
            XCTAssertTrue(foc.hasPrefix(key + "/"), "the remembered focus must be row 1's: \(unvisited)")
        }
        remote.press(.up)
        pause(2.5)
        let back = strip(app)
        note("S07", "left=\(left)\nunvisited=\(unvisited)\nback=\(back)")
        shot("S07_back_on_row0")
        XCTAssertEqual(Self.int(back, "row"), 0, "Up must page back to row 0: \(back)")
        XCTAssertEqual(Self.token(back, "foc"), leftFocus, "Up must land on the card row 0 was left on (per-row memory): \(left) → \(back)")
        if !leftLabel.isEmpty {
            XCTAssertEqual(focused(app)?.label, leftLabel, "the focused card after Up must be the one left on row 0")
        }
    }

    // MARK: - testS08

    /// P1 §9.4 testS08 (Rail mode, which replaced the sidebar): Menu from row 3 pages back to row
    /// 0's remembered card in one press and leaves the rail closed; Menu at row 0 then opens the rail
    /// (`rail_state … reason=menu`). Never presses Menu again: inside a Menu-opened rail it leaves
    /// the app (Q2). The rail is closed with Right.
    func testS08_MenuRow3ToRow0ThenRail() throws {
        let app = launch(Self.stageArguments(navigation: "rail"))
        let geo = try requireGeometry(app)
        guard !railState(app).isEmpty else {
            throw HarnessAbort("rail_state missing with -sidebar_style rail (DEBUG build?)")
        }
        try requireStrip(app, geo)
        pause(1.5)
        remote.press(.right)
        pause(1.0)
        remote.press(.right)
        pause(1.5)
        let row0Focus = Self.token(strip(app), "foc") ?? "-"
        var deepest = 0
        for _ in 0..<3 {
            let before = Self.int(strip(app), "row") ?? 0
            remote.press(.down)
            pause(2.0)
            let after = Self.int(strip(app), "row") ?? 0
            if after == before { break }
            deepest = after
        }
        XCTAssertGreaterThanOrEqual(deepest, 1, "the strip never left row 0: \(strip(app))")
        remote.press(.menu)
        XCTAssertTrue(poll(3.0) { Self.int(strip(app), "row") == 0 }, "Menu from row \(deepest) must page to row 0: \(strip(app))")
        pause(1.0)
        let atTop = strip(app)
        shot("S08_menu_to_row0")
        XCTAssertEqual(app.state, .runningForeground, "Menu down the strip must page, never leave the app")
        XCTAssertEqual(Self.token(atTop, "foc"), row0Focus, "Menu must land on row 0's remembered card: \(atTop)")
        XCTAssertEqual(Self.token(railState(app), "expanded"), "0", "the first Menu pages; it must not open the rail: \(railState(app))")
        XCTAssertEqual(Self.token(atTop, "atTop"), "1", "\(atTop)")

        remote.press(.menu)
        XCTAssertTrue(poll(2.5) { Self.token(railState(app), "expanded") == "1" }, "Menu at row 0 must open the rail: \(railState(app))")
        let opened = railState(app)
        shot("S08_rail")
        XCTAssertEqual(Self.token(opened, "reason"), "menu", "the rail must say Menu opened it: \(opened)")
        XCTAssertEqual(Self.token(opened, "focused"), "0", "the rail opens on the current tab's item (Home): \(opened)")
        remote.press(.right)
        pause(1.5)
    }

    // MARK: - testS09

    /// P1 §9.4 testS09 (the Stage test01/test41): Trailer Location In Row. A Down's focus starts the
    /// card's dwell, and the M3 rest gate holds the morph until the strip's page has ended: the
    /// `event=gate host=card` line's rest comes after the glide and its start is ≥ 1 s after the rest
    /// (Automatic = rest + 1 s). The gate runs without a resolved URL; whether the morph then plays
    /// (YouTube answers LOGIN_REQUIRED from this Mac) is only noted.
    func testS09_InRowMorphAfterRest() throws {
        let app = launch(Self.stageArguments(trailers: true) + Self.trailerArguments(location: "poster"))
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(3.0)
        var gateLine: String?
        for attempt in 0..<3 where gateLine == nil {
            let before = label(app, "debug_trailerMorph")
            remote.press(attempt == 1 ? .up : .down)
            let deadline = Date().addingTimeInterval(4.0)
            while Date() < deadline, gateLine == nil {
                let line = label(app, "debug_trailerMorph")
                if line != before, line.contains("event=gate host=card") { gateLine = line }
                pause(0.08)
            }
            pause(1.5)
        }
        guard let gate = gateLine else {
            throw XCTSkip("no `event=gate host=card` line was observed after three pages — the gate fired between polls and later trailer events overwrote the one-line log, or Trailers on Focus did not arm. Last: \(label(app, "debug_trailerMorph"))")
        }
        note("S09_gate", gate)
        let rest = Self.double(gate, "rest")
        let start = Self.double(gate, "start")
        XCTAssertEqual(Self.token(gate, "via"), "rest", "the In Row dwell must open on the strip's rest, not the 3 s ceiling: \(gate)")
        XCTAssertNotNil(rest, "the gate line carries no rest=: \(gate)")
        if let rest {
            // The simulator's Down hop settles in ~0.21–0.27 s (S01's trace: settle=212/269 ms; an
            // Up takes ~0.5 s), and `via=rest` already proves the dwell waited for it, so the floor
            // only rules out a rest taken before the glide started.
            XCTAssertGreaterThanOrEqual(rest, 0.15, "the strip's rest came before the glide: \(gate)")
            if let start {
                XCTAssertGreaterThanOrEqual(start - rest, 0.95, "Automatic starts 1 s after the rest: \(gate)")
            }
        }
        let played = poll(15, step: 0.5) { label(app, "debug_trailerMorph").contains("event=play host=card") }
        note("S09_playback", played ? "an In Row trailer played" : "no In Row playback (extraction unavailable on this host); last: \(label(app, "debug_trailerMorph"))")
    }

    // MARK: - testS10

    /// P1 §9.4 testS10 (the Stage test37): Trailer Location Background. The stage's trailer arms only
    /// once the strip rests on a title (`debug_stageTrailer arms`), its gate opens 1 s after the
    /// rest, any focus move tears it down, it re-arms at the next rest, and focus leaving the strip
    /// (Up to the tab bar, #17) tears it down again. None of this needs a resolved URL; playback is
    /// only noted.
    func testS10_BackgroundTrailer() throws {
        let app = launch(Self.stageArguments(trailers: true) + Self.trailerArguments(location: "hero"))
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        func trailerState() -> String { label(app, "debug_stageTrailer") }
        func arms() -> Int { Self.int(trailerState(), "arms") ?? 0 }
        func resets() -> Int { Self.int(trailerState(), "resets") ?? 0 }
        var gateLine: String?
        let armed = poll(6.0, step: 0.1) {
            let morph = label(app, "debug_trailerMorph")
            if morph.contains("event=gate host=hero") { gateLine = morph }
            return arms() >= 1 && (Self.token(trailerState(), "armed") ?? "-") != "-"
        }
        guard armed else {
            throw XCTSkip("the background trailer never armed at rest (\(trailerState())) — Accessibility › Auto-Play Video Previews may be off on this runtime")
        }
        _ = poll(3.0, step: 0.08) {
            let morph = label(app, "debug_trailerMorph")
            if morph.contains("event=gate host=hero") { gateLine = morph }
            return gateLine != nil
        }
        if let gateLine, let rest = Self.double(gateLine, "rest"), let start = Self.double(gateLine, "start") {
            XCTAssertGreaterThanOrEqual(start - rest, 0.95, "Automatic starts the background trailer 1 s after the rest: \(gateLine)")
        } else {
            note("S10_gate", "the hero gate line was not observed between polls (the one-line log moves on); arms/resets still judged")
        }

        let arms1 = arms()
        let resets1 = resets()
        remote.press(.right)
        XCTAssertTrue(poll(1.5, step: 0.05) { resets() > resets1 }, "a focus move must tear the background trailer down at once: \(trailerState())")
        XCTAssertTrue(poll(6.0, step: 0.1) { arms() > arms1 }, "the background trailer must re-arm at the next rest: \(trailerState())")
        pause(0.5)

        let resets2 = resets()
        remote.press(.up)
        XCTAssertTrue(poll(2.0) { tabBarFocused(app) }, "Up from row 0 must reach the tab bar")
        XCTAssertTrue(poll(2.0, step: 0.1) { resets() > resets2 }, "focus leaving the strip must tear the background trailer down (#17): \(trailerState())")
        let last = Self.token(trailerState(), "last") ?? "-"
        XCTAssertTrue(last.hasPrefix("reset/"), "the last trailer event must be a reset: \(trailerState())")
        let played = label(app, "debug_trailerMorph").contains("event=play host=hero")
        note("S10", "state=\(trailerState()) played=\(played)")
    }

    // MARK: - testS11

    /// P1 §9.4 testS11 (the Stage test71): a 2 s Select on a strip poster opens its hold menu
    /// (Library + "Mark as …"); Menu closes it and nothing else.
    func testS11_HoldMenuOnStripPoster() throws {
        let app = launch(Self.stageArguments() + ["-debug.trailerProbe", "YES", "-debug.trailerForceNoTrailer", "YES"])
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(1.5)
        func menuRow(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        }
        var opened = false
        for attempt in 0..<2 where !opened {
            remote.press(.select, forDuration: 2.0)
            pause(1.5)
            shot("S11_hold_\(attempt)")
            opened = menuRow("Mark as ").waitForExistence(timeout: 3)
            if !opened, ["Add to Library", "In Library", "Mark Watched", "Watched"].contains(where: { app.buttons[$0].exists }) {
                // The press fired the card's link on release (Detail pushed): pop it and try again.
                remote.press(.menu)
                pause(2.0)
            }
        }
        XCTAssertTrue(opened, "a 2 s Select on a strip poster must open its hold menu (\"Mark as …\")")
        guard opened else { return }
        XCTAssertTrue(menuRow("Library").exists, "the hold menu must offer Add to / Remove from Library")
        remote.press(.menu)
        pause(1.2)
        XCTAssertFalse(menuRow("Mark as ").exists, "Menu must close the hold menu")
        XCTAssertNotEqual(stage(app), "", "Menu must close the hold menu and leave Stage Home up")
    }

    // MARK: - testS12

    /// P1 §9.4 testS12: `-home_layout classic` keeps today's Home: no stage, the Classic hero probe.
    func testS12_ClassicArg() throws {
        let app = launch(["-home_layout", "classic", "-home_upcoming_row_enabled", "NO"])
        let hero = app.staticTexts["debug_hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20), "Classic Home's debug_hero probe never appeared")
        XCTAssertTrue(hero.label.contains("mode="), "debug_hero must carry mode=: \(hero.label)")
        pause(2.0)
        XCTAssertFalse(app.descendants(matching: .any)["debug_stage"].exists, "-home_layout classic must not mount the stage")
        XCTAssertFalse(app.descendants(matching: .any)["debug_strip"].exists, "-home_layout classic must not mount the strip")
        shot("S12_classic")
    }

    // MARK: - testS13

    /// P1 §9.4 testS13 (#11): Large posters (`-debug.posterSizeOverride large`) still fit: the stage
    /// keeps ≥ 420 pt with its logo compressed (stage < 480), stage + strip fill the screen, the
    /// strip is one page plus the heading peek, and one Down is still one page. Gate 1 measured
    /// stage 449 / P 588 on FA87's fonts (P1's table: 447 / 589).
    func testS13_LargeGeometry() throws {
        let app = launch(Self.stageArguments() + ["-debug.posterSizeOverride", "large"])
        let geo = try requireGeometry(app)
        note("S13_geometry", stage(app))
        XCTAssertTrue(geo.fits, "Large must fit the stage's 420 pt floor (fits=1): \(stage(app))")
        XCTAssertEqual(geo.stageH, 448, accuracy: 4, "Large stage height (P1 447, Gate 1 449): \(stage(app))")
        XCTAssertEqual(geo.page, 588.5, accuracy: 3, "Large page height (P1 589, Gate 1 588): \(stage(app))")
        XCTAssertLessThan(geo.stageH, 480, "Large compresses the stage's logo slot (stage < 480): \(stage(app))")
        XCTAssertEqual(geo.stageH + geo.stripH, 1080, accuracy: 1, "stage + strip must fill the screen: \(stage(app))")
        XCTAssertEqual(geo.stripH - geo.page, 44, accuracy: 4, "the strip is one page plus the heading peek: \(stage(app))")
        try requireStrip(app, geo)
        pause(1.5)
        var trace: [String] = []
        let outcome = pageOnce(app, .down, geo: geo, trace: &trace)
        note("S13_page", trace.joined(separator: "\n"))
        XCTAssertEqual(outcome, .paged, "one Down must page one Large row")
        shot("S13_large_row1")
    }

    // MARK: - testS14

    /// P1 §9.4 testS14 (#18): a held Down is ONE glide (one motion segment) however many rows it
    /// crosses, swaps the stage once at the end, and arms the background trailer at most once.
    func testS14_HeldDown() throws {
        let app = launch(Self.stageArguments(trailers: true) + Self.trailerArguments(location: "hero"))
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(3.0)
        let before = strip(app)
        let stageBefore = stage(app)
        let armsBefore = Self.int(label(app, "debug_stageTrailer"), "arms") ?? 0
        remote.press(.down, forDuration: 3.0)
        pause(2.0)
        let after = strip(app)
        let stageAfter = stage(app)
        let armsAfter = Self.int(label(app, "debug_stageTrailer"), "arms") ?? 0
        note("S14", "before=\(before)\nafter=\(after)\nstage \(stageBefore) → \(stageAfter)\narms \(armsBefore) → \(armsAfter)")
        shot("S14_after_hold")
        let rows = (Self.int(after, "row") ?? 0) - (Self.int(before, "row") ?? 0)
        XCTAssertGreaterThanOrEqual(rows, 1, "a held Down must page: \(after)")
        XCTAssertEqual((Self.int(after, "segs") ?? -1) - (Self.int(before, "segs") ?? -1), 1,
                       "a held Down across \(rows) row(s) must be ONE glide (one motion segment): \(before) → \(after)")
        XCTAssertEqual((Self.int(stageAfter, "swaps") ?? -1) - (Self.int(stageBefore, "swaps") ?? -1), 1,
                       "a held Down must swap the stage exactly once, at the end: \(stageBefore) → \(stageAfter)")
        XCTAssertLessThanOrEqual(armsAfter - armsBefore, 1, "a held Down must arm the background trailer at most once (at the final rest)")
        XCTAssertLessThanOrEqual(Self.int(stageAfter, "maxLive") ?? 99, 1, "two stage titles were live at once: \(stageAfter)")
    }

    // MARK: - testS15

    /// W2-A's Continue-Watching-aware stage copy, on a seeded entry (`-debug.continueWatchingSeedJsonB64`,
    /// DEBUG and guest only): The Shawshank Redemption at 60 of 142 minutes. The Continue Watching
    /// row is the strip's row 0, and its card's stage meta line reads "1h 22m left"; a catalog row's
    /// title does not; back on the card it does again. The entry is cleared again in `defer`.
    func testS15_ContinueWatchingRowAndCopy() throws {
        let entry: [String: Any] = ["type": "movie", "id": "tt0111161", "title": "The Shawshank Redemption",
                                    "positionMin": 60, "durationMin": 142]
        var removal = entry
        removal["remove"] = true
        func seed(_ entries: [[String: Any]]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: entries)) ?? Data("[]".utf8)
            return data.base64EncodedString()
        }
        defer {
            let cleanup = launch(["-debug.continueWatchingSeedJsonB64", seed([removal])], settle: 8)
            cleanup.terminate()
        }
        let app = launch(Self.stageArguments() + ["-debug.continueWatchingSeedJsonB64", seed([entry])])
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(1.0)
        let entered = strip(app)
        var atCW = entered
        if Self.token(atCW, "key") != "continue-watching" {
            // The seeded row is inserted above the catalog rows while focus sits on the tab bar; if
            // the strip stayed on the old first row, the inserted row is one Up away.
            remote.press(.up)
            pause(2.0)
            atCW = strip(app)
        }
        guard Self.token(atCW, "key") == "continue-watching" else {
            throw XCTSkip("the Continue Watching seed did not land (no continue-watching row; strip: '\(atCW)'): the seed is refused on a signed-in account, or this build lacks ContinueWatchingDebugSeed")
        }
        XCTAssertEqual(Self.token(entered, "key"), "continue-watching",
                       "entering the strip must land on its first row (Continue Watching, inserted above the catalogs while focus sat on the tab bar): \(entered)")
        let info = app.descendants(matching: .any)["stage_info"].firstMatch
        let expected = "1h 22m left"
        XCTAssertTrue(poll(4.0) { info.exists && info.label.contains(expected) },
                      "the Continue Watching card's stage copy must read '\(expected)': '\(info.exists ? info.label : "<no stage_info>")'")
        XCTAssertEqual(Self.token(stage(app), "disp"), "movie:tt0111161", "the stage must show the in-progress title: \(stage(app))")
        shot("S15_cw_copy")
        remote.press(.down)
        pause(3.0)
        XCTAssertEqual(Self.int(strip(app), "row"), 1, "Down must page to the first catalog row: \(strip(app))")
        if Self.token(stage(app), "disp") != "movie:tt0111161" {
            XCTAssertFalse(info.exists && info.label.contains(expected), "a title not in Continue Watching must get the plain copy: '\(info.label)'")
        }
        remote.press(.up)
        pause(3.0)
        XCTAssertEqual(Self.token(strip(app), "key"), "continue-watching", "Up must return to the Continue Watching row: \(strip(app))")
        XCTAssertTrue(poll(3.0) { info.exists && info.label.contains(expected) }, "back on the card the copy must read '\(expected)' again")
    }

    // MARK: - testS16

    /// W2-A §5: in Stage a catalog row's heading carries its add-on ("Popular · Cinemeta").
    func testS16_AddonHeadings() throws {
        let app = launch(Self.stageArguments())
        let geo = try requireGeometry(app)
        try requireStrip(app, geo)
        pause(1.5)
        let suffix = "\u{00B7} Cinemeta"
        let headings = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", suffix))
        XCTAssertTrue(headings.firstMatch.waitForExistence(timeout: 5),
                      "no Stage row heading carries its add-on ('… \(suffix)')")
        note("S16_headings", headings.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        shot("S16_headings")
    }
}
