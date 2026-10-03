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
/// `shot`, `openSettingsCategory`, `openTab`, `focusedButton`, `moveFocus`, `probeValue`) rather than a
/// shared import — same house rule `InlineTrailerTileProbeTests`/`TrailerSoakTests` give for why
/// cross-file UI-test helpers stay duplicated rather than factored out (Swift `private` scopes
/// those to `NuvioTVUITests.swift` alone). The Size-row walk and popover interaction below are
/// NOT copies of anything in that file, though — `SettingsPickerRow` (the Poster Size control)
/// turned out to need its own navigation entirely; see `walkFromSwatchesToSizeRow`'s doc for why
/// `walkToRowByTreeIndex`'s label-based approach (which works fine for every toggle row) and a
/// naive Y-position search both failed against this row kind.
///
/// `testSetHideLabelsOn`/`testSetHideLabelsOff` (added for test48's last-row leg,
/// `NuvioTVUITests.test48BeltHidesUncorrectableTitle`) drive the Poster Style section's "Hide
/// Titles" toggle (`AppearanceSettingsPane.swift`'s `PosterStyleControls`, bound to
/// `model.posterHideLabels`/`setPosterHideLabels` — `PosterStyle.showTitle = !hideLabels`, the same
/// profile-synced struct Poster Size lives on). test48's belt-hides-title gate needs a FITTING
/// pinned-row regime (`fits=1`) to exercise, and Large + captions + a carousel row is the
/// documented `fits=0` regime (`PinnedRowGeometry.plan`'s hero-compression notes) — so that leg's
/// fixture is Large **plus** Hide Titles ON, not Large alone. Verified the same way Poster Size is:
/// through the app's own `debug_pinned` probe (`regime=`'s `c0`/`c1` field —
/// `PinnedRowGeometry.regimeKey`'s `captionVisible` bit), not a UI screenshot, for the identical
/// "profile sync could silently clobber a `defaults write`" reason the type doc gives above.
/// Restore order after a run that used the Large+Hide-Titles-ON fixture: Hide Titles OFF
/// (`testSetHideLabelsOff`) first, then Poster Size back to Medium (`testSetPosterSizeMedium`) —
/// reversed from setup order so the intermediate state is never "Medium + Hide Titles ON", which no
/// other test expects.
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
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
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

    // MARK: - Settings root navigation (detail-settings-revamp W3-C, FEAT-50)
    //
    // Settings is a `NavigationStack`: a root `List` of ten categories (`settings_root_list`, each
    // row `settings_category_<raw>`) and one pushed pane per category (`settings_pane_<raw>`).
    // Select on a root row pushes the pane and focus lands on the pane's FIRST focusable row; Menu
    // inside a pane pops back to the root with focus on the category just left. There is no
    // sidebar and no Right-into-the-pane step any more. Duplicated per file (house rule: every UI
    // test file owns its helpers).

    /// The fixed root order, mirroring `SettingsCategory.allCases` (SettingsView.swift).
    private static let settingsRootOrder: [(title: String, raw: String)] = [
        ("Account & Profiles", "accountProfiles"), ("Services", "services"), ("Appearance", "appearance"),
        ("Home Screen", "homeScreen"), ("Detail Page", "detailPage"), ("Player", "player"),
        ("Sources", "sources"), ("Subtitles & Audio", "subtitlesAudio"), ("About", "about"),
        ("Developer", "developer"),
    ]

    /// Whether the Settings ROOT list is on screen (a pushed pane removes it from the tree).
    private func settingsRootPresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_root_list"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_category_'"))
                .firstMatch.exists
    }

    /// Whether a pushed Settings pane is on screen.
    private func settingsPanePresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_pane_title"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_pane_'"))
                .firstMatch.exists
    }

    /// Identifier + label of every element that reports focus, from ONE snapshot (a List row's
    /// focus can sit on its wrapping Cell or on the inner Button; reading both in one pass avoids
    /// the per-element `hasFocus` sweep).
    private func focusedNodes(_ app: XCUIApplication) -> [(identifier: String, label: String)] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [(identifier: String, label: String)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { out.append((node.identifier, node.label)) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// The title of the focused Settings ROOT row, or nil. Detected by the row's identifier
    /// (`settings_category_<raw>`) or by a focused element whose label begins with a category
    /// title (corrections F9).
    private func focusedSettingsRootTitle(_ app: XCUIApplication) -> String? {
        let nodes = focusedNodes(app)
        for node in nodes where node.identifier.hasPrefix("settings_category_") {
            let raw = String(node.identifier.dropFirst("settings_category_".count))
            if let entry = Self.settingsRootOrder.first(where: { $0.raw == raw }) { return entry.title }
        }
        for node in nodes {
            if let entry = Self.settingsRootOrder.first(where: { node.label.hasPrefix($0.title) }) { return entry.title }
        }
        return nil
    }

    /// Opens the Settings tab and makes sure the ROOT list is showing: pops any pane the persisted
    /// path left open (Menu only while a pane is up and the root is absent — Menu AT the root
    /// reveals the sidebar or leaves the app). Returns whether the root is on screen.
    @discardableResult
    private func enterSettingsRoot(_ app: XCUIApplication) -> Bool {
        openTab(app, named: "Settings")
        pause(0.8)
        for _ in 0..<3 where !settingsRootPresent(app) && settingsPanePresent(app) {
            remote.press(.menu)
            pause(1.2)
        }
        return settingsRootPresent(app)
    }

    /// With the root showing, puts focus on the root row `title` WITHOUT pushing it.
    ///
    /// Arrival is detected by identifier / focused label; when detection never fires the walk falls
    /// back to the fixed root order: Down ×12 parks on the LAST row (Down from the last row does
    /// nothing), then Up by the distance. (Up ×12 to the tab bar then Down is NOT deterministic:
    /// Down from the tab bar lands on the root's preferred row, which is the last category opened,
    /// not the first.) Returns whether arrival was DETECTED (false after a blind fallback).
    @discardableResult
    private func focusSettingsRootRow(_ app: XCUIApplication, named title: String) -> Bool {
        guard let index = Self.settingsRootOrder.firstIndex(where: { $0.title == title }) else {
            XCTFail("focusSettingsRootRow: unknown category '\(title)'")
            return false
        }
        if focusedSettingsRootTitle(app) == title { return true }
        for _ in 0..<10 {
            remote.press(.down)
            pause(0.6)
            if focusedSettingsRootTitle(app) == title { return true }
        }
        for _ in 0..<10 {
            remote.press(.up)
            pause(0.6)
            if focusedSettingsRootTitle(app) == title { return true }
        }
        press(.down, times: 12, gap: 0.4)
        press(.up, times: Self.settingsRootOrder.count - 1 - index, gap: 0.6)
        pause(0.6)
        return focusedSettingsRootTitle(app) == title
    }

    /// Opens Settings, returns to the root, focuses the category `title` and pushes it. Returns
    /// whether `settings_pane_<raw>` appeared.
    @discardableResult
    private func openSettingsCategory(_ app: XCUIApplication, named title: String) -> Bool {
        guard let entry = Self.settingsRootOrder.first(where: { $0.title == title }) else {
            XCTFail("openSettingsCategory: unknown category '\(title)'")
            return false
        }
        guard enterSettingsRoot(app) else {
            XCTFail("openSettingsCategory(\(title)): the Settings root list never appeared")
            return false
        }
        focusSettingsRootRow(app, named: title)
        remote.press(.select)
        pause(1.5)
        return app.descendants(matching: .any)["settings_pane_\(entry.raw)"].waitForExistence(timeout: 4)
    }

    /// Settings › Developer (the probe readouts moved here from About in the revamp).
    @discardableResult
    private func openDeveloper(_ app: XCUIApplication) -> Bool {
        openSettingsCategory(app, named: "Developer")
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

    /// String twin of `probeValue`, for fields that carry a token rather than a number
    /// (`regime=L403c1p1r0z1t38`) — copy of `PinnedRowSettleRegimeTests.probeToken`, same
    /// exact-key parsing, same reason (private to that file).
    private static func probeToken(_ label: String, key: String) -> String? {
        for token in label.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return String(parts[1])
        }
        return nil
    }

    /// `debug_env`'s live `w=` (poster artwork width in pt — Small ~183, Medium ~220, Medium+ ~234,
    /// Large ~269; `PosterStyle`'s own scale of the synced `widthDp`). nil when the probe is
    /// missing/unparseable (DEBUG-only, HomeView.swift) rather than defaulting to a value that
    /// could hide a real gap.
    private func readPosterArtworkWidth(_ app: XCUIApplication) -> Int? {
        let env = app.staticTexts["debug_env"]
        guard env.waitForExistence(timeout: 15) else { return nil }
        return Self.probeValue(env.label, key: "w")
    }

    /// The app's own account of the pinned-row regime it settled on — `debug_pinned`'s `regime=`
    /// field, e.g. `L403c1p1r0z1t38` (`PinnedRowGeometry.regimeKey`: size tag + rounded artwork
    /// height + `c`aptionVisible + `p`anel + land`r`scape + `z`oom-mode + `t`itle-metric). Same
    /// probe `PinnedRowSettleRegimeTests`/test47/test48 read, for the same render-vs-layout reason
    /// their doc comments give — a screenshot or AX frame can't be trusted for this, only the
    /// app's own settled plan can. nil when the probe is missing (DEBUG-only, HomeView.swift).
    private func readPinnedRegime(_ app: XCUIApplication) -> String? {
        let probe = app.staticTexts["debug_pinned"]
        guard probe.waitForExistence(timeout: 15) else { return nil }
        return Self.probeToken(probe.label, key: "regime")
    }

    /// Pulls the `captionVisible` bit back out of a `regime=` token. The digit sits immediately
    /// after `c` and immediately before `p` in `regimeKey`'s fixed field order (`c\(0|1)p\(0|1)…`),
    /// so `"c1p"`/`"c0p"` are the only two shapes that substring can take — no other field in the
    /// key contains a bare `c`. nil (not a default) when neither is found, so a format change fails
    /// loudly instead of silently reading as "hidden" or "visible".
    private func captionsVisible(inRegime regime: String) -> Bool? {
        if regime.contains("c1p") { return true }
        if regime.contains("c0p") { return false }
        return nil
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
    /// UPDATED 2026-09-15 (rc13, FEAT-38): the "OLED True Black" toggle landed after "No Zoom on
    /// Focus", one row above every row this file walks to, so both counts below are +1
    /// (swatches -> Accent Focus Ring (1) -> No Zoom (2) -> OLED True Black (3) -> Settings Style (4)
    /// -> Navigation (5) -> Typeface (6) -> Size (7)). Verified by the setters landing again on FA87.
    private func walkFromSwatchesToSizeRow(_ app: XCUIApplication) {
        press(.down, times: 7, gap: 0.6)
        pause(0.8)
    }

    /// Selects `optionLabel` ("Small"/"Medium"/"Medium+"/"Large") from an ALREADY-OPEN Size/Corners
    /// popover (`SettingsPickerRow`'s `Menu { Picker }`, opened by pressing Select on the row).
    ///
    /// Ground truth from an `app.debugDescription` dump taken with the popover open (2026-09-04,
    /// three options at the time — FEAT-39 later added "Medium+" as a fourth, same shape): the
    /// options are NOT `Button`s — each is a plain `Other`-typed element carrying the
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
        // Revamp: the pane List now sits in the right two thirds beside the explainer, so the
        // popover is no longer guaranteed to sit past x = 1200 pt. Also accept a focused cell in
        // the OPTION's own column that is narrower than a pane row (a pane row spans the ~1100 pt
        // List; a popover row is far narrower). UNVERIFIED on the sim at the time of writing.
        let optionMidX = option.frame.midX
        func isPopoverCell(_ cell: XCUIElement) -> Bool {
            let f = cell.frame
            return f.minX > 1200 || (f.minX <= optionMidX && f.maxX >= optionMidX && f.width < 1000)
        }
        for _ in 0..<8 {
            guard let focusedCell = app.cells.allElementsBoundByIndex.first(where: { $0.hasFocus && isPopoverCell($0) }) else {
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

    /// Walks from the Theme swatches to the "Hide Titles" row (Poster Style section, the
    /// `SettingsToggleRow` right after Corners in `PosterStyleControls`) with the same FIXED
    /// down-count technique as `walkFromSwatchesToSizeRow`, extended two rows further: swatches ->
    /// Accent Focus Ring (1) -> No Zoom on Focus (2) -> Settings Style (3) -> Navigation (4) ->
    /// Typeface (5) -> Size (6) -> Corners (7) -> Hide Titles (8). Unlike Size/Corners, "Hide
    /// Titles" is a real `Toggle` (`SettingsToggleRow`), so — per `walkFromSwatchesToSizeRow`'s own
    /// doc — a label-prefix walk (`NuvioTVUITests.walkToRowByTreeIndex`'s technique) WOULD work
    /// here; the fixed count is used anyway to stay consistent with this file's already-proven
    /// navigation and avoid porting that walk's ~100-line row-detection machinery for one row. Every
    /// row after Hide Titles in this section (Landscape Rows, the conditional Trailer Duration
    /// picker) sits BELOW it, so neither affects this count.
    /// UPDATED 2026-09-15 (rc13, FEAT-38): the "OLED True Black" toggle landed after "No Zoom on
    /// Focus", one row above every row this file walks to, so both counts below are +1
    /// (swatches -> Accent Focus Ring (1) -> No Zoom (2) -> OLED True Black (3) -> Settings Style (4)
    /// -> Navigation (5) -> Typeface (6) -> Size (7)). Verified by the setters landing again on FA87.
    private func walkFromSwatchesToHideTitlesRow(_ app: XCUIApplication) {
        press(.down, times: 9, gap: 0.6)
        pause(0.8)
    }

    /// Reads the "Hide Titles" `SettingsToggleRow`'s On/Off state. Copy of
    /// `NuvioTVUITests.ensureToggleRow`'s `readState()` — the row surfaces under one label across
    /// several AX element kinds (wrapping `Cell` with a composed "Hide Titles, …, On/Off" label, the
    /// `Toggle` itself with a bare `.value` "On"/"Off", and a label-less `StaticText`); scan every
    /// candidate, prefer one with a real `.value`, and return nil (never a silent default) when none
    /// is readable.
    private func hideTitlesToggleState(_ app: XCUIApplication) -> Bool? {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Hide Titles"))
            .allElementsBoundByIndex
        for e in matches {
            // Revamp (D11 V1): the value may sit on a Button, Cell or Switch; a Switch may say "1"/"0".
            if let value = e.value as? String, ["On", "Off", "1", "0"].contains(value) {
                return value == "On" || value == "1"
            }
        }
        for e in matches {
            if e.label.hasSuffix(", On") { return true }
            if e.label.hasSuffix(", Off") { return false }
        }
        return nil
    }

    /// Navigates Settings > Appearance and sets Poster Style > Hide Titles to `on`, idempotently
    /// (presses Select only when the current state disagrees). Mirrors `selectPosterSize`'s
    /// navigation prologue exactly, then swaps the popover interaction for a direct toggle press —
    /// "Hide Titles" is a `Toggle`, not a `Menu`+`Picker`.
    private func selectHideTitles(_ app: XCUIApplication, on: Bool) throws {
        // Revamp (FEAT-50): root → push; the push lands on the pane's first row (the swatches).
        guard openSettingsCategory(app, named: "Appearance") else {
            XCTFail("Settings › Appearance pane did not open")
            return
        }

        climbToThemeSwatches(app)
        walkFromSwatchesToHideTitlesRow(app)
        shot(app, "fixture_hide_titles_row_before")

        guard let before = hideTitlesToggleState(app) else {
            XCTFail("Hide Titles toggle state unreadable — did the fixed-count walk land on the wrong row?")
            return
        }
        if before != on {
            remote.press(.select)
            pause(1.5)
        }
        shot(app, "fixture_hide_titles_row_after_\(on ? "on" : "off")")
        guard let after = hideTitlesToggleState(app) else {
            XCTFail("Hide Titles toggle state unreadable after the press")
            return
        }
        XCTAssertEqual(after, on, "Hide Titles toggle did not end up \(on ? "ON" : "OFF") (was \(before))")
    }

    /// Navigates Settings > Appearance and sets Poster Style > Size to `optionLabel`
    /// ("Small"/"Medium"/"Medium+"/"Large") through the real UI.
    private func selectPosterSize(_ app: XCUIApplication, _ optionLabel: String) throws {
        // Revamp (FEAT-50): root → push; the push lands on the pane's first row (the swatches).
        guard openSettingsCategory(app, named: "Appearance") else {
            XCTFail("Settings › Appearance pane did not open")
            return
        }

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

        // FEAT-39: 212…228 keeps Medium+ (~234) and Large (~269) out of the pass band.
        if let before = readPosterArtworkWidth(app), before > 212, before < 228 {
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
            after > 212 && after < 228,
            "Poster Size did not switch to Medium via the UI (debug_env w=\(after))"
        )
    }

    /// FEAT-39: the fourth Size option, between Medium and Large. Same idempotent-restore shape as
    /// `testSetPosterSizeMedium`/`testSetPosterSizeLarge`. `w=` at 134dp is ≈234, comfortably clear
    /// of Medium's ≈220 and Large's ≈269 on either side — 228…240 leaves 6pt of margin to both
    /// neighbors without overlapping either.
    func testSetPosterSizeMediumPlus() throws {
        let app = launchToHome()

        if let before = readPosterArtworkWidth(app), before > 228, before < 240 {
            let attachment = XCTAttachment(string: "already Medium+ before this test ran: w=\(before)")
            attachment.name = "fixture_already_medium_plus"
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }

        try selectPosterSize(app, "Medium+")

        openTab(app, named: "Home")
        pause(2)
        guard let after = readPosterArtworkWidth(app) else {
            XCTFail("debug_env probe missing after setting Poster Size to Medium+ — is this a Release build, or did Home never remount?")
            return
        }
        let report = XCTAttachment(string: "debug_env w=\(after) after selecting Medium+ via the UI")
        report.name = "fixture_after_medium_plus"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertTrue(
            after > 228 && after < 240,
            "Poster Size did not switch to Medium+ via the UI (debug_env w=\(after))"
        )
    }

    /// Sets the fixture's "Hide Titles" toggle ON (captions hidden) through the real Settings UI —
    /// half of the setup `test48BeltHidesUncorrectableTitle`'s last-row leg needs, alongside
    /// `testSetPosterSizeLarge`, for a FITTING pinned-row regime (see the type doc). Idempotent: if
    /// `debug_pinned`'s `regime=` already reads captions-hidden (`c0`) this is a no-op pass —
    /// verified through the app's own settled plan, not a screenshot, for the same
    /// profile-sync-could-clobber-it reason `testSetPosterSizeLarge` gives.
    func testSetHideLabelsOn() throws {
        let app = launchToHome()

        if let before = readPinnedRegime(app), captionsVisible(inRegime: before) == false {
            let attachment = XCTAttachment(string: "already Hide Titles ON before this test ran: regime=\(before)")
            attachment.name = "fixture_already_hide_labels_on"
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }

        try selectHideTitles(app, on: true)

        openTab(app, named: "Home")
        pause(2)
        guard let after = readPinnedRegime(app) else {
            XCTFail("debug_pinned probe missing after enabling Hide Titles — is this a Release build, or did Home never remount?")
            return
        }
        let report = XCTAttachment(string: "debug_pinned regime=\(after) after enabling Hide Titles via the UI")
        report.name = "fixture_after_hide_labels_on"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertEqual(
            captionsVisible(inRegime: after), false,
            "Hide Titles did not reach Home's pinned-row regime as captions-hidden (debug_pinned regime=\(after)) — either the toggle press did not land, or a cloud pull clobbered the just-written value (profile-synced setting, per this file's header comment)"
        )
    }

    /// Restore path — sets "Hide Titles" OFF (captions visible) through the real Settings UI, the
    /// inverse of `testSetHideLabelsOn`. Per the type doc's restore order, run this BEFORE
    /// `testSetPosterSizeMedium` when putting the fixture back after the Large+Hide-Titles-ON
    /// leg. Idempotent the same way as `testSetHideLabelsOn`.
    func testSetHideLabelsOff() throws {
        let app = launchToHome()

        if let before = readPinnedRegime(app), captionsVisible(inRegime: before) == true {
            let attachment = XCTAttachment(string: "already Hide Titles OFF before this test ran: regime=\(before)")
            attachment.name = "fixture_already_hide_labels_off"
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }

        try selectHideTitles(app, on: false)

        openTab(app, named: "Home")
        pause(2)
        guard let after = readPinnedRegime(app) else {
            XCTFail("debug_pinned probe missing after disabling Hide Titles — is this a Release build, or did Home never remount?")
            return
        }
        let report = XCTAttachment(string: "debug_pinned regime=\(after) after disabling Hide Titles via the UI")
        report.name = "fixture_after_hide_labels_off"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertEqual(
            captionsVisible(inRegime: after), true,
            "Hide Titles did not reach Home's pinned-row regime as captions-visible (debug_pinned regime=\(after))"
        )
    }

}
