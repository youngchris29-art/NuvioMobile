import XCTest

/// beta.19-rc1 verdict batch (spec P-A, `docs/research/steven-rc1-fix-spec-A-motion-trailers.md` §8):
/// the UI legs for the trailer rest gate (M3), the morph choreography and abort (R2), the morphed
/// card's ring colour (R1), the Trailer Start Delay setting (M4), the hero text swap and folder
/// return (M5) and the trailer listener lifecycle (B2).
///
/// Every oracle is a DEBUG accessibility label the app renders for exactly this purpose, never a
/// screenshot, because XCUITest frames ignore `.offset` / `.opacity` / `.visualEffect`:
///
///   - `debug_trailerMorph`   `<last InlineTrailerDebugLog line> aborts=N`
///                            (`event=gate|reveal|wide|shrink|dissolve|abort|defer|play|mute …`)
///   - `debug_trailerTile`    the tile geometry + `stage= gate= gateRest= gateStart= via= ring=`
///                            (exists only while the tile is visible)
///   - `debug_trailerListener` `<last> rebuilds=N recent=<newest six joined by " | ">`
///   - `debug_heroText`       `phase= shown= pending= swaps= maxLive=`
///   - `debug_hero`           `… src= fitem= … pitem=` (the focused item and the PRESENTED hero)
///
/// Frames DO follow LAYOUT (a card pushed aside by the widening tile moves in `snapshot()`), which
/// is what test86/test86B read, with test37's neighbour oracle.
///
/// Environment facts the legs are built around (measured on the FA87 fixture, a signed-out guest
/// with Cinemeta only and a local "Chris" profile):
///   - trailers resolve with `-debug.trailerSmokeVideoId rNZ0xKaCdus` (needs `-debug.trailerProbe YES`);
///   - initial focus is on the tab bar; the first Down reaches the hero CTA and the second a row-0
///     card, in the pinned Nuvio hero and in classic alike. The legs do not count Downs: they walk
///     until `debug_hero fitem=` reports a row card (`landOnFirstCard`);
///   - SIMULATOR QUIRK (also on the unchanged base build): with the pinned Nuvio hero and Trailer
///     Location = poster, focus jumps from a morphing row-0 card up into the hero ~1.3 s after the
///     morph starts and collapses the card. Morph legs therefore run classic (`-hero_nuvio_style NO`)
///     where the morph plays through; test85 runs pinned only because it reads the gate fields the
///     moment the tile first appears (before the jump) and it is the leg that covers the pinned rest
///     source;
///   - `hasFocus` is only trusted from a `snapshot()` (test37's pattern). A prerequisite that fails
///     is an `XCTSkip` with the precise reason, never a silent pass.
///
/// Helpers are a trimmed COPY of the other UI-test files' (`InlineTrailerTileProbeTests`,
/// `HeroFolderSwapTests`, `NuvioTVUITests`) rather than a shared import: same house rule they give
/// (each is `private` to its file).
final class TrailerMotionUITests: XCTestCase {

    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers (duplicated by house rule)

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
        print("[TrailerMotion] \(name): \(text)")
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

    /// Always a fresh launch (every leg needs its launch arguments in effect), then the profile
    /// gate (profile "Chris", no PIN) and the Home catalog fan-out.
    @discardableResult
    private func launchToHome(extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // Home Stage & Strip (W3, 2026-10-05): Stage is the app's default Home now, and this file
        // measures Classic Home (the legs read `debug_hero fitem=`, which only Classic's rows
        // feed), so every launch pins Classic.
        app.launchArguments += ["-home_layout", "classic"]
        app.launchArguments += extraArguments
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

    /// `NuvioTVUITests.launchToHomeWithSeededCollections`: `json` imported as the active profile's
    /// collections through the DEBUG-only `-debug.collectionsSeedJsonB64` knob. The import REPLACES
    /// and persists the profile's collections, so the caller re-seeds `"[]"` in a `defer`. The app
    /// refuses the seed on a signed-in cloud account, in which case the walk finds no folder and the
    /// leg skips with that reason.
    private func launchToHomeWithSeededCollections(_ json: String, extraArguments: [String] = []) -> XCUIApplication {
        let b64 = Data(json.utf8).base64EncodedString()
        return launchToHome(extraArguments: ["-debug.collectionsSeedJsonB64", b64] + extraArguments)
    }

    /// The UX-4c smoke id (`TrailerSoakTests.smokeVideoId`): a known bar-free 16:9 trailer.
    private static let smokeVideoId = "rNZ0xKaCdus"

    /// The inline-trailer launch recipe every leg shares. `-home_upcoming_row_enabled NO` pins the
    /// row geometry (TrailerSoakTests' trick); the argument domain wins over any stored value, so no
    /// leg touches the synced profile. `-hero_trailer_autoplay` is forced either way so the carousel
    /// autoplay never takes the single extraction slot or satisfies a hero-phase oracle by accident.
    private func trailerArguments(location: String, heroPinned: Bool, startDelay: String,
                                  heroAutoplay: Bool = false, extra: [String] = []) -> [String] {
        [
            "-inline_trailers_enabled", "YES",
            "-debug.trailerProbe", "YES",
            "-debug.trailerSmokeVideoId", Self.smokeVideoId,
            "-home_upcoming_row_enabled", "NO",
            "-trailer_playback_location", location,
            "-hero_nuvio_style", heroPinned ? "YES" : "NO",
            "-hero_trailer_autoplay", heroAutoplay ? "YES" : "NO",
            "-trailer_start_delay", startDelay,
        ] + extra
    }

    // MARK: - Probe reading

    /// One permanent Home label (`debug_hero`, `debug_trailerMorph`, …) by identifier; nil when it
    /// is not in the tree. Not for the transient `debug_trailerTile`: `exists` then `label` can race
    /// a vanishing element, which `sampleRow` (one snapshot) cannot.
    private func probe(_ app: XCUIApplication, _ identifier: String) -> String? {
        let element = app.staticTexts[identifier]
        guard element.exists else { return nil }
        return element.label
    }

    /// `key=value` token out of a probe line (first match wins, tolerant of token order). A prefix
    /// match from the start of the token: `rest=` never matches `gateRest=`.
    private static func token(_ line: String, _ key: String) -> String? {
        let prefix = key + "="
        for part in line.split(separator: " ") where part.hasPrefix(prefix) {
            // Gate 4 (main session): some readouts separate fields with ", " — `ring=poster,` must
            // read as `poster`.
            return String(part.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        }
        return nil
    }

    private static func number(_ line: String, _ key: String) -> Double? {
        token(line, key).flatMap { Double($0) }
    }

    /// The item id inside an event line's `key=<type>:<id>` (`TrailerResolutionCache.key`); the type
    /// is dropped by the FIRST colon only, so an id that itself carries colons survives.
    private static func keyItemId(_ line: String) -> String? {
        guard let key = token(line, "key") else { return nil }
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    /// Everything one `snapshot()` knows that the legs need: the requested labels by identifier and
    /// every button's frame + focus flag. One walk, so the morph label and the card frames describe
    /// the same instant.
    private struct RowSample {
        var labels: [String: String] = [:]
        var buttons: [(frame: CGRect, hasFocus: Bool)] = []
    }

    private func sampleRow(_ app: XCUIApplication, labelIds: [String]) -> RowSample? {
        guard let root = try? app.snapshot() else { return nil }
        var out = RowSample()
        func walk(_ node: XCUIElementSnapshot) {
            if !node.identifier.isEmpty, labelIds.contains(node.identifier), out.labels[node.identifier] == nil {
                out.labels[node.identifier] = node.label
            }
            if node.elementType == .button { out.buttons.append((node.frame, node.hasFocus)) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// test37's neighbour oracle: the leftmost button to the right of `anchor` in its row band.
    private func firstNeighbourMinX(_ buttons: [(frame: CGRect, hasFocus: Bool)], anchor: CGRect) -> CGFloat? {
        buttons.compactMap { button -> CGFloat? in
            let frame = button.frame
            guard abs(frame.midY - anchor.midY) < 20, frame.minX > anchor.maxX - 1 else { return nil }
            return frame.minX
        }.min()
    }

    /// `debug_trailerTile`'s gate fields (append-only tail; `-` when the model has no value).
    private struct TileFields {
        let stage, gate, via, ring: String?
        let gateRest, gateStart: Double?
        init(_ label: String) {
            stage = TrailerMotionUITests.token(label, "stage")
            gate = TrailerMotionUITests.token(label, "gate")
            via = TrailerMotionUITests.token(label, "via")
            ring = TrailerMotionUITests.token(label, "ring")
            gateRest = TrailerMotionUITests.number(label, "gateRest")
            gateStart = TrailerMotionUITests.number(label, "gateStart")
        }
    }

    // MARK: - Walking

    /// The focused row item's bare id off `debug_hero fitem=`, or nil while no row card holds focus
    /// (`fitem=-`: the tab bar or the hero CTA). Independent of `hasFocus`.
    private func focusedItemId(_ app: XCUIApplication) -> String? {
        guard let hero = probe(app, "debug_hero"), let id = Self.token(hero, "fitem"), id != "-" else { return nil }
        return id
    }

    /// The PRESENTED hero's identity off `debug_hero pitem=` (what the resolver actually committed,
    /// as opposed to `fitem=`, the focus target), or nil when the probe is unreadable.
    private func presentedItem(_ app: XCUIApplication) -> String? {
        guard let hero = probe(app, "debug_hero") else { return nil }
        return Self.token(hero, "pitem")
    }

    /// Presses Down until a row card reports focus through `fitem=` (the hero commit lags a row
    /// focus by 0.2 s, plus up to 0.5 s waiting for rest, so each press polls for it). Returns the
    /// item id, or nil after `maxDowns`.
    private func landOnFirstCard(_ app: XCUIApplication, maxDowns: Int = 8) -> String? {
        for _ in 0..<maxDowns {
            press(.down, gap: 0.9)
            for _ in 0..<6 {
                if let id = focusedItemId(app) { return id }
                pause(0.3)
            }
        }
        return nil
    }

    /// Presses Right and waits for `fitem=` to name a different card (so a following `key=` match
    /// is against the NEW title). Returns that id, or nil when focus did not move.
    private func advance(_ app: XCUIApplication, from previous: String) -> String? {
        press(.right, gap: 0.6)
        for _ in 0..<8 {
            if let id = focusedItemId(app), id != previous { return id }
            pause(0.3)
        }
        return nil
    }

    /// First `debug_trailerTile` label seen on the focused card, trying up to `cards` cards (a
    /// title that lists no trailer never morphs, so the walk moves one card right and tries again).
    /// nil = no tile on any of them: trailer extraction unavailable on this host.
    private func awaitTile(_ app: XCUIApplication, cards: Int, perCard: TimeInterval) -> String? {
        for card in 0..<cards {
            let deadline = Date().addingTimeInterval(perCard)
            while Date() < deadline {
                if let label = sampleRow(app, labelIds: ["debug_trailerTile"])?.labels["debug_trailerTile"] {
                    return label
                }
                pause(0.25)
            }
            if card < cards - 1 { press(.right, gap: 0.6) }
        }
        return nil
    }

    /// The `debug_trailerMorph` line that reports `event=play host=<host>` for `itemId`, polled up
    /// to `timeout`. Matching the item id makes it the focused card's playback, not a stale line or
    /// another host's. `onTick` runs on every poll (test91 accumulates the listener trace there).
    private func waitForPlay(_ app: XCUIApplication, host: String, itemId: String, timeout: TimeInterval,
                             onTick: (() -> Void)? = nil) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            onTick?()
            if let line = probe(app, "debug_trailerMorph"),
               line.contains("event=play host=\(host)"),
               Self.keyItemId(line) == itemId {
                return line
            }
            pause(0.4)
        }
        return nil
    }

    /// Presses Play/Pause and waits up to `timeout` for a `debug_trailerMorph` line reading
    /// `event=mute` whose `muted=` differs from `previous` (nil = accept the first). The stale
    /// `event=mute` line from the previous press is never accepted. Returns the new `muted=` value.
    private func pressPlayPauseForMute(_ app: XCUIApplication, differingFrom previous: String?, timeout: TimeInterval = 3) -> String? {
        remote.press(.playPause)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pause(0.25)
            if let line = probe(app, "debug_trailerMorph"), line.contains("event=mute"),
               let muted = Self.token(line, "muted"), muted != previous {
                return muted
            }
        }
        return nil
    }

    // MARK: - M3: the trailer starts after the rows stop

    /// test85. Pinned Nuvio hero (the fixture default, so the pinned rest source is the one under
    /// test), poster location, `-trailer_start_delay auto`. Reads the gate fields the moment the
    /// tile first appears: `via=rest`, and the start is at least 0.95 s after the rest began
    /// (Automatic = rest + 1 s). `via=ceiling` here is a real finding (the rest decision never
    /// came: the phantom-armed corrector class), so it fails loudly instead of skipping.
    func test85TrailerStartsAfterRest() throws {
        let app = launchToHome(extraArguments: trailerArguments(location: "poster", heroPinned: true, startDelay: "auto"))
        guard let landed = landOnFirstCard(app) else {
            throw XCTSkip("test85: no row card reported focus (debug_hero fitem=) within 8 Down presses — Home rows did not load")
        }
        note("85_landed", "fitem=\(landed)")
        guard let label = awaitTile(app, cards: 3, perCard: 18) else {
            throw XCTSkip("test85: trailer extraction unavailable on this host — no debug_trailerTile on 3 consecutive cards within 18 s each")
        }
        shot("85_tile_first_seen")
        note("85_tile", label)
        let fields = TileFields(label)
        XCTAssertEqual(fields.gate, "auto", "Trailer Start Delay was pinned to auto — got \(label)")
        XCTAssertEqual(fields.via, "rest", "the gate must start via=rest (via=ceiling means the rest decision never arrived within 3 s). \(label)")
        guard let rest = fields.gateRest, let start = fields.gateStart else {
            XCTFail("test85: gateRest/gateStart unreadable (gateRest=\(String(describing: fields.gateRest)) gateStart=\(String(describing: fields.gateStart))) — via=\(fields.via ?? "nil"). \(label)")
            return
        }
        let afterRest = start - rest
        XCTAssertGreaterThanOrEqual(afterRest, 0.95,
                                    "Automatic must start at least 0.95 s after rest began — gateRest=\(rest) gateStart=\(start). \(label)")
        XCTAssertLessThanOrEqual(afterRest, 2.0,
                                 "Automatic should start about 1 s after rest (poll is 0.05 s) — gateRest=\(rest) gateStart=\(start). \(label)")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the rest-gate leg")
    }

    /// test85B (critique #1). Trailer Location: Hero, pinned hero, hero autoplay on (the verified
    /// recipe). With a row card focused the HERO model plays that card's trailer
    /// (`event=play host=hero key=<the focused card>`); Play/Pause must then toggle the mute through
    /// the row's `rowPlayingKey` (`event=mute muted=…`) and flip back on the second press. Waits for
    /// the hero play of the FOCUSED card's id, so the carousel's own autoplay line never satisfies it.
    func test85BHeroLocationMuteToggle() throws {
        let app = launchToHome(extraArguments: trailerArguments(location: "hero", heroPinned: true, startDelay: "1", heroAutoplay: true))
        guard let landed = landOnFirstCard(app) else {
            throw XCTSkip("test85B: no row card reported focus (debug_hero fitem=) within 8 Down presses — Home rows did not load")
        }
        guard let playLine = waitForPlay(app, host: "hero", itemId: landed, timeout: 60) else {
            throw XCTSkip("test85B: trailer extraction unavailable on this host — no `event=play host=hero` for the focused card (\(landed)) within 60 s. Last debug_trailerMorph: \(probe(app, "debug_trailerMorph") ?? "absent")")
        }
        note("85B_play", playLine)
        shot("85B_hero_playing")
        // Play/Pause belongs to the focused card; make sure focus is still on the card whose trailer plays.
        XCTAssertEqual(focusedItemId(app), landed, "focus left the card whose trailer the hero is playing before Play/Pause was pressed")

        guard let first = pressPlayPauseForMute(app, differingFrom: nil) else {
            XCTFail("test85B: Play/Pause produced no `event=mute` within 3 s in Trailer Location: Hero — the hero's key never reached the focused card's row (rowPlayingKey). Last debug_trailerMorph: \(probe(app, "debug_trailerMorph") ?? "absent")")
            return
        }
        guard let second = pressPlayPauseForMute(app, differingFrom: first) else {
            XCTFail("test85B: the second Play/Pause produced no `event=mute` with muted≠\(first) within 3 s. Last debug_trailerMorph: \(probe(app, "debug_trailerMorph") ?? "absent")")
            return
        }
        XCTAssertNotEqual(first, second, "the second Play/Pause must flip the mute value")
        note("85B_mute", "first muted=\(first) second muted=\(second)")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the hero-location mute leg")
    }

    /// test85C. The poster-location half of critique #1: classic hero, the CARD model plays
    /// (`event=play host=card`), and Play/Pause toggles the mute through the same per-row path.
    func test85CPosterLocationMuteToggle() throws {
        let app = launchToHome(extraArguments: trailerArguments(location: "poster", heroPinned: false, startDelay: "1"))
        guard var current = landOnFirstCard(app) else {
            throw XCTSkip("test85C: no row card reported focus (debug_hero fitem=) within 8 Down presses — Home rows did not load")
        }
        var foundPlay: String?
        for card in 0..<3 {
            foundPlay = waitForPlay(app, host: "card", itemId: current, timeout: 25)
            if foundPlay != nil { break }
            guard card < 2, let next = advance(app, from: current) else { break }
            current = next
        }
        guard let playLine = foundPlay else {
            throw XCTSkip("test85C: trailer extraction unavailable on this host — no `event=play host=card` on 3 consecutive cards. Last debug_trailerMorph: \(probe(app, "debug_trailerMorph") ?? "absent")")
        }
        note("85C_play", playLine)
        XCTAssertEqual(focusedItemId(app), current, "focus left the playing card before Play/Pause was pressed")

        guard let first = pressPlayPauseForMute(app, differingFrom: nil) else {
            XCTFail("test85C: Play/Pause produced no `event=mute` within 3 s in Trailer Location: Poster. Last debug_trailerMorph: \(probe(app, "debug_trailerMorph") ?? "absent")")
            return
        }
        guard let second = pressPlayPauseForMute(app, differingFrom: first) else {
            XCTFail("test85C: the second Play/Pause produced no `event=mute` with muted≠\(first) within 3 s. Last debug_trailerMorph: \(probe(app, "debug_trailerMorph") ?? "absent")")
            return
        }
        XCTAssertNotEqual(first, second, "the second Play/Pause must flip the mute value")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the poster-location mute leg")
    }

    // MARK: - R2: morph abort

    private struct AbortObservation {
        /// The first right-hand neighbour's minX before the dwell (card #2 for a first-card focus).
        var baseline: CGFloat = 0
        /// Largest rightward shift over the whole observation (the widened tile pushing card #2).
        var peakShift: CGFloat = 0
        /// Largest |shift| over every sample, abort included.
        var maxAbsShift: CGFloat = 0
        var tileSeen = false
        /// The `debug_trailerMorph` line at the first sample whose `aborts=` rose.
        var abortLine: String?
        /// |shift| at every sample taken from the abort on.
        var postAbortShifts: [CGFloat] = []
        /// The last post-abort sample carried no `debug_trailerTile`.
        var tileGoneAfterAbort = false
    }

    /// Takes a baseline from ONE snapshot (the focused portrait poster, its first right-hand
    /// neighbour and the abort counter), then samples every ~0.2 s for `window` seconds, tracking the
    /// neighbour's shift, until the abort counter rises; then collects a few more samples. XCUITest
    /// frames follow LAYOUT, so the widened tile's push shows as a shift while the stage is `.wide`.
    private func observeAbort(_ app: XCUIApplication, tag: String, window: TimeInterval) throws -> AbortObservation {
        let ids = ["debug_trailerMorph", "debug_trailerTile"]
        guard let base = sampleRow(app, labelIds: ids),
              let anchor = base.buttons.first(where: { $0.hasFocus })?.frame else {
            throw XCTSkip("\(tag): no focused element reported before the dwell (the runtime does not report hasFocus reliably) — cannot read the neighbour oracle")
        }
        guard anchor.width > 80, anchor.height > anchor.width else {
            throw XCTSkip("\(tag): the focused element is not a resting portrait poster — frame=\(anchor)")
        }
        guard let baseline = firstNeighbourMinX(base.buttons, anchor: anchor) else {
            throw XCTSkip("\(tag): the focused poster has no row neighbour to its right — frame=\(anchor)")
        }
        let abortsBefore = Self.number(base.labels["debug_trailerMorph"] ?? "", "aborts").map { Int($0) } ?? 0
        var obs = AbortObservation()
        obs.baseline = baseline
        shot("\(tag)_00_baseline")

        let deadline = Date().addingTimeInterval(window)
        var postSamples = 0
        while Date() < deadline, postSamples < 4 {
            guard let sample = sampleRow(app, labelIds: ids) else { pause(0.2); continue }
            let morph = sample.labels["debug_trailerMorph"] ?? ""
            let tile = sample.labels["debug_trailerTile"]
            if tile != nil { obs.tileSeen = true }
            let aborts = Self.number(morph, "aborts").map { Int($0) } ?? 0
            if let neighbour = firstNeighbourMinX(sample.buttons, anchor: anchor) {
                let shift = neighbour - baseline
                obs.peakShift = max(obs.peakShift, shift)
                obs.maxAbsShift = max(obs.maxAbsShift, abs(shift))
                if aborts > abortsBefore {
                    obs.postAbortShifts.append(abs(shift))
                }
            }
            if aborts > abortsBefore {
                if obs.abortLine == nil { obs.abortLine = morph }
                obs.tileGoneAfterAbort = tile == nil
                postSamples += 1
                pause(0.3)
            } else {
                pause(0.15)
            }
        }
        shot("\(tag)_01_after")
        note("\(tag)_observation", "baseline=\(obs.baseline) peakShift=\(obs.peakShift) maxAbsShift=\(obs.maxAbsShift) tileSeen=\(obs.tileSeen) abortLine=\(obs.abortLine ?? "nil") post=\(obs.postAbortShifts) tileGone=\(obs.tileGoneAfterAbort)")
        return obs
    }

    /// Walks to the first card, then to card #1 of the row (so the widened tile pushes card #2 and
    /// never needs a horizontal row scroll), and observes up to three cards for an abort.
    private func runAbortLeg(_ app: XCUIApplication, tag: String) throws -> AbortObservation {
        guard landOnFirstCard(app) != nil else {
            throw XCTSkip("\(tag): no row card reported focus (debug_hero fitem=) within 8 Down presses — Home rows did not load")
        }
        press(.left, times: 8, gap: 0.25) // card #1 (Left at the row start is a no-op)
        pause(0.8)
        for attempt in 0..<3 {
            if attempt > 0 { press(.right, gap: 0.8) }
            let obs = try observeAbort(app, tag: "\(tag)_card\(attempt)", window: 24)
            if obs.tileSeen || obs.abortLine != nil { return obs }
        }
        throw XCTSkip("\(tag): trailer extraction unavailable on this host — no debug_trailerTile on 3 consecutive cards")
    }

    /// test86 (critique #7). Classic hero, poster location, a 3 s fixed delay (a wide baseline
    /// window), `-debug.trailerMorphAbortAfterWideMs 2500` so `reset()` fires 2.5 s after the
    /// `.wide` edge, and `-debug.trailerAbortWindowMs 4000` so that reset still counts as an
    /// "instant" abort. The pushed layout is observed first (card #2 shifted by > 20 pt), then
    /// `event=abort style=instant stage=wide`, then card #2 is back at its baseline ± 2 pt in the
    /// same frame and the tile is gone.
    func test86MorphAbortIsInstant() throws {
        let app = launchToHome(extraArguments: trailerArguments(
            location: "poster", heroPinned: false, startDelay: "3",
            extra: ["-debug.trailerMorphAbortAfterWideMs", "2500", "-debug.trailerAbortWindowMs", "4000"]))
        let obs = try runAbortLeg(app, tag: "86")
        XCTAssertGreaterThan(obs.peakShift, 20,
                             "the widened tile never pushed card #2 (peak shift \(obs.peakShift) pt) — the morph did not reach .wide inside the observation window")
        guard let line = obs.abortLine else {
            XCTFail("test86: no abort observed (aborts= never rose) although the abort knob should fire 2.5 s after .wide — peakShift=\(obs.peakShift)")
            return
        }
        XCTAssertTrue(line.contains("event=abort"), "the last event at the abort sample was not an abort: \(line)")
        XCTAssertTrue(line.contains("style=instant"), "the abort must be instant, got: \(line)")
        XCTAssertTrue(line.contains("stage=wide"), "the abort must come from the .wide stage, got: \(line)")
        XCTAssertFalse(obs.postAbortShifts.isEmpty, "no neighbour reading after the abort")
        for (index, shift) in obs.postAbortShifts.enumerated() {
            XCTAssertLessThanOrEqual(shift, 2, "card #2 is \(shift) pt from its baseline in post-abort sample \(index) — the abort must restore the layout in one frame")
        }
        XCTAssertTrue(obs.tileGoneAfterAbort, "debug_trailerTile was still present after the abort")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the abort leg")
    }

    /// test86B. `-debug.trailerMorphAbortAfterRevealMs 60`: the abort lands in the in-place reveal
    /// stage, before the width ever grows, so `event=abort style=instant stage=reveal` is the proof
    /// the morph started and was cut, and card #2 never moved (every sample within ± 2 pt).
    func test86BRevealAbort() throws {
        let app = launchToHome(extraArguments: trailerArguments(
            location: "poster", heroPinned: false, startDelay: "3",
            extra: ["-debug.trailerMorphAbortAfterRevealMs", "60"]))
        let obs = try runAbortLeg(app, tag: "86B")
        guard let line = obs.abortLine else {
            XCTFail("test86B: no abort observed (aborts= never rose) although the knob should fire 60 ms after the reveal edge — tileSeen=\(obs.tileSeen)")
            return
        }
        XCTAssertTrue(line.contains("event=abort"), "the last event at the abort sample was not an abort: \(line)")
        XCTAssertTrue(line.contains("style=instant"), "the abort must be instant, got: \(line)")
        XCTAssertTrue(line.contains("stage=reveal"), "the abort must come from the .reveal stage, got: \(line)")
        XCTAssertLessThanOrEqual(obs.maxAbsShift, 2, "card #2 moved \(obs.maxAbsShift) pt although the width never grows in the reveal stage")
        XCTAssertTrue(obs.tileGoneAfterAbort, "debug_trailerTile was still present after the abort")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the reveal-abort leg")
    }

    // MARK: - R1: the morphed card's ring keeps the poster colour

    /// test87. `-accent_focus_ring YES -focus_ring_poster_color YES` (zoom on): the tile's ring takes
    /// the poster's own colour, `ring=poster`. The colour can land a beat after the tile appears
    /// (`sampleTileColors`), so each card is polled for 3 s; grey art legitimately keeps the accent
    /// colour (`ring=accent`), so up to four cards are tried and the leg skips only when every one of
    /// them reads `accent`. Any other value is a failure.
    func test87MorphedRingKeepsPosterColour() throws {
        let app = launchToHome(extraArguments: trailerArguments(
            location: "poster", heroPinned: false, startDelay: "1",
            extra: ["-accent_focus_ring", "YES", "-focus_ring_poster_color", "YES", "-no_zoom_on_focus", "NO"]))
        guard landOnFirstCard(app) != nil else {
            throw XCTSkip("test87: no row card reported focus (debug_hero fitem=) within 8 Down presses — Home rows did not load")
        }
        var readings: [String] = []
        for card in 0..<4 {
            if card > 0 { press(.right, gap: 0.8) }
            guard let first = awaitTile(app, cards: 1, perCard: 16) else {
                readings.append("card\(card): no tile")
                continue
            }
            var ring = TileFields(first).ring
            let settle = Date().addingTimeInterval(3)
            while ring != "poster", Date() < settle {
                pause(0.3)
                if let latest = sampleRow(app, labelIds: ["debug_trailerTile"])?.labels["debug_trailerTile"] {
                    ring = TileFields(latest).ring
                }
            }
            readings.append("card\(card): ring=\(ring ?? "nil")")
            if ring == "poster" {
                shot("87_ring_poster")
                note("87_readings", readings.joined(separator: " | "))
                XCTAssertTrue(app.state == .runningForeground, "app must survive the ring-colour leg")
                return
            }
            XCTAssertEqual(ring, "accent",
                           "with accent ring + poster colour on, the tile's ring must read poster (or accent for grey art); got \(ring ?? "nil") on card \(card). Tile: \(first)")
        }
        note("87_readings", readings.joined(separator: " | "))
        throw XCTSkip("test87: no card showed ring=poster — \(readings.joined(separator: " | ")). All-accent readings mean grey art on 4 cards, or no tile at all (trailer extraction unavailable on this host)")
    }

    // MARK: - M4: Trailer Start Delay

    /// Walks Settings → Home Screen and finds the row by label, then returns what the tree says
    /// about it: the row node's label/value plus its descendants', joined. nil when no node carries
    /// the title yet.
    private func describeRow(_ app: XCUIApplication, titled title: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        var parts: [String] = []
        // The explainer column's copy ("Automatic waits until the rows stop moving…") contains the
        // word "Automatic" too; it must never stand in for the ROW's own value.
        let explainerCopy = "waits until the rows stop moving"
        func collect(_ node: XCUIElementSnapshot) {
            if !node.label.contains(explainerCopy) { parts.append(node.label) }
            if let value = node.value as? String, !value.contains(explainerCopy) { parts.append(value) }
            node.children.forEach(collect)
        }
        // Gate 4 (main session): the row's value ("Automatic ›") is a SIBLING of the title text,
        // not its child, so the row is every node on the title's line (same midY ± 30 pt, to its
        // right) — the explainer column sits to the LEFT of the list and is excluded by minX.
        var titleFrame: CGRect?
        func findTitle(_ node: XCUIElementSnapshot) {
            if titleFrame == nil, node.label.contains(title), !node.label.contains(explainerCopy),
               node.frame.width > 0 {
                titleFrame = node.frame
                return
            }
            node.children.forEach(findTitle)
        }
        findTitle(root)
        guard let row = titleFrame else { return nil }
        func onRowLine(_ node: XCUIElementSnapshot) {
            let f = node.frame
            if f.width > 0, f.height <= 120, abs(f.midY - row.midY) <= 30, f.minX >= row.minX - 10 {
                collect(node)
                return
            }
            node.children.forEach(onRowLine)
        }
        onRowLine(root)
        return parts.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// test88 (row). Inline trailers on, no `-trailer_start_delay` argument: Settings → Home Screen
    /// shows a "Trailer Start Delay" row whose value is "Automatic" (the default). The row is far
    /// down the pane, so the walk presses Down until it exists in the tree. With the row focused the
    /// explainer column must show the copy "Automatic waits until the rows stop moving…" (the
    /// `.homeTrailerStartDelay` description wiring); that check runs only when focus is detected on
    /// the row.
    func test88TrailerStartDelaySetting() throws {
        let app = launchToHome(extraArguments: ["-inline_trailers_enabled", "YES", "-home_upcoming_row_enabled", "NO"])
        guard openSettingsCategory(app, named: "Home Screen") else {
            XCTFail("test88: Settings › Home Screen pane did not open")
            return
        }
        pause(1.0)
        var foundRow: String?
        for _ in 0..<40 {
            if let found = describeRow(app, titled: "Trailer Start Delay") { foundRow = found; break }
            press(.down, gap: 0.6)
        }
        guard let description = foundRow else {
            shot("88_row_missing")
            XCTFail("test88: no 'Trailer Start Delay' row after 40 Down presses with Trailers on Focus enabled")
            return
        }
        note("88_row", description)
        XCTAssertTrue(description.contains("Automatic"),
                      "the Trailer Start Delay row must read Automatic by default (unless the fixture carries a stored trailer_start_delay). Row: \(description)")

        // Bring focus onto the row (it mounts a few rows before it is reached) for the explainer check.
        var focusedOnRow = false
        for _ in 0..<8 {
            if focusedNodes(app).contains(where: { $0.label.contains("Trailer Start Delay") }) { focusedOnRow = true; break }
            press(.down, gap: 0.6)
        }
        shot("88_row_focus")
        if focusedOnRow {
            pause(0.6)
            let explainer = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Automatic waits until the rows stop moving"))
                .firstMatch
            XCTAssertTrue(explainer.waitForExistence(timeout: 3),
                          "with the Trailer Start Delay row focused the explainer must show its description (\"Automatic waits until the rows stop moving…\")")
        } else {
            note("88_explainer", "focus on the Trailer Start Delay row was not detected (hasFocus unreliable) — explainer text not asserted")
        }
        XCTAssertTrue(app.state == .runningForeground, "app must survive the settings leg")
    }

    /// test88B (behaviour). `-trailer_start_delay 2`: the gate counts 2 s from FOCUS and never
    /// before the rows stop, so the first tile reads `gate=2`, `via=rest`, `gateStart ≥ 2.0`.
    func test88BFixedDelayGate() throws {
        let app = launchToHome(extraArguments: trailerArguments(location: "poster", heroPinned: false, startDelay: "2"))
        guard landOnFirstCard(app) != nil else {
            throw XCTSkip("test88B: no row card reported focus (debug_hero fitem=) within 8 Down presses — Home rows did not load")
        }
        guard let label = awaitTile(app, cards: 3, perCard: 18) else {
            throw XCTSkip("test88B: trailer extraction unavailable on this host — no debug_trailerTile on 3 consecutive cards within 18 s each")
        }
        note("88B_tile", label)
        let fields = TileFields(label)
        XCTAssertEqual(fields.gate, "2", "the gate must report the fixed 2 s delay. \(label)")
        XCTAssertEqual(fields.via, "rest", "the gate must start via=rest. \(label)")
        guard let start = fields.gateStart else {
            XCTFail("test88B: gateStart unreadable. \(label)")
            return
        }
        XCTAssertGreaterThanOrEqual(start, 1.995, "a fixed 2 s delay must not start before 2 s from focus — gateStart=\(start). \(label)")
        XCTAssertLessThanOrEqual(start, 5.0, "a fixed 2 s delay on settled rows should start close to 2 s — gateStart=\(start). \(label)")
        if let rest = fields.gateRest {
            XCTAssertGreaterThanOrEqual(start, rest, "the gate must never start before the rows stop — gateRest=\(rest) gateStart=\(start)")
        }
    }

    // MARK: - M5: the hero text never shows two titles

    /// test89 (critique #8). Pinned Nuvio hero, trailers off. After landing on a row card, walks
    /// Right across 8 cards at 0.9 s gaps. The oracle is `debug_heroText`: at least 6 swaps happened
    /// in the walk, and `maxLive=1` — the high-water mark of the info block's appear/disappear
    /// counter, which a regression back to a cross-dissolve raises to 2. The `hero_info` identifier
    /// count is only a weak smoke check (an identifier on a container can surface on several AX
    /// nodes), so it is compared with the single-block count taken at the start and fails only above
    /// twice that.
    func test89HeroTextNeverDoubles() throws {
        let app = launchToHome(extraArguments: [
            "-inline_trailers_enabled", "NO",
            "-hero_trailer_autoplay", "NO",
            "-hero_nuvio_style", "YES",
            "-home_upcoming_row_enabled", "NO",
        ])
        guard app.staticTexts["debug_heroText"].waitForExistence(timeout: 30) else {
            throw XCTSkip("test89: debug_heroText never appeared — no hero was presented (Show Hero off, or the catalogs did not load)")
        }
        guard landOnFirstCard(app) != nil else {
            throw XCTSkip("test89: no row card reported focus (debug_hero fitem=) within 8 Down presses — Home rows did not load")
        }
        pause(2.5) // the focus commit's own swap and the resolver settle
        func heroInfoCount() -> Int {
            app.descendants(matching: .any).matching(identifier: "hero_info").count
        }
        guard let start = probe(app, "debug_heroText"),
              let swaps0 = Self.number(start, "swaps").map({ Int($0) }),
              let maxLive0 = Self.number(start, "maxLive").map({ Int($0) }) else {
            XCTFail("test89: debug_heroText unreadable or missing swaps=/maxLive= — \(probe(app, "debug_heroText") ?? "absent")")
            return
        }
        let infoUnit = heroInfoCount()
        note("89_start", "\(start) hero_info=\(infoUnit)")
        shot("89_start")

        var maxInfoCount = infoUnit
        for step in 1...8 {
            press(.right, gap: 0.9)
            maxInfoCount = max(maxInfoCount, heroInfoCount())
            if step == 4 { shot("89_midwalk") }
        }
        pause(1.5)
        guard let end = probe(app, "debug_heroText"),
              let swaps1 = Self.number(end, "swaps").map({ Int($0) }),
              let maxLive1 = Self.number(end, "maxLive").map({ Int($0) }) else {
            XCTFail("test89: debug_heroText unreadable at the end of the walk — \(probe(app, "debug_heroText") ?? "absent")")
            return
        }
        note("89_end", "\(end) hero_info max=\(maxInfoCount) unit=\(infoUnit)")
        shot("89_end")
        XCTAssertGreaterThanOrEqual(swaps1 - swaps0, 6,
                                    "8 hero changes should swap the text at least 6 times — swaps \(swaps0) → \(swaps1). \(end)")
        XCTAssertEqual(maxLive1, 1,
                       "two hero info blocks were alive at once (maxLive=\(maxLive1); \(maxLive0) before the walk — a value already above 1 at the start points at startup, not the swaps). \(end)")
        if infoUnit >= 1 {
            XCTAssertLessThanOrEqual(maxInfoCount, infoUnit * 2,
                                     "hero_info nodes peaked at \(maxInfoCount) against a single-block count of \(infoUnit)")
        } else {
            note("89_smoke", "hero_info is not exposed as an AX node here (baseline count 0) — the weak identifier smoke check was skipped; maxLive is the oracle")
        }
        XCTAssertTrue(app.state == .runningForeground, "app must survive the hero text walk")
    }

    // MARK: - M5: the hero holds the folder across a push and pop

    private static let heroFoldSeedJson = """
    [{"id":"zzherofold-collection","title":"ZZHeroFold","pinToTop":true,"showAllTab":false,"folders":[{"id":"zzherofold-a","title":"ZZHeroFoldA","hideTitle":false,"heroBackdropUrl":"https://images.metahub.space/background/medium/tt0111161/img","sources":[{"provider":"addon","addonId":"com.linvo.cinemeta","type":"movie","catalogId":"top"}]}]}]
    """

    /// test90 (critique #8), seeded so it runs on the guest fixture. Focuses the seeded folder tile
    /// until the PRESENTED hero (`pitem=`) is the folder, opens the folder, waits 2 s (longer than
    /// the focus model's 0.3 s revert grace, so a cover that lets the hero revert would show it),
    /// presses Menu and polls `pitem=` for 1.6 s: it must never leave the folder identity. Teardown
    /// re-seeds `[]`.
    func test90HeroHoldsFolderOnReturn() throws {
        let app = launchToHomeWithSeededCollections(Self.heroFoldSeedJson, extraArguments: [
            "-hero_nuvio_style", "YES",
            "-inline_trailers_enabled", "NO",
            "-hero_trailer_autoplay", "NO",
            "-home_upcoming_row_enabled", "NO",
            "-debug.homeHeroProbe", "YES",
        ])
        defer {
            // The import REPLACED this profile's collections; put back the fixture's (none).
            let restored = launchToHomeWithSeededCollections("[]")
            XCTAssertTrue(restored.state == .runningForeground, "the re-seed launch must reach Home")
        }
        pause(1.5)

        // 1. Walk Down to the seeded folder tile (it reports focus through fitem=nuvio-folder://…).
        var folderFocused = false
        var lastItem = ""
        var stalled = 0
        for _ in 1...45 {
            press(.down, gap: 0.5)
            let item = focusedItemId(app) ?? ""
            if item.contains("nuvio-folder://") { folderFocused = true; break }
            if item == lastItem { stalled += 1 } else { stalled = 0; lastItem = item }
            if stalled >= 10, !item.isEmpty { break }
        }
        guard folderFocused else {
            let rowShown = app.staticTexts["ZZHeroFold"].exists
            throw XCTSkip(rowShown
                ? "test90: the seeded collection row is on Home but its folder tile never reported focus through debug_hero fitem="
                : "test90: seeded collection not on Home — seed refused (signed-in cloud account?) or not imported; see the [CollectionsSeed] log line")
        }

        // 2. The PRESENTED hero must be the folder before the push (the resolver pays a 0.2 s commit
        // and a backdrop fetch with a 1.5 s deadline).
        var presentedFolder: String?
        let presentDeadline = Date().addingTimeInterval(10)
        while Date() < presentDeadline {
            if let pitem = presentedItem(app), pitem.contains("nuvio-folder://") {
                presentedFolder = pitem
                break
            }
            pause(0.25)
        }
        guard let folderIdentity = presentedFolder else {
            let stuckOn = presentedItem(app) ?? "absent"
            throw XCTSkip("test90: the folder hero never presented (pitem= stayed \(stuckOn)) — the folder backdrop fetch is unavailable on this host")
        }
        note("90_before_push", "pitem=\(folderIdentity)")
        shot("90_folder_hero")

        // 3. Open the folder page and sit on it longer than the revert grace.
        remote.press(.select)
        guard app.descendants(matching: .any)["folder_header"].waitForExistence(timeout: 20) else {
            XCTFail("test90: Select on the folder tile did not push the folder page (no folder_header within 20 s)")
            return
        }
        pause(2.0)
        shot("90_covered")
        // Soft check while covered: readable only if Home stays in the tree under the push.
        if let covered = presentedItem(app) {
            XCTAssertEqual(covered, folderIdentity, "the presented hero changed while Home was covered by the folder page")
        }

        // 4. Pop and watch the presented hero for 1.6 s: the carousel title must never show.
        remote.press(.menu)
        let popAt = Date()
        var readable = 0
        var seen: [String] = []
        while Date().timeIntervalSince(popAt) < 1.6 {
            if let pitem = presentedItem(app) {
                readable += 1
                seen.append(pitem)
                XCTAssertEqual(pitem, folderIdentity,
                               "after popping the folder page the hero showed \(pitem) instead of the folder (\(folderIdentity)) — t+\(String(format: "%.2f", Date().timeIntervalSince(popAt))) s")
            }
            pause(0.2)
        }
        note("90_after_pop", "readable=\(readable) seen=\(seen)")
        shot("90_after_pop")
        XCTAssertGreaterThanOrEqual(readable, 3, "debug_hero was readable only \(readable) times in the 1.6 s after the pop — Home did not come back, or the probe is missing")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the folder push and pop")
    }

    // MARK: - B2: trailers survive a background cycle

    /// What `debug_trailerListener` has shown so far: the highest `rebuilds=` and every distinct
    /// `recent=` string (the listener log moves quickly, so a single read can miss an event).
    private struct ListenerTrace {
        var rebuilds = 0
        var recents: [String] = []
        var last = ""

        mutating func observe(_ line: String?) {
            guard let line else { return }
            last = line
            if let rebuilds = TrailerMotionUITests.number(line, "rebuilds") { self.rebuilds = max(self.rebuilds, Int(rebuilds)) }
            if let range = line.range(of: "recent=") {
                let recent = String(line[range.upperBound...])
                if recents.last != recent { recents.append(recent) }
            }
        }

        var union: String { recents.joined(separator: " || ") }

        /// Some single `recent` string holds the rebuild and, chronologically after it, a `ready`.
        var sawRebuildThenReady: Bool {
            recents.contains { recent in
                guard let range = recent.range(of: "rebuild reason=active") else { return false }
                return recent[range.upperBound...].contains("ready port=")
            }
        }
    }

    /// test91 (critique #9). `-debug.trailerListenerFault silent -debug.trailerListenerLifecycleCycleAfterS 8`:
    /// 8 s after the loopback listener first reports ready, the server runs a background → active
    /// cycle in-process after silently killing the live `NWListener` (no `press(.home)` /
    /// `activate()`). Expected: a first trailer plays (the listener is up); then `health … alive=0` →
    /// `dead … reason=active` → `rebuild reason=active prefer=8230` → `ready port=8230`
    /// (`rebuilds ≥ 1`, read from `rebuilds=` and the accumulated `recent=`, never just `last`);
    /// and a NEW card's trailer plays afterwards. The longest leg: the first trailer needs a fresh
    /// extraction, the cycle fires 8 s after the listener is up, and the new title needs another.
    func test91TrailersSurviveBackground() throws {
        let app = launchToHome(extraArguments: trailerArguments(
            location: "poster", heroPinned: false, startDelay: "1",
            extra: ["-debug.trailerListenerFault", "silent", "-debug.trailerListenerLifecycleCycleAfterS", "8"]))
        var trace = ListenerTrace()
        func tick() { trace.observe(probe(app, "debug_trailerListener")) }

        guard var current = landOnFirstCard(app) else {
            throw XCTSkip("test91: no row card reported focus (debug_hero fitem=) within 8 Down presses — Home rows did not load")
        }

        // Phase 1: a first trailer plays, so the loopback listener is up and the cycle timer runs.
        var playedKey: String?
        for card in 0..<3 {
            if let line = waitForPlay(app, host: "card", itemId: current, timeout: 25, onTick: tick) {
                playedKey = Self.token(line, "key")
                break
            }
            guard card < 2, let next = advance(app, from: current) else { break }
            current = next
        }
        guard let firstKey = playedKey else {
            throw XCTSkip("test91: trailer extraction unavailable on this host — no `event=play host=card` on 3 consecutive cards, so the listener never started. Listener: \(trace.last)")
        }
        note("91_first_play", "key=\(firstKey)")
        shot("91_first_trailer")

        // Phase 2: the in-process cycle kills the listener silently, then `.active` verifies and rebuilds.
        let rebuildDeadline = Date().addingTimeInterval(45)
        while Date() < rebuildDeadline, !(trace.rebuilds >= 1 && trace.sawRebuildThenReady) {
            tick()
            pause(0.3)
        }
        for _ in 0..<5 { tick(); pause(0.3) } // let `start` / `ready` land in the trace
        note("91_listener_trace", "rebuilds=\(trace.rebuilds) union=\(trace.union)")
        XCTAssertGreaterThanOrEqual(trace.rebuilds, 1,
                                    "the in-process background cycle never produced a listener rebuild (rebuilds=\(trace.rebuilds)). Trace: \(trace.union)")
        XCTAssertTrue(trace.union.contains("rebuild reason=active"),
                      "the rebuild must be attributed to the .active verification. Trace: \(trace.union)")
        XCTAssertTrue(trace.union.contains("alive=0"),
                      "the .active health ping must have found the silently killed listener dead (health … alive=0). Trace: \(trace.union)")
        XCTAssertTrue(trace.sawRebuildThenReady,
                      "no `ready port=` followed the rebuild in any single recent= window. Trace: \(trace.union)")
        XCTAssertFalse(trace.union.contains("exhausted"), "the rebuild exhausted every port. Trace: \(trace.union)")
        XCTAssertFalse(trace.union.contains("start-timeout"), "the rebuild hit its start deadline. Trace: \(trace.union)")

        // Phase 3: a NEW title plays on the rebuilt listener.
        var playedNew = false
        var previous = current
        for attempt in 0..<2 {
            guard let next = advance(app, from: previous) else { break }
            previous = next
            if let line = waitForPlay(app, host: "card", itemId: next, timeout: 20, onTick: tick),
               let key = Self.token(line, "key"), key != firstKey {
                note("91_new_play", "attempt=\(attempt) key=\(key)")
                shot("91_new_trailer")
                playedNew = true
                break
            }
        }
        XCTAssertTrue(playedNew,
                      "no new title played after the listener rebuild (two cards tried, 20 s each). Listener: \(trace.last). Morph: \(probe(app, "debug_trailerMorph") ?? "absent")")
        XCTAssertTrue(app.state == .runningForeground, "app must survive the background-cycle leg")
    }

    // MARK: - Settings navigation (trimmed copy of HeroFolderSwapTests', tabs mode)

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

    /// The fixed root order, mirroring `SettingsCategory.allCases` (SettingsView.swift).
    private static let settingsRootOrder: [(title: String, raw: String)] = [
        ("Account & Profiles", "accountProfiles"), ("Services", "services"), ("Appearance", "appearance"),
        ("Home Screen", "homeScreen"), ("Detail Page", "detailPage"), ("Player", "player"),
        ("Sources", "sources"), ("Subtitles & Audio", "subtitlesAudio"), ("About", "about"),
        ("Developer", "developer"),
    ]

    private func settingsRootPresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_root_list"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_category_'"))
                .firstMatch.exists
    }

    private func settingsPanePresent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings_pane_title"].exists
            || app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings_pane_'"))
                .firstMatch.exists
    }

    /// Identifier + label of every element that reports focus, from ONE snapshot.
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
}
