import XCTest
@testable import NuvioTV

/// Home Stage & Strip (P1 §2, §9.3): `StripGeometry` against the spec's 16-row table, the Open Sans
/// spot checks, landscape catalog rows, the 170/171 dp fit boundary (#23, moved from 164/165 by BUG-146 and its second trim), the stage block insets,
/// `pixelCeil`, the peek, and `pageOpacity`. Font metrics are passed explicitly (system: title 38,
/// caption 23, synopsis line 30), so the table does not depend on the simulator's live metrics.
@MainActor
final class StripGeometryTests: XCTestCase {

    /// `PosterStyle.init(from:)`'s scale: 126 dp → 220 pt, height = 1.5 × width.
    private static let dpToPoint: CGFloat = 220.0 / 126.0

    private func inputs(dp: CGFloat,
                        titles: Bool,
                        noZoom: Bool,
                        landscape: Bool = false,
                        titleHeight: CGFloat = 38,
                        caption: CGFloat = 23,
                        synopsisLine: CGFloat = 30,
                        leadingInset: CGFloat = 0) -> StripGeometry.Inputs {
        let width = dp * Self.dpToPoint
        return StripGeometry.Inputs(posterHeight: width * 1.5,
                                    posterWidth: width,
                                    titlesShown: titles,
                                    landscapeCatalogRows: landscape,
                                    noZoom: noZoom,
                                    titleHeight: titleHeight,
                                    folderCaptionHeight: caption,
                                    synopsisLineHeight: synopsisLine,
                                    screenHeight: 1080,
                                    leadingInset: leadingInset)
    }

    private struct TableRow {
        let dp: CGFloat
        let titles: Bool
        let noZoom: Bool
        let rowHeight: CGFloat
        let page: CGFloat
        let strip: CGFloat
        let stage: CGFloat
        let logo: CGFloat
        let synopsisSlot: CGFloat
        let lines: Int
    }

    /// P1 §2's table (system font, titleH 38, peek 44, synLH 30). BUG-146 (2026-10-15): the catalog
    /// row's shelf top padding in the strip is `sm` 12, not `lg` 24, so every titles-on row was 12 pt
    /// shorter and its stage 12 pt taller (titles-off rows were held by the collection row).
    /// BUG-146 second trim (2026-10-16): the heading gap in the strip is `headingGap` 12, not `md` 16,
    /// in BOTH the catalog and the collection row, so every row is 4 pt shorter and every stage 4 pt
    /// taller (re-derived from `make`, not subtracted). One row changes shape: 154 dp titles-off
    /// zoom-on's stage crosses `compactLogoBelowStage` (479.5 → 483.5), so its logo slot grows from
    /// 110 to 150 and the synopsis slot SHRINKS (169.5 → 133.5, 5 → 4 lines).
    private let table: [TableRow] = [
        TableRow(dp: 105, titles: true, noZoom: false, rowHeight: 404.5, page: 444.5, strip: 488.5, stage: 591.5, logo: 150, synopsisSlot: 241.5, lines: 5),
        TableRow(dp: 105, titles: true, noZoom: true, rowHeight: 404.5, page: 404.5, strip: 448.5, stage: 631.5, logo: 150, synopsisSlot: 281.5, lines: 5),
        TableRow(dp: 105, titles: false, noZoom: false, rowHeight: 384, page: 424, strip: 468, stage: 612, logo: 150, synopsisSlot: 262, lines: 5),
        TableRow(dp: 105, titles: false, noZoom: true, rowHeight: 384, page: 384, strip: 428, stage: 652, logo: 150, synopsisSlot: 302, lines: 5),
        TableRow(dp: 126, titles: true, noZoom: false, rowHeight: 459.5, page: 499.5, strip: 543.5, stage: 536.5, logo: 150, synopsisSlot: 186.5, lines: 5),
        TableRow(dp: 126, titles: true, noZoom: true, rowHeight: 459.5, page: 459.5, strip: 503.5, stage: 576.5, logo: 150, synopsisSlot: 226.5, lines: 5),
        TableRow(dp: 126, titles: false, noZoom: false, rowHeight: 439, page: 479, strip: 523, stage: 557, logo: 150, synopsisSlot: 207, lines: 5),
        TableRow(dp: 126, titles: false, noZoom: true, rowHeight: 439, page: 439, strip: 483, stage: 597, logo: 150, synopsisSlot: 247, lines: 5),
        TableRow(dp: 134, titles: true, noZoom: false, rowHeight: 480.5, page: 520.5, strip: 564.5, stage: 515.5, logo: 150, synopsisSlot: 165.5, lines: 5),
        TableRow(dp: 134, titles: true, noZoom: true, rowHeight: 480.5, page: 480.5, strip: 524.5, stage: 555.5, logo: 150, synopsisSlot: 205.5, lines: 5),
        TableRow(dp: 134, titles: false, noZoom: false, rowHeight: 460, page: 500, strip: 544, stage: 536, logo: 150, synopsisSlot: 186, lines: 5),
        TableRow(dp: 134, titles: false, noZoom: true, rowHeight: 460, page: 460, strip: 504, stage: 576, logo: 150, synopsisSlot: 226, lines: 5),
        TableRow(dp: 154, titles: true, noZoom: false, rowHeight: 533, page: 573, strip: 617, stage: 463, logo: 110, synopsisSlot: 153, lines: 5),
        TableRow(dp: 154, titles: true, noZoom: true, rowHeight: 533, page: 533, strip: 577, stage: 503, logo: 150, synopsisSlot: 153, lines: 5),
        TableRow(dp: 154, titles: false, noZoom: false, rowHeight: 512.5, page: 552.5, strip: 596.5, stage: 483.5, logo: 150, synopsisSlot: 133.5, lines: 4),
        TableRow(dp: 154, titles: false, noZoom: true, rowHeight: 512.5, page: 512.5, strip: 556.5, stage: 523.5, logo: 150, synopsisSlot: 173.5, lines: 5),
    ]

    func testSpecTable() {
        for row in table {
            let g = StripGeometry.make(inputs(dp: row.dp, titles: row.titles, noZoom: row.noZoom))
            let label = "\(Int(row.dp)) dp titles=\(row.titles) noZoom=\(row.noZoom)"
            XCTAssertEqual(g.rowHeight, row.rowHeight, accuracy: 0.001, label)
            XCTAssertEqual(g.pageHeight, row.page, accuracy: 0.001, label)
            XCTAssertEqual(g.stripHeight, row.strip, accuracy: 0.001, label)
            XCTAssertEqual(g.stageHeight, row.stage, accuracy: 0.001, label)
            XCTAssertEqual(g.logoSlot, row.logo, accuracy: 0.001, label)
            XCTAssertEqual(g.synopsisSlot, row.synopsisSlot, accuracy: 0.001, label)
            XCTAssertEqual(g.synopsisLines, row.lines, label)
            XCTAssertEqual(g.peek, 44, accuracy: 0.001, label)
            XCTAssertEqual(g.focusLift, row.noZoom ? 0 : 20, accuracy: 0.001, label)
            XCTAssertTrue(g.fits, label)
            XCTAssertEqual(g.layoutPosterHeight, row.dp * Self.dpToPoint * 1.5, accuracy: 0.001, label)
            // The strip and the stage always fill the screen exactly.
            XCTAssertEqual(g.stageHeight + g.stripHeight, 1080, accuracy: 0.001, label)
        }
    }

    /// The spike's Medium numbers (515.5 / 559.5 / 520.5) less BUG-146's 12 pt and its second
    /// trim's 4 pt.
    func testMediumMatchesTheSpike() {
        let g = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false))
        XCTAssertEqual(g.pageHeight, 499.5, accuracy: 0.001)
        XCTAssertEqual(g.stripHeight, 543.5, accuracy: 0.001)
        XCTAssertEqual(g.stageHeight, 536.5, accuracy: 0.001)
    }

    /// Home Watchlist W4 (spec 9.2). G2 / G3 were measured 2026-11-12 on the 1080p tvOS sim clone
    /// "NuvioTV home-watchlist" (CB9C5444), poster cards width 220, Stage with fit rows, from the
    /// laid-out view readout `debug_strip_fit` (not accessibility frames).
    private static let firstCatalogRowMeasured: CGFloat = 459   // G2: key=com.linvo.cinemeta:movie:top m=459 h=498.5
    private static let watchlistRowMeasured: CGFloat = 459      // G3: key=home-watchlist m=459 h=498.5

    /// The sim's title line height was 37 (not the table's 38): that is the one input that
    /// reproduces the measured P 498.5 / stage 538.5 / strip 541.5 (peek 43, row 458.5).
    private func simInputs() -> StripGeometry.Inputs {
        inputs(dp: 126, titles: true, noZoom: false, titleHeight: 37)
    }

    func testWatchlistRowPagesLikeACatalogRow() {
        let g = StripGeometry.make(simInputs())
        let watchlist = StripGeometry.fitPageHeight(measured: Self.watchlistRowMeasured,
                                                    page: g.pageHeight, focusLift: g.focusLift)
        let catalog = StripGeometry.fitPageHeight(measured: Self.firstCatalogRowMeasured,
                                                  page: g.pageHeight, focusLift: g.focusLift)
        XCTAssertEqual(watchlist, catalog, accuracy: 0.001)
        // h = P (the fit page is capped at the fixed page), as measured.
        XCTAssertEqual(watchlist, 498.5, accuracy: 0.5)

        // The same equality holds on the table's Medium inputs (titleH 38).
        let medium = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false))
        XCTAssertEqual(StripGeometry.fitPageHeight(measured: Self.watchlistRowMeasured,
                                                   page: medium.pageHeight, focusLift: medium.focusLift),
                       StripGeometry.fitPageHeight(measured: Self.firstCatalogRowMeasured,
                                                   page: medium.pageHeight, focusLift: medium.focusLift),
                       accuracy: 0.001)
    }

    /// G1 = G4: P 498.5, stageH 538.5, stripH 541.5, measured without (G1) and with (G4) the
    /// Watchlist. The row adds no input to `StripGeometry.make` (it is one more key in the strip;
    /// page, stage and strip heights do not depend on the row set), which is what "does not change
    /// the Stage" means at the unit level.
    func testWatchlistDoesNotChangeTheStage() {
        let g = StripGeometry.make(simInputs())
        XCTAssertEqual(g.pageHeight, 498.5, accuracy: 0.5)
        XCTAssertEqual(g.stageHeight, 538.5, accuracy: 0.5)
        XCTAssertEqual(g.stripHeight, 541.5, accuracy: 0.5)
    }

    func testOpenSansSpotChecks() {
        let medium = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false,
                                               titleHeight: 38.84, synopsisLine: 31.32))
        XCTAssertEqual(medium.rowHeight, 460.5, accuracy: 0.001)
        XCTAssertEqual(medium.pageHeight, 500.5, accuracy: 0.001)
        XCTAssertEqual(medium.stripHeight, 545.5, accuracy: 0.001)
        XCTAssertEqual(medium.stageHeight, 534.5, accuracy: 0.001)
        XCTAssertEqual(medium.synopsisLines, 5)

        let large = StripGeometry.make(inputs(dp: 154, titles: true, noZoom: false,
                                              titleHeight: 38.84, synopsisLine: 31.32))
        XCTAssertEqual(large.pageHeight, 574, accuracy: 0.001)
        XCTAssertEqual(large.stripHeight, 619, accuracy: 0.001)
        XCTAssertEqual(large.stageHeight, 461, accuracy: 0.001)
        XCTAssertEqual(large.synopsisLines, 4)
    }

    func testLandscapeCatalogRowsUseTheCollectionRule() {
        let g = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false, landscape: true))
        XCTAssertEqual(g.rowHeight, 439, accuracy: 0.001)
        XCTAssertEqual(g.stageHeight, 557, accuracy: 0.001)
    }

    /// BUG-146 moved the boundary from 164/165 dp to 168/169 dp (12 pt more room per row), and its
    /// second trim to 170/171 dp (4 pt more).
    func testFitBoundary() {
        let fits = StripGeometry.make(inputs(dp: 170, titles: true, noZoom: false))
        XCTAssertTrue(fits.fits)
        XCTAssertEqual(fits.stageHeight, 421, accuracy: 0.001)

        let tooTall = StripGeometry.make(inputs(dp: 171, titles: true, noZoom: false))
        XCTAssertFalse(tooTall.fits)
        XCTAssertEqual(tooTall.layoutPosterHeight, 446.5, accuracy: 0.001)
        XCTAssertEqual(tooTall.rowHeight, 576, accuracy: 0.001)
        XCTAssertEqual(tooTall.pageHeight, 616, accuracy: 0.001)
        XCTAssertEqual(tooTall.stageHeight, 420, accuracy: 0.001)
        XCTAssertEqual(tooTall.stripHeight, 660, accuracy: 0.001)
        XCTAssertEqual(tooTall.requestedPosterHeight, 171 * Self.dpToPoint * 1.5, accuracy: 0.001)
    }

    /// The clamp never leaves the stage under the floor, whatever font and row shape dominates.
    func testClampKeepsTheFloorAcrossShapes() {
        let shapes: [(titles: Bool, noZoom: Bool, landscape: Bool, title: CGFloat)] = [
            (true, false, false, 38), (false, true, false, 38), (true, false, true, 38),
            (true, false, false, 38.84), (false, false, false, 38.84),
        ]
        for shape in shapes {
            let g = StripGeometry.make(inputs(dp: 200, titles: shape.titles, noZoom: shape.noZoom,
                                              landscape: shape.landscape, titleHeight: shape.title))
            let label = "\(shape)"
            XCTAssertFalse(g.fits, label)
            XCTAssertGreaterThanOrEqual(g.stageHeight, 420, label)
            XCTAssertEqual(g.stageHeight + g.stripHeight, 1080, accuracy: 0.001, label)
            XCTAssertLessThan(g.layoutPosterHeight, 200 * Self.dpToPoint * 1.5, label)
        }
    }

    /// BUG-146 second trim: 12 under a strip heading, Classic's 16 everywhere else; the lift (20)
    /// clears the heading's line box by 4 inside the 24 pt heading → shelf gap.
    func testHeadingGapIsKeyedOnTheStrip() {
        XCTAssertEqual(StripGeometry.headingGap(inStrip: true), 12)
        XCTAssertEqual(StripGeometry.headingGap(inStrip: false), Theme.Spacing.md)
        XCTAssertEqual(StripGeometry.headingGap + StripGeometry.shelfTopPadding
                       - Theme.Size.heroPinnedRowFocusLiftAllowance, 4)
    }

    func testStageBlockInsets() {
        let plain = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false))
        XCTAssertEqual(plain.stageBlockTop, 120, accuracy: 0.001)
        XCTAssertEqual(plain.contentLeading, 140, accuracy: 0.001)
        XCTAssertEqual(plain.stageBlockLeading, 140, accuracy: 0.001)
        XCTAssertEqual(plain.trailingMargin, 140, accuracy: 0.001)

        let rail = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false, leadingInset: 36))
        XCTAssertEqual(rail.contentLeading, 176, accuracy: 0.001)
        XCTAssertEqual(rail.stageBlockLeading, 176, accuracy: 0.001)
        // The inset moves content sideways only.
        XCTAssertEqual(rail.stageHeight, plain.stageHeight, accuracy: 0.001)
    }

    func testPixelCeilAndPeek() {
        XCTAssertEqual(StripGeometry.pixelCeil(496.452), 496.5, accuracy: 0.0001)
        XCTAssertEqual(StripGeometry.pixelCeil(475.5), 475.5, accuracy: 0.0001)
        XCTAssertEqual(StripGeometry.pixelCeil(475.50000000000006), 475.5, accuracy: 0.0001)
        XCTAssertEqual(StripGeometry.pixelCeil(475.51), 476, accuracy: 0.0001)
        let openSans = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false, titleHeight: 38.84))
        XCTAssertEqual(openSans.peek, 45, accuracy: 0.0001)
    }

    func testPageOpacity() {
        let page: CGFloat = 515.5
        XCTAssertEqual(StripGeometry.pageOpacity(minY: 0, pageHeight: page), 1.0)
        XCTAssertEqual(StripGeometry.pageOpacity(minY: page, pageHeight: page), 0.6, accuracy: 1e-9)
        XCTAssertEqual(StripGeometry.pageOpacity(minY: page * 0.5, pageHeight: page), 0.8, accuracy: 1e-9)
        XCTAssertEqual(StripGeometry.pageOpacity(minY: page * 2, pageHeight: page), 0.6, accuracy: 1e-9)
        XCTAssertEqual(StripGeometry.pageOpacity(minY: -page * 0.6, pageHeight: page), 1.0)
        XCTAssertEqual(StripGeometry.pageOpacity(minY: -page, pageHeight: page), 1.0)
    }

    func testSynopsisLines() {
        XCTAssertEqual(StripGeometry.synopsisLines(slot: 150.5, lineHeight: 30), 5)
        XCTAssertEqual(StripGeometry.synopsisLines(slot: 149.5, lineHeight: 30.2), 4)
        XCTAssertEqual(StripGeometry.synopsisLines(slot: 400, lineHeight: 30), 5, "capped at 5")
        XCTAssertEqual(StripGeometry.synopsisLines(slot: 10, lineHeight: 30), 1, "at least 1")
        XCTAssertEqual(StripGeometry.synopsisLines(slot: 100, lineHeight: 0), 1)
    }

    /// #23: the strip re-lays its rows out at the clamped height, keeping 2:3.
    func testPosterStyleWithHeight() {
        let style = PosterStyle().withHeight(430.5)
        XCTAssertEqual(style.height, 430.5, accuracy: 0.0001)
        XCTAssertEqual(style.width, 287, accuracy: 0.0001)
        XCTAssertEqual(style.cornerRadius, PosterStyle().cornerRadius)
        XCTAssertEqual(style.showTitle, PosterStyle().showTitle)
    }

    /// The launch knobs: unset → nil, out of range → clamped, non-positive → nil.
    func testTuningKnobs() throws {
        let suite = "StripGeometryTests.knobs"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(StageStripTuning.knob("debug.x", in: 0.3...1.0, defaults: defaults))
        defaults.set(2.0, forKey: "debug.x")
        XCTAssertEqual(StageStripTuning.knob("debug.x", in: 0.3...1.0, defaults: defaults), 1.0)
        defaults.set(0.1, forKey: "debug.x")
        XCTAssertEqual(StageStripTuning.knob("debug.x", in: 0.3...1.0, defaults: defaults), 0.3)
        defaults.set(0.6, forKey: "debug.x")
        XCTAssertEqual(StageStripTuning.knob("debug.x", in: 0.3...1.0, defaults: defaults), 0.6)
        defaults.set(-1.0, forKey: "debug.x")
        XCTAssertNil(StageStripTuning.knob("debug.x", in: 0.3...1.0, defaults: defaults))
        // The test host passes no knobs: the shipped defaults.
        XCTAssertEqual(StageStripTuning.swapTiming, TextSwapTiming.stage)
        XCTAssertEqual(StageStripTuning.pageSeconds, 0.5)
    }
}
