import XCTest

/// UI leg for the Apple-style Detail page's season tabs (`EpisodeSeasonTabs` / `season_tab_<n>`,
/// episode cards `episode_card_<season>_<episode>`): Down from the hero lands on the VIEWED season's
/// tab, switching tabs leaves the hero alone, a quick Right-then-Down enters the new season, and Menu
/// from the shelf goes to the hero before it leaves the page.
///
/// Route: the DEBUG `-debug.openDeepLink` hook straight into Severance (Season 1, Season 2,
/// Specials), as `DetailChipRowScrollUITests` does, with the shared verified profile-picker step
/// (`DetailEntryRoute.selectChrisTile`) when the picker shows. TMDB is on for the launch only
/// through `-debug.tmdbEnabledOverride YES` (in memory, never synced).
///
/// Focus oracle: `XCUIElement.hasFocus` (FA87's tvOS 26.5 runtime reports it, the route's own
/// premise) read on the tab / card / hero button by identifier, cross-checked where useful with the
/// DEBUG `debug_detail_focus row=<row>` probe (`-debug.detailFocusProbe YES`; `-` = hero,
/// `episodes` = the Episodes section). Where a check rests on one of the two only, its comment
/// says so.
///
/// FA87 has no stream source, so Play reads "Playback unavailable" and is disabled: default focus
/// lands on Mark Watched, and "the hero action row" below means whichever of Play / Watched / the
/// other action buttons holds focus. A missing fixture (the Detail hero or its metadata never loads,
/// read from the probe's `meta=1` token, set once `model.meta` is non-nil) XCTSkips with its reason;
/// once the fixture is loaded, missing season tabs (Season 2 included) or no hero focus on entry
/// FAIL. Nothing here passes silently.
///
/// The profile is persistent, so Season 1's first episode may be watched: the shelf enters on the
/// season's first unwatched episode. The legs read the focused `episode_card_<s>_<e>` at runtime
/// instead of assuming episode 1.
final class DetailAppleSeasonTabsUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

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
        print("[SEASONTABS] \(name): \(text)")
    }

    private func press(_ button: XCUIRemote.Button, gap: TimeInterval = 0.8) {
        remote.press(button)
        pause(gap)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// `debug_detail_focus`'s `row=` token: `-` in the hero, `episodes` in the Episodes section.
    private func focusRow(_ app: XCUIApplication) -> String {
        let label = app.staticTexts["debug_detail_focus"]
        guard label.waitForExistence(timeout: 4) else { return "MISSING" }
        for part in label.label.split(separator: " ") where part.hasPrefix("row=") {
            return String(part.dropFirst(4))
        }
        return "?"
    }

    /// Identifiers of the hero's action buttons, in the row's order.
    private static let heroActionIDs = ["detail_action_play", "detail_action_watched", "detail_action_trailer",
                                        "detail_action_library", "detail_action_shuffle"]

    private func focusedHeroAction(_ app: XCUIApplication) -> String? {
        Self.heroActionIDs.first { element(app, $0).exists && element(app, $0).hasFocus }
    }

    /// Episode cards on the shelf, all seasons or one (`episode_card_<season>_…`).
    private func episodeCards(_ app: XCUIApplication, season: Int? = nil) -> XCUIElementQuery {
        let prefix = season.map { "episode_card_\($0)_" } ?? "episode_card_"
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    /// The identifier of the episode card holding focus, if any.
    private func focusedEpisodeCard(_ app: XCUIApplication) -> String? {
        episodeCards(app).allElementsBoundByIndex.first { $0.hasFocus }?.identifier
    }

    private func waitForCard(_ app: XCUIApplication, season: Int, timeout: TimeInterval) -> Bool {
        episodeCards(app, season: season).firstMatch.waitForExistence(timeout: timeout)
    }

    private func focusedSummary(_ app: XCUIApplication) -> String {
        var focused: [String] = []
        for id in Self.heroActionIDs + ["season_tab_1", "season_tab_2", "season_tab_0"]
        where element(app, id).exists && element(app, id).hasFocus {
            focused.append(id)
        }
        if let card = focusedEpisodeCard(app) { focused.append(card) }
        return "focused=[\(focused.joined(separator: ","))] row=\(focusRow(app))"
    }

    /// `debug_detail_focus`'s `play=` token: Play's target (`<videoId>|s<S>e<E>`), `-` when unknown.
    private func playTarget(_ app: XCUIApplication) -> String {
        let label = app.staticTexts["debug_detail_focus"]
        guard label.waitForExistence(timeout: 4) else { return "MISSING" }
        for part in label.label.split(separator: " ") where part.hasPrefix("play=") {
            return String(part.dropFirst(5))
        }
        return "?"
    }

    /// `debug_detail_focus`'s `meta=` token is `1` once the page's `model.meta` is loaded (the
    /// hero's meta-line and synopsis slots, and a preview synopsis, show before that).
    private func metaLoaded(_ app: XCUIApplication) -> Bool {
        let label = app.staticTexts["debug_detail_focus"]
        guard label.exists else { return false }
        return label.label.split(separator: " ").contains("meta=1")
    }

    /// Launches into Severance's Detail (Apple-style layout) and waits for the season tabs.
    private func launchToSeasonTabs() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-detail_layout", "apple", "-detail_trailer_autoplay", "NO",
                                "-detail_trailer_fullscreen_autoplay", "NO",
                                "-debug.tmdbEnabledOverride", "YES", "-debug.rememberLastProfile", "YES",
                                "-debug.detailFocusProbe", "YES",
                                "-debug.openDeepLink", "nuviotv://title?id=tt11280740&type=series&name=Severance"]
        app.launch()
        // rememberLastProfile YES normally skips the picker; if it shows anyway, take the verified step.
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        if chris.waitForExistence(timeout: 6) {
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        }
        // Fixture availability first: the Detail hero mounted and the title's metadata loaded
        // (`model.meta`, through the probe). Only a missing fixture skips.
        let hero = element(app, "detail_hero")
        guard hero.waitForExistence(timeout: 60) else {
            shot("seasontabs_no_page")
            throw XCTSkip("Severance's Detail page never opened within 60 s (deep link or profile step unavailable)")
        }
        var waited: TimeInterval = 0
        while !metaLoaded(app), waited < 45 {
            pause(1)
            waited += 1
        }
        guard metaLoaded(app) else {
            shot("seasontabs_no_meta")
            throw XCTSkip("Severance's Detail opened but its metadata never loaded within 45 s (no network or meta source)")
        }
        // The page and its metadata are there: missing season tabs (any of them) are a failure.
        waited = 0
        while !element(app, "season_tab_1").exists, waited < 30 {
            pause(1)
            waited += 1
        }
        pause(2)
        shot("seasontabs_opened")
        XCTAssertTrue(element(app, "season_tab_1").exists,
                      "Severance's Detail loaded its metadata but showed no season tabs (season_tab_1) within 30 s")
        XCTAssertTrue(element(app, "season_tab_2").exists,
                      "Severance's Detail loaded its metadata but shows no Season 2 tab (season_tab_2)")
        XCTAssertTrue(element(app, "season_tab_0").exists, "Severance should list Specials (season_tab_0) after the numbered seasons")
        return app
    }

    /// Down from the page's first focus until a season tab holds focus (the hero action row sits
    /// above; the default focus is the first enabled action). Returns false when it never gets there.
    private func walkDownToTabs(_ app: XCUIApplication) -> Bool {
        for _ in 0..<4 {
            if ["season_tab_1", "season_tab_2", "season_tab_0"].contains(where: { element(app, $0).hasFocus }) { return true }
            press(.down)
        }
        return ["season_tab_1", "season_tab_2", "season_tab_0"].contains { element(app, $0).hasFocus }
    }

    /// Text the hero shows for the title, the Play button's label and the synopsis teaser.
    private func heroSnapshot(_ app: XCUIApplication) -> (play: String, synopsis: String) {
        let play = element(app, "detail_action_play")
        let teaser = element(app, "detail_synopsis_teaser")
        return (play.exists ? play.label : "<no play>", teaser.exists ? teaser.label : "<no teaser>")
    }

    // MARK: - Legs

    /// Down from the hero action row lands on the VIEWED season's tab (Season 1), not on Specials,
    /// which is the last tab and the one a plain nearest-focus move could pick.
    func testDownFromHeroLandsOnSelectedSeasonTab() throws {
        let app = try launchToSeasonTabs()
        guard let start = focusedHeroAction(app) else {
            shot("down_no_hero_focus")
            XCTFail("no hero action button reports focus on entry; \(focusedSummary(app))")
            return
        }
        note("start", "hero focus on \(start); \(focusedSummary(app))")
        XCTAssertEqual(focusRow(app), "-", "the page should start with focus in the hero")
        press(.down)
        pause(0.6)
        shot("down_after")
        note("after Down", focusedSummary(app))
        XCTAssertTrue(element(app, "season_tab_1").hasFocus, "Down from the hero should land on the Season 1 tab; \(focusedSummary(app))")
        XCTAssertFalse(element(app, "season_tab_0").hasFocus, "Down from the hero must not land on Specials")
        XCTAssertFalse(element(app, "season_tab_2").hasFocus, "Down from the hero must not land on Season 2")
    }

    /// Right onto Season 2 switches the shelf after the debounce and leaves the hero untouched:
    /// Play's label, its target (the probe's `play=` token, readable even when Play is disabled
    /// with no stream source) and the synopsis teaser read the same before and after.
    func testSwitchingTabsKeepsHeroAndPlayTarget() throws {
        let app = try launchToSeasonTabs()
        XCTAssertTrue(walkDownToTabs(app), "could not reach the season tabs; \(focusedSummary(app))")
        XCTAssertTrue(element(app, "season_tab_1").hasFocus, "should start on Season 1; \(focusedSummary(app))")
        let before = heroSnapshot(app)
        let targetBefore = playTarget(app)
        note("hero before", "play='\(before.play)' target=\(targetBefore) synopsis='\(before.synopsis.prefix(80))'")
        XCTAssertFalse(["-", "?", "MISSING"].contains(targetBefore), "Play's target should be known before the switch (play=\(targetBefore))")
        XCTAssertTrue(waitForCard(app, season: 1, timeout: 3), "Season 1's episode cards should be on the shelf before the switch")

        press(.right, gap: 0.6)
        shot("switched_season2")
        note("after Right", focusedSummary(app))
        XCTAssertTrue(element(app, "season_tab_2").hasFocus, "Right should move focus to the Season 2 tab; \(focusedSummary(app))")
        XCTAssertTrue(waitForCard(app, season: 2, timeout: 3), "the shelf should show Season 2's episode cards (episode_card_2_*) after the switch")
        XCTAssertFalse(episodeCards(app, season: 1).firstMatch.exists, "Season 1's episode cards should be gone once the shelf shows Season 2")

        let after = heroSnapshot(app)
        let targetAfter = playTarget(app)
        note("hero after", "play='\(after.play)' target=\(targetAfter) synopsis='\(after.synopsis.prefix(80))'")
        XCTAssertEqual(targetAfter, targetBefore, "switching season tabs changed Play's target")
        XCTAssertEqual(after.play, before.play, "switching season tabs changed the hero's Play button")
        XCTAssertEqual(after.synopsis, before.synopsis, "switching season tabs changed the hero synopsis")
    }

    /// Right then Down with no wait: the Down must commit the pending season switch and enter
    /// Season 2's shelf, not Season 1's (the debounce has not fired yet). The entry card is the
    /// season's first unwatched episode, so any Season 2 card counts.
    func testFastRightDownLandsInNewSeason() throws {
        let app = try launchToSeasonTabs()
        XCTAssertTrue(walkDownToTabs(app), "could not reach the season tabs; \(focusedSummary(app))")
        XCTAssertTrue(element(app, "season_tab_1").hasFocus, "should start on Season 1; \(focusedSummary(app))")

        remote.press(.right)
        remote.press(.down) // no pause between the two presses
        pause(1.0)
        shot("fast_right_down")
        note("after Right+Down", focusedSummary(app))
        XCTAssertTrue(waitForCard(app, season: 2, timeout: 3), "Season 2's shelf should be showing")
        XCTAssertFalse(episodeCards(app, season: 1).firstMatch.exists, "Season 1's shelf must not still be showing")
        XCTAssertEqual(focusRow(app), "episodes", "focus should be in the Episodes section; \(focusedSummary(app))")
        let card = focusedEpisodeCard(app)
        XCTAssertTrue(card?.hasPrefix("episode_card_2_") == true, "focus should be on a Season 2 episode card; \(focusedSummary(app))")
    }

    /// Shared tail of the Menu legs: `from` already holds focus. First Menu returns focus to the hero
    /// action row (Play, or Mark Watched when Play is disabled as on FA87) with the page at the top;
    /// the second Menu leaves the Detail page. "Page at the top" is asserted through the hero's
    /// synopsis teaser sitting fully on screen and the hero probe row (`-`); an exact scroll offset
    /// is not readable here. "Left the page" is "the Detail's hero and season tabs are gone".
    private func assertMenuReturnsToHeroThenLeaves(_ app: XCUIApplication, from: String) {
        shot("menu_from_\(from)")
        press(.menu, gap: 1.5)
        shot("menu_after_first_\(from)")
        note("after first Menu from \(from)", focusedSummary(app))
        XCTAssertEqual(focusRow(app), "-", "first Menu from \(from) should return focus to the hero; \(focusedSummary(app))")
        let playEnabled = element(app, "detail_action_play").isEnabled
        let expected = playEnabled ? "detail_action_play" : "detail_action_watched"
        XCTAssertEqual(focusedHeroAction(app), expected,
                       "first Menu from \(from) should land on \(expected) (Play enabled: \(playEnabled)); \(focusedSummary(app))")
        let teaser = element(app, "detail_synopsis_teaser")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(teaser.exists && teaser.frame.minY >= 0 && teaser.frame.maxY <= screen.height,
                      "the page should be back at the top (hero synopsis on screen); teaser frame \(teaser.frame)")
        XCTAssertTrue(element(app, "detail_hero").exists, "the Detail page should still be showing after the first Menu")

        press(.menu, gap: 2.0)
        shot("menu_after_second_\(from)")
        note("after second Menu from \(from)", "hero exists=\(element(app, "detail_hero").exists) tab1 exists=\(element(app, "season_tab_1").exists)")
        XCTAssertFalse(element(app, "season_tab_1").exists, "second Menu should leave the Detail page (season tabs still present)")
        XCTAssertFalse(element(app, "detail_hero").exists, "second Menu should leave the Detail page (hero still present)")
    }

    /// Menu on an episode card: hero first, then out.
    func testMenuFromEpisodeCardGoesToHeroThenLeaves() throws {
        let app = try launchToSeasonTabs()
        XCTAssertTrue(walkDownToTabs(app), "could not reach the season tabs; \(focusedSummary(app))")
        press(.down)
        pause(0.6)
        note("in shelf", focusedSummary(app))
        XCTAssertEqual(focusRow(app), "episodes", "Down from the tabs should enter the Episodes section; \(focusedSummary(app))")
        // The entry card is Season 1's first unwatched episode (persistent profile), read at runtime.
        let card = focusedEpisodeCard(app)
        note("entry card", card ?? "<none>")
        XCTAssertTrue(card?.hasPrefix("episode_card_1_") == true, "Down from the Season 1 tab should land on one of its episodes; \(focusedSummary(app))")
        assertMenuReturnsToHeroThenLeaves(app, from: "episode")
    }

    /// Menu on a season tab: hero first, then out.
    func testMenuFromSeasonTabGoesToHeroThenLeaves() throws {
        let app = try launchToSeasonTabs()
        XCTAssertTrue(walkDownToTabs(app), "could not reach the season tabs; \(focusedSummary(app))")
        XCTAssertTrue(element(app, "season_tab_1").hasFocus, "should be on the Season 1 tab; \(focusedSummary(app))")
        assertMenuReturnsToHeroThenLeaves(app, from: "tab")
    }
}
