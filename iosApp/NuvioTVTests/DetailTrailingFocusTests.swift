import XCTest
@testable import NuvioTV

/// BUG-244: `DetailTrailingFocus`, the pure rule that gives every content section after the last
/// focus stop one focus stop of its own (`DetailTailFocusStop`), so a Down walk reaches the end of
/// the page in every layout. The sections come from the real presets
/// (`DetailSectionOrder.sections`); `hasOwnStop` mirrors `DetailView.sectionHasOwnFocusStop`.
@MainActor
final class DetailTrailingFocusTests: XCTestCase {
    private struct Config {
        var layout: DetailLayout
        var series: Bool
        var castHasIds = false
        var companiesHaveIds = false
        var states: [DetailSection: DetailSectionState] = [:]
    }

    private static let contentSections: [DetailSection] = DetailSection.allCases.filter { $0 != .hero }

    /// `DetailView.sectionHasOwnFocusStop`.
    private func ownStop(_ config: Config) -> (DetailSection) -> Bool {
        { section in
            switch section {
            case .parentalGuide: return false
            case .castAndCrew: return config.castHasIds
            case .companies: return config.companiesHaveIds
            default: return true
            }
        }
    }

    private func rendered(_ config: Config) -> (sections: [DetailSection], contentless: Set<DetailSection>) {
        let availability = DetailSectionAvailability(states: config.states)
        let sections = DetailSectionOrder.sections(layout: config.layout, isSeries: config.series,
                                                   availability: availability)
        let contentless = Set(sections.filter { availability.state($0) == .pending })
        return (sections, contentless)
    }

    private func tail(_ config: Config) -> Set<DetailSection> {
        let (sections, contentless) = rendered(config)
        return DetailTrailingFocus.tailStops(sections: sections, contentless: contentless,
                                             hasOwnStop: ownStop(config))
    }

    private func ready(_ sections: [DetailSection]) -> [DetailSection: DetailSectionState] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0, DetailSectionState.ready) })
    }

    // MARK: Exhaustive properties

    /// Calls `body` for every layout, type and per-section state assignment from `choices`.
    private func forEachConfig(choices: [DetailSectionState], castIds: [Bool], companyIds: [Bool],
                               _ body: (Config) -> Void) {
        let count = Self.contentSections.count
        var combos = 1
        for _ in 0..<count { combos *= choices.count }
        for layout in [DetailLayout.cinematic, .classic, .appleStyle] {
            for series in [true, false] {
                for cast in castIds {
                    for companies in companyIds {
                        for code in 0..<combos {
                            var config = Config(layout: layout, series: series, castHasIds: cast,
                                                companiesHaveIds: companies)
                            var rest = code
                            for section in Self.contentSections {
                                config.states[section] = choices[rest % choices.count]
                                rest /= choices.count
                            }
                            // Availability hides About in Classic and Episodes on a film.
                            if layout == .classic { config.states[.about] = .hidden }
                            if !series { config.states[.episodes] = .hidden }
                            body(config)
                        }
                    }
                }
            }
        }
    }

    /// Every rendered content section has a focus stop (its own or a tail stop) at its index or below.
    func testEveryContentSectionHasAStopAtOrBelowIt() {
        var checked = 0
        forEachConfig(choices: [.hidden, .ready, .pending], castIds: [false, true], companyIds: [false, true]) { config in
            let (sections, contentless) = rendered(config)
            let stops = DetailTrailingFocus.tailStops(sections: sections, contentless: contentless,
                                                      hasOwnStop: ownStop(config))
            let content = sections.filter { $0 != .hero && !contentless.contains($0) }
            for (index, section) in content.enumerated() {
                let hasStop = content[index...].contains { stops.contains($0) || ownStop(config)($0) }
                if !hasStop {
                    XCTFail("\(config.layout) series=\(config.series) \(content): \(section) has no stop at or below it")
                    return
                }
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100_000)
    }

    /// The tail is empty exactly when the last content section has a stop of its own.
    func testTailIsEmptyIffTheLastContentSectionHasItsOwnStop() {
        forEachConfig(choices: [.hidden, .ready, .pending], castIds: [false, true], companyIds: [false, true]) { config in
            let (sections, contentless) = rendered(config)
            let stops = DetailTrailingFocus.tailStops(sections: sections, contentless: contentless,
                                                      hasOwnStop: ownStop(config))
            let content = sections.filter { $0 != .hero && !contentless.contains($0) }
            let lastHasStop = content.last.map(ownStop(config)) ?? true
            if stops.isEmpty != lastHasStop {
                XCTFail("\(config.layout) series=\(config.series) \(content): tail \(stops) but lastHasStop=\(lastHasStop)")
            }
            // A tail section never has a stop of its own, and is always rendered content.
            for section in stops {
                XCTAssertFalse(ownStop(config)(section), "\(section) in the tail has its own stop")
                XCTAssertTrue(content.contains(section), "\(section) in the tail is not rendered content")
            }
        }
    }

    /// Comments is a stop of its own (built eagerly): nothing above it is ever in the tail.
    func testNothingAboveReadyCommentsIsInTheTail() {
        forEachConfig(choices: [.hidden, .ready], castIds: [false, true], companyIds: [false, true]) { config in
            guard config.states[.comments] == .ready else { return }
            let stops = tail(config)
            let (sections, _) = rendered(config)
            guard let commentsIndex = sections.firstIndex(of: .comments) else {
                return XCTFail("ready comments not rendered: \(config)")
            }
            for section in sections[..<commentsIndex] where stops.contains(section) {
                XCTFail("\(config.layout) series=\(config.series): \(section) is in the tail above ready Comments")
            }
            XCTAssertFalse(stops.contains(.comments))
        }
    }

    /// I1: a page whose tail is empty is today's page. Pinned over the real presets: with every
    /// section ready, the last section is About (Cinematic, Apple-style) or Comments (Classic).
    func testFullPagesNeverNeedATail() {
        for layout in [DetailLayout.cinematic, .classic, .appleStyle] {
            for series in [true, false] {
                for ids in [false, true] {
                    var config = Config(layout: layout, series: series, castHasIds: ids, companiesHaveIds: ids)
                    config.states = ready(Self.contentSections)
                    if layout == .classic { config.states[.about] = .hidden }
                    if !series { config.states[.episodes] = .hidden }
                    XCTAssertEqual(tail(config), [], "\(layout) series=\(series) ids=\(ids)")
                }
            }
        }
    }

    // MARK: Named configurations (device passes 3 and 7, spec §1.4)

    private func apple(series: Bool = true, ready sections: [DetailSection], castIds: Bool = false,
                       companyIds: Bool = false) -> Config {
        Config(layout: .appleStyle, series: series, castHasIds: castIds, companiesHaveIds: companyIds,
               states: ready(sections))
    }

    /// Pass 3 A1: Apple-style, TMDB off, About off, no comments: Cast (names) and Parental Guide.
    func testPass3A1() {
        let config = apple(ready: [.episodes, .trailers, .castAndCrew, .parentalGuide])
        XCTAssertEqual(tail(config), [.castAndCrew, .parentalGuide])
    }

    /// Pass 3 A2: the same with About on: About is the stop below them.
    func testPass3A2() {
        let config = apple(ready: [.episodes, .trailers, .castAndCrew, .parentalGuide, .about])
        XCTAssertEqual(tail(config), [])
    }

    /// Pass 3 A3: TMDB on (Cast has ids), About and Studio Logos off: Parental Guide alone.
    func testPass3A3() {
        let config = apple(ready: [.episodes, .trailers, .bonus, .moreLikeThis, .castAndCrew, .parentalGuide],
                           castIds: true)
        XCTAssertEqual(tail(config), [.parentalGuide])
    }

    /// Pass 7, About off (the tester's case) and on: Comments is the stop below Parental Guide.
    func testPass7() {
        let base: [DetailSection] = [.episodes, .trailers, .bonus, .moreLikeThis, .castAndCrew, .companies,
                                     .parentalGuide, .comments]
        XCTAssertEqual(tail(apple(ready: base, castIds: true, companyIds: true)), [])
        XCTAssertEqual(tail(apple(ready: base + [.about], castIds: true, companyIds: true)), [])
    }

    /// Cinematic defaults (TMDB off: no logos, no collection, names-only Cast), everything else on.
    func testCinematicDefaults() {
        let config = Config(layout: .cinematic, series: true,
                            states: ready([.parentalGuide, .episodes, .castAndCrew, .trailers, .moreLikeThis,
                                           .comments, .about]))
        XCTAssertEqual(tail(config), [])
    }

    /// C-2 and K-2: a film with only Parental Guide and names-only Cast: Down from the hero or the
    /// action row reaches both.
    func testCinematicAndClassicFilmWithOnlyTheTail() {
        for layout in [DetailLayout.cinematic, .classic] {
            let config = Config(layout: layout, series: false, states: ready([.parentalGuide, .castAndCrew]))
            XCTAssertEqual(tail(config), [.parentalGuide, .castAndCrew], "\(layout)")
        }
    }

    /// K-1: Classic series, names-only Cast last.
    func testClassicSeriesNamesOnlyCast() {
        let config = Config(layout: .classic, series: true, states: ready([.episodes, .castAndCrew]))
        XCTAssertEqual(tail(config), [.castAndCrew])
    }

    /// D-C: Studio Logos wired to the rule: chips with no TMDB id, last, are in the tail.
    func testCompaniesWithoutIdsLastAreInTheTail() {
        let config = apple(series: false, ready: [.trailers, .companies], companyIds: false)
        XCTAssertEqual(tail(config), [.companies])
        XCTAssertEqual(tail(apple(series: false, ready: [.trailers, .companies], companyIds: true)), [])
    }

    /// A pending slot (Apple-style keeps it) carries no content and is never a stop: it is skipped,
    /// so the rows above it still count as trailing.
    func testPendingSlotAfterTheTailIsIgnored() {
        var config = apple(series: false, ready: [.castAndCrew, .parentalGuide])
        config.states[.about] = .pending
        let (sections, contentless) = rendered(config)
        XCTAssertEqual(sections, [.hero, .castAndCrew, .parentalGuide, .about])
        XCTAssertEqual(contentless, [.about])
        XCTAssertEqual(tail(config), [.castAndCrew, .parentalGuide])
    }

    /// A held slot is passed in as contentless too.
    func testHeldSlotIsContentless() {
        let sections: [DetailSection] = [.hero, .castAndCrew, .parentalGuide, .moreLikeThis]
        let stops = DetailTrailingFocus.tailStops(sections: sections, contentless: [.moreLikeThis],
                                                  hasOwnStop: ownStop(Config(layout: .appleStyle, series: false)))
        XCTAssertEqual(stops, [.castAndCrew, .parentalGuide])
    }

    // MARK: Hold

    func testAStopThatHoldsFocusStaysUntilFocusLeaves() {
        let inert: (DetailSection) -> Bool = { _ in false }
        func resolve(_ tail: Set<DetailSection>, _ previous: Set<DetailSection>, _ focused: DetailSection?)
            -> DetailTrailingFocus.Resolution {
            DetailTrailingFocus.resolve(tail: tail, previous: previous, focused: focused, hasOwnTargets: inert)
        }
        XCTAssertEqual(resolve([], [.parentalGuide], .parentalGuide).stops, [.parentalGuide])
        XCTAssertEqual(resolve([], [.parentalGuide], .trailers).stops, [])
        XCTAssertEqual(resolve([], [.parentalGuide], nil).stops, [])
        // Only a previous stop is held; a focused section that was never a stop is not invented.
        XCTAssertEqual(resolve([], [], .parentalGuide).stops, [])
        XCTAssertEqual(resolve([.castAndCrew], [.parentalGuide], .parentalGuide).stops, [.castAndCrew, .parentalGuide])
        XCTAssertNil(resolve([], [.parentalGuide], .parentalGuide).handoff)
    }

    /// Round 1 P2 (finding 1): Cast & Crew gains TMDB ids while its names-only stop holds focus.
    func testIdsArrivingUnderAFocusedStopHandFocusToALinkThenDropTheStop() {
        let own: (DetailSection) -> Bool = { $0 == .castAndCrew }
        let prev: Set<DetailSection> = [.castAndCrew, .parentalGuide]
        // Stop focused, ids arrive: the stop is kept for this pass and the hand-off is named, so focus
        // moves to a link instead of falling to nil.
        let handed = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: prev, focused: .castAndCrew,
                                                 hasOwnTargets: own, linkFocused: { _ in false })
        XCTAssertEqual(handed.stops, [.castAndCrew, .parentalGuide])
        XCTAssertEqual(handed.handoff, .castAndCrew)
        // Focus is now on a person link: the wrapper is gone, no further hand-off.
        let done = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: handed.stops, focused: .castAndCrew,
                                               hasOwnTargets: own, linkFocused: { $0 == .castAndCrew })
        XCTAssertEqual(done.stops, [.parentalGuide])
        XCTAssertNil(done.handoff)
        // Stop not focused, ids arrive: wrapper gone at once, no focus change.
        for focused in [DetailSection.parentalGuide, nil] {
            let quiet = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: prev, focused: focused,
                                                    hasOwnTargets: own)
            XCTAssertEqual(quiet.stops, [.parentalGuide])
            XCTAssertNil(quiet.handoff)
        }
    }

    func testBoxHandsOffUntilALinkHoldsFocus() {
        let box = DetailTailStopBox()
        var castIds = false
        var linkFocused = false
        let own: (DetailSection) -> Bool = { $0 == .castAndCrew ? castIds : $0 != .parentalGuide }
        let sections: [DetailSection] = [.hero, .castAndCrew, .parentalGuide]
        func pass() { _ = box.resolve(sections: sections, contentless: [], focused: .castAndCrew, hasOwnStop: own,
                                       linkFocused: { _ in linkFocused }) }
        pass()
        XCTAssertEqual(box.stops, [.castAndCrew, .parentalGuide])
        castIds = true
        pass()
        XCTAssertEqual(box.stops, [.castAndCrew, .parentalGuide], "the stop is kept while it still holds focus")
        XCTAssertEqual(box.handoff, .castAndCrew)
        linkFocused = true
        pass()
        XCTAssertEqual(box.stops, [.parentalGuide])
        XCTAssertNil(box.handoff)
    }

    /// Review finding A: the hold lasts one pass. The pass after a reported hand-off drops the stop
    /// whatever happened to focus (the link never took it, or the link was inserted in the same update).
    func testHeldStopIsReleasedOnThePassAfterTheHandoff() {
        let box = DetailTailStopBox()
        var castIds = false
        let own: (DetailSection) -> Bool = { $0 == .castAndCrew ? castIds : $0 != .parentalGuide }
        let sections: [DetailSection] = [.hero, .castAndCrew, .parentalGuide]
        func pass() { _ = box.resolve(sections: sections, contentless: [], focused: .castAndCrew, hasOwnStop: own,
                                       linkFocused: { _ in false }) }
        pass()
        castIds = true
        pass()
        XCTAssertEqual(box.handoff, .castAndCrew)
        XCTAssertEqual(box.stops, [.castAndCrew, .parentalGuide], "held once")
        XCTAssertEqual(box.takeAction()?.action, .assign)
        pass()   // focus never reached a link
        XCTAssertNil(box.handoff, "no retry")
        XCTAssertEqual(box.stops, [.parentalGuide], "then dropped")
        pass()
        XCTAssertEqual(box.stops, [.parentalGuide])
        XCTAssertNil(box.handoff)
        // Pure form: the previous pass's hand-off for the focused section releases it.
        let held = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: [.castAndCrew, .parentalGuide],
                                               focused: .castAndCrew, hasOwnTargets: own,
                                               previousHandoff: .castAndCrew)
        XCTAssertEqual(held.stops, [.parentalGuide])
        XCTAssertNil(held.handoff)
        // A hand-off reported for another section does not release this one.
        let other = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: [.castAndCrew, .parentalGuide],
                                                focused: .castAndCrew, hasOwnTargets: own,
                                                previousHandoff: .companies)
        XCTAssertEqual(other.handoff, .castAndCrew)
    }

    /// Review finding A: the hand-off targets the first realized card with a link.
    func testHandoffTargetIsTheFirstRealizedIdCard() {
        let cards: [(key: String, hasLink: Bool)] = (0..<12).map { (key: "c\($0)", hasLink: $0 >= 10) }
        // The first 10 have no id and the 11th has one: realized -> it is the target.
        XCTAssertEqual(DetailTrailingFocus.handoffTarget(cards: cards, realized: ["c0", "c9", "c10", "c11"]), "c10")
        // An id card that is not realized is skipped for a later realized one.
        XCTAssertEqual(DetailTrailingFocus.handoffTarget(cards: cards, realized: ["c11"]), "c11")
        // No on-screen id card: nil (the stop is dropped anyway).
        XCTAssertNil(DetailTrailingFocus.handoffTarget(cards: cards, realized: Set((0..<10).map { "c\($0)" })))
        XCTAssertNil(DetailTrailingFocus.handoffTarget(cards: [], realized: ["c0"]))
    }

    /// Review round 2 (finding 1): no id card is realized -> the stop is held with a SCROLL action
    /// (focus stays in the row), bounded by the attempts; a realized one assigns; leaving ends the hold.
    func testUnrealizedTargetHoldsTheStopWithAScrollActionUntilTheAttemptsRunOut() {
        let own: (DetailSection) -> Bool = { $0 == .castAndCrew }
        let prev: Set<DetailSection> = [.castAndCrew, .parentalGuide]
        func resolve(attempts: Int, realized: Bool, focused: DetailSection? = .castAndCrew,
                     linkFocused: Bool = false) -> DetailTrailingFocus.Resolution {
            DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: prev, focused: focused, hasOwnTargets: own,
                                        linkFocused: { _ in linkFocused }, targetRealized: { _ in realized },
                                        scrollAttempts: attempts)
        }
        for attempts in 0...DetailTrailingFocus.maxScrollAttempts {
            let held = resolve(attempts: attempts, realized: false)
            XCTAssertEqual(held.stops, [.castAndCrew, .parentalGuide], "attempt \(attempts): the stop is held")
            XCTAssertEqual(held.handoff, .castAndCrew)
            XCTAssertEqual(held.action, .scroll)
        }
        // The last scroll was checked too and the card never appeared: dropped, as before.
        let spent = resolve(attempts: DetailTrailingFocus.maxScrollAttempts + 1, realized: false)
        XCTAssertEqual(spent.stops, [.parentalGuide])
        XCTAssertNil(spent.handoff)
        XCTAssertNil(spent.action)
        // The card is built: assign, whatever the attempts so far.
        let assign = resolve(attempts: 2, realized: true)
        XCTAssertEqual(assign.action, .assign)
        XCTAssertEqual(assign.stops, [.castAndCrew, .parentalGuide])
        // The user left the row, or focus is already on a link: dropped at once, no action.
        for quiet in [resolve(attempts: 0, realized: false, focused: .parentalGuide),
                      resolve(attempts: 0, realized: false, focused: nil),
                      resolve(attempts: 0, realized: false, linkFocused: true)] {
            XCTAssertEqual(quiet.stops, [.parentalGuide])
            XCTAssertNil(quiet.action)
        }
        // The section lost its targets again (meta changed): back to the plain held stop, no action.
        let lost = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: prev, focused: .castAndCrew,
                                               hasOwnTargets: { _ in false }, targetRealized: { _ in false })
        XCTAssertEqual(lost.stops, [.castAndCrew, .parentalGuide])
        XCTAssertNil(lost.action)
    }

    /// The box counts a scroll attempt only when its action is taken (once per pass), resets when the
    /// hold ends, never lets the hold stick, and still drops the stop one pass after an assign.
    func testBoxBoundsTheScrollHoldAndStillReleasesAfterAnAssign() {
        var box = DetailTailStopBox()
        var castIds = false
        var realized = false
        let own: (DetailSection) -> Bool = { $0 == .castAndCrew ? castIds : $0 != .parentalGuide }
        let sections: [DetailSection] = [.hero, .castAndCrew, .parentalGuide]
        func pass(focused: DetailSection? = .castAndCrew) {
            _ = box.resolve(sections: sections, contentless: [], focused: focused, hasOwnStop: own,
                            linkFocused: { _ in false }, targetRealized: { _ in realized })
        }
        pass()
        castIds = true
        // Unrelated body passes do not use the attempts up.
        for _ in 0..<10 { pass() }
        XCTAssertEqual(box.stops, [.castAndCrew, .parentalGuide])
        XCTAssertEqual(box.scrollAttempts, 0)
        // Each taken scroll action is one attempt; taking it twice in one pass is a no-op.
        for attempt in 0..<DetailTrailingFocus.maxScrollAttempts {
            pass()
            XCTAssertEqual(box.action, .scroll)
            let taken = box.takeAction()
            XCTAssertEqual(taken?.action, .scroll)
            XCTAssertEqual(taken?.attempt, attempt)
            XCTAssertNil(box.takeAction(), "an action runs once per pass")
        }
        // Every issued scroll gets one check: the pass after the 4th scroll still holds (a wait that
        // scrolls nothing), and only the check after that drops the stop.
        pass()
        XCTAssertEqual(box.action, .scroll)
        let wait = box.takeAction()
        XCTAssertEqual(wait?.attempt, DetailTrailingFocus.maxScrollAttempts)
        XCTAssertFalse(DetailTrailingFocus.issuesScroll(attempt: wait?.attempt ?? 0), "no scroll right before the drop")
        pass()
        XCTAssertNil(box.action, "the card never appeared: the hold is over")
        XCTAssertEqual(box.stops, [.parentalGuide], "and the stop is dropped, never stuck")
        XCTAssertEqual(box.scrollAttempts, 0, "reset for the next hold")
        // A fresh hold that finds the card built assigns, and releases one pass later.
        box = DetailTailStopBox()
        castIds = false
        pass()
        castIds = true
        realized = true
        pass()
        XCTAssertEqual(box.action, .assign)
        XCTAssertEqual(box.takeAction()?.action, .assign)
        pass()
        XCTAssertNil(box.action, "no retry after an assign")
        XCTAssertEqual(box.stops, [.parentalGuide])
    }

    /// An assign nobody took (an unrelated body pass resolved it) is not the previous hand-off: the
    /// next pass resolves it again and the stop stays held; once taken, the next pass drops it.
    func testUntakenAssignSurvivesTheNextPassAndTakenOneDrops() {
        let box = DetailTailStopBox()
        var castIds = false
        let own: (DetailSection) -> Bool = { $0 == .castAndCrew ? castIds : $0 != .parentalGuide }
        let sections: [DetailSection] = [.hero, .castAndCrew, .parentalGuide]
        func pass() { _ = box.resolve(sections: sections, contentless: [], focused: .castAndCrew, hasOwnStop: own,
                                       linkFocused: { _ in false }, targetRealized: { _ in true }) }
        pass()
        castIds = true
        pass()
        XCTAssertEqual(box.action, .assign)
        pass()   // not taken
        XCTAssertEqual(box.action, .assign, "still an assign")
        XCTAssertEqual(box.stops, [.castAndCrew, .parentalGuide], "stop still held")
        pass()
        XCTAssertEqual(box.takeAction()?.action, .assign)
        pass()
        XCTAssertNil(box.action)
        XCTAssertEqual(box.stops, [.parentalGuide], "dropped one pass after taken")
    }

    func testScrollOffsetIsAColumnBeforeTheCardAndSweepsOnLaterAttempts() {
        XCTAssertEqual(DetailTrailingFocus.scrollOffset(index: 10, pitch: 100, attempt: 0), 900)
        XCTAssertEqual(DetailTrailingFocus.scrollOffset(index: 10, pitch: 100, attempt: 1), 950)
        XCTAssertEqual(DetailTrailingFocus.scrollOffset(index: 10, pitch: 100, attempt: 3), 1050)
        XCTAssertEqual(DetailTrailingFocus.scrollOffset(index: 0, pitch: 100, attempt: 0), 0, "never negative")
        XCTAssertEqual(DetailTrailingFocus.scrollOffset(index: 1, pitch: 100, attempt: -2), 0)
        let cards: [(key: String, hasLink: Bool)] = (0..<12).map { (key: "c\($0)", hasLink: $0 >= 10) }
        XCTAssertEqual(DetailTrailingFocus.firstLinkIndex(cards: cards), 10)
        XCTAssertNil(DetailTrailingFocus.firstLinkIndex(cards: cards.map { (key: $0.key, hasLink: false) }))
        XCTAssertNil(DetailTrailingFocus.firstLinkIndex(cards: []))
    }

    /// Review round 2 (finding 2): the stop's VoiceOver text carries each name AND the line the card shows.
    func testCastStopLabelCarriesNamesAndRoles() {
        typealias P = (name: String, subtitle: String?)
        func label(_ people: [P]) -> String { DetailTrailingFocus.castStopPeopleLabel(people) }
        XCTAssertEqual(label([("Ann", nil), ("Bo", nil)]), "Ann, Bo", "names only")
        XCTAssertEqual(label([("Ann", "Mark"), ("Bo", "Helly")]), "Ann, Mark, Bo, Helly", "names with roles")
        XCTAssertEqual(label([("Ann", "Mark"), ("Bo", nil), ("Cy", "Director")]), "Ann, Mark, Bo, Cy, Director", "mixed")
        XCTAssertEqual(label([("Ann", ""), ("Bo", "Writer")]), "Ann, Bo, Writer", "an empty subtitle is skipped")
        XCTAssertEqual(label([]), "")
    }

    // MARK: Data-driven classification (finding 2)

    private typealias Facts = DetailTrailingFocus.Facts

    /// Present but empty sections are contentless, never "always focusable".
    func testPresentButEmptySectionsAreContentless() {
        for section in [DetailSection.episodes, .trailers, .bonus, .moreLikeThis, .collection, .comments,
                        .castAndCrew, .companies, .parentalGuide] {
            XCTAssertEqual(DetailTrailingFocus.kind(of: section, facts: Facts()), .contentless, "\(section)")
        }
        XCTAssertEqual(DetailTrailingFocus.kind(of: .hero, facts: Facts()), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .about, facts: Facts()), .focusable)
    }

    func testFilledSectionsAreFocusableExceptTheInertOnes() {
        var f = Facts(numberedEpisodes: true, trailers: true, bonus: true, moreLikeThis: true, collection: true,
                      comments: true, castItems: true, castWithIds: false, logos: true, logosWithIds: false,
                      warnings: true)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .episodes, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .trailers, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .bonus, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .moreLikeThis, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .collection, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .comments, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .castAndCrew, facts: f), .inert)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .companies, facts: f), .inert)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .parentalGuide, facts: f), .inert)
        f.castWithIds = true
        f.logosWithIds = true
        XCTAssertEqual(DetailTrailingFocus.kind(of: .castAndCrew, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .companies, facts: f), .focusable)
    }

    /// The finding's configuration: Classic or Cinematic series, Parental Guide above an Episodes
    /// section with no numbered videos, nothing focusable after: Parental Guide is a stop.
    func testParentalGuideAboveAnEmptyEpisodesSectionIsAStop() {
        for layout in [DetailLayout.cinematic, .classic] {
            let sections = DetailSectionOrder.sections(
                layout: layout, isSeries: true,
                availability: DetailSectionAvailability(states: ready([.parentalGuide, .episodes])))
            XCTAssertEqual(sections, [.hero, .parentalGuide, .episodes], "\(layout)")
            let empty = DetailTrailingFocus.tailStops(sections: sections, pendingOrHeld: [],
                                                      facts: Facts(numberedEpisodes: false, warnings: true))
            XCTAssertEqual(empty, [.parentalGuide], "\(layout)")
            // With real episodes the scan stops at Episodes: nothing changes.
            let full = DetailTrailingFocus.tailStops(sections: sections, pendingOrHeld: [],
                                                     facts: Facts(numberedEpisodes: true, warnings: true))
            XCTAssertEqual(full, [], "\(layout)")
        }
    }

    /// Each present-but-empty section after an inert one lets the scan reach the inert one.
    func testEachEmptyTrailingSectionIsSkippedByTheScan() {
        let layoutCases: [(DetailSection, [DetailSection])] = [
            (.trailers, [.parentalGuide, .trailers]), (.moreLikeThis, [.parentalGuide, .moreLikeThis]),
            (.collection, [.parentalGuide, .collection]), (.comments, [.parentalGuide, .comments]),
            (.episodes, [.parentalGuide, .episodes]),
        ]
        for (empty, order) in layoutCases {
            let stops = DetailTrailingFocus.tailStops(sections: [.hero] + order, pendingOrHeld: [],
                                                      facts: Facts(warnings: true))
            XCTAssertEqual(stops, [.parentalGuide], "\(empty)")
        }
        // Bonus (Apple-style): Parental Guide above an empty Bonus.
        let bonus = DetailTrailingFocus.tailStops(sections: [.hero, .parentalGuide, .bonus], pendingOrHeld: [],
                                                  facts: Facts(warnings: true))
        XCTAssertEqual(bonus, [.parentalGuide])
    }

    func testBoxCarriesTheHoldAcrossBodyPasses() {
        let box = DetailTailStopBox()
        let own = ownStop(Config(layout: .appleStyle, series: false))
        let first = box.resolve(sections: [.hero, .castAndCrew, .parentalGuide], contentless: [], focused: nil,
                                hasOwnStop: own)
        XCTAssertEqual(first, [.castAndCrew, .parentalGuide])
        // Comments arrive below while Parental Guide holds focus: the stop stays, Cast's is released.
        let held = box.resolve(sections: [.hero, .castAndCrew, .parentalGuide, .comments], contentless: [],
                               focused: .parentalGuide, hasOwnStop: own)
        XCTAssertEqual(held, [.parentalGuide])
        // Focus leaves: released.
        let released = box.resolve(sections: [.hero, .castAndCrew, .parentalGuide, .comments], contentless: [],
                                   focused: .castAndCrew, hasOwnStop: own)
        XCTAssertEqual(released, [])
    }
}
