import XCTest

/// Fixture setup/restore for the "FA87" signed-in Apple TV simulator's Poster Size
/// (Settings > Appearance > Poster Style > Size), which is a profile-SYNCED setting
/// (`PosterStyle.widthDp`, pushed through `SettingsViewModel.setPosterWidth`). Writing the
/// underlying value directly via `defaults`/`plutil` gets clobbered by the next cloud pull — see
/// the harness notes around `restoreAppearanceBaseline`/`test30AppearanceBaselineRestore` and
/// `test43ThemePickerKeepsCategoryAndTintsSettings` in `NuvioTVUITests.swift` for the same lesson
/// learned about synced Appearance state — so this drives the REAL Settings UI, exactly like a
/// tester would, and lets the app's own repository push the change through sync.
///
/// The new Large-only geometry gates (`test47LargePinnedRowTitleClearsArtwork`,
/// `test48BeltHidesUncorrectableTitle`) `XCTSkip` with an explicit "set Poster Size to Large and
/// rerun" message when `debug_env`'s `w=` reads below ~260pt — this file is that setup step, done
/// through the UI instead of by hand.
///
/// Helper methods here are a trimmed COPY of `NuvioTVUITests`'s (`launchToHome`, `press`, `pause`,
/// `shot`, `moveToSidebarRow`, `openTab`, `focusedButton`, `moveFocus`, `probeValue`) rather than a
/// shared import — same house rule `InlineTrailerTileProbeTests`/`TrailerSoakTests` give for why
/// cross-file UI-test helpers stay duplicated rather than factored out (Swift `private` scopes
/// those to `NuvioTVUITests.swift` alone). The Size-row walk and popover interaction below are
/// NOT copies of anything in that file, though — `SettingsPickerRow` (the Poster Size control)
/// turned out to need its own navigation entirely; see `walkFromSwatchesToSizeRow`'s doc for why
/// `walkToRowByTreeIndex`'s label-based approach (which works fine for every toggle row) and a
/// naive Y-position search both failed against this row kind.
final class FixtureSetupTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers (trimmed copies — see type doc for why these are duplicated, not shared)

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
    }

    /// Simplified cold-launch (this file only ever runs its own tests, so the in-suite/"already
    /// running" reuse branch `NuvioTVUITests.launchToHome` needs is unnecessary here — matches
    /// `InlineTrailerTileProbeTests.launchToHome`'s precedent for a standalone probe file).
    @discardableResult
    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10) // Home catalog fan-out
        return app
    }

    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, until element: XCUIElement, max: Int = 12) -> Bool {
        for _ in 0..<max {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(0.7)
        }
        return element.exists && element.hasFocus
    }

    /// beta.15 §C5: `app.buttons[name]` never reports `hasFocus` for a Settings sidebar row — only
    /// the wrapping `Cell` does. Checks `app.cells[title]` too so arrival is actually detected.
    @discardableResult
    private func moveToSidebarRow(_ app: XCUIApplication, _ direction: XCUIRemote.Button, named title: String, max: Int = 12) -> Bool {
        let button = app.buttons[title]
        let cell = app.cells[title]
        func focused() -> Bool { button.hasFocus || (cell.exists && cell.hasFocus) }
        for _ in 0..<max {
            if button.exists && focused() { return true }
            remote.press(direction)
            pause(0.7)
        }
        return button.exists && focused()
    }

    /// From Home content, walk up to the tab bar, right to the wanted tab, and enter it.
    private func openTab(_ app: XCUIApplication, named title: String) {
        let tabNames = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        for _ in 0..<40 {
            if tabNames.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.35)
        }
        press(.up, times: 1, gap: 0.5)
        let tab = app.buttons[title]
        if !moveFocus(.right, until: tab, max: 6) {
            _ = moveFocus(.left, until: tab, max: 8)
        }
        remote.press(.select)
        pause(2)
        press(.down, times: 1)
    }

    /// Union of Cell/Button/Toggle/Switch element kinds — see `NuvioTVUITests.focusedButton`'s
    /// header comment for why a Settings row's focus can only be reliably read this way.
    private func focusedButton(_ app: XCUIApplication) -> XCUIElement? {
        if let cell = app.cells.allElementsBoundByIndex.first(where: { $0.hasFocus }) {
            return cell
        }
        if let button = app.buttons.allElementsBoundByIndex.first(where: { $0.hasFocus }) {
            return button
        }
        if let toggle = app.toggles.allElementsBoundByIndex.first(where: { $0.hasFocus }) {
            return toggle
        }
        return app.switches.allElementsBoundByIndex.first { $0.hasFocus }
    }

    /// Twin of `NuvioTVUITests.probeValue` — reads `k=v` out of a DEBUG probe label.
    private static func probeValue(_ label: String, key: String) -> Int? {
        for token in label.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return Int(parts[1])
        }
        return nil
    }

    /// `debug_env`'s live `w=` (poster artwork width in pt — Small ~183, Medium ~220, Large ~269;
    /// `PosterStyle`'s own scale of the synced `widthDp`). nil when the probe is missing/unparseable
    /// (DEBUG-only, HomeView.swift) rather than defaulting to a value that could hide a real gap.
    private func readPosterArtworkWidth(_ app: XCUIApplication) -> Int? {
        let env = app.staticTexts["debug_env"]
        guard env.waitForExistence(timeout: 15) else { return nil }
        return Self.probeValue(env.label, key: "w")
    }

    /// Deterministic anchor: the Theme swatches row is the topmost focusable row in the
    /// Appearance pane and reliably reports real `hasFocus` (unlike the Cell-focus-only
    /// Toggle/Picker rows below it) — same technique `restoreAppearanceBaseline` uses in
    /// `NuvioTVUITests.swift`.
    private func climbToThemeSwatches(_ app: XCUIApplication) {
        let swatches = ["Crimson", "Ocean", "Violet", "Emerald", "Amber", "Rose", "White"]
        for _ in 0..<30 {
            if swatches.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.4)
        }
    }

    /// Walks from the Theme swatches to the "Size" row (Poster Style section,
    /// `PosterStyleControls` in AppearanceSettingsPane.swift) with a FIXED down-count, not a
    /// label or Y-position search. Two earlier approaches were tried and failed (2026-09-04,
    /// verified via `app.debugDescription` dumps, not guessed):
    ///  1. A label-prefix match (`NuvioTVUITests.walkToRowByTreeIndex`'s own technique, which
    ///     works for every TOGGLE row on this pane) never finds Size/Corners at all —
    ///     `SettingsPickerRow` composes NO accessible label whatsoever on its wrapping Cell/Button;
    ///     "Size" and "Medium" are two separate plain `StaticText` leaves inside an otherwise
    ///     unlabeled Button. The walk silently overshot into Stream Badges and failed with
    ///     "row 'Size…' never materialised".
    ///  2. A pure Y-position search (bracket the focused row's frame against
    ///     `app.staticTexts["Size"].frame`, with no fixed starting point) overshot by TWO rows and
    ///     landed on "Hide Titles" instead — a lazy List's on-screen Y for a row you haven't
    ///     reached yet is a MOVING target as focus scrolls toward it, so a delta computed once (or
    ///     even re-computed but compared to a resting-focus assumption that doesn't hold) drifts.
    ///     Landing on the wrong row here isn't just a wasted step, either: pressing Select on
    ///     "Hide Titles" flips that TOGGLE, not a picker — this exact bug flipped it ON on the
    ///     real synced profile during development and had to be reverted.
    /// `AppearanceSettingsPane.swift`'s section order is fixed, though: swatches -> Accent Focus
    /// Ring -> No Zoom on Focus -> Settings Style (picker) -> Size (picker) -> Corners (picker) ->
    /// Hide Titles -> Landscape Rows -> Reset -> .... Four Downs from the swatches reaches Size,
    /// confirmed by actually opening the real Small/Medium/Large popover from exactly that landing
    /// spot (`app.debugDescription` dump showed the three options mounted with "Medium" — the
    /// fixture's value at the time — carrying the `Selected` trait).
    ///
    /// UPDATED 2026-09-05 (FEAT-30/31): two more `SettingsPickerRow`s — "Navigation" and
    /// "Typeface" — landed in the Theme section between "Settings Style" and "Size", so the walk
    /// is now SIX Downs, not four: swatches -> Accent Focus Ring (1) -> No Zoom on Focus (2) ->
    /// Settings Style (3) -> Navigation (4) -> Typeface (5) -> Size (6). Not re-verified against a
    /// live popover the way the original four-count was (this pass owns the UI test files only,
    /// not a device/sim run) — counted directly off `AppearanceSettingsPane.body`'s literal order,
    /// which is the same method the original comment above used to derive "four".
    private func walkFromSwatchesToSizeRow(_ app: XCUIApplication) {
        press(.down, times: 6, gap: 0.6)
        pause(0.8)
    }

    /// Selects `optionLabel` ("Small"/"Medium"/"Large") from an ALREADY-OPEN Size/Corners popover
    /// (`SettingsPickerRow`'s `Menu { Picker }`, opened by pressing Select on the row).
    ///
    /// Ground truth from an `app.debugDescription` dump taken with the popover open (2026-09-04):
    /// the three options are NOT `Button`s — each is a plain `Other`-typed element carrying the
    /// exact label ("Small"/"Medium"/"Large"), wrapped in an unlabeled `Cell` that carries the
    /// real `Focused`/`Selected` traits (the same "Cell carries focus, inner element carries the
    /// label" shape every other row in this pane has). The popover renders as a SEPARATE overlay
    /// far to the right of the main pane — options sat at x≈1341 on a 1920pt-wide screen, vs. the
    /// pane's own content at x≈666 — so filtering candidate focused cells by `frame.minX > 1200`
    /// cleanly distinguishes the popover's own rows from the (still-present) background pane
    /// during the walk. Focus on open did NOT default to the current selection ("Medium" carried
    /// `Selected` while "Small" carried `Focused` in the same dump) — this walk is state-aware
    /// about its OWN progress regardless.
    private func selectFromOpenPopover(_ app: XCUIApplication, optionLabel: String) throws {
        let option = app.otherElements[optionLabel]
        guard option.waitForExistence(timeout: 5) else {
            XCTFail("popover never showed an option labelled '\(optionLabel)'")
            remote.press(.menu) // best-effort: don't leave a stray popover open
            pause(1)
            return
        }
        let targetY = option.frame.midY
        for _ in 0..<8 {
            guard let focusedCell = app.cells.allElementsBoundByIndex.first(where: { $0.hasFocus && $0.frame.minX > 1200 }) else {
                remote.press(.down); pause(0.5); continue
            }
            if abs(focusedCell.frame.midY - targetY) < 6 {
                remote.press(.select)
                pause(1.5)
                return
            }
            remote.press(focusedCell.frame.midY > targetY ? .up : .down)
            pause(0.5)
        }
        XCTFail("could not settle focus on popover option '\(optionLabel)' (target y=\(targetY))")
    }

    /// Navigates Settings > Appearance and sets Poster Style > Size to `optionLabel`
    /// ("Small"/"Medium"/"Large") through the real UI.
    private func selectPosterSize(_ app: XCUIApplication, _ optionLabel: String) throws {
        openTab(app, named: "Settings")
        _ = moveToSidebarRow(app, .down, named: "Appearance", max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        climbToThemeSwatches(app)
        walkFromSwatchesToSizeRow(app)
        shot(app, "fixture_size_row_before_open")

        remote.press(.select) // opens the Size popover
        pause(1.2)
        shot(app, "fixture_size_popover_\(optionLabel)")

        try selectFromOpenPopover(app, optionLabel: optionLabel)
        pause(1)
        shot(app, "fixture_size_after_select_\(optionLabel)")
    }

    // MARK: - Tests

    /// Sets the fixture's Poster Size to Large through the real Settings UI so the Wave-G
    /// Large-only geometry gates (test47/test48 in `NuvioTVUITests.swift`) can run against real
    /// data instead of self-skipping. Idempotent: if `debug_env` already reads Large-range
    /// (`w >= 260`) this is a no-op pass.
    func testSetPosterSizeLarge() throws {
        let app = launchToHome()

        if let before = readPosterArtworkWidth(app), before >= 260 {
            let attachment = XCTAttachment(string: "already Large before this test ran: w=\(before)")
            attachment.name = "fixture_already_large"
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }

        try selectPosterSize(app, "Large")

        openTab(app, named: "Home")
        pause(2)
        guard let after = readPosterArtworkWidth(app) else {
            XCTFail("debug_env probe missing after setting Poster Size to Large — is this a Release build, or did Home never remount?")
            return
        }
        let report = XCTAttachment(string: "debug_env w=\(after) after selecting Large via the UI")
        report.name = "fixture_after_large"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertGreaterThanOrEqual(
            after, 260,
            "Poster Size did not switch to Large via the UI (debug_env w=\(after)) — either the popover selection did not land, or a cloud pull clobbered the just-written value (profile-synced setting, per this file's header comment)"
        )
    }

    /// Restore path — NOT run as part of the Large-gate setup, kept for symmetry so the fixture
    /// can be put back to Medium afterward the same way it was moved to Large (through the UI).
    /// Idempotent the same way as `testSetPosterSizeLarge`.
    func testSetPosterSizeMedium() throws {
        let app = launchToHome()

        if let before = readPosterArtworkWidth(app), before > 200, before < 260 {
            let attachment = XCTAttachment(string: "already Medium before this test ran: w=\(before)")
            attachment.name = "fixture_already_medium"
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }

        try selectPosterSize(app, "Medium")

        openTab(app, named: "Home")
        pause(2)
        guard let after = readPosterArtworkWidth(app) else {
            XCTFail("debug_env probe missing after setting Poster Size to Medium — is this a Release build, or did Home never remount?")
            return
        }
        let report = XCTAttachment(string: "debug_env w=\(after) after selecting Medium via the UI")
        report.name = "fixture_after_medium"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertTrue(
            after > 200 && after < 260,
            "Poster Size did not switch to Medium via the UI (debug_env w=\(after))"
        )
    }

}
