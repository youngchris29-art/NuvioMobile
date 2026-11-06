import XCTest
import SwiftUI
import UIKit
@testable import NuvioTV

/// Play keeps its label on titles with progress (device pass 2026-11-06, a1f40b76b).
///
/// `DetailCinematicHero` (Cinematic and Apple-style) used to cap its whole left column, action row
/// included, at `DetailCinematicLayout.textColumnMaxWidth` (680 pt). With a saved position the row
/// holds Resume + Start Over + Watch Trailer + Mark Watched + Add to Library (+ Shuffle on a series):
/// the icon buttons are fixed-size, so the shortfall fell on Play's text, the row's only flexible
/// view, and Play drew as a tall unlabelled pill or a circle. The fix caps the text block only and
/// gives the row `.fixedSize(horizontal:)`.
///
/// These tests lay the REAL hero out in a window at the page's real width (1920 minus the tvOS
/// side safe area and the page inset) and measure Play inside it. The row passed in is a stand-in
/// for `DetailView.actionRow`: that row is private to `DetailView` and reads a live
/// `DetailViewModel` (meta, progress, trailer, shuffle settings), which a unit test cannot build
/// deterministically. The stand-in uses the same pieces as the production row in its Cinematic
/// form (`usesIconOnlyLabel`: Play labelled, every secondary icon-only): `.borderedProminent` /
/// `.bordered` with the Corners shape, `Theme.Font.meta`, the same paddings, the production glyphs,
/// `DetailActionGlyphScale` and, for Corners = Square, the production `DetailActionSquare` sizing.
/// The bug lived in how the hero proposes width to whatever row it is given, which is what these
/// tests pin; the row's own composition is pinned by the Detail UI legs.
///
/// Larger Text is not covered here: on the tvOS 27 simulator neither `.dynamicTypeSize(_:)` nor a
/// `preferredContentSizeCategory` trait override changes the metrics of `Font.system(.caption)`
/// (Play's label measured 187 × 30 pt at `.large`, `.accessibility3` and AX-XXL alike), so a unit
/// test cannot reproduce it. The longest English caption below is the width stress case instead.
@MainActor
final class DetailHeroActionRowLayoutTests: XCTestCase {

    // MARK: - Geometry

    /// tvOS keeps 80 pt of horizontal safe area on each side of a 1920 pt screen.
    private static let screenWidth: CGFloat = 1920
    private static let screenHeight: CGFloat = 1080
    private static let sideSafeArea: CGFloat = 80

    /// The width the page gives the hero: Cinematic pads 60 inside the safe area, Apple-style
    /// ignores the side safe area and pads 80 from the bezel (`DetailGeometry.pageInsets`).
    private static func heroWidth(appleStyle: Bool) -> CGFloat {
        let insets = DetailGeometry.pageInsets(appleStyle: appleStyle, cinematicBase: true,
                                               screenPadding: Theme.Spacing.screen, railLeadingExtra: 0)
        let safe = insets.ignoresSideSafeArea ? 0 : sideSafeArea * 2
        return screenWidth - safe - insets.leading - insets.trailing
    }

    // MARK: - Probe

    /// What the layout pass reported, written from `onGeometryChange` callbacks.
    final class Probe {
        var playButton: CGRect = .zero
        var playLabel: CGSize = .zero
        /// Play's label laid out at its ideal size (a hidden `.fixedSize()` copy).
        var playLabelIdeal: CGSize = .zero
        var row: CGRect = .zero
        var secondaries: [String: CGRect] = [:]
        var hero: CGRect = .zero
        /// The credits' text at its one-line ideal width (a hidden `.fixedSize()` copy).
        var creditsIdeal: CGSize = .zero
    }

    struct Config {
        var appleStyle = false
        var series = true
        var playLabel = "Resume S1E3"
        var startOver = true
        var trailer = true
        var shuffle = true
        var square = false
        /// Square only: the label size the production `squareLabelSize` would compute from Play's
        /// measured sizes (nil on the first pass, exactly as in `DetailView`).
        var squareLabel: CGSize? = nil
    }

    private static let credits = DetailCreditsText(
        castNames: "Bryan Cranston, Aaron Paul, Anna Gunn",
        crewLabel: .createdBy,
        crewNames: "Vince Gilligan"
    )

    // MARK: - Stand-in row (DetailView.actionRow, Cinematic form)

    private struct Row: View {
        let config: Config
        let probe: Probe

        private var shape: ButtonBorderShape { config.square ? .roundedRectangle(radius: 0) : .capsule }

        var body: some View {
            HStack(spacing: Theme.Spacing.md) {
                Button {} label: {
                    Label(config.playLabel, systemImage: DetailActionSymbol.play)
                        .font(Theme.Font.meta)
                        .prominentAccentLabel()
                        .onGeometryChange(for: CGSize.self, of: { $0.size }) { probe.playLabel = $0 }
                        // The same label at its ideal size, inside the button so it gets the
                        // style's label spacing too.
                        .background(alignment: .leading) {
                            Label(config.playLabel, systemImage: DetailActionSymbol.play)
                                .font(Theme.Font.meta)
                                .fixedSize()
                                .hidden()
                                .onGeometryChange(for: CGSize.self, of: { $0.size }) { probe.playLabelIdeal = $0 }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xxs + 2)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(shape)
                .tint(Theme.Palette.accent)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.playButton = $0 }

                if config.startOver { secondary("startOver", "Start Over", DetailActionSymbol.startOver) }
                if config.trailer { secondary("trailer", "Watch Trailer", DetailActionSymbol.trailer) }
                secondary("watched", "Mark Watched", DetailActionSymbol.watchedOff)
                secondary("library", "Add to Library", DetailActionSymbol.libraryAdd)
                if config.series && config.shuffle { secondary("shuffle", "Shuffle", DetailActionSymbol.shuffleOff) }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.row = $0 }
        }

        /// `actionLabelBody` + `actionButtonPadding`'s icon-only branch.
        private func secondary(_ key: String, _ title: String, _ glyph: String) -> some View {
            Button {} label: {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: glyph).scaleEffect(DetailActionGlyphScale.scale(for: glyph))
                }
                .labelStyle(.iconOnly)
                .font(Theme.Font.meta)
                .padding(Theme.Spacing.md)
                .modifier(DetailActionSquareLabel(size: config.square ? config.squareLabel : nil))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(shape)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.secondaries[key] = $0 }
        }
    }

    private struct Host: View {
        let config: Config
        let probe: Probe
        let width: CGFloat
        @FocusState private var focus: DetailHeroFocus?
        @State private var sheet = false

        var body: some View {
            DetailCinematicHero(
                title: "Breaking Bad",
                logoURL: nil,
                meta: DetailMetaLineModel(year: "2008", runtime: "47m", genres: ["Drama", "Crime"],
                                          ageRating: "TV-MA", imdbRating: "9.5"),
                ratings: [],
                ratingsGateOn: false,
                ratingsSectionOn: true,
                overview: "A chemistry teacher diagnosed with cancer turns to making methamphetamine.",
                synopsisSlotVisible: true,
                credits: DetailHeroActionRowLayoutTests.credits,
                showSynopsisSheet: $sheet,
                heroFocus: $focus,
                onOpenSynopsis: {}
            ) {
                Row(config: config, probe: probe)
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.hero = $0 }
            .background {
                VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                    Text("With \(DetailHeroActionRowLayoutTests.credits.castNames ?? "")")
                    Text("Created by \(DetailHeroActionRowLayoutTests.credits.crewNames ?? "")")
                }
                .font(Theme.Font.detail)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { probe.creditsIdeal = $0 }
            }
            .frame(width: width, height: DetailHeroActionRowLayoutTests.screenHeight - 120, alignment: .bottomLeading)
        }
    }

    // MARK: - Layout driver

    private var retained: [UIWindow] = []

    private func layOut(_ config: Config) -> Probe {
        let probe = Probe()
        let width = Self.heroWidth(appleStyle: config.appleStyle)
        let controller = UIHostingController(rootView: Host(config: config, probe: probe, width: width))
        controller.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.screenWidth, height: Self.screenHeight))
        window.rootViewController = controller
        window.isHidden = false
        retained.append(window)
        for _ in 0..<4 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return probe
    }

    /// Two passes for Corners = Square, as in `DetailView`: Play is measured, then the secondaries
    /// take `DetailActionSquare.labelSize` from it.
    private func layOutResolvingSquares(_ config: Config) -> Probe {
        let first = layOut(config)
        guard config.square else { return first }
        let button = DetailActionSquare.whole(first.playButton.size)
        // The production measure is Play's PADDED label (`actionButtonPadding`'s geometry probe).
        let paddedLabel = DetailActionSquare.whole(CGSize(width: first.playLabel.width + Theme.Spacing.lg * 2,
                                                          height: first.playLabel.height + (Theme.Spacing.xxs + 2) * 2))
        var next = config
        if let side = DetailActionSquare.side(playHeight: button.height) {
            next.squareLabel = DetailActionSquare.labelSize(side: side, playLabel: paddedLabel, playButton: button)
        }
        return layOut(next)
    }

    override func tearDown() {
        retained.forEach { $0.isHidden = true }
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - Assertions

    private func assertPlayKeepsItsLabel(_ config: Config, _ name: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let probe = layOutResolvingSquares(config)
        let heroWidth = Self.heroWidth(appleStyle: config.appleStyle)
        XCTAssertGreaterThan(probe.playLabelIdeal.width, 1, "\(name): the layout pass never ran", file: file, line: line)
        XCTAssertFalse(probe.secondaries.isEmpty, "\(name): the secondaries never laid out", file: file, line: line)

        // 1. Play's label gets its full ideal width and stays on one line.
        XCTAssertGreaterThanOrEqual(probe.playLabel.width, probe.playLabelIdeal.width - 0.5,
                                    "\(name): Play's label was squeezed (got \(probe.playLabel), ideal \(probe.playLabelIdeal))",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(probe.playLabel.height, probe.playLabelIdeal.height + 0.5,
                                 "\(name): Play's label wrapped (got \(probe.playLabel), ideal \(probe.playLabelIdeal))",
                                 file: file, line: line)

        // 2. Play is a pill, not a tall pill or a circle: wider than tall, and no taller than the
        //    tallest secondary.
        XCTAssertGreaterThan(probe.playButton.width, probe.playButton.height * 1.5,
                             "\(name): Play is not a pill (\(probe.playButton.size))", file: file, line: line)
        let tallestSecondary = probe.secondaries.values.map(\.height).max() ?? 0
        XCTAssertLessThanOrEqual(probe.playButton.height, tallestSecondary + 1,
                                 "\(name): Play (\(probe.playButton.height)) is taller than the secondaries (\(tallestSecondary))",
                                 file: file, line: line)
        if config.square {
            for (key, rect) in probe.secondaries {
                XCTAssertEqual(rect.height, probe.playButton.height, accuracy: 1,
                               "\(name): square \(key) is not as tall as Play", file: file, line: line)
            }
        }

        // 3. Row and credits fit the hero: the row ends inside it and leaves the credits block at
        //    least half its one-line width (it wraps to two lines, `lineLimit(2)`), past the gap.
        let rowTrailing = probe.row.maxX - probe.hero.minX
        let creditsRoom = heroWidth - rowTrailing - Theme.Spacing.xl
        let creditsNeed = min(probe.creditsIdeal.width, DetailCinematicLayout.creditsMaxWidth) / 2
        XCTAssertEqual(probe.hero.width, heroWidth, accuracy: 0.5, "\(name): hero width", file: file, line: line)
        XCTAssertGreaterThanOrEqual(creditsRoom, creditsNeed,
                                    "\(name): the row (\(rowTrailing) pt of \(heroWidth)) leaves the credits \(creditsRoom) pt, needs \(creditsNeed)",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(probe.row.maxX, probe.hero.maxX + 0.5, "\(name): row overflows the hero", file: file, line: line)
    }

    // MARK: - Tests

    /// The device-pass configuration: a series with a saved position (Resume + Start Over +
    /// trailer + Watched + Library + Shuffle), Cinematic, Rounded corners.
    func testSeriesWithProgressKeepsPlayLabelInCinematic() {
        assertPlayKeepsItsLabel(Config(), "cinematic series")
    }

    func testSeriesWithProgressKeepsPlayLabelInAppleStyle() {
        assertPlayKeepsItsLabel(Config(appleStyle: true), "apple-style series")
    }

    func testMovieWithProgressAndTrailerKeepsPlayLabel() {
        assertPlayKeepsItsLabel(Config(series: false, playLabel: "Play"), "cinematic movie")
        assertPlayKeepsItsLabel(Config(appleStyle: true, series: false, playLabel: "Play"), "apple-style movie")
    }

    /// The longest English caption the row can carry, with every button present.
    func testLongResumeCaptionFitsBesideTheCredits() {
        assertPlayKeepsItsLabel(Config(playLabel: "Resume S12E104"), "cinematic long")
        assertPlayKeepsItsLabel(Config(appleStyle: true, playLabel: "Resume S12E104"), "apple-style long")
    }

    /// Corners = Square: the secondaries are cut to squares as tall as Play.
    func testSquareCornersKeepPlayLabelAndEqualHeights() {
        assertPlayKeepsItsLabel(Config(square: true), "cinematic square")
        assertPlayKeepsItsLabel(Config(appleStyle: true, playLabel: "Resume S12E104", square: true), "apple-style square long")
    }

    /// Without Start Over (no saved position) the row was already fine; it must stay so.
    func testNoProgressRowStillKeepsPlayLabel() {
        assertPlayKeepsItsLabel(Config(playLabel: "Play S1E1", startOver: false), "cinematic no progress")
    }
}
