import XCTest

/// Stream picker A, P5 (`docs/stream-picker-addons-plan-2026-10-25.md` §2 "Wave P5"): one leg over
/// the whole picker, driven on the FA87 fixture (tvOS 26.5, which reports `hasFocus`).
///
///  - `testPickerChipsFocusAndPlay`: Detail -> Play opens the picker; the source panel is up with
///    one row per stream of both stub add-ons, an "All" chip selected plus one chip per add-on
///    ("ZZ Picker A, 3 sources" / "ZZ Picker B, 2 sources"), one section label per add-on, and the
///    FIRST ROW focused (the P4 device-pass fix `865ba971a`: the focus request re-issues until
///    focus is observed). Right on the list steps the chip selection with wrap (All -> A -> B ->
///    All) while focus stays on the list; Up from the first row lands on the selected chip; Right
///    on the chip row moves focus without selecting; Select on a chip selects it and keeps focus;
///    Down returns to the first row; Select on that row starts the player.
///
/// Knobs: two stream add-ons ("ZZ Picker A" with three direct links, "ZZ Picker B" with two) are
/// served by `DiscoveryStubServer` and installed through the DEBUG `-debug.addonManifestUrls` knob
/// on a seed launch (removed again by `-debug.addonManifestRemoveMatching /picker-zz-`, also on a
/// cleanup launch in a teardown block registered before the seed, so the fixture never keeps them;
/// teardown blocks, not `defer`s: `continueAfterFailure = false` unwinds past a `defer`). The add-on stub carries the
/// manifests and stream lists; a second stub only hosts the media URLs (it answers every path with
/// 404, so a chosen stream never plays, the leg only needs it chosen). `-debug.streamAutoPlayModeOverride
/// MANUAL` keeps auto-play from skipping the picker; `-debug.openDeepLink` goes straight to Dune's
/// Detail page; trailers are forced off so no cover buries Detail.
///
/// Skips when the Detail page never appears (network / fixture, not the picker), and, after the
/// panel, row-count, title and both-stub-chips checks have passed, when the fixture has other
/// movie stream add-ons installed (more than 5 rows: the stepping checks assume exactly the two
/// stubs). Every failure after the Play press names the identifiers and labels seen. XCUITest on
/// this runtime reports `hasFocus` on a chip only while it is selected, so focus on an unselected
/// chip is proven by the Select that follows (it can only select the chip that holds focus).
final class StreamPickerUITests: XCTestCase {
    let remote = XCUIRemote.shared

    private var printed: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers (duplicated per file, house rule)

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Prints a `[PickerLeg]` line and keeps it for the attachment at the end of the leg.
    private func say(_ text: String) {
        let line = "[PickerLeg] \(text)"
        print(line)
        printed.append(line)
    }

    @discardableResult
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared")
        if chris.exists {
            // ui-legs: the shared verified step (Select only once "Chris" reads focused).
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        }
        return app
    }

    /// Identifier and label of every element holding focus, for failure messages.
    private func focusDump(_ app: XCUIApplication) -> String {
        let nodes = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        if nodes.isEmpty { return "<no focused element>" }
        return nodes.map { "[id=\($0.identifier) label=\($0.label)]" }.joined(separator: " ")
    }

    private func focusedLabel(_ app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return focused.exists ? focused.label : "<none>"
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "stream_picker_row")
    }

    private func chip(_ app: XCUIApplication, _ suffix: String) -> XCUIElement {
        element(app, "stream_picker_chip_\(suffix)")
    }

    /// Waits until the picker lists exactly `count` rows (`>= count` when `atLeast`).
    private func waitRows(_ app: XCUIApplication, _ count: Int, atLeast: Bool = false, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = rows(app).count
            if atLeast ? now >= count : now == count { return true }
            pause(0.25)
        }
        let now = rows(app).count
        return atLeast ? now >= count : now == count
    }

    /// Polls `condition` every 0.25 s until it holds or `timeout` passes (review r1 P2: a single
    /// read after a press races the StateFlow → collector → SwiftUI → AX snapshot chain).
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.25)
        }
        return condition()
    }

    private func waitFocus(_ target: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists && target.hasFocus { return true }
            pause(0.25)
        }
        return target.exists && target.hasFocus
    }

    /// "ZZ Picker A, 3 sources" -> ("ZZ Picker A", 3). Count is nil for "loading" / "failed".
    private func parseChip(_ label: String) -> (name: String, count: Int?) {
        guard let comma = label.range(of: ", ", options: .backwards) else { return (label, nil) }
        let name = String(label[..<comma.lowerBound])
        let tail = String(label[comma.upperBound...])
        return (name, Int(tail.split(separator: " ").first ?? ""))
    }

    private func chipLabels(_ app: XCUIApplication) -> [String] {
        (0..<8).compactMap { index in
            let node = chip(app, "\(index)")
            return node.exists ? node.label : nil
        }
    }

    // MARK: - Source Layout (GitHub #25)

    /// `TEST_RUNNER_PICKER_LAYOUT=FULL` (seen here as `PICKER_LAYOUT`) runs every picker leg in the
    /// Full Width layout through `-debug.sourceLayout`; absent, the legs pin Two-Pane (review r5: a
    /// profile that saved Full Width must not move the default legs). Row Text is pinned to Nuvio.
    static var pickerLayout: String? {
        let raw = ProcessInfo.processInfo.environment["PICKER_LAYOUT"]?.trimmingCharacters(in: .whitespaces)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    static var layoutArgs: [String] { ["-debug.sourceLayout", pickerLayout ?? "TWO", "-debug.rowText", "NUVIO"] }

    static var isFullWidthRun: Bool { pickerLayout?.uppercased().hasPrefix("FULL") ?? false }

    // MARK: - Fixture add-ons

    private static let stubPrefix = "/picker-zz-"

    private func manifest(id: String, name: String) -> String {
        """
        {"id":"\(id)","version":"1.0.0","name":"\(name)","description":"Stream picker P5 leg","resources":[{"name":"stream","types":["movie"],"idPrefixes":["tt"]}],"types":["movie"],"catalogs":[]}
        """
    }

    private func streams(_ items: [(name: String, title: String, file: String)], prefix: String, media: String) -> String {
        let body = items.map { item in
            "{\"name\":\"\(item.name)\",\"title\":\"\(item.title)\",\"url\":\"\(media)\(prefix)media/\(item.file)\"}"
        }.joined(separator: ",")
        return "{\"streams\":[\(body)]}"
    }

    // MARK: - The leg

    func testPickerChipsFocusAndPlay() throws {
        // Media host: answers 404 JSON for every path (the stub has no routes), so the stream URLs
        // are real, parseable loopback links that never need to play. The add-on stub learns its
        // own origin only after start(), but the bodies need the MEDIA origin, so the media stub
        // starts first.
        // Review r1 P1: `continueAfterFailure = false` stops a failing test by unwinding past Swift
        // `defer`s, so every cleanup is a teardown block (LIFO: the attachment is registered first
        // and runs last, the cleanup launch is registered last and runs first).
        addTeardownBlock { [self] in
            let transcript = printed.joined(separator: "\n")
            let attachment = XCTAttachment(string: transcript)
            attachment.name = "picker-leg-log"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let mediaStub = DiscoveryStubServer()
        try mediaStub.start()
        addTeardownBlock { mediaStub.stop() }
        let media = mediaStub.origin

        let addonStub = DiscoveryStubServer(routes: [
            (prefix: "/picker-zz-a/manifest.json", body: manifest(id: "zz.picker.a", name: "ZZ Picker A")),
            (prefix: "/picker-zz-a/stream/movie/", body: streams([
                ("ZZ A\\n1080p", "Dune 2021 1080p WEB-DL", "a1.mp4"),
                ("ZZ A\\n720p", "Dune 2021 720p WEB", "a2.mp4"),
                ("ZZ A\\n480p", "Dune 2021 480p", "a3.mp4"),
            ], prefix: "/picker-zz-a/", media: media)),
            (prefix: "/picker-zz-b/manifest.json", body: manifest(id: "zz.picker.b", name: "ZZ Picker B")),
            (prefix: "/picker-zz-b/stream/movie/", body: streams([
                ("ZZ B\\n2160p", "Dune 2021 2160p", "b1.mp4"),
                ("ZZ B\\n1080p", "Dune 2021 1080p", "b2.mp4"),
            ], prefix: "/picker-zz-b/", media: media)),
        ])
        try addonStub.start()
        addTeardownBlock { addonStub.stop() }

        let common = [
            "-home_layout", "classic", "-debug.rememberLastProfile", "NO",
            "-detail_trailer_autoplay", "NO", "-debug.trailerForceNoTrailer", "YES",
            "-hero_trailer_autoplay", "NO", "-debug.streamAutoPlayModeOverride", "MANUAL",
            "-debug.sourceListOpensWith", "FULL",
        ] + Self.layoutArgs

        // Cleanup launch (registered BEFORE the seed launch, review r2: `launch` itself can fail
        // after the seed applied): the remove knob alone, so the fixture never keeps the stub add-ons.
        addTeardownBlock { [self] in
            XCUIApplication().terminate()
            let cleanup = launch(common + ["-debug.addonManifestRemoveMatching", Self.stubPrefix])
            pause(10)
            cleanup.terminate()
        }

        // 1. Seed launch: install both add-ons (applied on Home's first add-ons emission).
        let seed = launch(common + [
            "-debug.addonManifestRemoveMatching", Self.stubPrefix,
            "-debug.addonManifestUrls",
            "\(addonStub.origin)/picker-zz-a/manifest.json,\(addonStub.origin)/picker-zz-b/manifest.json",
        ])
        pause(14)
        seed.terminate()

        // 2. Leg launch: Dune's Detail page, then Play.
        let app = launch(common + [
            "-debug.openDeepLink", "nuviotv://title?id=tt1160419&type=movie&name=Dune",
            "-detail_layout", "cinematic", "-home_upcoming_row_enabled", "NO",
        ])

        var detailUp = false
        for _ in 0..<90 {
            if element(app, "detail_hero").exists || element(app, "detail_action_play").exists {
                detailUp = true
                break
            }
            pause(0.5)
        }
        if !detailUp {
            throw XCTSkip("the deep link never produced a Detail page — network or fixture, not the picker")
        }

        var playFocused = false
        for _ in 0..<60 {
            let label = focusedLabel(app)
            if label.hasPrefix("Play") || label.hasPrefix("Resume") {
                playFocused = true
                break
            }
            pause(0.25)
        }
        guard playFocused else {
            XCTFail("focus never reached Play/Resume on Detail; focused: \(focusDump(app))")
            return
        }
        remote.press(.select)

        // a. The panel.
        XCTAssertTrue(element(app, "stream_picker_source_panel").waitForExistence(timeout: 20),
                      "stream_picker_source_panel never appeared; focused: \(focusDump(app))")
        say("panel up")

        // b. Rows: 3 (A) + 2 (B) under "All". The list is a LazyVStack, so XCUITest only sees the
        // rows realized so far (run 1 saw 4 of 5 on open); the count is read after a Down walk to
        // the end of the list, then focus is walked back to the first row.
        XCTAssertTrue(waitRows(app, 4, atLeast: true, timeout: 20),
                      "expected >= 4 stream_picker_row on open, saw \(rows(app).count); chips: \(chipLabels(app)); focused: \(focusDump(app)) (seed refused or stub unreachable?)")
        say("rows realized on open = \(rows(app).count)")
        let expectedTotal = chipLabels(app).compactMap { parseChip($0).count }.reduce(0, +)
        XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                      "the first stream_picker_row never took focus; focused: \(focusDump(app))")
        say("first row focused on open")
        // Review r2: once the list has scrolled, `boundBy: 0` is the first REALIZED row, so the
        // first row is known by its label from here on.
        let firstRowLabel = rows(app).element(boundBy: 0).label
        let firstRowByLabel = rows(app).matching(NSPredicate(format: "label == %@", firstRowLabel)).firstMatch
        // Review r1 P2 / r2: press Down `expectedTotal + 2` times (capped; the lazy list grows only
        // as focus nears its end, so a "stops growing" rule quit too early on run 9) reading the
        // realized count after each press; the Up walk back is bounded by the first row's label,
        // so a dropped press cannot derail the leg.
        var total = rows(app).count
        for _ in 0..<min(expectedTotal + 2, 14) {
            remote.press(.down)
            pause(0.5)
            total = max(total, rows(app).count)
        }
        var ups = 0
        while ups < 12, !(firstRowByLabel.exists && firstRowByLabel.hasFocus) {
            remote.press(.up)
            pause(0.5)
            ups += 1
        }
        XCTAssertTrue(waitFocus(firstRowByLabel, timeout: 5),
                      "focus did not return to the first row after the walk (\(ups) Ups); focused: \(focusDump(app))")
        XCTAssertTrue(rows(app).element(boundBy: 0).hasFocus,
                      "the first realized row is not the first row after the walk; focused: \(focusDump(app))")
        XCTAssertGreaterThanOrEqual(total, 5,
                                    "expected >= 5 stream_picker_row after walking the list, saw \(total); chips: \(chipLabels(app)) (seed refused or stub unreachable?)")
        let exact = total == 5 && expectedTotal == 5
        say("rows under All = \(total), chip counts sum = \(expectedTotal) (exact fixture: \(exact))")

        // c. Info panel title.
        // Scoped to the info panel (review r1 P3): Detail's own logo under the cover carries the
        // same label.
        // GitHub #25: on a Full Width run the title and progress live in the header strip and the
        // info panel is gone.
        let infoPanel = element(app, Self.isFullWidthRun ? "stream_picker_header_strip" : "stream_picker_info_panel")
        XCTAssertTrue(infoPanel.waitForExistence(timeout: 10), "\(infoPanel.identifier) never appeared")
        if Self.isFullWidthRun {
            XCTAssertFalse(element(app, "stream_picker_info_panel").exists, "Full Width still draws the info panel")
        }
        let titleImage = infoPanel.images["Dune"]
        let titleAny = infoPanel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Dune")).firstMatch
        XCTAssertTrue(titleAny.waitForExistence(timeout: 10),
                      "no element labelled \"Dune\" in the info panel; focused: \(focusDump(app))")
        say("title shown as \(titleImage.exists ? "image" : "text")")
        let progress = infoPanel.descendants(matching: .any)["stream_picker_progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "stream_picker_progress not under \(infoPanel.identifier)")
        say("progress line: \(progress.label)")

        // d. Chips.
        let all = chip(app, "all")
        XCTAssertTrue(all.exists, "stream_picker_chip_all missing")
        XCTAssertTrue(all.isSelected, "stream_picker_chip_all not selected on open; label: \(all.label)")
        XCTAssertTrue(chip(app, "0").exists && chip(app, "1").exists,
                      "stream_picker_chip_0 / _1 missing; chips: \(chipLabels(app))")
        let labels = chipLabels(app)
        say("chips = \(labels)")
        XCTAssertTrue(labels.contains("ZZ Picker A, 3 sources") && labels.contains("ZZ Picker B, 2 sources"),
                      "both stub chips must be present whatever else is installed; chips: \(labels)")
        if !exact {
            // Review r1 P2: the stepping checks assume exactly the two stub add-ons; a fixture with
            // more stream add-ons skips (the teardown blocks still run), it never passes silently.
            throw XCTSkip("fixture has extra movie stream add-ons (\(labels), \(total) rows): the stepping checks assume the two stubs alone")
        } else {
            XCTAssertEqual(Set(labels.prefix(2)), Set(["ZZ Picker A, 3 sources", "ZZ Picker B, 2 sources"]),
                           "chip labels: \(labels)")
            XCTAssertFalse(chip(app, "2").exists, "unexpected stream_picker_chip_2: \(chip(app, "2").label)")

            // e. Section labels under "All". The default grouping is Quality (polish D4), so the
            // labels are the tiers of the stub streams (4K, 1080p, 720p, SD), not one per add-on.
            let sections = app.descendants(matching: .any).matching(identifier: "stream_picker_section_label").count
            XCTAssertEqual(sections, 4, "stream_picker_section_label count under All (quality tiers)")
        }

        // f. Initial focus on the first row (P4 device-pass fix 865ba971a) was read in b, before
        // the walk; here only that focus is back on the first row.
        XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                      "the first stream_picker_row does not hold focus; focused: \(focusDump(app))")

        if exact {
            let first = parseChip(chip(app, "0").label)
            let second = parseChip(chip(app, "1").label)
            let firstCount = first.count ?? -1
            let secondCount = second.count ?? -1
            say("chip order = \(first.name), \(second.name)")

            // g. Right from the list steps the selection (All -> chip_0 -> chip_1 -> All).
            remote.press(.right)
            XCTAssertTrue(waitUntil(timeout: 5) { chip(app, "0").isSelected }, "Right did not select chip_0; chips: \(chipLabels(app)); focused: \(focusDump(app))")
            XCTAssertFalse(all.isSelected, "\"All\" still selected after Right")
            XCTAssertTrue(waitRows(app, firstCount, timeout: 10),
                          "rows after first step: \(rows(app).count), expected \(firstCount) for \(first.name)")
            XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                          "the step moved focus off the list; focused: \(focusDump(app))")

            remote.press(.right)
            XCTAssertTrue(waitUntil(timeout: 5) { chip(app, "1").isSelected }, "second Right did not select chip_1; chips: \(chipLabels(app))")
            XCTAssertFalse(chip(app, "0").isSelected, "chip_0 still selected after the second Right")
            XCTAssertTrue(waitRows(app, secondCount, timeout: 10),
                          "rows after second step: \(rows(app).count), expected \(secondCount) for \(second.name)")

            remote.press(.right)
            XCTAssertTrue(waitUntil(timeout: 5) { all.isSelected }, "third Right did not wrap to \"All\"; chips: \(chipLabels(app))")
            // Back under "All" the lazy list realizes 4 of the 5 rows on screen (as on open).
            XCTAssertTrue(waitRows(app, 4, atLeast: true, timeout: 10), "rows after the wrap: \(rows(app).count), expected >= 4")
            say("right-step cycle ok")

            // h. Up from the first row lands on the selected chip ("All").
            XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                          "focus left the list before the Up check; focused: \(focusDump(app))")
            remote.press(.up)
            pause(0.6)
            XCTAssertTrue(waitFocus(all, timeout: 5), "Up from the first row did not land on stream_picker_chip_all; focused: \(focusDump(app))")
            // Right on the chip row moves focus; it is NOT a selection change. XCUITest on the FA87
            // runtime reports `hasFocus` on the "All" chip but NOT on the ForEach chips (runs 4 and
            // 5 of this leg: no focused element for 5 s while the captured frames show chip_0's
            // lifted platter), so focus on a ForEach chip is read softly and the Select that
            // follows is the oracle: it can only select chip_0 if chip_0 holds focus.
            remote.press(.right)
            pause(0.6)
            say("chip_0 reports focus after Right: \(waitFocus(chip(app, "0"), timeout: 2)) (soft read); focused: \(focusDump(app))")
            XCTAssertTrue(all.isSelected, "\"All\" lost its selection on a focus move")
            XCTAssertFalse(chip(app, "0").isSelected, "a focus move along the chip row selected chip_0")
            // Select on the focused chip selects it and keeps focus there (Down then re-enters the list).
            remote.press(.select)
            XCTAssertTrue(waitUntil(timeout: 5) { chip(app, "0").isSelected }, "Select on chip_0 did not select it (focus was not on chip_0 after Right); chips: \(chipLabels(app))")
            XCTAssertFalse(all.isSelected, "\"All\" still selected after Select on chip_0")
            // A selected chip does report focus (run 6): hard assert (review r1 P2).
            XCTAssertTrue(waitFocus(chip(app, "0"), timeout: 5), "focus left chip_0 after Select; focused: \(focusDump(app))")
            XCTAssertTrue(waitRows(app, firstCount, timeout: 10),
                          "rows after selecting chip_0: \(rows(app).count), expected \(firstCount)")
            remote.press(.down)
            XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                          "Down from the chip did not focus the first row; focused: \(focusDump(app))")
            say("chip focus and select ok")

            // Review r1 P2: "Up lands on the SELECTED chip" with a chip that is not next to the
            // refresh button, so a geometric landing cannot pass it: step to chip_1 from the list,
            // Down/Up, and hard-assert chip_1 (selected chips report focus).
            remote.press(.right)
            XCTAssertTrue(waitUntil(timeout: 5) { chip(app, "1").isSelected }, "Right from the list did not step to chip_1; chips: \(chipLabels(app))")
            XCTAssertTrue(waitRows(app, secondCount, timeout: 10),
                          "rows after stepping to chip_1: \(rows(app).count), expected \(secondCount)")
            XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                          "the step to chip_1 moved focus off the list; focused: \(focusDump(app))")
            remote.press(.up)
            XCTAssertTrue(waitFocus(chip(app, "1"), timeout: 5),
                          "Up from the first row did not land on the selected chip_1; focused: \(focusDump(app))")
            // Reviewer's decisive check on the missing hasFocus: Left onto the UNSELECTED chip_0.
            remote.press(.left)
            pause(0.6)
            say("unselected chip_0 reports focus after Left from selected chip_1: \(waitFocus(chip(app, "0"), timeout: 2)) (soft read; false = the gap follows selection, not ForEach)")
            remote.press(.right)
            XCTAssertTrue(waitFocus(chip(app, "1"), timeout: 5), "Right back onto the selected chip_1 lost focus; focused: \(focusDump(app))")
            remote.press(.down)
            XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                          "Down from chip_1 did not focus the first row; focused: \(focusDump(app))")
            say("up onto the selected chip_1 ok")
        }

        // i. No progress for this title on the fixture: no resume pill.
        let pill = element(app, "stream_picker_resume_pill")
        if pill.exists {
            say("resume pill present, label: \(pill.label)")
        } else {
            say("resume pill absent")
        }

        // j. Select on the first row plays.
        let firstRow = rows(app).element(boundBy: 0)
        XCTAssertTrue(waitFocus(firstRow, timeout: 5),
                      "the first row does not hold focus before the play press; focused: \(focusDump(app))")
        remote.press(.select)
        let playerIds = ["player.native", "player.mpv", "player.loadingOverlay"]
        var reached: String?
        for _ in 0..<120 {
            if let id = playerIds.first(where: { element(app, $0).exists }) {
                reached = id
                break
            }
            pause(0.25)
        }
        XCTAssertNotNil(reached, "no player element (\(playerIds)) within 30 s of the row press; focused: \(focusDump(app))")
        say("player reached via \(reached ?? "<none>")")

        // Best effort back out; the cleanup launch resets the fixture anyway.
        for _ in 0..<3 {
            remote.press(.menu)
            pause(1)
            if element(app, "stream_picker_source_panel").exists || element(app, "detail_hero").exists { break }
        }
    }

    // MARK: - Tier headers

    private func sectionLabels(_ app: XCUIApplication) -> Set<String> {
        let nodes = app.descendants(matching: .any).matching(identifier: "stream_picker_section_label").allElementsBoundByIndex
        return Set(nodes.map(\.label))
    }

    /// Polish D4: under All the Quality grouping lists the rows under tier headings ("4K · 1",
    /// "1080p · 2", "720p · 1", "SD · 1" for the stubs), whose counts sum to the row total; Down walks
    /// rows only; a selected chip keeps the tier headings (the add-on grouping's "no labels under a
    /// chip" rule does not apply). The lazy list realizes only the headings near the viewport, so
    /// the headings are collected over a Down walk.
    func testTierHeadersGroupTheAllView() throws {
        addTeardownBlock { [self] in
            let attachment = XCTAttachment(string: printed.joined(separator: "\n"))
            attachment.name = "picker-leg-log"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let mediaStub = DiscoveryStubServer()
        try mediaStub.start()
        addTeardownBlock { mediaStub.stop() }
        let media = mediaStub.origin
        let addonStub = DiscoveryStubServer(routes: [
            (prefix: "/picker-zz-a/manifest.json", body: manifest(id: "zz.picker.a", name: "ZZ Picker A")),
            (prefix: "/picker-zz-a/stream/movie/", body: streams([
                ("ZZ A\\n1080p", "Dune 2021 1080p WEB-DL", "a1.mp4"),
                ("ZZ A\\n720p", "Dune 2021 720p WEB", "a2.mp4"),
                ("ZZ A\\n480p", "Dune 2021 480p", "a3.mp4"),
            ], prefix: "/picker-zz-a/", media: media)),
            (prefix: "/picker-zz-b/manifest.json", body: manifest(id: "zz.picker.b", name: "ZZ Picker B")),
            (prefix: "/picker-zz-b/stream/movie/", body: streams([
                ("ZZ B\\n2160p", "Dune 2021 2160p", "b1.mp4"),
                ("ZZ B\\n1080p", "Dune 2021 1080p", "b2.mp4"),
            ], prefix: "/picker-zz-b/", media: media)),
        ])
        try addonStub.start()
        addTeardownBlock { addonStub.stop() }

        let common = [
            "-home_layout", "classic", "-debug.rememberLastProfile", "NO",
            "-detail_trailer_autoplay", "NO", "-debug.trailerForceNoTrailer", "YES",
            "-hero_trailer_autoplay", "NO", "-debug.streamAutoPlayModeOverride", "MANUAL",
            "-debug.sourceListOpensWith", "FULL",
        ] + Self.layoutArgs
        addTeardownBlock { [self] in
            XCUIApplication().terminate()
            let cleanup = launch(common + ["-debug.addonManifestRemoveMatching", Self.stubPrefix])
            pause(10)
            cleanup.terminate()
        }
        let seed = launch(common + [
            "-debug.addonManifestRemoveMatching", Self.stubPrefix,
            "-debug.addonManifestUrls",
            "\(addonStub.origin)/picker-zz-a/manifest.json,\(addonStub.origin)/picker-zz-b/manifest.json",
        ])
        pause(14)
        seed.terminate()
        let app = launch(common + [
            "-debug.openDeepLink", "nuviotv://title?id=tt1160419&type=movie&name=Dune",
            "-detail_layout", "cinematic", "-home_upcoming_row_enabled", "NO",
        ])

        var detailUp = false
        for _ in 0..<90 {
            if element(app, "detail_hero").exists || element(app, "detail_action_play").exists {
                detailUp = true
                break
            }
            pause(0.5)
        }
        if !detailUp {
            throw XCTSkip("the deep link never produced a Detail page — network or fixture, not the picker")
        }
        var playFocused = false
        for _ in 0..<60 {
            let label = focusedLabel(app)
            if label.hasPrefix("Play") || label.hasPrefix("Resume") {
                playFocused = true
                break
            }
            pause(0.25)
        }
        guard playFocused else {
            XCTFail("focus never reached Play/Resume on Detail; focused: \(focusDump(app))")
            return
        }
        remote.press(.select)
        XCTAssertTrue(element(app, "stream_picker_source_panel").waitForExistence(timeout: 20),
                      "stream_picker_source_panel never appeared; focused: \(focusDump(app))")
        XCTAssertTrue(waitRows(app, 3, atLeast: true, timeout: 20),
                      "expected >= 3 stream_picker_row on open, saw \(rows(app).count); chips: \(chipLabels(app))")
        let expectedTotal = chipLabels(app).compactMap { parseChip($0).count }.reduce(0, +)
        XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                      "the first stream_picker_row never took focus; focused: \(focusDump(app))")

        // Collect the headings across a Down walk to the end of the list; focus must stay on rows.
        var seen = sectionLabels(app)
        var total = rows(app).count
        for _ in 0..<min(expectedTotal + 2, 14) {
            remote.press(.down)
            pause(0.5)
            seen.formUnion(sectionLabels(app))
            total = max(total, rows(app).count)
            XCTAssertFalse(focusDump(app).contains("id=stream_picker_section_label"),
                           "Down focused a section label; focused: \(focusDump(app))")
        }
        say("tier headings under All = \(seen.sorted()), rows = \(total), chip counts sum = \(expectedTotal)")
        guard total == 5, expectedTotal == 5 else {
            throw XCTSkip("fixture has extra movie stream add-ons (\(chipLabels(app)), \(total) rows): the tier counts assume the two stubs alone")
        }
        XCTAssertEqual(seen, ["4K · 1", "1080p · 2", "720p · 1", "SD · 1"], "tier headings under All")
        let counts = seen.compactMap { label in label.split(separator: "·").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        XCTAssertEqual(counts.reduce(0, +), expectedTotal, "heading counts must sum to the chip counts")

        // Back to the first row, then step the selection to "ZZ Picker A" with Right.
        var ups = 0
        while ups < 12, rows(app).element(boundBy: 0).exists, !rows(app).element(boundBy: 0).hasFocus {
            remote.press(.up)
            pause(0.5)
            ups += 1
        }
        var aSelected = false
        for index in 0..<2 where parseChip(chip(app, "\(index)").label).name == "ZZ Picker A" {
            for _ in 0...2 {
                remote.press(.right)
                if waitUntil(timeout: 3, { chip(app, "\(index)").isSelected }) { aSelected = true; break }
            }
        }
        XCTAssertTrue(aSelected, "could not select the ZZ Picker A chip; chips: \(chipLabels(app)); focused: \(focusDump(app))")
        XCTAssertTrue(waitRows(app, 3, timeout: 10), "rows after selecting ZZ Picker A: \(rows(app).count)")
        var selectedSeen = Set<String>()
        _ = waitUntil(timeout: 5) {
            selectedSeen.formUnion(sectionLabels(app))
            return selectedSeen.count >= 3
        }
        XCTAssertEqual(selectedSeen, ["1080p · 1", "720p · 1", "SD · 1"],
                       "tier headings remain with a chip selected; saw \(selectedSeen.sorted())")
    }

    // MARK: - Best pick (Direction C)

    private func bestPick(_ app: XCUIApplication) -> XCUIElement { element(app, "stream_picker_best_pick") }
    private func compactRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "stream_picker_compact_row")
    }

    /// Direction C (`docs/stream-picker-direction-c-spec-2026-10-28.md` §9.3): launched with
    /// `-debug.sourceListOpensWith BEST`, the picker opens on the best-pick card. Add-on A serves four
    /// streams here (a leg-local fixture: three 1080p rows make a "1 more" row) and B two: tiers
    /// 4K 1, 1080p 3, 720p 1, SD 1, six rows. The card holds focus and names the 2160p stream;
    /// "Best 1080p" and "Show all 6" are the pills (the best is already a direct link, so no direct
    /// pill); the 1080p tier folds its third row behind "1 more"; Left/Right on the card steps the
    /// chips; Down from the card goes to the first pill; Select on "more" reveals the row; Show all
    /// swaps to the A list; Menu closes the picker and a reopen lands on the card again; Select on
    /// the card chooses the stream (the stub 404s, so "chosen" is the assertion, as in the play leg).
    func testBestPickLeadsThePanel() throws {
        addTeardownBlock { [self] in
            let attachment = XCTAttachment(string: printed.joined(separator: "\n"))
            attachment.name = "picker-leg-log"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let mediaStub = DiscoveryStubServer()
        try mediaStub.start()
        addTeardownBlock { mediaStub.stop() }
        let media = mediaStub.origin
        let addonStub = DiscoveryStubServer(routes: [
            (prefix: "/picker-zz-a/manifest.json", body: manifest(id: "zz.picker.a", name: "ZZ Picker A")),
            (prefix: "/picker-zz-a/stream/movie/", body: streams([
                ("ZZ A\\n1080p", "Dune 2021 1080p WEB-DL", "a1.mp4"),
                ("ZZ A\\n1080p HEVC", "Dune 2021 1080p WEB-DL HEVC", "a4.mp4"),
                ("ZZ A\\n720p", "Dune 2021 720p WEB", "a2.mp4"),
                ("ZZ A\\n480p", "Dune 2021 480p", "a3.mp4"),
            ], prefix: "/picker-zz-a/", media: media)),
            (prefix: "/picker-zz-b/manifest.json", body: manifest(id: "zz.picker.b", name: "ZZ Picker B")),
            (prefix: "/picker-zz-b/stream/movie/", body: streams([
                ("ZZ B\\n2160p", "Dune 2021 2160p", "b1.mp4"),
                ("ZZ B\\n1080p", "Dune 2021 1080p", "b2.mp4"),
            ], prefix: "/picker-zz-b/", media: media)),
        ])
        try addonStub.start()
        addTeardownBlock { addonStub.stop() }

        let common = [
            "-home_layout", "classic", "-debug.rememberLastProfile", "NO",
            "-detail_trailer_autoplay", "NO", "-debug.trailerForceNoTrailer", "YES",
            "-hero_trailer_autoplay", "NO", "-debug.streamAutoPlayModeOverride", "MANUAL",
            "-debug.sourceListOpensWith", "BEST",
        ] + Self.layoutArgs
        addTeardownBlock { [self] in
            XCUIApplication().terminate()
            let cleanup = launch(common + ["-debug.addonManifestRemoveMatching", Self.stubPrefix])
            pause(10)
            cleanup.terminate()
        }
        let seed = launch(common + [
            "-debug.addonManifestRemoveMatching", Self.stubPrefix,
            "-debug.addonManifestUrls",
            "\(addonStub.origin)/picker-zz-a/manifest.json,\(addonStub.origin)/picker-zz-b/manifest.json",
        ])
        pause(14)
        seed.terminate()
        let app = launch(common + [
            "-debug.openDeepLink", "nuviotv://title?id=tt1160419&type=movie&name=Dune",
            "-detail_layout", "cinematic", "-home_upcoming_row_enabled", "NO",
        ])

        func detailUp() -> Bool {
            for _ in 0..<90 {
                if element(app, "detail_hero").exists || element(app, "detail_action_play").exists { return true }
                pause(0.5)
            }
            return false
        }
        func pressPlay() -> Bool {
            for _ in 0..<60 {
                let label = focusedLabel(app)
                if label.hasPrefix("Play") || label.hasPrefix("Resume") {
                    remote.press(.select)
                    return true
                }
                pause(0.25)
            }
            return false
        }
        if !detailUp() {
            throw XCTSkip("the deep link never produced a Detail page — network or fixture, not the picker")
        }
        guard pressPlay() else {
            XCTFail("focus never reached Play/Resume on Detail; focused: \(focusDump(app))")
            return
        }

        // 1. The panel opens on the card, which holds focus and names the 2160p stream.
        XCTAssertTrue(element(app, "stream_picker_source_panel").waitForExistence(timeout: 20),
                      "stream_picker_source_panel never appeared; focused: \(focusDump(app))")
        let card = bestPick(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20),
                      "stream_picker_best_pick never appeared; chips: \(chipLabels(app)); focused: \(focusDump(app))")
        let chipsSettled = waitUntil(timeout: 30) { chipLabels(app).compactMap { parseChip($0).count }.reduce(0, +) == 6 }
        let chipDump = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "stream_picker_chip"))
            .allElementsBoundByIndex.map { $0.identifier + "=" + $0.label }
        XCTAssertTrue(chipsSettled,
                      "the chips never settled on 6 sources: \(chipLabels(app)); all chips: \(chipDump); card: \(card.label); focused: \(focusDump(app))")
        let labels = chipLabels(app)
        let expectedTotal = labels.compactMap { parseChip($0).count }.reduce(0, +)
        say("chips = \(labels)")
        guard labels.count == 2, expectedTotal == 6,
              labels.contains("ZZ Picker A, 4 sources"), labels.contains("ZZ Picker B, 2 sources") else {
            throw XCTSkip("fixture has extra movie stream add-ons (\(labels)): the tier counts assume the two stubs alone")
        }
        XCTAssertTrue(waitUntil(timeout: 10) { card.label.contains("4K") && card.label.contains("Best of 6") },
                      "the card never named the 2160p stream of 6; label: \(card.label)")
        XCTAssertTrue(waitFocus(card, timeout: 10), "the card does not hold focus on open; focused: \(focusDump(app))")
        say("card focused: \(card.label)")

        // 2. The pills: Best 1080p and Show all 6; no direct pill (the best is a direct link).
        let fhd = element(app, "stream_picker_alt_fhd")
        let showAll = element(app, "stream_picker_show_all")
        XCTAssertTrue(fhd.waitForExistence(timeout: 5), "stream_picker_alt_fhd missing")
        XCTAssertTrue(fhd.label.hasPrefix("Best 1080p"), "alt_fhd label: \(fhd.label)")
        XCTAssertFalse(element(app, "stream_picker_alt_direct").exists, "no direct pill when the best is direct")
        XCTAssertEqual(showAll.label, "Show all 6")

        // 3. Folded tiers: 4K · 1 and 1080p · 3 headings, the 1080p tier with a "1 more" row.
        var headings = sectionLabels(app)
        let more = element(app, "stream_picker_tier_more")
        XCTAssertTrue(waitUntil(timeout: 10) {
            headings.formUnion(sectionLabels(app))
            return headings.contains("4K · 1") && headings.contains("1080p · 3") && more.exists
        }, "tier headings \(headings.sorted()), more exists: \(more.exists)")
        XCTAssertTrue(more.label.hasSuffix("1 more"), "more label: \(more.label)")

        // 4. Right on the card steps the chips (focus stays on the card); Left steps back to All.
        guard let aIndex = (0..<2).first(where: { parseChip(chip(app, "\($0)").label).name == "ZZ Picker A" }) else {
            XCTFail("no ZZ Picker A chip; chips: \(chipLabels(app))")
            return
        }
        var aSelected = false
        for _ in 0..<3 {
            remote.press(.right)
            if waitUntil(timeout: 3, { chip(app, "\(aIndex)").isSelected }) { aSelected = true; break }
        }
        XCTAssertTrue(aSelected, "Right on the card never selected ZZ Picker A; chips: \(chipLabels(app)); focused: \(focusDump(app))")
        XCTAssertTrue(waitUntil(timeout: 10) { card.exists && card.label.contains("1080p") && !card.label.contains("4K") },
                      "with ZZ Picker A selected the card should name a 1080p stream; label: \(card.label)")
        XCTAssertTrue(waitFocus(card, timeout: 5), "a chip step moved focus off the card; focused: \(focusDump(app))")
        var allSelected = false
        for _ in 0..<3 {
            remote.press(.left)
            if waitUntil(timeout: 3, { chip(app, "all").isSelected }) { allSelected = true; break }
        }
        XCTAssertTrue(allSelected, "Left on the card never returned to All; chips: \(chipLabels(app)); focused: \(focusDump(app))")
        XCTAssertTrue(waitUntil(timeout: 10) { card.exists && card.label.contains("4K") },
                      "back on All the card should name the 2160p stream; label: \(card.label)")
        XCTAssertTrue(waitFocus(card, timeout: 5), "focus left the card after stepping back; focused: \(focusDump(app))")
        say("chips stepped from the card: ok")

        // 5. Down from the card lands on the first pill; Down on to the "more" row; Select reveals the row.
        remote.press(.down)
        XCTAssertTrue(waitFocus(element(app, "stream_picker_alt_fhd"), timeout: 5),
                      "Down from the card did not land on the Best 1080p pill; focused: \(focusDump(app))")
        var downs = 0
        while downs < 6, !(more.exists && more.hasFocus) {
            remote.press(.down)
            pause(0.5)
            downs += 1
        }
        XCTAssertTrue(waitFocus(more, timeout: 5), "Down never reached the 1080p \"more\" row (\(downs) presses); focused: \(focusDump(app))")
        remote.press(.select)
        XCTAssertTrue(waitUntil(timeout: 10) { !more.exists }, "the \"more\" row is still there after Select")
        // The lazy list realizes the rows near focus only (the off-screen 4K row may be unrealized),
        // so the count is >= 5 and the three 1080p rows are all there.
        let fhdRows = compactRows(app).matching(NSPredicate(format: "label CONTAINS %@", "1080p"))
        XCTAssertTrue(waitUntil(timeout: 10) { compactRows(app).count >= 5 && fhdRows.count == 3 },
                      "expected >= 5 compact rows with three 1080p after the expand, saw \(compactRows(app).count) / \(fhdRows.count)")
        let focusedAfter = focusedLabel(app)
        XCTAssertTrue(focusedAfter.contains("1080p"), "focus should sit on the revealed 1080p row; focused: \(focusDump(app))")
        say("more expanded, focus on: \(focusedAfter)")

        // 6. Back up to the Best 1080p pill, Right to Show all, Select: the A list.
        var ups = 0
        while ups < 8, !(fhd.exists && fhd.hasFocus) {
            if showAll.exists, showAll.hasFocus { remote.press(.left) } else { remote.press(.up) }
            pause(0.5)
            ups += 1
        }
        XCTAssertTrue(waitFocus(fhd, timeout: 5), "Up never reached the Best 1080p pill (\(ups) presses); focused: \(focusDump(app))")
        remote.press(.right)
        XCTAssertTrue(waitFocus(showAll, timeout: 5), "Right from Best 1080p did not land on Show all; focused: \(focusDump(app))")
        say("before Show all select: focused \(focusDump(app)) showAll.exists=\(showAll.exists) label=\(showAll.label)")
        remote.press(.select)
        pause(2)
        say("after Show all select: focused \(focusDump(app)) rows=\(rows(app).count) compact=\(compactRows(app).count) card=\(bestPick(app).exists) showAll=\(showAll.exists)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "after-show-all"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(waitUntil(timeout: 10) { self.rows(app).count > 0 && self.compactRows(app).count == 0 },
                      "Show all did not swap to the full list: rows=\(rows(app).count) compact=\(compactRows(app).count)")
        XCTAssertTrue(waitRows(app, 4, atLeast: true, timeout: 10),
                      "expected >= 4 stream_picker_row, saw \(rows(app).count); compact=\(compactRows(app).count) headings=\(sectionLabels(app).sorted()) card=\(bestPick(app).exists) pills=\(showAll.exists) more=\(more.exists); focused: \(focusDump(app))\n\(app.debugDescription.prefix(6000))")
        XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 10),
                      "the first row of the full list never took focus; focused: \(focusDump(app))")
        var listHeadings = sectionLabels(app)
        XCTAssertTrue(waitUntil(timeout: 5) {
            listHeadings.formUnion(sectionLabels(app))
            return listHeadings.contains("4K · 1")
        }, "the A list's tier headings: \(listHeadings.sorted())")
        say("show all: \(rows(app).count) rows realized, headings \(listHeadings.sorted())")

        // 7. Menu closes the picker; a reopen lands on the card again.
        remote.press(.menu)
        XCTAssertTrue(waitUntil(timeout: 10) { !element(app, "stream_picker_source_panel").exists },
                      "Menu did not close the picker; focused: \(focusDump(app))")
        XCTAssertTrue(element(app, "detail_hero").waitForExistence(timeout: 10) || element(app, "detail_action_play").exists,
                      "Detail never came back; focused: \(focusDump(app))")
        guard pressPlay() else {
            XCTFail("focus never returned to Play/Resume on Detail; focused: \(focusDump(app))")
            return
        }
        XCTAssertTrue(element(app, "stream_picker_source_panel").waitForExistence(timeout: 20), "the picker did not reopen")
        let reopened = bestPick(app)
        XCTAssertTrue(reopened.waitForExistence(timeout: 20), "the reopened picker has no card; focused: \(focusDump(app))")
        XCTAssertTrue(waitFocus(reopened, timeout: 15), "the reopened picker did not focus the card; focused: \(focusDump(app))")
        say("reopen lands on the card")

        // 8. Select on the card chooses the stream.
        remote.press(.select)
        let playerIds = ["player.native", "player.mpv", "player.loadingOverlay"]
        var reached: String?
        for _ in 0..<120 {
            if let id = playerIds.first(where: { element(app, $0).exists }) { reached = id; break }
            pause(0.25)
        }
        XCTAssertNotNil(reached, "no player element (\(playerIds)) within 30 s of the card press; focused: \(focusDump(app))")
        say("player reached via \(reached ?? "<none>")")

        for _ in 0..<3 {
            remote.press(.menu)
            pause(1)
            if element(app, "stream_picker_source_panel").exists || element(app, "detail_hero").exists { break }
        }
    }

    // MARK: - Full Width with the add-on's own text (GitHub #25)

    /// `-debug.sourceLayout FULL -debug.rowText ADDON`: no info panel, the header strip carries the
    /// title and the progress line, every row reads the add-on's own name first (no Nuvio headline:
    /// the stub names are "ZZ A\n1080p", so a Nuvio row would lead with "1080p"), and Right from a
    /// row still steps the chips with focus kept on the list. Runs whatever `PICKER_LAYOUT` says.
    func testFullWidthAddonTextRows() throws {
        addTeardownBlock { [self] in
            let attachment = XCTAttachment(string: printed.joined(separator: "\n"))
            attachment.name = "picker-leg-log"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let mediaStub = DiscoveryStubServer()
        try mediaStub.start()
        addTeardownBlock { mediaStub.stop() }
        let media = mediaStub.origin
        let addonStub = DiscoveryStubServer(routes: [
            (prefix: "/picker-zz-a/manifest.json", body: manifest(id: "zz.picker.a", name: "ZZ Picker A")),
            (prefix: "/picker-zz-a/stream/movie/", body: streams([
                ("ZZ A\\n1080p", "Dune 2021 1080p WEB-DL", "a1.mp4"),
                ("ZZ A\\n720p", "Dune 2021 720p WEB", "a2.mp4"),
                ("ZZ A\\n480p", "Dune 2021 480p", "a3.mp4"),
            ], prefix: "/picker-zz-a/", media: media)),
            (prefix: "/picker-zz-b/manifest.json", body: manifest(id: "zz.picker.b", name: "ZZ Picker B")),
            (prefix: "/picker-zz-b/stream/movie/", body: streams([
                ("ZZ B\\n2160p", "Dune 2021 2160p", "b1.mp4"),
                ("ZZ B\\n1080p", "Dune 2021 1080p", "b2.mp4"),
            ], prefix: "/picker-zz-b/", media: media)),
        ])
        try addonStub.start()
        addTeardownBlock { addonStub.stop() }

        let common = [
            "-home_layout", "classic", "-debug.rememberLastProfile", "NO",
            "-detail_trailer_autoplay", "NO", "-debug.trailerForceNoTrailer", "YES",
            "-hero_trailer_autoplay", "NO", "-debug.streamAutoPlayModeOverride", "MANUAL",
            "-debug.sourceListOpensWith", "FULL",
            "-debug.sourceLayout", "FULL", "-debug.rowText", "ADDON",
        ]
        addTeardownBlock { [self] in
            XCUIApplication().terminate()
            let cleanup = launch(common + ["-debug.addonManifestRemoveMatching", Self.stubPrefix])
            pause(10)
            cleanup.terminate()
        }
        let seed = launch(common + [
            "-debug.addonManifestRemoveMatching", Self.stubPrefix,
            "-debug.addonManifestUrls",
            "\(addonStub.origin)/picker-zz-a/manifest.json,\(addonStub.origin)/picker-zz-b/manifest.json",
        ])
        pause(14)
        seed.terminate()
        let app = launch(common + [
            "-debug.openDeepLink", "nuviotv://title?id=tt1160419&type=movie&name=Dune",
            "-detail_layout", "cinematic", "-home_upcoming_row_enabled", "NO",
        ])

        var detailUp = false
        for _ in 0..<90 {
            if element(app, "detail_hero").exists || element(app, "detail_action_play").exists { detailUp = true; break }
            pause(0.5)
        }
        if !detailUp {
            throw XCTSkip("the deep link never produced a Detail page — network or fixture, not the picker")
        }
        var pressed = false
        for _ in 0..<60 {
            let label = focusedLabel(app)
            if label.hasPrefix("Play") || label.hasPrefix("Resume") { remote.press(.select); pressed = true; break }
            pause(0.25)
        }
        guard pressed else {
            XCTFail("focus never reached Play/Resume on Detail; focused: \(focusDump(app))")
            return
        }

        // 1. The layout: a header strip with the title and progress, no info panel.
        XCTAssertTrue(element(app, "stream_picker_source_panel").waitForExistence(timeout: 20),
                      "stream_picker_source_panel never appeared; focused: \(focusDump(app))")
        let strip = element(app, "stream_picker_header_strip")
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "stream_picker_header_strip never appeared")
        XCTAssertFalse(element(app, "stream_picker_info_panel").exists, "Full Width still draws the info panel")
        let progress = strip.descendants(matching: .any)["stream_picker_progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "stream_picker_progress not under the header strip")
        XCTAssertTrue(strip.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Dune")).firstMatch
            .waitForExistence(timeout: 10), "no element labelled \"Dune\" in the header strip")
        say("header strip up, progress: \(progress.label)")

        // 2. Rows read the add-on's own text: the name first, never a Nuvio headline.
        // Review r1 (P3): wait for the stub rows themselves, not any four rows (another installed
        // add-on may answer first), and check only the stub rows' text.
        let stubQuery = rows(app).matching(NSPredicate(format: "label BEGINSWITH %@", "ZZ "))
        XCTAssertTrue(waitUntil(timeout: 30) { stubQuery.count >= 4 },
                      "expected >= 4 stub rows leading with the add-on's name, saw \(stubQuery.count); rows: \(rows(app).allElementsBoundByIndex.map(\.label))")
        let stubRows = stubQuery.allElementsBoundByIndex.map(\.label)
        say("stub row labels = \(stubRows)")
        for label in stubRows {
            for headline in ["4K", "1440p", "1080p", "720p", "SD"] {
                XCTAssertFalse(label.hasPrefix(headline + ","), "a row leads with Nuvio's headline: \(label)")
            }
        }
        XCTAssertTrue(stubRows.contains { $0.contains("Dune 2021") },
                      "the description (the stub's legacy title) is read after the name; rows: \(stubRows)")

        // 3. Right from a row still steps the chips, focus kept on the list.
        XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 10),
                      "the first stream_picker_row never took focus; focused: \(focusDump(app))")
        let labels = chipLabels(app)
        guard labels.count == 2 else {
            throw XCTSkip("fixture has extra movie stream add-ons (\(labels)): the chip step assumes the two stubs alone")
        }
        remote.press(.right)
        XCTAssertTrue(waitUntil(timeout: 5) { chip(app, "0").isSelected },
                      "Right did not select chip_0; chips: \(chipLabels(app)); focused: \(focusDump(app))")
        XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5),
                      "the chip step moved focus off the list; focused: \(focusDump(app))")
        remote.press(.left)
        XCTAssertTrue(waitUntil(timeout: 5) { chip(app, "all").isSelected },
                      "Left did not step back to All; chips: \(chipLabels(app))")
        say("chip step from a full-width row: ok")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "full-width-addon-text"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Chip row overflow

    /// P5 device pass: with seven stub add-ons the chip row overflows the panel. Left from the first
    /// row wraps the selection to the LAST chip; the row must scroll that chip inside the panel
    /// (the P4 device-pass fix, `865ba971a`, which the box showed as a no-op: the chip stayed cut
    /// at the panel edge). Prints the chip row's and the panel's frames so a layout cause (a chip
    /// row laid out wider than the panel) can be told from a scroll that never ran.
    func testChipRowScrollsTheSelectedChipIntoView() throws {
        let mediaStub = DiscoveryStubServer()
        try mediaStub.start()
        addTeardownBlock { mediaStub.stop() }
        let media = mediaStub.origin
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf"]
        var routes: [(prefix: String, body: String)] = []
        for (index, name) in names.enumerated() {
            let prefix = "/picker-zz-\(index)/"
            routes.append((prefix: "\(prefix)manifest.json", body: manifest(id: "zz.picker.\(index)", name: "ZZ \(name)")))
            routes.append((prefix: "\(prefix)stream/movie/", body: streams([
                ("ZZ \(name)\\n1080p", "Dune 2021 1080p \(name)", "\(index).mp4"),
            ], prefix: prefix, media: media)))
        }
        let addonStub = DiscoveryStubServer(routes: routes)
        try addonStub.start()
        addTeardownBlock { addonStub.stop() }

        let common = [
            "-home_layout", "classic", "-debug.rememberLastProfile", "NO",
            "-detail_trailer_autoplay", "NO", "-debug.trailerForceNoTrailer", "YES",
            "-hero_trailer_autoplay", "NO", "-debug.streamAutoPlayModeOverride", "MANUAL",
            "-debug.sourceListOpensWith", "FULL",
        ] + Self.layoutArgs
        addTeardownBlock { [self] in
            XCUIApplication().terminate()
            let cleanup = launch(common + ["-debug.addonManifestRemoveMatching", Self.stubPrefix])
            pause(10)
            cleanup.terminate()
        }
        let urls = names.indices.map { "\(addonStub.origin)/picker-zz-\($0)/manifest.json" }.joined(separator: ",")
        let seed = launch(common + ["-debug.addonManifestRemoveMatching", Self.stubPrefix, "-debug.addonManifestUrls", urls])
        pause(16)
        seed.terminate()

        let app = launch(common + [
            "-debug.openDeepLink", "nuviotv://title?id=tt1160419&type=movie&name=Dune",
            "-detail_layout", "cinematic", "-home_upcoming_row_enabled", "NO",
        ])
        var detailUp = false
        for _ in 0..<90 {
            if element(app, "detail_hero").exists || element(app, "detail_action_play").exists { detailUp = true; break }
            pause(0.5)
        }
        if !detailUp { throw XCTSkip("the deep link never produced a Detail page — network or fixture, not the picker") }
        var playFocused = false
        for _ in 0..<60 {
            let label = focusedLabel(app)
            if label.hasPrefix("Play") || label.hasPrefix("Resume") { playFocused = true; break }
            pause(0.25)
        }
        guard playFocused else { XCTFail("focus never reached Play/Resume on Detail; focused: \(focusDump(app))"); return }
        remote.press(.select)

        // `.firstMatch`: the container identifiers resolve to more than one node (run 1 of this leg).
        let panel = app.descendants(matching: .any).matching(identifier: "stream_picker_source_panel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20), "stream_picker_source_panel never appeared")
        XCTAssertTrue(waitUntil(timeout: 20) { chipLabels(app).count >= names.count },
                      "expected \(names.count) chips, saw \(chipLabels(app))")
        XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 10),
                      "the first row never took focus; focused: \(focusDump(app))")
        let lastIndex = chipLabels(app).count - 1
        let last = chip(app, "\(lastIndex)")
        // The chip row's own identifier (a ScrollView with a focus section) is not exposed on this
        // runtime (run 2: no match), so the row is read through its chips: the refresh chip's
        // leading edge and the last chip's trailing edge.
        let refresh = element(app, "stream_picker_chip_refresh")
        func rowFrame() -> String { "refresh.minX=\(refresh.frame.minX) last.maxX=\(last.frame.maxX)" }
        say("overflow: panel=\(panel.frame) \(rowFrame()) all=\(chip(app, "all").frame) last(\(lastIndex))=\(last.frame) before the step")
        // Review: the leg must prove an overflow first, else a row that fits passes with no scroll.
        XCTAssertGreaterThan(last.frame.maxX, panel.frame.maxX,
                             "the chip row does not overflow the panel with \(names.count) stub add-ons: last=\(last.frame) panel=\(panel.frame)")
        let refreshBefore = refresh.frame.minX

        remote.press(.left)
        XCTAssertTrue(waitUntil(timeout: 5) { last.isSelected }, "Left from the first row did not wrap to the last chip; chips: \(chipLabels(app))")
        pause(1.5)
        say("overflow: \(rowFrame()) all=\(chip(app, "all").frame) last(\(lastIndex))=\(last.frame) after the step")
        XCTAssertLessThanOrEqual(last.frame.maxX, panel.frame.maxX - 8,
                                 "the selected last chip is not inside the panel: last=\(last.frame) panel=\(panel.frame) \(rowFrame())")
        XCTAssertLessThan(refresh.frame.minX, refreshBefore - 100,
                          "the row did not scroll: refresh.minX \(refreshBefore) -> \(refresh.frame.minX)")
        XCTAssertTrue(waitFocus(rows(app).element(boundBy: 0), timeout: 5), "the step moved focus off the list; focused: \(focusDump(app))")
    }
}
