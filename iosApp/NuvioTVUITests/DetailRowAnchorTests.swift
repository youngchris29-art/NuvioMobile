import XCTest

/// BUG-96 (beta.18): on the detail page, a vertical focus move must leave every section header
/// either fully on screen or fully off it — never straddling the top edge (the tester's photos:
/// "Guide parental" cut in half above a focused Saga row) — and the focused row's title must rest
/// near `DetailRowAnchor.topInset`.
///
/// Oracle: XCUI frames of the section-title `staticTexts` at rest after each Down press. The tvOS
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
        app.launchArguments += ["-home_upcoming_row_enabled", "NO",
                                "-debug.trailerProbe", "YES", "-debug.trailerForceNoTrailer", "YES",
                                "-debug.detailScrollProbe", "YES"]
        app.launch()
        let chris = app.buttons["Chris"]
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the sim session still signed in?")
        if chris.exists {
            if !chris.hasFocus { press(.left, times: 3, gap: 0.5) }
            remote.press(.select)
        }
        pause(10)
        return app
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
        // test02's route to a real DetailView: a movies catalog row (portrait cards → NavigationLink).
        press(.down, times: 4)
        pause(0.5)
        remote.press(.select)
        pause(8)
        guard app.staticTexts["debug_ux6"].waitForExistence(timeout: 6) else {
            throw XCTSkip("no detail page opened (debug_ux6 probe absent) — the down×4 walk did not land on a movies row on this fixture; nothing to measure")
        }
        // FEAT-32: the page auto-enters the full-screen trailer cover a few seconds in (its caption
        // carries the Back hint). `forceNoTrailer` does not gate that path, so back out of the
        // cover once and settle before walking; the auto-entry fires once per page.
        // The Back hint element persists on the page (it is the cover's caption, kept mounted), so
        // its presence is not proof the cover is up; press Menu once regardless — on the page it is
        // a no-op for focus, inside the cover it returns to the page.
        pause(6)
        if app.staticTexts["Press Back to exit the trailer"].exists {
            remote.press(.menu)
            pause(3)
        }

        var anchoredHits = 0
        var anchorSamples = 0
        var anchoredRows = Set<String>()
        var straddles: [String] = []
        // BUG-96 rc5 regression fix: `moves=` is `DetailScrollMotion.segments` over this focus
        // visit's raw offset samples — `1` means the engine's reveal and the anchor pass blended
        // into one motion, `2`+ means the old land-then-nudge two-step move is back. Kept alongside
        // the `(top − off) − 108` residual per step so both survive in the failure message and in
        // an attachment even when the run passes.
        var movesByStep: [(step: Int, moves: Int)] = []
        var residualByStep: [(step: Int, residual: Double)] = []
        for step in 1...6 {
            press(.down, times: 1, gap: 1.4)
            // Only the anchored rows' section titles are the oracle; the top block's details grid
            // (Network, Country, …) is not an anchored row.
            let sectionLabels: Set<String> = ["Parental Guide", "Guide parental", "Cast", "Casting", "Episodes", "Épisodes",
                                              "Trailers & Extras", "Bandes-annonces et extras", "More Like This", "Comments"]
            let titles = sectionTitleFrames(app).filter { sectionLabels.contains($0.label) || $0.label.hasSuffix("Saga") || $0.label.hasSuffix("Collection") }
            for (label, f) in titles {
                // Straddling: the top edge cuts through the title's own glyph box AND the title sits
                // below the top scrim's opaque zone (a header under the scrim is faded away, not cut).
                if f.minY > 40, f.minY < f.height * 0.8 {
                    straddles.append("step \(step): '\(label)' minY=\(Int(f.minY)) h=\(Int(f.height))")
                }
            }
            // The anchor oracle reads the app's own probe: `anchor=<row> top=<content y> …` and
            // `geo=off=<content offset>`; the focused row's screen top is `top − off`, and it must
            // rest at `DetailRowAnchor.screenRest` (108). Title heuristics are not used for this —
            // rows whose top is not a title (season chips, logos) and titles the accessibility
            // walk does not list (Cast) would make it vacuous.
            let probeLabel = app.staticTexts["debug_ux6"].exists ? app.staticTexts["debug_ux6"].label : ""
            if let top = probeNumber(probeLabel, key: "top="), let off = probeNumber(probeLabel, key: "off=") {
                anchorSamples += 1
                let residual = (top - off) - 108
                residualByStep.append((step, residual))
                // ±16: the content height can shift a few points after the sample (late images).
                if abs(residual) <= 16 { anchoredHits += 1 }
                // Codex BUG-96 r3 (P3): a stuck focus would repeat one good sample on every press —
                // the walk must reach DISTINCT anchored rows, not the same one six times.
                if let range = probeLabel.range(of: "anchor=") {
                    let row = probeLabel[range.upperBound...].prefix { $0 != " " }
                    anchoredRows.insert(String(row))
                }
                // BUG-96 rc5: the motion-segment count sampled alongside this same at-rest probe
                // read — `debug_ux6`'s `geo=` mirrors `dimModel.geometrySample`, which carries
                // `moves=` (see `DetailView`'s scroll-geometry handler).
                if let moves = probeNumber(probeLabel, key: "moves=") {
                    movesByStep.append((step, Int(moves)))
                }
            }
            let visible = titles.filter { $0.frame.minY >= 0 && $0.frame.maxY <= 1080 }.map { "\($0.label)@\(Int($0.frame.minY))" }
            let shotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shotAttachment.name = "bug96_step\(step)"
            shotAttachment.lifetime = .keepAlways
            add(shotAttachment)
            let probe = app.staticTexts["debug_ux6"]
            print("[BUG96] step \(step) titles=\(visible) probe=\(probe.exists ? probe.label : "-")")
        }
        XCTAssertTrue(straddles.isEmpty, "BUG-96: a section header straddled the top edge at rest — \(straddles)")
        XCTAssertGreaterThanOrEqual(anchorSamples, 4, "BUG-96: the probe never reported an anchored row — is -debug.detailScrollProbe on?")
        XCTAssertGreaterThanOrEqual(anchoredRows.count, 3,
                                    "BUG-96: the Down walk must anchor at least three DISTINCT rows (saw \(anchoredRows.sorted())) — a repeated sample means focus was stuck")
        XCTAssertGreaterThanOrEqual(anchoredHits, anchorSamples - 1,
                                    "BUG-96: the focused row's top must rest at DetailRowAnchor.screenRest (108) after each move; \(anchoredHits)/\(anchorSamples) did")

        // BUG-96 rc5 regression fix: numbers first, so they survive a PASSING run too — the
        // experiment report needs the moves= distribution and residuals per variant regardless of
        // outcome, not just on failure.
        let movesDescription = movesByStep.map { "step\($0.step)=\($0.moves)" }.joined(separator: " ")
        let residualDescription = residualByStep.map { "step\($0.step)=\(String(format: "%.0f", $0.residual))" }.joined(separator: " ")
        XCTContext.runActivity(named: "BUG-96 moves= distribution and (top-off-108) residuals") { activity in
            let attachment = XCTAttachment(string: "moves: \(movesDescription)\nresiduals(top-off-108): \(residualDescription)")
            attachment.name = "bug96_moves_and_residuals"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        print("[BUG96] moves=\(movesDescription) residuals=\(residualDescription)")

        // The blend fix's whole point: every at-rest sample reads as ONE motion. `moves=2`+ is the
        // land-then-nudge regression rc5 reported.
        let multiMoveSteps = movesByStep.filter { $0.moves > 1 }
        XCTAssertTrue(multiMoveSteps.isEmpty,
                      "BUG-96: a Down press landed in more than one visible motion (land-then-nudge) — " +
                      "steps \(multiMoveSteps.map { "step\($0.step)=\($0.moves)" }) — full distribution moves: \(movesDescription) residuals(top-off-108): \(residualDescription)")

        remote.press(.menu)
        pause(1)
    }
}
