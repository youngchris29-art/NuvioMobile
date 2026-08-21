import XCTest

/// Headless verification harness for the beta.7 UX batch (UX-2/UX-3).
///
/// This sandbox has no Simulator window, so `XCUIRemote` is the only way to drive tvOS focus
/// headlessly (`xcodebuild test` needs no GUI). Tests are deliberately tolerant: navigation is
/// best-effort, every checkpoint captures a named screenshot attachment into the result bundle,
/// and a human (or agent) reviews the exported attachments afterwards. Assertions are kept to
/// existence checks that survive layout changes.
final class NuvioTVUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers

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

    /// Launch and pass the profile gate (profile "Chris", no PIN, first in the row and focused by
    /// default). Lands on Home.
    ///
    /// 2026-07-28: a cold `launch()` from XCTest reproducibly sits on **AuthView** — the Supabase
    /// session restore doesn't complete for it (a plain `xcrun simctl launch` of the same build
    /// reaches the profile picker in ~20s). So when the app is already running in the foreground
    /// and no launch arguments are needed, `activate()` it instead: pre-warm the sim with
    /// `xcrun simctl launch <udid> com.nuvio.media.NuvioTV` before the run and the suite attaches to
    /// that signed-in instance. (In-suite relaunches of a warm app reach the picker fine — test05/
    /// 06/08 prove it every run — so the fall-through below is safe mid-suite.)
    ///
    /// 2026-08-02 — the suite-order failure class (test04/09/11/19 failed in-suite, passed
    /// isolated): the old recovery dance here blindly pressed Menu 4×. When the previous test
    /// ended at a ROOT tab surface (top of Home is how test03/08/10/18 all end), the first Menu
    /// press exited to the springboard, and `activate()` from there intermittently re-fronts the
    /// app into a black-screen state: XCUIScreen captures pure black, the AX tree stays queryable,
    /// and D-pad presses go blind (the failed run's screen recordings show the tab-walk presses
    /// driving springboard app icons). Two rules keep the path order-independent now:
    ///  - only press Menu while the root tab bar ("Home") is not visibly on screen — pushed
    ///    screens (immersive DetailView, covers) remove it and deep scroll moves it off screen,
    ///    and a Menu press with the bar visible is exactly the press that escapes;
    ///  - never `activate()` out of a springboard escape or a backgrounded app — fall through to
    ///    a full relaunch instead, the only reliable recovery.
    /// `forceFreshLaunch` forces that same relaunch unconditionally, for tests that must not
    /// inherit any prior UI state (settings-pane scroll/focus, pushed screens) from suite order.
    @discardableResult
    private func launchToHome(extraArguments: [String] = [], forceFreshLaunch: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        if extraArguments.isEmpty && !forceFreshLaunch && app.state == .runningForeground {
            app.activate()
            pause(2)
            let chris = app.buttons["Chris"]
            if chris.waitForExistence(timeout: 8) {
                if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
                remote.press(.select)
                pause(10)
                return app
            }
            // Already past the profile gate, somewhere inside the app (a prior test's end state —
            // e.g. test01 deliberately ends on a pushed DetailView). Pop pushed screens with Menu
            // ONLY while the root tab bar is off screen (see the header comment), then reselect
            // the Home tab so every test starts from the same top-of-Home state a fresh launch
            // gives. `.exists` alone is NOT the right stop signal: the failed run's hierarchy
            // dumps show the bar's buttons stay in the tree when scrolled off screen (frame.minY
            // -604…-1510) and sit at ~+62 when actually visible — and only the visible-bar state
            // is the one where a Menu press escapes to the springboard (off-screen-deep Menu is
            // the BUG-27 jump-to-top interception, and pushed covers remove the bar entirely).
            let homeTab = app.buttons["Home"]
            var escapedToSpringboard = false
            for _ in 0..<4 {
                if homeTab.exists, homeTab.frame.minY > 0 { break }
                remote.press(.menu)
                pause(1.2)
                if app.state != .runningForeground {
                    escapedToSpringboard = true
                    break
                }
            }
            if !escapedToSpringboard {
                press(.up, times: 8, gap: 0.5)
                if !moveFocus(.left, until: homeTab, max: 8) {
                    _ = moveFocus(.right, until: homeTab, max: 8)
                }
                remote.press(.select)
                pause(3)
                press(.down, times: 1)
                pause(1)
                return app
            }
            // Springboard escape: fall through to app.launch() below.
        }
        app.launch()
        // Session restore + profile fetch can take well past 15s on a cold sim launch; a short wait
        // silently dropped the suite onto the sign-in screen and every screenshot was of AuthView.
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10) // Home catalog fan-out
        return app
    }

    /// Press `direction` until `element` has focus (or the budget runs out).
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
        // Climb until a tab-bar button reports focus (tabs DO report focus, test13) — a fixed
        // Up×8 could not leave a long Settings pane (beta.13 wave 2 finding: test27/29 ended in
        // the sidebar), while Up past the tab bar is a no-op, so overshooting is harmless.
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

    /// Types `text` on the tvOS full-screen system keyboard by walking to each letter key in turn
    /// and selecting it. Best-effort, same spirit as test19DiscoverSurvivesSearch's typing step
    /// (see its header comment): this harness has no verified key-to-key adjacency map for the
    /// keyboard grid, so a character the walk can't reach just stops the whole attempt rather than
    /// guessing blind arrow-press counts. Returns whether every character was found and selected.
    @discardableResult
    private func typeOnKeyboard(_ app: XCUIApplication, _ text: String) -> Bool {
        // tvOS 27's full-screen keyboard exposes `app.keys` elements but their `hasFocus` never
        // reads true (verified on the 27.0 sim: the walk finds "b" 80+ times and can never focus
        // it), so the key-walk below is 26.5-only. Hardware keyboard synthesis types into the
        // focused keyboard on both runtimes — proved by the manual BUG-47 repro — so try that
        // first and validate it landed by watching the entry field's value; only fall back to
        // walking keys when synthesis provably changed nothing.
        let entryField = app.textFields.firstMatch
        let before = (entryField.exists ? entryField.value as? String : nil) ?? ""
        app.typeText(text)
        pause(0.8)
        let after = (entryField.exists ? entryField.value as? String : nil) ?? ""
        if after != before && !after.isEmpty { return true }
        for character in text {
            let key = app.keys[String(character)]
            guard key.waitForExistence(timeout: 3) else { return false }
            if !key.hasFocus {
                let reached = moveFocus(.right, until: key, max: 12)
                    || moveFocus(.down, until: key, max: 6)
                    || moveFocus(.left, until: key, max: 12)
                    || moveFocus(.up, until: key, max: 6)
                guard reached else { return false }
            }
            guard key.hasFocus else { return false }
            remote.press(.select)
            pause(0.25)
        }
        return true
    }

    /// Whichever button currently holds focus, or nil if none does. `hasFocus` isn't a reliable
    /// NSPredicate key on `XCUIElementQuery`, so this walks the snapshot instead — fine here since
    /// a "See All" grid's visible button count is small.
    private func focusedButton(_ app: XCUIApplication) -> XCUIElement? {
        app.buttons.allElementsBoundByIndex.first { $0.hasFocus }
    }

    // MARK: - UX-2: trailers in thumbnails

    // Also doubles as the poster-location regression test for `trailer_playback_location`
    // (default "poster") — test37TrailerLocationHero's leg 2 re-covers this same morph under the
    // explicit argument, but this test is the one that has always run it at the default.
    func test01InlineTrailerDwell() throws {
        // Trailers on Focus is opt-in (default OFF since 05dd8ecd) — force it via the argument
        // domain so this test never depends on the sim's stored settings.
        let app = launchToHome(extraArguments: ["-inline_trailers_enabled", "YES"])
        shot(app, "01a_home")

        // Hero → Continue Watching → Streaming → first *movies* catalog row (portrait cards, the
        // row where the portrait ⇄ landscape morph is visible at all).
        press(.down, times: 4)
        shot(app, "01b_row_focused") // baseline: all portrait, evenly spaced

        // The morph fires at the 1s dwell and runs ~0.35s. Sample tightly through it so the
        // exported PNGs show the focused card mid-widen AND the trailing posters sliding right
        // rather than being overlapped.
        pause(0.9)
        shot(app, "01c_morph_t0_90")
        pause(0.25)
        shot(app, "01d_morph_t1_15")
        pause(0.25)
        shot(app, "01e_morph_t1_40")
        pause(0.6)
        shot(app, "01f_morph_settled_landscape") // landscape tile, neighbours pushed right

        // Resolution + playback (or, when nothing resolves, the new collapse-back-to-portrait).
        pause(5)
        shot(app, "01g_after_resolve")
        pause(3)
        shot(app, "01h_playing_or_collapsed") // diff vs 01g ⇒ video actually renders

        // Mute toggle while playing: the glyph in the tile's bottom-trailing corner must flip
        // between speaker.slash.fill and speaker.wave.2.fill. (Audio itself is device-only.)
        remote.press(.playPause)
        pause(2)
        shot(app, "01i_after_playpause")

        // Focus must survive the resize: Right has to move to the next card, and the row has to
        // collapse the card we left back to portrait.
        remote.press(.right)
        pause(0.3)
        shot(app, "01j_collapse_immediate")
        pause(1)
        shot(app, "01k_collapsed_portrait") // previous card portrait again, spacing restored

        // Rapid scrub must not expand anything mid-flight.
        press(.right, times: 4, gap: 0.25)
        shot(app, "01l_scrub_immediate")
        pause(7)
        shot(app, "01m_scrub_settled_expanded")

        // Back to the first card: cache hit should re-expand fast.
        press(.left, times: 5, gap: 0.25)
        pause(3.5)
        shot(app, "01n_refocus_cache_hit")

        // Select → Detail: inline player must tear down, Detail loads (⇒ focus was never lost).
        remote.press(.select)
        pause(4)
        shot(app, "01o_detail_from_card")
        XCTAssertTrue(app.state == .runningForeground, "app should survive card → detail push")
    }

    // MARK: - UX-3: detail auto-play + poster layer

    func test02DetailAutoPlayAndPoster() throws {
        let app = launchToHome()
        // Land on a *movies catalog* row (portrait cards → NavigationLink to DetailView). The
        // Continue Watching and Streaming rows above it open the stream picker / entity browse
        // instead, so going only 3 rows deep verifies the wrong screen.
        press(.down, times: 4)
        pause(0.5)
        shot(app, "02x_row_before_select")
        remote.press(.select)
        pause(2.5)
        shot(app, "02a_detail_early_poster_layer") // before trailer resolves: poster right
        pause(3)
        shot(app, "02b_detail_trailer_bg")         // bg trailer active ⇒ poster hidden
        // The auto-play fires ~4s after the trailer URL resolves and the hint fades ~4s after
        // presentation — sample every 2s so at least one frame catches the hint on screen.
        for i in 1...4 {
            pause(2)
            shot(app, "02c\(i)_autoplay_window")
        }
        pause(3)
        shot(app, "02d_autoplay_hint_faded")
        remote.press(.menu)
        pause(2.5)
        shot(app, "02e_after_trailer_dismiss")     // focus restoration check
        remote.press(.menu)
        pause(2)
        shot(app, "02f_back_on_home")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - UX-3: tab bar hiding

    func test03TabBarHiding() throws {
        let app = launchToHome()
        shot(app, "03a_home_bar_visible")
        press(.down, times: 6)
        pause(1.5)
        shot(app, "03b_scrolled_bar_hidden")
        press(.up, times: 8)
        pause(1.5)
        shot(app, "03c_scrolled_back_bar_visible")

        // Detail page is immersive: bar hidden while pushed, back on pop.
        press(.down, times: 3)
        pause(0.5)
        remote.press(.select)
        pause(3)
        shot(app, "03d_detail_bar_hidden")
        remote.press(.menu)
        pause(2)
        shot(app, "03e_popped_bar_visible")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Settings: new rows + hero sources

    /// SCRATCH utility (not part of the suite contract): re-enables Show Hero through the real
    /// Settings UI so the change pushes to the signed-in account via profile settings sync —
    /// prefs injection cannot do this (sync pulls the account value back on every launch).
    /// Run explicitly via -only-testing when a repro session left the profile hero-off.
    func test00zRestoreShowHeroOn() throws {
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        press(.down, times: 1)   // Home Screen category (activates on focus)
        pause(1.5)
        // Enter the pane, then walk UP until the FOCUSED row is Show Hero (the pane's first row;
        // entering can land focus on any row — the previous attempt selected whatever had focus
        // and collaterally toggled Trailers on Focus OFF). 26.5 reports hasFocus reliably.
        press(.right, times: 1)
        pause(1.0)
        func focusedButton() -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        }
        for _ in 0..<6 {
            if focusedButton().label.contains("Show Hero") { break }
            press(.up, times: 1)
            pause(0.8)
        }
        shot(app, "00z_before_toggle")
        XCTAssertTrue(focusedButton().label.contains("Show Hero"),
                      "focus must be on the Show Hero row before toggling, got: \(focusedButton().label)")
        if focusedButton().label.contains("Off") {
            remote.press(.select)
            pause(2.0)
        }
        shot(app, "00z_after_toggle")
        XCTAssertTrue(app.staticTexts["Hero Sources"].waitForExistence(timeout: 6),
                      "Show Hero must be ON (Hero Sources group renders only then)")

        // Repair the collateral from the previous attempt: Trailers on Focus back ON.
        press(.down, times: 1)
        pause(0.8)
        if focusedButton().label.contains("Trailers on Focus"), focusedButton().label.contains("Off") {
            remote.press(.select)
            pause(1.5)
        }
        shot(app, "00z_trailers_restored")
        // Give the settings sync a moment to push the changes to the account.
        pause(5.0)
    }

    func test04SettingsRows() throws {
        // Fresh launch (2026-08-02): this test asserts Settings pane CONTENT, so it must not
        // inherit a prior test's pane scroll/focus or the springboard black-screen state (see
        // launchToHome's header) — in-suite it failed exactly that way after test03.
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        shot(app, "04a_settings")

        // Appearance category → the two Detail-page toggle rows. ("Trailers on Focus" lives in
        // the Home Screen category, not here — asserted in the 04c step below.)
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        shot(app, "04b_appearance")
        XCTAssertTrue(app.staticTexts["Auto-Play Trailer on Detail"].waitForExistence(timeout: 4), "Auto-Play Trailer row missing")
        XCTAssertTrue(app.staticTexts["Poster in Detail Background"].exists, "Poster in Detail Background row missing")

        // "Home Screen" category (the Home Rows *section* lives inside it) sits directly below
        // Appearance in the sidebar, and categories activate on FOCUS — a single Down press from
        // the Appearance row switches the pane. Walking further lets focus escape into the content
        // pane (which is what sank the earlier attempts), so don't.
        press(.down, times: 1)
        pause(1.5)
        shot(app, "04c_home_rows")
        XCTAssertTrue(app.staticTexts["Show Hero"].waitForExistence(timeout: 4), "Show Hero row missing")
        XCTAssertTrue(app.staticTexts["Hero Sources"].exists, "Hero Sources group missing")
        XCTAssertTrue(app.staticTexts["Trailers on Focus"].exists, "Trailers on Focus row missing")
        // Scroll down through the section so the sources list + caption land in a screenshot.
        press(.down, times: 4)
        shot(app, "04d_hero_sources_list")
    }

    // MARK: - Localization smoke (German)

    func test05SettingsGerman() throws {
        let app = launchToHome(extraArguments: ["-AppleLanguages", "(de)"])
        openTab(app, named: "Einstellungen")
        shot(app, "05a_settings_de")
        // Category names are localized; walk a few and screenshot whatever renders.
        press(.down, times: 2)
        remote.press(.select)
        pause(1.5)
        shot(app, "05b_settings_de_category")
        press(.down, times: 3)
        shot(app, "05c_settings_de_scrolled")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - UX-2 hero redesign v2 (Nuvio-style: info left, artwork right)

    func test06HeroRedesign() throws {
        // The toggle defaults OFF (classic); force the opt-in layout via the argument domain
        // so this test captures the redesign without touching the sim's stored settings.
        let app = launchToHome(extraArguments: ["-hero_nuvio_style", "YES"])
        // Home lands with the hero at the top; give the backdrop art a beat to load.
        pause(4)
        shot(app, "06a_hero_nuvio")
        // Page once so the fixed-slot swap (logo/meta/synopsis swap in place) shows.
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(1)
        press(.right, times: 1)
        pause(3)
        shot(app, "06b_hero_nuvio_paged")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-25 audit: do the card settings still reach the beta.8 surfaces?

    /// Drives the REAL Settings pane (the reporter's own path): baseline shot of a poster row,
    /// then Corners → Round, Card Depth ON + Bold/Bright/Full, back to Home, after shot.
    /// A human/agent compares 07a vs 07e: corner radius must visibly change and the depth
    /// edge+sheen must appear. If they don't, the pane→repository→environment chain is broken
    /// in practice even though it reads correct statically.
    func test07CardSettingsAudit() throws {
        let app = launchToHome()
        press(.down, times: 4, gap: 1.0)
        pause(3) // let row artwork decode
        shot(app, "07a_cards_baseline")

        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)

        // Into the content pane: Corners → "Round" (28pt — the biggest visual jump from the
        // default 12).
        press(.right, times: 1)
        pause(1)
        let round = app.buttons["Round"]
        if !moveFocus(.down, until: round, max: 16) { _ = moveFocus(.up, until: round, max: 16) }
        if round.exists && round.hasFocus {
            remote.press(.select)
            pause(1)
        }
        shot(app, "07b_corners_round")

        // Card Depth master toggle, then max out the visual: Bold edge, Bright sheen, Full
        // coverage (chips only render once the toggle is on).
        let depthToggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Card Depth'")).firstMatch
        if moveFocus(.down, until: depthToggle, max: 24) {
            remote.press(.select)
            pause(1.2)
        }
        shot(app, "07c_depth_toggle")
        for chipName in ["Bold", "Bright", "Full"] {
            let chip = app.buttons[chipName]
            if moveFocus(.down, until: chip, max: 12) {
                remote.press(.select)
                pause(0.8)
            }
        }
        shot(app, "07d_depth_options")

        openTab(app, named: "Home")
        press(.down, times: 3, gap: 1.0)
        pause(3)
        shot(app, "07e_cards_after")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-24 audit: does "Hero Poster Only When Focused" still gate the backdrop?

    /// Forces the toggle through the argument domain (test06's trick) to isolate the RENDER
    /// path from the Settings write path. 08a (hero CTA focused) must show the backdrop.
    /// 2026-08-02 (UX-7): a row-focused poster now OWNS the hero too — `heroPosterFocusOnly`
    /// only gates the carousel's own idle fade, and `.opacity(... || focusModel.focusedItem
    /// != nil ? 1 : 0)` in HomeView.swift keeps the artwork VISIBLE once focus lands on a
    /// reporting row poster (src=f in the debug_hero probe — see test20). So 08b (focus down
    /// onto a row poster) must ALSO show the backdrop now, not the flat background; the hidden
    /// state this test used to assert here only applies when focus lands on a non-reporting
    /// element (e.g. a collection folder tile that never calls into `focusModel`). Kept as a
    /// pure render/existence check — no assertions changed, only the doc comment + shot name.
    func test08HeroFocusOnlyToggle() throws {
        let app = launchToHome(extraArguments: ["-hero_poster_focus_only", "YES"])
        pause(4)
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2) // fade-in animation + artwork load
        shot(app, "08a_hero_focused_art_visible")
        press(.down, times: 3, gap: 0.8)
        pause(2) // fade-out animation
        shot(app, "08b_rows_focused_art_follows_focus")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Second BUG-25 pass, sharper: storage was left with depth ON (test07's writes landed even
    /// though the pane displayed OFF), so this run checks all three links separately:
    /// 09a — RENDER: Home cards must show the Bold edge + Bright sheen from stored state.
    /// 09b — WRITE: select "Square" corners, then defocus the row so the selection color is
    ///        unambiguous (the white focus platter masks the accent).
    /// 09c/09d — DISPLAY: the Card Depth toggle must show ON before the press (storage truth)
    ///        and OFF 4s after it; chips must collapse.
    /// 09e — RENDER AGAIN: back on Home the depth effect must be gone.
    func test09CardSettingsAudit2() throws {
        // Fresh launch (2026-08-02): order-independence — the stored per-profile state this
        // audit reads survives a relaunch, but the pane walk below must start from a clean
        // top-of-pane, not wherever test08 (or the springboard escape) left the UI.
        let app = launchToHome(forceFreshLaunch: true)
        press(.down, times: 4, gap: 1.0)
        pause(3)
        shot(app, "09a_cards_depth_should_be_on")

        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        let square = app.buttons["Square"]
        if moveFocus(.down, until: square, max: 16) {
            remote.press(.select)
            pause(2)
        }
        press(.up, times: 1)
        pause(1)
        shot(app, "09b_corners_after_square_defocused")

        let depthToggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Card Depth'")).firstMatch
        _ = moveFocus(.down, until: depthToggle, max: 24)
        pause(1)
        shot(app, "09c_depth_before_press")
        remote.press(.select)
        pause(4)
        shot(app, "09d_depth_4s_after_press")

        openTab(app, named: "Home")
        pause(2)
        press(.down, times: 4, gap: 1.0)
        pause(3)
        shot(app, "09e_cards_depth_should_be_off")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Final render check for the BUG-25 audit: storage now holds depth ON (Subtle/Bright/Full)
    /// and Square corners for the active profile — Home cards must draw both. Reads the
    /// debug_env accessibility label (DEBUG builds) so the environment truth lands in the log.
    func test10RenderCheck() throws {
        let app = launchToHome()
        let env = app.staticTexts["debug_env"]
        if env.waitForExistence(timeout: 6) {
            let attachment = XCTAttachment(string: env.label)
            attachment.name = "10_env_truth"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[BUG25] env: \(env.label)")
        } else {
            print("[BUG25] debug_env not found")
        }
        press(.down, times: 4, gap: 1.0)
        pause(4)
        shot(app, "10a_cards_square_depth_on")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Cleanup after the BUG-25 audit: the audit toggled Card Depth on (Bold/Bright/Full) and set
    /// Square corners on the signed-in profile — and those writes sync to the real cloud account.
    /// Reset both sections via their own "Reset to Defaults" buttons (poster section first in the
    /// pane, card depth second).
    func test12ResetAppearanceDefaults() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        let resets = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Reset to Defaults'"))
        // Poster style reset.
        let posterReset = resets.element(boundBy: 0)
        if moveFocus(.down, until: posterReset, max: 20) {
            remote.press(.select)
            pause(1.5)
        }
        shot(app, "12a_poster_reset")
        // Card depth reset (second Reset button, further down).
        let depthReset = resets.element(boundBy: 1)
        if moveFocus(.down, until: depthReset, max: 24) {
            remote.press(.select)
            pause(1.5)
        }
        shot(app, "12b_depth_reset")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// BUG-22 verification: switch to the WHITE accent theme (the reporter's config) and capture
    /// the surfaces that were white-on-white pre-fix — the sidebar's focused+selected category
    /// and a focused ON toggle row. Restores the Ocean theme at the end (theme syncs per profile).
    func test13WhiteThemeContrast() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        // The theme swatches are the pane's FIRST row — walk RIGHT along it to White.
        let white = app.buttons["White"]
        _ = moveFocus(.right, until: white, max: 8)
        if white.exists && white.hasFocus {
            remote.press(.select)
            pause(2.5) // theme change rebuilds the tree (.id flip)
        }
        shot(app, "13a_white_theme_applied")

        // The money shot pre-fix: walk focus back to the SIDEBAR — the focused row is always the
        // selected category, whose label was raw accent (white on the white platter).
        press(.left, times: 8, gap: 0.6)
        pause(1)
        shot(app, "13b_sidebar_focused_selected")

        // Back into the pane: focus an ON toggle row (Auto-Play Trailer defaults on for this
        // profile) so the checkmark renders on the white platter.
        press(.right, times: 1)
        pause(1)
        let autoPlay = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Auto-Play Trailer'")).firstMatch
        _ = moveFocus(.down, until: autoPlay, max: 16)
        pause(1)
        shot(app, "13c_toggle_row_focused")

        // Restore the Ocean theme (the account's real setting): back up to the swatch row,
        // then walk left along it.
        let ocean = app.buttons["Ocean"]
        press(.up, times: 4, gap: 0.6)
        if !moveFocus(.left, until: ocean, max: 8) { _ = moveFocus(.right, until: ocean, max: 8) }
        if ocean.exists && ocean.hasFocus {
            remote.press(.select)
            pause(2.5)
        }
        shot(app, "13d_theme_restored")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Probe: what does the Appearance pane show for Corners on a fresh launch (repo state truth)?
    /// Focus a Size chip so the Corners row renders unfocused — the selected chip's accent tint
    /// is unambiguous there.
    func test11PaneStateProbe() throws {
        // Fresh launch (2026-08-02): this probe's whole premise is "what does the pane show on a
        // fresh launch (repo state truth)" — forceFreshLaunch makes that literal, and makes the
        // test independent of test10's end state (which fed it the springboard escape in-suite).
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        let medium = app.buttons["Medium"]
        _ = moveFocus(.down, until: medium, max: 10)
        pause(1)
        shot(app, "11a_poster_style_rows")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-23 diagnostic: does one left press page the hero back by exactly one?

    /// Reads the `debug_hero` probe (idx / focus / count) around single left and right presses
    /// on the hero CTA. Expected healthy sequence from page 1: left ⇒ idx 0, stays 0. The bug
    /// report says left needs TWO presses and "snaps back to the right-hand item" — so the
    /// probe samples both immediately after the press and again after the page animation
    /// settles, to catch a transient page-back-then-snap-forward.
    private func heroProbe(_ app: XCUIApplication, _ name: String) {
        let probe = app.staticTexts["debug_hero"]
        let text = probe.waitForExistence(timeout: 4) ? probe.label : "debug_hero MISSING"
        let attachment = XCTAttachment(string: "\(name): \(text)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[BUG23] \(name): \(text)")
    }

    func test14HeroLeftNavDiag() throws {
        let app = launchToHome()
        // Normalize focus onto the hero CTA (same walk as test06: up to the tab bar, one down
        // lands on the hero button).
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        heroProbe(app, "14a_initial")
        shot(app, "14a_hero_focused")

        // Page right twice so left has room (and so we're clear of any wrap edge case).
        press(.right, times: 1, gap: 1.5)
        pause(2)
        heroProbe(app, "14b_after_right1")
        press(.right, times: 1, gap: 1.5)
        pause(2)
        heroProbe(app, "14c_after_right2")
        shot(app, "14c_paged_right_twice")

        // THE measurement: one left press, sampled mid-animation and settled.
        remote.press(.left)
        pause(0.4)
        heroProbe(app, "14d_left1_immediate")
        pause(2.5)
        heroProbe(app, "14e_left1_settled")
        shot(app, "14e_after_left1")

        // Second left press — if the bug reproduces, THIS is the press that visibly pages.
        remote.press(.left)
        pause(0.4)
        heroProbe(app, "14f_left2_immediate")
        pause(2.5)
        heroProbe(app, "14g_left2_settled")
        shot(app, "14g_after_left2")

        // The BUG-23 fix intercepts dropped LEFT presses via onMoveCommand on the carousel —
        // verify it did not accidentally trap vertical movement: one down press must move
        // focus out of the hero (probe foc flips to 0).
        press(.down, times: 1)
        pause(1.5)
        heroProbe(app, "14h_down_leaves_hero")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-27: Menu from down the page jumps back to the top / tab bar

    /// Walks focus several rows down Home (far enough that the tab bar auto-hides), presses
    /// Menu once, and verifies the app is still frontmost with the hero focused (probe foc=1)
    /// — i.e. Menu was intercepted as jump-to-top rather than bubbling to the springboard.
    /// A second Up press should then reach the visible tab bar (screenshot evidence).
    func test15MenuJumpToTop() throws {
        let app = launchToHome()
        press(.down, times: 6, gap: 1.2)
        pause(2)
        shot(app, "15a_deep_in_rows")

        remote.press(.menu)
        pause(1.8)
        XCTAssertTrue(app.state == .runningForeground, "Menu from deep rows must NOT exit the app")
        heroProbe(app, "15b_after_menu")
        shot(app, "15b_back_at_top")

        press(.up, times: 1)
        pause(1.2)
        shot(app, "15c_tab_bar_reached")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-24 rename + FEAT-10 Search Sources: do the new Settings rows render?

    /// Visual check for two settings changes: (a) Appearance now says "Hide Hero Artwork
    /// While Browsing" (BUG-24/UX-1 rename), (b) Content Sources gained a "Search Sources"
    /// section with one toggle per search-capable catalog (FEAT-10).
    func test16SettingsNewRows() throws {
        // Fresh launch (2026-08-02): in-suite, re-entering the Settings tab restores focus to
        // wherever the last Settings test left it — which can be deep inside the Appearance
        // pane, where the lazy pane culls the top-of-pane Theme rows from the AX tree and the
        // Accent Focus Ring existence assert below fails ("no matches found") even though the
        // row renders fine (same test passed isolated on the same build). A fresh launch
        // guarantees the sidebar-default Settings entry this test's walk assumes.
        let app = launchToHome(forceFreshLaunch: true)

        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        // FEAT-14: opt-in "Accent Focus Ring" toggle (default OFF), Theme section — the first
        // section in the pane, so content-pane focus (the press(.right, 1) above lands on the
        // theme swatches row) reaches it in a single Down press. Screenshot + existence/label
        // check only — do NOT select it, this test asserts the OFF default, not the ON behavior.
        let accentRing = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Accent Focus Ring'")
        ).firstMatch
        _ = moveFocus(.down, until: accentRing, max: 8)
        pause(1)
        shot(app, "16c_accent_ring_toggle_default_off")
        XCTAssertTrue(accentRing.exists, "FEAT-14 Accent Focus Ring toggle must exist in the Theme section")
        XCTAssertTrue(
            accentRing.label.contains("Off"),
            "Accent Focus Ring must default OFF, got label: \(accentRing.label)"
        )

        let renamed = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Hide Hero Artwork'")
        ).firstMatch
        _ = moveFocus(.down, until: renamed, max: 16)
        pause(1)
        shot(app, "16a_hero_toggle_renamed")
        XCTAssertTrue(renamed.exists, "renamed BUG-24 toggle must exist in Appearance")

        press(.left, times: 1)
        pause(1)
        let contentSources = app.buttons["Content Sources"]
        if !moveFocus(.down, until: contentSources, max: 10) {
            _ = moveFocus(.up, until: contentSources, max: 10)
        }
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        // Walk down far enough to bring the Search Sources section into view (it sits below
        // the TMDB and MDBList sections).
        press(.down, times: 10, gap: 0.6)
        pause(1)
        shot(app, "16b_search_sources_section")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - UX-6: detail background darkens on scroll

    private func ux6Probe(_ app: XCUIApplication, _ name: String) {
        let probe = app.staticTexts["debug_ux6"]
        let text = probe.waitForExistence(timeout: 4) ? probe.label : "debug_ux6 MISSING"
        let attachment = XCTAttachment(string: "\(name): \(text)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[UX6] \(name): \(text)")
    }

    /// Opens a detail page from the hero CTA and walks focus down the page, sampling the live
    /// darkening value before/after — the device report says the background never darkens, so
    /// this measures whether focus-driven scrolling feeds `onScrollGeometryChange` at all.
    func test17DetailScrollDarkening() throws {
        let app = launchToHome()
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        remote.press(.select)
        pause(8)
        ux6Probe(app, "17a_detail_opened")
        shot(app, "17a_detail_top")

        press(.down, times: 4, gap: 1.0)
        pause(1.5)
        ux6Probe(app, "17b_after_down4")
        press(.down, times: 4, gap: 1.0)
        pause(1.5)
        ux6Probe(app, "17c_after_down8")
        shot(app, "17c_detail_scrolled")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-33(3): settings-row legibility when focused, default vs White theme

    /// The white-on-white regression only showed up on focused rows in the White theme
    /// (SettingsRowViews are now focus-aware). Capture the SAME row class focused in both the
    /// default (dark/Ocean) theme and White so the exported screenshots are a direct A/B — a
    /// human/agent compares 18a vs 18b for a legible label + control on both platters.
    /// Navigation to the White swatch and back mirrors test13WhiteThemeContrast's walk
    /// (duplicated rather than factored out — the two tests reach it from different starting
    /// focus positions and this harness already accepts duplication over shared helpers).
    func test18FocusedSettingsRowLegibility() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        // Accent Focus Ring toggle (Theme section, top of pane) — one Down press from the
        // swatches row that content-pane focus lands on.
        let accentRing = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Accent Focus Ring'")
        ).firstMatch
        _ = moveFocus(.down, until: accentRing, max: 8)
        pause(1)
        shot(app, "18a_row_focused_dark")

        // Back up to the swatch row, then right along it to White (test13's walk).
        press(.up, times: 4, gap: 0.6)
        let white = app.buttons["White"]
        if !moveFocus(.right, until: white, max: 8) { _ = moveFocus(.left, until: white, max: 8) }
        if white.exists && white.hasFocus {
            remote.press(.select)
            pause(2.5) // theme change rebuilds the tree (.id flip)
        }

        // Refocus the same toggle row under the new theme.
        _ = moveFocus(.down, until: accentRing, max: 8)
        pause(1)
        shot(app, "18b_row_focused_white")

        // Restore Ocean (the account's real setting) so later tests aren't affected.
        press(.up, times: 4, gap: 0.6)
        let ocean = app.buttons["Ocean"]
        if !moveFocus(.left, until: ocean, max: 8) { _ = moveFocus(.right, until: ocean, max: 8) }
        if ocean.exists && ocean.hasFocus {
            remote.press(.select)
            pause(2.5)
        }
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-33(2): Discover survives a search + clear cycle

    /// SearchView.swift: query-empty shows Discover (recent-search chips + the shared
    /// `discoverUiState` browse grid); a non-empty query swaps in `searchResults`. The reported
    /// bug is Discover staying wiped after a search is cleared back to empty.
    ///
    /// tvOS drives text entry via its own full-screen system keyboard (the file's own comment:
    /// "opens tvOS's self-contained full-screen keyboard"), which no test in this harness has
    /// driven before, so its exact key-grid layout/labels are unverified here — this pass has no
    /// sim run available to confirm `app.keys[...]` resolves the way it does for a plain iOS
    /// on-screen keyboard. Every keyboard-grid step below is therefore guarded by `.exists`
    /// checks: if the grid doesn't expose the expected keys, the test backs out via Menu and
    /// still captures the "after" screenshot, instead of guessing a fixed arrow-press count that
    /// could hang or mistype.
    ///
    /// MANUAL SIM STEP — keyboard grid driving unreliable: if the exported "19a2_after_query"
    /// screenshot never shows a typed query, or "19b_discover_after" doesn't show the Discover
    /// chips/grid back on screen, verify this manually instead: open Search, select the field,
    /// type 1-2 letters on the tvOS keyboard, wait for results to render, clear the field (Menu
    /// back to the field, then delete/backspace to empty it, or re-select and clear), and confirm
    /// Discover's genre chips / catalog grid reappear rather than staying blank.
    ///
    /// FINDING 7 fix (P2, Codex review): every failure path previously fell through to only
    /// `app.state == .runningForeground`, so the test could pass without ever confirming Discover
    /// actually rendered — a regression that left Discover blank after clearing a search, or a sim
    /// that couldn't drive the keyboard at all, would still go green. This now asserts a concrete
    /// Discover signal — the `Text("Discover")` section header from `SearchView.discoverSection`
    /// (SearchView.swift ~line 143) — which `SearchViewModel.start()` renders as soon as
    /// `discoverUiState` emits once, independent of whether any catalogs/items are present (an
    /// empty-addon profile still gets the header plus an empty-state message below it). Profile
    /// "Chris" (launchToHome) has real addons installed (test16 walks live Settings against it),
    /// so the header is expected to appear here, not just in principle.
    ///
    /// ALWAYS asserted (mandatory, regardless of how the keyboard step goes):
    ///   1. the Discover header exists right after opening Search, before any keyboard interaction.
    ///   2. the Discover header exists again after the Menu/Menu round-trip that backs out of the
    ///      keyboard — this is the actual BUG-33(2) regression check.
    ///   3. the app is still in the foreground at the end (kept as a final sanity net).
    /// Best-effort / conditional (does not fail the test if the keyboard grid can't be driven):
    ///   - typing "as" into the query field.
    ///   - if typing demonstrably succeeded (both letter keys were focused and selected), that a
    ///     results signal (a result cell, or the "No results." empty-results message) appeared —
    ///     this is still a real `XCTAssertTrue`, it's just skipped entirely when typing itself
    ///     could not be driven, so a keyboard-grid mismatch doesn't fail the test.
    func test19DiscoverSurvivesSearch() throws {
        // Fresh launch (2026-08-02): the Discover asserts below need a Search tab with no
        // leftover query/keyboard state from suite order, and test18's end state fed this test
        // the springboard escape in-suite (see launchToHome's header).
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Search")
        pause(1.5)
        shot(app, "19a_discover_before")

        // Mandatory: Discover must actually be on screen before we touch the keyboard at all,
        // otherwise everything that follows is exercising nothing.
        let discoverHeader = app.staticTexts["Discover"]
        XCTAssertTrue(discoverHeader.waitForExistence(timeout: 6), "Discover missing on entry")

        let searchField = app.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 4) else {
            // Field never resolved — nothing further to drive automatically. Still re-check
            // Discover so this path can't silently pass without exercising anything.
            shot(app, "19b_discover_after")
            XCTAssertTrue(discoverHeader.exists, "Discover gone after search/keyboard round-trip — BUG-33(2) regression")
            XCTAssertTrue(app.state == .runningForeground)
            return
        }
        if !searchField.hasFocus {
            _ = moveFocus(.up, until: searchField, max: 6)
        }
        remote.press(.select)
        pause(2) // full-screen keyboard presentation

        // Best-effort "as": walk to "a", select, then to "s", select. Bail to the manual-step
        // path (Menu back out) if the grid doesn't expose letter keys the way expected. Tracks
        // whether both selects were actually driven, so the post-typing results assert below can
        // stay guarded rather than failing the test on a keyboard-grid mismatch.
        var typedSuccessfully = false
        let keyA = app.keys["a"]
        if keyA.waitForExistence(timeout: 3) {
            _ = moveFocus(.right, until: keyA, max: 12)
            var selectedA = false
            if keyA.hasFocus {
                remote.press(.select)
                selectedA = true
            }
            pause(0.5)
            let keyS = app.keys["s"]
            var selectedS = false
            if moveFocus(.right, until: keyS, max: 8) || moveFocus(.down, until: keyS, max: 6) {
                remote.press(.select)
                selectedS = true
            }
            pause(2.5) // debounce + results fetch
            shot(app, "19a2_after_query_typed")
            typedSuccessfully = selectedA && selectedS
        }

        // Conditional: only when typing was actually driven do we require a results signal — a
        // result cell for a hit, or the "No results." empty-results text for a legitimate miss.
        // Either counts as proof the query round-tripped through SearchRepository.
        if typedSuccessfully {
            let resultCell = app.cells.firstMatch
            let noResultsMessage = app.staticTexts["No results."]
            XCTAssertTrue(
                resultCell.waitForExistence(timeout: 3) || noResultsMessage.waitForExistence(timeout: 1),
                "typed query \"as\" produced neither result cells nor an empty-results message"
            )
        }

        // Clear back to Discover: Menu dismisses the keyboard/backs out of the query. If the
        // query text survived (see the manual-step note above), a human should re-check by
        // clearing it explicitly and re-screenshotting.
        remote.press(.menu)
        pause(1.5)
        remote.press(.menu)
        pause(1.5)

        shot(app, "19b_discover_after")
        // Mandatory: the actual BUG-33(2) regression check — Discover must reappear after the
        // search + clear round-trip, whether or not the query itself could be typed.
        XCTAssertTrue(discoverHeader.waitForExistence(timeout: 6), "Discover gone after search/keyboard round-trip — BUG-33(2) regression")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the search + clear cycle even if the query itself couldn't be driven")
    }

    // MARK: - UX-7: focus-follows-backdrop hero on Home

    /// Reads the `debug_hero` probe and asserts it contains `src=c` — the carousel owns the
    /// hero. HomeView.swift's probe (DEBUG only) ends `src=\(focusModel.focusedItem == nil ?
    /// "c" : "f") fitem=\(focusModel.focusedItem?.id ?? "-")`.
    private func heroSrcProbe(_ app: XCUIApplication, _ name: String) -> String {
        let probe = app.staticTexts["debug_hero"]
        let text = probe.waitForExistence(timeout: 4) ? probe.label : "debug_hero MISSING"
        let attachment = XCTAttachment(string: "\(name): \(text)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[UX7] \(name): \(text)")
        return text
    }

    /// UX-7: a row-focused poster now owns the hero backdrop too — `HomeFocusModel` commits a
    /// focused row item after `commitDelay` (0.2s) and reverts to nil after `revertGrace`
    /// (0.3s) once focus reports nothing. This walks CTA → row poster → CTA and watches the
    /// `debug_hero` probe's `src=c|f` field flip both ways, with `fitem=` populated (not `-`)
    /// while a row poster owns it.
    func test20HeroFocusFollowsBackdrop() throws {
        // Fresh launch: this test asserts the probe's live src/fitem fields, so it must not
        // inherit a prior test's pushed screen or springboard-escape state (see launchToHome's
        // header) — the same rationale test04/09/11/16/19 already use.
        let app = launchToHome(forceFreshLaunch: true)

        // Normalize focus onto the hero CTA (test06's walk: up to the tab bar, one down lands
        // back on the hero button).
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        shot(app, "20a_hero_carousel")
        let carouselState = heroSrcProbe(app, "20a_carousel")
        XCTAssertTrue(carouselState.contains("src=c"), "hero must start carousel-owned, got: \(carouselState)")

        // Walk down one row at a time, sampling the probe after each press, until a REPORTING
        // row takes the hero. Not every Home row drives it: the Streaming-services shelf and
        // collection folder tiles carry no MetaPreview and by design leave the carousel in
        // charge (src=c) — only catalog rows and Continue Watching report. The ceiling exists
        // only so the test terminates; keep it generous (the signed-in profile's synced row
        // order can stack several non-reporting rows before the first catalog row).
        var downPresses = 0
        var focusedState = ""
        for _ in 1...12 {
            press(.down, times: 1)
            downPresses += 1
            pause(1.0) // commit delay is 200ms — well clear of it by the time we sample
            focusedState = heroSrcProbe(app, "20b_after_down_\(downPresses)")
            if focusedState.contains("src=f") { break }
        }
        shot(app, "20b_hero_follows_focus")
        XCTAssertTrue(focusedState.contains("src=f"), "no row poster took the hero within \(downPresses) presses, got: \(focusedState)")
        XCTAssertFalse(focusedState.contains("fitem=-"), "src=f must carry a real fitem id, got: \(focusedState)")

        // Walk back up to the CTA (mirrors the walk down) and confirm the carousel reclaims
        // the hero once focus lands back on it.
        press(.up, times: downPresses, gap: 0.8)
        pause(1.0) // revert grace is 300ms — well clear of it by the time we sample
        let revertedState = heroSrcProbe(app, "20c_back_on_cta")
        XCTAssertTrue(revertedState.contains("src=c"), "hero must revert to carousel-owned, got: \(revertedState)")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - UX-10: trailer thumbnails on Detail

    func test21DetailTrailerThumbnails() throws {
        // Navigate to a detail page exactly like test02: land on a movies catalog row (portrait
        // cards → NavigationLink to DetailView), not the Continue Watching / Streaming rows
        // above it which open the stream picker / entity browse instead.
        let app = launchToHome()
        press(.down, times: 4)
        pause(0.5)
        remote.press(.select)
        pause(2.5)

        // Walk focus down toward the Trailers & Extras shelf (test17's detail-scroll walk).
        press(.down, times: 10, gap: 0.5)
        pause(1.5)
        shot(app, "21a_trailers_row")

        // Soft assertion: only when the debug_trailers probe made it on screen (title had
        // trailers AND focus reached the shelf) do we parse and assert on it. DetailView.swift's
        // probe (DEBUG only) is `debug_trailers n=<count> thumbs=<count-with-thumbnail-url>`.
        let probe = app.staticTexts["debug_trailers"]
        if probe.exists {
            let text = probe.label
            let attachment = XCTAttachment(string: "21b_trailers_probe: \(text)")
            attachment.name = "21b_trailers_probe"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[UX10] 21b_trailers_probe: \(text)")

            func intValue(after marker: String) -> Int? {
                guard let range = text.range(of: marker) else { return nil }
                let rest = text[range.upperBound...]
                let digits = rest.prefix { $0.isNumber }
                return Int(digits)
            }

            if let n = intValue(after: "n="), let thumbs = intValue(after: "thumbs=") {
                if n > 0 {
                    XCTAssertGreaterThan(thumbs, 0, "trailer cards rendered without a single thumbnail URL")
                }
            }
        } else {
            // Probe not on screen (no trailers for this title, or focus didn't reach the
            // shelf) — same softness as test02/test17, do not hard-fail on a missing probe.
            print("[UX10] debug_trailers not found on screen")
        }
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Pinned Nuvio hero: foreground stays on screen at deep scroll (UX-7 extension)

    /// Launches with -hero_nuvio_style YES, walks focus deep into the rows, and asserts the hero
    /// foreground is STILL on screen: the CTA ("Go to Movie"/"Go to Show") must exist AND be
    /// hittable (in classic it scrolls away and stops being hittable — the discriminator), and the
    /// debug_hero probe must carry pin=1. Screenshots give the human pass the hero-over-rows
    /// composition check (fade band artifacts, row 1 rest position).
    func test22PinnedHeroDeepScroll() throws {
        // Fresh launch: the pinned-hero layout must not inherit a prior test's scroll/focus state
        // (same rationale as test06/test20's use of the argument-domain toggle + forceFreshLaunch).
        let app = launchToHome(extraArguments: ["-hero_nuvio_style", "YES"], forceFreshLaunch: true)

        // Normalize focus onto the hero CTA (test06/test20's walk: up to the tab bar, one down
        // lands back on the hero button).
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)
        shot(app, "22a_pinned_hero_at_top")
        let topState = heroSrcProbe(app, "22a_probe_at_top")
        XCTAssertTrue(topState.contains("pin=1"), "hero_nuvio_style=YES must set pin=1 on the debug_hero probe, got: \(topState)")

        // Deep scroll: the classic (unpinned) hero scrolls its foreground away with the carousel;
        // the pinned variant must keep the CTA on screen and hittable throughout.
        press(.down, times: 8, gap: 1.0)
        pause(2)
        shot(app, "22b_pinned_hero_deep_scroll")
        // src=c or src=f are both legal this deep (depends which row reports) — not asserted here.
        _ = heroSrcProbe(app, "22b_probe_after_deep_scroll")

        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Go to'")).firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 4), "hero CTA must still exist after deep scroll with pinned hero")
        XCTAssertTrue(cta.isHittable, "pinned hero CTA must remain hittable at deep scroll — a non-hittable CTA means it scrolled away like the classic layout")

        // Up-walk through the fade band (Codex review P2, 2026-08-03): rows masked under the
        // pinned hero stay focus-ELIGIBLE — the design bets on the focus engine's scroll-to-
        // reveal honoring the safe-area inset so a focused card is always brought back below
        // the hero. Walk Up one press at a time and screenshot each step; the human/agent pass
        // checks that no step shows the focus halo resting inside the hero band on an invisible
        // card. No hard assert — the masked card is still "visible" to the AX tree, so the
        // screenshot is the only oracle (same philosophy as the rest of the harness).
        for step in 1...4 {
            press(.up, times: 1)
            pause(1)
            shot(app, "22b_upwalk_\(step)")
        }
        // Return deep so the Menu leg below exercises the pinned Menu-to-top branch from a
        // genuinely scrolled-down state (its handler only attaches while isScrolledDown).
        press(.down, times: 4, gap: 1.0)
        pause(2)

        // Menu from deep scroll must jump rows back to top AND land focus on the pinned CTA.
        remote.press(.menu)
        pause(2)
        XCTAssertTrue(app.state == .runningForeground, "Menu from deep rows must NOT exit the app")
        shot(app, "22c_menu_back_to_top")
        let afterMenuState = heroSrcProbe(app, "22c_probe_after_menu")
        XCTAssertTrue(afterMenuState.contains("foc=1"), "Menu-to-top must land focus on the pinned hero CTA (foc=1), got: \(afterMenuState)")
    }

    // MARK: - BUG-47: Search "See All" grid must survive a Back mid-navigation

    /// BUG-47 (P0): on tvOS 27, pressing Back (Menu) out of the "See All" grid pushed from Search
    /// results reproducibly terminated the process. Root cause: `FlowWatcher` cancellation is
    /// cooperative, so a resume already queued on the main run loop could deliver one more value
    /// to the watcher callback AFTER `stop()`/`cancel()` returned, driving a `@Published` write
    /// into a view mid-pop — `CatalogGridViewModel`'s `stopped` guard closes that window. This
    /// drives the exact repro path three times with different timing, so a regression that only
    /// shows up under a specific race window (immediate Menu vs. Menu after pagination) still gets
    /// exercised.
    ///
    /// Query typing is best-effort (see `typeOnKeyboard` / test19's header comment on the tvOS
    /// keyboard grid): if it can't be driven on a given run this still asserts the app survived
    /// the attempt, but the actual crash probe below needs real results to reach a "See All" card,
    /// so a failed type makes the rest of the test a no-op pass.
    func test23SearchSeeAllBackNoCrash() throws {
        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Search")
        pause(1.5)

        let searchField = app.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 4) else {
            XCTAssertTrue(app.state == .runningForeground)
            return
        }
        if !searchField.hasFocus {
            _ = moveFocus(.up, until: searchField, max: 6)
        }
        remote.press(.select)
        pause(2) // full-screen keyboard presentation

        // Broad query so real result rows (and a "See All" card) are likely regardless of which
        // addons are installed on the signed-in profile.
        let typed = typeOnKeyboard(app, "batman")
        remote.press(.menu) // dismiss the keyboard back to the results list either way
        pause(2.5) // debounce + results fetch
        shot(app, "23a_search_results")
        // Prerequisite failures are LOUD: this test is the BUG-47 regression gate, and a silent
        // skip-return already produced one vacuous green (Codex round 1 — the first run never
        // opened the grid at all, because `waitForExistence` cannot see a `SeeAllCard` that a
        // LazyHStack hasn't materialized yet; only walking focus rightward brings it into the
        // tree, and the "batman" row is ~47 cards long).
        guard typed else {
            XCTFail("BUG-47 gate not exercised: the tvOS keyboard grid could not be driven")
            return
        }

        let seeAll = seeAllCard(app)
        press(.down, times: 1) // out of the search field, into the first results row

        for iteration in 1...3 {
            // On the tvOS 27.0 runtime under Xcode 26.6, `hasFocus` NEVER reads true for these
            // cards (input lands fine; focus *reporting* is broken — same class as the keyboard's
            // `app.keys` focus). So the walk is existence-driven, not focus-driven: a lazy
            // `SeeAllCard` materializes only when the walk nears the row's end, so "it exists"
            // means "focus is within a couple of cards of it" — a few more presses land on it,
            // and the row's end stops focus there regardless of what `hasFocus` claims.
            guard walkRightUntilExists(seeAll, max: 60) else {
                shot(app, "23x_no_seeall_\(iteration)")
                XCTFail("BUG-47 gate not exercised: See All never materialized in the \"batman\" row (iteration \(iteration))")
                return
            }
            press(.right, times: 3, gap: 0.6) // land on the row-end See All card
            remote.press(.select)

            if iteration == 1 {
                // Back almost immediately — the race window the `stopped` guard closes (device
                // repro: Menu fired while the grid's first page is still in flight).
                pause(0.3)
            } else {
                pause(2.5)
                shot(app, "23b_grid_opened_\(iteration)")
                XCTAssertTrue(app.state == .runningForeground, "app should survive opening the See All grid (iteration \(iteration))")
                if iteration == 2 {
                    press(.down, times: 6, gap: 0.3) // paginate first, then back mid-scroll
                }
            }

            remote.press(.menu)
            pause(2)
            shot(app, "23c_after_menu_\(iteration)")
            XCTAssertTrue(app.state == .runningForeground, "BUG-47 regression: Menu out of the See All grid must not terminate the process (iteration \(iteration))")

            let backOnResults = seeAll.waitForExistence(timeout: 4) || searchField.waitForExistence(timeout: 2)
            XCTAssertTrue(backOnResults, "expected to be back on search results after Menu (iteration \(iteration))")
        }
    }

    // MARK: - UX-13: "See All" grid keeps its focus position across a detail round trip

    /// Once inside a "See All" grid: walks Right×2 Down×1 (`LazyVGrid` populates left-to-right,
    /// top-to-bottom, so this lands a couple of rows in rather than the very first cell), records
    /// the focused poster's accessibility label, opens its detail page, backs out with Menu, and
    /// asserts the SAME element regains focus. This is the UX-13 contract H1's `detach()` exists
    /// for: a pop only cancels the in-flight fetch (`CatalogRepository.detach()`), it does not wipe
    /// `items`/`scrollPositions` the way `clear()` did, so `load()`'s same-target early-return
    /// keeps the grid — and its focus/scroll state — exactly as the user left it.
    /// Enter the See All grid from a card row, recovering from mis-entry. The blind Right×N +
    /// Select after `walkRightUntilExists` is approximate by design (the SeeAllCard materializes
    /// while focus is still a couple of cards away, and composed-label cards never report focus),
    /// so an undershoot Selects a POSTER and opens its detail page instead of the grid — which is
    /// exactly what the 2026-08-21 in-suite run did (suite-order Home drift; the UX-13 assert then
    /// ran against a detail page's cast row and failed on the wrong screen entirely, while the
    /// solo run passed). Detail pages carry the always-on `debug_ux6` probe in DEBUG builds, so:
    /// Select, and if a detail page opened, Menu out and retry one card further Right. The SeeAll
    /// card is the row's LAST card, so extra Rights can't overshoot — only undershoot needs
    /// walking, and each attempt converges on it. First observed solo 2026-08-21 on the Search
    /// fallback: the results row is long and the SeeAllCard can be IN THE TREE while focus is
    /// still many cards short of it, so proximity guessing (+1 per retry) never covered the
    /// distance — each retry now strides several cards, which overshoot-safety makes free.
    /// Walk Right until the FOCUSED element is the SeeAll card itself. tvOS 26.5 (the gating
    /// runtime) reports focus, so identity beats press-count guessing — a long Search results
    /// row defeated both Right×3 and Right×28 (2026-08-21): existence of the card in the tree
    /// says nothing about how many cards away focus is. On 27.0 `focusedButton` is nil and this
    /// no-ops; the caller's blind stride + mis-entry retries remain the (skippy) fallback there.
    private func walkFocusOntoSeeAll(_ app: XCUIApplication) {
        for _ in 0..<30 {
            guard let f = focusedButton(app) else { return }
            if f.label.localizedCaseInsensitiveContains("See All") { return }
            remote.press(.right)
            pause(0.45)
        }
    }

    private func selectIntoSeeAllGrid(_ app: XCUIApplication, shotName: String) -> Bool {
        for attempt in 0..<6 {
            walkFocusOntoSeeAll(app)
            remote.press(.select)
            pause(2.5)
            if !app.staticTexts["debug_ux6"].exists {
                shot(app, shotName)
                return true
            }
            print("[UX13] mis-entry attempt \(attempt): detail page opened instead of the grid — backing out, striding Right")
            remote.press(.menu)
            pause(2)
            press(.right, times: 3, gap: 0.5)
        }
        shot(app, "\(shotName)_misentry")
        return false
    }

    private func assertGridFocusRestores(_ app: XCUIApplication) throws {
        press(.right, times: 2, gap: 0.5)
        press(.down, times: 1, gap: 0.5)
        pause(0.5)

        guard let focused = focusedButton(app) else {
            // The tvOS 27.0 runtime under Xcode 26.6 never reports `hasFocus` for any element
            // (see test23's walk comment), so a focus-identity assertion is unprovable there —
            // skip rather than fail or pass vacuously; the 26.5 run is the gating one.
            throw XCTSkip("focus reporting unavailable on this runtime — UX-13 restore asserted on tvOS 26.5")
        }
        let label = focused.label
        shot(app, "24a_grid_focused_\(label)")

        remote.press(.select)
        pause(3) // detail page load
        shot(app, "24b_detail_opened")
        XCTAssertTrue(app.state == .runningForeground)

        remote.press(.menu)
        pause(2.5)
        shot(app, "24c_back_on_grid")

        let restored = app.buttons[label]
        XCTAssertTrue(
            restored.waitForExistence(timeout: 6) && restored.hasFocus,
            "UX-13 regression: focus did not return to \"\(label)\" after popping the detail page"
        )
    }

    func test24CatalogGridFocusRestore() throws {
        let app = launchToHome(forceFreshLaunch: true)

        // Prefer Home (more stable than Search — no keyboard round trip needed): land on the same
        // movies catalog row test01/02/17/21 use and walk out to its trailing "See All" card.
        press(.down, times: 4)
        pause(1)
        let homeSeeAll = seeAllCard(app)
        if walkRightUntilExists(homeSeeAll, max: 40) {
            // Overshoot-safe stride: the SeeAll card is the row's LAST card, so Rights past it
            // are no-ops — 10 covers the materializes-early gap the old ×3 undershot.
            press(.right, times: 10, gap: 0.4)
            guard selectIntoSeeAllGrid(app, shotName: "24_home_grid_opened") else {
                XCTFail("UX-13 gate not exercised: could not enter the Home See All grid (kept opening detail pages)")
                return
            }
            try assertGridFocusRestores(app)
            return
        }

        // Home's harness config has no reachable "See All" on that row — fall back to test23's
        // Search path into a grid.
        openTab(app, named: "Search")
        pause(1.5)
        let searchField = app.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 4) else {
            XCTAssertTrue(app.state == .runningForeground)
            return
        }
        if !searchField.hasFocus {
            _ = moveFocus(.up, until: searchField, max: 6)
        }
        remote.press(.select)
        pause(2)
        let typed = typeOnKeyboard(app, "batman")
        remote.press(.menu)
        pause(2.5)
        guard typed else {
            XCTFail("UX-13 gate not exercised: the tvOS keyboard grid could not be driven")
            return
        }
        // Same lazy-materialization + broken-hasFocus caveats as test23: existence-driven walk.
        let searchSeeAll = seeAllCard(app)
        press(.down, times: 1)
        guard walkRightUntilExists(searchSeeAll, max: 60) else {
            shot(app, "24x_no_seeall")
            XCTFail("UX-13 gate not exercised: no reachable See All card on Home or in Search results")
            return
        }
        // Same overshoot-safe stride as the Home path — the Search results row is where the
        // materializes-early gap actually bit (2026-08-21 solo run).
        press(.right, times: 10, gap: 0.4)
        guard selectIntoSeeAllGrid(app, shotName: "24_search_grid_opened") else {
            XCTFail("UX-13 gate not exercised: could not enter the Search See All grid (kept opening detail pages)")
            return
        }
        try assertGridFocusRestores(app)
    }

    // MARK: - BUG-45: Home Screen pane focused-toggle contrast probe

    /// Screenshot probe for the BUG-45 class on the Settings → Home Screen pane: the tester's
    /// `p1vylo0` frame measured the FOCUSED "Nuvio-Style Hero" toggle at 1.05:1 label/platter on
    /// beta.10 even though `SettingsToggleRow` routes through `rowTextColor()`. This captures
    /// both toggles focused, on the current build, for pixel measurement — it asserts nothing
    /// about color itself (the measurement is done on the exported PNGs).
    func test25HomeScreenPaneContrast() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let homeScreen = app.buttons["Home Screen"]
        _ = moveFocus(.down, until: homeScreen, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        // Fixed press counts, no hasFocus: `SettingsToggleRow` buttons do not report focus to
        // XCUITest even on 26.5 (the first probe run walked straight past both toggles to the
        // Catalogs row) — itself a data point for BUG-45's focus-propagation hypothesis. The
        // pane's first focusable row is the Show Hero toggle; one Down is Nuvio-Style Hero.
        shot(app, "25a_show_hero_focused")
        press(.down, times: 1)
        pause(1)
        shot(app, "25b_nuvio_style_hero_focused")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-42: the hero commits its artwork once on a cold launch

    /// Cold-launches with the release-safe `debug.homeHeroProbe` knob and lets the hero settle.
    /// The oracle is the `[HomeHero]` log stream (harness style — see the type doc): a healthy
    /// launch has exactly ONE `paint … first=1` line (`kind=primary`, or `kind=seededPrimary`
    /// when the backdrop was already in the memory cache) and NO `publish … headChanged=1` /
    /// `hero emptied` line before any focus moves; `paint kind=fallbackHeld first=1` means the
    /// real backdrop missed the 600 ms first-paint deadline (poster shown), allowed but worth
    /// counting.
    ///
    ///     xcrun simctl spawn booted log show --last 5m \
    ///       --predicate 'eventMessage CONTAINS "[HomeHero]"'
    ///
    /// Two launches so the second one starts with a warm artwork disk cache (the reporter's
    /// every-day case) as well as the first's cold one.
    func test31HeroCommitsOnce() throws {
        for launch in 1...2 {
            let app = launchToHome(extraArguments: ["-debug.homeHeroProbe", "YES"], forceFreshLaunch: true)
            pause(4.0)
            shot(app, "31_launch\(launch)_hero_settled")
            XCTAssertTrue(app.state == .runningForeground, "app must be alive after hero first paint (launch \(launch))")
            app.terminate()
            pause(1.0)
        }
    }

    // MARK: - BUG-64: the accent focus ring must not cover the poster

    /// Reporter's exact configuration (u/mrStevenx3, p4afwfo): Accent Focus Ring ON + No Zoom on
    /// Focus ON — "the film ends up hidden behind the border". Both are LOCAL @AppStorage keys, so
    /// the argument domain sets them without touching the synced profile (same trick as test01's
    /// `-inline_trailers_enabled`). Focus a poster in the first movies row and measure two bands of
    /// the focused card: the OUTER 4 pt band (must carry the ring — mean colour far from the ring-
    /// OFF baseline of the same card) and an INNER band 6…14 pt in (must be the poster — mean colour
    /// close to the ring-OFF baseline). Pre-BUG-64 the inner band was painted by the stroke too.
    func test32AccentRingArtworkInset() throws {
        // No Zoom via the argument domain (local key); the ring is flipped through the REAL
        // Appearance toggle inside ONE launch so both measurements are of the same card (two
        // launches focused different cards and the first version of this test skipped itself).
        let app = launchToHome(extraArguments: ["-no_zoom_on_focus", "YES"], forceFreshLaunch: true)
        let appearance = app.buttons["Appearance"]
        func openAppearance() {
            openTab(app, named: "Settings")
            _ = moveFocus(.down, until: appearance, max: 10)
            remote.press(.select)
            pause(1.5)
            press(.right, times: 1)
            pause(1)
        }
        func focusedPosterShot(_ name: String) throws -> (CGRect, UIImage) {
            openTab(app, named: "Home")
            press(.down, times: 3)
            press(.left, times: 6, gap: 0.3)
            pause(1.5)
            guard let card = focusedButton(app), card.frame.width > 80, card.frame.height > card.frame.width else {
                throw XCTSkip("no focused poster card reported (27.0 runtime never reports hasFocus)")
            }
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return (card.frame, screenshot.image)
        }
        openAppearance()
        let sidebarX = appearance.frame.maxX
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        let (frameOff, imageOff) = try focusedPosterShot("32a_ring_off")
        openAppearance()
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        let (frameOn, imageOn) = try focusedPosterShot("32b_ring_on")
        // Restore the local toggle (it is real prefs on this sim, not the argument domain).
        openAppearance()
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: false, sidebarMaxX: sidebarX, category: "Appearance")

        // The poster caption sits below the artwork; the artwork is the top 2:3 of the card frame.
        func bands(_ f: CGRect) -> (outer: CGRect, inner: CGRect) {
            let artH = f.width * 1.5
            let outer = CGRect(x: f.minX, y: f.minY + artH * 0.3, width: 4, height: artH * 0.4)         // left ring band
            let inner = CGRect(x: f.minX + 6, y: f.minY + artH * 0.3, width: 8, height: artH * 0.4)     // 6…14 pt in
            return (outer, inner)
        }
        let bOff = bands(frameOff), bOn = bands(frameOn)
        let outerOff = try meanRGB(in: imageOff, pointRect: bOff.outer, windowSize: app.frame.size)
        let outerOn = try meanRGB(in: imageOn, pointRect: bOn.outer, windowSize: app.frame.size)
        let innerOff = try meanRGB(in: imageOff, pointRect: bOff.inner, windowSize: app.frame.size)
        let innerOn = try meanRGB(in: imageOn, pointRect: bOn.inner, windowSize: app.frame.size)
        func dist(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            (abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)) / 3
        }
        let outerDelta = dist(outerOff, outerOn), innerDelta = dist(innerOff, innerOn)
        let report = XCTAttachment(string: "outerDelta=\(outerDelta) innerDelta=\(innerDelta) outerOff=\(outerOff) outerOn=\(outerOn) innerOff=\(innerOff) innerOn=\(innerOn) frames off=\(frameOff) on=\(frameOn)")
        report.name = "32c_band_deltas"
        report.lifetime = .keepAlways
        add(report)
        NSLog("[BUG64] outerDelta=%.3f innerDelta=%.3f off=%@ on=%@", outerDelta, innerDelta, NSCoder.string(for: frameOff), NSCoder.string(for: frameOn))
        // The two focus treatments report slightly different accessibility frames for the same
        // card (~5 pt); the bands are computed per frame, so a small drift is fine — a different
        // CARD (different column / row) is not.
        guard abs(frameOff.width - frameOn.width) < 12, abs(frameOff.minX - frameOn.minX) < 12, abs(frameOff.minY - frameOn.minY) < 12 else {
            throw XCTSkip("focused card differs between the two measurements (\(frameOff) vs \(frameOn))")
        }
        XCTAssertGreaterThan(outerDelta, 0.08, "ring band did not change colour with the ring ON — is the ring drawn at all?")
        XCTAssertLessThan(innerDelta, outerDelta * 0.5, "the band 6…14 pt inside the card edge changed almost as much as the ring band — the stroke is still painted over the poster (BUG-64)")
    }

    /// Mean RGB (0…1) inside `pointRect` of a full-screen screenshot — the colour cousin of
    /// `lumaStats`.
    private func meanRGB(in image: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> (Double, Double, Double) {
        guard let cg = image.cgImage, windowSize.width > 0 else { throw XCTSkip("screenshot has no CGImage / zero window size") }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(x: pointRect.minX * scale, y: pointRect.minY * scale, width: pointRect.width * scale, height: pointRect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else { throw XCTSkip("band \(pointRect) is off-screen") }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            r += Double(buffer[i]); g += Double(buffer[i + 1]); b += Double(buffer[i + 2])
        }
        let n = Double(w * h) * 255.0
        return (r / n, g / n, b / n)
    }

    // MARK: - FEAT-24: season posters in the season selector

    /// Opens the first title of the row directly under the hero (a series row on this account —
    /// the same walk test17 uses), scrolls to the Episodes section and looks for the poster
    /// selector (`season_poster_<n>` identifiers). Skips loudly when the opened title is not a
    /// multi-season series or TMDB season posters are off, rather than failing on data.
    func test33SeasonPosterRow() throws {
        let app = launchToHome(forceFreshLaunch: true)
        press(.down, times: 3)          // hero → CW → Streaming → first catalog row
        let anyPoster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'season_poster_'"))
        let anyChip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season '"))
        // Rows are a mix of movie and series catalogs on this account; walk down until a title
        // with a season selector opens (≤ 5 rows), backing out of anything else.
        var found = false
        for row in 0..<5 {
            press(.left, times: 6, gap: 0.3)
            pause(1.0)
            remote.press(.select)
            pause(7)
            shot(app, "33a_row\(row)_detail_opened")
            press(.down, times: 3, gap: 1.0)
            pause(1.5)
            if anyPoster.count > 0 || anyChip.count > 0 { found = true; break }
            // Not a series: back to Home (Menu pops the pushed Detail) and try the next row.
            remote.press(.menu)
            pause(2)
            press(.down, times: 1)
        }
        guard found else { throw XCTSkip("no multi-season series found in the first five rows — nothing to verify") }
        shot(app, "33b_detail_episodes")
        if anyPoster.count == 0 {
            throw XCTSkip("season selector rendered as text chips — no TMDB season posters for this title (useSeasonPosters off or none returned)")
        }
        // The Down walk lands on the episode row (below the selector); the selector is one Up away.
        if !moveFocus(.up, until: anyPoster.firstMatch, max: 3) { _ = moveFocus(.down, until: anyPoster.firstMatch, max: 3) }
        pause(1)
        shot(app, "33c_season_posters_focused")
        XCTAssertGreaterThanOrEqual(anyPoster.count, 2, "poster selector should show one card per season")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Appearance baseline restore (state-aware; safe to run any time)

    /// Puts the signed-in sim profile's SYNCED appearance state back to the suite's baseline:
    /// Ocean theme, Landscape Rows OFF, Hide Titles OFF, Card Depth OFF, plus the two local
    /// focus toggles OFF. Every step is state-aware (reads the row's accessibility value / the
    /// swatch's selection), so it is idempotent. Run it after any failed appearance test — a
    /// mis-landed walk in test27/28 once flipped Landscape Rows and the theme on the real
    /// account (beta.13 wave 2), and every later screenshot lied about the layout.
    func test30AppearanceBaselineRestore() throws {
        let app = launchToHome(forceFreshLaunch: true)
        try restoreAppearanceBaseline(app)
        shot(app, "30_baseline_restored")
        XCTAssertTrue(app.state == .runningForeground)
    }

    private func restoreAppearanceBaseline(_ app: XCUIApplication) throws {
        let appearance = app.buttons["Appearance"]
        openTab(app, named: "Settings")
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)
        let sidebarX = appearance.frame.maxX
        // Theme → Ocean (swatches report focus; selecting the already-selected theme is a no-op).
        let ocean = app.buttons["Ocean"]
        let swatches = ["Crimson", "Ocean", "Violet", "Emerald", "Amber", "Rose", "White"]
        for _ in 0..<30 { // climb to the swatch row; NEVER past it (the tab bar is next)
            if swatches.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) { break }
            remote.press(.up)
            pause(0.4)
        }
        // Right FIRST: Ocean is the 2nd swatch, and Left from Crimson leaves the row for the
        // sidebar (whose focus SWITCHES panes) — the recording of the 2026-08-16 failure.
        if !moveFocus(.right, until: ocean, max: 6) { _ = moveFocus(.left, until: ocean, max: 6) }
        if ocean.exists && ocean.hasFocus {
            remote.press(.select)
            pause(2.5) // theme change re-identifies the tree; focus may land back on the sidebar
            if appearance.hasFocus { press(.right, times: 1); pause(1) }
        }
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "No Zoom on Focus", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "Hide Titles", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "Landscape Rows", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "Card Depth", on: false, sidebarMaxX: sidebarX, category: "Appearance")
    }

    // MARK: - UX-8: Hide Discover toggle round-trip

    /// Settings → Content Sources → "Hide Discover" ON ⇒ the Search tab must show NO Discover
    /// header; OFF again ⇒ it must come back (test19's existence check, inverted then restored).
    /// Toggle rows never report focus (test25), so `ensureToggleRow` walks by counted rows and
    /// asserts the row's accessibility value flipped — a mis-landed walk fails loudly.
    func test29HideDiscoverToggle() throws {
        let app = launchToHome(forceFreshLaunch: true)
        let contentSources = app.buttons["Content Sources"]
        func openContentSources() {
            openTab(app, named: "Settings")
            _ = moveFocus(.down, until: contentSources, max: 10)
            remote.press(.select)
            pause(1.5)
            press(.right, times: 1)
            pause(1)
        }
        openContentSources()
        let sidebarX = contentSources.frame.maxX
        try ensureToggleRow(app, labelPrefix: "Hide Discover", on: true, sidebarMaxX: sidebarX, category: "Content Sources")
        shot(app, "29a_hide_discover_on")

        openTab(app, named: "Search")
        pause(2.5)
        shot(app, "29b_search_without_discover")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 6), "Search tab not reached")
        XCTAssertFalse(app.staticTexts["Discover"].exists, "Discover header still on Search with Hide Discover ON")

        openContentSources()
        try ensureToggleRow(app, labelPrefix: "Hide Discover", on: false, sidebarMaxX: sidebarX, category: "Content Sources")
        openTab(app, named: "Search")
        pause(2.5)
        shot(app, "29c_search_with_discover_again")
        XCTAssertTrue(app.staticTexts["Discover"].waitForExistence(timeout: 8), "Discover did not return after Hide Discover OFF")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - FEAT-18: in-tile title while the focus trailer plays (Hide Titles on)

    /// Screenshot probe (asserts liveness + that the settings walk landed): the reporter runs
    /// Hide Titles (`p2qudtq` t22 — no captions under any card), so the playing trailer tile
    /// carried no title. FEAT-18 draws the logo/name ON the tile in that configuration. Walk:
    /// Hide Titles ON through the real pane (synced poster-style payload — restored at the end),
    /// Home, dwell on the first movies-row card past the morph + resolve, capture; then restore.
    /// Compare 28b (still art + overlay) / 28c (playing + overlay) — the bottom-left of the wide
    /// tile must carry a logo or the title text over a dark foot scrim.
    func test28InlineTrailerTitleOverlayWithHiddenLabels() throws {
        let app = launchToHome(extraArguments: ["-inline_trailers_enabled", "YES", "-debug.trailerProbe", "YES"], forceFreshLaunch: true)
        try restoreAppearanceBaseline(app) // portrait rows, no ring — the reporter's row shape
        let appearance = app.buttons["Appearance"]
        func openAppearance() {
            openTab(app, named: "Settings")
            _ = moveFocus(.down, until: appearance, max: 10)
            remote.press(.select)
            pause(1.5)
            press(.right, times: 1)
            pause(1)
        }
        openAppearance()
        let sidebarX = appearance.frame.maxX
        try ensureToggleRow(app, labelPrefix: "Hide Titles", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        shot(app, "28a_hide_titles_toggled_on")

        openTab(app, named: "Home")
        press(.down, times: 3)          // openTab already stepped into content: hero → CW → Streaming → first movies row
        press(.left, times: 6, gap: 0.3) // first card of the row
        pause(2.5) // dwell (1s) + morph
        shot(app, "28b_expanded_still_with_title_overlay")
        pause(6)
        shot(app, "28c_playing_with_title_overlay")

        openAppearance()
        try ensureToggleRow(app, labelPrefix: "Hide Titles", on: false, sidebarMaxX: sidebarX, category: "Appearance")
        shot(app, "28d_hide_titles_restored_off")
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-57: Card Depth "Top" vs "Full" coverage A/B (reporter's config)

    /// Screenshot probe (asserts liveness + landed walks): drives the REAL Appearance pane — the
    /// only valid A/B for a profile-synced payload (prefs injection is overwritten by sync at
    /// launch, beta.12 lesson) — into the reporter's configuration (u/mrStevenx3, `p2qudtq`
    /// t73.5: Accent Focus Ring ON, No Zoom on Focus ON), turns Card Depth on with the Bold edge,
    /// and captures Home rows at Edge Coverage = Top ("En haut" — the reporter's "upwards") and
    /// again at Full. Restores: depth section reset, both toggles back OFF (state-aware, so a
    /// re-run after a failure cannot invert leftover state). Human/agent compares 27b vs 27d
    /// against the mobile app's Top rendering (a full-perimeter outline whose alpha ramps
    /// top→bottom, `composeApp/.../CardDepthEffect.kt`).
    func test27CardDepthCoverageAB() throws {
        let app = launchToHome(forceFreshLaunch: true)
        let appearance = app.buttons["Appearance"]
        func openAppearance() {
            openTab(app, named: "Settings")
            _ = moveFocus(.down, until: appearance, max: 10)
            remote.press(.select)
            pause(1.5)
            press(.right, times: 1)
            pause(1)
        }
        // Chip rows keep the column you arrive in — walk to the row, then Left/Right by chip
        // (chips DO report focus).
        func selectChip(_ name: String, rowPrefix: String, sidebarX: CGFloat) throws {
            try walkToRowByTreeIndex(app, targetLabelPrefix: rowPrefix, sidebarMaxX: sidebarX, category: "Appearance")
            let chip = app.buttons[name]
            // Chips report focus: prove the walk landed on the row before sliding along it.
            let rowChips = ["Subtle", "Balanced", "Bold", "Off", "Soft", "Bright", "Top", "Half", "Full"]
            guard rowChips.contains(where: { app.buttons[$0].exists && app.buttons[$0].hasFocus }) else {
                XCTFail("walk to chip row '\(rowPrefix)' did not land on a chip row"); return
            }
            // Right FIRST: Left from the leftmost chip leaves the row for the sidebar (pane
            // switch), while Right past the last chip is a no-op.
            if !moveFocus(.right, until: chip, max: 4) { _ = moveFocus(.left, until: chip, max: 4) }
            guard chip.exists && chip.hasFocus else { XCTFail("chip \(name) never focused"); return }
            remote.press(.select)
            pause(0.8)
        }

        try restoreAppearanceBaseline(app) // Ocean, portrait rows, everything OFF — a known start
        openAppearance()
        let sidebarX = appearance.frame.maxX
        try ensureToggleRow(app, labelPrefix: "Accent Focus Ring", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        try ensureToggleRow(app, labelPrefix: "No Zoom on Focus", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        shot(app, "27a_ring_and_nozoom_on")
        try ensureToggleRow(app, labelPrefix: "Card Depth", on: true, sidebarMaxX: sidebarX, category: "Appearance")
        XCTAssertTrue(app.buttons["Top"].waitForExistence(timeout: 2), "Edge Coverage chips never appeared — Card Depth not on")
        // The chip rows are labelled by their first chip in the AX tree — anchor on "Subtle"
        // (edge row) and "Top" (coverage row).
        try selectChip("Bold", rowPrefix: "Subtle", sidebarX: sidebarX)
        try selectChip("Top", rowPrefix: "Top", sidebarX: sidebarX)
        shot(app, "27a2_depth_bold_top_selected")

        openTab(app, named: "Home")
        press(.down, times: 3, gap: 1.0)
        pause(3)
        shot(app, "27b_home_rows_depth_TOP")
        press(.right, times: 1)
        pause(1.5)
        shot(app, "27b2_home_rows_depth_TOP_second_card")

        openAppearance()
        try selectChip("Full", rowPrefix: "Top", sidebarX: sidebarX)
        shot(app, "27c_depth_full_selected")
        openTab(app, named: "Home")
        press(.down, times: 3, gap: 1.0)
        pause(3)
        shot(app, "27d_home_rows_depth_FULL")

        // Restore everything (depth OFF, both focus toggles OFF, theme) through the shared
        // state-aware baseline — the same routine test30 runs standalone.
        try restoreAppearanceBaseline(app)
        shot(app, "27e_restored")
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Moves focus to the pane row whose label starts with `targetLabelPrefix` — a row that does
    /// NOT report focus to XCUITest (SettingsToggleRow, test25) — by COUNTING ROWS in the AX
    /// tree. Precondition: focus is on the pane's FIRST row (just pressed Right from the
    /// sidebar). Rows are grouped by frame.minY (chip rows hold several buttons side by side but
    /// are ONE row for Down/Up), so Downs = row-index distance. Lazy culling means the target
    /// may not be in the tree from the top: then hop to the LAST materialised row (its label is
    /// known and it is on-screen after the hop, so it is re-findable), re-capture, repeat.
    /// Landing on a chip row leaves focus in the same column it came from — callers that need a
    /// specific chip walk Left/Right afterwards with `moveFocus` (chips report focus).
    private func walkToRowByTreeIndex(_ app: XCUIApplication, targetLabelPrefix: String, sidebarMaxX: CGFloat, category: String) throws {
        let tabNames: Set<String> = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
        func rows() -> [[XCUIElement]] {
            let pane = app.buttons.allElementsBoundByIndex
                // Past the sidebar, and NOT the tab bar (its buttons also sit right of the sidebar
                // and once counted as "row 0" of the pane — beta.13 wave 2 finding).
                .filter { $0.frame.minX > sidebarMaxX + 20 && $0.frame.width > 0 && !tabNames.contains($0.label) && $0.frame.minY > 90 }
                .sorted { $0.frame.minY < $1.frame.minY }
            var out: [[XCUIElement]] = []
            for b in pane {
                if let last = out.last?.first, abs(last.frame.minY - b.frame.minY) < 6 {
                    out[out.count - 1].append(b)
                } else {
                    out.append([b])
                }
            }
            return out
        }
        // Where is focus NOW? Right from the sidebar lands on the pane row NEAREST the sidebar
        // item's Y (tvOS focus engine), not on the first row — so never assume row 0. Toggle
        // rows don't report focus, but chip/swatch buttons do: press Up one row at a time until
        // some pane button reports focus and take its row as the anchor; past the top Up is a
        // no-op, so if nothing ever reports we are at row 0 anyway.
        func inPane(_ e: XCUIElement) -> Bool { e.frame.minX > sidebarMaxX + 20 && !tabNames.contains(e.label) && e.frame.minY > 90 }
        // Anchor: the row containing the focused element (by FRAME, not label — the Appearance
        // pane repeats labels: two "Reset to Defaults", "Off"/"Default" chips). Toggle rows don't
        // report focus, but chips/swatches do; Up one row at a time until something reports.
        func focusedRowIndex(_ r: [[XCUIElement]]) -> Int? {
            guard let f = focusedButton(app), inPane(f) else { return nil }
            let y = f.frame.minY
            return r.firstIndex(where: { row in abs(row[0].frame.minY - y) < 6 })
        }
        var anchorLabel: String? = nil // set after a hop; looked up with lastIndex (hops only go down)
        if focusedButton(app).map(inPane) != true {
            for _ in 0..<24 {
                if let f = focusedButton(app), tabNames.contains(f.label) {
                    remote.press(.down); pause(0.8)
                    if let g = focusedButton(app), inPane(g) { break }
                    continue
                }
                if let f = focusedButton(app), f.frame.minX <= sidebarMaxX + 20 {
                    let cat = app.buttons[category]
                    if f.label != category {
                        if !moveFocus(.down, until: cat, max: 8) { _ = moveFocus(.up, until: cat, max: 8) }
                        pause(1)
                    }
                    remote.press(.right); pause(0.8)
                    if let g = focusedButton(app), inPane(g) { break }
                    continue
                }
                remote.press(.up); pause(0.35)
                if let f = focusedButton(app), inPane(f) { break }
            }
        }
        for _ in 0..<10 {
            let r = rows()
            guard !r.isEmpty else { throw XCTSkip("no pane buttons in the AX tree") }
            let from = focusedRowIndex(r)
                ?? anchorLabel.flatMap { label in r.lastIndex(where: { row in row.contains { $0.label == label } }) }
                ?? 0
            if let targetIndex = r.firstIndex(where: { row in row.contains { $0.label.hasPrefix(targetLabelPrefix) } }) {
                let delta = targetIndex - from
                if delta > 0 { press(.down, times: delta, gap: 0.6) }
                if delta < 0 { press(.up, times: -delta, gap: 0.6) }
                pause(0.8)
                return
            }
            // Hop to the LAST row whose label is unique in this capture (so it is re-findable).
            let labels = r.map { $0[0].label }
            guard let hop = (0..<r.count).reversed().first(where: { i in i > from && labels.filter { $0 == labels[i] }.count == 1 }) else { break }
            press(.down, times: hop - from, gap: 0.6)
            anchorLabel = labels[hop]
            pause(0.8)
        }
        XCTFail("row '\(targetLabelPrefix)…' never materialised in the pane")
    }

    /// State-aware toggle: walks to the `SettingsToggleRow` whose label starts with
    /// `labelPrefix` and presses Select ONLY if its "On ·"/"Off ·" subtitle disagrees with
    /// `on`. Idempotent, so a re-run after a failed run cannot invert leftover state. Asserts
    /// the resulting label loudly. Precondition/postcondition as `walkToRowByTreeIndex`.
    private func ensureToggleRow(_ app: XCUIApplication, labelPrefix: String, on: Bool, sidebarMaxX: CGFloat, category: String) throws {
        let row = { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch }
        try walkToRowByTreeIndex(app, targetLabelPrefix: labelPrefix, sidebarMaxX: sidebarMaxX, category: category)
        guard row().exists else { XCTFail("toggle '\(labelPrefix)' missing"); return }
        func isOn() -> Bool { (row().value as? String) == "On" }
        if isOn() != on {
            remote.press(.select)
            pause(1.5)
        }
        XCTAssertEqual(isOn(), on, "toggle '\(labelPrefix)' did not end up \(on ? "ON" : "OFF"): value=\(String(describing: row().value))")
    }

    // MARK: - Home "Upcoming" row (next airing episodes of followed shows)

    /// The Upcoming row renders under Continue Watching with one card per followed show carrying
    /// an S00E00 code and a TODAY / TOMORROW / IN N DAYS pill, and selecting a card pushes the
    /// show's Detail page. Data-dependent: the signed-in profile must follow a show with an
    /// episode inside the 14-day horizon — if the row never appears the test SKIPS loudly (not
    /// a vacuous pass); if it appears its cards must carry the badges.
    func test34UpcomingRow() throws {
        let app = launchToHome(forceFreshLaunch: true)
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2)

        // Cards are NavigationLinks whose composed label carries the badges — the row's own
        // signature (the title alone can be in the tree a row early: the LazyVStack mounts the
        // next row while the previous one is focused, more so in pinned mode).
        let badgePredicate = NSPredicate(
            format: "label MATCHES[c] '.*S[0-9]{2}E[0-9]{2}.*' AND (label CONTAINS[c] 'TODAY' OR label CONTAINS[c] 'TOMORROW' OR label MATCHES[c] '.*IN [0-9]+ DAYS.*')"
        )
        let title = app.staticTexts["Upcoming"]
        let badgeCards = app.buttons.matching(badgePredicate)
        let badgeCard = badgeCards.firstMatch

        // Walk down one row at a time until a badge card HOLDS focus — ANY of them: vertical
        // focus travel keeps the column, so entering the row from CW's 4th card lands on the
        // row's 4th card (26.5 runtime reports focus; on 27.0 `hasFocus` never reads true —
        // fall back to "title + card exist" like the other existence-driven walks). CW sits
        // above; catalog rows below.
        var downs = 0
        var cardFocused = false
        var mounted = false
        while downs < 9 {
            press(.down, times: 1)
            downs += 1
            pause(1.0)
            if badgeCards.allElementsBoundByIndex.contains(where: { $0.hasFocus }) { cardFocused = true; break }
            // 27.0-runtime fallback (no focus reports): the row mounts one step before focus
            // reaches it (it is the row after the one focused), so stop at the first step where
            // it exists and take exactly one more Down — never walk on past it.
            if title.exists && badgeCard.exists { mounted = true; break }
        }
        if !cardFocused {
            guard mounted else {
                shot(app, "34_no_upcoming_row")
                throw XCTSkip("no Upcoming row within \(downs) rows — does the profile follow a show airing in the next 14 days?")
            }
            press(.down, times: 1)
            pause(1.0)
        }
        pause(1.5)
        shot(app, "34a_upcoming_row")
        XCTAssertTrue(badgeCard.exists, "no Upcoming card with an S00E00 code + air-date pill in the tree")

        // Select → the show's Detail page (a pushed screen: the root tab bar leaves the tree's
        // visible band). Menu pops back.
        remote.press(.select)
        pause(4)
        shot(app, "34b_detail_from_upcoming")
        let homeTab = app.buttons["Home"]
        XCTAssertTrue(!homeTab.exists || homeTab.frame.minY <= 0, "selecting an Upcoming card should push Detail (tab bar off-screen)")
        remote.press(.menu)
        pause(2)
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Self-hosted server discovery (review step, non-destructive)

    /// Settings → Account & Services → "Connect to a Self-Hosted Server" → type the URL of a
    /// loopback stub serving `/.well-known/nuvio` → "Check Server" → the REVIEW step must show
    /// the discovered backend. Also exercises the typed-error path (the official host is
    /// refused with the "already selected" copy) and that Back returns to the entry step.
    /// DELIBERATELY never presses "Connect to This Server" — a switch signs the account out
    /// and wipes local data on the signed-in sim; the destructive half lives in
    /// `ScratchServerSwitchTests` (scratch-device only).
    func test35ServerDiscoveryReview() throws {
        let stub = DiscoveryStubServer(document: .init(emailPasswordAuth: true, tvLogin: false))
        try stub.start()
        defer { stub.stop() }

        let app = launchToHome(forceFreshLaunch: true)
        openTab(app, named: "Settings")
        let account = app.buttons["Account & Services"]
        if !(account.exists && account.hasFocus) { _ = moveFocus(.up, until: account, max: 8) }
        remote.press(.select)
        pause(1.2)
        press(.right, times: 1)
        pause(1)
        let sidebarX = account.frame.maxX
        shot(app, "35a_account_pane")

        // The Server section sits right under Account; walk there by tree index.
        try walkToRowByTreeIndex(app, targetLabelPrefix: "Connect to a Self-Hosted Server", sidebarMaxX: sidebarX, category: "Account & Services")
        let connectRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connect to a Self-Hosted Server'")).firstMatch
        guard connectRow.exists else { XCTFail("Server section row missing from Account & Services"); return }
        remote.press(.select)
        pause(1.5)

        let urlField = app.textFields["server.url"]
        guard urlField.waitForExistence(timeout: 6) else {
            shot(app, "35x_no_cover")
            XCTFail("ServerConnectionView cover did not appear")
            return
        }
        shot(app, "35b_server_enter")

        // 1) Negative path: the official host is refused with a typed error.
        func enterUrl(_ text: String) -> Bool {
            if !urlField.hasFocus { _ = moveFocus(.up, until: urlField, max: 6) }
            remote.press(.select)
            pause(2) // full-screen keyboard
            // Clear anything pre-filled (a custom server's discovery base is pre-filled when
            // one is active; on the official sim it is empty) — select-all isn't available on
            // the tvOS keyboard, so only proceed when the field is empty.
            let typed = typeOnKeyboard(app, text)
            remote.press(.menu) // commit + dismiss the keyboard (the typed text stays in the field)
            pause(1.5)
            return typed
        }
        guard enterUrl("https://api.nuvio.tv") else {
            XCTFail("could not type into the server URL field (keyboard not driveable)")
            return
        }
        let check = app.buttons["server.check"]
        guard check.waitForExistence(timeout: 4) else { XCTFail("Check Server button missing"); return }
        // Down from the field can land on either button of the row (focus-engine geometry);
        // glass buttons don't reliably report focus, so pin it: Down, then Left twice (Check
        // Server is the leftmost control of the row, Left past it is a no-op).
        func focusCheckServer() { press(.down, times: 1); press(.left, times: 2, gap: 0.5) }
        focusCheckServer()
        remote.press(.select)
        pause(2)
        let officialError = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "official server")).firstMatch
        XCTAssertTrue(officialError.waitForExistence(timeout: 8), "typing the official host must surface the 'official server' discovery error")
        shot(app, "35c_official_refused")

        // 2) Happy path against the loopback stub. The field still holds the official URL —
        // Menu-commit keeps the text — so re-open the keyboard and replace it: tvOS keyboards
        // have a clear ("Clear") key; fall back to appending if clearing isn't reachable.
        if !urlField.hasFocus { _ = moveFocus(.up, until: urlField, max: 6) }
        remote.press(.select)
        pause(2)
        let clearKey = app.keys["Clear"]
        if clearKey.waitForExistence(timeout: 2) {
            if !clearKey.hasFocus { _ = moveFocus(.right, until: clearKey, max: 14) || moveFocus(.down, until: clearKey, max: 6) }
            if clearKey.hasFocus { remote.press(.select); pause(0.5) }
        }
        let value = (urlField.value as? String) ?? ""
        if !value.isEmpty && value != "https://backend.example.com" {
            // Could not clear; delete character by character via the hardware-keyboard path.
            for _ in 0..<value.count { app.typeText(XCUIKeyboardKey.delete.rawValue) }
            pause(0.5)
        }
        _ = typeOnKeyboard(app, stub.origin)
        remote.press(.menu)
        pause(1.5)
        let entered = (urlField.value as? String) ?? ""
        guard entered.contains("127.0.0.1") else {
            shot(app, "35x_url_not_entered")
            XCTFail("stub URL not entered (field value = \(entered))")
            return
        }
        focusCheckServer()
        remote.press(.select)

        let reviewTitle = app.staticTexts["server.review"]
        guard reviewTitle.waitForExistence(timeout: 20) else {
            shot(app, "35x_no_review")
            XCTFail("review step never appeared — stub saw \(stub.requestLog)")
            return
        }
        shot(app, "35d_server_review")
        let backend = app.staticTexts["server.backend"]
        XCTAssertTrue(backend.exists && backend.label.contains("127.0.0.1:\(stub.port)"), "review must show the discovered backend (got \(backend.exists ? backend.label : "nil"))")
        XCTAssertTrue(app.buttons["server.connect"].exists, "Connect to This Server must be offered")
        XCTAssertTrue(stub.requestLog.contains("GET /.well-known/nuvio"), "the app must have fetched the discovery document (log: \(stub.requestLog))")
        // tv_login=false → the review must say QR sign-in is not available.
        XCTAssertTrue(app.staticTexts["Not available"].exists, "QR sign-in capability must read Not available for a tv_login=false document")

        // Back → entry step again (no switch happened).
        let back = app.buttons["Back"]
        if back.exists {
            // Back is the rightmost control of the review's button row.
            press(.down, times: 8, gap: 0.4)
            press(.right, times: 2, gap: 0.5)
            remote.press(.select)
            pause(1.5)
            XCTAssertTrue(urlField.waitForExistence(timeout: 5), "Back must return to the URL entry step")
        }
        shot(app, "35e_back_to_enter")
        remote.press(.menu) // dismiss the cover
        pause(1.5)
        XCTAssertTrue(app.state == .runningForeground)
        // Still signed in: the Account & Services pane's Sign Out row must still be around.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sign Out'")).firstMatch.waitForExistence(timeout: 6), "the non-destructive flow must leave the account signed in")
    }


    // MARK: - BUG-58: theme swatch label must stay legible while focused

    /// BUG-58 (beta.11 regression from the BUG-50 sweep): the focused theme swatch's name was
    /// painted `onFocusPlatter` (near-black) on the assumption that the `.borderless` swatch
    /// button draws the white system focus platter. It doesn't — the label landed straight on
    /// the dark pane and vanished ("Amber" disappears while it has focus; Christian's device
    /// clip, 2026-08-16). This walks focus onto a swatch and MEASURES the label band under it in
    /// the screenshot: it must contain bright (textPrimary-class) pixels. Pre-fix the band's
    /// brightest pixel was the pane background (~0.05 luma); post-fix it is the label (~0.9).
    /// Skips (loudly) if the swatch never reports focus (tvOS 27.0 runtime gotcha) rather than
    /// passing vacuously.
    func test26ThemeSwatchFocusedLabelLegible() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        // Violet is neither the account's selected theme (Ocean) nor an edge swatch, so its
        // at-rest label is textSecondary and the focused read is purely the isFocused branch.
        let violet = app.buttons["Violet"]
        if !moveFocus(.right, until: violet, max: 8) { _ = moveFocus(.left, until: violet, max: 8) }
        guard violet.exists, violet.hasFocus else {
            throw XCTSkip("Violet swatch never reported focus — cannot measure the focused label")
        }
        pause(1) // let the focus lift + label color animation settle
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "26a_violet_swatch_focused"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Label band = the bottom third of the swatch button (circle 56pt + caption below it),
        // inset horizontally so the neighbouring swatches' labels never leak in.
        let frame = violet.frame
        let band = CGRect(
            x: frame.minX + frame.width * 0.15,
            y: frame.minY + frame.height * 0.62,
            width: frame.width * 0.70,
            height: frame.height * 0.36
        )
        let stats = try lumaStats(in: screenshot.image, pointRect: band, windowSize: app.frame.size)
        let report = XCTAttachment(string: "band=\(band) max=\(stats.max) brightFraction=\(stats.brightFraction)")
        report.name = "26b_label_band_luma"
        report.lifetime = .keepAlways
        add(report)
        print("[BUG58] focused Violet label band: max luma \(stats.max), bright fraction \(stats.brightFraction)")
        XCTAssertGreaterThan(
            stats.max, 0.7,
            "focused swatch label is not legible — brightest pixel under the focused swatch is \(stats.max) (BUG-58 regression: label painted platter-black on the dark pane)"
        )
        XCTAssertGreaterThan(
            stats.brightFraction, 0.005,
            "focused swatch label band has almost no bright pixels (\(stats.brightFraction))"
        )
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - BUG-65: Appearance toggle rows must keep dark text on the focus platter

    /// BUG-65 (beta.13, u/mrStevenx3's review video t=133.5): on HIS DEVICE the focused "Anneau
    /// de focus couleur d'accent" row renders as a white platter with near-invisible light
    /// title/subtitle. Calibration finding (2026-08-20, three sim runs): the 26.5 SIM does NOT
    /// reproduce the white-out — the focused row renders dark-on-platter here in every run,
    /// measuring a dark-pixel fraction of ~0.013 (the title is a thin line in a wide platter
    /// band). So this guard's job in the sim is regression-catching only: a healthy row measures
    /// ≥ ~0.013 dark; a white-out measures ≈ 0. The threshold sits between the two. Toggle rows
    /// never report `hasFocus` on this runtime (beta.13 harness lesson), so the probe keys off
    /// the measured platter instead and skips loudly if no platter is ever seen.
    func test36AppearanceToggleRowFocusedContrast() throws {
        let app = launchToHome()
        openTab(app, named: "Settings")
        let appearance = app.buttons["Appearance"]
        _ = moveFocus(.down, until: appearance, max: 10)
        remote.press(.select)
        pause(1.5)
        press(.right, times: 1)
        pause(1)

        let ringRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Accent Focus Ring")
        ).firstMatch
        guard ringRow.waitForExistence(timeout: 6) else {
            throw XCTSkip("Accent Focus Ring row never appeared — pane navigation failed")
        }

        // Walk down from the swatch row toward the toggle rows, measuring the ring row's band at
        // each rest. The focused step is the one where the band's mean luma jumps (white platter).
        var platterSeen = false
        var worstDarkFraction = 1.0
        for step in 0..<6 {
            if step > 0 { press(.down, times: 1) }
            pause(1)
            guard ringRow.exists else { break }
            let frame = ringRow.frame
            let band = frame.insetBy(dx: frame.width * 0.05, dy: frame.height * 0.12)
            let profile = try lumaProfile(in: XCUIScreen.main.screenshot().image, pointRect: band, windowSize: app.frame.size)
            print("[BUG65] step \(step): ring row band mean=\(profile.mean) dark=\(profile.darkFraction) bright=\(profile.brightFraction)")
            if profile.mean > 0.55 {
                platterSeen = true
                worstDarkFraction = min(worstDarkFraction, profile.darkFraction)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "36_ring_row_platter_step\(step)"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
        guard platterSeen else {
            throw XCTSkip("the ring row never showed a focus platter — focus walk missed it; cannot measure")
        }
        XCTAssertGreaterThan(
            worstDarkFraction, 0.004,
            "focused Appearance toggle row is white-on-white: platter present but only \(worstDarkFraction) of the band is dark label-class pixels (BUG-65; a legible row measures ~0.013)"
        )
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Mean luma plus dark (<0.35) and bright (>0.7) pixel fractions inside `pointRect`.
    /// Same coordinate/scaling contract as `lumaStats`.
    private func lumaProfile(in image: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> (mean: Double, darkFraction: Double, brightFraction: Double) {
        guard let cg = image.cgImage, windowSize.width > 0 else {
            throw XCTSkip("screenshot has no CGImage / zero window size")
        }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(
            x: pointRect.minX * scale, y: pointRect.minY * scale,
            width: pointRect.width * scale, height: pointRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else {
            throw XCTSkip("band \(pointRect) is off-screen")
        }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0
        var dark = 0
        var bright = 0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let l = (0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])) / 255.0
            total += l
            if l < 0.35 { dark += 1 }
            if l > 0.7 { bright += 1 }
        }
        let count = Double(w * h)
        return (total / count, Double(dark) / count, Double(bright) / count)
    }

    /// Max relative luma and the fraction of pixels above 0.7 luma inside `pointRect` (in the
    /// app window's point space) of a full-screen screenshot. Scales points→pixels from the
    /// screenshot/window width ratio (sim screenshots are exactly 2 px/pt).
    private func lumaStats(in image: UIImage, pointRect: CGRect, windowSize: CGSize) throws -> (max: Double, brightFraction: Double) {
        guard let cg = image.cgImage, windowSize.width > 0 else {
            throw XCTSkip("screenshot has no CGImage / zero window size")
        }
        let scale = CGFloat(cg.width) / windowSize.width
        let px = CGRect(
            x: pointRect.minX * scale, y: pointRect.minY * scale,
            width: pointRect.width * scale, height: pointRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let cropped = cg.cropping(to: px) else {
            throw XCTSkip("label band \(pointRect) is off-screen")
        }
        let w = cropped.width, h = cropped.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("could not build a bitmap context") }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var maxLuma = 0.0
        var bright = 0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let l = (0.2126 * Double(buffer[i]) + 0.7152 * Double(buffer[i + 1]) + 0.0722 * Double(buffer[i + 2])) / 255.0
            if l > maxLuma { maxLuma = l }
            if l > 0.7 { bright += 1 }
        }
        return (maxLuma, Double(bright) / Double(w * h))
    }

    /// The trailing SeeAllCard as an element query. Its composed accessibility label is NOT the
    /// bare string "See All" (the card's empty caption-alignment slot joins in), so an exact
    /// `app.buttons["See All"]` subscript never matches on any runtime — every earlier "green"
    /// that gated on it was skipping (Codex round 1's vacuous-pass finding).
    private func seeAllCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "See All")).firstMatch
    }

    /// Walks Right until `element` exists in the accessibility tree (a lazily-mounted trailing
    /// card materializes only as focus nears it), pressing at most `max` times. Deliberately NOT
    /// focus-driven — see test23's comment on tvOS 27.0 focus reporting.
    @discardableResult
    private func walkRightUntilExists(_ element: XCUIElement, max: Int) -> Bool {
        if element.exists { return true }
        for _ in 0..<max {
            remote.press(.right)
            pause(0.6)
            if element.exists { return true }
        }
        return false
    }

    // MARK: - trailer_playback_location: hero vs poster

    /// `trailer_playback_location` (`HomeView.swift`'s `@AppStorage` key, default "poster") picks
    /// WHERE "Trailers on Focus" plays a focused title's trailer: the classic poster morph
    /// (unchanged pre-existing behavior, covered by test01), or the pinned hero backdrop —
    /// `heroFocusTrailerMode` only engages the hero surface when the container is actually
    /// pinned (`-hero_nuvio_style YES`, same as test22/test31), so that argument travels with
    /// both legs here.
    ///
    /// Reuses `TrailerSoakTests`' deterministic-row-geometry recipe (forced smoke video id,
    /// `-home_upcoming_row_enabled NO` so the down×4 walk to the first movies row is the same
    /// pre-Upcoming layout test01/TrailerSoakTests' walks were written against — those run
    /// UNPINNED; the pinned variant of the same walk is validated here, not by that precedent —
    /// plus the location knob. Both
    /// legs are fresh launches (`forceFreshLaunch: true`, same rationale as test20/22/31) so
    /// neither inherits the other's focus/dwell state.
    ///
    /// `debug_hero`'s two appended fields (HomeView.swift) are the oracle: `tloc=h|p` is the
    /// trailer location the rows are actually rendering under, `hph=idle|dwell|exp|play` the
    /// hero trailer model's live phase (see `debugHeroTrailerPhase`). Hero location must show
    /// `tloc=h` and the model advancing past idle; poster location must show `tloc=p` and the
    /// pre-existing 16:9 morph on the focused card.
    func test37TrailerLocationHero() throws {
        // Same known bar-free trailer id TrailerSoakTests.smokeVideoId forces (duplicated, not
        // shared — see TrailerSoakTests' type doc on why cross-file test helpers stay copied).
        let smokeVideoId = "rNZ0xKaCdus"
        func heroLocationArguments(_ location: String) -> [String] {
            [
                "-inline_trailers_enabled", "YES",
                "-debug.trailerProbe", "YES",
                "-debug.trailerSmokeVideoId", smokeVideoId,
                // Deterministic row geometry (TrailerSoakTests' trick): removes the Upcoming row
                // so the down×4 walk below has a stable target.
                "-home_upcoming_row_enabled", "NO",
                "-trailer_playback_location", location,
                "-hero_nuvio_style", "YES",
            ]
        }

        /// Walks down×4 to the first movies row (test01/TrailerSoakTests' walk, run pinned
        /// here), snapshots the pre-dwell focused card's frame, waits out the dwell gate (1s) +
        /// morph window, then the settle margin, and returns the PEAK width the card showed
        /// across both samples plus the debug_hero probe — the peak is the morph oracle, so a
        /// morph that fired and collapsed still registers.
        func measureDwell(_ app: XCUIApplication, _ tag: String) throws -> (before: CGFloat, peak: CGFloat, probe: String) {
            // Upcoming row forced off (see heroLocationArguments), so this is the pre-Upcoming
            // row geometry test01/TrailerSoakTests' down×4 walks were written against.
            press(.down, times: 4)
            // ONE .frame read, taken immediately: focusedButton's AX sweep plus repeated frame
            // reads can straddle the 1.0s dwell on a loaded sim, and a mid-morph baseline would
            // inflate `before` (failing leg 2 on a correct build) or flip the portrait guard
            // into an XCTSkip. Snapshot first, judge the snapshot after.
            guard let beforeButton = focusedButton(app) else {
                throw XCTSkip("no focused element reported before dwell (27.0 runtime never reports hasFocus)")
            }
            let beforeFrame = beforeButton.frame
            guard beforeFrame.width > 80, beforeFrame.height > beforeFrame.width else {
                throw XCTSkip("focused element before dwell is not a resting portrait poster — frame=\(beforeFrame)")
            }
            let widthBefore = beforeFrame.width
            shot(app, "\(tag)_00_before_dwell")

            // Codex pre-commit round 5: a single sample 3s out would false-pass a morph that
            // fired and then COLLAPSED (trailer resolution failure) — so sample once inside the
            // morph window (dwell 1.0s + morph 0.35s) and once after settle, and judge the MAX
            // width the card ever showed, not the final rest.
            pause(1.4) // dwell gate + morph window
            shot(app, "\(tag)_01_mid_window")
            let midWidth = focusedButton(app)?.frame.width ?? widthBefore
            pause(1.6) // focus commit delay + margin — let the morph (or hero handoff) settle
            shot(app, "\(tag)_02_after_dwell")

            guard let after = focusedButton(app) else {
                throw XCTSkip("focused card lost after the dwell wait")
            }
            let probe = heroSrcProbe(app, "\(tag)_03_probe")
            return (widthBefore, max(midWidth, after.frame.width), probe)
        }

        // Leg 1: hero location — the focused poster must NOT morph; the hero backdrop takes the
        // trailer instead.
        let heroApp = launchToHome(extraArguments: heroLocationArguments("hero"), forceFreshLaunch: true)
        let heroResult = try measureDwell(heroApp, "37a_hero")
        XCTAssertLessThanOrEqual(
            heroResult.peak, heroResult.before + 12,
            "poster width grew (morph fired) while trailer_playback_location=hero — before=\(heroResult.before) peak=\(heroResult.peak)"
        )
        XCTAssertTrue(heroResult.probe.contains(" tloc=h"), "trailer_playback_location=hero must set tloc=h on debug_hero, got: \(heroResult.probe)")

        // debug_hero must also show the hero trailer model took the attempt. Poll a few more
        // samples if the first one is still mid-resolve — same tolerant polling shape test20's
        // src=c/src=f walk uses — preferring the strongest signal (exp/play) but accepting dwell
        // as the floor, matching what TrailerSoakTests' own dwell-play-leave soak treats as the
        // reliably-observable attempt signal on a sim.
        var hphState = heroResult.probe
        var reachedAttemptPhase = hphState.contains("hph=exp") || hphState.contains("hph=play")
        if !reachedAttemptPhase {
            for i in 1...6 {
                pause(0.5)
                hphState = heroSrcProbe(heroApp, "37a_hero_hph_poll_\(i)")
                if hphState.contains("hph=exp") || hphState.contains("hph=play") {
                    reachedAttemptPhase = true
                    break
                }
            }
        }
        XCTAssertTrue(
            reachedAttemptPhase || hphState.contains("hph=dwell"),
            "hero trailer model never took the focus attempt (expected hph=exp/play, or at least hph=dwell) — got: \(hphState)"
        )
        XCTAssertTrue(heroApp.state == .runningForeground, "app must survive the hero-location leg")
        heroApp.terminate()
        pause(1.0)

        // Leg 2: poster location (the pre-existing default) — same walk, the poster DOES morph.
        let posterApp = launchToHome(extraArguments: heroLocationArguments("poster"), forceFreshLaunch: true)
        let posterResult = try measureDwell(posterApp, "37b_poster")
        XCTAssertGreaterThan(
            posterResult.peak, posterResult.before + 20,
            "poster width did not grow (no morph) while trailer_playback_location=poster — before=\(posterResult.before) peak=\(posterResult.peak)"
        )
        XCTAssertTrue(posterResult.probe.contains(" tloc=p"), "trailer_playback_location=poster must set tloc=p on debug_hero, got: \(posterResult.probe)")
        XCTAssertTrue(posterApp.state == .runningForeground, "app must survive the poster-location leg")
    }
}
