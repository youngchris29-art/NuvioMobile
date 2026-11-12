import XCTest

/// BUG-96 (beta.18): on the detail page, a vertical focus move must leave every section header
/// either fully on screen or fully off it — never straddling the top edge (the tester's photos:
/// "Guide parental" cut in half above a focused Saga row) — and the focused row's title must rest
/// near `DetailRowAnchor.topInset`.
///
/// BUG-99 (rc6): the direction split changed what "at rest" means for a Down press. Down no
/// longer anchors by default — the engine's own minimal reveal is left alone unless it would
/// leave the header straddling the top scrim — so the Down walk below no longer expects every
/// step to land within ±16 of `DetailRowAnchor.screenRest`; it instead asserts the row never rests
/// ABOVE the rest, and that the probe's `anchor=… free` reading actually fires on at least two of
/// the six presses (proof the new decision is being exercised, not just never triggering). Up is
/// unchanged — it must still anchor every time — so an Up leg is appended after the Down walk to
/// cover that.
///
/// Oracle: XCUI frames of the section-title `staticTexts` at rest after each press. The tvOS
/// 27 runtime never reports `hasFocus`, so the leg does not identify the focused row; it asserts
/// the invariant every title must satisfy, plus that SOME title sits at the anchor band once focus
/// has left the top block. The detail page is recognised by its DEBUG-only `debug_ux6` probe.
final class DetailRowAnchorTests: XCTestCase {
    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, gap: TimeInterval = 0.8) {
        for _ in 0..<times {
            remote.press(button)
            pause(gap)
        }
    }

    private func launchToHome() -> XCUIApplication {
        let app = XCUIApplication()
        // Deterministic row geometry: no Upcoming row, so down×4 lands on a movies catalog row
        // (the same trick TrailerSoakTests / RowLeadingEdgeTests use).
        // No trailer anywhere: the detail page otherwise auto-enters the full-screen cover
        // (FEAT-32) a few seconds in, and the Down walk would be pressing inside it.
        // `forceNoTrailer` is honoured only alongside `debug.trailerProbe`.
        // Home Stage & Strip (W3): the Down walk to a movies row is Classic Home's; pin Classic.
        app.launchArguments += ["-home_layout", "classic"]
        app.launchArguments += ["-home_upcoming_row_enabled", "NO",
                                "-debug.trailerProbe", "YES", "-debug.trailerForceNoTrailer", "YES",
                                "-debug.detailScrollProbe", "YES"]
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            // ui-legs: the shared verified step (Select only once "Chris" reads focused).
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        }
        pause(10)
        return app
    }

    /// BUG-217: where the probe's `anchor=<row>` row rests on screen (`DetailRowAnchor.screenRest(for:)`):
    /// 108, except the rows whose first item the focus engine would otherwise pull down on the first
    /// Right press: the chip row (`logos`, 180) and Cast / Collection / Trailers (180 less the lead of
    /// their first item under the heading block: 61 / 69 / 69 with the system font).
    private func restForAnchoredRow(_ probeLabel: String, cinematic: Bool) -> Double {
        guard let range = probeLabel.range(of: "anchor=") else { return 108 }
        switch probeLabel[range.upperBound...].prefix(while: { $0 != " " }) {
        case "logos": return cinematic ? 180 : 108
        case "cast": return 119
        case "collection", "trailers": return 111
        default: return 108
        }
    }

    /// `key=<number>` out of the probe label (first occurrence).
    private func probeNumber(_ label: String, key: String) -> Double? {
        guard let range = label.range(of: key) else { return nil }
        let tail = label[range.upperBound...]
        let token = tail.prefix { $0 == "-" || $0 == "." || $0.isNumber }
        return Double(token)
    }

    /// Section-title candidates: single-line labels at the section-title size. Cards' captions are
    /// shorter and posters are not staticTexts, so a height band is a stable enough filter here.
    private func sectionTitleFrames(_ app: XCUIApplication) -> [(label: String, frame: CGRect)] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [(String, CGRect)] = []
        func walk(_ node: XCUIElementSnapshot) {
            // FEAT-35: the Cinematic hero (`detail_hero`) is not an anchored row; its title fallback,
            // meta line and credits must never enter the oracle (a title such as "… Collection"
            // would otherwise match the suffix filter below).
            if node.identifier == "detail_hero" { return }
            if node.elementType == .staticText {
                let f = node.frame
                if f.height >= 30, f.height <= 64, f.width >= 80, f.width <= 900, !node.label.isEmpty {
                    out.append((node.label, f))
                }
            }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    func testDownWalkNeverLeavesAHeaderStraddlingTheTopEdge() throws {
        let app = launchToHome()
        // harness-w4 (2026-10-23): into Detail by the shared, focus-verified Search route
        // (`DetailEntryRoute`: the Severance series, then Dune), never a blind Select. The old
        // "Down ×4, Select" could land on FA87's Continue Watching row, whose cards resume the
        // player; the route presses Select only on a result card that reads focused.
        guard DetailEntryRoute(test: self, app: app).openDetail() else { return }
        pause(2)
        guard app.staticTexts["debug_ux6"].waitForExistence(timeout: 6) else {
            throw XCTSkip("no detail page opened (debug_ux6 probe absent) — nothing to measure")
        }
        // BUG-217: the Cinematic hero (`detail_hero`) marks the layout; the chip row's rest differs.
        let cinematic = app.descendants(matching: .any)["detail_hero"].exists
        // FEAT-32: the page used to auto-enter the full-screen trailer cover a few seconds in, and
        // this walk pressed Menu once "regardless" to back out of it. That Menu now POPS the page:
        // the Back-hint caption stays mounted on the page with no cover up, and in the Cinematic
        // layout Menu on Detail returns to Home (the 10-02 g3 run walked Home's rows, probe "-").
        // `-debug.trailerForceNoTrailer` is honoured by `DetailViewModel` since rc13 (see test68),
        // so no cover engages; only press Menu if the page's probe has actually gone (a cover is up).
        pause(6)
        if !app.staticTexts["debug_ux6"].exists, app.staticTexts["Press Back to exit the trailer"].exists {
            remote.press(.menu)
            pause(3)
        }
        guard app.staticTexts["debug_ux6"].waitForExistence(timeout: 4) else {
            throw XCTSkip("the Detail page's debug_ux6 probe disappeared before the walk — the page was left (nothing to measure)")
        }

        // Guest fixture (10-02 g4 run): no stream source, so Play reads "Playback unavailable" and is
        // disabled; initial focus then sits on the icon-only Watched button (x ≈ 730) and Down from
        // there can jump past the narrow rows under the hero. Start from the leftmost focusable hero
        // control; if the walk still cannot reach three rows, skip below (the focus PATH changed, not
        // the anchor behaviour this test measures).
        let playDisabled = app.buttons["Playback unavailable"].exists
        if playDisabled {
            press(.left, times: 4, gap: 0.6)
            pause(0.8)
        }

        var anchorSamples = 0
        var anchoredRows = Set<String>()
        var straddles: [String] = []
        // BUG-96 rc5 regression fix: `moves=` is `DetailScrollMotion.segments` over this focus
        // visit's raw offset samples — `1` means the engine's reveal and the anchor pass blended
        // into one motion, `2`+ means the old land-then-nudge two-step move is back. Kept alongside
        // the `(top − off) − rest(row)` residual per step so both survive in the failure message and in
        // an attachment even when the run passes. BUG-99: both are now tagged by `direction` since
        // the Down walk and the Up leg below are measured with the same arrays.
        var movesByStep: [(step: Int, direction: String, moves: Int)] = []
        var residualByStep: [(step: Int, direction: String, residual: Double)] = []
        // BUG-99 rc6: how many of the Down presses read `anchor=… free` on the probe — i.e. the
        // engine's own minimal reveal was left alone rather than pulled up to the anchor. At least
        // some of the six presses on a typical detail page (short rows, no straddle) must land
        // here, or the new decision is never actually being exercised by this walk.
        var downFreeSteps = 0
        // Only the anchored rows' section titles are the oracle; the top block's details grid
        // (Network, Country, …) is not an anchored row.
        let sectionLabels: Set<String> = ["Parental Guide", "Guide parental", "Cast", "Casting", "Episodes", "Épisodes",
                                          "Trailers & Extras", "Bandes-annonces et extras", "More Like This", "Comments"]

        for step in 1...6 {
            press(.down, times: 1, gap: 1.4)
            let titles = sectionTitleFrames(app).filter { sectionLabels.contains($0.label) || $0.label.hasSuffix("Saga") || $0.label.hasSuffix("Collection") }
            for (label, f) in titles {
                // Straddling: the top edge cuts through the title's own glyph box AND the title sits
                // below the top scrim's opaque zone (a header under the scrim is faded away, not cut).
                if f.minY > 40, f.minY < f.height * 0.8 {
                    straddles.append("step \(step) (down): '\(label)' minY=\(Int(f.minY)) h=\(Int(f.height))")
                }
            }
            // The anchor oracle reads the app's own probe: `anchor=<row> top=<content y> …` and
            // `geo=off=<content offset>`; the focused row's screen top is `top − off`. On Down,
            // BUG-99 no longer expects this to land at `DetailRowAnchor.screenRest` (108) on every
            // press — only that it never rests ABOVE the rest (a residual below -16 would mean the
            // header was pushed past the anchor band, the pre-blend-fix symptom), and that the
            // probe's `free` note actually shows up more than once across the six presses. Title
            // heuristics are not used for this — rows whose top is not a title (season chips,
            // logos) and titles the accessibility walk does not list (Cast) would make it vacuous.
            let probeLabel = app.staticTexts["debug_ux6"].exists ? app.staticTexts["debug_ux6"].label : ""
            if let top = probeNumber(probeLabel, key: "top="), let off = probeNumber(probeLabel, key: "off=") {
                anchorSamples += 1
                let residual = (top - off) - restForAnchoredRow(probeLabel, cinematic: cinematic)
                residualByStep.append((step, "down", residual))
                // Codex BUG-96 r3 (P3): a stuck focus would repeat one good sample on every press —
                // the walk must reach DISTINCT rows, not the same one six times.
                if let range = probeLabel.range(of: "anchor=") {
                    let row = probeLabel[range.upperBound...].prefix { $0 != " " }
                    anchoredRows.insert(String(row))
                }
                // The `debug_ux6` label reads `anchor=<row> top=<t> free geo=…` for a `.free`
                // decision (see `DetailView`'s `String(format: "%@ top=%.0f free", …)`), so " free
                // geo=" is present exactly when this step's decision was `.free`.
                if probeLabel.contains(" free geo=") { downFreeSteps += 1 }
                // BUG-96 rc5: the motion-segment count sampled alongside this same at-rest probe
                // read — `debug_ux6`'s `geo=` mirrors `dimModel.geometrySample`, which carries
                // `moves=` (see `DetailView`'s scroll-geometry handler).
                if let moves = probeNumber(probeLabel, key: "moves=") {
                    movesByStep.append((step, "down", Int(moves)))
                }
            }
            let visible = titles.filter { $0.frame.minY >= 0 && $0.frame.maxY <= 1080 }.map { "\($0.label)@\(Int($0.frame.minY))" }
            let shotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shotAttachment.name = "bug99_down_step\(step)"
            shotAttachment.lifetime = .keepAlways
            add(shotAttachment)
            let probe = app.staticTexts["debug_ux6"]
            print("[BUG99] down step \(step) titles=\(visible) probe=\(probe.exists ? probe.label : "-")")
        }
        if playDisabled && anchoredRows.count < 3 {
            throw XCTSkip("Play disabled on guest fixture changes the focus path: with \"Playback unavailable\" the walk starts on an icon-only secondary and Down reached only \(anchoredRows.sorted()) — not enough distinct rows to measure the anchor; rerun on a fixture with a playable title")
        }
        XCTAssertGreaterThanOrEqual(anchorSamples, 4, "BUG-96: the probe never reported a row — is -debug.detailScrollProbe on?")
        XCTAssertGreaterThanOrEqual(anchoredRows.count, 3,
                                    "BUG-96: the Down walk must reach at least three DISTINCT rows (saw \(anchoredRows.sorted())) — a repeated sample means focus was stuck")

        // BUG-99 (rc6): replaces the old "residual within ±16 on nearly every step" rule, which
        // assumed Down always anchors — it doesn't any more. What must still hold on Down: the row
        // never rests ABOVE `DetailRowAnchor.screenRest` (that would be the ORIGINAL BUG-96
        // straddle, not the two-step-motion regression the blend fix already closed), and the
        // straddle-only-when-needed decision must actually be exercised at least twice in six
        // presses.
        let downResiduals = residualByStep.filter { $0.direction == "down" }
        let aboveRestSteps = downResiduals.filter { $0.residual < -16 }
        XCTAssertTrue(aboveRestSteps.isEmpty,
                      "BUG-99: a Down step rested the row ABOVE its DetailRowAnchor rest (108, or the BUG-217 row rest) — " +
                      "\(aboveRestSteps.map { "step\($0.step)=\(String(format: "%.0f", $0.residual))" })")
        XCTAssertGreaterThanOrEqual(downFreeSteps, 2,
                                    "BUG-99: at least two of the six Down presses must leave the engine's own minimal reveal alone (anchor=… free) — saw \(downFreeSteps)")

        // BUG-99: Up is unchanged — it must still anchor every time, exactly like every row did
        // before rc6. Same oracle, appended as its own leg after the Down walk.
        var upClampedSteps = Set<Int>()
        for step in 1...3 {
            press(.up, times: 1, gap: 1.4)
            let titles = sectionTitleFrames(app).filter { sectionLabels.contains($0.label) || $0.label.hasSuffix("Saga") || $0.label.hasSuffix("Collection") }
            for (label, f) in titles {
                if f.minY > 40, f.minY < f.height * 0.8 {
                    straddles.append("step \(step) (up): '\(label)' minY=\(Int(f.minY)) h=\(Int(f.height))")
                }
            }
            let probeLabel = app.staticTexts["debug_ux6"].exists ? app.staticTexts["debug_ux6"].label : ""
            if let top = probeNumber(probeLabel, key: "top="), let off = probeNumber(probeLabel, key: "off=") {
                let residual = (top - off) - restForAnchoredRow(probeLabel, cinematic: cinematic)
                residualByStep.append((step, "up", residual))
                // End-of-content clamp: when the page is already scrolled to its end (the geometry
                // sample's offset + visible height reaches the content height), a row near the bottom
                // (About is the short last row in Cinematic) physically cannot be raised to the 108 pt
                // rest — it rests LOWER (positive residual). Only that case is exempt below.
                // harness-w4 (2026-10-23): the page's last reachable offset is `content − vis − inset`
                // (`geo=… inset=`), not `content − vis`. Measured on FA87's Severance page (the leg's
                // first run in weeks, via DetailEntryRoute): `content=2627 vis=863 inset=157`, and the
                // About row (Down 4–6) rested at `off=1607` = 2627 − 863 − 157 while asking for more;
                // Up 1 to Trailers & Extras then re-issued y=1873 and stayed at 1607 (residual 109),
                // which the old `off + vis ≥ content − 4` test did not recognise as the clamp.
                let inset = probeNumber(probeLabel, key: "inset=") ?? 0
                if let vis = probeNumber(probeLabel, key: "vis="), let content = probeNumber(probeLabel, key: "content="),
                   off + vis + inset >= content - 4, residual > 0 {
                    upClampedSteps.insert(step)
                }
                if let moves = probeNumber(probeLabel, key: "moves=") {
                    movesByStep.append((step, "up", Int(moves)))
                }
            }
            let visible = titles.filter { $0.frame.minY >= 0 && $0.frame.maxY <= 1080 }.map { "\($0.label)@\(Int($0.frame.minY))" }
            let shotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shotAttachment.name = "bug99_up_step\(step)"
            shotAttachment.lifetime = .keepAlways
            add(shotAttachment)
            let probe = app.staticTexts["debug_ux6"]
            print("[BUG99] up step \(step) titles=\(visible) probe=\(probe.exists ? probe.label : "-")")
        }
        let upResiduals = residualByStep.filter { $0.direction == "up" }
        XCTAssertGreaterThanOrEqual(upResiduals.count, 2, "BUG-99: the Up leg never reported a probe sample — is -debug.detailScrollProbe on?")
        for entry in upResiduals where !upClampedSteps.contains(entry.step) {
            XCTAssertLessThanOrEqual(abs(entry.residual), 16,
                                     "BUG-99: Up step \(entry.step) must anchor to its DetailRowAnchor rest (108, or the BUG-217 row rest) — residual \(String(format: "%.0f", entry.residual))")
        }

        XCTAssertTrue(straddles.isEmpty, "BUG-96: a section header straddled the top edge at rest — \(straddles)")

        // Numbers first, so they survive a PASSING run too — the experiment report needs the
        // moves= distribution and residuals per direction regardless of outcome, not just on
        // failure.
        let movesDescription = movesByStep.map { "\($0.direction)\($0.step)=\($0.moves)" }.joined(separator: " ")
        let residualDescription = residualByStep.map { "\($0.direction)\($0.step)=\(String(format: "%.0f", $0.residual))" }.joined(separator: " ")
        XCTContext.runActivity(named: "BUG-99 moves= distribution and (top-off-108) residuals, Down then Up") { activity in
            let attachment = XCTAttachment(string: "moves: \(movesDescription)\nresiduals(top-off-108): \(residualDescription)\ndownFreeSteps: \(downFreeSteps)/\(downResiduals.count)\nupClampedSteps: \(upClampedSteps.sorted())")
            attachment.name = "bug99_moves_and_residuals"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print("[BUG99] moves=\(movesDescription) residuals=\(residualDescription) downFreeSteps=\(downFreeSteps) upClampedSteps=\(upClampedSteps.sorted())")

        // The blend fix's whole point (unchanged by BUG-99): every at-rest sample, on either
        // direction, reads as ONE motion. `moves=2`+ is the land-then-nudge regression rc5 reported.
        let multiMoveSteps = movesByStep.filter { $0.moves > 1 }
        XCTAssertTrue(multiMoveSteps.isEmpty,
                      "BUG-96: a focus move landed in more than one visible motion (land-then-nudge) — " +
                      "steps \(multiMoveSteps.map { "\($0.direction)\($0.step)=\($0.moves)" }) — full distribution moves: \(movesDescription) residuals(top-off-108): \(residualDescription)")

        remote.press(.menu)
        pause(1)
    }

    // MARK: - BUG-244: the Down walk reaches every section and the end of the page

    /// One at-rest reading after a Down press: the focused row, the focused comment card (the DEBUG
    /// `debug_comment_focus` marker), the laid-out scroll geometry (`debug_ux6` `geo=`) and the
    /// sections' laid-out tops in content space (`debug_detail_sections` `rows=`).
    private struct WalkSample: CustomStringConvertible {
        var press: Int
        var row: String
        var comment: Int?
        var off: Double
        var inset: Double
        var vis: Double
        var content: Double
        var tops: [String: Double]
        var cbody: Int?
        /// The Comments section's screen-space bottom (`sb=` of the focus marker), live between cards.
        var sectionBottom: Double?
        var description: String {
            "p\(press) row=\(row) c=\(comment.map(String.init) ?? "-") off=\(Int(off)) inset=\(Int(inset)) vis=\(Int(vis)) content=\(Int(content)) cbody=\(cbody.map(String.init) ?? "-")"
        }
    }

    private struct WalkResult {
        var app: XCUIApplication
        /// Rendered sections in page order (probe `rows=`), with their tops at the first reading.
        var sections: [String]
        var stops: Set<String>
        var tail: Set<String>
        var gap: Double
        var pad: Double
        var hasSectionsProbe: Bool
        var initialCBody: Int?
        var samples: [WalkSample]
    }

    /// `DetailSection.rawValue` → `DetailRowID` case name (the `debug_detail_focus` `row=` token).
    private static func rowName(_ section: String) -> String {
        switch section {
        case "companies": return "logos"
        case "parentalGuide": return "parental"
        case "castAndCrew": return "cast"
        default: return section
        }
    }

    private static func tokens(_ label: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in label.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    /// Eight comments shaped like a real title's: a 1/10 with 57 likes, a spoiler, a five-line one,
    /// a review, the rest one or two lines. In memory only (`DetailCommentsDebugSeed`, guest only).
    private static let commentsSeedB64: String = {
        let long = String(repeating: "A long comment that runs over several lines so the card is taller than the rest, like a real review does. ", count: 6)
        let items: [[String: Any]] = [
            ["id": 1, "author": "Seed One", "text": "Worst thing I have seen this year.", "likes": 57, "rating": 1, "createdAt": "2026-10-18T00:00:00Z"],
            ["id": 2, "author": "Seed Two", "text": "The ending is a twist you will not see coming.", "spoiler": true, "likes": 41, "rating": 9, "createdAt": "2026-10-12T00:00:00Z"],
            ["id": 3, "author": "Seed Three", "text": long, "review": true, "likes": 33, "rating": 8, "createdAt": "2026-10-09T00:00:00Z"],
            ["id": 4, "author": "Seed Four", "text": "Great.", "likes": 12, "rating": 10, "createdAt": "2026-10-01T00:00:00Z"],
            ["id": 5, "author": "Seed Five", "text": "Slow start, strong middle and a finish that earns it.", "likes": 9, "createdAt": "2026-09-28T00:00:00Z"],
            ["id": 6, "author": "Seed Six", "text": "Watched it twice.", "likes": 4, "rating": 7, "createdAt": "2026-09-20T00:00:00Z"],
            ["id": 7, "author": "Seed Seven", "text": "Not for me, but the cast is good and the score carries a lot of it.", "likes": 2, "rating": 5, "createdAt": "2026-09-14T00:00:00Z"],
            ["id": 8, "author": "Seed Eight", "text": "Fine.", "likes": 0, "createdAt": "2026-09-02T00:00:00Z"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: items)
        return data.base64EncodedString()
    }()
    private static let commentsSeedCount = 8

    private static let severance = "nuviotv://title?id=tt11280740&type=series&name=Severance"
    private static let dune = "nuviotv://title?id=tt1160419&type=movie&name=Dune"

    /// Launches straight into `url` through the DEBUG deep-link hook (no Home walk, no Select on a
    /// content card) and settles. Launch arguments live in the argument domain: nothing is written
    /// or synced. The app is terminated in a teardown block, also when the test fails.
    private func launchWalk(_ url: String, layout: String, tmdb: Bool, sections: [String: Bool] = [:],
                            seedComments: Bool = false, extra: [String] = []) -> XCUIApplication? {
        let app = XCUIApplication()
        var args = ["-debug.openDeepLink", url, "-debug.tmdbEnabledOverride", tmdb ? "YES" : "NO",
                    "-debug.rememberLastProfile", "NO", "-detail_layout", layout,
                    "-detail_trailer_autoplay", "NO", "-detail_trailer_fullscreen_autoplay", "NO",
                    "-debug.trailerProbe", "YES", "-debug.trailerForceNoTrailer", "YES",
                    "-debug.detailScrollProbe", "YES", "-debug.detailFocusProbe", "YES"]
        for (key, on) in sections.sorted(by: { $0.key < $1.key }) { args += ["-detail_section_\(key)", on ? "YES" : "NO"] }
        if seedComments { args += ["-debug.detailCommentsSeedB64", Self.commentsSeedB64] }
        app.launchArguments += args + extra
        addTeardownBlock { app.terminate() }
        app.launch()
        guard DetailEntryRoute.selectChrisTile(self, app, timeout: 90) != nil else {
            XCTFail("profile picker never appeared — is the sim session still signed in?")
            return nil
        }
        // The page settles: meta loaded, then the late rows (Parental Guide, Trakt comments).
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if app.staticTexts["debug_detail_focus"].exists, app.staticTexts["debug_detail_focus"].label.contains("meta=1") { break }
            pause(1)
        }
        pause(14)
        return app
    }

    private func readSample(_ app: XCUIApplication, press: Int) -> WalkSample? {
        let focus = app.staticTexts["debug_detail_focus"]
        let ux6 = app.staticTexts["debug_ux6"]
        guard focus.exists, ux6.exists else { return nil }
        let focusTokens = Self.tokens(focus.label)
        let geo = ux6.label
        // The initial rest (press 0) has no geometry sample yet (`geo=-`): the page is at its top,
        // offset 0 on the 1080 pane (vis 960 inset 60, as every later reading reports).
        let initialRest = press == 0 && !geo.contains("off=")
        guard let off = initialRest ? 0 : probeNumber(geo, key: "off="),
              let vis = initialRest ? 960 : probeNumber(geo, key: "vis="),
              let content = initialRest ? 0 : probeNumber(geo, key: "content=") else { return nil }
        let marker = app.staticTexts["debug_comment_focus"]
        let markerTokens = marker.exists ? marker.label.split(separator: " ").map(String.init) : []
        let comment = markerTokens.count > 1 ? Int(markerTokens[1]) : nil
        let sectionBottom = markerTokens.first { $0.hasPrefix("sb=") }.flatMap { Double($0.dropFirst(3)) }
        var tops: [String: Double] = [:]
        var cbody: Int?
        let sections = app.staticTexts["debug_detail_sections"]
        if sections.exists {
            let t = Self.tokens(sections.label)
            for entry in (t["rows"] ?? "").split(separator: ",") {
                let kv = entry.split(separator: ":")
                if kv.count == 2, let top = Double(kv[1]) { tops[String(kv[0])] = top }
            }
            cbody = t["cbody"].flatMap(Int.init)
        }
        return WalkSample(press: press, row: focusTokens["row"] ?? "?", comment: comment, off: off,
                          inset: initialRest ? 60 : (probeNumber(geo, key: "inset=") ?? 0), vis: vis, content: content, tops: tops, cbody: cbody, sectionBottom: sectionBottom)
    }

    /// The shared Down-walk oracle: Down one press at a time (0.8 s gap, then the Down settle task's
    /// two 0.35 s waits plus margin), at most 40 presses, until two consecutive presses change
    /// nothing. Geometry from laid-out values only, never accessibility frames.
    private func walkDownToEnd(_ app: XCUIApplication, tag: String = "walk") -> WalkResult? {
        // Guest fixture: Play reads "Playback unavailable" and initial focus can sit on an icon-only
        // secondary; start from the leftmost hero control (as the BUG-96 walk does).
        if app.buttons["Playback unavailable"].exists { press(.left, times: 4, gap: 0.6) }
        pause(0.8)
        let sectionsLabel = app.staticTexts["debug_detail_sections"]
        let hasProbe = sectionsLabel.exists
        let t = hasProbe ? Self.tokens(sectionsLabel.label) : [:]
        var sections: [String] = []
        for entry in (t["rows"] ?? "").split(separator: ",") {
            if let name = entry.split(separator: ":").first { sections.append(String(name)) }
        }
        func set(_ key: String) -> Set<String> { Set((t[key] ?? "").split(separator: ",").map(String.init)) }
        var result = WalkResult(app: app, sections: sections, stops: set("stops"), tail: set("tail"),
                                gap: t["gap"].flatMap(Double.init) ?? 0, pad: t["pad"].flatMap(Double.init) ?? 0,
                                hasSectionsProbe: hasProbe, initialCBody: t["cbody"].flatMap(Int.init), samples: [])
        if let initial = readSample(app, press: 0) { result.samples.append(initial) }
        var unchanged = 0
        for n in 1...40 {
            press(.down, times: 1, gap: 0.8)
            pause(1.2)
            guard var sample = readSample(app, press: n) else {
                XCTFail("no geometry reading after press \(n) (probes absent?)")
                return result
            }
            // Between comment cards the page's own scroll sample is stale (it is published when the
            // focused ROW changes): take the live offset from the Comments section's screen-space
            // bottom, whose content-space bottom is the next section's top minus the gap (or the
            // content end minus the padding).
            if sample.comment != nil, let sb = sample.sectionBottom, sb > 0,
               let at = result.sections.firstIndex(of: "comments") {
                let bottomContent: Double? = at + 1 < result.sections.count
                    ? sample.tops[result.sections[at + 1]].map { $0 - result.gap }
                    : sample.content - result.pad
                if let bottomContent { sample.off = bottomContent - sb }
            }
            if let last = result.samples.last, last.row == sample.row, last.comment == sample.comment,
               abs(last.off - sample.off) < 1 {
                unchanged += 1
            } else {
                unchanged = 0
            }
            result.samples.append(sample)
            frameIfRequested("\(tag)-p\(String(format: "%02d", n))-\(sample.row)\(sample.comment.map { "-c\($0)" } ?? "")")
            if unchanged >= 2 { break }
        }
        return result
    }

    /// The pane's bottom in the content space's screen mapping: a section's on-screen y is
    /// `contentY - off`; the last reachable offset is `content - vis - inset`, so the bottom safe
    /// area is at `vis + inset` (1020 on the 1080 pane).
    private func paneBottom(_ s: WalkSample) -> Double { s.vis + s.inset }

    private func attachWalk(_ name: String, _ r: WalkResult) {
        let text = "sections=\(r.sections) stops=\(r.stops.sorted()) tail=\(r.tail.sorted()) gap=\(r.gap) pad=\(r.pad)\n"
            + r.samples.map { "\($0) tops=\($0.tops.sorted { $0.key < $1.key })" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[BUG244] \(name):\n\(text)")
    }

    /// The distinct focused rows after the hero, in order (repeats collapsed; the hero and unknown
    /// readings dropped).
    private func rowSequence(_ r: WalkResult) -> [String] {
        var out: [String] = []
        for s in r.samples where s.row != "-" && s.row != "?" {
            if out.last != s.row { out.append(s.row) }
        }
        return out
    }

    private func assertEnd(_ r: WalkResult, _ tag: String) {
        guard let last = r.samples.last else { return XCTFail("\(tag): no samples") }
        let section = r.hasSectionsProbe ? (r.sections.last ?? "") : ""
        // The last section's bottom is `content - pad` (base tip: pad unknown, 0).
        let bottom = last.content - r.pad - last.off
        XCTAssertLessThanOrEqual(bottom, paneBottom(last) + 1,
                                 "\(tag) END: the last section (\(section)) ends at y=\(Int(bottom)), below the pane bottom \(Int(paneBottom(last))) — \(r.samples)")
    }

    /// Asserts 1 (order), 2 (visited), 3 (end) and 4 (comments) of the shared oracle.
    private func assertWalk(_ r: WalkResult, _ tag: String, commentCount: Int? = nil) throws {
        attachWalk(tag, r)
        assertEnd(r, tag)
        guard r.hasSectionsProbe else {
            throw XCTSkip("\(tag): no debug_detail_sections probe (base tip): asserts 1, 2 and 4 skipped")
        }
        let expected = r.sections.filter { r.stops.contains($0) || r.tail.contains($0) }.map(Self.rowName(_:))
        XCTAssertEqual(rowSequence(r), expected, "\(tag) ORDER: the focused rows must visit every stop in page order — \(r.samples)")
        // Visited: focused at some rest, or fully on the pane at some rest.
        for (index, section) in r.sections.enumerated() {
            let row = Self.rowName(section)
            if r.samples.contains(where: { $0.row == row }) { continue }
            let onScreen = r.samples.contains { s in
                guard let top = s.tops[section] else { return false }
                let bottom: Double
                if index + 1 < r.sections.count, let next = s.tops[r.sections[index + 1]] {
                    bottom = next - r.gap
                } else if index + 1 == r.sections.count, s.content > 0 {
                    bottom = s.content - r.pad
                } else {
                    return false
                }
                // "On screen": inside the 1080 pt screen (a section may end under the bottom safe-area line).
                return top - s.off >= 0 && bottom - s.off <= 1080 + 1
            }
            XCTAssertTrue(onScreen, "\(tag) VISITED: \(section) was never focused nor fully on the pane at a rest — \(r.samples)")
        }
        if let n = commentCount {
            var seen: [Int] = []
            for s in r.samples { if let c = s.comment, seen.last != c { seen.append(c) } }
            XCTAssertEqual(seen, Array(0..<n), "\(tag) COMMENTS: the focused comment cards must be 0…\(n - 1) in order — \(r.samples)")
        }
    }

    /// A per-press frame, saved only when `BUG244_SHOT_DIR` is set for the run (the evidence frames).
    private func frameIfRequested(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["BUG244_SHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func screenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["BUG244_SHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// U1: Apple-style, TMDB off (names-only Cast), About, More Like This and Comments off.
    func testAppleStyleNamesOnlyTailReachesPageEnd() throws {
        guard let app = launchWalk(Self.severance, layout: "apple", tmdb: false,
                                   sections: ["about": false, "more_like_this": false, "comments": false]) else { return }
        let label = app.staticTexts["debug_detail_sections"]
        if label.exists, !(Self.tokens(label.label)["tail"] ?? "").contains("castAndCrew") {
            throw XCTSkip("the title's Cast & Crew is not a names-only tail section here: \(label.label)")
        }
        guard let r = walkDownToEnd(app, tag: "u1") else { return }
        screenshot("u1-apple-end")
        try assertWalk(r, "U1")
        if r.hasSectionsProbe {
            XCTAssertTrue(app.descendants(matching: .any)["detail_tail_stop_castAndCrew"].exists, "U1: the Cast tail stop element is missing")
        }
    }

    /// U2: Classic film, TMDB off, Trailers, More Like This and Comments off: Down from the action
    /// row reaches Parental Guide then Cast.
    func testClassicFilmTailReachesPageEnd() throws {
        guard let app = launchWalk(Self.dune, layout: "classic", tmdb: false,
                                   sections: ["trailers": false, "more_like_this": false, "comments": false]) else { return }
        let label = app.staticTexts["debug_detail_sections"]
        if label.exists, (Self.tokens(label.label)["tail"] ?? "").isEmpty {
            throw XCTSkip("no tail on this title's Classic page: \(label.label)")
        }
        guard let r = walkDownToEnd(app, tag: "u2") else { return }
        screenshot("u2-classic-end")
        try assertWalk(r, "U2")
    }

    /// U2c: Cinematic series, TMDB off, About, Trailers, More Like This and Comments off.
    func testCinematicAboutOffTailReachesPageEnd() throws {
        guard let app = launchWalk(Self.severance, layout: "cinematic", tmdb: false,
                                   sections: ["about": false, "trailers": false, "more_like_this": false, "comments": false]) else { return }
        let label = app.staticTexts["debug_detail_sections"]
        if label.exists, !(Self.tokens(label.label)["tail"] ?? "").contains("castAndCrew") {
            throw XCTSkip("the title's Cast & Crew is not a names-only tail section here: \(label.label)")
        }
        guard let r = walkDownToEnd(app) else { return }
        screenshot("u2c-cinematic-end")
        try assertWalk(r, "U2c")
    }

    private func commentsLeg(about: Bool, tag: String) throws {
        guard let app = launchWalk(Self.severance, layout: "apple", tmdb: true,
                                   sections: ["about": about], seedComments: true) else { return }
        let label = app.staticTexts["debug_detail_sections"]
        guard label.exists, label.label.contains("comments:") else {
            XCTFail("\(tag): comments seed refused or absent — \(label.exists ? label.label : "no probe")")
            return
        }
        guard let r = walkDownToEnd(app, tag: tag) else { return }
        screenshot("\(tag)-end")
        try assertWalk(r, tag, commentCount: Self.commentsSeedCount)
        // I7: the comments list body does not re-run for focus moves outside it.
        let atFirstComment = r.samples.first { $0.comment == 0 }?.cbody
        if let initial = r.initialCBody, let first = atFirstComment {
            XCTAssertLessThanOrEqual(first - initial, 1, "\(tag) CBODY: the comments list body re-ran \(first - initial) times on the walk to the first card (settled \(initial))")
        }
        if about {
            // The pass-7 clip: About's bottom edge inside the pane at the end.
            XCTAssertEqual(r.samples.last?.row, "about", "\(tag): the walk must end on About — \(r.samples)")
        } else {
            XCTAssertEqual(r.samples.last?.row, "comments", "\(tag): the walk must end on the last comment card — \(r.samples)")
        }
    }

    /// U3: the tester's case: Apple-style, TMDB on, About off, Trakt comments (seeded).
    func testCommentsReachableAboutOff() throws { try commentsLeg(about: false, tag: "U3") }

    /// U4: the same with About on: Down enters every card, then About, whole.
    func testCommentsThenAboutWhole() throws { try commentsLeg(about: true, tag: "U4") }

    /// R1 (invariant): Cinematic with every section on and no tail: no tail stop exists and the walk
    /// ends on About.
    func testCinematicDefaultsWalkUnchanged() throws {
        let all: [String: Bool] = ["about": true, "more_like_this": true, "trailers": true, "comments": true,
                                   "parental_guide": true, "cast": true, "collection": true, "studio_logos": true]
        guard let app = launchWalk(Self.severance, layout: "cinematic", tmdb: false, sections: all) else { return }
        guard let r = walkDownToEnd(app) else { return }
        screenshot("r1-cinematic-end")
        attachWalk("R1", r)
        if r.hasSectionsProbe {
            XCTAssertTrue(r.tail.isEmpty, "R1: the tail must be empty — \(r.tail)")
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'detail_tail_stop_'")).firstMatch.exists, "R1: a tail stop exists")
        }
        XCTAssertEqual(r.samples.last?.row, "about", "R1: the walk ends on About — \(r.samples)")
        assertEnd(r, "R1")
        print("[BUG244] R1 rowSequence=\(rowSequence(r))")
    }

    /// R2 (invariant): Apple-style, TMDB on, every section on, no seed: same.
    func testAppleStyleTmdbOnWalkUnchanged() throws {
        let all: [String: Bool] = ["about": true, "more_like_this": true, "trailers": true, "comments": true,
                                   "parental_guide": true, "cast": true, "collection": true, "studio_logos": true]
        guard let app = launchWalk(Self.severance, layout: "apple", tmdb: true, sections: all) else { return }
        guard let r = walkDownToEnd(app) else { return }
        screenshot("r2-apple-end")
        attachWalk("R2", r)
        if r.hasSectionsProbe {
            XCTAssertTrue(r.tail.isEmpty, "R2: the tail must be empty — \(r.tail)")
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'detail_tail_stop_'")).firstMatch.exists, "R2: a tail stop exists")
        }
        XCTAssertEqual(r.samples.last?.row, "about", "R2: the walk ends on About — \(r.samples)")
        assertEnd(r, "R2")
        print("[BUG244] R2 rowSequence=\(rowSequence(r))")
    }

    // MARK: Reach, hand-off and the no-change baseline (round 1)

    private func focusReading(_ app: XCUIApplication) -> (row: String, idx: String) {
        let t = Self.tokens(app.staticTexts["debug_detail_focus"].label)
        return (t["row"] ?? "?", t["idx"] ?? "-")
    }

    /// Down one press at a time until the probe reports `row` (at most `max` presses).
    @discardableResult
    private func pressDown(_ app: XCUIApplication, until row: String, max: Int = 8) -> Bool {
        if app.buttons["Playback unavailable"].exists { press(.left, times: 4, gap: 0.6) }
        for n in 0..<max {
            print("[BUG244] pressDown \(n) reading \(focusReading(app)) tail=\(tailTokens(app).sorted())")
            if focusReading(app).row == row { return true }
            press(.down, times: 1, gap: 0.8)
            pause(1.5)
        }
        return focusReading(app).row == row
    }

    private func tailTokens(_ app: XCUIApplication) -> Set<String> {
        let label = app.staticTexts["debug_detail_sections"]
        guard label.exists else { return [] }
        return Set((Self.tokens(label.label)["tail"] ?? "").split(separator: ",").map(String.init))
    }

    /// Finding 3 (Cast stop): with focus on the right-most Episodes card, Down lands on the names-only
    /// Cast stop (its platter hugs the names, its focus reach spans the page), then on Parental Guide.
    func testCastStopReachableFromTheRightmostCardAbove() throws {
        guard let app = launchWalk(Self.severance, layout: "apple", tmdb: false,
                                   sections: ["about": false, "more_like_this": false, "comments": false, "trailers": false]) else { return }
        guard tailTokens(app).contains("castAndCrew") else { throw XCTSkip("no names-only Cast tail on this title today") }
        XCTAssertTrue(pressDown(app, until: "episodes"), "Down never reached Episodes")
        // Apple-style: the first Episodes stop is the season tab row; Down once more reaches a card.
        press(.down, times: 1, gap: 0.8)
        pause(1.2)
        press(.right, times: 14, gap: 0.5)
        pause(1)
        press(.down, times: 1, gap: 0.8)
        pause(1.5)
        screenshot("reach-cast-stop")
        print("[BUG244] reach-cast reading \(focusReading(app)) sections=\(app.staticTexts["debug_detail_sections"].label)")
        XCTAssertEqual(focusReading(app).row, "cast", "Down from the right-most Episodes card must land on the Cast stop")
        XCTAssertTrue(app.descendants(matching: .any)["detail_tail_stop_castAndCrew"].exists)
    }

    /// Finding 3 (Parental Guide): with focus on the right-most Cast card (a wide row), Down lands on
    /// the Parental Guide stop although the chip row is narrow.
    func testParentalStopReachableFromTheRightmostCardAbove() throws {
        guard let app = launchWalk(Self.severance, layout: "apple", tmdb: true,
                                   sections: ["about": false, "studio_logos": false, "collection": false, "comments": false,
                                              "more_like_this": false, "trailers": false]) else { return }
        guard tailTokens(app) == ["parentalGuide"] else { throw XCTSkip("no Parental-Guide-only tail today: \(tailTokens(app))") }
        XCTAssertTrue(pressDown(app, until: "cast"), "Down never reached Cast")
        press(.right, times: 30, gap: 0.4)
        pause(1)
        press(.down, times: 1, gap: 0.8)
        pause(1.5)
        XCTAssertEqual(focusReading(app).row, "parental", "Down from the right-most Cast card must land on the Parental Guide stop")
        XCTAssertTrue(app.descendants(matching: .any)["detail_tail_stop_parentalGuide"].exists)
        screenshot("reach-parental-stop")
    }

    /// Finding 1: TMDB ids arrive (`-debug.detailCastIdsDelay`) while the names-only Cast stop holds
    /// focus: the wrapper goes and focus is handed to a person link, never nil.
    func testCastIdsArrivingUnderTheFocusedStopHandFocusToALink() throws {
        guard let app = launchWalk(Self.severance, layout: "apple", tmdb: true,
                                   sections: ["about": false, "studio_logos": false, "collection": false, "comments": false,
                                              "more_like_this": false, "trailers": false],
                                   extra: ["-debug.detailCastIdsDelay", "75"]) else { return }
        guard tailTokens(app).contains("castAndCrew") else { throw XCTSkip("ids were not withheld / no Cast tail: \(tailTokens(app))") }
        XCTAssertTrue(pressDown(app, until: "cast"), "Down never reached the Cast stop")
        let stop = app.descendants(matching: .any)["detail_tail_stop_castAndCrew"]
        guard stop.exists else { throw XCTSkip("the Cast stop was already gone (ids arrived before focus)") }
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline, stop.exists { pause(1) }
        XCTAssertFalse(stop.exists, "the Cast stop wrapper must be removed once the ids arrive")
        pause(3)
        let after = focusReading(app)
        XCTAssertEqual(after.row, "cast", "focus must stay in the Cast row, not fall to nil")
        XCTAssertNotEqual(after.idx, "-", "focus must be on a person link (the focus memory holds its key)")
        screenshot("handoff-person-link")
    }

    /// Review finding A (late card): only a card beyond the built ones carries an id when the ids
    /// arrive (`-debug.detailCastIdsFromCard 10`: the first 10 cards have none, the 11th has one) while the
    /// stop holds focus. The hand-off cannot assign (that card is not built) and is not retried: afterwards the
    /// stop element is gone and focus is not nil.
    func testLateIdCardDropsTheHeldStopAndLinksStayFocusable() throws {
        guard let app = launchWalk(Self.severance, layout: "apple", tmdb: true,
                                   sections: ["about": false, "studio_logos": false, "collection": false, "comments": false,
                                              "more_like_this": false, "trailers": false],
                                   extra: ["-debug.detailCastIdsDelay", "75", "-debug.detailCastIdsFromCard", "10"]) else { return }
        guard tailTokens(app).contains("castAndCrew") else { throw XCTSkip("ids were not withheld / no Cast tail: \(tailTokens(app))") }
        XCTAssertTrue(pressDown(app, until: "cast"), "Down never reached the Cast stop")
        let stop = app.descendants(matching: .any)["detail_tail_stop_castAndCrew"]
        guard stop.exists else { throw XCTSkip("the Cast stop was already gone (ids arrived before focus)") }
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline, stop.exists { pause(1) }
        XCTAssertFalse(stop.exists, "the held Cast stop must be dropped after one pass, whether or not focus reached a link")
        pause(3)
        print("[BUG244] late-card after-drop reading \(focusReading(app)) sections=\(app.staticTexts["debug_detail_sections"].label)")
        screenshot("late-card-after-drop")
        // The 11th card was not built, so nothing could be assigned and the engine placed focus itself
        // (here: back up on the Episodes row, never nil). The stop stays gone. Whether Down then reaches
        // the unbuilt 11th card is the lazy row's own limit (no built view is focusable), so it is only
        // reported, not asserted.
        XCTAssertNotEqual(focusReading(app).row, "-", "focus must not be nil after the stop is dropped")
        XCTAssertFalse(stop.exists)
        let reached = pressDown(app, until: "cast", max: 3)
        print("[BUG244] late-card Down reaches Cast row: \(reached) reading \(focusReading(app))")
    }

    /// Finding 4: with no comments and no tail rows, the focus sequence and the scroll offset at each
    /// stop equal the constants measured on `b055a42a2` (the commit before the fix), in all three
    /// layouts. Record mode (no constants for a tag) only prints `[BASELINE]` lines.
    /// Measured on `b055a42a2` (the commit before the fix, app sources temporarily restored to it,
    /// 2026-11-12, sim clone 855DC175, Severance, guest fixture): the focus rows after each Down press
    /// with the page's scroll offset at each rest. Larger Text: no launch argument or helper exists
    /// for it on tvOS here, so no walk covers it.
    private static let baselineWalks: [String: [(row: String, off: Double)]] = [
        "base-cinematic": [("-", 0), ("episodes", 844), ("trailers", 1640), ("about", 1652)],
        "base-apple": [("-", 0), ("episodes", 792), ("trailers", 934), ("bonus", 1388), ("moreLikeThis", 1965),
                       ("cast", 2400), ("logos", 2502), ("about", 3111)],
        "base-classic": [("-", 0), ("logos", 84), ("episodes", 574), ("cast", 1420), ("trailers", 2259),
                         ("moreLikeThis", 2269)],
    ]

    /// `tolerance`: Cinematic and Apple-style repeat to within 2 pt; Classic's mid-page rests wander by up
    /// to ~14 pt between identical runs (episodes 567-574, cast 1414-1420, trailers 2245-2259 on this
    /// clone, base commit measured once), so it gets 16 pt. The focus sequence is exact in all three.
    private func baselineWalk(layout: String, tmdb: Bool, sections: [String: Bool], tag: String,
                              tolerance: Double = 2) throws {
        guard let app = launchWalk(Self.severance, layout: layout, tmdb: tmdb, sections: sections) else { return }
        guard let r = walkDownToEnd(app, tag: tag) else { return }
        attachWalk(tag, r)
        // One reading per distinct (row, rounded offset): the sequence the viewer sees.
        var seq: [(row: String, off: Double)] = []
        for s in r.samples {
            let item = (row: s.row, off: s.off.rounded())
            if let last = seq.last, last.row == item.row, abs(last.off - item.off) < 1 { continue }
            seq.append(item)
        }
        print("[BASELINE \(tag)] " + seq.map { "\($0.row)@\(Int($0.off))" }.joined(separator: ","))
        if r.hasSectionsProbe { XCTAssertTrue(r.tail.isEmpty, "\(tag): the fixture must have no tail — \(r.tail)") }
        guard let want = Self.baselineWalks[tag] else { return }
        XCTAssertEqual(seq.map(\.row), want.map(\.row), "\(tag) focus sequence differs from the base commit — \(seq)")
        if seq.count == want.count {
            for (got, exp) in zip(seq, want) {
                XCTAssertEqual(got.off, exp.off, accuracy: tolerance, "\(tag) offset at \(got.row) differs from the base commit — \(seq)")
            }
        }
    }

    private static let everySection: [String: Bool] = ["about": true, "more_like_this": true, "trailers": true, "comments": true,
                                                       "parental_guide": true, "cast": true, "collection": true, "studio_logos": true]

    func testBaselineWalkCinematic() throws {
        try baselineWalk(layout: "cinematic", tmdb: false, sections: Self.everySection, tag: "base-cinematic")
    }
    func testBaselineWalkAppleStyle() throws {
        try baselineWalk(layout: "apple", tmdb: true, sections: Self.everySection, tag: "base-apple")
    }
    func testBaselineWalkClassic() throws {
        var s = Self.everySection
        s["comments"] = false
        try baselineWalk(layout: "classic", tmdb: true, sections: s, tag: "base-classic", tolerance: 16)
    }
}
