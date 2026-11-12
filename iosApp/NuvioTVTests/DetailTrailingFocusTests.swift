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
    func testIdsArrivingUnderAFocusedStopHandFocusToALinkAndDropTheWrapper() {
        let own: (DetailSection) -> Bool = { $0 == .castAndCrew }
        // Stop focused, ids arrive: wrapper gone, hand-off named (focus is never left to fall to nil).
        let handed = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: [.castAndCrew, .parentalGuide],
                                                 focused: .castAndCrew, hasOwnTargets: own)
        XCTAssertEqual(handed.stops, [.parentalGuide])
        XCTAssertEqual(handed.handoff, .castAndCrew)
        // Stop not focused, ids arrive: wrapper gone, no focus change.
        let quiet = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: [.castAndCrew, .parentalGuide],
                                                focused: .parentalGuide, hasOwnTargets: own)
        XCTAssertEqual(quiet.stops, [.parentalGuide])
        XCTAssertNil(quiet.handoff)
        let nofocus = DetailTrailingFocus.resolve(tail: [.parentalGuide], previous: [.castAndCrew, .parentalGuide],
                                                  focused: nil, hasOwnTargets: own)
        XCTAssertEqual(nofocus.stops, [.parentalGuide])
        XCTAssertNil(nofocus.handoff)
    }

    func testBoxHandsOffOnTheTransitionPassOnly() {
        let box = DetailTailStopBox()
        var castIds = false
        let own: (DetailSection) -> Bool = { $0 == .castAndCrew ? castIds : $0 != .parentalGuide }
        let sections: [DetailSection] = [.hero, .castAndCrew, .parentalGuide]
        _ = box.resolve(sections: sections, contentless: [], focused: nil, hasOwnStop: own)
        XCTAssertEqual(box.stops, [.castAndCrew, .parentalGuide])
        castIds = true
        _ = box.resolve(sections: sections, contentless: [], focused: .castAndCrew, hasOwnStop: own)
        XCTAssertEqual(box.stops, [.parentalGuide])
        XCTAssertEqual(box.handoff, .castAndCrew)
        // The next pass (focus now on a link, row still Cast): no second hand-off, wrapper stays gone.
        _ = box.resolve(sections: sections, contentless: [], focused: .castAndCrew, hasOwnStop: own)
        XCTAssertEqual(box.stops, [.parentalGuide])
        XCTAssertNil(box.handoff)
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
        var f = Facts(numberedEpisodes: 3, trailers: 1, bonus: 1, moreLikeThis: 5, collection: 2, comments: 4,
                      castItems: 4, castWithIds: 0, logos: 2, logosWithIds: 0, warnings: 3)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .episodes, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .trailers, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .bonus, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .moreLikeThis, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .collection, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .comments, facts: f), .focusable)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .castAndCrew, facts: f), .inert)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .companies, facts: f), .inert)
        XCTAssertEqual(DetailTrailingFocus.kind(of: .parentalGuide, facts: f), .inert)
        f.castWithIds = 1
        f.logosWithIds = 1
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
                                                      facts: Facts(numberedEpisodes: 0, warnings: 2))
            XCTAssertEqual(empty, [.parentalGuide], "\(layout)")
            // With real episodes the scan stops at Episodes: nothing changes.
            let full = DetailTrailingFocus.tailStops(sections: sections, pendingOrHeld: [],
                                                     facts: Facts(numberedEpisodes: 6, warnings: 2))
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
                                                      facts: Facts(warnings: 1))
            XCTAssertEqual(stops, [.parentalGuide], "\(empty)")
        }
        // Bonus (Apple-style): Parental Guide above an empty Bonus.
        let bonus = DetailTrailingFocus.tailStops(sections: [.hero, .parentalGuide, .bonus], pendingOrHeld: [],
                                                  facts: Facts(warnings: 1))
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
