import XCTest
@testable import NuvioTV

/// A2 (D1): the typed, ordered Detail sections per layout and type, and the availability rules
/// (`DetailSectionOrder`, `DetailSectionAvailability`).
@MainActor
final class DetailSectionOrderTests: XCTestCase {
    private let layouts: [DetailLayout] = [.cinematic, .classic, .appleStyle]

    /// Every section in `sections` ready, the rest hidden.
    private func ready(_ sections: [DetailSection]) -> DetailSectionAvailability {
        var states: [DetailSection: DetailSectionState] = [:]
        for section in sections { states[section] = .ready }
        return DetailSectionAvailability(states: states)
    }

    private var allReady: DetailSectionAvailability { ready(DetailSection.allCases) }

    private func order(_ layout: DetailLayout, series: Bool,
                       _ availability: DetailSectionAvailability? = nil) -> [DetailSection] {
        DetailSectionOrder.sections(layout: layout, isSeries: series, availability: availability ?? allReady)
    }

    // MARK: Presets

    func testCinematicSeriesMatchesToday() {
        XCTAssertEqual(order(.cinematic, series: true),
                       [.hero, .companies, .parentalGuide, .episodes, .castAndCrew, .collection, .trailers,
                        .moreLikeThis, .comments, .about])
    }

    func testCinematicMovieMatchesToday() {
        XCTAssertEqual(order(.cinematic, series: false),
                       [.hero, .companies, .parentalGuide, .castAndCrew, .collection, .trailers,
                        .moreLikeThis, .comments, .about])
    }

    /// Classic has no About (availability hides it, as the page does), and the same preset.
    func testClassicSeriesAndMovieMatchToday() {
        var availability = allReady
        availability.states[.about] = .hidden
        XCTAssertEqual(order(.classic, series: true, availability),
                       [.hero, .companies, .parentalGuide, .episodes, .castAndCrew, .collection, .trailers,
                        .moreLikeThis, .comments])
        XCTAssertEqual(order(.classic, series: false, availability),
                       [.hero, .companies, .parentalGuide, .castAndCrew, .collection, .trailers,
                        .moreLikeThis, .comments])
        for series in [true, false] {
            XCTAssertEqual(DetailSectionOrder.preset(layout: .classic, isSeries: series),
                           DetailSectionOrder.preset(layout: .cinematic, isSeries: series))
        }
    }

    func testAppleStyleSeriesPreset() {
        XCTAssertEqual(DetailSectionOrder.preset(layout: .appleStyle, isSeries: true),
                       [.hero, .episodes, .trailers, .bonus, .moreLikeThis, .castAndCrew, .collection,
                        .companies, .parentalGuide, .comments, .about])
    }

    func testAppleStyleMoviePreset() {
        XCTAssertEqual(DetailSectionOrder.preset(layout: .appleStyle, isSeries: false),
                       [.hero, .trailers, .bonus, .moreLikeThis, .collection, .castAndCrew,
                        .companies, .parentalGuide, .comments, .about])
    }

    /// Cinematic and Classic never list Bonus, even when it reads ready.
    func testCinematicAndClassicPresetsHaveNoBonus() {
        for layout: DetailLayout in [.cinematic, .classic] {
            for series in [true, false] {
                XCTAssertFalse(DetailSectionOrder.preset(layout: layout, isSeries: series).contains(.bonus))
            }
        }
    }

    // MARK: Availability

    func testHiddenAndEmptyAreDroppedEverywhere() {
        for layout in layouts {
            for series in [true, false] {
                let full = order(layout, series: series)
                for section in DetailSection.allCases where section != .hero {
                    for state: DetailSectionState in [.hidden, .empty] {
                        var availability = allReady
                        availability.states[section] = state
                        let result = order(layout, series: series, availability)
                        XCTAssertFalse(result.contains(section), "\(section) \(state) in \(layout)")
                        XCTAssertEqual(result, full.filter { $0 != section }, "\(section) in \(layout)")
                    }
                }
            }
        }
    }

    func testPendingDroppedInCinematicAndClassic() {
        for layout: DetailLayout in [.cinematic, .classic] {
            XCTAssertFalse(DetailSectionOrder.reservesPendingSlots(layout))
            var availability = allReady
            availability.states[.moreLikeThis] = .pending
            XCTAssertFalse(order(layout, series: true, availability).contains(.moreLikeThis), "\(layout)")
        }
    }

    func testPendingKeepsSlotInAppleStyle() {
        XCTAssertTrue(DetailSectionOrder.reservesPendingSlots(.appleStyle))
        var availability = allReady
        availability.states[.moreLikeThis] = .pending
        let result = order(.appleStyle, series: true, availability)
        XCTAssertEqual(result.firstIndex(of: .moreLikeThis), 4)
        XCTAssertEqual(result, order(.appleStyle, series: true))
    }

    func testBonusOnlyWhenApplicable() {
        var cinematic = allReady
        cinematic.states[.bonus] = .hidden
        XCTAssertFalse(order(.cinematic, series: false, cinematic).contains(.bonus))
        XCTAssertFalse(order(.cinematic, series: false).contains(.bonus))

        var apple = allReady
        apple.states[.trailers] = .empty
        let movie = order(.appleStyle, series: false, apple)
        XCTAssertEqual(Array(movie.prefix(2)), [.hero, .bonus])
    }

    func testHeroAlwaysFirst() {
        let states: [DetailSectionState] = [.hidden, .empty, .pending, .ready]
        var generator = SystemRandomNumberGenerator()
        for layout in layouts {
            for series in [true, false] {
                XCTAssertEqual(order(layout, series: series, DetailSectionAvailability()), [.hero])
                for _ in 0..<50 {
                    var availability = DetailSectionAvailability()
                    for section in DetailSection.allCases {
                        availability.states[section] = states.randomElement(using: &generator)
                    }
                    let result = order(layout, series: series, availability)
                    XCTAssertEqual(result.first, .hero)
                    XCTAssertEqual(result.filter { $0 == .hero }.count, 1)
                }
            }
        }
    }

    /// `DetailRowAnchor.direction` reads a missing top for Comments / About as Up: they are last.
    func testCommentsAndAboutAreLastInEveryPreset() {
        for layout in layouts {
            for series in [true, false] {
                XCTAssertEqual(Array(DetailSectionOrder.preset(layout: layout, isSeries: series).suffix(2)),
                               [.comments, .about], "\(layout)")
            }
        }
    }

    func testStateDerivation() {
        typealias A = DetailSectionAvailability
        XCTAssertEqual(A.state(enabled: false, hasContent: true, loading: true), .hidden)
        XCTAssertEqual(A.state(enabled: false, hasContent: false, loading: false), .hidden)
        XCTAssertEqual(A.state(enabled: true, hasContent: true, loading: true), .ready, "content wins over loading")
        XCTAssertEqual(A.state(enabled: true, hasContent: true, loading: false), .ready)
        XCTAssertEqual(A.state(enabled: true, hasContent: false, loading: true), .pending)
        XCTAssertEqual(A.state(enabled: true, hasContent: false, loading: false), .empty)
        // A missing key is hidden; the hero is always ready.
        XCTAssertEqual(A().state(.castAndCrew), .hidden)
        XCTAssertEqual(A(states: [.hero: .hidden]).state(.hero), .ready)
    }

    /// Only More Like This reserves height while pending; the rest of the meta rows land with the
    /// first meta, while focus is still in the hero.
    func testReservedHeights() {
        for shown in [true, false] {
            XCTAssertGreaterThan(DetailSectionOrder.reservedHeight(.moreLikeThis, posterTitlesShown: shown),
                                 Theme.Size.miniPosterHeight)
            for section in DetailSection.allCases where section != .moreLikeThis {
                XCTAssertEqual(DetailSectionOrder.reservedHeight(section, posterTitlesShown: shown), 0, "\(section)")
            }
        }
    }

    /// The reservation follows the row: a `cardTitle` caption line plus its gap with poster titles
    /// on, no caption at all with Hide Labels on.
    func testMoreLikeThisReservationFollowsCaptionSetting() {
        let shown = DetailSectionOrder.moreLikeThisHeight(sectionTitleLine: 40, gap: 16, posterHeight: 270,
                                                          captionLine: 30)
        let hidden = DetailSectionOrder.moreLikeThisHeight(sectionTitleLine: 40, gap: 16, posterHeight: 270,
                                                           captionLine: nil)
        XCTAssertEqual(shown, 40 + 16 + 270 + 32 + 16 + 30)
        XCTAssertEqual(hidden, 40 + 16 + 270 + 32)
        let caption = Theme.Font.uiFont(for: .caption2).lineHeight
        XCTAssertEqual(DetailSectionOrder.reservedHeight(.moreLikeThis, posterTitlesShown: true)
                       - DetailSectionOrder.reservedHeight(.moreLikeThis, posterTitlesShown: false),
                       Theme.Spacing.md + caption, accuracy: 0.001)
    }

    /// A failed meta request is finished: its sections read empty (no placeholder kept forever).
    func testMetaLoadingStates() {
        XCTAssertTrue(DetailSectionAvailability.metaLoading(hasMeta: false, isLoading: true, failed: false))
        // Before the first emission.
        XCTAssertTrue(DetailSectionAvailability.metaLoading(hasMeta: false, isLoading: false, failed: false))
        // Failed request.
        XCTAssertFalse(DetailSectionAvailability.metaLoading(hasMeta: false, isLoading: false, failed: true))
        XCTAssertFalse(DetailSectionAvailability.metaLoading(hasMeta: true, isLoading: true, failed: false))
        let failed = DetailSectionAvailability.state(
            enabled: true, hasContent: false,
            loading: DetailSectionAvailability.metaLoading(hasMeta: false, isLoading: false, failed: true))
        XCTAssertEqual(failed, .empty)
        XCTAssertFalse(DetailSectionOrder.sections(layout: .appleStyle, isSeries: true,
                                                   availability: .init(states: [.moreLikeThis: failed]))
            .contains(.moreLikeThis))
    }

    // MARK: Identity

    func testRawValuesAreStable() {
        XCTAssertEqual(DetailSection.allCases.map(\.rawValue),
                       ["hero", "companies", "parentalGuide", "episodes", "castAndCrew", "collection",
                        "trailers", "bonus", "moreLikeThis", "comments", "about"])
    }

    func testRowIDMappingIsOneToOne() {
        XCTAssertNil(DetailSection.hero.rowID)
        let ids = DetailSection.allCases.filter { $0 != .hero }.compactMap { $0.rowID }
        XCTAssertEqual(ids.count, DetailSection.allCases.count - 1)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(DetailSection.companies.rowID, .logos)
        XCTAssertEqual(DetailSection.parentalGuide.rowID, .parental)
        XCTAssertEqual(DetailSection.castAndCrew.rowID, .cast)
        XCTAssertEqual(DetailSection.bonus.rowID, .bonus)
    }

    // MARK: Layout setting

    func testLayoutValues() {
        XCTAssertEqual(DetailLayout.resolve("apple"), .appleStyle)
        XCTAssertEqual(DetailLayout.appleStyle.rawValue, "apple")
        XCTAssertEqual(DetailLayout.allCases, [.cinematic, .classic, .appleStyle])
        XCTAssertEqual(DetailLayout.appleStyle.visualBase, .cinematic)
        XCTAssertEqual(DetailLayout.cinematic.visualBase, .cinematic)
        XCTAssertEqual(DetailLayout.classic.visualBase, .classic)
        XCTAssertEqual(DetailLayout.resolve(""), .cinematic)
    }

    func testAppleStyleSharesCinematicGeometry() {
        let cases: [(hero: CGFloat, chips: Bool)] = [(627, true), (627, false), (300, true)]
        for (hero, chips) in cases {
            XCTAssertEqual(DetailDim.rampDistance(layout: .appleStyle, heroHeight: hero, hasChipRow: chips),
                           DetailDim.rampDistance(layout: .cinematic, heroHeight: hero, hasChipRow: chips))
        }
        XCTAssertEqual(DetailDim.scrolledDistance(layout: .appleStyle, contentOffset: 600, contentInsetTop: 157),
                       DetailDim.scrolledDistance(layout: .cinematic, contentOffset: 600, contentInsetTop: 157))
        XCTAssertEqual(DetailRowAnchor.firstItemLead(for: .logos, layout: .appleStyle), 0)
        XCTAssertEqual(DetailRowAnchor.firstItemLead(for: .bonus, layout: .appleStyle),
                       DetailRowAnchor.firstItemLead(for: .trailers, layout: .appleStyle))
        XCTAssertEqual(DetailRowAnchor.firstItemLead(for: .bonus, layout: .cinematic),
                       DetailRowAnchor.firstItemLead(for: .trailers, layout: .cinematic))
    }

    // MARK: - Held slots (DetailSlotHold)

    private var seriesOrder: [DetailSection] { DetailSectionOrder.preset(layout: .appleStyle, isSeries: true) }

    private func availability(moreLikeThis: DetailSectionState) -> DetailSectionAvailability {
        DetailSectionAvailability(states: [.episodes: .ready, .trailers: .ready, .moreLikeThis: moreLikeThis,
                                           .castAndCrew: .ready, .collection: .ready])
    }

    /// Placeholder 300, measured ready row 320, every other row 200.
    private func update(_ hold: inout DetailSlotHold, _ state: DetailSectionState,
                        _ focus: DetailSlotHold.Focus, reserves: Bool = true,
                        order: [DetailSection]? = nil) -> [DetailSection: CGFloat] {
        hold.update(order: order ?? seriesOrder, availability: availability(moreLikeThis: state), focus: focus,
                    reservesSlots: reserves, height: { section, state in
                        guard section == .moreLikeThis else { return 200 }
                        return state == .pending ? 300 : 320
                    })
    }

    /// Pending → empty while focus is in Cast & Crew (below): held at the placeholder height, still
    /// held further down, released for good once focus is back above it.
    func testPendingThenEmptyHeldWhileFocusBelow() {
        var hold = DetailSlotHold()
        XCTAssertEqual(update(&hold, .pending, .row(.castAndCrew)), [:])
        XCTAssertEqual(update(&hold, .empty, .row(.castAndCrew)), [.moreLikeThis: 300])
        XCTAssertEqual(update(&hold, .empty, .row(.collection)), [.moreLikeThis: 300])
        XCTAssertEqual(update(&hold, .empty, .row(.trailers)), [:])
        XCTAssertEqual(update(&hold, .empty, .row(.castAndCrew)), [:])
        XCTAssertTrue(DetailSectionOrder.sections(layout: .appleStyle, isSeries: true,
                                                  availability: availability(moreLikeThis: .empty),
                                                  held: [.moreLikeThis]).contains(.moreLikeThis))
    }

    /// Ready (initial recommendations) → empty after enrichment while focus is below: held at the
    /// row's measured height.
    func testReadyThenEmptyHeldAtMeasuredHeight() {
        var hold = DetailSlotHold()
        _ = update(&hold, .ready, .row(.castAndCrew))
        XCTAssertEqual(update(&hold, .empty, .row(.castAndCrew)), [.moreLikeThis: 320])
    }

    /// Pending or ready → empty with focus at or above the section: dropped at once.
    func testEmptyWithFocusAboveDrops() {
        let above: [DetailSlotHold.Focus] = [.hero, .row(.episodes), .row(.trailers), .row(.bonus), .row(.moreLikeThis)]
        for before in [DetailSectionState.pending, .ready] {
            for focus in above {
                var hold = DetailSlotHold()
                _ = update(&hold, before, focus)
                XCTAssertEqual(update(&hold, .empty, focus), [:], "\(before) \(focus)")
            }
        }
    }

    /// A cover (or a focus restore) takes focus off the page: the last on-page focus stands, so the
    /// held slot stays under the cover; real hero focus releases it.
    func testOffPageFocusKeepsTheLastRow() {
        var hold = DetailSlotHold()
        _ = update(&hold, .pending, .row(.castAndCrew))
        XCTAssertEqual(update(&hold, .empty, .row(.castAndCrew)), [.moreLikeThis: 300])
        XCTAssertEqual(update(&hold, .empty, .offPage), [.moreLikeThis: 300])
        XCTAssertEqual(update(&hold, .empty, .offPage), [.moreLikeThis: 300])
        XCTAssertEqual(update(&hold, .empty, .hero), [:])
    }

    /// Empty arriving while focus is off the page after being in a row below: held too.
    func testEmptyArrivingUnderACoverIsHeld() {
        var hold = DetailSlotHold()
        _ = update(&hold, .ready, .row(.collection))
        XCTAssertEqual(update(&hold, .empty, .offPage), [.moreLikeThis: 320])
    }

    /// Data coming back renders for real, nothing held.
    func testReadyAgainIsNotHeld() {
        var hold = DetailSlotHold()
        _ = update(&hold, .pending, .row(.castAndCrew))
        XCTAssertEqual(update(&hold, .ready, .row(.castAndCrew)), [:])
    }

    /// Cinematic and Classic never reserve, so nothing is held.
    func testNoHoldWithoutReservation() {
        var hold = DetailSlotHold()
        let order = DetailSectionOrder.preset(layout: .cinematic, isSeries: true)
        _ = update(&hold, .ready, .row(.castAndCrew), reserves: false, order: order)
        XCTAssertEqual(update(&hold, .empty, .row(.castAndCrew), reserves: false, order: order), [:])
        XCTAssertFalse(DetailSectionOrder.sections(layout: .cinematic, isSeries: true,
                                                   availability: availability(moreLikeThis: .empty),
                                                   held: [.moreLikeThis]).contains(.moreLikeThis))
    }

    func testSectionForRow() {
        XCTAssertNil(DetailSection.section(for: nil))
        XCTAssertEqual(DetailSection.section(for: .cast), .castAndCrew)
        XCTAssertEqual(DetailSection.section(for: .moreLikeThis), .moreLikeThis)
    }
}
