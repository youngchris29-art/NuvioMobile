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
    /// reaches the profile picker in ~20s). So when the app is already running and no launch
    /// arguments are needed, `activate()` it instead: pre-warm the sim with
    /// `xcrun simctl launch <udid> com.nuvio.media.NuvioTV` before the run and the suite attaches to
    /// that signed-in instance.
    @discardableResult
    private func launchToHome(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        let alreadyRunning = app.state == .runningForeground || app.state == .runningBackground
        if extraArguments.isEmpty && alreadyRunning {
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
            // e.g. test01 deliberately ends on a pushed DetailView). Pop back out with Menu,
            // re-front if a root-level Menu press exited to the springboard, then reselect the
            // Home tab so every test starts from the same top-of-Home state a fresh launch gives.
            for _ in 0..<4 {
                remote.press(.menu)
                pause(1.2)
                if app.state != .runningForeground {
                    app.activate()
                    pause(2)
                    break
                }
            }
            press(.up, times: 8, gap: 0.5)
            let homeTab = app.buttons["Home"]
            if !moveFocus(.left, until: homeTab, max: 8) {
                _ = moveFocus(.right, until: homeTab, max: 8)
            }
            remote.press(.select)
            pause(3)
            press(.down, times: 1)
            pause(1)
            return app
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
        press(.up, times: 8, gap: 0.5)
        let tab = app.buttons[title]
        if !moveFocus(.right, until: tab, max: 6) {
            _ = moveFocus(.left, until: tab, max: 8)
        }
        remote.press(.select)
        pause(2)
        press(.down, times: 1)
    }

    // MARK: - UX-2: trailers in thumbnails

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

    func test04SettingsRows() throws {
        let app = launchToHome()
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
    /// path from the Settings write path. 08a (hero CTA focused) must show the backdrop;
    /// 08b (focus down in the rows) must show the flat background. If 08b still shows
    /// artwork, the beta.8 CTA-button focus rewiring broke `heroFocused`.
    func test08HeroFocusOnlyToggle() throws {
        let app = launchToHome(extraArguments: ["-hero_poster_focus_only", "YES"])
        pause(4)
        press(.up, times: 6, gap: 0.5)
        press(.down, times: 1)
        pause(2) // fade-in animation + artwork load
        shot(app, "08a_hero_focused_art_visible")
        press(.down, times: 3, gap: 0.8)
        pause(2) // fade-out animation
        shot(app, "08b_rows_focused_art_hidden")
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
        let app = launchToHome()
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
        let app = launchToHome()
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
}
