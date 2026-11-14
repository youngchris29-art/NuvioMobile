import XCTest

/// Home Watchlist row (FEAT-92), W3 brief 3: the UI legs for the Watchlist row under Continue Watching
/// in both Home layouts (spec section 6, `docs/spec-home-watchlist-row-2026-11-12.md`).
///
/// The row is a `HomeCatalogSection` with key `home-watchlist`, shown under Continue Watching and
/// above Upcoming. A guest has no Trakt or Simkl, so the legs inject it with the DEBUG seed
/// (`-debug.homeWatchlistSeedJsonB64`, in-memory) and, where a leg needs them, the Continue Watching
/// seed (`-debug.continueWatchingSeedJsonB64`, persistent: every leg that uses it clears it again in
/// `defer`), the Upcoming seed (`-debug.homeUpcomingSeedJsonB64`, in-memory) and the no-catalog-rows
/// knob (`-debug.homeNoCatalogRows`).
///
/// Oracles are the DEBUG readouts, never accessibility frames of moving things:
///   - Classic: `debug_homeReturn own=<rowKey>` (the row holding focus now), `debug_pinned` (the last
///     pinned settle: `row= vh= rowH= last= lastRowShaped=`), `debug_hero pitem=` (the presented hero);
///   - Stage: `debug_strip key= row= foc=<rowKey>/<itemId> atTop=`, `debug_stage disp=<type:id>`,
///     `debug_strip_fit key=<rowKey> m= h= | ...`;
///   - both: `debug_homeWatchlist on= n= first=`.
///
/// Fixture facts: FA87 or the project's sim clone, guest "Chris" with Cinemeta, Medium posters. FA87 may
/// carry stored watch progress from the player-harness classes (`smoke-mpv`): the no-Continue-Watching
/// legs 17-19 then skip (§22), and the others accept a Continue Watching row above the rows they test.
/// In Tabs mode the launch lands focus on the tab bar, so the first Down enters the strip (Stage)
/// or the hero (Classic).
///
/// Helpers are this file's own (the harness's duplication rule: every UI test file owns its helpers;
/// copied from `StageStripUITests` and `StripFitNoZoomUITests`).
final class HomeWatchlistRowUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// A harness precondition that makes the rest of a leg meaningless.
    private struct HarnessAbort: Error, CustomStringConvertible {
        let description: String
        init(_ reason: String) { description = reason }
    }

    // MARK: - Basics

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
        print("[HomeWatchlistRowUITests] \(name): \(text)")
    }

    private func poll(_ timeout: TimeInterval, step: TimeInterval = 0.2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(step)
        }
        return condition()
    }

    /// Fresh launch with `arguments`, then the profile gate ("Chris" is the first profile and focused
    /// by default), then `settle`.
    @discardableResult
    private func launch(_ arguments: [String], settle: TimeInterval = 14) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        let chris = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chris")).firstMatch
        XCTAssertTrue(chris.waitForExistence(timeout: 90), "profile picker never appeared — is the fixture set up?")
        if chris.exists {
            DetailEntryRoute.selectChrisTile(self, app, timeout: 5)
        }
        pause(settle)
        return app
    }

    private func label(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        return element.exists ? element.label : ""
    }

    /// `key=value` out of a readout line, matched on the exact key.
    private static func token(_ line: String, _ key: String) -> String? {
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == Substring(key) else { continue }
            return String(pair[1])
        }
        return nil
    }

    private static func int(_ line: String, _ key: String) -> Int? { token(line, key).flatMap { Int($0) } }

    /// One row's `(m, h)` out of `debug_strip_fit`, nil when that row has no measurement yet
    /// (`StripFitNoZoomUITests.fit`).
    private static func fit(_ line: String, rowKey: String) -> (measured: Double, page: Double)? {
        let body = line.hasPrefix("debug_strip_fit ") ? String(line.dropFirst("debug_strip_fit ".count)) : line
        for entry in body.components(separatedBy: " | ") where token(entry, "key") == rowKey {
            guard let m = token(entry, "m").flatMap(Double.init),
                  let h = token(entry, "h").flatMap(Double.init) else { return nil }
            return (m, h)
        }
        return nil
    }

    // MARK: - Seeds and launch arguments

    private static func b64(_ array: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8)
        return data.base64EncodedString()
    }

    private static let cwEntry: [String: Any] = ["type": "movie", "id": "tt0111161", "title": "The Shawshank Redemption",
                                                 "positionMin": 60, "durationMin": 142]
    private static var cwSeed: String { b64([cwEntry]) }

    private static func watchlistItem(_ type: String, _ id: String, _ name: String) -> [String: Any] {
        ["type": type, "id": id, "name": name,
         "poster": "https://images.metahub.space/poster/medium/\(id)/img",
         "background": "https://images.metahub.space/background/medium/\(id)/img",
         "logo": "https://images.metahub.space/logo/medium/\(id)/img"]
    }

    private static let wlFirst = "movie:tt0068646"
    private static var wlSeed: String {
        b64([watchlistItem("movie", "tt0068646", "The Godfather"),
             watchlistItem("series", "tt0903747", "Breaking Bad"),
             watchlistItem("movie", "tt0110912", "Pulp Fiction")])
    }

    private static var upSeed: String {
        b64([["showId": "tt0944947", "showTitle": "Game of Thrones", "season": 8, "episode": 1, "daysUntilAir": 1,
              "showYear": "2011", "episodeTitle": "Winterfell",
              "poster": "https://images.metahub.space/poster/medium/tt0944947/img",
              "background": "https://images.metahub.space/background/medium/tt0944947/img",
              "logo": "https://images.metahub.space/logo/medium/tt0944947/img"]])
    }

    private static let baseArguments = ["-inline_trailers_enabled", "NO", "-hero_trailer_autoplay", "NO",
                                        "-sidebar_style", "tabs", "-debug.homeScrollProbe", "YES"]
    private static let classicBase = ["-home_layout", "classic", "-hero_nuvio_style", "YES"] + baseArguments
    private static let stageBase = ["-home_layout", "stage", "-debug.stripFitRows", "YES"] + baseArguments

    /// One Watchlist/Upcoming combination of the spec's table (CW is always seeded).
    private struct Combo {
        let name: String
        let watchlist: Bool
        let upcoming: Bool

        /// Top rows after Continue Watching, in order.
        var below: [String] { (watchlist ? ["home-watchlist"] : []) + (upcoming ? ["upcoming"] : []) }
        var topRows: [String] { ["continue-watching"] + below }
        /// The Down sequence from Continue Watching: the rows below, then the first catalog row.
        var down: [String] { below + ["c1"] }
        /// The Up sequence from the first catalog row back to Continue Watching.
        var up: [String] { Array(below.reversed()) + ["continue-watching"] }
        var last: String { topRows.last ?? "continue-watching" }

        /// Seeds and toggles of this combination (Continue Watching seeded).
        var arguments: [String] {
            var out = ["-debug.continueWatchingSeedJsonB64", HomeWatchlistRowUITests.cwSeed,
                       "-home_upcoming_row_enabled", upcoming ? "YES" : "NO"]
            if watchlist { out += ["-debug.homeWatchlistSeedJsonB64", HomeWatchlistRowUITests.wlSeed] }
            if upcoming { out += ["-debug.homeUpcomingSeedJsonB64", HomeWatchlistRowUITests.upSeed] }
            return out
        }
    }

    private static let comboA = Combo(name: "A", watchlist: false, upcoming: false)
    private static let comboB = Combo(name: "B", watchlist: true, upcoming: false)
    private static let comboC = Combo(name: "C", watchlist: false, upcoming: true)
    private static let comboD = Combo(name: "D", watchlist: true, upcoming: true)

    private static let topKeys: Set<String> = ["continue-watching", "home-watchlist", "upcoming"]

    /// Clears the persistent Continue Watching seed (the S15 recipe).
    private func clearContinueWatchingSeed() {
        var removal = Self.cwEntry
        removal["remove"] = true
        let cleanup = launch(["-debug.continueWatchingSeedJsonB64", Self.b64([removal])], settle: 8)
        cleanup.terminate()
    }

    /// Skips only when the seed was provably refused (`seed=refused`: the fixture is not a guest, or a
    /// tracker is the progress source). On a guest fixture a missing or empty row is a failure.
    private func requireWatchlistSeed(_ app: XCUIApplication) throws {
        var line = ""
        _ = poll(25, step: 0.5) {
            line = label(app, "debug_homeWatchlist")
            return Self.token(line, "seed") == "refused" || (Self.int(line, "n") ?? 0) > 0
        }
        if Self.token(line, "seed") == "refused" {
            throw XCTSkip("fixture is not a guest (the Watchlist seed was refused): '\(line)'")
        }
        guard !line.isEmpty else {
            XCTFail("debug_homeWatchlist is missing: not a DEBUG build, or the readout is unmounted")
            throw HarnessAbort("no debug_homeWatchlist")
        }
        guard (Self.int(line, "n") ?? 0) > 0 else {
            XCTFail("the seeded Watchlist row never appeared on a guest fixture: '\(line)'")
            throw HarnessAbort("no seeded Watchlist row")
        }
        XCTAssertEqual(Self.token(line, "seed"), "applied", "seed status: '\(line)'")
        XCTAssertEqual(Self.token(line, "first"), Self.wlFirst, "the seeded Watchlist's first item: '\(line)'")
    }

    // MARK: - Fixture precondition: stored watch progress (§22)

    /// The Continue Watching items this fixture shows with no seed at all: a Classic launch with no
    /// catalog rows, no Watchlist and no Upcoming, so the only row Down can reach is Continue Watching
    /// (the Combo A last-row leg's launch minus its seed). Empty when the fixture has no stored progress.
    private func storedContinueWatchingItems() throws -> [String] {
        let app = launch(Self.classicBase + ["-home_upcoming_row_enabled", "NO", "-debug.homeNoCatalogRows", "YES"])
        defer { app.terminate() }
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty }) else {
            throw HarnessAbort("debug_homeReturn never appeared in the stored-progress probe")
        }
        var onContinueWatching = false
        for _ in 0..<4 where !onContinueWatching {
            onContinueWatching = classicStep(app, .down) == "continue-watching"
        }
        guard onContinueWatching else { return [] }
        func focusedItem() -> String? {
            guard let foc = Self.token(label(app, "debug_homeReturn"), "foc"),
                  foc.hasPrefix("continue-watching/") else { return nil }
            return String(foc.dropFirst("continue-watching/".count))
        }
        var items = focusedItem().map { [$0] } ?? ["?"]
        for _ in 0..<6 {
            remote.press(.right)
            pause(1.0)
            guard let item = focusedItem(), item != items.last else { break }
            items.append(item)
        }
        return items
    }

    /// The no-Continue-Watching legs (17-19) need a fixture without stored watch progress. A fixture
    /// with history (FA87 after the player-harness classes) skips them; this class's own seed left
    /// behind fails them.
    private func requireNoStoredContinueWatching() throws {
        let items = try storedContinueWatchingItems()
        note("stored_progress_probe", "Continue Watching with no seed: \(items)")
        guard !items.isEmpty else { return }
        let ownSeed = (Self.cwEntry["id"] as? String) ?? "tt0111161"
        if items.contains(where: { $0.contains(ownSeed) }) {
            XCTFail("this class's Continue Watching seed (\(ownSeed)) survived its cleanup: \(items) (a test-hygiene defect, not a fixture condition)")
            throw HarnessAbort("own Continue Watching seed left behind")
        }
        throw XCTSkip("fixture has stored watch progress (\(items.joined(separator: ","))); the no-Continue-Watching case is covered on a clean guest fixture")
    }

    // MARK: - Classic readouts and walks

    private func own(_ app: XCUIApplication) -> String { Self.token(label(app, "debug_homeReturn"), "own") ?? "-" }

    /// Presses `button` once, rests 1.8 s, and returns the row now owning focus (a second short wait
    /// when the readout is mid-motion and reads "-").
    @discardableResult
    private func classicStep(_ app: XCUIApplication, _ button: XCUIRemote.Button) -> String {
        remote.press(button)
        pause(1.8)
        var key = own(app)
        if key == "-" {
            _ = poll(2.0, step: 0.25) { own(app) != "-" }
            key = own(app)
        }
        return key
    }

    /// The last `debug_pinned` settle line whose `row=` is `key`, waited for up to 4 s.
    private func pinnedLine(_ app: XCUIApplication, row key: String) -> String? {
        var found: String?
        _ = poll(4.0, step: 0.25) {
            let line = label(app, "debug_pinned")
            if Self.token(line, "row") == key { found = line; return true }
            return false
        }
        return found
    }

    private static func normalized(_ key: String) -> String { topKeys.contains(key) ? key : "c1" }

    private struct ClassicWalk {
        var down: [String] = []
        var up: [String] = []
        var c1Key = "-"
        var pinned: [String: String] = [:]
    }

    /// Down until Continue Watching owns focus (≤ 5 presses), Down recording each `own=` until a
    /// non-top key, Up once, then Up until Continue Watching.
    private func classicWalkFromCW(_ app: XCUIApplication, guestProven: Bool) throws -> ClassicWalk {
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty }) else {
            throw HarnessAbort("debug_homeReturn never appeared (DEBUG build? -home_layout classic honoured?)")
        }
        var reached = false
        for _ in 0..<5 {
            if classicStep(app, .down) == "continue-watching" { reached = true; break }
        }
        guard reached else {
            let why = "the Continue Watching seed did not land (own=\(own(app)))"
            if guestProven { XCTFail(why + " on a guest fixture"); throw HarnessAbort(why) }
            throw XCTSkip(why + ": refused on a signed-in account?")
        }
        var walk = ClassicWalk()
        for _ in 0..<6 {
            let before = own(app)
            let key = classicStep(app, .down)
            if key == before { walk.down.append("stuck:\(key)"); break }
            walk.down.append(Self.normalized(key))
            if let line = pinnedLine(app, row: key) { walk.pinned[key] = line }
            if !Self.topKeys.contains(key) { walk.c1Key = key; break }
        }
        for _ in 0..<6 {
            let before = own(app)
            let key = classicStep(app, .up)
            if key == before { walk.up.append("stuck:\(key)"); break }
            walk.up.append(Self.normalized(key))
            if key == "continue-watching" { break }
        }
        note("classic_walk", "down=\(walk.down) up=\(walk.up) c1=\(walk.c1Key)\n" +
             walk.pinned.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
        return walk
    }

    private func assertClassicCombo(_ combo: Combo) throws {
        defer { clearContinueWatchingSeed() }
        let app = launch(Self.classicBase + combo.arguments)
        if combo.watchlist { try requireWatchlistSeed(app) }
        let walk = try classicWalkFromCW(app, guestProven: combo.watchlist)
        shot("classic_combo\(combo.name)")
        XCTAssertEqual(walk.down, combo.down, "Combo \(combo.name): the Down sequence from Continue Watching")
        if combo.name == "D" {
            XCTAssertEqual(walk.up, combo.up, "Combo D: the Up sequence from the first catalog row")
        } else {
            // prev(c1). combo.up.first is combo.below.last, or "continue-watching" for A.
            // Combo A: prev(c1) is Continue Watching itself, the very case the expected failure below
            // covers (the sim lands on the hero CTA), so its first Up is checked only inside it.
            if combo.up.first != "continue-watching" {
                XCTAssertEqual(walk.up.first, combo.up.first, "Combo \(combo.name): the first Up from c1 gives prev(c1)")
            }
            let options = XCTExpectedFailure.Options()
            options.isStrict = false
            XCTExpectFailure("Sim-only and pre-existing (fails on 996a274c4): Up into a still-realized Continue Watching row under the pinned hero lands on the hero CTA, and the redirect's isEngineSkip needs press-after-focus ordering that only hardware gives; see docs/folder-return-up-skip-root-cause-2026-10-17.md; device check in W5.", options: options) {
                XCTAssertEqual(walk.up, combo.up, "Combo \(combo.name): the Up sequence from the first catalog row")
            }
        }
        if combo.watchlist {
            let wl = walk.pinned["home-watchlist"] ?? ""
            let c1 = walk.pinned[walk.c1Key] ?? ""
            let wlH = Self.int(wl, "rowH"), c1H = Self.int(c1, "rowH")
            XCTAssertNotNil(wlH, "no debug_pinned settle for home-watchlist: '\(wl)'")
            XCTAssertEqual(wlH, c1H, "G6 = G5: the Watchlist's rowH equals the catalog row's: wl='\(wl)' c1='\(c1)'")
            XCTAssertEqual(Self.token(wl, "last"), "0", "the Watchlist is not the last row here: '\(wl)'")
        }
    }

    // MARK: - Stage readouts and walks

    private func strip(_ app: XCUIApplication) -> String { label(app, "debug_strip") }
    private func stage(_ app: XCUIApplication) -> String { label(app, "debug_stage") }
    private func stripKey(_ app: XCUIApplication) -> String { Self.token(strip(app), "key") ?? "-" }

    private static let tabTitles = ["Home", "Search", "Library", "Add-ons", "Settings", "Profile"]
    private func tabBarFocused(_ app: XCUIApplication) -> Bool {
        Self.tabTitles.contains { app.buttons[$0].exists && app.buttons[$0].hasFocus }
    }

    /// Waits for Stage Home (`debug_stage` with its geometry and a shown title) and returns its line.
    private func requireStage(_ app: XCUIApplication) throws -> String {
        var line = ""
        let ready = poll(30, step: 0.5) {
            line = stage(app)
            return Self.token(line, "stageH") != nil && (Self.token(line, "shown") ?? "-") != "-"
        }
        guard ready else { throw HarnessAbort("Stage Home never came up: debug_stage='\(line)'") }
        return line
    }

    @discardableResult
    private func stageStep(_ app: XCUIApplication, _ button: XCUIRemote.Button) -> String {
        remote.press(button)
        pause(3.0)
        return stripKey(app)
    }

    private struct StageWalk {
        var down: [String] = []
        var up: [String] = []
        var c1Key = "-"
    }

    /// Enters the strip (the first Down leaves the tab bar; Up once when the first row read is not
    /// Continue Watching, S15's inserted-row rule), then the same Down and Up walk as Classic.
    private func stageWalkFromCW(_ app: XCUIApplication, guestProven: Bool) throws -> StageWalk {
        _ = try requireStage(app)
        var key = stageStep(app, .down)
        for _ in 0..<2 where key != "continue-watching" {
            key = stageStep(app, .up)
            if key == "-" || tabBarFocused(app) { key = stageStep(app, .down) }
        }
        guard key == "continue-watching" else {
            let why = "the Continue Watching seed did not land (strip: '\(strip(app))')"
            if guestProven { XCTFail(why + " on a guest fixture"); throw HarnessAbort(why) }
            throw XCTSkip(why + ": refused on a signed-in account?")
        }
        var walk = StageWalk()
        for _ in 0..<6 {
            let before = stripKey(app)
            let next = stageStep(app, .down)
            if next == before { walk.down.append("stuck:\(next)"); break }
            walk.down.append(Self.normalized(next))
            if !Self.topKeys.contains(next) { walk.c1Key = next; break }
        }
        for _ in 0..<6 {
            let before = stripKey(app)
            let next = stageStep(app, .up)
            if next == before { walk.up.append("stuck:\(next)"); break }
            walk.up.append(Self.normalized(next))
            if next == "continue-watching" { break }
        }
        note("stage_walk", "down=\(walk.down) up=\(walk.up) c1=\(walk.c1Key)\n\(stage(app))\n\(label(app, "debug_strip_fit"))")
        return walk
    }

    private func assertStageCombo(_ combo: Combo) throws {
        defer { clearContinueWatchingSeed() }
        let app = launch(Self.stageBase + combo.arguments)
        if combo.watchlist { try requireWatchlistSeed(app) }
        let walk = try stageWalkFromCW(app, guestProven: combo.watchlist)
        shot("stage_combo\(combo.name)")
        XCTAssertEqual(walk.down, combo.down, "Combo \(combo.name): the Down sequence from Continue Watching")
        XCTAssertEqual(walk.up, combo.up, "Combo \(combo.name): the Up sequence from the first catalog row")
        if combo.watchlist {
            // Walk back down so both rows are measured, then read the fit pages of both.
            _ = stageStep(app, .down)
            for _ in 0..<(combo.below.count) { _ = stageStep(app, .down) }
            let line = label(app, "debug_strip_fit")
            let wl = Self.fit(line, rowKey: "home-watchlist")
            let c1 = Self.fit(line, rowKey: walk.c1Key)
            note("G3_G2_fit", "wl=\(String(describing: wl)) c1=\(String(describing: c1)) line=\(line)")
            if let wl, let c1 {
                XCTAssertEqual(wl.measured, c1.measured, accuracy: 0.5, "the Watchlist's measured height equals the catalog row's: \(line)")
                XCTAssertEqual(wl.page, c1.page, accuracy: 0.5, "the Watchlist's fit page equals the catalog row's: \(line)")
            } else {
                XCTFail("debug_strip_fit lacks an entry for home-watchlist or \(walk.c1Key): \(line)")
            }
            // Stage geometry readout of this launch (G1 vs G4: the Watchlist must not change the stage).
            note("G4_stage", stage(app))
        }
    }

    // MARK: - Tests 1-4 (Classic: Down from CW, Up from the first catalog row)

    func testClassic_ComboA_DownFromCWAndUpFromFirstCatalogRow() throws { try assertClassicCombo(Self.comboA) }
    func testClassic_ComboB_DownFromCWAndUpFromFirstCatalogRow() throws { try assertClassicCombo(Self.comboB) }
    func testClassic_ComboC_DownFromCWAndUpFromFirstCatalogRow() throws { try assertClassicCombo(Self.comboC) }
    func testClassic_ComboD_DownFromCWAndUpFromFirstCatalogRow() throws { try assertClassicCombo(Self.comboD) }

    // MARK: - Tests 5-8 (Stage)

    func testStage_ComboA_DownFromCWAndUpFromFirstCatalogRow() throws { try assertStageCombo(Self.comboA) }
    func testStage_ComboB_DownFromCWAndUpFromFirstCatalogRow() throws { try assertStageCombo(Self.comboB) }
    func testStage_ComboC_DownFromCWAndUpFromFirstCatalogRow() throws { try assertStageCombo(Self.comboC) }
    func testStage_ComboD_DownFromCWAndUpFromFirstCatalogRow() throws { try assertStageCombo(Self.comboD) }

    // MARK: - Tests 9-12 (Classic pinned: the last row with no catalog rows)

    /// Down until `own=` stops changing (2 still reads).
    private func assertClassicLastRow(_ combo: Combo) throws {
        defer { clearContinueWatchingSeed() }
        let app = launch(Self.classicBase + combo.arguments + ["-debug.homeNoCatalogRows", "YES", "-debug.pinnedRowSettleProbe", "YES"])
        if combo.watchlist { try requireWatchlistSeed(app) }
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty }) else {
            throw HarnessAbort("debug_homeReturn never appeared")
        }
        var last = "-"
        var still = 0
        var seen: [String] = []
        for _ in 0..<10 {
            remote.press(.down)
            pause(1.8)
            let key = own(app)
            if key == last { still += 1 } else { still = 0 }
            if key != "-", seen.last != key { seen.append(key) }
            last = key
            if still >= 2, key != "-" { break }
        }
        let finalKey = own(app)
        let line = pinnedLine(app, row: finalKey) ?? label(app, "debug_pinned")
        note("classic_last_combo\(combo.name)", "own sequence=\(seen) final=\(finalKey)\n\(line)")
        shot("classic_last_combo\(combo.name)")
        XCTAssertEqual(finalKey, combo.last, "Combo \(combo.name): the last row with no catalog rows (sequence \(seen))")
        if combo.name == "B" {
            XCTAssertEqual(Self.token(line, "row"), "home-watchlist", "debug_pinned must describe the Watchlist: '\(line)'")
            XCTAssertEqual(Self.token(line, "last"), "1", "the Watchlist is the last row: '\(line)'")
            // lastRowShaped equals fits: `PinnedRowGeometry.lastRowLinkFrameFloor` is 0 when the plan does not
            // fit, and no row is shaped in that regime (a last catalog row and Upcoming report 0 too).
            let fits = Self.token(line, "fits") ?? "?"
            XCTAssertEqual(Self.token(line, "lastRowShaped"), fits == "1" ? "1" : "0",
                           "lastRowShaped follows fits=\(fits) for the Watchlist as the last row: '\(line)'")
            // G5's catalog rowH on the base tip (554, plan "Geometry, base tip"): no catalog row exists in this launch.
            XCTAssertEqual(Self.int(line, "rowH"), 554, "the Watchlist's rowH equals the catalog row's (G5 = 554): '\(line)'")
        }
    }

    func testClassic_ComboA_PinnedLastRowWithNoCatalogRows() throws { try assertClassicLastRow(Self.comboA) }
    func testClassic_ComboB_PinnedLastRowWithNoCatalogRows() throws { try assertClassicLastRow(Self.comboB) }
    func testClassic_ComboC_PinnedLastRowWithNoCatalogRows() throws { try assertClassicLastRow(Self.comboC) }
    func testClassic_ComboD_PinnedLastRowWithNoCatalogRows() throws { try assertClassicLastRow(Self.comboD) }

    // MARK: - Tests 13-16 (Stage: the last row with no catalog rows)

    /// Down until `debug_strip row=` stops changing.
    private func assertStageLastRow(_ combo: Combo) throws {
        defer { clearContinueWatchingSeed() }
        let app = launch(Self.stageBase + combo.arguments + ["-debug.homeNoCatalogRows", "YES"])
        if combo.watchlist { try requireWatchlistSeed(app) }
        _ = try requireStage(app)
        var lastRow = -2
        var still = 0
        for _ in 0..<8 {
            remote.press(.down)
            pause(3.0)
            let row = Self.int(strip(app), "row") ?? -1
            if row == lastRow { still += 1 } else { still = 0 }
            lastRow = row
            if still >= 1, row >= 0 { break }
        }
        let line = strip(app)
        note("stage_last_combo\(combo.name)", line)
        shot("stage_last_combo\(combo.name)")
        XCTAssertEqual(stripKey(app), combo.last, "Combo \(combo.name): the last row with no catalog rows: \(line)")
        XCTAssertEqual(Self.int(line, "row"), combo.topRows.count - 1, "row= is the number of top rows minus 1: \(line)")
        remote.press(.down)
        pause(2.0)
        XCTAssertEqual(strip(app).isEmpty ? "" : stripKey(app), combo.last, "Down at the end changes nothing: \(strip(app))")
        XCTAssertEqual(Self.int(strip(app), "row"), combo.topRows.count - 1, "Down at the end changes nothing: \(strip(app))")
    }

    func testStage_ComboA_LastRowWithNoCatalogRows() throws { try assertStageLastRow(Self.comboA) }
    func testStage_ComboB_LastRowWithNoCatalogRows() throws { try assertStageLastRow(Self.comboB) }
    func testStage_ComboC_LastRowWithNoCatalogRows() throws { try assertStageLastRow(Self.comboC) }
    func testStage_ComboD_LastRowWithNoCatalogRows() throws { try assertStageLastRow(Self.comboD) }

    // MARK: - Test 17 (Classic, no Continue Watching: the Watchlist is the top row)

    /// A card of a catalog row holds focus (not Continue Watching, the Watchlist or Upcoming, whose
    /// cards play or open another page), read from the layout's own readout.
    private func classicCatalogCardFocused(_ app: XCUIApplication) -> Bool {
        let line = label(app, "debug_homeReturn")
        guard let own = Self.token(line, "own"), own != "-", !Self.topKeys.contains(own),
              let foc = Self.token(line, "foc"), let slash = foc.firstIndex(of: "/"),
              String(foc[..<slash]) == own else { return false }
        guard let root = try? app.snapshot() else { return false }
        var frame: CGRect?
        func walk(_ node: XCUIElementSnapshot) {
            if node.hasFocus { frame = node.frame }
            node.children.forEach(walk)
        }
        walk(root)
        guard let frame else { return false }
        return frame.width >= 100 && frame.height >= 100
    }

    func testClassic_NoCWWatchlistIsTheTopRow() throws {
        try requireNoStoredContinueWatching()
        let app = launch(Self.classicBase + ["-debug.homeWatchlistSeedJsonB64", Self.wlSeed, "-home_upcoming_row_enabled", "NO"])
        try requireWatchlistSeed(app)
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty }) else {
            throw HarnessAbort("debug_homeReturn never appeared")
        }
        // From the hero CTA (own=-), Down: the Watchlist.
        var first = "-"
        for _ in 0..<4 {
            first = classicStep(app, .down)
            if first != "-" { break }
        }
        XCTAssertEqual(first, "home-watchlist", "the first row reached from the hero is the Watchlist: \(label(app, "debug_homeReturn"))")
        let c1 = classicStep(app, .down)
        XCTAssertFalse(Self.topKeys.contains(c1) || c1 == "-", "Down from the Watchlist reaches the first catalog row: \(label(app, "debug_homeReturn"))")
        XCTAssertEqual(classicStep(app, .up), "home-watchlist", "Up from the first catalog row reaches the Watchlist")
        XCTAssertEqual(classicStep(app, .down), c1, "Down again reaches the first catalog row")
        guard classicCatalogCardFocused(app) else {
            shot("unverified_c1_card")
            throw HarnessAbort("focus is not on a catalog card (\(label(app, "debug_homeReturn"))) — not pressing Select")
        }
        let remBefore = Self.int(label(app, "debug_homeReturn"), "remN") ?? 0
        remote.press(.select)
        pause(2.0)
        remote.press(.menu)
        // `rem=`/`remN=` keep the last remount (`ret=` is overwritten by the next restore rung ~0.1 s later).
        var line = ""
        let remounted = poll(4.0, step: 0.25) {
            line = label(app, "debug_homeReturn")
            return (Self.int(line, "remN") ?? 0) > remBefore
        }
        note("remount", line)
        XCTAssertTrue(remounted, "a top-row remount ran after the pop: \(line)")
        XCTAssertTrue((Self.token(line, "rem") ?? "").split(separator: ",").contains("home-watchlist"),
                      "after the pop the Watchlist is remounted (top-row token; c1 is the origin): \(line)")
        XCTAssertEqual(classicStep(app, .up), "home-watchlist", "Up from the first catalog row after the pop reaches the Watchlist")
    }

    // MARK: - Test 18 (Classic, hero off: the Watchlist seeds the panel)

    func testClassic_NoCWWatchlistSeedsTheHeroPanel() throws {
        try requireNoStoredContinueWatching()
        let args = Self.classicBase + ["-debug.homeWatchlistSeedJsonB64", Self.wlSeed, "-home_upcoming_row_enabled", "NO",
                                       "-debug.homeHeroOff", "YES", "-debug.homeHeroProbe", "YES"]
        let app = launch(args + ["-debug.homeNoCatalogRows", "YES"])
        try requireWatchlistSeed(app)
        var pitem = "-"
        _ = poll(10, step: 0.3) {
            pitem = Self.token(label(app, "debug_hero"), "pitem") ?? "-"
            return pitem != "-"
        }
        note("pitem_no_catalog", label(app, "debug_hero"))
        XCTAssertEqual(pitem, Self.wlFirst, "no catalog rows and no Continue Watching: the panel's seed is the Watchlist's first item: \(label(app, "debug_hero"))")
        app.terminate()

        // With catalog rows present the panel's seed is the first catalog row's first item (decision Q).
        let second = launch(args)
        try requireWatchlistSeed(second)
        var catalogItem = "-"
        _ = poll(15, step: 0.3) {
            catalogItem = Self.token(label(second, "debug_hero"), "pitem") ?? "-"
            return catalogItem != "-"
        }
        note("pitem_with_catalog", label(second, "debug_hero"))
        XCTAssertNotEqual(catalogItem, "-", "the panel presents an item: \(label(second, "debug_hero"))")
        XCTAssertNotEqual(catalogItem, Self.wlFirst, "with catalog rows the panel's seed is the first catalog row's item, not the Watchlist's: \(label(second, "debug_hero"))")
    }

    // MARK: - Test 19 (Stage, no Continue Watching: row zero and the stage seed)

    /// After focus settles on a card of `rowKey`, two quick Rights, then the stage's shown item
    /// (`debug_stage disp=<type:id>`) must equal the focused card (`debug_strip foc=<rowKey>/<itemId>`)
    /// within 10 s. Returns the result text.
    private func stageFollowsFocus(_ app: XCUIApplication, rowKey: String) -> (ok: Bool, detail: String) {
        guard stripKey(app) == rowKey else { return (false, "precondition: strip is on \(stripKey(app)), not \(rowKey)") }
        remote.press(.right)
        pause(0.15)
        remote.press(.right)
        var detail = ""
        let ok = poll(10, step: 0.3) {
            let foc = Self.token(strip(app), "foc") ?? "-"
            let id = foc.firstIndex(of: "/").map { String(foc[foc.index(after: $0)...]) } ?? "-"
            let disp = Self.token(stage(app), "disp") ?? "-"
            let dispId = disp.firstIndex(of: ":").map { String(disp[disp.index(after: $0)...]) } ?? "-"
            detail = "foc=\(foc) disp=\(disp)"
            return id != "-" && id == dispId
        }
        return (ok, detail)
    }

    func testStage_NoCWWatchlistIsRowZeroAndSeedsTheStage() throws {
        try requireNoStoredContinueWatching()
        let app = launch(Self.stageBase + ["-debug.homeWatchlistSeedJsonB64", Self.wlSeed, "-home_upcoming_row_enabled", "NO"])
        try requireWatchlistSeed(app)
        let geometry = try requireStage(app)
        note("G1_G4_stage", geometry)
        XCTAssertTrue(poll(10, step: 0.3) { Self.token(stage(app), "disp") == Self.wlFirst },
                      "before focus the stage seed is the Watchlist's first item: \(stage(app))")
        remote.press(.down)
        pause(3.0)
        XCTAssertEqual(stripKey(app), "home-watchlist", "entering the strip lands on the Watchlist: \(strip(app))")
        XCTAssertEqual(Self.int(strip(app), "row"), 0, "the Watchlist is row 0: \(strip(app))")
        let wlFocus = stageFollowsFocus(app, rowKey: "home-watchlist")
        note("stage_follows_focus_watchlist", "\(wlFocus.ok) \(wlFocus.detail)")
        XCTAssertTrue(wlFocus.ok, "the stage shows the focused Watchlist card within 10 s of settling: \(wlFocus.detail)")
        let below = stageStep(app, .down)
        XCTAssertFalse(Self.topKeys.contains(below) || below == "-", "Down reaches the first catalog row: \(strip(app))")
        XCTAssertEqual(Self.int(strip(app), "row"), 1, "the first catalog row is row 1: \(strip(app))")
        let catalogFocus = stageFollowsFocus(app, rowKey: below)
        note("stage_follows_focus_catalog", "\(catalogFocus.ok) \(catalogFocus.detail)")
        XCTAssertTrue(catalogFocus.ok, "the stage shows the focused catalog card within 10 s of settling: \(catalogFocus.detail)")
        XCTAssertEqual(stageStep(app, .up), "home-watchlist", "Up returns to the Watchlist: \(strip(app))")
        remote.press(.up)
        XCTAssertTrue(poll(2.0) { tabBarFocused(app) }, "Up from row 0 reaches the tab bar")
        XCTAssertEqual(Self.token(strip(app), "atTop"), "1", "the strip reads atTop=1: \(strip(app))")
    }

    // MARK: - Tests 20-21 (toggle off)

    func testToggleOffRemovesTheRow_Classic() throws {
        let app = launch(Self.classicBase + ["-debug.homeWatchlistSeedJsonB64", Self.wlSeed, "-home_watchlist_row_enabled", "NO",
                                             "-home_upcoming_row_enabled", "NO"])
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty }) else {
            throw HarnessAbort("debug_homeReturn never appeared")
        }
        var owned: [String] = []
        for _ in 0..<5 {
            let key = classicStep(app, .down)
            if key != "-", owned.last != key { owned.append(key) }
        }
        let wl = label(app, "debug_homeWatchlist")
        note("toggle_off_classic", "own sequence=\(owned) \(wl)")
        XCTAssertEqual(Self.token(wl, "on"), "0", "the toggle reads off: \(wl)")
        XCTAssertEqual(Self.token(wl, "n"), "0", "no Watchlist section while off: \(wl)")
        XCTAssertFalse(owned.contains("home-watchlist"), "no row owns focus as the Watchlist: \(owned)")
        // §6 leg 20: the first catalog row follows Continue Watching (stored progress on the fixture) or the hero directly.
        let rows = owned.first == "continue-watching" ? Array(owned.dropFirst()) : owned
        XCTAssertNotNil(rows.first, "a catalog row took focus: \(owned) \(label(app, "debug_homeReturn"))")
        if let first = rows.first {
            XCTAssertFalse(Self.topKeys.contains(first), "the first catalog row follows Continue Watching or the hero directly: \(owned)")
        }
    }

    func testToggleOffRemovesTheRow_Stage() throws {
        let app = launch(Self.stageBase + ["-debug.homeWatchlistSeedJsonB64", Self.wlSeed, "-home_watchlist_row_enabled", "NO",
                                           "-home_upcoming_row_enabled", "NO"])
        _ = try requireStage(app)
        var keys: [String] = []
        for _ in 0..<5 {
            let key = stageStep(app, .down)
            if key != "-", keys.last != key { keys.append(key) }
        }
        let wl = label(app, "debug_homeWatchlist")
        let fitLine = label(app, "debug_strip_fit")
        note("toggle_off_stage", "keys=\(keys) \(wl)\n\(fitLine)")
        XCTAssertEqual(Self.token(wl, "on"), "0", "the toggle reads off: \(wl)")
        XCTAssertEqual(Self.token(wl, "n"), "0", "no Watchlist section while off: \(wl)")
        XCTAssertFalse(keys.contains("home-watchlist"), "no strip row is the Watchlist: \(keys)")
        XCTAssertNil(Self.fit(fitLine, rowKey: "home-watchlist"), "no fit entry for the Watchlist: \(fitLine)")
        XCTAssertFalse(fitLine.contains("home-watchlist"), "no fit entry for the Watchlist: \(fitLine)")
    }

    // MARK: - Test 22 (Classic: a late Watchlist keeps focus on Upcoming)

    /// The Watchlist arrives 30 s after launch (`-debug.homeWatchlistSeedDelayMs`) while focus rests on
    /// Upcoming; the insert is held (§16) so focus stays on it, and lands once focus goes to the hero.
    /// Stage is out of scope (its pager re-keys by index, a different mechanism).
    func testClassic_LateWatchlistKeepsFocusOnUpcoming() throws {
        let app = launch(Self.classicBase + ["-home_upcoming_row_enabled", "YES", "-debug.homeUpcomingSeedJsonB64", Self.upSeed,
                                             "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                             "-debug.homeWatchlistSeedDelayMs", "30000"], settle: 4)
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty }) else {
            throw HarnessAbort("debug_homeReturn never appeared")
        }
        var reached = false
        for _ in 0..<5 {
            if classicStep(app, .down) == "upcoming" { reached = true; break }
        }
        guard reached else {
            XCTFail("focus never reached Upcoming (own=\(own(app))): '\(label(app, "debug_homeReturn"))'")
            throw HarnessAbort("focus never reached Upcoming")
        }
        let early = label(app, "debug_homeWatchlist")
        XCTAssertEqual(Self.int(early, "n"), 0, "the delay elapsed before focus reached Upcoming: '\(early)'")
        // The delayed seed lands while focus rests on Upcoming: it is held, not inserted.
        guard poll(45, step: 0.5, { Self.token(label(app, "debug_homeWatchlist"), "held") == "1" }) else {
            XCTFail("the late Watchlist was never held: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("no held Watchlist")
        }
        for i in 0..<3 {
            XCTAssertEqual(own(app), "upcoming", "read \(i + 1): focus stays on Upcoming while the Watchlist is held: '\(label(app, "debug_homeReturn"))'")
            XCTAssertEqual(Self.int(label(app, "debug_homeWatchlist"), "n"), 0, "read \(i + 1): the held row is not inserted")
            pause(1.0)
        }
        // Up from the top row reaches the hero; the hold lets go within about a second.
        remote.press(.up)
        XCTAssertTrue(poll(5, step: 0.25) { (Self.int(label(app, "debug_homeWatchlist"), "n") ?? 0) > 0 },
                      "the held Watchlist lands once focus leaves the rows below it: '\(label(app, "debug_homeWatchlist"))'")
        XCTAssertEqual(Self.token(label(app, "debug_homeWatchlist"), "held"), "0", "the hold is released")
        try requireWatchlistSeed(app)
        // Up from upcoming lands on the hero, or on Continue Watching when the fixture has one (the sim may still
        // put it on the hero: the combo legs' expected Up-skip). The Watchlist is the next row below that,
        // through Continue Watching when Down starts from the hero.
        let afterUp = own(app)
        XCTAssertTrue(afterUp == "-" || afterUp == "continue-watching",
                      "Up from upcoming reaches the hero or Continue Watching: '\(label(app, "debug_homeReturn"))'")
        var path = [classicStep(app, .down)]
        if afterUp == "-", path[0] == "continue-watching" { path.append(classicStep(app, .down)) }
        XCTAssertEqual(path.last, "home-watchlist",
                       "Down from \(afterUp == "-" ? "the hero" : afterUp) reaches the Watchlist: path \(path) '\(label(app, "debug_homeReturn"))'")
        note("late_watchlist", "\(label(app, "debug_homeWatchlist")) | \(label(app, "debug_homeReturn"))")
        shot("classic_late_watchlist")
    }

    // MARK: - Test 23 (Classic: a late Watchlist lands at once under focused Continue Watching)

    /// Continue Watching sits above the Watchlist's slot, so a late Watchlist is inserted without a hold
    /// and focus stays on Continue Watching.
    func testClassic_LateWatchlistLandsAtOnceUnderFocusedContinueWatching() throws {
        let app = launch(Self.classicBase + ["-debug.continueWatchingSeedJsonB64", Self.cwSeed,
                                             "-home_upcoming_row_enabled", "YES", "-debug.homeUpcomingSeedJsonB64", Self.upSeed,
                                             "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                             "-debug.homeWatchlistSeedDelayMs", "30000"], settle: 4)
        defer { app.terminate(); clearContinueWatchingSeed() }
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty }) else {
            throw HarnessAbort("debug_homeReturn never appeared")
        }
        var reached = false
        for _ in 0..<4 {
            if classicStep(app, .down) == "continue-watching" { reached = true; break }
        }
        guard reached else {
            throw XCTSkip("the Continue Watching seed did not land: refused on a signed-in account?")
        }
        XCTAssertEqual(Self.int(label(app, "debug_homeWatchlist"), "n"), 0, "the delay elapsed before focus reached Continue Watching: '\(label(app, "debug_homeWatchlist"))'")
        guard poll(45, step: 0.5, { (Self.int(label(app, "debug_homeWatchlist"), "n") ?? 0) > 0 }) else {
            XCTFail("the late Watchlist never landed under Continue Watching: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("no late Watchlist row")
        }
        XCTAssertEqual(Self.token(label(app, "debug_homeWatchlist"), "held"), "0", "no hold above the slot: '\(label(app, "debug_homeWatchlist"))'")
        for i in 0..<3 {
            XCTAssertEqual(own(app), "continue-watching", "read \(i + 1): focus stays on Continue Watching: '\(label(app, "debug_homeReturn"))'")
            pause(1.0)
        }
        XCTAssertEqual(classicStep(app, .down), "home-watchlist", "Down from Continue Watching reaches the Watchlist")
        XCTAssertEqual(classicStep(app, .down), "upcoming", "Down from the Watchlist reaches Upcoming")
        note("late_watchlist_cw", "\(label(app, "debug_homeWatchlist")) | \(label(app, "debug_homeReturn"))")
        shot("classic_late_watchlist_cw")
    }

    // MARK: - Test 24 (Classic: a late Watchlist is held while focus is on the first catalog row)

    func testClassic_LateWatchlistHeldWhileOnFirstCatalogRow() throws {
        let app = launch(Self.classicBase + ["-home_upcoming_row_enabled", "NO",
                                             "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                             "-debug.homeWatchlistSeedDelayMs", "30000"], settle: 4)
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty }) else {
            throw HarnessAbort("debug_homeReturn never appeared")
        }
        var c1 = "-"
        for _ in 0..<4 {
            c1 = classicStep(app, .down)
            if c1 != "-" && !Self.topKeys.contains(c1) { break }
        }
        guard c1 != "-", !Self.topKeys.contains(c1) else {
            XCTFail("focus never reached a catalog row (own=\(own(app))): '\(label(app, "debug_homeReturn"))'")
            throw HarnessAbort("focus never reached a catalog row")
        }
        XCTAssertEqual(Self.int(label(app, "debug_homeWatchlist"), "n"), 0, "the delay elapsed before focus reached the catalog row: '\(label(app, "debug_homeWatchlist"))'")
        guard poll(45, step: 0.5, { Self.token(label(app, "debug_homeWatchlist"), "held") == "1" }) else {
            XCTFail("the late Watchlist was never held: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("no held Watchlist")
        }
        for i in 0..<3 {
            XCTAssertEqual(own(app), c1, "read \(i + 1): focus stays on \(c1) while the Watchlist is held: '\(label(app, "debug_homeReturn"))'")
            XCTAssertEqual(Self.int(label(app, "debug_homeWatchlist"), "n"), 0, "read \(i + 1): the held row is not inserted")
            pause(1.0)
        }
        remote.press(.up)
        XCTAssertTrue(poll(5, step: 0.25) {
            let line = label(app, "debug_homeWatchlist")
            return (Self.int(line, "n") ?? 0) > 0 && Self.token(line, "held") == "0"
        }, "the held Watchlist lands once focus leaves the catalog row: '\(label(app, "debug_homeWatchlist"))'")
        try requireWatchlistSeed(app)
        // Up from c1 lands on the hero, or on Continue Watching when the fixture has one (the sim may still
        // put it on the hero: the combo legs' expected Up-skip). The Watchlist is the next row below that,
        // through Continue Watching when Down starts from the hero.
        let afterUp = own(app)
        XCTAssertTrue(afterUp == "-" || afterUp == "continue-watching",
                      "Up from \(c1) reaches the hero or Continue Watching: '\(label(app, "debug_homeReturn"))'")
        var path = [classicStep(app, .down)]
        if afterUp == "-", path[0] == "continue-watching" { path.append(classicStep(app, .down)) }
        XCTAssertEqual(path.last, "home-watchlist",
                       "Down from \(afterUp == "-" ? "the hero" : afterUp) reaches the Watchlist: path \(path) '\(label(app, "debug_homeReturn"))'")
        note("late_watchlist_c1", "\(label(app, "debug_homeWatchlist")) | \(label(app, "debug_homeReturn"))")
        shot("classic_late_watchlist_c1")
    }

    // MARK: - Stage late-row legs (D10: the strip re-anchors after a row-list change)

    private struct StageSlot {
        let stageH: Double
        let page: Double
    }

    /// `debug_stage stageH=` and `P=` once Stage Home is up.
    private func stageSlot(_ app: XCUIApplication) throws -> StageSlot {
        let line = try requireStage(app)
        guard let stageH = Self.token(line, "stageH").flatMap(Double.init),
              let page = Self.token(line, "P").flatMap(Double.init), page > 0 else {
            throw HarnessAbort("debug_stage lacks stageH= or P=: '\(line)'")
        }
        return StageSlot(stageH: stageH, page: page)
    }

    /// `debug_strip foc=<rowKey>/<itemId>` split at the first "/" ("-" parts when absent).
    private func focParts(_ app: XCUIApplication) -> (row: String, item: String) {
        let foc = Self.token(strip(app), "foc") ?? "-"
        guard let slash = foc.firstIndex(of: "/") else { return (foc, "-") }
        return (String(foc[..<slash]), String(foc[foc.index(after: slash)...]))
    }

    /// `debug_stage disp=<type:id>` without the type (the comparison `stageFollowsFocus` makes).
    private func dispId(_ app: XCUIApplication) -> String {
        let disp = Self.token(stage(app), "disp") ?? "-"
        return disp.firstIndex(of: ":").map { String(disp[disp.index(after: $0)...]) } ?? "-"
    }

    /// The outermost element reporting focus and its frame, from ONE snapshot (`StageStripUITests.focused`).
    private func focusedFrame(_ app: XCUIApplication) -> (label: String, frame: CGRect)? {
        guard let root = try? app.snapshot() else { return nil }
        var found: (label: String, frame: CGRect)?
        func walk(_ node: XCUIElementSnapshot) {
            guard found == nil else { return }
            if node.hasFocus {
                found = (node.label, node.frame)
                return
            }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }

    private func watchlistCount(_ app: XCUIApplication) -> Int {
        Self.int(label(app, "debug_homeWatchlist"), "n") ?? 0
    }

    /// Skips when the Watchlist seed is refused (not a guest, or a tracker is the progress source).
    private func requireSeedNotRefused(_ app: XCUIApplication) throws {
        var line = ""
        _ = poll(15, step: 0.5) {
            line = label(app, "debug_homeWatchlist")
            return !line.isEmpty
        }
        guard !line.isEmpty else {
            XCTFail("debug_homeWatchlist is missing: not a DEBUG build, or the readout is unmounted")
            throw HarnessAbort("no debug_homeWatchlist")
        }
        if Self.token(line, "seed") == "refused" {
            throw XCTSkip("fixture is not a guest (the Watchlist seed was refused): '\(line)'")
        }
    }

    /// From launch (Tabs mode: focus on the tab bar), Down until a catalog row owns the strip (≤ 5 presses).
    private func stageEnterFirstCatalogRow(_ app: XCUIApplication) throws -> String {
        var key = "-"
        for _ in 0..<5 {
            key = stageStep(app, .down)
            if key != "-", !Self.topKeys.contains(key) { return key }
        }
        XCTFail("focus never reached a catalog row within five Downs: '\(strip(app))'")
        throw HarnessAbort("no catalog row")
    }

    /// A2c: the focused card sits in the strip's current-row slot, not in the peek band.
    private func focusedCardInSlot(_ app: XCUIApplication, _ slot: StageSlot) -> (ok: Bool, detail: String) {
        guard let focused = focusedFrame(app) else {
            return (false, "no element reports focus (hasFocus unsupported on this runtime?)")
        }
        let minY = Double(focused.frame.minY)
        let top = slot.stageH - 60
        let bottom = slot.stageH + 0.5 * slot.page
        let detail = "focused '\(focused.label)' minY=\(Int(minY)) slot=[\(Int(top)), \(Int(bottom))) stageH=\(Int(slot.stageH)) P=\(Int(slot.page))"
        return (minY >= top && minY < bottom, detail)
    }

    /// The d10 oracle set, read after a rest: A1 focus unchanged, A2 the strip shows the focused row,
    /// A3 the stage shows the focused item, A4 one Right moves exactly one item, A5 the slot again.
    private func assertStripShowsFocusedRow(_ app: XCUIApplication, _ slot: StageSlot,
                                            row expectRow: String, item expectItem: String?, tag: String) {
        shot(tag)
        let foc = focParts(app)
        let stripLine = strip(app)
        let inSlot = focusedCardInSlot(app, slot)
        note(tag, "strip=\(stripLine)\nstage=\(stage(app))\nwatchlist=\(label(app, "debug_homeWatchlist"))\n\(inSlot.detail)")
        XCTAssertEqual(foc.row, expectRow, "\(tag) A1: the focused row changed: \(stripLine)")
        if let expectItem {
            XCTAssertEqual(foc.item, expectItem, "\(tag) A1: the focused item changed: \(stripLine)")
        }
        XCTAssertEqual(stripKey(app), foc.row, "\(tag) A2a: debug_strip key= is not the focused row: \(stripLine)")
        XCTAssertEqual(Self.token(stripLine, "page"), foc.row,
                       "\(tag) A2b: debug_strip page= (the row the strip last paged or re-pinned to; '-' until either happens) is not the focused row, so the re-pin after the insert did not run: \(stripLine)")
        XCTAssertTrue(inSlot.ok,
                      "\(tag) A2c: the strip does not show the focused row in its current-row slot (d10: the row above is shown, the focused row peeks): \(inSlot.detail)")
        XCTAssertEqual(dispId(app), foc.item,
                       "\(tag) A3: the stage does not show the focused item: disp=\(Self.token(stage(app), "disp") ?? "-") foc=\(foc.row)/\(foc.item)")
        let start = foc
        remote.press(.right)
        pause(2.0)
        let moved = focParts(app)
        XCTAssertEqual(moved.row, start.row, "\(tag) A4a: Right left the row: \(strip(app))")
        XCTAssertNotEqual(moved.item, start.item, "\(tag) A4b: Right did not move focus: \(strip(app))")
        remote.press(.left)
        pause(2.0)
        XCTAssertEqual(focParts(app).item, start.item,
                       "\(tag) A4c: one Left after one Right does not return to \(start.item), so Right did not move exactly one item: \(strip(app))")
        let after = focusedCardInSlot(app, slot)
        XCTAssertTrue(after.ok, "\(tag) A5: after Right/Left the focused row is not in the slot: \(after.detail)")
    }

    /// d10 leg S-late-rest: focus rests on the first catalog row (below the Watchlist slot) when the
    /// delayed Watchlist lands; Stage does not hold it (D10), and the strip must keep showing the row.
    func testStage_LateWatchlistRestOnFirstCatalogRow() throws {
        let app = launch(Self.stageBase + ["-home_upcoming_row_enabled", "NO",
                                           "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                           "-debug.homeWatchlistSeedDelayMs", "30000"], settle: 4)
        defer { app.terminate() }
        let slot = try stageSlot(app)
        try requireSeedNotRefused(app)
        let c1 = try stageEnterFirstCatalogRow(app)
        guard watchlistCount(app) == 0 else {
            XCTFail("the 30 s delay elapsed before focus reached \(c1): '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("Watchlist landed too early")
        }
        pause(2.0)
        let before = focParts(app)
        let rowBefore = Self.int(strip(app), "row") ?? -1
        XCTAssertEqual(before.row, c1, "focus rests on \(c1) before the insert: \(strip(app))")
        let baseline = focusedCardInSlot(app, slot)
        guard baseline.ok else {
            XCTFail("A2c baseline fails BEFORE the insert, so the oracle is not usable here: \(baseline.detail)")
            throw HarnessAbort("A2c baseline")
        }
        guard poll(45, step: 0.5, { watchlistCount(app) > 0 }) else {
            XCTFail("the late Watchlist never landed: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("no late Watchlist row")
        }
        XCTAssertEqual(Self.token(label(app, "debug_homeWatchlist"), "held"), "0",
                       "Stage never holds the row (D10): '\(label(app, "debug_homeWatchlist"))'")
        try requireWatchlistSeed(app)
        pause(5.0)
        XCTAssertEqual(Self.int(strip(app), "row"), rowBefore + 1,
                       "A1b: debug_strip row= did not move down by one with the insert: before=\(rowBefore) now='\(strip(app))'")
        assertStripShowsFocusedRow(app, slot, row: c1, item: before.item, tag: "S_late_rest")
    }

    /// d10 leg S-late-inflight, kept as a STRESS leg (review r1): the same launch, with Down/Up pressed
    /// back to back (each inside or just after the previous page's glide, stretched to 1.0 s) until
    /// the Watchlist lands, asserted against whatever catalog row focus rests on. Automation timing
    /// decides where in a glide the insert lands and whether a press follows it, so it proves no
    /// path ran; the deterministic legs below do. Not a gate: run with `-test-iterations 10` and
    /// record the pass rate (8/10 at `2119479cb`).
    func testStage_LateWatchlistPressTrain() throws {
        let app = launch(Self.stageBase + ["-home_upcoming_row_enabled", "NO",
                                           "-debug.stripPageSeconds", "1.0",
                                           "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                           "-debug.homeWatchlistSeedDelayMs", "30000"], settle: 4)
        // ≈ when Home appeared and HomeView.onAppear ran startWatchlist() (launch() paused `settle` after the profile tap).
        let t0 = Date().addingTimeInterval(-4)
        defer { app.terminate() }
        let slot = try stageSlot(app)
        try requireSeedNotRefused(app)
        let c1 = try stageEnterFirstCatalogRow(app)
        let c2 = stageStep(app, .down)
        guard c2 != c1, c2 != "-", !Self.topKeys.contains(c2) else {
            throw HarnessAbort("the leg needs two catalog rows below the slot; Down from \(c1) gave \(c2): '\(strip(app))'")
        }
        XCTAssertEqual(stageStep(app, .up), c1, "Up from \(c2) returns to \(c1): \(strip(app))")
        guard watchlistCount(app) == 0 else {
            XCTFail("the 30 s delay elapsed before the press train: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("Watchlist landed too early")
        }
        // Idle until ~4 s before the estimated landing (t0 + 30 s).
        while Date() < t0.addingTimeInterval(26), watchlistCount(app) == 0 { pause(0.25) }
        guard watchlistCount(app) == 0 else {
            XCTFail("the Watchlist landed before the press train started: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("Watchlist landed before the train")
        }
        var presses: [String] = []
        var down = true
        let deadline = t0.addingTimeInterval(45)
        while watchlistCount(app) == 0, Date() < deadline {
            remote.press(down ? .down : .up)
            presses.append(down ? "D" : "U")
            down.toggle()
            pause(0.3)
        }
        guard watchlistCount(app) > 0 else {
            XCTFail("the late Watchlist never landed during the press train (\(presses.count) presses)")
            throw HarnessAbort("no late Watchlist row")
        }
        note("S_late_inflight_presses", "\(presses.joined(separator: " ")) | \(strip(app))")
        XCTAssertEqual(Self.token(label(app, "debug_homeWatchlist"), "held"), "0",
                       "Stage never holds the row (D10): '\(label(app, "debug_homeWatchlist"))'")
        pause(5.0)
        let rest = focParts(app)
        guard rest.row != "-", !Self.topKeys.contains(rest.row) else {
            XCTFail("after the train focus is not on a catalog row: '\(strip(app))'")
            throw HarnessAbort("focus off the catalog rows")
        }
        assertStripShowsFocusedRow(app, slot, row: rest.row, item: rest.item, tag: "S_late_inflight")
    }

    /// D10 r1: the delayed seed armed for the next strip page (`debug_homeWatchlist armed=1`), polled
    /// while focus rests (no press, so no page can take it early).
    private func waitForArmedSeed(_ app: XCUIApplication) throws {
        guard watchlistCount(app) == 0 else {
            XCTFail("the held seed landed before the glide under test (a page ran after it armed): '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("Watchlist landed early")
        }
        guard poll(40, step: 0.5, { Self.token(label(app, "debug_homeWatchlist"), "armed") == "1" }) else {
            XCTFail("the delayed seed never armed for a strip page: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("seed not armed")
        }
    }

    /// D10 r1 (item 5, finding 4): the in-flight case, deterministic. The seed lands 500 ms into one
    /// Down's 1.0 s glide (`-debug.homeWatchlistSeedOnPageMs 500`): mid visual glide, long after the
    /// motion signal's page has ended. Fails if the re-pin did not see the strip moving and leave the
    /// running glide alone (`deferred=`), if no re-pin ran at rest (`settles=`), or on the oracle set.
    func testStage_LateWatchlistPressInFlight() throws {
        let app = launch(Self.stageBase + ["-home_upcoming_row_enabled", "NO",
                                           "-debug.stripPageSeconds", "1.0",
                                           "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                           "-debug.homeWatchlistSeedDelayMs", "25000",
                                           "-debug.homeWatchlistSeedOnPageMs", "500"], settle: 4)
        defer { app.terminate() }
        let slot = try stageSlot(app)
        try requireSeedNotRefused(app)
        let c1 = try stageEnterFirstCatalogRow(app)
        try waitForArmedSeed(app)
        let before = focParts(app)
        let rowBefore = Self.int(strip(app), "row") ?? -1
        let deferredBefore = Self.int(strip(app), "deferred") ?? -1
        let settlesBefore = Self.int(strip(app), "settles") ?? -1
        XCTAssertEqual(before.row, c1, "focus rests on \(c1) before the glide: \(strip(app))")
        XCTAssertEqual(deferredBefore, 0, "no deferred re-pin before the insert: \(strip(app))")
        remote.press(.down)
        guard poll(5, step: 0.1, { watchlistCount(app) > 0 }) else {
            XCTFail("the Down's glide did not land the armed seed (no page started?): '\(label(app, "debug_homeWatchlist"))' strip='\(strip(app))'")
            throw HarnessAbort("no insert on the glide")
        }
        XCTAssertEqual(Self.token(label(app, "debug_homeWatchlist"), "held"), "0",
                       "Stage never holds the row (D10): '\(label(app, "debug_homeWatchlist"))'")
        pause(5.0)
        let line = strip(app)
        XCTAssertEqual(Self.int(line, "deferred"), deferredBefore + 1,
                       "S_late_midglide R1: debug_strip deferred= did not count exactly one re-pin left to the strip's rest, so the Watchlist landed 500 ms into the Down's 1.0 s glide but the re-pin did not see the strip moving (it ran an instant scroll mid-glide, action=now: the iteration-6 failure): before=\(deferredBefore) now='\(line)'")
        XCTAssertGreaterThanOrEqual(Self.int(line, "settles") ?? -1, settlesBefore + 1,
                                    "S_late_midglide R2: debug_strip settles= did not count the re-pin at rest after the glide: before=\(settlesBefore) now='\(line)'")
        let rest = focParts(app)
        guard rest.row != "-", rest.row != c1, !Self.topKeys.contains(rest.row) else {
            XCTFail("the Down did not move focus from \(c1) to the next catalog row: '\(line)'")
            throw HarnessAbort("focus did not move down")
        }
        XCTAssertEqual(Self.int(line, "row"), rowBefore + 2,
                       "A1b: debug_strip row= is not one Down plus one row inserted above: before=\(rowBefore) now='\(line)'")
        assertStripShowsFocusedRow(app, slot, row: rest.row, item: rest.item, tag: "S_late_midglide")
    }

    /// D10 r1 (item 5, iteration 1's shape): a press lands right after the insert. The seed lands
    /// 300 ms into one Down's 1.0 s glide; the leg presses Down again the moment it sees the row, so the
    /// second glide starts while the first still runs. The strip must end on the row that second Down
    /// focused (`restAnchor`), not on the re-pin's target.
    func testStage_LateWatchlistPressRightAfterInsert() throws {
        let app = launch(Self.stageBase + ["-home_upcoming_row_enabled", "NO",
                                           "-debug.stripPageSeconds", "1.0",
                                           "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                           "-debug.homeWatchlistSeedDelayMs", "25000",
                                           "-debug.homeWatchlistSeedOnPageMs", "300"], settle: 4)
        defer { app.terminate() }
        let slot = try stageSlot(app)
        try requireSeedNotRefused(app)
        let c1 = try stageEnterFirstCatalogRow(app)
        try waitForArmedSeed(app)
        let rowBefore = Self.int(strip(app), "row") ?? -1
        let deferredBefore = Self.int(strip(app), "deferred") ?? -1
        let settlesBefore = Self.int(strip(app), "settles") ?? -1
        let pressed = Date()
        remote.press(.down)
        guard poll(5, step: 0.05, { watchlistCount(app) > 0 }) else {
            XCTFail("the Down's glide did not land the armed seed: '\(label(app, "debug_homeWatchlist"))' strip='\(strip(app))'")
            throw HarnessAbort("no insert on the glide")
        }
        remote.press(.down)
        let secondPressAfter = Date().timeIntervalSince(pressed)
        note("S_late_press_after", "second Down sent \(Int(secondPressAfter * 1000)) ms after the first (insert at 300 ms; glide 1000 ms)")
        XCTAssertLessThan(secondPressAfter, 0.9,
                          "harness: the second Down was sent \(Int(secondPressAfter * 1000)) ms after the first, past the first glide's 1.0 s, so this run did not test a press landing while the strip moves")
        pause(5.0)
        let line = strip(app)
        XCTAssertGreaterThanOrEqual(Self.int(line, "deferred") ?? -1, deferredBefore + 1,
                                    "S_late_press_after R1: debug_strip deferred= did not count the re-pin left to the rest of the moving strip at the insert: before=\(deferredBefore) now='\(line)'")
        XCTAssertGreaterThanOrEqual(Self.int(line, "settles") ?? -1, settlesBefore + 1,
                                    "S_late_press_after R2: debug_strip settles= did not count the re-pin at rest after the second glide: before=\(settlesBefore) now='\(line)'")
        let rest = focParts(app)
        guard rest.row != "-", rest.row != c1, !Self.topKeys.contains(rest.row) else {
            XCTFail("focus is not on a catalog row below \(c1) after two Downs: '\(line)'")
            throw HarnessAbort("focus off the catalog rows")
        }
        XCTAssertEqual(Self.int(line, "row"), rowBefore + 3,
                       "A1b: debug_strip row= is not two Downs plus one row inserted above: before=\(rowBefore) now='\(line)'")
        assertStripShowsFocusedRow(app, slot, row: rest.row, item: rest.item, tag: "S_late_press_after")
    }

    /// D10 r1 (finding 1, variant B): a row lands above the Menu glide's target 300 ms into that glide.
    /// No Continue Watching, so the Watchlist becomes row 0, above the first catalog row Menu pages to;
    /// focus on the fourth catalog row, so Menu is a long glide with a mounted span. The re-pin is left
    /// to the strip's rest and then goes to the SAME row (never the new row 0, §4), where the strip
    /// must end.
    func testStage_LateWatchlistLandsDuringMenuGlide() throws {
        try requireNoStoredContinueWatching()
        let app = launch(Self.stageBase + ["-home_upcoming_row_enabled", "NO",
                                           "-debug.stripPageSeconds", "1.0",
                                           "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                           "-debug.homeWatchlistSeedDelayMs", "30000",
                                           "-debug.homeWatchlistSeedOnPageMs", "300"], settle: 4)
        defer { app.terminate() }
        let slot = try stageSlot(app)
        try requireSeedNotRefused(app)
        let c1 = try stageEnterFirstCatalogRow(app)
        guard Self.int(strip(app), "row") == 0 else {
            throw HarnessAbort("with no Continue Watching the first catalog row is row 0: '\(strip(app))'")
        }
        var deep = c1
        for _ in 0..<3 { deep = stageStep(app, .down) }
        guard (Self.int(strip(app), "row") ?? 0) >= 3, deep != "-", !Self.topKeys.contains(deep) else {
            throw HarnessAbort("the leg needs a fourth catalog row (Menu from row 3 or deeper is a long glide): '\(strip(app))'")
        }
        try waitForArmedSeed(app)
        let deferredBefore = Self.int(strip(app), "deferred") ?? -1
        XCTAssertEqual(deferredBefore, 0, "no deferred re-pin before Menu: \(strip(app))")
        remote.press(.menu)
        guard poll(5, step: 0.1, { watchlistCount(app) > 0 }) else {
            XCTFail("the Menu glide did not land the armed seed: '\(label(app, "debug_homeWatchlist"))' strip='\(strip(app))'")
            throw HarnessAbort("no insert on the Menu glide")
        }
        pause(5.0)
        let line = strip(app)
        XCTAssertEqual(app.state, .runningForeground, "Menu below row 0 pages to the top, never leaves the app")
        XCTAssertEqual(Self.int(line, "deferred"), deferredBefore + 1,
                       "S_late_menu R1: debug_strip deferred= did not count exactly one re-pin left to the strip's rest, so the row that landed above the Menu target mid-glide was not deferred: before=\(deferredBefore) now='\(line)'")
        XCTAssertEqual(focParts(app).row, c1,
                       "the Menu glide still ends on \(c1), never on the new row 0 (§4: a re-pin never redirects a Menu glide): '\(line)'")
        XCTAssertEqual(Self.int(line, "row"), 1, "A1b: \(c1) is row 1 under the new Watchlist row: '\(line)'")
        XCTAssertEqual(Self.token(line, "atTop"), "0", "D-A: the strip no longer rests on row 0: '\(line)'")
        assertStripShowsFocusedRow(app, slot, row: c1, item: nil, tag: "S_late_menu")
    }

    /// D10 (fix legs): the rest case one level deeper. Focus rests on the THIRD catalog row (index 2
    /// or more) when the delayed Watchlist lands above it. Settles whether `.scrollPosition(id:)`
    /// keeps the offset mid-strip too; with the re-pin it must pass either way.
    func testStage_LateWatchlistRestOnThirdCatalogRow() throws {
        let app = launch(Self.stageBase + ["-home_upcoming_row_enabled", "NO",
                                           "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                           "-debug.homeWatchlistSeedDelayMs", "30000"], settle: 4)
        defer { app.terminate() }
        let slot = try stageSlot(app)
        try requireSeedNotRefused(app)
        let c1 = try stageEnterFirstCatalogRow(app)
        let c2 = stageStep(app, .down)
        let c3 = stageStep(app, .down)
        guard c2 != c1, c3 != c2, c3 != "-", !Self.topKeys.contains(c2), !Self.topKeys.contains(c3) else {
            throw HarnessAbort("the leg needs three catalog rows below the slot: \(c1) → \(c2) → \(c3): '\(strip(app))'")
        }
        guard watchlistCount(app) == 0 else {
            XCTFail("the 30 s delay elapsed before focus reached \(c3): '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("Watchlist landed too early")
        }
        pause(2.0)
        let before = focParts(app)
        let rowBefore = Self.int(strip(app), "row") ?? -1
        XCTAssertEqual(before.row, c3, "focus rests on \(c3) before the insert: \(strip(app))")
        XCTAssertGreaterThanOrEqual(rowBefore, 2, "the focused row is index 2 or deeper: \(strip(app))")
        let baseline = focusedCardInSlot(app, slot)
        guard baseline.ok else {
            XCTFail("A2c baseline fails BEFORE the insert, so the oracle is not usable here: \(baseline.detail)")
            throw HarnessAbort("A2c baseline")
        }
        guard poll(45, step: 0.5, { watchlistCount(app) > 0 }) else {
            XCTFail("the late Watchlist never landed: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("no late Watchlist row")
        }
        XCTAssertEqual(Self.token(label(app, "debug_homeWatchlist"), "held"), "0",
                       "Stage never holds the row (D10): '\(label(app, "debug_homeWatchlist"))'")
        try requireWatchlistSeed(app)
        pause(5.0)
        XCTAssertEqual(Self.int(strip(app), "row"), rowBefore + 1,
                       "A1b: debug_strip row= did not move down by one with the insert: before=\(rowBefore) now='\(strip(app))'")
        assertStripShowsFocusedRow(app, slot, row: c3, item: before.item, tag: "S_late_rest_deep")
    }

    /// D10 (fix legs): a row REMOVED above the resting row. The Watchlist seed is there at launch and
    /// withdrawn 30 s later (`-debug.homeWatchlistSeedClearMs`) while focus rests on the second
    /// catalog row; the strip must keep showing that row as its index drops by one.
    func testStage_WatchlistRemovedAboveRestingRow() throws {
        let app = launch(Self.stageBase + ["-home_upcoming_row_enabled", "NO",
                                           "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                           "-debug.homeWatchlistSeedClearMs", "30000"], settle: 4)
        defer { app.terminate() }
        let slot = try stageSlot(app)
        try requireWatchlistSeed(app)
        // Passes through the Watchlist row (a top key) on the way down.
        let c1 = try stageEnterFirstCatalogRow(app)
        let c2 = stageStep(app, .down)
        guard c2 != c1, c2 != "-", !Self.topKeys.contains(c2) else {
            throw HarnessAbort("the leg needs two catalog rows below the slot; Down from \(c1) gave \(c2): '\(strip(app))'")
        }
        guard watchlistCount(app) > 0 else {
            XCTFail("the seed was withdrawn before focus reached \(c2): '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("Watchlist cleared too early")
        }
        pause(2.0)
        let before = focParts(app)
        let rowBefore = Self.int(strip(app), "row") ?? -1
        XCTAssertEqual(before.row, c2, "focus rests on \(c2) before the removal: \(strip(app))")
        let baseline = focusedCardInSlot(app, slot)
        guard baseline.ok else {
            XCTFail("A2c baseline fails BEFORE the removal, so the oracle is not usable here: \(baseline.detail)")
            throw HarnessAbort("A2c baseline")
        }
        guard poll(45, step: 0.5, { watchlistCount(app) == 0 }) else {
            XCTFail("the Watchlist seed was never withdrawn: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("no removal")
        }
        pause(5.0)
        XCTAssertEqual(Self.int(strip(app), "row"), rowBefore - 1,
                       "A1b: debug_strip row= did not move up by one with the removal: before=\(rowBefore) now='\(strip(app))'")
        assertStripShowsFocusedRow(app, slot, row: c2, item: before.item, tag: "S_removed_rest")
    }

    /// D10 (fix legs): covered Home. Focus on the third catalog row, Select opens Detail, the delayed
    /// Watchlist lands while Detail is up, Menu pops: the pop restore must land on the same row and
    /// card with the strip showing that row in its slot (the owed `onAppear` re-pin).
    func testStage_LateWatchlistLandsWhileDetailCovers() throws {
        let app = launch(Self.stageBase + ["-home_upcoming_row_enabled", "NO",
                                           "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                                           "-debug.homeWatchlistSeedDelayMs", "30000"], settle: 4)
        // ≈ when Home appeared and HomeView.onAppear ran startWatchlist() (as in the in-flight leg).
        let t0 = Date().addingTimeInterval(-4)
        defer { app.terminate() }
        let slot = try stageSlot(app)
        try requireSeedNotRefused(app)
        let c1 = try stageEnterFirstCatalogRow(app)
        let c2 = stageStep(app, .down)
        let c3 = stageStep(app, .down)
        guard c2 != c1, c3 != c2, c3 != "-", !Self.topKeys.contains(c2), !Self.topKeys.contains(c3) else {
            throw HarnessAbort("the leg needs three catalog rows below the slot: \(c1) → \(c2) → \(c3): '\(strip(app))'")
        }
        pause(2.0)
        let before = focParts(app)
        let rowBefore = Self.int(strip(app), "row") ?? -1
        guard watchlistCount(app) == 0 else {
            XCTFail("the 30 s delay elapsed before Detail could open: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("Watchlist landed too early")
        }
        guard before.row == c3, before.item != "-", !before.item.hasPrefix("nuvio-folder://") else {
            throw HarnessAbort("focus is not on a catalog card of \(c3): '\(strip(app))' — not pressing Select")
        }
        guard focusedCardInSlot(app, slot).ok else {
            throw HarnessAbort("A2c baseline fails before Detail opens: \(focusedCardInSlot(app, slot).detail)")
        }
        // Detail must be up before the seed lands (≈ t0 + 30 s) and stay up until after it.
        guard Date() < t0.addingTimeInterval(25) else {
            throw HarnessAbort("too late to open Detail before the seed lands (\(Int(Date().timeIntervalSince(t0))) s)")
        }
        remote.press(.select)
        pause(3.0)
        shot("S_late_covered_detail")
        while Date() < t0.addingTimeInterval(36) { pause(0.5) }
        remote.press(.menu)
        // After ~30 s on Detail its inline trailer is playing and the first Menu only stops it
        // (screenshot evidence): press again while Home's readout is still absent.
        pause(1.5)
        if label(app, "debug_strip").isEmpty { remote.press(.menu) }
        let restored = poll(6.0) { focParts(app) == before }
        XCTAssertGreaterThan(watchlistCount(app), 0,
                             "the Watchlist landed while Detail was up: '\(label(app, "debug_homeWatchlist"))'")
        XCTAssertTrue(restored, "the pop restore lands on \(before.row)/\(before.item): '\(strip(app))'")
        XCTAssertEqual(app.state, .runningForeground, "one Menu from Detail pops, never leaves the app")
        pause(5.0)
        XCTAssertEqual(Self.int(strip(app), "row"), rowBefore + 1,
                       "A1b: debug_strip row= did not move down by one with the insert: before=\(rowBefore) now='\(strip(app))'")
        assertStripShowsFocusedRow(app, slot, row: c3, item: before.item, tag: "S_late_covered")
    }

    // MARK: - Test 25 (Classic: a late Watchlist stays held while the rail holds focus)

    private func railState(_ app: XCUIApplication) -> String { label(app, "rail_state") }
    private func railExpanded(_ app: XCUIApplication) -> Bool { Self.token(railState(app), "expanded") == "1" }

    /// §17: the rail's return row is below the slot, so the hold keeps the Watchlist back while the
    /// viewer sits in the rail; Right returns to the same row, then Up lands the held row.
    func testClassic_LateWatchlistHeldWhileRailHoldsFocus() throws {
        let app = launch(["-home_layout", "classic", "-hero_nuvio_style", "YES", "-inline_trailers_enabled", "NO",
                          "-hero_trailer_autoplay", "NO", "-sidebar_style", "rail", "-rail_visibility", "always",
                          "-discover_placement", "off", "-debug.homeScrollProbe", "YES",
                          "-home_upcoming_row_enabled", "NO",
                          "-debug.homeWatchlistSeedJsonB64", Self.wlSeed,
                          "-debug.homeWatchlistSeedDelayMs", "30000"], settle: 4)
        guard poll(30, step: 0.5, { !label(app, "debug_homeReturn").isEmpty && !railState(app).isEmpty }) else {
            throw HarnessAbort("readouts never appeared (rail mounted?)")
        }
        pause(1.0)
        var c1 = own(app)                       // launch focus may already sit on the first catalog row
        let launchFocus = (c1 == "-" || Self.topKeys.contains(c1)) ? "hero/top" : "first catalog row"
        if c1 == "-" || Self.topKeys.contains(c1) {
            c1 = "-"
            for _ in 0..<4 {
                c1 = classicStep(app, .down)
                if c1 != "-" && !Self.topKeys.contains(c1) { break }
            }
        }
        print("[leg25] launch focus: \(launchFocus); c1=\(c1)")
        guard c1 != "-", !Self.topKeys.contains(c1) else {
            XCTFail("focus never reached a catalog row (own=\(own(app))): '\(label(app, "debug_homeReturn"))'")
            throw HarnessAbort("focus never reached a catalog row")
        }
        XCTAssertEqual(Self.int(label(app, "debug_homeWatchlist"), "n"), 0, "the delay elapsed before focus reached the catalog row: '\(label(app, "debug_homeWatchlist"))'")
        for _ in 0..<6 where !railExpanded(app) {
            remote.press(.left)
            pause(0.8)
        }
        guard railExpanded(app) else {
            XCTFail("Left from the row's first card never opened the rail: \(railState(app))")
            throw HarnessAbort("rail never opened")
        }
        guard poll(45, step: 0.5, { Self.token(label(app, "debug_homeWatchlist"), "held") == "1" }) else {
            XCTFail("the late Watchlist was never held: '\(label(app, "debug_homeWatchlist"))'")
            throw HarnessAbort("no held Watchlist")
        }
        pause(1.5)
        let line = label(app, "debug_homeWatchlist")
        XCTAssertEqual(Self.int(line, "n"), 0, "the rail's return row is below the slot: the Watchlist stays held: '\(line)'")
        XCTAssertEqual(Self.token(line, "held"), "1", "still held in the rail: '\(line)'")
        remote.press(.right)
        XCTAssertTrue(poll(2.0) { !railExpanded(app) }, "Right closes the rail: \(railState(app))")
        XCTAssertTrue(poll(3.0) { own(app) == c1 }, "Right returns to \(c1): '\(label(app, "debug_homeReturn"))'")
        XCTAssertEqual(Self.int(label(app, "debug_homeWatchlist"), "n"), 0, "the held row is not inserted after the return")
        // The rail's exit verification takes 0.5 s: wait it out before Up, or the press races it.
        var settledSince: Date?
        let settleDeadline = Date().addingTimeInterval(5)
        var settled = false
        while Date() < settleDeadline {
            let rs = railState(app)
            let quiet = own(app) == c1 && Self.token(rs, "armed") == "0" && Self.token(rs, "focused") == "-1"
                && Self.token(rs, "gated") == "0"
            if quiet {
                if settledSince == nil { settledSince = Date() }
                if Date().timeIntervalSince(settledSince!) >= 0.6 { settled = true; break }
            } else {
                settledSince = nil
            }
            pause(0.1)
        }
        guard settled else {
            XCTFail("the rail never finished its exit (armed=0 focused=-1 gated=0, own=\(c1) for 0.6 s): '\(label(app, "debug_homeReturn"))' | '\(railState(app))'")
            throw HarnessAbort("rail exit never settled")
        }
        func onHero() -> Bool {
            let l = label(app, "debug_homeReturn")
            return own(app) == "-" && (l.contains("ret=own hero") || l.contains("ret=up press own=hero"))
        }
        func landed() -> Bool {
            let w = label(app, "debug_homeWatchlist")
            return (Self.int(w, "n") ?? 0) > 0 && Self.token(w, "held") == "0"
        }
        if landed() {   // released during the rail exit (the best-effort edge)
            print("[leg25] released-during-rail-exit")
            note("late_watchlist_rail", "released-during-rail-exit: \(label(app, "debug_homeReturn"))")
            let o = own(app)
            XCTAssertTrue(o == c1 || Self.topKeys.contains(o), "focus lost after an early release: '\(label(app, "debug_homeReturn"))'")
            try requireWatchlistSeed(app)
            return
        }
        remote.press(.up)
        XCTAssertTrue(poll(2.0, step: 0.1) { onHero() || landed() }, "Up from \(c1) did not reach the hero: '\(label(app, "debug_homeReturn"))'")
        XCTAssertFalse(own(app) != "-" && !Self.topKeys.contains(own(app)), "Up from \(c1) reached another catalog row: c1 was not the first catalog row: '\(label(app, "debug_homeReturn"))'")
        let ok = poll(5, step: 0.25) { landed() }
        let landedReadouts = "\(label(app, "debug_homeWatchlist")) | \(label(app, "debug_homeReturn")) | \(railState(app))"
        note("late_watchlist_rail", landedReadouts)
        XCTAssertTrue(ok, "the held Watchlist lands once focus leaves the catalog row: \(landedReadouts)")
        try requireWatchlistSeed(app)
        shot("classic_late_watchlist_rail")
    }
}
