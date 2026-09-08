import XCTest

/// BUG-95 (beta.18, 2026-09-08) simulator repro rig — companion to the `HeroBitmapLayer` fix in
/// `HomeView.swift` and the layout unit tests in `HeroCrossfadeLayoutTests.swift`.
///
/// This is NOT a pass/fail geometry assertion. XCUITest has no way to sample a `UIImageView`'s
/// `bounds` mid-crossfade from outside the process, and the bug is a VISUAL one (a mosaic backdrop
/// visibly re-cropping itself over ~35 frames) — so this test's only job is to drive a scripted
/// walk across several folder-to-folder and folder-to-title hero swaps on the FA87 fixture while
/// the main session records the simulator screen with `scripts/dev/hero-swap-sheets.sh` (or a
/// straight screen recording) running alongside it. The actual verdict — whether the backdrop
/// re-crops after it appears — is read off that recording, not off any assertion in this file.
///
/// The walk begins with a self-locating Down loop: starting from the tab bar, press Down once at
/// a time (up to 45 times) while reading `debug_hero`'s `pitem=` value, and break once the
/// presented item's identity starts with the folder id prefix `nuvio-folder://`. If the loop
/// exhausts without finding a folder, the test fails with the last probe label. Once a folder
/// hero is found, the choreography (three rights across consecutive tiles, one up, one down)
/// exercises the swap classes BUG-95 was filmed against (folder→folder, folder→title, title→folder).
/// The `debug_hero` probe confirms that a hero surface was live and responding to focus.
///
/// Total scripted duration is ~14s (4×1.2 + 1.5 + 3×1.5 + 1.5 + 1.5 + 1.5 + 2.0), not counting
/// launch/profile-picker time.
final class HeroFolderSwapTests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers (trimmed copies — see the other hero test files' type docs for why these are
    // duplicated per-file rather than shared: they are `private` to each file already).

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
    }

    @discardableResult
    private func launchToHome(extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extraArguments
        app.launch()
        // Session restore + profile fetch can take well past 15s on a cold sim launch — same
        // budget `NuvioTVUITests.launchToHome` and `HeroOffLaunchTests.launchToHome` use.
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90),
                      "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        return app
    }

    // MARK: - test54

    /// Drives the scripted hero-swap walk described in the type doc. Waits for Home's rows to be
    /// present (the same `debug_hero` probe every other hero test uses as its "Home is live" gate),
    /// then walks: 4× Down (1.2s gaps, reaching the fixture's row 4), a 1.5s settle, 3× Right (1.5s
    /// gaps — three folder-to-folder hero swaps), a 1.5s settle, 1× Up (folder → title swap), a
    /// 1.5s settle, 1× Down (title → folder swap), and a final 2s settle before the closing
    /// screenshot. `-debug.homeHeroProbe YES` is the same release-safe probe knob every other hero
    /// test uses; no other debug launch arguments are needed to reach Home on the signed-in FA87
    /// fixture (the profile picker auto-select above is `launchToHome`'s whole job).
    func test54FolderHeroSwapGeometry() throws {
        let app = launchToHome(extraArguments: [
            "-debug.homeHeroProbe", "YES",
        ])

        let probe = app.staticTexts["debug_hero"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20),
                      "debug_hero probe never appeared — Home rows are not up, nothing to walk")
        pause(2.0) // catalog fan-out settle, matching the other hero tests' post-Home pause

        // Self-locating loop: walk Down up to 45 times looking for a folder hero.
        // Extract pitem=<identity> from debug_hero to verify we've reached a collection-folder row.
        var foundFolder = false
        var downsPressedForFolder = 0
        var lastProbeLabel = ""

        for attempt in 1...45 {
            press(.down, times: 1, gap: 1.2)

            let label = probe.label
            lastProbeLabel = label

            // Parse pitem=<identity> from the debug probe label.
            if let pitemRange = label.range(of: "pitem=") {
                let afterPitem = String(label[pitemRange.upperBound...])
                let pitemValue = afterPitem.components(separatedBy: " ")[0]

                if pitemValue.contains("nuvio-folder://") {
                    foundFolder = true
                    downsPressedForFolder = attempt
                    break
                }
            }
        }

        if !foundFolder {
            XCTFail("Could not locate a collection-folder hero after 45 Down presses. Last probe: \(lastProbeLabel)")
            return
        }

        XCTContext.runActivity(named: "folder_found_at_down_\(downsPressedForFolder)") { _ in }
        print("Found collection folder after \(downsPressedForFolder) Down presses")
        pause(1.5)

        // 3 Rights, 1.5s gaps — three consecutive folder-to-folder hero swaps.
        press(.right, times: 3, gap: 1.5)
        pause(1.5)

        // 1 Up — folder → title swap.
        press(.up, times: 1, gap: 1.5)
        pause(1.5)

        // 1 Down — title → folder swap.
        press(.down, times: 1, gap: 1.5)
        pause(2.0)

        XCTContext.runActivity(named: "54_hero_swap_walk_final") { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "54_hero_swap_walk_final"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertTrue(probe.exists,
                      "debug_hero probe disappeared after the walk — hero surface no longer live")
        XCTAssertTrue(app.state == .runningForeground,
                      "app must still be foregrounded after the scripted swap walk")
    }
}
