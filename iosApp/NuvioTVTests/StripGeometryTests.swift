import XCTest
@testable import NuvioTV

/// Home Stage & Strip (P1 §2, §9.3): `StripGeometry` against the spec's 16-row table, the Open Sans
/// spot checks, landscape catalog rows, the 164/165 dp fit boundary (#23), the stage block insets,
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

    /// P1 §2's table (system font, titleH 38, peek 44, synLH 30).
    private let table: [TableRow] = [
        TableRow(dp: 105, titles: true, noZoom: false, rowHeight: 420.5, page: 460.5, strip: 504.5, stage: 575.5, logo: 150, synopsisSlot: 225.5, lines: 5),
        TableRow(dp: 105, titles: true, noZoom: true, rowHeight: 420.5, page: 420.5, strip: 464.5, stage: 615.5, logo: 150, synopsisSlot: 265.5, lines: 5),
        TableRow(dp: 105, titles: false, noZoom: false, rowHeight: 388, page: 428, strip: 472, stage: 608, logo: 150, synopsisSlot: 258, lines: 5),
        TableRow(dp: 105, titles: false, noZoom: true, rowHeight: 388, page: 388, strip: 432, stage: 648, logo: 150, synopsisSlot: 298, lines: 5),
        TableRow(dp: 126, titles: true, noZoom: false, rowHeight: 475.5, page: 515.5, strip: 559.5, stage: 520.5, logo: 150, synopsisSlot: 170.5, lines: 5),
        TableRow(dp: 126, titles: true, noZoom: true, rowHeight: 475.5, page: 475.5, strip: 519.5, stage: 560.5, logo: 150, synopsisSlot: 210.5, lines: 5),
        TableRow(dp: 126, titles: false, noZoom: false, rowHeight: 443, page: 483, strip: 527, stage: 553, logo: 150, synopsisSlot: 203, lines: 5),
        TableRow(dp: 126, titles: false, noZoom: true, rowHeight: 443, page: 443, strip: 487, stage: 593, logo: 150, synopsisSlot: 243, lines: 5),
        TableRow(dp: 134, titles: true, noZoom: false, rowHeight: 496.5, page: 536.5, strip: 580.5, stage: 499.5, logo: 150, synopsisSlot: 149.5, lines: 5),
        TableRow(dp: 134, titles: true, noZoom: true, rowHeight: 496.5, page: 496.5, strip: 540.5, stage: 539.5, logo: 150, synopsisSlot: 189.5, lines: 5),
        TableRow(dp: 134, titles: false, noZoom: false, rowHeight: 464, page: 504, strip: 548, stage: 532, logo: 150, synopsisSlot: 182, lines: 5),
        TableRow(dp: 134, titles: false, noZoom: true, rowHeight: 464, page: 464, strip: 508, stage: 572, logo: 150, synopsisSlot: 222, lines: 5),
        TableRow(dp: 154, titles: true, noZoom: false, rowHeight: 549, page: 589, strip: 633, stage: 447, logo: 110, synopsisSlot: 137, lines: 4),
        TableRow(dp: 154, titles: true, noZoom: true, rowHeight: 549, page: 549, strip: 593, stage: 487, logo: 150, synopsisSlot: 137, lines: 4),
        TableRow(dp: 154, titles: false, noZoom: false, rowHeight: 516.5, page: 556.5, strip: 600.5, stage: 479.5, logo: 110, synopsisSlot: 169.5, lines: 5),
        TableRow(dp: 154, titles: false, noZoom: true, rowHeight: 516.5, page: 516.5, strip: 560.5, stage: 519.5, logo: 150, synopsisSlot: 169.5, lines: 5),
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

    func testMediumMatchesTheSpike() {
        let g = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false))
        XCTAssertEqual(g.pageHeight, 515.5, accuracy: 0.001)
        XCTAssertEqual(g.stripHeight, 559.5, accuracy: 0.001)
        XCTAssertEqual(g.stageHeight, 520.5, accuracy: 0.001)
    }

    func testOpenSansSpotChecks() {
        let medium = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false,
                                               titleHeight: 38.84, synopsisLine: 31.32))
        XCTAssertEqual(medium.rowHeight, 476.5, accuracy: 0.001)
        XCTAssertEqual(medium.pageHeight, 516.5, accuracy: 0.001)
        XCTAssertEqual(medium.stripHeight, 561.5, accuracy: 0.001)
        XCTAssertEqual(medium.stageHeight, 518.5, accuracy: 0.001)
        XCTAssertEqual(medium.synopsisLines, 5)

        let large = StripGeometry.make(inputs(dp: 154, titles: true, noZoom: false,
                                              titleHeight: 38.84, synopsisLine: 31.32))
        XCTAssertEqual(large.pageHeight, 590, accuracy: 0.001)
        XCTAssertEqual(large.stripHeight, 635, accuracy: 0.001)
        XCTAssertEqual(large.stageHeight, 445, accuracy: 0.001)
        XCTAssertEqual(large.synopsisLines, 4)
    }

    func testLandscapeCatalogRowsUseTheCollectionRule() {
        let g = StripGeometry.make(inputs(dp: 126, titles: true, noZoom: false, landscape: true))
        XCTAssertEqual(g.rowHeight, 443, accuracy: 0.001)
        XCTAssertEqual(g.stageHeight, 553, accuracy: 0.001)
    }

    func testFitBoundary() {
        let fits = StripGeometry.make(inputs(dp: 164, titles: true, noZoom: false))
        XCTAssertTrue(fits.fits)
        XCTAssertEqual(fits.stageHeight, 420.5, accuracy: 0.001)

        let tooTall = StripGeometry.make(inputs(dp: 165, titles: true, noZoom: false))
        XCTAssertFalse(tooTall.fits)
        XCTAssertEqual(tooTall.layoutPosterHeight, 430.5, accuracy: 0.001)
        XCTAssertEqual(tooTall.rowHeight, 576, accuracy: 0.001)
        XCTAssertEqual(tooTall.pageHeight, 616, accuracy: 0.001)
        XCTAssertEqual(tooTall.stageHeight, 420, accuracy: 0.001)
        XCTAssertEqual(tooTall.stripHeight, 660, accuracy: 0.001)
        XCTAssertEqual(tooTall.requestedPosterHeight, 165 * Self.dpToPoint * 1.5, accuracy: 0.001)
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
